package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

const (
	monkeyMuxVersion         = "0.1.47"
	defaultColumns           = 80
	defaultRows              = 24
	maxTitleBytes            = 160
	oscBufferLimitBytes      = 4096
	processMetadataTimeout   = 500 * time.Millisecond
	processMetadataInterval  = 500 * time.Millisecond
	runCommandOutputMaxBytes = 8 * 1024 * 1024
	runCommandTimeout        = 20 * time.Second
	socketTimeout            = 2 * time.Second
	windowUpdateMinInterval  = 750 * time.Millisecond
	windowHistoryLimitBytes  = 128 * 1024
	windowReplayLimitBytes   = 32 * 1024
	csiBufferLimitBytes      = 64
	themeHintLimitBytes      = 1024
	restoreFileMode          = 0o600
	restoreSchemaVersion     = 1
)

const terminalParserResetSequence = "\x1b\\"

const terminalCharacterSetResetSequence = "\x0f\x1b(B\x1b)B"

const terminalScreenClearSequence = "\x1b[H\x1b[2J\x1b[3J"

const terminalAllScreensClearSequence = terminalScreenClearSequence + "\x1b[?1049h" + terminalScreenClearSequence + "\x1b[?1049l" + terminalScreenClearSequence

const activeWindowReplayPrefix = terminalParserResetSequence + "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?1007l\x1b[?2004l\x1b[?2031l\x1b[?1049l\x1b[?1l\x1b[?6l\x1b[?7h\x1b[4l\x1b>\x1b[r" + terminalCharacterSetResetSequence + "\x1b[0m" + terminalAllScreensClearSequence

var (
	preReplayPrivateModes = []string{
		"1049",
		"6",
		"7",
		"1",
		"1000",
		"1002",
		"1003",
		"1006",
		"1004",
		"1007",
		"2004",
		"2031",
	}
	postReplayPrivateModes = []string{
		"7",
		"1",
		"1000",
		"1002",
		"1003",
		"1006",
		"1004",
		"1007",
		"2004",
		"2031",
	}
	trackedPrivateModes = map[string]struct{}{
		"1":    {},
		"6":    {},
		"7":    {},
		"1000": {},
		"1002": {},
		"1003": {},
		"1004": {},
		"1006": {},
		"1007": {},
		"1049": {},
		"2004": {},
		"2031": {},
	}
)

var capabilities = []string{
	"attach",
	"attach-command",
	"control-json-v1",
	"direct-pass-through",
	"posix-pty",
	"window-list",
	"window-create",
	"window-select",
	"window-close",
	"active-context",
	"inject-input",
	"run-command",
	"client-scoped-run-command",
	"focus-hint",
	"theme-hint",
	"shutdown",
	"attach-update-policy",
	"attach-state",
	"upgrade-restore-v1",
}

var (
	errRunCommandCanceled     = errors.New("command canceled")
	errRunCommandClientClosed = errors.New("control client closed")
	errRunCommandOutputLimit  = errors.New("command output limit exceeded")
	errRunCommandTimeout      = errors.New("command timed out")
)

var signalForegroundResize = func(processGroup int) {
	if processGroup <= 0 {
		return
	}
	_ = syscall.Kill(-processGroup, syscall.SIGWINCH)
}

var foregroundProcessGroupForWindow = func(window *muxWindow) int {
	if window == nil || window.pty == nil {
		return 0
	}
	pgrp, err := unix.IoctlGetInt(int(window.pty.Fd()), unix.TIOCGPGRP)
	if err != nil || pgrp <= 0 {
		return 0
	}
	return pgrp
}

const (
	serverUpdatePolicyPrompt = "prompt"
	serverUpdatePolicyNever  = "never"
	serverUpdatePolicyAlways = "always"
)

var (
	leadingCdCommandPattern       = regexp.MustCompile(`^cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*`)
	leadingEnvPattern             = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=(?:"(?:[^"\\]|\\.)*"|'[^']*'|\S+)\s+`)
	restoreFileNamePattern        = regexp.MustCompile(`^monkeymux-restore-[a-f0-9]{24}-[0-9]+\.json$`)
	agentSessionIDArgumentPattern = map[string][]*regexp.Regexp{
		"claude": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"copilot": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"codex": {
			regexp.MustCompile(`(?:^|\s)resume\s+(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"gemini": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"opencode": {
			regexp.MustCompile(`(?:^|\s)--session(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
		"antigravity": {
			regexp.MustCompile(`(?:^|\s)--conversation(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
	}
)

type controlMessage struct {
	Role        string   `json:"role,omitempty"`
	ID          string   `json:"id,omitempty"`
	Type        string   `json:"type,omitempty"`
	Session     string   `json:"session,omitempty"`
	WindowID    string   `json:"windowId,omitempty"`
	WindowIndex *int     `json:"windowIndex,omitempty"`
	Name        string   `json:"name,omitempty"`
	Cwd         string   `json:"cwd,omitempty"`
	Command     string   `json:"command,omitempty"`
	Args        []string `json:"args,omitempty"`
	Data        string   `json:"data,omitempty"`
	Width       int      `json:"width,omitempty"`
	Height      int      `json:"height,omitempty"`
	PixelWidth  int      `json:"pixelWidth,omitempty"`
	PixelHeight int      `json:"pixelHeight,omitempty"`
}

type controlResponse struct {
	ID             string           `json:"id,omitempty"`
	Type           string           `json:"type"`
	Status         string           `json:"status,omitempty"`
	Error          string           `json:"error,omitempty"`
	Version        string           `json:"version,omitempty"`
	Session        string           `json:"session,omitempty"`
	Capabilities   []string         `json:"capabilities,omitempty"`
	Windows        []windowSnapshot `json:"windows,omitempty"`
	Window         *windowSnapshot  `json:"window,omitempty"`
	CurrentPath    string           `json:"currentPath,omitempty"`
	CurrentCommand string           `json:"currentCommand,omitempty"`
	Data           string           `json:"data,omitempty"`
	ExitCode       int              `json:"exitCode,omitempty"`
	HasAttach      bool             `json:"hasForegroundClient,omitempty"`
	Restore        *serverRestore   `json:"restore,omitempty"`
}

type windowSnapshot struct {
	ID                        string `json:"id"`
	Index                     int    `json:"index"`
	Name                      string `json:"name"`
	Active                    bool   `json:"active"`
	CurrentCommand            string `json:"currentCommand,omitempty"`
	CurrentPath               string `json:"currentPath,omitempty"`
	PanePid                   int    `json:"panePid,omitempty"`
	Flags                     string `json:"flags,omitempty"`
	PaneTitle                 string `json:"paneTitle,omitempty"`
	AgentTool                 string `json:"agentTool,omitempty"`
	LastActivityEpochSeconds  int64  `json:"lastActivityEpochSeconds,omitempty"`
	TerminalReportsMouseWheel bool   `json:"terminalReportsMouseWheel,omitempty"`
	TerminalMouseReportSgr    bool   `json:"terminalMouseReportSgr,omitempty"`
}

type serverRestore struct {
	SchemaVersion   int                  `json:"schemaVersion"`
	Windows         []restoreWindowState `json:"windows,omitempty"`
	StartInYoloMode bool                 `json:"startInYoloMode,omitempty"`
}

type restoreWindowState struct {
	ID                       string          `json:"id,omitempty"`
	Index                    int             `json:"index,omitempty"`
	Name                     string          `json:"name,omitempty"`
	Cwd                      string          `json:"cwd,omitempty"`
	CurrentCommand           string          `json:"currentCommand,omitempty"`
	PanePid                  int             `json:"panePid,omitempty"`
	PaneTitle                string          `json:"paneTitle,omitempty"`
	AgentTool                string          `json:"agentTool,omitempty"`
	AgentSessionID           string          `json:"agentSessionId,omitempty"`
	HistoryBase64            string          `json:"historyBase64,omitempty"`
	CursorVisible            bool            `json:"cursorVisible,omitempty"`
	CursorVisibilityKnown    bool            `json:"cursorVisibilityKnown,omitempty"`
	PrivateModes             map[string]bool `json:"privateModes,omitempty"`
	InsertModeEnabled        bool            `json:"insertModeEnabled,omitempty"`
	InsertModeKnown          bool            `json:"insertModeKnown,omitempty"`
	ApplicationKeypadEnabled bool            `json:"applicationKeypadEnabled,omitempty"`
	ApplicationKeypadKnown   bool            `json:"applicationKeypadKnown,omitempty"`
	Active                   bool            `json:"active,omitempty"`
}

type muxServer struct {
	session string
	width   int
	height  int

	mu         sync.Mutex
	windows    []*muxWindow
	activeID   string
	nextID     int
	listener   net.Listener
	attachConn net.Conn
	attachMu   sync.Mutex
	controls   map[*controlClient]struct{}
	themeHint  []byte
	closed     bool
}

type muxWindow struct {
	id                         string
	index                      int
	name                       string
	cwd                        string
	command                    string
	agentTool                  string
	foregroundPid              int
	foregroundCommand          string
	paneTitle                  string
	pty                        *os.File
	cmd                        *exec.Cmd
	history                    []byte
	oscBuffer                  []byte
	attachOscBuffer            []byte
	csiBuffer                  []byte
	lastActivity               time.Time
	lastProcessMetadataRefresh time.Time
	lastBroadcast              time.Time
	cursorVisible              bool
	cursorVisibilityKnown      bool
	privateModes               map[string]bool
	insertModeEnabled          bool
	insertModeKnown            bool
	applicationKeypadEnabled   bool
	applicationKeypadKnown     bool
	focusModeEnabled           bool
	focusModeProcessID         int
	themeRefreshModeProcessID  int
	themeColorQueryPid         int
	themeColorQueryKeys        map[string]bool
	alert                      bool
	closed                     bool
}

type windowBroadcastIdentity struct {
	name      string
	cwd       string
	command   string
	paneTitle string
	agentTool string
	panePid   int
	alert     bool
}

type controlClient struct {
	conn net.Conn
	enc  *json.Encoder

	mu sync.Mutex

	commandsMu sync.Mutex
	commands   map[string]context.CancelFunc
	closed     bool
}

func main() {
	if len(os.Args) < 2 {
		usageAndExit()
	}

	switch os.Args[1] {
	case "attach":
		attachCommand(os.Args[2:])
	case "control":
		controlCommand(os.Args[2:])
	case "serve":
		serveCommand(os.Args[2:])
	case "gc":
		gcCommand()
	case "version", "--version", "-v":
		fmt.Println(monkeyMuxVersion)
	default:
		usageAndExit()
	}
}

func usageAndExit() {
	fmt.Fprintln(os.Stderr, "usage: monkeymux attach [--cwd DIR] [--name NAME] [--command CMD] [--restore-yolo] [--theme-hint-base64 DATA] [--update-policy prompt|never|always] <session> | control <session> --json | gc | version")
	os.Exit(2)
}

func attachCommand(args []string) {
	fs := flag.NewFlagSet("attach", flag.ExitOnError)
	cwd := fs.String("cwd", "", "initial working directory")
	name := fs.String("name", "", "initial window name")
	command := fs.String("command", "", "initial command")
	restoreYolo := fs.Bool("restore-yolo", false, "restore agent windows in YOLO mode")
	themeHintBase64 := fs.String("theme-hint-base64", "", "base64-encoded terminal theme reports")
	updatePolicy := fs.String("update-policy", serverUpdatePolicyPrompt, "running server update policy: prompt, never, or always")
	_ = fs.Parse(args)
	if fs.NArg() != 1 {
		usageAndExit()
	}
	policy, err := normalizeServerUpdatePolicy(*updatePolicy)
	if err != nil {
		fatal(err)
	}
	themeHint, err := decodeThemeHintBase64(*themeHintBase64)
	if err != nil {
		fatal(err)
	}
	session := fs.Arg(0)
	width, height := terminalSize()
	if err := ensureServer(
		session,
		createWindowOptions{
			cwd:       *cwd,
			name:      *name,
			command:   *command,
			themeHint: themeHint,
		},
		policy,
		*restoreYolo,
		width,
		height,
	); err != nil {
		fatal(err)
	}

	conn, err := dialSession(session)
	if err != nil {
		fatal(err)
	}
	defer conn.Close()

	hello := controlMessage{
		Role:    "attach",
		Session: session,
		Width:   width,
		Height:  height,
		Data:    string(themeHint),
	}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	restoreTerminal := makeTerminalRaw()
	defer restoreTerminal()

	stopResize := forwardResizeSignals(session)
	defer stopResize()

	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
}

func controlCommand(args []string) {
	fs := flag.NewFlagSet("control", flag.ExitOnError)
	jsonMode := fs.Bool("json", false, "use newline-delimited JSON")
	_ = fs.String("cwd", "", "ignored; only attach starts sessions")
	_ = fs.Parse(args)
	if fs.NArg() != 1 || !*jsonMode {
		usageAndExit()
	}
	session := fs.Arg(0)

	conn, err := dialSession(session)
	if err != nil {
		fatal(fmt.Errorf("monkeymux session %q is not running; attach before opening control", session))
	}
	defer conn.Close()

	hello := controlMessage{Role: "control", Session: session}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
}

func serveCommand(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	session := fs.String("session", "", "session name")
	cwd := fs.String("cwd", "", "initial working directory")
	name := fs.String("name", "", "initial window name")
	command := fs.String("command", "", "initial command")
	restoreFile := fs.String("restore-file", "", "window restore snapshot")
	width := fs.Int("width", defaultColumns, "initial terminal columns")
	height := fs.Int("height", defaultRows, "initial terminal rows")
	themeHintBase64 := fs.String("theme-hint-base64", "", "base64-encoded terminal theme reports")
	_ = fs.Parse(args)
	if strings.TrimSpace(*session) == "" {
		usageAndExit()
	}
	themeHint, err := decodeThemeHintBase64(*themeHintBase64)
	if err != nil {
		fatal(err)
	}
	restore, err := readRestoreFile(*restoreFile)
	if err != nil {
		fatal(err)
	}
	if err := serveSession(*session, createWindowOptions{
		cwd:       *cwd,
		name:      *name,
		command:   *command,
		themeHint: themeHint,
	}, restore, *width, *height); err != nil {
		fatal(err)
	}
}

func decodeThemeHintBase64(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid theme hint: %w", err)
	}
	if len(decoded) > themeHintLimitBytes {
		return nil, fmt.Errorf("theme hint is too large")
	}
	return decoded, nil
}

func gcCommand() {
	runDir, err := runtimeDirectory()
	if err != nil {
		fatal(err)
	}
	entries, err := os.ReadDir(runDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "monkeymux-") {
			continue
		}
		path := filepath.Join(runDir, entry.Name())
		conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			continue
		}
		_ = os.Remove(path)
	}
}

func ensureServer(
	session string,
	initialWindow createWindowOptions,
	updatePolicy string,
	startInYoloMode bool,
	width int,
	height int,
) error {
	var restore *serverRestore
	if status, err := queryRunningServerStatus(session); err == nil {
		if status.version == monkeyMuxVersion {
			return nil
		}
		if !shouldUpdateRunningServer(
			os.Stdin,
			os.Stderr,
			session,
			status,
			updatePolicy,
		) {
			return nil
		}
		restore = collectServerRestore(session, status)
		if restore != nil {
			restore.StartInYoloMode = startInYoloMode
		}
		if status.supportsCapability("shutdown") {
			requestServerShutdown(session)
			if !waitForServerExit(session, 2*time.Second) {
				fmt.Fprintf(
					os.Stderr,
					"monkeymux: running session did not exit; continuing with helper %s\r\n",
					status.displayVersion(),
				)
				return nil
			}
		} else {
			fmt.Fprintf(
				os.Stderr,
				"monkeymux: abandoning helper %s socket and starting helper %s\r\n",
				status.displayVersion(),
				monkeyMuxVersion,
			)
		}
	}

	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	_ = os.Remove(socket)

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, "serve", "--session", session)
	if width > 0 && height > 0 {
		cmd.Args = append(
			cmd.Args,
			"--width",
			strconv.Itoa(width),
			"--height",
			strconv.Itoa(height),
		)
	}
	if restore != nil && len(restore.Windows) > 0 {
		path, err := writeRestoreFile(session, restore)
		if err == nil {
			defer os.Remove(path)
			cmd.Args = append(cmd.Args, "--restore-file", path)
		}
	}
	if strings.TrimSpace(initialWindow.cwd) != "" {
		cmd.Args = append(cmd.Args, "--cwd", initialWindow.cwd)
	}
	if strings.TrimSpace(initialWindow.name) != "" {
		cmd.Args = append(cmd.Args, "--name", initialWindow.name)
	}
	if strings.TrimSpace(initialWindow.command) != "" {
		cmd.Args = append(cmd.Args, "--command", initialWindow.command)
	}
	if len(initialWindow.themeHint) > 0 {
		cmd.Args = append(cmd.Args, "--theme-hint-base64", base64.StdEncoding.EncodeToString(initialWindow.themeHint))
	}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Env = inheritedEnvironment(os.Environ())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	_ = cmd.Process.Release()

	deadline := time.Now().Add(socketTimeout)
	for time.Now().Before(deadline) {
		conn, err := dialSession(session)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("monkeymux server did not start for session %q", session)
}

func collectServerRestore(session string, status runningServerStatus) *serverRestore {
	var restore *serverRestore
	if status.supportsCapability("upgrade-restore-v1") {
		if snapshot, err := requestServerRestore(session); err == nil && len(snapshot.Windows) > 0 {
			restore = snapshot
		}
	}
	if restore == nil {
		windows, err := queryServerWindows(session)
		if err != nil || len(windows) == 0 {
			return nil
		}
		restore = restoreFromWindowSnapshots(windows)
		enrichRestoreWithCapturedShellHistory(session, restore)
	}
	enrichRestoreWithAgentSessionIDs(restore)
	return restore
}

func requestServerRestore(session string) (*serverRestore, error) {
	conn, err := dialSession(session)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil, err
	}
	if _, err := readControlHello(dec); err != nil {
		return nil, err
	}
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:      requestID,
		Type:    "upgrade_snapshot",
		Session: session,
	}); err != nil {
		return nil, err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return nil, err
		}
		if response.ID != requestID {
			continue
		}
		if response.Status == "error" || response.Type == "error" {
			return nil, errors.New(response.Error)
		}
		if response.Restore == nil || len(response.Restore.Windows) == 0 {
			return nil, errors.New("empty restore snapshot")
		}
		return response.Restore, nil
	}
}

func queryServerWindows(session string) ([]windowSnapshot, error) {
	conn, err := dialSession(session)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil, err
	}
	if _, err := readControlHello(dec); err != nil {
		return nil, err
	}
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:      requestID,
		Type:    "list_windows",
		Session: session,
	}); err != nil {
		return nil, err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return nil, err
		}
		if response.Type == "window_list" && (response.ID == requestID || response.ID == "") {
			return response.Windows, nil
		}
		if response.ID == requestID && (response.Status == "error" || response.Type == "error") {
			return nil, errors.New(response.Error)
		}
	}
}

func readControlHello(dec *json.Decoder) (controlResponse, error) {
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return controlResponse{}, err
		}
		if response.Type == "hello" {
			return response, nil
		}
	}
}

func restoreFromWindowSnapshots(windows []windowSnapshot) *serverRestore {
	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows:       make([]restoreWindowState, 0, len(windows)),
	}
	for _, window := range windows {
		restore.Windows = append(restore.Windows, restoreWindowState{
			ID:             window.ID,
			Index:          window.Index,
			Name:           window.Name,
			Cwd:            window.CurrentPath,
			CurrentCommand: window.CurrentCommand,
			PanePid:        window.PanePid,
			PaneTitle:      window.PaneTitle,
			AgentTool:      window.AgentTool,
			PrivateModes:   privateModesFromWindowSnapshot(window),
			Active:         window.Active,
		})
	}
	return restore
}

func privateModesFromWindowSnapshot(window windowSnapshot) map[string]bool {
	modes := map[string]bool{}
	if window.TerminalReportsMouseWheel {
		modes["1000"] = true
	}
	if window.TerminalMouseReportSgr {
		modes["1006"] = true
	}
	if len(modes) == 0 {
		return nil
	}
	return modes
}

func enrichRestoreWithCapturedShellHistory(session string, restore *serverRestore) {
	if restore == nil || !restoreNeedsShellHistory(restore) {
		return
	}
	histories := captureShellWindowHistories(session, restore)
	for i := range restore.Windows {
		if !isShellRestoreWindow(restore.Windows[i]) ||
			restore.Windows[i].HistoryBase64 != "" {
			continue
		}
		history := histories[restore.Windows[i].ID]
		if len(history) == 0 {
			continue
		}
		restore.Windows[i].HistoryBase64 = base64.StdEncoding.EncodeToString(history)
	}
}

func restoreNeedsShellHistory(restore *serverRestore) bool {
	for _, window := range restore.Windows {
		if isShellRestoreWindow(window) && window.HistoryBase64 == "" {
			return true
		}
	}
	return false
}

func captureShellWindowHistories(
	session string,
	restore *serverRestore,
) map[string][]byte {
	targets := map[string]restoreWindowState{}
	activeID := ""
	for _, window := range restore.Windows {
		if window.Active {
			activeID = window.ID
		}
		if isShellRestoreWindow(window) && window.ID != "" {
			targets[window.ID] = window
		}
	}
	if len(targets) == 0 {
		return nil
	}

	attachConn, err := dialSession(session)
	if err != nil {
		return nil
	}
	defer attachConn.Close()
	controlConn, err := dialSession(session)
	if err != nil {
		return nil
	}
	defer controlConn.Close()
	_ = attachConn.SetDeadline(time.Now().Add(socketTimeout))
	_ = controlConn.SetDeadline(time.Now().Add(socketTimeout))

	if err := json.NewEncoder(attachConn).Encode(controlMessage{
		Role:    "attach",
		Session: session,
		Width:   defaultColumns,
		Height:  defaultRows,
	}); err != nil {
		return nil
	}
	controlEnc := json.NewEncoder(controlConn)
	controlDec := json.NewDecoder(controlConn)
	if err := controlEnc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return nil
	}
	if _, err := readControlHello(controlDec); err != nil {
		return nil
	}

	histories := map[string][]byte{}
	if _, ok := targets[activeID]; ok {
		if history := readAttachReplayHistory(attachConn); len(history) > 0 {
			histories[activeID] = history
		}
	}
	for _, window := range restore.Windows {
		if _, ok := targets[window.ID]; !ok || window.ID == activeID {
			continue
		}
		if err := requestSelectWindow(controlEnc, controlDec, session, window.ID); err != nil {
			continue
		}
		if history := readAttachReplayHistory(attachConn); len(history) > 0 {
			histories[window.ID] = history
		}
	}
	if activeID != "" {
		_ = requestSelectWindow(controlEnc, controlDec, session, activeID)
	}
	return histories
}

func requestSelectWindow(
	enc *json.Encoder,
	dec *json.Decoder,
	session string,
	windowID string,
) error {
	requestID := strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := enc.Encode(controlMessage{
		ID:       requestID,
		Type:     "select_window",
		Session:  session,
		WindowID: windowID,
	}); err != nil {
		return err
	}
	for {
		var response controlResponse
		if err := dec.Decode(&response); err != nil {
			return err
		}
		if response.ID != requestID {
			continue
		}
		if response.Status == "error" || response.Type == "error" {
			return errors.New(response.Error)
		}
		return nil
	}
}

func readAttachReplayHistory(conn net.Conn) []byte {
	var output bytes.Buffer
	buf := make([]byte, 32*1024)
	deadline := time.Now().Add(150 * time.Millisecond)
	_ = conn.SetReadDeadline(deadline)
	for output.Len() < windowHistoryLimitBytes {
		n, err := conn.Read(buf)
		if n > 0 {
			remaining := windowHistoryLimitBytes - output.Len()
			if n > remaining {
				n = remaining
			}
			_, _ = output.Write(buf[:n])
			deadline = time.Now().Add(50 * time.Millisecond)
			_ = conn.SetReadDeadline(deadline)
		}
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				break
			}
			break
		}
	}
	return normalizeCapturedReplayHistory(output.Bytes())
}

func normalizeCapturedReplayHistory(history []byte) []byte {
	if len(history) == 0 {
		return nil
	}
	if bytes.HasPrefix(history, []byte(activeWindowReplayPrefix)) {
		history = history[len(activeWindowReplayPrefix):]
	}
	if len(history) > windowHistoryLimitBytes {
		history = history[len(history)-windowHistoryLimitBytes:]
	}
	return append([]byte(nil), history...)
}

func enrichRestoreWithAgentSessionIDs(restore *serverRestore) {
	if restore == nil {
		return
	}
	panePids := map[int]struct{}{}
	for _, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) != "" {
			continue
		}
		if agentToolForRestore(window) == "" || window.PanePid <= 0 {
			continue
		}
		panePids[window.PanePid] = struct{}{}
	}
	if len(panePids) == 0 {
		return
	}
	processes := readProcessTable()
	if len(processes) == 0 {
		return
	}
	copilotSessions := discoverCopilotSessionIDs(processes, panePids)
	for i := range restore.Windows {
		if strings.TrimSpace(restore.Windows[i].AgentSessionID) != "" {
			continue
		}
		tool := agentToolForRestore(restore.Windows[i])
		panePid := restore.Windows[i].PanePid
		if panePid <= 0 || tool == "" {
			continue
		}
		if tool == "copilot" {
			if sessionID := copilotSessions[panePid]; sessionID != "" {
				restore.Windows[i].AgentSessionID = sessionID
				continue
			}
		}
		if sessionID := sessionIDFromDescendantProcessArgs(processes, panePid, tool); sessionID != "" {
			restore.Windows[i].AgentSessionID = sessionID
		}
	}
}

func agentToolForRestore(window restoreWindowState) string {
	return firstNonEmptyString(
		window.AgentTool,
		agentToolFromCommandName(window.CurrentCommand),
		agentToolFromTerminalTitle(window.PaneTitle),
		agentToolFromCommandName(window.Name),
	)
}

type processInfo struct {
	pid  int
	ppid int
	pgid int
	comm string
	args string
}

type processTableCache struct {
	mu        sync.Mutex
	loadedAt  time.Time
	processes map[int]processInfo
}

var commandProcessTableCache processTableCache

func readProcessTable() map[int]processInfo {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"ps",
		"-eo",
		"pid=,ppid=,pgid=,comm=,args=",
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	processes := map[int]processInfo{}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		pgid, err := strconv.Atoi(fields[2])
		if err != nil {
			continue
		}
		args := ""
		if len(fields) > 4 {
			args = strings.Join(fields[4:], " ")
		}
		processes[pid] = processInfo{
			pid:  pid,
			ppid: ppid,
			pgid: pgid,
			comm: fields[3],
			args: args,
		}
	}
	return processes
}

func cachedProcessTable(now time.Time) map[int]processInfo {
	commandProcessTableCache.mu.Lock()
	defer commandProcessTableCache.mu.Unlock()
	if commandProcessTableCache.processes != nil &&
		!commandProcessTableCache.loadedAt.IsZero() &&
		now.Sub(commandProcessTableCache.loadedAt) < processMetadataInterval {
		return commandProcessTableCache.processes
	}
	processes := readProcessTable()
	commandProcessTableCache.processes = processes
	commandProcessTableCache.loadedAt = now
	return processes
}

func discoverCopilotSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	stateDir := filepath.Join(home, ".copilot", "session-state")
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return nil
	}
	sessions := map[int]string{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(stateDir, entry.Name())
		locks, err := filepath.Glob(filepath.Join(dir, "inuse.*.lock"))
		if err != nil {
			continue
		}
		for _, lock := range locks {
			pid := pidFromCopilotLockPath(lock)
			if pid <= 0 {
				continue
			}
			process, ok := processes[pid]
			if !ok || !strings.Contains(strings.ToLower(process.comm+" "+process.args), "copilot") {
				continue
			}
			if panePid := ancestorPanePID(processes, pid, panePids); panePid > 0 {
				sessions[panePid] = entry.Name()
			}
		}
	}
	return sessions
}

func pidFromCopilotLockPath(path string) int {
	name := filepath.Base(path)
	if !strings.HasPrefix(name, "inuse.") || !strings.HasSuffix(name, ".lock") {
		return 0
	}
	pidText := strings.TrimSuffix(strings.TrimPrefix(name, "inuse."), ".lock")
	pid, err := strconv.Atoi(pidText)
	if err != nil {
		return 0
	}
	return pid
}

func ancestorPanePID(
	processes map[int]processInfo,
	pid int,
	panePids map[int]struct{},
) int {
	seen := map[int]struct{}{}
	for current := pid; current > 0; {
		if _, ok := panePids[current]; ok {
			return current
		}
		if _, ok := seen[current]; ok {
			return 0
		}
		seen[current] = struct{}{}
		process, ok := processes[current]
		if !ok {
			return 0
		}
		current = process.ppid
	}
	return 0
}

func sessionIDFromDescendantProcessArgs(
	processes map[int]processInfo,
	panePid int,
	tool string,
) string {
	targetPanePids := map[int]struct{}{panePid: struct{}{}}
	for _, process := range processes {
		if ancestorPanePID(processes, process.pid, targetPanePids) != panePid {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if agentToolFromCommandName(command) != tool {
			continue
		}
		if sessionID := agentSessionIDFromArgs(tool, process.args); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func agentSessionIDFromArgs(tool string, args string) string {
	for _, pattern := range agentSessionIDArgumentPattern[tool] {
		match := pattern.FindStringSubmatch(args)
		if match == nil {
			continue
		}
		for _, group := range match[1:] {
			if strings.TrimSpace(group) != "" {
				return strings.TrimSpace(group)
			}
		}
	}
	return ""
}

func serveSession(
	session string,
	initialWindow createWindowOptions,
	restore *serverRestore,
	width int,
	height int,
) error {
	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return err
	}
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(socket)
	}()
	_ = os.Chmod(socket, 0o600)

	server := newMuxServerWithSize(session, width, height)
	server.themeHint = append([]byte(nil), initialWindow.themeHint...)
	server.listener = listener
	if err := server.restoreOrCreateInitialWindow(restore, initialWindow); err != nil {
		return err
	}
	defer server.close()

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		<-signals
		server.close()
		_ = listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if server.isClosed() {
				return nil
			}
			return err
		}
		go server.handleConnection(conn)
	}
}

func newMuxServer(session string) *muxServer {
	return newMuxServerWithSize(session, defaultColumns, defaultRows)
}

func newMuxServerWithSize(session string, width int, height int) *muxServer {
	if width <= 0 {
		width = defaultColumns
	}
	if height <= 0 {
		height = defaultRows
	}
	return &muxServer{
		session:  session,
		width:    width,
		height:   height,
		controls: map[*controlClient]struct{}{},
	}
}

func readRestoreFile(path string) (*serverRestore, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var restore serverRestore
	if err := json.Unmarshal(data, &restore); err != nil {
		return nil, err
	}
	if restore.SchemaVersion != restoreSchemaVersion {
		return nil, fmt.Errorf("unsupported MonkeyMux restore schema %d", restore.SchemaVersion)
	}
	if isManagedRestoreFile(path) {
		_ = os.Remove(path)
	}
	return &restore, nil
}

func isManagedRestoreFile(path string) bool {
	absPath, err := filepath.Abs(path)
	if err != nil || !restoreFileNamePattern.MatchString(filepath.Base(absPath)) {
		return false
	}
	runDir, err := runtimeDirectory()
	if err != nil {
		return false
	}
	absRunDir, err := filepath.Abs(runDir)
	if err != nil {
		return false
	}
	return filepath.Dir(absPath) == absRunDir
}

func writeRestoreFile(session string, restore *serverRestore) (string, error) {
	runDir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		return "", err
	}
	data, err := json.Marshal(restore)
	if err != nil {
		return "", err
	}
	path := filepath.Join(
		runDir,
		fmt.Sprintf(
			"monkeymux-restore-%s-%d.json",
			restoreSessionToken(session),
			time.Now().UnixNano(),
		),
	)
	if err := os.WriteFile(path, data, restoreFileMode); err != nil {
		return "", err
	}
	return path, nil
}

func restoreSessionToken(session string) string {
	sum := sha256.Sum256([]byte(session))
	return hex.EncodeToString(sum[:])[:24]
}

func (s *muxServer) restoreOrCreateInitialWindow(
	restore *serverRestore,
	initialWindow createWindowOptions,
) error {
	if restore == nil || len(restore.Windows) == 0 {
		_, err := s.createWindow(initialWindow)
		return err
	}

	var activeID string
	var firstID string
	restored := 0
	for _, state := range restore.Windows {
		window, err := s.createWindow(
			createWindowOptionsForRestore(state, restore.StartInYoloMode),
		)
		if err != nil {
			continue
		}
		if firstID == "" {
			firstID = window.id
		}
		if state.Active {
			activeID = window.id
		}
		restored++
	}
	if restored == 0 {
		_, err := s.createWindow(initialWindow)
		return err
	}
	if activeID == "" {
		activeID = firstID
	}
	if activeID != "" {
		_ = s.selectWindow(activeID)
	}
	return nil
}

func createWindowOptionsForRestore(
	state restoreWindowState,
	startInYoloMode bool,
) createWindowOptions {
	agentTool := firstNonEmptyString(
		state.AgentTool,
		agentToolFromCommandName(state.CurrentCommand),
		agentToolFromTerminalTitle(state.PaneTitle),
		agentToolFromCommandName(state.Name),
	)
	command := ""
	if agentTool != "" {
		command = agentLaunchCommand(agentTool, startInYoloMode)
		if sessionID := strings.TrimSpace(state.AgentSessionID); sessionID != "" {
			command = agentResumeCommand(agentTool, sessionID, startInYoloMode)
		}
	}
	history := []byte(nil)
	if isShellRestoreWindow(state) {
		history = decodeRestoreHistory(state.HistoryBase64)
	}
	return createWindowOptions{
		name:                     firstNonEmptyString(state.Name, state.PaneTitle, state.CurrentCommand, "shell"),
		cwd:                      state.Cwd,
		command:                  command,
		history:                  history,
		paneTitle:                firstNonEmptyString(state.PaneTitle, state.Name),
		agentTool:                agentTool,
		cursorVisible:            state.CursorVisible,
		cursorVisibilityKnown:    state.CursorVisibilityKnown,
		privateModes:             copyPrivateModes(state.PrivateModes),
		insertModeEnabled:        state.InsertModeEnabled,
		insertModeKnown:          state.InsertModeKnown,
		applicationKeypadEnabled: state.ApplicationKeypadEnabled,
		applicationKeypadKnown:   state.ApplicationKeypadKnown,
	}
}

func decodeRestoreHistory(encoded string) []byte {
	if strings.TrimSpace(encoded) == "" {
		return nil
	}
	history, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil
	}
	if len(history) > windowHistoryLimitBytes {
		return append([]byte(nil), history[len(history)-windowHistoryLimitBytes:]...)
	}
	return history
}

func isShellRestoreWindow(state restoreWindowState) bool {
	agentTool := firstNonEmptyString(
		state.AgentTool,
		agentToolFromCommandName(state.CurrentCommand),
		agentToolFromTerminalTitle(state.PaneTitle),
		agentToolFromCommandName(state.Name),
	)
	if agentTool != "" {
		return false
	}
	command := cleanProcessCommandName(state.CurrentCommand)
	return command == "" || isShellCommandName(command)
}

type createWindowOptions struct {
	name                     string
	cwd                      string
	command                  string
	args                     []string
	history                  []byte
	paneTitle                string
	agentTool                string
	cursorVisible            bool
	cursorVisibilityKnown    bool
	privateModes             map[string]bool
	insertModeEnabled        bool
	insertModeKnown          bool
	applicationKeypadEnabled bool
	applicationKeypadKnown   bool
	themeHint                []byte
}

func (s *muxServer) createWindow(options createWindowOptions) (*muxWindow, error) {
	var attach net.Conn
	var replay []byte
	var snapshots []windowSnapshot
	var addedSnapshot *windowSnapshot
	cwd := strings.TrimSpace(options.cwd)
	if cwd == "" {
		if current, err := os.Getwd(); err == nil {
			cwd = current
		}
	} else if expanded, err := expandHomePath(cwd); err == nil {
		cwd = expanded
	}

	shell := defaultShellPath()
	cmd := shellCommand(shell)
	name := filepath.Base(shell)
	if len(options.args) > 0 {
		cmd = exec.Command(options.args[0], options.args[1:]...)
		name = filepath.Base(options.args[0])
	} else if strings.TrimSpace(options.command) != "" {
		cmd = shellCommandForScript(shell, strings.TrimSpace(options.command))
	}
	if strings.TrimSpace(options.name) != "" {
		name = strings.TrimSpace(options.name)
	} else if strings.TrimSpace(options.command) != "" {
		name = firstShellWord(options.command)
	}
	agentTool := firstNonEmptyString(
		options.agentTool,
		agentToolFromCommandText(options.command),
		agentToolFromCommandName(name),
	)
	paneTitle := firstNonEmptyString(options.paneTitle, name)
	cursorVisible := true
	if options.cursorVisibilityKnown {
		cursorVisible = options.cursorVisible
	}
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = inheritedEnvironment(os.Environ())

	s.mu.Lock()
	size := &pty.Winsize{Rows: uint16(s.height), Cols: uint16(s.width)}
	s.mu.Unlock()

	file, err := pty.StartWithSize(cmd, size)
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.nextID++
	window := &muxWindow{
		id:                       fmt.Sprintf("@%d", s.nextID),
		index:                    len(s.windows),
		name:                     name,
		cwd:                      cwd,
		command:                  filepath.Base(cmd.Path),
		agentTool:                agentTool,
		foregroundPid:            cmd.Process.Pid,
		foregroundCommand:        filepath.Base(cmd.Path),
		paneTitle:                paneTitle,
		pty:                      file,
		cmd:                      cmd,
		history:                  append([]byte(nil), options.history...),
		lastActivity:             time.Now(),
		cursorVisible:            cursorVisible,
		cursorVisibilityKnown:    options.cursorVisibilityKnown,
		privateModes:             copyPrivateModes(options.privateModes),
		insertModeEnabled:        options.insertModeEnabled,
		insertModeKnown:          options.insertModeKnown,
		applicationKeypadEnabled: options.applicationKeypadEnabled,
		applicationKeypadKnown:   options.applicationKeypadKnown,
	}
	s.windows = append(s.windows, window)
	s.activeID = window.id
	s.clearAlertsLocked(window.id)
	attach = s.attachConn
	replay = s.replayBytesLocked(window)
	snapshots = s.snapshotsLocked()
	addedSnapshot = snapshotByID(snapshots, window.id)
	s.mu.Unlock()

	s.writeAttach(attach, replay)
	go s.readWindow(window)
	go func() {
		_ = cmd.Wait()
		s.markWindowClosed(window.id)
	}()

	s.broadcast(controlResponse{
		Type:    "window_added",
		Session: s.session,
		Window:  addedSnapshot,
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	s.broadcast(controlResponse{
		Type:    "active_window_changed",
		Session: s.session,
		Windows: snapshots,
	})
	return window, nil
}

func (s *muxServer) readWindow(window *muxWindow) {
	buf := make([]byte, 32*1024)
	for {
		n, err := window.pty.Read(buf)
		if n > 0 {
			s.handleWindowOutput(window.id, buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) handleWindowOutput(windowID string, chunk []byte) {
	var attach net.Conn
	var forwarded []byte
	var themeHint []byte
	var themeHintData []byte
	var shouldWrite bool
	var snapshot *windowSnapshot
	now := time.Now()

	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return
	}
	before := window.broadcastIdentityLocked()
	wasAlert := window.alert
	window.lastActivity = now
	window.refreshProcessMetadataLocked(now)
	queryKeys := window.observeTerminalMetadataLocked(chunk)
	if len(queryKeys) > 0 && len(s.themeHint) > 0 {
		themeHint = append([]byte(nil), s.themeHint...)
		themeHintData = themeHintResponsesForKeys(themeHint, queryKeys)
	}
	window.observeTerminalModesLocked(chunk)
	window.appendHistoryLocked(chunk)
	if s.activeID == windowID {
		attach = s.attachConn
		shouldWrite = attach != nil
	} else if containsTerminalBell(chunk) {
		window.alert = true
	}
	after := window.broadcastIdentityLocked()
	if before != after ||
		(!wasAlert && window.alert) ||
		window.lastBroadcast.IsZero() ||
		now.Sub(window.lastBroadcast) >= windowUpdateMinInterval {
		snap := s.snapshotLocked(window)
		snapshot = &snap
		window.lastBroadcast = now
	}
	if shouldWrite {
		forwarded = window.stripLocallyAnsweredThemeQueriesLocked(chunk, themeHint)
	}
	s.mu.Unlock()

	if len(themeHintData) > 0 {
		_ = s.writeWindow(windowID, themeHintData)
	}

	if shouldWrite {
		if len(forwarded) > 0 {
			s.writeAttachIfActive(windowID, attach, forwarded)
		}
	}

	if snapshot != nil {
		s.broadcast(controlResponse{
			Type:    "window_updated",
			Session: s.session,
			Window:  snapshot,
		})
	}
}

func (s *muxServer) markWindowClosed(windowID string) {
	var attach net.Conn
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var shouldShutdown bool

	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	window.closed = true
	window.alert = false
	_ = window.pty.Close()
	s.reindexWindowsLocked()
	if s.activeID == windowID {
		s.activeID = ""
		for _, candidate := range s.windows {
			if !candidate.closed {
				s.activeID = candidate.id
				candidate.alert = false
				s.resizeActiveLocked(s.width, s.height)
				attach = s.attachConn
				replay = s.replayBytesLocked(candidate)
				foregroundProcessGroup = candidate.foregroundProcessGroupLocked()
				activeChanged = true
				break
			}
		}
	}
	snapshots := s.snapshotsLocked()
	shouldShutdown = len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		s.writeAttachLocked(attach, replay)
	}
	s.attachMu.Unlock()

	s.broadcast(controlResponse{
		Type:    "window_removed",
		Session: s.session,
		Window:  &windowSnapshot{ID: windowID},
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	if activeChanged {
		s.broadcast(controlResponse{
			Type:    "active_window_changed",
			Session: s.session,
			Windows: snapshots,
		})
		signalForegroundResize(foregroundProcessGroup)
	}
	if shouldShutdown {
		go s.close()
	}
}

func (s *muxServer) handleConnection(conn net.Conn) {
	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		_ = conn.Close()
		return
	}
	var hello controlMessage
	if err := json.Unmarshal(line, &hello); err != nil {
		_ = conn.Close()
		return
	}
	switch hello.Role {
	case "attach":
		s.handleAttach(conn, reader, hello)
	case "control":
		s.handleControl(conn, reader)
	default:
		_ = conn.Close()
	}
}

func (s *muxServer) handleAttach(conn net.Conn, reader *bufio.Reader, hello controlMessage) {
	var replay []byte
	var foregroundProcessGroup int
	var themeHintData []byte
	var themeHintWindowID string
	s.mu.Lock()
	if s.attachConn != nil {
		_ = s.attachConn.Close()
	}
	s.attachConn = conn
	if themeHint := themeHintDataFromString(hello.Data); len(themeHint) > 0 {
		s.themeHint = append(s.themeHint[:0], themeHint...)
	}
	if hello.Width > 0 && hello.Height > 0 {
		s.width = hello.Width
		s.height = hello.Height
		s.resizeAllLocked(hello.Width, hello.Height)
	}
	replay = s.activeReplayLocked()
	if window := s.windowByIDLocked(s.activeID); window != nil {
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
		if len(s.themeHint) > 0 {
			themeHintData = themeHintResponsesForKeys(
				s.themeHint,
				window.themeHintRefreshKeysLocked(),
			)
			themeHintWindowID = window.id
		}
	}
	s.mu.Unlock()
	s.writeAttach(conn, replay)
	if len(themeHintData) > 0 {
		_ = s.writeWindow(themeHintWindowID, themeHintData)
	}
	s.broadcastWindowList("active_window_changed")
	signalForegroundResize(foregroundProcessGroup)

	defer func() {
		s.mu.Lock()
		if s.attachConn == conn {
			s.attachConn = nil
		}
		s.mu.Unlock()
		_ = conn.Close()
	}()

	buf := make([]byte, 32*1024)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			s.writeActiveFromAttach(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) handleControl(conn net.Conn, reader *bufio.Reader) {
	client := newControlClient(conn)
	s.addControl(client)
	defer func() {
		client.close()
		s.removeControl(client)
		_ = conn.Close()
	}()

	client.send(controlResponse{
		Type:         "hello",
		Status:       "ok",
		Version:      monkeyMuxVersion,
		Session:      s.session,
		Capabilities: capabilities,
	})
	client.send(controlResponse{
		Type:    "window_list",
		Status:  "ok",
		Session: s.session,
		Windows: s.snapshots(),
	})

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var request controlMessage
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			client.send(controlResponse{
				Type:   "error",
				Status: "error",
				Error:  err.Error(),
			})
			continue
		}
		s.handleControlRequest(client, request)
	}
}

func (s *muxServer) handleControlRequest(client *controlClient, request controlMessage) {
	switch request.Type {
	case "ping":
		client.send(controlResponse{ID: request.ID, Type: "pong", Status: "ok"})
	case "list_windows":
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_list",
			Status:  "ok",
			Session: s.session,
			Windows: s.snapshots(),
		})
	case "upgrade_snapshot":
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "upgrade_snapshot",
			Status:  "ok",
			Session: s.session,
			Restore: s.restoreSnapshot(),
		})
	case "create_window":
		window, err := s.createWindow(createWindowOptions{
			name:    request.Name,
			cwd:     request.Cwd,
			command: request.Command,
			args:    request.Args,
		})
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_created",
			Status:  "ok",
			Session: s.session,
			Window:  ptrWindowSnapshot(s.snapshot(window)),
		})
	case "select_window":
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		if err := s.selectWindow(id); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_selected", Status: "ok"})
	case "close_window", "kill_window":
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		shouldShutdown, err := s.closeWindow(id)
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_closed", Status: "ok"})
		if shouldShutdown {
			go s.close()
		}
	case "resize":
		if request.Width <= 0 || request.Height <= 0 {
			client.sendError(request, errors.New("invalid terminal size"))
			return
		}
		s.resize(request.Width, request.Height)
		client.send(controlResponse{ID: request.ID, Type: "resized", Status: "ok"})
	case "query_active_context":
		s.mu.Lock()
		window := s.windowByIDLocked(s.activeID)
		if window == nil || window.closed {
			s.mu.Unlock()
			client.sendError(request, errors.New("no active window"))
			return
		}
		window.refreshProcessMetadataLocked(time.Now())
		currentPath := window.cwd
		currentCommand := window.currentCommandLocked()
		s.mu.Unlock()
		client.send(controlResponse{
			ID:             request.ID,
			Type:           "active_context",
			Status:         "ok",
			Session:        s.session,
			CurrentPath:    currentPath,
			CurrentCommand: currentCommand,
		})
	case "query_attach_state":
		client.send(controlResponse{
			ID:        request.ID,
			Type:      "attach_state",
			Status:    "ok",
			Session:   s.session,
			HasAttach: s.hasAttachClient(),
		})
	case "run_command":
		if strings.TrimSpace(request.Command) == "" {
			client.sendError(request, errors.New("missing command"))
			return
		}
		client.runShellCommandAsync(s, request)
	case "inject_input":
		id := request.WindowID
		if id == "" {
			id = s.activeWindowID()
		}
		if err := s.writeWindow(id, []byte(request.Data)); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "input_injected", Status: "ok"})
	case "focus_changed":
		s.sendThemeHint(request.Data)
		client.send(controlResponse{ID: request.ID, Type: "focus_hint_sent", Status: "ok"})
	case "theme_changed":
		s.sendThemeHint(request.Data)
		client.send(controlResponse{ID: request.ID, Type: "theme_hint_ack", Status: "ok"})
	case "shutdown":
		client.send(controlResponse{ID: request.ID, Type: "shutdown", Status: "ok"})
		go s.close()
	default:
		client.sendError(request, fmt.Errorf("unsupported command %q", request.Type))
	}
}

func (s *muxServer) addControl(client *controlClient) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.controls[client] = struct{}{}
}

func (s *muxServer) removeControl(client *controlClient) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.controls, client)
}

func (s *muxServer) hasAttachClient() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attachConn != nil
}

func newControlClient(conn net.Conn) *controlClient {
	client := &controlClient{
		conn:     conn,
		commands: map[string]context.CancelFunc{},
	}
	if conn != nil {
		client.enc = json.NewEncoder(conn)
	}
	return client
}

func (c *controlClient) send(response controlResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.enc == nil {
		return
	}
	_ = c.enc.Encode(response)
}

func (c *controlClient) sendError(request controlMessage, err error) {
	c.send(controlResponse{
		ID:     request.ID,
		Type:   "error",
		Status: "error",
		Error:  err.Error(),
	})
}

func (c *controlClient) trackCommand(key string, cancel context.CancelFunc) bool {
	c.commandsMu.Lock()
	defer c.commandsMu.Unlock()
	if c.closed {
		return false
	}
	c.commands[key] = cancel
	return true
}

func (c *controlClient) untrackCommand(key string) {
	c.commandsMu.Lock()
	defer c.commandsMu.Unlock()
	delete(c.commands, key)
}

func (c *controlClient) close() {
	c.commandsMu.Lock()
	if c.closed {
		c.commandsMu.Unlock()
		return
	}
	c.closed = true
	cancels := make([]context.CancelFunc, 0, len(c.commands))
	for _, cancel := range c.commands {
		cancels = append(cancels, cancel)
	}
	c.commands = map[string]context.CancelFunc{}
	c.commandsMu.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

func (c *controlClient) runShellCommandAsync(s *muxServer, request controlMessage) {
	commandKey := fmt.Sprintf("%s/%d", request.ID, time.Now().UnixNano())
	go func() {
		output, exitCode, err := c.runShellCommand(s, commandKey, request.Command)
		if err != nil {
			c.sendError(request, err)
			return
		}
		c.send(controlResponse{
			ID:       request.ID,
			Type:     "command_output",
			Status:   "ok",
			Session:  s.session,
			Data:     output,
			ExitCode: exitCode,
		})
	}()
}

func (c *controlClient) runShellCommand(
	s *muxServer,
	commandKey string,
	command string,
) (string, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), runCommandTimeout)
	if !c.trackCommand(commandKey, cancel) {
		cancel()
		return "", 0, errRunCommandClientClosed
	}
	defer c.untrackCommand(commandKey)
	defer cancel()
	return s.runShellCommandContext(ctx, command)
}

func (s *muxServer) broadcast(response controlResponse) {
	s.mu.Lock()
	clients := make([]*controlClient, 0, len(s.controls))
	for client := range s.controls {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	for _, client := range clients {
		client.send(response)
	}
}

func (s *muxServer) broadcastWindowList(eventType string) {
	s.broadcast(controlResponse{
		Type:    eventType,
		Session: s.session,
		Windows: s.snapshots(),
	})
}

func (s *muxServer) snapshots() []windowSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotsLocked()
}

func (s *muxServer) snapshotsLocked() []windowSnapshot {
	windows := make([]windowSnapshot, 0, len(s.windows))
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		windows = append(windows, s.snapshotLocked(window))
	}
	return windows
}

func (s *muxServer) restoreSnapshot() *serverRestore {
	s.mu.Lock()
	defer s.mu.Unlock()

	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows:       make([]restoreWindowState, 0, len(s.windows)),
	}
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		window.refreshProcessMetadataLocked(time.Now())
		state := restoreWindowState{
			ID:                       window.id,
			Index:                    window.index,
			Name:                     window.name,
			Cwd:                      window.cwd,
			CurrentCommand:           window.currentCommandLocked(),
			PanePid:                  window.metadataProcessIDLocked(),
			PaneTitle:                window.paneTitle,
			AgentTool:                window.agentToolLocked(),
			CursorVisible:            window.cursorVisible,
			CursorVisibilityKnown:    window.cursorVisibilityKnown,
			PrivateModes:             copyPrivateModes(window.privateModes),
			InsertModeEnabled:        window.insertModeEnabled,
			InsertModeKnown:          window.insertModeKnown,
			ApplicationKeypadEnabled: window.applicationKeypadEnabled,
			ApplicationKeypadKnown:   window.applicationKeypadKnown,
			Active:                   s.activeID == window.id,
		}
		if isShellRestoreWindow(state) && len(window.history) > 0 {
			state.HistoryBase64 = base64.StdEncoding.EncodeToString(window.historyTailLocked())
		}
		restore.Windows = append(restore.Windows, state)
	}
	return restore
}

func (s *muxServer) snapshot(window *muxWindow) windowSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked(window)
}

func (s *muxServer) snapshotLocked(window *muxWindow) windowSnapshot {
	window.refreshProcessMetadataLocked(time.Now())
	flags := ""
	if window.alert {
		flags = "#"
	}
	return windowSnapshot{
		ID:                        window.id,
		Index:                     window.index,
		Name:                      window.name,
		Active:                    s.activeID == window.id,
		CurrentCommand:            window.currentCommandLocked(),
		CurrentPath:               window.cwd,
		PanePid:                   window.metadataProcessIDLocked(),
		Flags:                     flags,
		PaneTitle:                 window.paneTitle,
		AgentTool:                 window.agentToolLocked(),
		LastActivityEpochSeconds:  window.lastActivity.Unix(),
		TerminalReportsMouseWheel: window.reportsMouseWheelLocked(),
		TerminalMouseReportSgr:    window.privateModes["1006"],
	}
}

func (s *muxServer) runShellCommand(command string) (string, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), runCommandTimeout)
	defer cancel()
	return s.runShellCommandContext(ctx, command)
}

func (s *muxServer) runShellCommandContext(
	ctx context.Context,
	command string,
) (string, int, error) {
	s.mu.Lock()
	cwd := ""
	if window := s.windowByIDLocked(s.activeID); window != nil {
		cwd = window.cwd
	}
	s.mu.Unlock()

	shell := commandShellPath()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	output := newBoundedCommandOutput(runCommandOutputMaxBytes, cancel)
	cmd := exec.Command(shell, "-c", command)
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = inheritedEnvironment(os.Environ())
	cmd.Stdout = output
	cmd.Stderr = output
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return "", 0, err
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	var err error
	select {
	case err = <-waitCh:
	case <-ctx.Done():
		killCommandProcessGroup(cmd)
		err = <-waitCh
	}

	if output.exceeded() {
		return output.String(), 0, errRunCommandOutputLimit
	}
	if ctx.Err() == context.DeadlineExceeded {
		return output.String(), 0, errRunCommandTimeout
	}
	if ctx.Err() == context.Canceled {
		return output.String(), 0, errRunCommandCanceled
	}
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return "", 0, err
		}
	}
	return output.String(), exitCode, nil
}

func commandShellPath() string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	switch filepath.Base(shell) {
	case "sh", "bash", "zsh", "ksh", "dash":
		return shell
	default:
		return "/bin/sh"
	}
}

func killCommandProcessGroup(cmd *exec.Cmd) {
	signalCommandProcessGroup(cmd, syscall.SIGKILL)
}

func signalCommandProcessGroup(cmd *exec.Cmd, signal syscall.Signal) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, signal)
	}
	_ = cmd.Process.Signal(signal)
}

type boundedCommandOutput struct {
	mu        sync.Mutex
	buffer    bytes.Buffer
	limit     int
	cancel    context.CancelFunc
	overLimit bool
}

func newBoundedCommandOutput(
	limit int,
	cancel context.CancelFunc,
) *boundedCommandOutput {
	return &boundedCommandOutput{limit: limit, cancel: cancel}
}

func (o *boundedCommandOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	remaining := o.limit - o.buffer.Len()
	if remaining > 0 {
		if remaining > len(p) {
			remaining = len(p)
		}
		_, _ = o.buffer.Write(p[:remaining])
	}
	exceededNow := len(p) > remaining && !o.overLimit
	if len(p) > remaining {
		o.overLimit = true
	}
	cancel := o.cancel
	o.mu.Unlock()

	if exceededNow && cancel != nil {
		cancel()
	}
	return len(p), nil
}

func (o *boundedCommandOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buffer.String()
}

func (o *boundedCommandOutput) exceeded() bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.overLimit
}

func (s *muxServer) selectWindow(windowID string) error {
	var attach net.Conn
	var replay []byte
	var foregroundProcessGroup int
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	s.activeID = windowID
	window.alert = false
	s.resizeActiveLocked(s.width, s.height)
	attach = s.attachConn
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	s.mu.Unlock()
	s.writeAttachLocked(attach, replay)
	s.attachMu.Unlock()
	s.broadcastWindowList("active_window_changed")
	signalForegroundResize(foregroundProcessGroup)
	return nil
}

func (s *muxServer) closeWindow(windowID string) (bool, error) {
	var attach net.Conn
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var shouldShutdown bool
	var command *exec.Cmd
	var windowPty *os.File
	var snapshots []windowSnapshot

	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false, fmt.Errorf("window %q not found", windowID)
	}
	openCount := 0
	for _, candidate := range s.windows {
		if !candidate.closed {
			openCount++
		}
	}
	if s.activeID == windowID {
		replacement := s.replacementWindowForClosedLocked(window)
		if replacement != nil {
			s.activeID = replacement.id
			replacement.alert = false
			s.resizeActiveLocked(s.width, s.height)
			attach = s.attachConn
			replay = s.replayBytesLocked(replacement)
			foregroundProcessGroup = replacement.foregroundProcessGroupLocked()
			activeChanged = true
		} else {
			s.activeID = ""
		}
	}
	window.closed = true
	window.alert = false
	command = window.cmd
	windowPty = window.pty
	s.reindexWindowsLocked()
	snapshots = s.snapshotsLocked()
	shouldShutdown = openCount <= 1 || len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		s.writeAttachLocked(attach, replay)
	}
	s.attachMu.Unlock()

	s.broadcast(controlResponse{
		Type:    "window_removed",
		Session: s.session,
		Window:  &windowSnapshot{ID: windowID},
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
	if activeChanged {
		s.broadcast(controlResponse{
			Type:    "active_window_changed",
			Session: s.session,
			Windows: snapshots,
		})
		signalForegroundResize(foregroundProcessGroup)
	}
	signalCommandProcessGroup(command, syscall.SIGHUP)
	if windowPty != nil {
		_ = windowPty.Close()
	}
	return shouldShutdown, nil
}

func (s *muxServer) replacementWindowForClosedLocked(closing *muxWindow) *muxWindow {
	for _, candidate := range s.windows {
		if candidate.closed || candidate.id == closing.id {
			continue
		}
		if candidate.index > closing.index {
			return candidate
		}
	}
	for _, candidate := range s.windows {
		if !candidate.closed && candidate.id != closing.id {
			return candidate
		}
	}
	return nil
}

func (s *muxServer) resize(width int, height int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.width = width
	s.height = height
	s.resizeAllLocked(width, height)
}

func (s *muxServer) resizeActiveLocked(width int, height int) {
	window := s.windowByIDLocked(s.activeID)
	s.resizeWindowLocked(window, width, height)
}

func (s *muxServer) resizeAllLocked(width int, height int) {
	for _, window := range s.windows {
		s.resizeWindowLocked(window, width, height)
	}
}

func (s *muxServer) resizeWindowLocked(window *muxWindow, width int, height int) {
	if window == nil || window.closed || window.pty == nil {
		return
	}
	_ = pty.Setsize(window.pty, &pty.Winsize{
		Rows: uint16(height),
		Cols: uint16(width),
	})
}

func (w *muxWindow) foregroundProcessGroupLocked() int {
	pgrp := foregroundProcessGroupForWindow(w)
	if pgrp <= 0 {
		return 0
	}
	w.foregroundPid = pgrp
	return pgrp
}

func (s *muxServer) activeReplayLocked() []byte {
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		return nil
	}
	return s.replayBytesLocked(window)
}

func (s *muxServer) replayBytesLocked(window *muxWindow) []byte {
	history := stripTerminalQueriesFromReplay(window.historyTailLocked())
	if !window.usesFullHistoryForReplayLocked() {
		history = trimReplayHistoryForAttach(history)
	}
	title := terminalTitleReplaySequence(window)
	preModes := terminalModePreReplaySequence(window)
	preHistoryClear := terminalPreHistoryClearSequence(window)
	postModes := terminalModePostReplaySequence(window)
	postParser := []byte(terminalParserResetSequence)
	postCharset := []byte(terminalCharacterSetResetSequence)
	cursor := cursorVisibilityReplaySequence(window.cursorVisibleForReplayLocked())
	replay := make(
		[]byte,
		0,
		len(activeWindowReplayPrefix)+len(title)+len(preModes)+
			len(preHistoryClear)+len(history)+
			len(postParser)+len(postModes)+len(postCharset)+len(cursor),
	)
	replay = append(replay, activeWindowReplayPrefix...)
	replay = append(replay, title...)
	replay = append(replay, preModes...)
	replay = append(replay, preHistoryClear...)
	replay = append(replay, history...)
	replay = append(replay, postParser...)
	replay = append(replay, postModes...)
	replay = append(replay, postCharset...)
	replay = append(replay, cursor...)
	return replay
}

func (w *muxWindow) usesFullHistoryForReplayLocked() bool {
	if w == nil {
		return false
	}
	return w.privateModes["1049"] || w.agentToolLocked() == "antigravity"
}

func (w *muxWindow) reportsMouseWheelLocked() bool {
	if w == nil {
		return false
	}
	return w.privateModes["1000"] ||
		w.privateModes["1002"] ||
		w.privateModes["1003"]
}

func copyPrivateModes(privateModes map[string]bool) map[string]bool {
	if len(privateModes) == 0 {
		return nil
	}
	copied := make(map[string]bool, len(privateModes))
	for mode, enabled := range privateModes {
		if _, ok := trackedPrivateModes[mode]; ok {
			copied[mode] = enabled
		}
	}
	if len(copied) == 0 {
		return nil
	}
	return copied
}

func terminalTitleReplaySequence(window *muxWindow) []byte {
	title := ""
	if window != nil {
		title = firstNonEmptyString(window.paneTitle, window.name)
	}
	title = sanitizeTerminalTitle(title)
	return []byte("\x1b]0;" + title + "\x07\x1b]1;" + title + "\x07\x1b]2;" + title + "\x07")
}

func sanitizeTerminalTitle(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, strings.TrimSpace(value))
}

func terminalModePreReplaySequence(window *muxWindow) []byte {
	if window == nil {
		return nil
	}
	return terminalModeReplaySequence(window, preReplayPrivateModes, true)
}

func terminalPreHistoryClearSequence(window *muxWindow) []byte {
	if window == nil || !window.privateModes["1049"] {
		return nil
	}
	return []byte(terminalScreenClearSequence)
}

func terminalModePostReplaySequence(window *muxWindow) []byte {
	if window == nil {
		return nil
	}
	return terminalModeReplaySequence(window, postReplayPrivateModes, true)
}

func terminalModeReplaySequence(
	window *muxWindow,
	privateModes []string,
	includeApplicationKeypad bool,
) []byte {
	var replay []byte
	for _, mode := range privateModes {
		enabled, ok := window.privateModes[mode]
		if !ok {
			continue
		}
		if mode == "1004" && enabled && !window.focusModeActiveLocked() {
			continue
		}
		final := byte('l')
		if enabled {
			final = 'h'
		}
		replay = append(replay, "\x1b[?"...)
		replay = append(replay, mode...)
		replay = append(replay, final)
	}
	if window.insertModeKnown {
		if window.insertModeEnabled {
			replay = append(replay, "\x1b[4h"...)
		} else {
			replay = append(replay, "\x1b[4l"...)
		}
	}
	if includeApplicationKeypad && window.applicationKeypadKnown {
		if window.applicationKeypadEnabled {
			replay = append(replay, "\x1b="...)
		} else {
			replay = append(replay, "\x1b>"...)
		}
	}
	return replay
}

func (s *muxServer) writeAttach(conn net.Conn, data []byte) {
	if conn == nil || len(data) == 0 {
		return
	}
	s.attachMu.Lock()
	s.writeAttachLocked(conn, data)
	s.attachMu.Unlock()
}

func (s *muxServer) writeAttachLocked(conn net.Conn, data []byte) {
	if conn == nil || len(data) == 0 {
		return
	}
	_, err := conn.Write(data)
	if err != nil {
		s.mu.Lock()
		if s.attachConn == conn {
			s.attachConn = nil
		}
		s.mu.Unlock()
	}
}

func (s *muxServer) writeAttachIfActive(windowID string, conn net.Conn, data []byte) {
	if conn == nil || len(data) == 0 {
		return
	}
	s.attachMu.Lock()
	s.mu.Lock()
	shouldWrite := s.activeID == windowID && s.attachConn == conn
	s.mu.Unlock()
	if shouldWrite {
		s.writeAttachLocked(conn, data)
	}
	s.attachMu.Unlock()
}

func (s *muxServer) writeActive(data []byte) {
	_ = s.writeWindow(s.activeWindowID(), data)
}

func (s *muxServer) writeActiveFromAttach(data []byte) {
	if len(data) == 0 {
		return
	}
	s.mu.Lock()
	windowID := s.activeID
	window := s.windowByIDLocked(windowID)
	stripFocusReports := window == nil || !window.focusModeActiveLocked()
	s.mu.Unlock()
	if stripFocusReports {
		data = stripFocusReportsFromAttachInput(data)
		if len(data) == 0 {
			return
		}
	}
	_ = s.writeWindow(windowID, data)
}

func (s *muxServer) sendThemeHint(data string) bool {
	themeHint := themeHintDataFromString(data)
	var themeHintData []byte
	s.mu.Lock()
	if len(themeHint) > 0 {
		s.themeHint = append(s.themeHint[:0], themeHint...)
	}
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return false
	}
	window.refreshProcessMetadataLocked(time.Now())
	if len(themeHint) > 0 {
		themeHintData = themeHintResponsesForKeys(
			themeHint,
			window.themeHintRefreshKeysLocked(),
		)
	}
	sendFocusTransition := window.themeHintFocusTransitionLocked()
	if len(themeHintData) == 0 && !sendFocusTransition {
		s.mu.Unlock()
		return false
	}
	windowID := window.id
	s.mu.Unlock()

	if len(themeHintData) > 0 {
		if err := s.writeWindow(windowID, themeHintData); err != nil {
			return false
		}
	}
	if sendFocusTransition {
		s.sendFocusTransition(windowID)
	}
	return true
}

func themeHintDataFromString(data string) []byte {
	data = strings.TrimSpace(data)
	if data == "" || len(data) > themeHintLimitBytes {
		return nil
	}
	return []byte(data)
}

func (s *muxServer) sendFocusTransition(windowID string) {
	go func() {
		_ = s.writeWindow(windowID, []byte("\x1b[O"))
		time.Sleep(50 * time.Millisecond)
		_ = s.writeWindow(windowID, []byte("\x1b[I"))
	}()
}

func (s *muxServer) writeWindow(windowID string, data []byte) error {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	s.mu.Unlock()
	if window == nil || window.closed {
		return fmt.Errorf("window %q not found", windowID)
	}
	_, err := window.pty.Write(data)
	return err
}

func (s *muxServer) activeWindow() *muxWindow {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.windowByIDLocked(s.activeID)
}

func (s *muxServer) activeWindowID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.activeID
}

func (s *muxServer) windowIDForIndex(index int) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, window := range s.windows {
		if !window.closed && window.index == index {
			return window.id
		}
	}
	return ""
}

func (s *muxServer) windowByIDLocked(windowID string) *muxWindow {
	for _, window := range s.windows {
		if window.id == windowID {
			return window
		}
	}
	return nil
}

func (w *muxWindow) appendHistoryLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	if len(chunk) >= windowHistoryLimitBytes {
		w.history = append(
			w.history[:0],
			chunk[len(chunk)-windowHistoryLimitBytes:]...,
		)
		return
	}
	// Grow the underlying buffer to 2x the limit so trims are amortized:
	// each byte gets shifted at most once before falling out of history.
	if cap(w.history) < 2*windowHistoryLimitBytes {
		grown := make([]byte, len(w.history), 2*windowHistoryLimitBytes)
		copy(grown, w.history)
		w.history = grown
	}
	w.history = append(w.history, chunk...)
	if len(w.history) > 2*windowHistoryLimitBytes {
		// copy() handles the overlap correctly because src is after dst.
		n := copy(w.history, w.history[len(w.history)-windowHistoryLimitBytes:])
		w.history = w.history[:n]
	}
}

func (w *muxWindow) historyTailLocked() []byte {
	if len(w.history) <= windowHistoryLimitBytes {
		return w.history
	}
	start := len(w.history) - windowHistoryLimitBytes
	start = advanceToUtf8Boundary(w.history, start)
	return w.history[start:]
}

func trimReplayHistoryForAttach(history []byte) []byte {
	if len(history) <= windowReplayLimitBytes {
		return history
	}
	start := len(history) - windowReplayLimitBytes
	scanEnd := start + 2048
	if scanEnd > len(history) {
		scanEnd = len(history)
	}
	for i := start; i < scanEnd; i++ {
		switch history[i] {
		case '\x1b', '\n', '\r':
			return history[i:]
		}
	}
	start = advanceToUtf8Boundary(history, start)
	return history[start:]
}

// advanceToUtf8Boundary moves start forward past any UTF-8 continuation bytes
// (0b10xxxxxx) so the returned slice begins on a valid UTF-8 starter. This
// prevents replay payloads from beginning in the middle of a multi-byte
// character, which would force strict UTF-8 decoders (such as Dart's
// default Utf8Decoder) to throw and drop the chunk that contained the next
// redraw frame.
func advanceToUtf8Boundary(data []byte, start int) int {
	if start < 0 {
		start = 0
	}
	limit := start + 4
	if limit > len(data) {
		limit = len(data)
	}
	for start < limit && data[start]&0xC0 == 0x80 {
		start++
	}
	return start
}

func stripFocusReportsFromAttachInput(data []byte) []byte {
	if len(data) < 3 || !bytes.Contains(data, []byte("\x1b[")) {
		return data
	}
	var output []byte
	copyStart := 0
	for i := 0; i+2 < len(data); i++ {
		if data[i] != '\x1b' || data[i+1] != '[' ||
			(data[i+2] != 'I' && data[i+2] != 'O') {
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-3)
		}
		output = append(output, data[copyStart:i]...)
		copyStart = i + 3
		i += 2
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func containsTerminalBell(data []byte) bool {
	return bytes.IndexByte(data, '\a') >= 0
}

// stripLocallyAnsweredThemeQueries removes OSC 10/11/12/17/19 background-color
// queries and OSC 4 palette queries from chunk when MonkeyMux can answer them
// locally from hint. The daemon already writes the cached responses directly
// to the window PTY in handleWindowOutput, so forwarding the same queries to
// the SSH client would produce a duplicate reply. That duplicate would travel
// back through the attach socket as keyboard input and surface inside the
// active TUI as literal text (the user-visible "spew" bug). Queries we cannot
// answer (no cached response for every queried key) are left in place so the
// client can still reply.
func stripLocallyAnsweredThemeQueries(chunk []byte, hint []byte) []byte {
	window := &muxWindow{}
	output := window.stripLocallyAnsweredThemeQueriesLocked(chunk, hint)
	if len(window.attachOscBuffer) == 0 {
		return output
	}
	output = append(output, window.attachOscBuffer...)
	return output
}

func (w *muxWindow) stripLocallyAnsweredThemeQueriesLocked(chunk []byte, hint []byte) []byte {
	if len(chunk) == 0 && len(w.attachOscBuffer) == 0 {
		return chunk
	}
	data := chunk
	if len(w.attachOscBuffer) > 0 {
		combined := make([]byte, 0, len(w.attachOscBuffer)+len(chunk))
		combined = append(combined, w.attachOscBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.attachOscBuffer = nil
	}

	var responses map[string][]byte
	answerable := func(queryKeys []string) bool {
		if len(queryKeys) == 0 || len(hint) == 0 {
			return false
		}
		if responses == nil {
			responses = themeHintResponseMap(hint)
			if len(responses) == 0 {
				return false
			}
		}
		for _, key := range queryKeys {
			if len(responses[key]) == 0 {
				return false
			}
		}
		return true
	}

	var output []byte
	copyStart := 0
	for i := 0; i < len(data); {
		if data[i] != '\x1b' {
			i++
			continue
		}
		if i+1 >= len(data) {
			if w.storeAttachPartialOscLocked(data[i:]) {
				if output == nil {
					return data[:i]
				}
				output = append(output, data[copyStart:i]...)
				return output
			}
			break
		}
		if data[i+1] != ']' {
			i++
			continue
		}
		payloadStart := i + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			if w.storeAttachPartialOscLocked(data[i:]) {
				if output == nil {
					return data[:i]
				}
				output = append(output, data[copyStart:i]...)
				return output
			}
			break
		}
		sequenceEnd := payloadStart + payloadEnd + terminatorLength
		payload := data[payloadStart : payloadStart+payloadEnd]
		queryKeys := themeQueryKeysFromOscPayload(string(payload))
		if !answerable(queryKeys) {
			i = sequenceEnd
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-(sequenceEnd-i))
		}
		output = append(output, data[copyStart:i]...)
		copyStart = sequenceEnd
		i = sequenceEnd
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func (w *muxWindow) storeAttachPartialOscLocked(data []byte) bool {
	if len(data) > oscBufferLimitBytes {
		w.attachOscBuffer = nil
		return false
	}
	w.attachOscBuffer = append(w.attachOscBuffer[:0], data...)
	return true
}

func stripTerminalQueriesFromReplay(data []byte) []byte {
	if len(data) == 0 {
		return data
	}

	var output []byte
	copyStart := 0
	for i := 0; i < len(data); {
		if data[i] != '\x1b' || i+1 >= len(data) {
			i++
			continue
		}
		next := data[i+1]
		stripEnd := -1
		if next == '[' {
			end := csiSequenceEnd(data, i+2)
			if end < 0 {
				break
			}
			sequence := data[i : end+1]
			if isReplayUnsafeCsiQuery(sequence) {
				stripEnd = end + 1
			}
		} else if next == ']' {
			end, terminatorLength, ok := findOscTerminator(data[i+2:])
			if !ok {
				break
			}
			payload := data[i+2 : i+2+end]
			if isReplayUnsafeOscQuery(payload) {
				stripEnd = i + 2 + end + terminatorLength
			}
		}
		if stripEnd < 0 {
			i++
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-(stripEnd-i))
		}
		output = append(output, data[copyStart:i]...)
		copyStart = stripEnd
		i = stripEnd
	}
	if output == nil {
		return data
	}
	output = append(output, data[copyStart:]...)
	return output
}

func csiSequenceEnd(data []byte, start int) int {
	for i := start; i < len(data); i++ {
		if data[i] >= 0x40 && data[i] <= 0x7e {
			return i
		}
	}
	return -1
}

func isReplayUnsafeCsiQuery(sequence []byte) bool {
	if len(sequence) < 3 || sequence[0] != '\x1b' || sequence[1] != '[' {
		return false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[2 : len(sequence)-1])
	switch final {
	case 'c':
		return params == "" ||
			params == "0" ||
			strings.HasPrefix(params, "?") ||
			strings.HasPrefix(params, ">")
	case 'n':
		return params == "5" ||
			params == "6" ||
			params == "?6" ||
			params == "?15" ||
			params == "?25" ||
			params == "?26" ||
			params == "?53"
	default:
		return false
	}
}

func isReplayUnsafeOscQuery(payload []byte) bool {
	code, value, ok := strings.Cut(string(payload), ";")
	if !ok || !strings.Contains(value, "?") {
		return false
	}
	switch code {
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19":
		return true
	default:
		return false
	}
}

func (w *muxWindow) processID() int {
	if w == nil || w.cmd == nil || w.cmd.Process == nil {
		return 0
	}
	return w.cmd.Process.Pid
}

func (w *muxWindow) metadataProcessIDLocked() int {
	if w.foregroundPid > 0 {
		return w.foregroundPid
	}
	return w.processID()
}

func (w *muxWindow) currentCommandLocked() string {
	if strings.TrimSpace(w.foregroundCommand) != "" {
		return w.foregroundCommand
	}
	return w.command
}

func (w *muxWindow) agentToolLocked() string {
	if tool := agentToolFromCommandName(w.currentCommandLocked()); tool != "" {
		return tool
	}
	if tool := strings.TrimSpace(w.agentTool); tool != "" {
		return tool
	}
	if tool := agentToolFromTerminalTitle(w.paneTitle); tool != "" {
		return tool
	}
	return agentToolFromCommandName(w.name)
}

func (w *muxWindow) broadcastIdentityLocked() windowBroadcastIdentity {
	return windowBroadcastIdentity{
		name:      w.name,
		cwd:       w.cwd,
		command:   w.currentCommandLocked(),
		paneTitle: w.paneTitle,
		agentTool: w.agentToolLocked(),
		panePid:   w.metadataProcessIDLocked(),
		alert:     w.alert,
	}
}

func (w *muxWindow) refreshProcessMetadataLocked(now time.Time) {
	if w == nil || w.pty == nil {
		return
	}
	if !w.lastProcessMetadataRefresh.IsZero() &&
		now.Sub(w.lastProcessMetadataRefresh) < processMetadataInterval {
		return
	}
	w.lastProcessMetadataRefresh = now

	pgrp := w.foregroundProcessGroupLocked()
	if command := commandNameForProcessGroup(pgrp); command != "" {
		w.foregroundCommand = command
	}
}

func (w *muxWindow) supportsThemeHintLocked() bool {
	return w.themeHintFocusTransitionLocked() || len(w.themeHintRefreshKeysLocked()) > 0
}

// themeHintRefreshKeysLocked returns the OSC theme-query keys the daemon
// should re-answer when refreshing the cached theme hint.
//
// Do not infer safety from a previous OSC color query alone: many TUIs
// query OSC 10/11 once at startup, react to the first response, and then
// never expect another one. Any follow-up push (every reconnect, every
// brightness change, every app-resume) surfaces as literal `]11;rgb:...`
// text in their input composer (observed with Nous Hermes, Codex, and
// Claude Code). Synthetic focus-out/focus-in transitions can cause the
// same kind of prompt/composer pollution.
//
// DEC private mode 2031 is the opt-in signal for color-scheme update
// reports. Only windows that currently have that mode enabled get
// refreshed replies for previously observed color queries, or a repaint
// nudge when the client theme changes.
//
// The contractually-correct live-query response path in
// handleWindowOutput still answers OSC 10/11/4/17/19 queries the
// foreground process actually emits. Other programs that truly need the
// latest theme can re-query on SIGWINCH or real focus changes.
func (w *muxWindow) themeHintRefreshKeysLocked() []string {
	if !w.themeRefreshModeActiveLocked() {
		return nil
	}
	return w.activeThemeColorQueryKeysLocked()
}

func (w *muxWindow) themeHintFocusTransitionLocked() bool {
	return w.themeRefreshModeActiveLocked() && w.focusModeActiveLocked()
}

func (w *muxWindow) themeRefreshModeActiveLocked() bool {
	if w == nil || !w.privateModes["2031"] {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.themeRefreshModeProcessID <= 0 ||
		activePid <= 0 ||
		w.themeRefreshModeProcessID == activePid
}

func (w *muxWindow) activeThemeColorQueryKeysLocked() []string {
	activePid := w.activeForegroundPidLocked()
	if w.themeColorQueryPid <= 0 ||
		activePid <= 0 ||
		w.themeColorQueryPid != activePid ||
		len(w.themeColorQueryKeys) == 0 {
		return nil
	}
	keys := make([]string, 0, len(w.themeColorQueryKeys))
	for key := range w.themeColorQueryKeys {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (w *muxWindow) activeForegroundPidLocked() int {
	if w.pty == nil {
		return w.metadataProcessIDLocked()
	}
	return w.foregroundProcessGroupLocked()
}

func (w *muxWindow) focusModeActiveLocked() bool {
	if w == nil || !w.focusModeEnabled {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.focusModeProcessID <= 0 ||
		activePid <= 0 ||
		w.focusModeProcessID == activePid
}

func commandNameForProcessGroup(pgrp int) string {
	if pgrp <= 0 {
		return ""
	}
	directCommand := commandNameForPID(pgrp)
	if directCommand != "" &&
		!isGenericRuntimeCommandName(directCommand) &&
		!isShellCommandName(directCommand) {
		return directCommand
	}

	fallback := directCommand
	if agentToolFromCommandName(fallback) != "" {
		return fallback
	}

	processes := cachedProcessTable(time.Now())
	if len(processes) == 0 {
		return fallback
	}
	for _, process := range processes {
		if process.pgid != pgrp {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if command == "" {
			continue
		}
		if agentToolFromCommandName(command) != "" {
			return command
		}
		if process.pid == pgrp && !isGenericRuntimeCommandName(command) {
			return command
		}
		if fallback == "" ||
			(!isShellCommandName(command) &&
				!isGenericRuntimeCommandName(command)) {
			fallback = command
		}
	}
	return fallback
}

func commandNameForPID(pid int) string {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=", "-o", "args=").Output()
	if err == nil && ctx.Err() == nil {
		for _, line := range strings.Split(string(output), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			if command := commandNameFromProcessFields(fields[0], strings.Join(fields[1:], " ")); command != "" {
				return command
			}
		}
	}

	ctx, cancel = context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err = exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if err != nil || ctx.Err() != nil {
		return ""
	}
	return cleanProcessCommandName(string(output))
}

func commandNameFromProcessFields(command string, args string) string {
	if agentCommand := agentCommandNameFromProcessArgs(args); agentCommand != "" {
		return agentCommand
	}
	if command := cleanProcessCommandName(command); command != "" {
		return command
	}
	return cleanProcessCommandName(args)
}

func cleanProcessCommandName(value string) string {
	for _, line := range strings.Split(value, "\n") {
		command := strings.TrimSpace(line)
		if command == "" {
			continue
		}
		command = strings.Fields(command)[0]
		command = strings.Trim(command, `"'`)
		command = filepath.Base(command)
		command = strings.TrimSuffix(command, ".exe")
		command = strings.TrimSuffix(command, ".js")
		return command
	}
	return ""
}

func agentCommandNameFromProcessArgs(args string) string {
	trimmed := strings.TrimSpace(args)
	if trimmed == "" {
		return ""
	}
	for _, token := range strings.Fields(trimmed) {
		command := cleanProcessCommandName(token)
		if agentToolFromCommandName(command) != "" {
			return canonicalAgentCommandName(command)
		}
	}

	lowered := strings.ToLower(trimmed)
	switch {
	case strings.Contains(lowered, "@google/gemini-cli") ||
		strings.Contains(lowered, "/gemini-cli/") ||
		strings.Contains(lowered, "/gemini.js"):
		return "gemini"
	case strings.Contains(lowered, "@openai/codex") ||
		strings.Contains(lowered, "/codex/bin/codex") ||
		strings.Contains(lowered, "/codex.js"):
		return "codex"
	case strings.Contains(lowered, "@anthropic-ai/claude-code") ||
		strings.Contains(lowered, "/claude-code/"):
		return "claude"
	default:
		return ""
	}
}

func agentToolFromCommandText(command string) string {
	return firstNonEmptyString(
		agentToolFromCommandName(commandNameFromShellCommand(command)),
		agentToolFromCommandName(agentCommandNameFromProcessArgs(command)),
	)
}

func agentToolFromCommandName(command string) string {
	normalized := strings.ToLower(cleanProcessCommandName(command))
	switch normalized {
	case "claude", "claude-code":
		return "claude"
	case "copilot", "github-copilot":
		return "copilot"
	case "codex", "codex-cli":
		return "codex"
	case "opencode", "open-code":
		return "opencode"
	case "gemini", "gemini-cli":
		return "gemini"
	case "agy", "antigravity", "antigravity-cli":
		return "antigravity"
	default:
		return ""
	}
}

func agentLaunchCommand(tool string, startInYoloMode bool) string {
	switch tool {
	case "claude":
		if startInYoloMode {
			return "claude --dangerously-skip-permissions"
		}
		return "claude"
	case "copilot":
		if startInYoloMode {
			return "copilot --yolo"
		}
		return "copilot"
	case "codex":
		if startInYoloMode {
			return "codex --yolo"
		}
		return "codex"
	case "opencode":
		if startInYoloMode {
			return "OPENCODE_PERMISSION=" + shellQuote(`{"*":"allow"}`) + " opencode"
		}
		return "opencode"
	case "gemini":
		if startInYoloMode {
			return "gemini --yolo"
		}
		return "gemini"
	case "antigravity":
		if startInYoloMode {
			return "agy --dangerously-skip-permissions"
		}
		return "agy"
	default:
		return ""
	}
}

func agentResumeCommand(tool string, sessionID string, startInYoloMode bool) string {
	quotedSessionID := shellQuote(sessionID)
	switch tool {
	case "claude":
		if startInYoloMode {
			return "claude --dangerously-skip-permissions --resume " + quotedSessionID
		}
		return "claude --resume " + quotedSessionID
	case "copilot":
		if startInYoloMode {
			return "copilot --yolo --resume " + quotedSessionID
		}
		return "copilot --resume " + quotedSessionID
	case "codex":
		if startInYoloMode {
			return "codex --yolo resume " + quotedSessionID
		}
		return "codex resume " + quotedSessionID
	case "opencode":
		commandPrefix := ""
		if startInYoloMode {
			commandPrefix = "OPENCODE_PERMISSION=" + shellQuote(`{"*":"allow"}`) + " "
		}
		if sessionID == "_continue" {
			return commandPrefix + "opencode --continue"
		}
		return commandPrefix + "opencode --session " + quotedSessionID
	case "gemini":
		if startInYoloMode {
			return "gemini --yolo --resume " + quotedSessionID
		}
		return "gemini --resume " + quotedSessionID
	case "antigravity":
		commandPrefix := ""
		if startInYoloMode {
			commandPrefix = "agy --dangerously-skip-permissions "
		} else {
			commandPrefix = "agy "
		}
		if sessionID == "_continue" {
			return commandPrefix + "--continue"
		}
		return commandPrefix + "--conversation " + quotedSessionID
	default:
		return ""
	}
}

func canonicalAgentCommandName(command string) string {
	return firstNonEmptyString(agentToolFromCommandName(command), cleanProcessCommandName(command))
}

func agentToolFromTerminalTitle(title string) string {
	normalized := strings.ToLower(strings.Join(strings.Fields(title), " "))
	normalized = strings.Trim(normalized, "·-: ")
	switch {
	case normalized == "claude" || normalized == "claude code" ||
		strings.HasPrefix(normalized, "claude code "):
		return "claude"
	case normalized == "copilot" || normalized == "copilot cli" ||
		strings.HasPrefix(normalized, "copilot cli "):
		return "copilot"
	case normalized == "codex" || strings.HasPrefix(normalized, "codex "):
		return "codex"
	case normalized == "opencode" || normalized == "open code" ||
		strings.HasPrefix(normalized, "opencode "):
		return "opencode"
	case normalized == "gemini" || normalized == "gemini cli" ||
		strings.HasPrefix(normalized, "gemini cli "):
		return "gemini"
	case normalized == "agy" || normalized == "antigravity" ||
		strings.HasPrefix(normalized, "agy ") || strings.HasPrefix(normalized, "antigravity "):
		return "antigravity"
	default:
		return ""
	}
}

func isGenericRuntimeCommandName(command string) bool {
	switch strings.ToLower(cleanProcessCommandName(command)) {
	case "node", "nodejs", "npm", "npx", "bun", "deno", "python", "python3":
		return true
	default:
		return false
	}
}

func isShellCommandName(command string) bool {
	switch strings.ToLower(cleanProcessCommandName(command)) {
	case "sh", "bash", "zsh", "fish", "dash", "ksh":
		return true
	default:
		return false
	}
}

func commandNameFromShellCommand(command string) string {
	normalized := strings.TrimSpace(command)
	for normalized != "" {
		if match := leadingCdCommandPattern.FindStringIndex(normalized); match != nil && match[0] == 0 {
			normalized = strings.TrimSpace(normalized[match[1]:])
			continue
		}
		if match := leadingEnvPattern.FindStringIndex(normalized); match != nil && match[0] == 0 {
			normalized = strings.TrimSpace(normalized[match[1]:])
			continue
		}
		break
	}
	token := leadingShellToken(normalized)
	if token == "" {
		return ""
	}
	return cleanProcessCommandName(token)
}

func leadingShellToken(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	if quote := trimmed[0]; quote == '\'' || quote == '"' {
		if end := strings.IndexByte(trimmed[1:], quote); end >= 0 {
			return trimmed[1 : end+1]
		}
	}
	fields := strings.Fields(trimmed)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

func (w *muxWindow) observeTerminalModesLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	data := chunk
	if len(w.csiBuffer) > 0 {
		combined := make([]byte, 0, len(w.csiBuffer)+len(chunk))
		combined = append(combined, w.csiBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.csiBuffer = nil
	}

	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return
		}
		if escapeIndex+1 >= len(data) {
			w.storePartialCsiLocked(data[escapeIndex:])
			return
		}
		switch data[escapeIndex+1] {
		case '[':
		case '=':
			w.applicationKeypadEnabled = true
			w.applicationKeypadKnown = true
			data = data[escapeIndex+2:]
			continue
		case '>':
			w.applicationKeypadEnabled = false
			w.applicationKeypadKnown = true
			data = data[escapeIndex+2:]
			continue
		default:
			data = data[escapeIndex+1:]
			continue
		}

		end := csiSequenceEnd(data, escapeIndex+2)
		if end < 0 {
			w.storePartialCsiLocked(data[escapeIndex:])
			return
		}
		final := data[end]
		if final == 'h' || final == 'l' {
			params := string(data[escapeIndex+2 : end])
			enabled := final == 'h'
			if strings.HasPrefix(params, "?") {
				for _, mode := range csiModeParams(strings.TrimPrefix(params, "?")) {
					w.setPrivateModeLocked(mode, enabled)
				}
			} else {
				for _, mode := range csiModeParams(params) {
					if mode == "4" {
						w.insertModeEnabled = enabled
						w.insertModeKnown = true
					}
				}
			}
		}
		data = data[end+1:]
	}
}

func (w *muxWindow) storePartialCsiLocked(data []byte) {
	if len(data) > csiBufferLimitBytes {
		w.csiBuffer = nil
		return
	}
	w.csiBuffer = append(w.csiBuffer[:0], data...)
}

func (w *muxWindow) setPrivateModeLocked(mode string, enabled bool) {
	if mode == "25" {
		w.cursorVisible = enabled
		w.cursorVisibilityKnown = true
		return
	}
	if mode == "1004" {
		w.focusModeEnabled = enabled
		if enabled {
			w.focusModeProcessID = w.activeForegroundPidLocked()
		} else {
			w.focusModeProcessID = 0
		}
	}
	if mode == "2031" {
		if enabled {
			w.themeRefreshModeProcessID = w.activeForegroundPidLocked()
		} else {
			w.themeRefreshModeProcessID = 0
		}
	}
	if _, ok := trackedPrivateModes[mode]; !ok {
		return
	}
	if w.privateModes == nil {
		w.privateModes = map[string]bool{}
	}
	w.privateModes[mode] = enabled
}

func csiModeParams(params string) []string {
	if params == "" {
		return nil
	}
	parts := strings.Split(params, ";")
	modes := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		mode, _, _ := strings.Cut(part, ":")
		if mode != "" {
			modes = append(modes, mode)
		}
	}
	return modes
}

func (w *muxWindow) cursorVisibleForReplayLocked() bool {
	return !w.cursorVisibilityKnown || w.cursorVisible
}

func cursorVisibilityReplaySequence(visible bool) string {
	if visible {
		return "\x1b[?25h"
	}
	return "\x1b[?25l"
}

func (w *muxWindow) observeTerminalMetadataLocked(chunk []byte) []string {
	if len(chunk) == 0 {
		return nil
	}
	data := chunk
	if len(w.oscBuffer) > 0 {
		combined := make([]byte, 0, len(w.oscBuffer)+len(chunk))
		combined = append(combined, w.oscBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.oscBuffer = nil
	}

	var observedThemeQueries []string
	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return observedThemeQueries
		}
		if escapeIndex+1 >= len(data) {
			w.storePartialOscLocked(data[escapeIndex:])
			return observedThemeQueries
		}
		if data[escapeIndex+1] != ']' {
			data = data[escapeIndex+1:]
			continue
		}

		payloadStart := escapeIndex + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			w.storePartialOscLocked(data[escapeIndex:])
			return observedThemeQueries
		}
		observedThemeQueries = appendThemeQueryKeys(
			observedThemeQueries,
			w.applyOscPayloadLocked(
				string(data[payloadStart:payloadStart+payloadEnd]),
			),
		)
		data = data[payloadStart+payloadEnd+terminatorLength:]
	}
	return observedThemeQueries
}

func findOscTerminator(data []byte) (payloadEnd int, terminatorLength int, ok bool) {
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '\a':
			return i, 1, true
		case '\x1b':
			if i+1 >= len(data) {
				return 0, 0, false
			}
			if data[i+1] == '\\' {
				return i, 2, true
			}
		}
	}
	return 0, 0, false
}

func (w *muxWindow) storePartialOscLocked(data []byte) {
	if len(data) > oscBufferLimitBytes {
		w.oscBuffer = nil
		return
	}
	w.oscBuffer = append(w.oscBuffer[:0], data...)
}

func (w *muxWindow) applyOscPayloadLocked(payload string) []string {
	code, value, ok := strings.Cut(payload, ";")
	if !ok {
		return nil
	}
	switch code {
	case "0", "1", "2":
		title := cleanTerminalTitle(value)
		if title == "" {
			return nil
		}
		w.paneTitle = title
	case "7":
		path := pathFromOsc7(value)
		if path != "" {
			w.cwd = path
		}
	}
	queryKeys := themeQueryKeysFromOscPayload(payload)
	if len(queryKeys) == 0 {
		return nil
	}
	queryPid := w.activeForegroundPidLocked()
	if queryPid <= 0 {
		return nil
	}
	if w.themeColorQueryPid != queryPid {
		w.themeColorQueryKeys = nil
	}
	w.themeColorQueryPid = queryPid
	if w.themeColorQueryKeys == nil {
		w.themeColorQueryKeys = map[string]bool{}
	}
	for _, key := range queryKeys {
		w.themeColorQueryKeys[key] = true
	}
	return queryKeys
}

func appendThemeQueryKeys(existing []string, keys []string) []string {
	if len(keys) == 0 {
		return existing
	}
	seen := make(map[string]bool, len(existing)+len(keys))
	for _, key := range existing {
		seen[key] = true
	}
	for _, key := range keys {
		if seen[key] {
			continue
		}
		seen[key] = true
		existing = append(existing, key)
	}
	return existing
}

func themeQueryKeysFromOscPayload(payload string) []string {
	parts := strings.Split(payload, ";")
	if len(parts) < 2 {
		return nil
	}
	code := strings.TrimSpace(parts[0])
	args := parts[1:]
	switch code {
	case "4":
		return paletteThemeQueryKeys(args)
	case "10", "11", "12", "17", "19":
		if strings.TrimSpace(args[0]) == "?" {
			return []string{code}
		}
	}
	return nil
}

func paletteThemeQueryKeys(args []string) []string {
	var keys []string
	for i := 0; i+1 < len(args); i += 2 {
		if strings.TrimSpace(args[i+1]) != "?" {
			continue
		}
		index, err := strconv.Atoi(strings.TrimSpace(args[i]))
		if err != nil || index < 0 || index > 255 {
			continue
		}
		keys = append(keys, fmt.Sprintf("4;%d", index))
	}
	return keys
}

func themeHintResponsesForKeys(hint []byte, keys []string) []byte {
	if len(hint) == 0 || len(keys) == 0 {
		return nil
	}
	responses := themeHintResponseMap(hint)
	if len(responses) == 0 {
		return nil
	}
	var output []byte
	seen := make(map[string]bool, len(keys))
	for _, key := range keys {
		if seen[key] {
			continue
		}
		seen[key] = true
		response := responses[key]
		if len(response) == 0 {
			continue
		}
		output = append(output, response...)
	}
	return output
}

func themeHintResponseMap(hint []byte) map[string][]byte {
	responses := map[string][]byte{}
	data := hint
	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return responses
		}
		if escapeIndex+1 >= len(data) {
			return responses
		}
		if data[escapeIndex+1] != ']' {
			data = data[escapeIndex+1:]
			continue
		}

		payloadStart := escapeIndex + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return responses
		}
		sequenceEnd := payloadStart + payloadEnd + terminatorLength
		key := themeResponseKeyFromOscPayload(
			string(data[payloadStart : payloadStart+payloadEnd]),
		)
		if key != "" {
			responses[key] = append([]byte(nil), data[escapeIndex:sequenceEnd]...)
		}
		data = data[sequenceEnd:]
	}
	return responses
}

func themeResponseKeyFromOscPayload(payload string) string {
	parts := strings.Split(payload, ";")
	if len(parts) < 2 {
		return ""
	}
	code := strings.TrimSpace(parts[0])
	switch code {
	case "4":
		if len(parts) < 3 {
			return ""
		}
		index, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || index < 0 || index > 255 {
			return ""
		}
		return fmt.Sprintf("4;%d", index)
	case "10", "11", "12", "17", "19":
		if strings.TrimSpace(parts[1]) == "?" {
			return ""
		}
		return code
	}
	return ""
}

func cleanTerminalTitle(value string) string {
	title := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	title = strings.Join(strings.Fields(title), " ")
	if len(title) <= maxTitleBytes {
		return title
	}
	for i := range title {
		if i > maxTitleBytes {
			return title[:i]
		}
	}
	return title
}

func pathFromOsc7(value string) string {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "file" {
		return ""
	}
	path, err := url.PathUnescape(parsed.Path)
	if err != nil || !strings.HasPrefix(path, "/") {
		return ""
	}
	return path
}

func (s *muxServer) clearAlertsLocked(activeID string) {
	for _, window := range s.windows {
		if window.id == activeID {
			window.alert = false
		}
	}
}

func (s *muxServer) reindexWindowsLocked() {
	index := 0
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		window.index = index
		index++
	}
}

func (s *muxServer) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	listener := s.listener
	s.listener = nil
	attach := s.attachConn
	s.attachConn = nil
	controls := make([]*controlClient, 0, len(s.controls))
	for control := range s.controls {
		controls = append(controls, control)
	}
	windows := append([]*muxWindow(nil), s.windows...)
	s.mu.Unlock()

	if listener != nil {
		_ = listener.Close()
	}
	if attach != nil {
		_ = attach.Close()
	}
	for _, control := range controls {
		_ = control.conn.Close()
	}
	for _, window := range windows {
		signalCommandProcessGroup(window.cmd, syscall.SIGHUP)
		if window.pty != nil {
			_ = window.pty.Close()
		}
	}
}

func (s *muxServer) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

type runningServerStatus struct {
	version      string
	capabilities []string
}

func (s runningServerStatus) displayVersion() string {
	if strings.TrimSpace(s.version) == "" {
		return "unknown"
	}
	return s.version
}

func (s runningServerStatus) supportsCapability(capability string) bool {
	for _, value := range s.capabilities {
		if value == capability {
			return true
		}
	}
	return false
}

func promptForServerUpdate(
	reader io.Reader,
	writer io.Writer,
	session string,
	status runningServerStatus,
) bool {
	fmt.Fprintf(
		writer,
		"\r\nMonkeyMux session %q is running with helper %s; this app includes helper %s.\r\n",
		session,
		status.displayVersion(),
		monkeyMuxVersion,
	)
	if status.supportsCapability("shutdown") {
		fmt.Fprint(
			writer,
			"Update now? MonkeyMux will try to restore existing windows in the new helper. [y/N] ",
		)
	} else {
		fmt.Fprint(
			writer,
			"Update now? This old helper cannot close itself; MonkeyMux will try to restore windows but may abandon the old ones. [y/N] ",
		)
	}
	answer, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil {
		fmt.Fprint(writer, "\r\nmonkeymux: update skipped; continuing existing session.\r\n")
		return false
	}
	answer = strings.ToLower(strings.TrimSpace(answer))
	if answer == "y" || answer == "yes" {
		return true
	}
	fmt.Fprint(writer, "monkeymux: update skipped; continuing existing session.\r\n")
	return false
}

func shouldUpdateRunningServer(
	reader io.Reader,
	writer io.Writer,
	session string,
	status runningServerStatus,
	updatePolicy string,
) bool {
	switch updatePolicy {
	case serverUpdatePolicyNever:
		return false
	case serverUpdatePolicyAlways:
		return true
	default:
		return promptForServerUpdate(reader, writer, session, status)
	}
}

func normalizeServerUpdatePolicy(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", serverUpdatePolicyPrompt:
		return serverUpdatePolicyPrompt, nil
	case serverUpdatePolicyNever:
		return serverUpdatePolicyNever, nil
	case serverUpdatePolicyAlways:
		return serverUpdatePolicyAlways, nil
	default:
		return "", fmt.Errorf("invalid update policy %q", value)
	}
}

func queryRunningServerStatus(session string) (runningServerStatus, error) {
	conn, err := dialSession(session)
	if err != nil {
		return runningServerStatus{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return runningServerStatus{}, err
	}
	var hello controlResponse
	if err := dec.Decode(&hello); err != nil {
		return runningServerStatus{}, err
	}
	return runningServerStatus{
		version:      hello.Version,
		capabilities: hello.Capabilities,
	}, nil
}

func requestServerShutdown(session string) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return
	}
	var ignored controlResponse
	if err := dec.Decode(&ignored); err != nil {
		return
	}
	_ = enc.Encode(controlMessage{
		ID:      strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:    "shutdown",
		Session: session,
	})
}

func waitForServerExit(session string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := dialSession(session)
		if err != nil {
			return true
		}
		_ = conn.Close()
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func defaultShellPath() string {
	shell := os.Getenv("SHELL")
	if strings.TrimSpace(shell) == "" {
		return "/bin/sh"
	}
	return shell
}

func shellCommand(shell string) *exec.Cmd {
	cmd := exec.Command(shell)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

func shellCommandForScript(shell string, command string) *exec.Cmd {
	cmd := exec.Command(shell, "-i", "-c", command)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

func inheritedEnvironment(base []string) []string {
	result := make([]string, len(base))
	copy(result, base)
	return result
}

func expandHomePath(path string) (string, error) {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path, err
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~/")), nil
}

func firstShellWord(command string) string {
	if command := agentCommandNameFromProcessArgs(command); command != "" {
		return command
	}
	if command := commandNameFromShellCommand(command); command != "" {
		return command
	}
	if strings.TrimSpace(command) == "" {
		return "shell"
	}
	return cleanProcessCommandName(command)
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func terminalSize() (int, int) {
	if size, err := pty.GetsizeFull(os.Stdin); err == nil && size.Cols > 0 && size.Rows > 0 {
		return int(size.Cols), int(size.Rows)
	}
	columns, rows, err := term.GetSize(int(os.Stdin.Fd()))
	if err == nil && columns > 0 && rows > 0 {
		return columns, rows
	}
	return defaultColumns, defaultRows
}

func makeTerminalRaw() func() {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return func() {}
	}
	state, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return func() {}
	}
	return func() {
		_ = term.Restore(int(os.Stdin.Fd()), state)
	}
}

func forwardResizeSignals(session string) func() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGWINCH)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-signals:
				width, height := terminalSize()
				sendResize(session, width, height)
			case <-done:
				return
			}
		}
	}()
	width, height := terminalSize()
	sendResize(session, width, height)
	return func() {
		close(done)
		signal.Stop(signals)
	}
}

func sendResize(session string, width int, height int) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	_ = enc.Encode(controlMessage{Role: "control", Session: session})
	_ = dec.Decode(&controlResponse{})
	_ = dec.Decode(&controlResponse{})
	_ = enc.Encode(controlMessage{
		ID:      strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:    "resize",
		Width:   width,
		Height:  height,
		Session: session,
	})
}

func socketPath(session string) (string, error) {
	dir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(session))
	return filepath.Join(dir, "monkeymux-"+hex.EncodeToString(sum[:])[:24]+".sock"), nil
}

func runtimeDirectory() (string, error) {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); strings.TrimSpace(dir) != "" {
		path := filepath.Join(dir, "monkeyssh", "monkeymux")
		return path, os.MkdirAll(path, 0o700)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, ".monkeyssh", "run")
	return path, os.MkdirAll(path, 0o700)
}

func dialSession(session string) (net.Conn, error) {
	socket, err := socketPath(session)
	if err != nil {
		return nil, err
	}
	return net.DialTimeout("unix", socket, 500*time.Millisecond)
}

func ptrWindowSnapshot(snapshot windowSnapshot) *windowSnapshot {
	return &snapshot
}

func snapshotByID(snapshots []windowSnapshot, id string) *windowSnapshot {
	for i := range snapshots {
		if snapshots[i].ID == id {
			return &snapshots[i]
		}
	}
	return nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "monkeymux: %v\n", err)
	os.Exit(1)
}

func init() {
	if runtime.GOOS == "windows" {
		fmt.Fprintln(os.Stderr, "monkeymux: windows is not supported by this POSIX build")
		os.Exit(1)
	}
}
