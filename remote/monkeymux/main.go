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

	"golang.org/x/term"
)

// muxPty is the terminal endpoint of a running window's child process. On POSIX
// systems it wraps the pty master file; on Windows it wraps a ConPTY.
type muxPty interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	Close() error
	// Resize sets the pseudo terminal size in character cells.
	Resize(cols int, rows int) error
	// Fd returns the underlying file descriptor on POSIX systems, or 0 when
	// there is no usable descriptor (Windows).
	Fd() uintptr
}

// muxProcess is the child process attached to a window's pty.
type muxProcess interface {
	// Pid returns the process identifier, or 0 when it is unavailable.
	Pid() int
	// Wait blocks until the process exits.
	Wait() error
	// Hangup asks the process (group) to terminate, as if the controlling
	// terminal went away (SIGHUP on POSIX).
	Hangup()
}

const (
	monkeyMuxVersion                  = "0.1.90"
	defaultColumns                    = 80
	defaultRows                       = 24
	maxTitleBytes                     = 160
	oscBufferLimitBytes               = 4096
	processMetadataTimeout            = 500 * time.Millisecond
	processMetadataInterval           = 500 * time.Millisecond
	runCommandOutputMaxBytes          = 8 * 1024 * 1024
	runCommandTimeout                 = 20 * time.Second
	socketTimeout                     = 2 * time.Second
	foregroundRedrawResizeDelay       = 40 * time.Millisecond
	foregroundRedrawForwardingPause   = foregroundRedrawResizeDelay + 80*time.Millisecond
	windowUpdateMinInterval           = 750 * time.Millisecond
	windowHistoryLimitBytes           = 128 * 1024
	windowFullReplayHistoryLimitBytes = 512 * 1024
	windowReplayLimitBytes            = 32 * 1024
	csiBufferLimitBytes               = 64
	pendingTerminalQueryLimitBytes    = 512
	themeHintLimitBytes               = 1024
	restoreFileMode                   = 0o600
	restoreSchemaVersion              = 1
	// Per-window Kitty image retention, used to survive history eviction across
	// reattaches and to back placeholder cells the foreground app re-emits.
	// Sized for genuinely image-heavy windows (e.g. an agent CLI rendering many
	// screenshots); the byte cap is the binding limit and is per window, so peak
	// server memory is this times the number of image-heavy windows.
	maxRetainedKittyImages       = 128
	maxRetainedKittyImageBytes   = 64 * 1024 * 1024
	maxKittyGraphicsPendingBytes = 2 * 1024 * 1024
	// Caps for how many retained images are *replayed* on a window switch.
	// Replaying every retained transmission makes the client decode many
	// megabytes per switch; even with client-side downscaling and dedup, a very
	// large burst can pressure memory on small devices, so keep this modest. The
	// foreground app re-emits placeholder cells for the visible screen, so this
	// only needs to cover the images currently on screen plus a little
	// scrollback; deeper scrollback images repaint when the app redraws.
	maxReplayedKittyImages     = 16
	maxReplayedKittyImageBytes = 8 * 1024 * 1024
)

const terminalParserResetSequence = "\x1b\\"

const terminalCharacterSetResetSequence = "\x0f\x1b(B\x1b)B"

const terminalScreenClearSequence = "\x1b[H\x1b[2J\x1b[3J"

const terminalAllScreensClearSequence = terminalScreenClearSequence + "\x1b[?1049h" + terminalScreenClearSequence + "\x1b[?1049l" + terminalScreenClearSequence

const activeWindowReplayPrefix = terminalParserResetSequence + "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?1007l\x1b[?2004l\x1b[?2031l\x1b[?1047l\x1b[?1049l\x1b[?1l\x1b[?6l\x1b[?7h\x1b[4l\x1b>\x1b[r" + terminalCharacterSetResetSequence + "\x1b[0m" + terminalAllScreensClearSequence

var (
	preReplayPrivateModes = []string{
		"1047",
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
	groupedReplayPrivateModes = [][]string{
		{"1047", "1049"},
		{"1000", "1002", "1003"},
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
		"1047": {},
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

var simulateForegroundResize = func(window *muxWindow, width int, height int) {
	if window == nil || window.pty == nil || width <= 0 || height <= 0 {
		return
	}
	ptyFile := window.pty
	temporaryWidth, temporaryHeight, ok := foregroundRedrawTemporarySize(
		width,
		height,
	)
	if ok {
		applyPtySize(ptyFile, temporaryWidth, temporaryHeight)
		// Leave the PTY at a temporary size long enough for TUIs that ignore
		// same-size SIGWINCH events to observe a real resize before restoring.
		time.AfterFunc(foregroundRedrawResizeDelay, func() {
			applyPtySize(ptyFile, width, height)
		})
		return
	}
	applyPtySize(ptyFile, width, height)
}

func foregroundRedrawTemporarySize(width int, height int) (int, int, bool) {
	if width <= 0 || height <= 0 {
		return 0, 0, false
	}
	if width > 1 {
		return width - 1, height, true
	}
	if height > 1 {
		return width, height - 1, true
	}
	return width, height, false
}

func applyPtySize(ptyFile muxPty, width int, height int) {
	if ptyFile == nil || width <= 0 || height <= 0 {
		return
	}
	_ = ptyFile.Resize(width, height)
}

// restoreRedrawFollowUpDelays are the delays after a restored foreground-redraw
// window first becomes visible at which we re-issue a forced redraw. A window
// restored from an upgrade snapshot relaunches its foreground process (for an
// agent, something like `claude --resume`), and that process can take a while
// to start listening for SIGWINCH. The immediate synthetic resize can therefore
// land before the process is ready, leaving the pane blank until the user
// manually resizes. Re-issuing the redraw a few times catches the process once
// it is up without waiting on a human.
var restoreRedrawFollowUpDelays = []time.Duration{
	250 * time.Millisecond,
	750 * time.Millisecond,
	1750 * time.Millisecond,
}

// scheduleRestoreRedraw runs a restore redraw follow-up after the given delay.
// It is a package variable so tests can invoke the action synchronously.
var scheduleRestoreRedraw = func(delay time.Duration, action func()) {
	time.AfterFunc(delay, action)
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
	codexSessionIDPattern         = regexp.MustCompile(`(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`)
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
	Redraw      bool     `json:"redraw,omitempty"`
	// HaveImageSignatures maps a Kitty protocol image id (as a string) to the
	// FNV-1a-32 signature of the base64-decoded payload the client already
	// holds. Sent with select_window so the replay can skip re-transmitting
	// images the client can render from its own cache.
	HaveImageSignatures map[string]uint32 `json:"haveImageSignatures,omitempty"`
	// ImageIDs lists Kitty protocol image ids (as strings) the client is missing
	// for the active window: it has drawn placeholder cells that reference them
	// but never received (or has evicted) their bytes. Sent with request_images
	// so the server can replay exactly those retained transmissions.
	ImageIDs []string `json:"imageIds,omitempty"`
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
	ID                        string          `json:"id"`
	Index                     int             `json:"index"`
	Name                      string          `json:"name"`
	Active                    bool            `json:"active"`
	CurrentCommand            string          `json:"currentCommand,omitempty"`
	CurrentPath               string          `json:"currentPath,omitempty"`
	PanePid                   int             `json:"panePid,omitempty"`
	Flags                     string          `json:"flags,omitempty"`
	PaneTitle                 string          `json:"paneTitle,omitempty"`
	AgentTool                 string          `json:"agentTool,omitempty"`
	LastActivityEpochSeconds  int64           `json:"lastActivityEpochSeconds,omitempty"`
	TerminalReportsMouseWheel bool            `json:"terminalReportsMouseWheel,omitempty"`
	TerminalMouseReportSgr    bool            `json:"terminalMouseReportSgr,omitempty"`
	PrivateModes              map[string]bool `json:"privateModes,omitempty"`
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

	// restoreRedrawPending tracks windows recreated from a restore snapshot
	// whose freshly-launched foreground process (an agent that was just
	// relaunched, for example) may not have been ready to repaint when it first
	// became visible. Such a window can miss the single synthetic resize that
	// drives its redraw and stay blank until the user manually resizes. The
	// first time each of these windows becomes the active/attached window we
	// schedule follow-up redraws and clear it from this set.
	restoreRedrawPending map[string]bool
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
	pty                        muxPty
	proc                       muxProcess
	history                    []byte
	oscBuffer                  []byte
	attachOscBuffer            []byte
	csiBuffer                  []byte
	terminalBellState          terminalBellParserState
	terminalBellBytes          int
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
	mouseTrackingProcessID     int
	themeRefreshModeProcessID  int
	themeColorQueryPid         int
	themeColorQueryKeys        map[string]bool
	alert                      bool
	closed                     bool
	redrawForwardingPaused     bool
	redrawForwardingGeneration int
	redrawForwardingReplay     []byte
	redrawForwardingBuffer     []byte
	// pendingTerminalQueries holds capability/status queries (device attributes,
	// DSR, XTVERSION) the child emitted while no terminal was showing this window
	// — e.g. an agent (Copilot CLI) relaunched during an upgrade restore, which
	// queries the terminal at startup before the client reattaches. They are
	// stored in history too, but foreground-redraw windows never replay history,
	// so without re-delivering them on attach the terminal never answers and the
	// agent times out into a less rich rendering mode. pendingTerminalQueryCarry
	// holds a query sequence split across pty reads until the rest arrives.
	pendingTerminalQueries    []byte
	pendingTerminalQueryCarry []byte
	// Kitty graphics image transmissions retained for replay on reattach.
	// Placeholder-protocol clients (e.g. Copilot CLI) transmit an image once
	// and thereafter only re-emit placeholder cells, so the one-time image
	// bytes must survive independently of the rolling visible history (which
	// evicts them once enough newer output arrives) or reattached placeholders
	// render blank. Keyed by protocol image id; kittyImageOrder tracks recency.
	kittyImages     map[string][]byte
	kittyImageOrder []string
	// kittyImageSeq records a global monotonic store sequence per image id so a
	// machine-wide budget can evict the globally-oldest image across all
	// windows. Protected by the server lock, like the maps above.
	kittyImageSeq map[string]uint64
	// kittyImageToken holds the FNV-1a-32 signature of each retained image's
	// base64-decoded transmission payload, keyed by protocol image id. A client
	// reports the signatures of the images it still holds on a window switch so
	// the replay can omit re-sending — and the client re-parsing — several
	// megabytes of image data it already has. Kept in sync with kittyImages.
	kittyImageToken      map[string]uint32
	kittyGraphicsPending []byte
}

type terminalBellParserState int

const (
	terminalBellParserGround terminalBellParserState = iota
	terminalBellParserEscape
	terminalBellParserOsc
	terminalBellParserOscEscape
	terminalBellParserString
	terminalBellParserStringEscape
)

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

	// The attach lives for as long as the server keeps the connection open. The
	// input relay (client stdin -> server) is best-effort: a stdin EOF must not
	// end the attach. On POSIX the PTY stdin never EOFs during a live session,
	// but Windows OpenSSH delivers an immediate EOF on exec+PTY channels, and
	// tearing down on that first-finished copy would drop the terminal the
	// instant it opened. Driving the lifetime from the server->stdout copy ends
	// the attach only when the server closes the session or the local output
	// stream can no longer be written (the SSH channel went away).
	go func() {
		_, _ = io.Copy(conn, os.Stdin)
	}()

	if _, err := io.Copy(os.Stdout, conn); err != nil && !errors.Is(err, io.EOF) {
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
	serveArgs := []string{"serve", "--session", session}
	if width > 0 && height > 0 {
		serveArgs = append(serveArgs, "--width", strconv.Itoa(width), "--height", strconv.Itoa(height))
	}
	if restore != nil && len(restore.Windows) > 0 {
		path, err := writeRestoreFile(session, restore)
		if err == nil {
			defer os.Remove(path)
			serveArgs = append(serveArgs, "--restore-file", path)
		}
	}
	if strings.TrimSpace(initialWindow.cwd) != "" {
		serveArgs = append(serveArgs, "--cwd", initialWindow.cwd)
	}
	if strings.TrimSpace(initialWindow.name) != "" {
		serveArgs = append(serveArgs, "--name", initialWindow.name)
	}
	if strings.TrimSpace(initialWindow.command) != "" {
		serveArgs = append(serveArgs, "--command", initialWindow.command)
	}
	if len(initialWindow.themeHint) > 0 {
		serveArgs = append(serveArgs, "--theme-hint-base64", base64.StdEncoding.EncodeToString(initialWindow.themeHint))
	}
	daemonEnv := inheritedEnvironment(os.Environ())
	buildServeCmd := func() *exec.Cmd {
		c := exec.Command(exe, serveArgs...)
		c.Stdin = nil
		c.Stdout = nil
		c.Stderr = nil
		c.Env = daemonEnv
		return c
	}
	// Detach the server so it outlives the launching shell (the POSIX analog is
	// setsid). detachedDaemonSysProcAttrs returns the strategies to try in
	// order; on Windows the first requests a job-object breakaway that some
	// hosts disallow, so a fresh command is started for each fallback attempt.
	var cmd *exec.Cmd
	var startErr error
	for _, attr := range detachedDaemonSysProcAttrs() {
		candidate := buildServeCmd()
		candidate.SysProcAttr = attr
		if err := candidate.Start(); err != nil {
			startErr = err
			continue
		}
		cmd = candidate
		startErr = nil
		break
	}
	if startErr != nil {
		return startErr
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
	if modes := copyPrivateModes(window.PrivateModes); len(modes) > 0 {
		return modes
	}
	modes := map[string]bool{}
	if window.TerminalReportsMouseWheel {
		if window.TerminalMouseReportSgr {
			modes["1002"] = true
		} else {
			modes["1000"] = true
		}
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
	hasAntigravityWindows := false
	for _, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) != "" {
			continue
		}
		tool := agentToolForRestore(window)
		if tool == "antigravity" {
			hasAntigravityWindows = true
		}
		if tool == "" || window.PanePid <= 0 {
			continue
		}
		panePids[window.PanePid] = struct{}{}
	}
	antigravitySessions := map[int]string{}
	if hasAntigravityWindows {
		antigravitySessions = discoverAntigravitySessionIDs(restore)
	}
	if len(panePids) == 0 {
		for i, sessionID := range antigravitySessions {
			restore.Windows[i].AgentSessionID = sessionID
		}
		assignCopilotSessionsByWorkingDirectory(restore)
		return
	}
	processes := readProcessTable()
	// Each entry maps a pane PID to the agent session ID discovered for the
	// agent running inside that pane. Tools that launch fresh (without a
	// resumable session ID in their process arguments) are recovered from
	// their own on-disk session stores so they keep resuming after a
	// MonkeyMux helper update restarts the session server.
	processDiscoveredSessions := map[string]map[int]string{}
	if len(processes) > 0 {
		processDiscoveredSessions = map[string]map[int]string{
			"copilot":  discoverCopilotSessionIDs(processes, panePids),
			"codex":    discoverCodexSessionIDs(processes, panePids),
			"opencode": discoverOpenCodeSessionIDs(processes, panePids),
			"claude":   discoverClaudeSessionIDs(processes, panePids),
			"gemini":   discoverGeminiSessionIDs(processes, panePids),
		}
	}
	for i := range restore.Windows {
		if strings.TrimSpace(restore.Windows[i].AgentSessionID) != "" {
			continue
		}
		tool := agentToolForRestore(restore.Windows[i])
		panePid := restore.Windows[i].PanePid
		if tool == "" {
			continue
		}
		if panePid > 0 {
			if sessionID := processDiscoveredSessions[tool][panePid]; sessionID != "" {
				restore.Windows[i].AgentSessionID = sessionID
				continue
			}
		}
		if panePid > 0 && len(processes) > 0 {
			if sessionID := sessionIDFromDescendantProcessArgs(processes, panePid, tool); sessionID != "" {
				restore.Windows[i].AgentSessionID = sessionID
				continue
			}
		}
		if tool == "antigravity" {
			if sessionID := antigravitySessions[i]; sessionID != "" {
				restore.Windows[i].AgentSessionID = sessionID
			}
		}
	}
	assignCopilotSessionsByWorkingDirectory(restore)
}

type antigravityHistoryEntry struct {
	conversationID string
	workspace      string
}

func discoverAntigravitySessionIDs(restore *serverRestore) map[int]string {
	entries := readAntigravityHistoryEntries()
	if len(entries) == 0 {
		return nil
	}
	latestSessionID := latestAntigravitySessionID(entries)
	needsFallback := antigravityRestoreWindowCount(restore) == 1
	sessions := map[int]string{}
	for i, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) != "" ||
			agentToolForRestore(window) != "antigravity" {
			continue
		}
		if sessionID := antigravitySessionIDForWorkspace(entries, window.Cwd); sessionID != "" {
			sessions[i] = sessionID
			continue
		}
		if needsFallback && latestSessionID != "" {
			sessions[i] = latestSessionID
		}
	}
	return sessions
}

func antigravityRestoreWindowCount(restore *serverRestore) int {
	if restore == nil {
		return 0
	}
	count := 0
	for _, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) == "" &&
			agentToolForRestore(window) == "antigravity" {
			count++
		}
	}
	return count
}

func readAntigravityHistoryEntries() []antigravityHistoryEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	file, err := os.Open(filepath.Join(home, ".gemini", "antigravity-cli", "history.jsonl"))
	if err != nil {
		return nil
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	entries := []antigravityHistoryEntry{}
	for scanner.Scan() {
		var raw struct {
			ConversationID string `json:"conversationId"`
			Workspace      string `json:"workspace"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &raw); err != nil {
			continue
		}
		sessionID := strings.TrimSpace(raw.ConversationID)
		if sessionID == "" {
			continue
		}
		entries = append(entries, antigravityHistoryEntry{
			conversationID: sessionID,
			workspace:      normalizedAntigravityWorkspacePath(raw.Workspace),
		})
	}
	return entries
}

func latestAntigravitySessionID(entries []antigravityHistoryEntry) string {
	for i := len(entries) - 1; i >= 0; i-- {
		if sessionID := strings.TrimSpace(entries[i].conversationID); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func antigravitySessionIDForWorkspace(
	entries []antigravityHistoryEntry,
	workspace string,
) string {
	normalizedWorkspace := normalizedAntigravityWorkspacePath(workspace)
	if normalizedWorkspace == "" {
		return ""
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].workspace == normalizedWorkspace {
			return entries[i].conversationID
		}
	}
	return ""
}

func normalizedAntigravityWorkspacePath(value string) string {
	workspace := strings.TrimSpace(value)
	if workspace == "" {
		return ""
	}
	if strings.HasPrefix(strings.ToLower(workspace), "file://") {
		if path := pathFromOsc7(workspace); path != "" {
			workspace = path
		}
	}
	if expanded, err := expandHomePath(workspace); err == nil {
		workspace = expanded
	}
	return filepath.Clean(workspace)
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

var processOpenFilePathsForMetadata = defaultProcessOpenFilePathsForMetadata

var processWorkingDirectoryForMetadata = defaultProcessWorkingDirectoryForMetadata

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
	chosenModTime := map[int]time.Time{}
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
			panePid := ancestorPanePID(processes, pid, panePids)
			if panePid <= 0 {
				continue
			}
			// When more than one session dir maps to the same pane — a stale
			// inuse lock whose PID was reused by a live copilot, or a session
			// left behind by an earlier resume — keep the most recently locked
			// one so a restored window resumes the live session rather than an
			// abandoned one.
			modTime := copilotLockModTime(lock)
			if previous, exists := chosenModTime[panePid]; exists && !modTime.After(previous) {
				continue
			}
			sessions[panePid] = entry.Name()
			chosenModTime[panePid] = modTime
		}
	}
	return sessions
}

// copilotLockModTime reports when a copilot inuse lock was last written, used to
// prefer the freshest session dir when several map to the same pane.
func copilotLockModTime(lock string) time.Time {
	if info, err := os.Stat(lock); err == nil {
		return info.ModTime()
	}
	return time.Time{}
}

// copilotSessionsByWorkingDirectory groups on-disk copilot sessions by the
// working directory recorded in each session's events log, most recently
// active first. It is the on-disk fallback used when the live process table no
// longer maps a restored copilot window to its session (the helper upgrade
// already reaped the process, ps timed out, or the inuse lock had been
// cleared) so the window can still resume the right conversation.
func copilotSessionsByWorkingDirectory() map[string][]string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	stateDir := filepath.Join(home, ".copilot", "session-state")
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		return nil
	}
	type sessionEntry struct {
		id      string
		modTime time.Time
	}
	byDirectory := map[string][]sessionEntry{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		eventsPath := filepath.Join(stateDir, entry.Name(), "events.jsonl")
		workingDirectory := copilotSessionWorkingDirectory(eventsPath)
		if workingDirectory == "" {
			continue
		}
		modTime := time.Time{}
		if info, err := os.Stat(eventsPath); err == nil {
			modTime = info.ModTime()
		}
		byDirectory[workingDirectory] = append(
			byDirectory[workingDirectory],
			sessionEntry{id: entry.Name(), modTime: modTime},
		)
	}
	result := map[string][]string{}
	for workingDirectory, list := range byDirectory {
		sort.SliceStable(list, func(i, j int) bool {
			return list[i].modTime.After(list[j].modTime)
		})
		ids := make([]string, 0, len(list))
		for _, session := range list {
			ids = append(ids, session.id)
		}
		result[workingDirectory] = ids
	}
	return result
}

// copilotSessionWorkingDirectory returns the normalized working directory a
// copilot session started in, read from the session.start event at the head of
// its events log.
func copilotSessionWorkingDirectory(eventsPath string) string {
	file, err := os.Open(eventsPath)
	if err != nil {
		return ""
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	// The cwd is recorded on the session.start event, which heads the log; scan
	// a few lines defensively in case an unrelated event ever comes first.
	for scanned := 0; scanned < 8; scanned++ {
		line, err := reader.ReadString('\n')
		if strings.TrimSpace(line) != "" {
			var raw struct {
				Data struct {
					Context struct {
						Cwd string `json:"cwd"`
					} `json:"context"`
				} `json:"data"`
			}
			if json.Unmarshal([]byte(line), &raw) == nil {
				if cwd := normalizedCopilotWorkingDirectory(raw.Data.Context.Cwd); cwd != "" {
					return cwd
				}
			}
		}
		if err != nil {
			break
		}
	}
	return ""
}

// normalizedCopilotWorkingDirectory canonicalizes a working directory so a
// window's cwd and a session's recorded cwd compare equal despite ~ expansion
// or symlinks (for example /tmp vs /private/tmp on macOS).
func normalizedCopilotWorkingDirectory(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	if expanded, err := expandHomePath(trimmed); err == nil {
		trimmed = expanded
	}
	cleaned := filepath.Clean(trimmed)
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		return resolved
	}
	return cleaned
}

// assignCopilotSessionsByWorkingDirectory is the on-disk fallback for restored
// copilot windows the live process table no longer maps to a session. Each such
// window resumes the most recent copilot session recorded for its working
// directory instead of relaunching blank, so a helper upgrade keeps the
// conversation open in every copilot window. Sessions already claimed by
// another window (via the process table or an earlier fallback) are never
// reused, so windows sharing a directory get distinct sessions.
func assignCopilotSessionsByWorkingDirectory(restore *serverRestore) {
	if restore == nil {
		return
	}
	needing := []int{}
	for i := range restore.Windows {
		if strings.TrimSpace(restore.Windows[i].AgentSessionID) != "" {
			continue
		}
		if agentToolForRestore(restore.Windows[i]) != "copilot" {
			continue
		}
		needing = append(needing, i)
	}
	if len(needing) == 0 {
		return
	}
	sessionsByDirectory := copilotSessionsByWorkingDirectory()
	if len(sessionsByDirectory) == 0 {
		return
	}
	used := map[string]bool{}
	for i := range restore.Windows {
		if id := strings.TrimSpace(restore.Windows[i].AgentSessionID); id != "" {
			used[id] = true
		}
	}
	for _, i := range needing {
		workingDirectory := normalizedCopilotWorkingDirectory(restore.Windows[i].Cwd)
		if workingDirectory == "" {
			continue
		}
		for _, id := range sessionsByDirectory[workingDirectory] {
			if used[id] {
				continue
			}
			restore.Windows[i].AgentSessionID = id
			used[id] = true
			break
		}
	}
}

func discoverCodexSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	type unresolvedCodexProcess struct {
		panePid          int
		workingDirectory string
	}
	sessions := map[int]string{}
	unresolved := []unresolvedCodexProcess{}
	unresolvedPanes := map[int]struct{}{}
	workingDirectoryCounts := map[string]int{}
	for _, process := range processes {
		panePid := ancestorPanePID(processes, process.pid, panePids)
		if panePid <= 0 || sessions[panePid] != "" {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if agentToolFromCommandName(command) != "codex" {
			continue
		}
		if sessionID := agentSessionIDFromArgs("codex", process.args); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		if sessionID := codexSessionIDFromOpenFiles(process.pid); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		workingDirectory := normalizedMetadataPath(
			processWorkingDirectoryForMetadata(process.pid),
		)
		if workingDirectory == "" {
			continue
		}
		if _, ok := unresolvedPanes[panePid]; ok {
			continue
		}
		unresolvedPanes[panePid] = struct{}{}
		unresolved = append(unresolved, unresolvedCodexProcess{
			panePid:          panePid,
			workingDirectory: workingDirectory,
		})
		workingDirectoryCounts[workingDirectory]++
	}
	for _, candidate := range unresolved {
		if sessions[candidate.panePid] != "" ||
			workingDirectoryCounts[candidate.workingDirectory] != 1 {
			continue
		}
		if sessionID := codexRecentSessionIDForWorkingDirectory(candidate.workingDirectory); sessionID != "" {
			sessions[candidate.panePid] = sessionID
		}
	}
	return sessions
}

func codexSessionIDFromOpenFiles(pid int) string {
	for _, path := range processOpenFilePathsForMetadata(pid) {
		if sessionID := codexSessionIDFromRolloutFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func codexRecentSessionIDForWorkingDirectory(workingDirectory string) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	sessionsDir := filepath.Join(home, ".codex", "sessions")
	for _, path := range recentCodexRolloutFiles(sessionsDir, 30) {
		if normalizedMetadataPath(codexRolloutWorkingDirectory(path)) != workingDirectory {
			continue
		}
		if sessionID := codexSessionIDFromRolloutFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func recentCodexRolloutFiles(root string, limit int) []string {
	type recentFile struct {
		path    string
		modTime time.Time
	}
	files := []recentFile{}
	if limit <= 0 {
		return nil
	}
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() {
			return nil
		}
		if !isCodexRolloutPath(path) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return nil
		}
		files = append(files, recentFile{path: path, modTime: info.ModTime()})
		return nil
	})
	sort.Slice(files, func(i, j int) bool {
		return files[i].modTime.After(files[j].modTime)
	})
	if len(files) > limit {
		files = files[:limit]
	}
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.path)
	}
	return paths
}

func codexRolloutWorkingDirectory(path string) string {
	if !isCodexRolloutPath(path) {
		return ""
	}
	return jsonStringFieldFromFile(path, "cwd")
}

func codexSessionIDFromRolloutFile(path string) string {
	if !isCodexRolloutPath(path) {
		return ""
	}
	if sessionID := codexSessionIDFromRolloutName(filepath.Base(path)); sessionID != "" {
		return sessionID
	}
	if sessionID := jsonStringFieldFromFile(path, "id"); sessionID != "" {
		return sessionID
	}
	return ""
}

func isCodexRolloutPath(path string) bool {
	normalized := filepath.ToSlash(path)
	if !strings.Contains(normalized, "/.codex/sessions/") {
		return false
	}
	name := filepath.Base(path)
	return strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl")
}

func codexSessionIDFromRolloutName(name string) string {
	match := codexSessionIDPattern.FindStringSubmatch(name)
	if len(match) > 1 {
		return match[1]
	}
	return ""
}

// ── OpenCode ───────────────────────────────────────────────────────────────
// OpenCode persists sessions in a SQLite store keyed by working directory, so
// a session launched fresh (`opencode`, no `--session`) carries no resumable
// ID in its process arguments. Recover the most recent session for the pane's
// working directory so it keeps resuming after a MonkeyMux helper update.

type openCodeSessionEntry struct {
	sessionID string
	directory string
}

// openCodeSessionEntriesReader is overridable in tests so the SQLite-backed
// lookup can be stubbed without a live OpenCode database.
var openCodeSessionEntriesReader = defaultOpenCodeSessionEntries

func discoverOpenCodeSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	type unresolvedOpenCodeProcess struct {
		panePid          int
		workingDirectory string
	}
	sessions := map[int]string{}
	unresolved := []unresolvedOpenCodeProcess{}
	unresolvedPanes := map[int]struct{}{}
	workingDirectoryCounts := map[string]int{}
	for _, process := range processes {
		panePid := ancestorPanePID(processes, process.pid, panePids)
		if panePid <= 0 || sessions[panePid] != "" {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if agentToolFromCommandName(command) != "opencode" {
			continue
		}
		if sessionID := agentSessionIDFromArgs("opencode", process.args); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		workingDirectory := normalizedMetadataPath(
			processWorkingDirectoryForMetadata(process.pid),
		)
		if workingDirectory == "" {
			continue
		}
		if _, ok := unresolvedPanes[panePid]; ok {
			continue
		}
		unresolvedPanes[panePid] = struct{}{}
		unresolved = append(unresolved, unresolvedOpenCodeProcess{
			panePid:          panePid,
			workingDirectory: workingDirectory,
		})
		workingDirectoryCounts[workingDirectory]++
	}
	if len(unresolved) == 0 {
		return sessions
	}
	entries := readOpenCodeSessionEntries()
	if len(entries) == 0 {
		return sessions
	}
	for _, candidate := range unresolved {
		if sessions[candidate.panePid] != "" ||
			workingDirectoryCounts[candidate.workingDirectory] != 1 {
			continue
		}
		if sessionID := openCodeSessionIDForWorkingDirectory(
			entries,
			candidate.workingDirectory,
		); sessionID != "" {
			sessions[candidate.panePid] = sessionID
		}
	}
	return sessions
}

func readOpenCodeSessionEntries() []openCodeSessionEntry {
	return openCodeSessionEntriesReader()
}

func openCodeSessionIDForWorkingDirectory(
	entries []openCodeSessionEntry,
	workingDirectory string,
) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" {
		return ""
	}
	// entries are ordered most-recently-updated first.
	for _, entry := range entries {
		if entry.directory == workingDirectory {
			return entry.sessionID
		}
	}
	return ""
}

// defaultOpenCodeSessionEntries reads the most recent top-level OpenCode
// sessions from its SQLite store. OpenCode keeps recent writes in a WAL file,
// so the lookup shells out to sqlite3 (which the app already requires for
// OpenCode session discovery) instead of parsing the database file directly.
func defaultOpenCodeSessionEntries() []openCodeSessionEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	dbPath := filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil
	}
	sqlitePath, err := exec.LookPath("sqlite3")
	if err != nil {
		return nil
	}
	const separator = "\x1f"
	query := "SELECT id, directory FROM session " +
		"WHERE parent_id IS NULL AND time_archived IS NULL " +
		"ORDER BY time_updated DESC LIMIT 200;"
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		sqlitePath,
		"-readonly",
		"-separator", separator,
		dbPath,
		query,
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	entries := []openCodeSessionEntry{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.SplitN(line, separator, 2)
		sessionID := strings.TrimSpace(parts[0])
		if sessionID == "" {
			continue
		}
		directory := ""
		if len(parts) > 1 {
			directory = normalizedMetadataPath(parts[1])
		}
		entries = append(entries, openCodeSessionEntry{
			sessionID: sessionID,
			directory: directory,
		})
	}
	return entries
}

// ── Claude Code ──────────────────────────────────────────────────────────────
// Claude Code stores each session as
// `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. A freshly launched
// `claude` carries no `--resume` argument, so recover the session from the
// rollout file the process holds open, or the most recent project file whose
// `cwd` matches the pane's working directory.

var claudeSessionIDPattern = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
)

func discoverClaudeSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	type unresolvedClaudeProcess struct {
		panePid          int
		workingDirectory string
	}
	sessions := map[int]string{}
	unresolved := []unresolvedClaudeProcess{}
	unresolvedPanes := map[int]struct{}{}
	workingDirectoryCounts := map[string]int{}
	for _, process := range processes {
		panePid := ancestorPanePID(processes, process.pid, panePids)
		if panePid <= 0 || sessions[panePid] != "" {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if agentToolFromCommandName(command) != "claude" {
			continue
		}
		if sessionID := agentSessionIDFromArgs("claude", process.args); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		if sessionID := claudeSessionIDFromOpenFiles(process.pid); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		workingDirectory := normalizedMetadataPath(
			processWorkingDirectoryForMetadata(process.pid),
		)
		if workingDirectory == "" {
			continue
		}
		if _, ok := unresolvedPanes[panePid]; ok {
			continue
		}
		unresolvedPanes[panePid] = struct{}{}
		unresolved = append(unresolved, unresolvedClaudeProcess{
			panePid:          panePid,
			workingDirectory: workingDirectory,
		})
		workingDirectoryCounts[workingDirectory]++
	}
	for _, candidate := range unresolved {
		if sessions[candidate.panePid] != "" ||
			workingDirectoryCounts[candidate.workingDirectory] != 1 {
			continue
		}
		if sessionID := claudeRecentSessionIDForWorkingDirectory(
			candidate.workingDirectory,
		); sessionID != "" {
			sessions[candidate.panePid] = sessionID
		}
	}
	return sessions
}

func claudeSessionIDFromOpenFiles(pid int) string {
	for _, path := range processOpenFilePathsForMetadata(pid) {
		if sessionID := claudeSessionIDFromProjectFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func claudeRecentSessionIDForWorkingDirectory(workingDirectory string) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	projectsDir := filepath.Join(home, ".claude", "projects")
	for _, path := range recentAgentSessionFiles(projectsDir, 60, isClaudeProjectSessionPath) {
		if normalizedMetadataPath(jsonStringFieldFromFile(path, "cwd")) != workingDirectory {
			continue
		}
		if sessionID := claudeSessionIDFromProjectFile(path); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func claudeSessionIDFromProjectFile(path string) string {
	if !isClaudeProjectSessionPath(path) {
		return ""
	}
	name := strings.TrimSuffix(filepath.Base(path), ".jsonl")
	if claudeSessionIDPattern.MatchString(name) {
		return name
	}
	if sessionID := jsonStringFieldFromFile(path, "sessionId"); claudeSessionIDPattern.MatchString(sessionID) {
		return sessionID
	}
	return ""
}

func isClaudeProjectSessionPath(path string) bool {
	normalized := filepath.ToSlash(path)
	if !strings.Contains(normalized, "/.claude/projects/") {
		return false
	}
	return strings.HasSuffix(normalized, ".jsonl")
}

// ── Gemini CLI ───────────────────────────────────────────────────────────────
// Gemini stores chats at `~/.gemini/tmp/<project>/chats/session-*.json`, with
// the resumable `sessionId` and the project `directories` recorded inside the
// file. Recover the session from the chat file the process holds open, or the
// most recent non-subagent chat whose directories include the pane's working
// directory.

var (
	geminiSessionIDFieldPattern   = regexp.MustCompile(`"sessionId"\s*:\s*"((?:\\.|[^"\\])*)"`)
	geminiKindFieldPattern        = regexp.MustCompile(`"kind"\s*:\s*"((?:\\.|[^"\\])*)"`)
	geminiDirectoriesStartPattern = regexp.MustCompile(`"directories"\s*:\s*\[`)
	geminiQuotedStringPattern     = regexp.MustCompile(`"((?:\\.|[^"\\])*)"`)
)

type geminiSessionMetadata struct {
	sessionID   string
	isSubagent  bool
	directories []string
}

func discoverGeminiSessionIDs(
	processes map[int]processInfo,
	panePids map[int]struct{},
) map[int]string {
	type unresolvedGeminiProcess struct {
		panePid          int
		workingDirectory string
	}
	sessions := map[int]string{}
	unresolved := []unresolvedGeminiProcess{}
	unresolvedPanes := map[int]struct{}{}
	workingDirectoryCounts := map[string]int{}
	for _, process := range processes {
		panePid := ancestorPanePID(processes, process.pid, panePids)
		if panePid <= 0 || sessions[panePid] != "" {
			continue
		}
		command := commandNameFromProcessFields(process.comm, process.args)
		if agentToolFromCommandName(command) != "gemini" {
			continue
		}
		if sessionID := agentSessionIDFromArgs("gemini", process.args); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		if sessionID := geminiSessionIDFromOpenFiles(process.pid); sessionID != "" {
			sessions[panePid] = sessionID
			continue
		}
		workingDirectory := normalizedMetadataPath(
			processWorkingDirectoryForMetadata(process.pid),
		)
		if workingDirectory == "" {
			continue
		}
		if _, ok := unresolvedPanes[panePid]; ok {
			continue
		}
		unresolvedPanes[panePid] = struct{}{}
		unresolved = append(unresolved, unresolvedGeminiProcess{
			panePid:          panePid,
			workingDirectory: workingDirectory,
		})
		workingDirectoryCounts[workingDirectory]++
	}
	for _, candidate := range unresolved {
		if sessions[candidate.panePid] != "" ||
			workingDirectoryCounts[candidate.workingDirectory] != 1 {
			continue
		}
		if sessionID := geminiRecentSessionIDForWorkingDirectory(
			candidate.workingDirectory,
		); sessionID != "" {
			sessions[candidate.panePid] = sessionID
		}
	}
	return sessions
}

func geminiSessionIDFromOpenFiles(pid int) string {
	for _, path := range processOpenFilePathsForMetadata(pid) {
		if !isGeminiChatSessionPath(path) {
			continue
		}
		metadata := readGeminiSessionMetadata(path)
		if metadata.sessionID != "" && !metadata.isSubagent {
			return metadata.sessionID
		}
	}
	return ""
}

func geminiRecentSessionIDForWorkingDirectory(workingDirectory string) string {
	workingDirectory = normalizedMetadataPath(workingDirectory)
	if workingDirectory == "" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	tmpDir := filepath.Join(home, ".gemini", "tmp")
	for _, path := range recentAgentSessionFiles(tmpDir, 60, isGeminiChatSessionPath) {
		metadata := readGeminiSessionMetadata(path)
		if metadata.sessionID == "" || metadata.isSubagent {
			continue
		}
		for _, dir := range metadata.directories {
			if normalizedMetadataPath(dir) == workingDirectory {
				return metadata.sessionID
			}
		}
	}
	return ""
}

func isGeminiChatSessionPath(path string) bool {
	normalized := filepath.ToSlash(path)
	if !strings.Contains(normalized, "/.gemini/tmp/") ||
		!strings.Contains(normalized, "/chats/") {
		return false
	}
	name := filepath.Base(path)
	return strings.HasPrefix(name, "session-") &&
		(strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".jsonl"))
}

func readGeminiSessionMetadata(path string) geminiSessionMetadata {
	file, err := os.Open(path)
	if err != nil {
		return geminiSessionMetadata{}
	}
	defer file.Close()
	const maxBytes = 64 * 1024
	raw, err := io.ReadAll(io.LimitReader(file, maxBytes))
	if err != nil {
		return geminiSessionMetadata{}
	}
	return parseGeminiSessionMetadata(string(raw))
}

func parseGeminiSessionMetadata(text string) geminiSessionMetadata {
	metadata := geminiSessionMetadata{}
	if match := geminiSessionIDFieldPattern.FindStringSubmatch(text); match != nil {
		metadata.sessionID = decodeJSONStringLiteral(match[1])
	}
	if match := geminiKindFieldPattern.FindStringSubmatch(text); match != nil {
		metadata.isSubagent = decodeJSONStringLiteral(match[1]) == "subagent"
	}
	metadata.directories = geminiDirectoriesFromText(text)
	return metadata
}

func geminiDirectoriesFromText(text string) []string {
	loc := geminiDirectoriesStartPattern.FindStringIndex(text)
	if loc == nil {
		return nil
	}
	segment := text[loc[1]:]
	// Paths never contain ']', so the array ends at the first closing bracket.
	// When the prefix is truncated mid-array, fall back to the prefix end.
	if end := strings.IndexByte(segment, ']'); end >= 0 {
		segment = segment[:end]
	}
	directories := []string{}
	for _, match := range geminiQuotedStringPattern.FindAllStringSubmatch(segment, -1) {
		if value := decodeJSONStringLiteral(match[1]); value != "" {
			directories = append(directories, value)
		}
	}
	return directories
}

// ── Shared agent session-file helpers ────────────────────────────────────────

// recentAgentSessionFiles returns up to limit matching files under root,
// ordered most-recently-modified first.
func recentAgentSessionFiles(
	root string,
	limit int,
	match func(path string) bool,
) []string {
	if limit <= 0 {
		return nil
	}
	type recentFile struct {
		path    string
		modTime time.Time
	}
	files := []recentFile{}
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() {
			return nil
		}
		if !match(path) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return nil
		}
		files = append(files, recentFile{path: path, modTime: info.ModTime()})
		return nil
	})
	sort.Slice(files, func(i, j int) bool {
		return files[i].modTime.After(files[j].modTime)
	})
	if len(files) > limit {
		files = files[:limit]
	}
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.path)
	}
	return paths
}

func decodeJSONStringLiteral(value string) string {
	var decoded string
	if err := json.Unmarshal([]byte(`"`+value+`"`), &decoded); err == nil {
		return strings.TrimSpace(decoded)
	}
	return strings.TrimSpace(value)
}

func jsonStringFieldFromFile(path string, field string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		if value := jsonStringFieldFromLine(scanner.Text(), field); value != "" {
			return value
		}
	}
	return ""
}

func jsonStringFieldFromLine(line string, field string) string {
	var parsed any
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return ""
	}
	return jsonStringField(parsed, field)
}

func jsonStringField(value any, field string) string {
	switch typed := value.(type) {
	case map[string]any:
		if raw, ok := typed[field]; ok {
			if text, ok := raw.(string); ok {
				return strings.TrimSpace(text)
			}
		}
		for _, child := range typed {
			if text := jsonStringField(child, field); text != "" {
				return text
			}
		}
	case []any:
		for _, child := range typed {
			if text := jsonStringField(child, field); text != "" {
				return text
			}
		}
	}
	return ""
}

func defaultProcessOpenFilePathsForMetadata(pid int) []string {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"lsof",
		"-nP",
		"-p",
		strconv.Itoa(pid),
		"-Fn",
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	paths := []string{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "n") && len(line) > 1 {
			paths = append(paths, line[1:])
		}
	}
	return paths
}

func defaultProcessWorkingDirectoryForMetadata(pid int) string {
	if runtime.GOOS == "linux" {
		if target, err := os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "cwd")); err == nil {
			return target
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"lsof",
		"-nP",
		"-a",
		"-p",
		strconv.Itoa(pid),
		"-d",
		"cwd",
		"-Fn",
	).Output()
	if err != nil || ctx.Err() != nil {
		return ""
	}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "n") && len(line) > 1 {
			return line[1:]
		}
	}
	return ""
}

func normalizedMetadataPath(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	return filepath.Clean(trimmed)
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
	var pendingRedraw []string
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
		if s.windowUsesForegroundRedraw(window.id) {
			pendingRedraw = append(pendingRedraw, window.id)
		}
		restored++
	}
	if restored == 0 {
		_, err := s.createWindow(initialWindow)
		return err
	}
	s.markRestoreRedrawPending(pendingRedraw)
	if activeID == "" {
		activeID = firstID
	}
	if activeID != "" {
		_ = s.selectWindow(activeID)
	}
	return nil
}

func (s *muxServer) windowUsesForegroundRedraw(windowID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	window := s.windowByIDLocked(windowID)
	return window != nil && !window.closed && window.usesForegroundRedrawReplayLocked()
}

func (s *muxServer) markRestoreRedrawPending(windowIDs []string) {
	if len(windowIDs) == 0 {
		return
	}
	s.mu.Lock()
	if s.restoreRedrawPending == nil {
		s.restoreRedrawPending = make(map[string]bool, len(windowIDs))
	}
	for _, id := range windowIDs {
		s.restoreRedrawPending[id] = true
	}
	s.mu.Unlock()
}

// takeRestoreRedrawPending reports whether the window still needs post-restore
// redraw follow-ups and, if so, clears it so the follow-ups run only once.
func (s *muxServer) takeRestoreRedrawPending(windowID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.restoreRedrawPending[windowID] {
		return false
	}
	delete(s.restoreRedrawPending, windowID)
	return true
}

// scheduleRestoreRedrawFollowUps re-issues a forced foreground redraw for a
// freshly restored window a few times after it first becomes visible, so an
// agent that was still starting up when it first appeared is repainted without
// the user having to resize the terminal.
func (s *muxServer) scheduleRestoreRedrawFollowUps(conn net.Conn, windowID string) {
	if conn == nil || !s.takeRestoreRedrawPending(windowID) {
		return
	}
	for _, delay := range restoreRedrawFollowUpDelays {
		scheduleRestoreRedraw(delay, func() {
			s.redrawRestoredWindow(conn, windowID)
		})
	}
}

func (s *muxServer) redrawRestoredWindow(conn net.Conn, windowID string) {
	s.mu.Lock()
	if conn == nil || s.attachConn != conn || s.activeID != windowID {
		s.mu.Unlock()
		return
	}
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed || !window.usesForegroundRedrawReplayLocked() {
		s.mu.Unlock()
		return
	}
	width, height := s.width, s.height
	s.mu.Unlock()
	s.resizeWithRedraw(width, height, true)
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
		launch := agentLaunchCommand(agentTool, startInYoloMode)
		command = launch
		if sessionID := strings.TrimSpace(state.AgentSessionID); sessionID != "" {
			resume := agentResumeCommand(agentTool, sessionID, startInYoloMode)
			command = agentResumeCommandWithFreshFallback(resume, launch)
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
		privateModes:             privateModesForRestore(state.PrivateModes),
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
	var foregroundProcessGroup int
	cwd := resolveStartupDirectory(options.cwd)

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
	cmd.Env = terminalEnvironment(os.Environ())

	s.mu.Lock()
	cols, rows := s.width, s.height
	s.mu.Unlock()

	windowPty, proc, err := startWindow(cmd, cols, rows)
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
		foregroundPid:            proc.Pid(),
		foregroundCommand:        filepath.Base(cmd.Path),
		paneTitle:                paneTitle,
		pty:                      windowPty,
		proc:                     proc,
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
	// Seed the Kitty image cache from any restored history so an image shown
	// before a server restart can still be replayed on the next reattach.
	if window.observeKittyGraphicsLocked(window.history) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	s.clearAlertsLocked(window.id)
	attach = s.attachConn
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	snapshots = s.snapshotsLocked()
	addedSnapshot = snapshotByID(snapshots, window.id)
	s.mu.Unlock()

	s.attachMu.Lock()
	redrew := s.writeAttachReplayAndResizeLocked(attach, replay, window)
	s.attachMu.Unlock()
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	go s.readWindow(window)
	go func() {
		_ = proc.Wait()
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
	terminalBell := window.observeTerminalBellLocked(chunk)
	if len(queryKeys) > 0 && len(s.themeHint) > 0 {
		themeHint = append([]byte(nil), s.themeHint...)
		themeHintData = themeHintResponsesForKeys(themeHint, queryKeys)
	}
	window.observeTerminalModesLocked(chunk)
	window.appendHistoryLocked(chunk)
	if window.observeKittyGraphicsLocked(chunk) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	if s.activeID == windowID {
		attach = s.attachConn
		shouldWrite = attach != nil
	} else if terminalBell {
		window.alert = true
	}
	if attach == nil {
		// No terminal is showing this window, so its capability queries will not
		// be forwarded and answered. Buffer them so they can be delivered — and
		// answered — once a terminal attaches or the window is selected.
		window.appendPendingTerminalQueriesLocked(chunk)
	} else {
		window.pendingTerminalQueryCarry = nil
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
		if len(forwarded) > 0 && window.redrawForwardingPaused {
			window.redrawForwardingBuffer = append(
				window.redrawForwardingBuffer,
				forwarded...,
			)
			shouldWrite = false
			forwarded = nil
		}
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
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var windowPty muxPty

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
	// Capture the pty and close it after releasing s.mu (see below): on Windows
	// muxPty.Close() calls ClosePseudoConsole, which blocks until the output
	// pipe is drained by readWindow -> handleWindowOutput, and that reader needs
	// s.mu. Closing under the lock would deadlock the whole server.
	windowPty = window.pty
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
				redrawWindow = candidate
				activeChanged = true
				break
			}
		}
	}
	snapshots := s.snapshotsLocked()
	shouldShutdown = len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		redrew = s.writeAttachReplayAndResizeLocked(attach, replay, redrawWindow)
	}
	s.attachMu.Unlock()

	// Now that s.mu/s.attachMu are released, tear down the pty. On Windows this
	// blocks until readWindow drains the final ConPTY output (which needs s.mu),
	// so it must happen after unlocking.
	if windowPty != nil {
		_ = windowPty.Close()
	}

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
		if redrew {
			signalForegroundResize(foregroundProcessGroup)
		}
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
	var redrawWindow *muxWindow
	var activeWindowID string
	var themeHintData []byte
	var themeHintWindowID string
	var sendFocusTransition bool
	var sendFocusRefresh bool
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
		s.resizeActiveLocked(hello.Width, hello.Height)
	}
	replay = s.activeReplayLocked()
	if window := s.windowByIDLocked(s.activeID); window != nil {
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
		redrawWindow = window
		activeWindowID = window.id
		if len(s.themeHint) > 0 {
			themeHintData = window.themeHintRefreshDataLocked(s.themeHint)
			themeHintWindowID = window.id
			sendFocusTransition = window.themeHintFocusTransitionLocked()
			sendFocusRefresh = !sendFocusTransition && window.themeHintFocusRefreshLocked()
		}
	}
	s.mu.Unlock()
	s.attachMu.Lock()
	redrew := s.writeAttachReplayAndResizeLocked(conn, replay, redrawWindow)
	s.flushPendingTerminalQueriesLocked(conn, activeWindowID)
	s.attachMu.Unlock()
	if len(themeHintData) > 0 {
		_ = s.writeWindow(themeHintWindowID, themeHintData)
	}
	if sendFocusTransition {
		s.sendFocusTransition(themeHintWindowID)
	} else if sendFocusRefresh {
		s.sendFocusRefresh(themeHintWindowID)
	}
	s.broadcastWindowList("active_window_changed")
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	s.scheduleRestoreRedrawFollowUps(conn, activeWindowID)

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
		if err := s.selectWindowWithSkip(id, request.HaveImageSignatures); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_selected", Status: "ok"})
	case "request_images":
		s.replayRequestedImages(request.ImageIDs)
		client.send(controlResponse{ID: request.ID, Type: "images_replayed", Status: "ok"})
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
		s.resizeWithRedraw(request.Width, request.Height, request.Redraw)
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
		TerminalMouseReportSgr:    window.mouseTrackingActiveLocked() && window.privateModes["1006"],
		PrivateModes:              copyPrivateModes(window.privateModes),
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

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	output := newBoundedCommandOutput(runCommandOutputMaxBytes, cancel)
	cmd := newRunCommand(command)
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = inheritedEnvironment(os.Environ())
	cmd.Stdout = output
	cmd.Stderr = output
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
	return s.selectWindowWithSkip(windowID, nil)
}

// replayRequestedImages re-sends specific retained Kitty image transmissions to
// the attach connection. The client calls this after a switch/redraw when it
// finds placeholder cells referencing images it never received (they fell
// outside the bounded switch replay). The bytes are the store-only (a=t)
// transmissions, so they only repopulate the client's image cache — the
// placeholder cells already on screen then resolve on the next repaint without
// drawing or moving the cursor. Only the active window is served: the attach
// connection is viewing it, and requested ids are scoped to what it just drew.
//
// The request carries no window id and resolves against whichever window is
// active when the server processes it. This is deliberate and safe if a window
// switch races the request: the ids are looked up in the now-active window's
// retained cache, so ids it does not hold are simply skipped (a no-op), and the
// client resets its per-visit request set on every window change and re-requests
// whatever the new window is still missing. The worst case is a redundant or
// skipped transmission, never a wrong-window image persisting on screen.
func (s *muxServer) replayRequestedImages(ids []string) {
	if len(ids) == 0 {
		return
	}
	var attach net.Conn
	var payload []byte
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	attach = s.attachConn
	payload = window.kittyImageTransmissionsForLocked(ids)
	s.mu.Unlock()
	s.writeAttachLocked(attach, payload)
	s.attachMu.Unlock()
}

// selectWindowWithSkip activates a window and streams its reattach replay,
// omitting retained Kitty images the client reports already holding in
// clientHas (nil replays every retained image).
func (s *muxServer) selectWindowWithSkip(
	windowID string,
	clientHas map[string]uint32,
) error {
	var attach net.Conn
	var replay []byte
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
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
	replay = s.replayBytesLockedWithSkip(window, clientHas)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	redrawWindow = window
	s.mu.Unlock()
	redrew := s.writeAttachReplayAndResizeLocked(attach, replay, redrawWindow)
	s.flushPendingTerminalQueriesLocked(attach, windowID)
	s.attachMu.Unlock()
	s.broadcastWindowList("active_window_changed")
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	s.scheduleRestoreRedrawFollowUps(attach, windowID)
	return nil
}

func (s *muxServer) closeWindow(windowID string) (bool, error) {
	var attach net.Conn
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var process muxProcess
	var windowPty muxPty
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
			redrawWindow = replacement
			activeChanged = true
		} else {
			s.activeID = ""
		}
	}
	window.closed = true
	window.alert = false
	process = window.proc
	windowPty = window.pty
	s.reindexWindowsLocked()
	snapshots = s.snapshotsLocked()
	shouldShutdown = openCount <= 1 || len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		redrew = s.writeAttachReplayAndResizeLocked(attach, replay, redrawWindow)
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
		if redrew {
			signalForegroundResize(foregroundProcessGroup)
		}
	}
	if process != nil {
		process.Hangup()
	}
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
	s.resizeWithRedraw(width, height, false)
}

func (s *muxServer) resizeWithRedraw(width int, height int, forceRedraw bool) {
	var attach net.Conn
	var modeReplay []byte
	var foregroundProcessGroup int
	var shouldSignal bool
	s.mu.Lock()
	sizeChanged := s.width != width || s.height != height
	s.width = width
	s.height = height
	window := s.windowByIDLocked(s.activeID)
	s.resizeWindowLocked(window, width, height)
	if window != nil &&
		!window.closed &&
		window.usesForegroundRedrawReplayLocked() &&
		(forceRedraw || sizeChanged) {
		s.pauseAttachForwardingForRedrawLocked(window, width, height)
		simulateForegroundResize(window, width, height)
		attach = s.attachConn
		modeReplay = window.modeReplayForAttachedTerminalLocked()
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
		shouldSignal = true
	}
	s.mu.Unlock()
	s.writeAttach(attach, modeReplay)
	if shouldSignal {
		signalForegroundResize(foregroundProcessGroup)
	}
}

func (s *muxServer) resizeActiveLocked(width int, height int) {
	window := s.windowByIDLocked(s.activeID)
	s.resizeWindowLocked(window, width, height)
}

func (s *muxServer) resizeWindowLocked(window *muxWindow, width int, height int) {
	if window == nil || window.closed || window.pty == nil {
		return
	}
	_ = window.pty.Resize(width, height)
}

func (s *muxServer) writeAttachReplayAndResizeLocked(
	conn net.Conn,
	replay []byte,
	window *muxWindow,
) bool {
	if s.deferAttachReplayForRedrawLocked(conn, replay, window) {
		return true
	}
	s.writeAttachLocked(conn, replay)
	return s.simulateForegroundResizeIfAttached(conn, window)
}

func (s *muxServer) deferAttachReplayForRedrawLocked(
	conn net.Conn,
	replay []byte,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conn == nil ||
		s.attachConn != conn ||
		window == nil ||
		window.closed ||
		!window.usesForegroundRedrawReplayLocked() {
		return false
	}
	if _, _, ok := foregroundRedrawTemporarySize(s.width, s.height); !ok {
		return false
	}
	// Foreground-redraw panes repaint in response to the synthetic resize. Keep
	// the reset replay with that repaint so attach clients never paint the
	// intermediate cleared/stale frame.
	s.pauseAttachForwardingForRedrawLocked(window, s.width, s.height)
	window.redrawForwardingReplay = append(
		window.redrawForwardingReplay[:0],
		replay...,
	)
	simulateForegroundResize(window, s.width, s.height)
	return true
}

func (s *muxServer) simulateForegroundResizeIfAttached(
	conn net.Conn,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conn == nil || s.attachConn != conn || window == nil || window.closed {
		return false
	}
	s.pauseAttachForwardingForRedrawLocked(window, s.width, s.height)
	simulateForegroundResize(window, s.width, s.height)
	return true
}

func (s *muxServer) pauseAttachForwardingForRedrawLocked(
	window *muxWindow,
	width int,
	height int,
) {
	if window == nil ||
		window.closed ||
		s.attachConn == nil ||
		!window.usesForegroundRedrawReplayLocked() {
		return
	}
	if _, _, ok := foregroundRedrawTemporarySize(width, height); !ok {
		return
	}
	window.redrawForwardingBuffer = nil
	window.redrawForwardingPaused = true
	window.redrawForwardingGeneration += 1
	windowID := window.id
	generation := window.redrawForwardingGeneration
	time.AfterFunc(foregroundRedrawForwardingPause, func() {
		s.resumePausedAttachForwarding(windowID, generation)
	})
}

func (s *muxServer) resumePausedAttachForwarding(
	windowID string,
	generation int,
) {
	var attach net.Conn
	var replay []byte
	var buffered []byte
	s.attachMu.Lock()
	defer s.attachMu.Unlock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil ||
		window.closed ||
		!window.redrawForwardingPaused ||
		window.redrawForwardingGeneration != generation {
		s.mu.Unlock()
		return
	}
	replay = append([]byte(nil), window.redrawForwardingReplay...)
	buffered = append([]byte(nil), window.redrawForwardingBuffer...)
	window.redrawForwardingReplay = nil
	window.redrawForwardingBuffer = nil
	window.redrawForwardingPaused = false
	if s.activeID == windowID {
		attach = s.attachConn
	}
	s.mu.Unlock()
	output := append(replay, buffered...)
	if len(output) > 0 {
		s.mu.Lock()
		shouldWrite := s.activeID == windowID && s.attachConn == attach
		s.mu.Unlock()
		if shouldWrite {
			s.writeAttachLocked(attach, output)
		}
	}
}

func (w *muxWindow) foregroundProcessGroupLocked() int {
	pgrp := foregroundProcessGroupForWindow(w)
	if pgrp <= 0 {
		return 0
	}
	w.foregroundPid = pgrp
	return pgrp
}

func (w *muxWindow) modeReplayForAttachedTerminalLocked() []byte {
	if w == nil || w.closed {
		return nil
	}
	modes := terminalModePostReplaySequence(w)
	cursor := cursorVisibilityReplaySequence(w.cursorVisibleForReplayLocked())
	replay := make([]byte, 0, len(modes)+len(cursor))
	replay = append(replay, modes...)
	replay = append(replay, cursor...)
	return replay
}

func (s *muxServer) activeReplayLocked() []byte {
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		return nil
	}
	return s.replayBytesLocked(window)
}

func (s *muxServer) replayBytesLocked(window *muxWindow) []byte {
	return s.replayBytesLockedWithSkip(window, nil)
}

// replayBytesLockedWithSkip builds the reattach replay, omitting retained Kitty
// images whose id/signature the client reports already holding in clientHas
// (nil replays every retained image, as a fresh attach does).
func (s *muxServer) replayBytesLockedWithSkip(
	window *muxWindow,
	clientHas map[string]uint32,
) []byte {
	history := stripTerminalQueriesFromReplay(window.historyTailLocked())
	if window.usesForegroundRedrawReplayLocked() {
		// The foreground app redraws its own cells on reattach (driven by a
		// resize), so we must not replay the visible history or it would draw
		// twice. We do, however, replay any retained Kitty graphics image
		// transmissions: placeholder-protocol clients (e.g. Copilot CLI)
		// transmit an image once and then only re-emit the placeholder cells,
		// so without restoring the image bytes the redrawn placeholders would
		// have nothing to composite and render blank. The retained transmissions
		// survive eviction from the rolling visible history and are store-only
		// (a=T downgraded to a=t) so they produce no visible output themselves.
		history = window.kittyImageReplayLocked(clientHas)
	} else {
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

func (w *muxWindow) usesForegroundRedrawReplayLocked() bool {
	if w == nil {
		return false
	}
	return w.alternateScreenModeActiveLocked() || w.agentToolLocked() != ""
}

func (w *muxWindow) alternateScreenModeActiveLocked() bool {
	return w.privateModes["1047"] || w.privateModes["1049"]
}

func (w *muxWindow) reportsMouseWheelLocked() bool {
	return w.mouseTrackingActiveLocked()
}

// reportsMouseWheelRawLocked reports whether any mouse-tracking mode is enabled
// in the window's tracked state, ignoring which process enabled it.
func (w *muxWindow) reportsMouseWheelRawLocked() bool {
	if w == nil {
		return false
	}
	return w.privateModes["1000"] ||
		w.privateModes["1002"] ||
		w.privateModes["1003"]
}

// mouseTrackingActiveLocked reports whether mouse-tracking should be considered
// active for the window's *current* foreground process. A TUI that enables
// mouse tracking and then exits (or is killed, e.g. when the app crashes
// mid-session) leaves the mode set in our tracked state, but the shell that
// returns to the foreground does not want mouse reports. Gating on the
// foreground PID — mirroring focus/theme mode handling — stops a plain shell
// prompt from being told it reports mouse wheel, which would otherwise turn
// touch-scrolls into SGR mouse-report spew.
func (w *muxWindow) mouseTrackingActiveLocked() bool {
	if !w.reportsMouseWheelRawLocked() {
		return false
	}
	activePid := w.activeForegroundPidLocked()
	return w.mouseTrackingProcessID <= 0 ||
		activePid <= 0 ||
		w.mouseTrackingProcessID == activePid
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

// privateModesForRestore copies tracked modes for a restored window but drops
// mouse-tracking modes (1000/1002/1003/1006). A restore spawns a fresh process:
// agent windows are relaunched and re-enable mouse tracking themselves, while
// shell windows do not want it. Carrying a dead process's mouse modes forward
// would make a plain shell prompt report mouse wheel and spew SGR reports on
// scroll.
func privateModesForRestore(privateModes map[string]bool) map[string]bool {
	copied := copyPrivateModes(privateModes)
	if copied == nil {
		return nil
	}
	for _, mode := range []string{"1000", "1002", "1003", "1006"} {
		delete(copied, mode)
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
	if window == nil || !window.alternateScreenModeActiveLocked() {
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
		if groupedReplayPrivateMode(mode) {
			continue
		}
		enabled, ok := window.privateModes[mode]
		if !ok {
			continue
		}
		if mode == "1004" && enabled && !window.focusModeActiveLocked() {
			continue
		}
		replay = appendPrivateModeReplay(replay, mode, enabled)
	}
	for _, group := range groupedReplayPrivateModes {
		replay = appendGroupedPrivateModeReplay(replay, window, privateModes, group)
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

func appendGroupedPrivateModeReplay(
	replay []byte,
	window *muxWindow,
	privateModes []string,
	group []string,
) []byte {
	for _, mode := range group {
		if !containsString(privateModes, mode) {
			continue
		}
		if enabled, ok := window.privateModes[mode]; ok && !enabled {
			replay = appendPrivateModeReplay(replay, mode, false)
		}
	}
	for _, mode := range group {
		if !containsString(privateModes, mode) {
			continue
		}
		if enabled, ok := window.privateModes[mode]; ok && enabled {
			// Don't re-enable mouse tracking on replay if the process that
			// turned it on is no longer in the foreground; the prefix already
			// disabled it, so the reattached client ends up in the effective
			// (off) state instead of spewing mouse reports at a shell prompt.
			if isMouseWheelMode(mode) && !window.mouseTrackingActiveLocked() {
				continue
			}
			replay = appendPrivateModeReplay(replay, mode, true)
		}
	}
	return replay
}

func isMouseWheelMode(mode string) bool {
	return mode == "1000" || mode == "1002" || mode == "1003"
}

func appendPrivateModeReplay(replay []byte, mode string, enabled bool) []byte {
	final := byte('l')
	if enabled {
		final = 'h'
	}
	replay = append(replay, "\x1b[?"...)
	replay = append(replay, mode...)
	replay = append(replay, final)
	return replay
}

func groupedReplayPrivateMode(mode string) bool {
	for _, group := range groupedReplayPrivateModes {
		if containsString(group, mode) {
			return true
		}
	}
	return false
}

func containsString(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
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

// flushPendingTerminalQueriesLocked delivers to the freshly attached terminal any
// capability/status queries the active window's child emitted while no terminal
// was showing it. An agent (e.g. Copilot CLI) relaunched during an upgrade
// restore queries the terminal at startup, before the client reattaches; those
// queries land in history but foreground-redraw windows do not replay history, so
// the terminal would otherwise never answer and the agent falls back to a less
// rich rendering mode. Re-emitting just the queries makes the terminal answer
// them, and the answers route back to the active window's child via the normal
// attach-input path. Must be called with attachMu held.
func (s *muxServer) flushPendingTerminalQueriesLocked(conn net.Conn, windowID string) {
	if conn == nil {
		return
	}
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	var pending []byte
	if window != nil && !window.closed &&
		s.activeID == windowID && s.attachConn == conn &&
		len(window.pendingTerminalQueries) > 0 {
		pending = window.pendingTerminalQueries
		window.pendingTerminalQueries = nil
		window.pendingTerminalQueryCarry = nil
	}
	s.mu.Unlock()
	if len(pending) > 0 {
		s.writeAttachLocked(conn, pending)
	}
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
	sendFocusTransition := window.themeHintFocusTransitionLocked()
	sendFocusRefresh := false
	if len(themeHint) > 0 {
		themeHintData = window.themeHintRefreshDataLocked(themeHint)
		sendFocusRefresh = !sendFocusTransition && window.themeHintFocusRefreshLocked()
	}
	if len(themeHintData) == 0 && !sendFocusTransition && !sendFocusRefresh {
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
	} else if sendFocusRefresh {
		s.sendFocusRefresh(windowID)
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

func (s *muxServer) sendFocusRefresh(windowID string) {
	_ = s.writeWindow(windowID, []byte("\x1b[I"))
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
	limit := w.historyLimitLocked()
	if len(chunk) >= limit {
		w.history = append(
			w.history[:0],
			chunk[len(chunk)-limit:]...,
		)
		return
	}
	// Grow the underlying buffer to 2x the limit so trims are amortized:
	// each byte gets shifted at most once before falling out of history.
	if cap(w.history) < 2*limit {
		grown := make([]byte, len(w.history), 2*limit)
		copy(grown, w.history)
		w.history = grown
	}
	w.history = append(w.history, chunk...)
	if len(w.history) > 2*limit {
		// copy() handles the overlap correctly because src is after dst.
		n := copy(w.history, w.history[len(w.history)-limit:])
		w.history = w.history[:n]
	}
}

func (w *muxWindow) historyTailLocked() []byte {
	limit := w.historyLimitLocked()
	if len(w.history) <= limit {
		return w.history
	}
	start := len(w.history) - limit
	start = advanceToUtf8Boundary(w.history, start)
	return w.history[start:]
}

func (w *muxWindow) historyLimitLocked() int {
	if w.usesForegroundRedrawReplayLocked() {
		return windowFullReplayHistoryLimitBytes
	}
	return windowHistoryLimitBytes
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

func (w *muxWindow) observeTerminalBellLocked(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	observedBell := false
	for _, b := range data {
		switch w.terminalBellState {
		case terminalBellParserGround:
			switch b {
			case '\a':
				observedBell = true
			case '\x1b':
				w.terminalBellState = terminalBellParserEscape
				w.terminalBellBytes = 1
			}
		case terminalBellParserEscape:
			w.terminalBellBytes++
			switch b {
			case ']':
				w.terminalBellState = terminalBellParserOsc
			case 'P', 'X', '^', '_':
				w.terminalBellState = terminalBellParserString
			case '\x1b':
				w.terminalBellState = terminalBellParserEscape
				w.terminalBellBytes = 1
			case '\a':
				observedBell = true
				w.resetTerminalBellParserLocked()
			default:
				w.resetTerminalBellParserLocked()
			}
		case terminalBellParserOsc:
			w.terminalBellBytes++
			switch b {
			case '\a':
				w.resetTerminalBellParserLocked()
			case '\x1b':
				w.terminalBellState = terminalBellParserOscEscape
			}
		case terminalBellParserOscEscape:
			w.terminalBellBytes++
			switch b {
			case '\\':
				w.resetTerminalBellParserLocked()
			case '\x1b':
				w.terminalBellState = terminalBellParserOscEscape
			default:
				w.terminalBellState = terminalBellParserOsc
			}
		case terminalBellParserString:
			w.terminalBellBytes++
			switch b {
			case '\a':
				w.resetTerminalBellParserLocked()
			case '\x1b':
				w.terminalBellState = terminalBellParserStringEscape
			}
		case terminalBellParserStringEscape:
			w.terminalBellBytes++
			switch b {
			case '\\', '\a':
				w.resetTerminalBellParserLocked()
			case '\x1b':
				w.terminalBellState = terminalBellParserStringEscape
			default:
				w.terminalBellState = terminalBellParserString
			}
		}
		if w.terminalBellState != terminalBellParserGround &&
			w.terminalBellBytes > oscBufferLimitBytes {
			w.resetTerminalBellParserLocked()
		}
	}
	return observedBell
}

func (w *muxWindow) resetTerminalBellParserLocked() {
	w.terminalBellState = terminalBellParserGround
	w.terminalBellBytes = 0
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
			if isReplayUnsafeOscQuery(payload) ||
				isReplayUnsafeOscNotification(payload) {
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

// kittyTransmission is a single complete Kitty graphics image transmission in
// store-only form (action downgraded to a=t), keyed by its protocol image id.
type kittyTransmission struct {
	id  string
	buf []byte
}

// scanKittyTransmissions parses complete Kitty graphics image transmissions from
// the front of data. It returns the store-only transmissions found (a=T rewritten
// to a=t), any image ids deleted via a=d, and the number of leading bytes fully
// consumed. data[consumed:] is the trailing remainder, which either is empty or
// begins an incomplete transmission and must be prepended to the next chunk.
//
// Non-graphics bytes are consumed and discarded; the remainder therefore never
// accumulates ordinary terminal output.
func scanKittyTransmissions(data []byte) (txs []kittyTransmission, deletes []string, consumed int) {
	i := 0
	for i < len(data) {
		if data[i] != '\x1b' {
			i++
			consumed = i
			continue
		}
		// data[i] == ESC. A graphics command is ESC _ G.
		if i+2 >= len(data) {
			// Not enough bytes to tell. If it cannot become "_G", consume the
			// ESC; otherwise carry the partial introducer forward.
			if i+1 < len(data) && data[i+1] != '_' {
				i++
				consumed = i
				continue
			}
			return txs, deletes, i
		}
		if data[i+1] != '_' || data[i+2] != 'G' {
			i++
			consumed = i
			continue
		}
		end, buf, id, isDelete, ok := assembleKittyTransmission(data, i)
		if !ok {
			// Incomplete transmission: carry everything from here forward.
			return txs, deletes, i
		}
		if isDelete {
			if id != "" {
				deletes = append(deletes, id)
			}
		} else if buf != nil {
			txs = append(txs, kittyTransmission{id: id, buf: buf})
		}
		i = end
		consumed = end
	}
	return txs, deletes, consumed
}

// assembleKittyTransmission parses a (possibly multi-chunk) Kitty graphics
// command beginning at start. It returns the index just past the final APC, the
// store-only transmission bytes (nil for non-transmissions), the image id, an
// isDelete flag for a=d commands, and ok=false if the command is incomplete and
// needs more bytes. a=T is downgraded to a=t so replay never draws or moves the
// cursor.
func assembleKittyTransmission(
	data []byte,
	start int,
) (end int, buf []byte, id string, isDelete bool, ok bool) {
	apcEnd := kittyApcEnd(data, start)
	if apcEnd < 0 {
		return 0, nil, "", false, false
	}
	args := parseKittyControl(kittyControl(data, start, apcEnd))
	action := args["a"]
	if action == "" {
		action = "t"
	}
	switch action {
	case "d":
		return apcEnd, nil, args["i"], true, true
	case "t", "T":
		// An image transmission; assemble continuation chunks below.
	default:
		// Queries (a=q), placements (a=p) etc. are complete but not retained.
		return apcEnd, nil, "", false, true
	}

	buf = append(buf, rewriteKittyTransmitAction(data[start:apcEnd])...)
	more := args["m"] == "1"
	next := apcEnd
	for more {
		if next+2 >= len(data) || data[next] != '\x1b' ||
			data[next+1] != '_' || data[next+2] != 'G' {
			return 0, nil, "", false, false
		}
		chunkEnd := kittyApcEnd(data, next)
		if chunkEnd < 0 {
			return 0, nil, "", false, false
		}
		chunkArgs := parseKittyControl(kittyControl(data, next, chunkEnd))
		buf = append(buf, data[next:chunkEnd]...)
		more = chunkArgs["m"] == "1"
		next = chunkEnd
	}
	return next, buf, args["i"], false, true
}

// observeKittyGraphicsLocked retains the Kitty image transmissions seen in chunk
// so they can be replayed on reattach regardless of how much later output has
// evicted them from the rolling visible history. Partial transmissions split
// across chunks are carried forward in kittyGraphicsPending.
func (w *muxWindow) observeKittyGraphicsLocked(chunk []byte) bool {
	if len(chunk) == 0 && len(w.kittyGraphicsPending) == 0 {
		return false
	}
	data := chunk
	if len(w.kittyGraphicsPending) > 0 {
		data = make([]byte, 0, len(w.kittyGraphicsPending)+len(chunk))
		data = append(data, w.kittyGraphicsPending...)
		data = append(data, chunk...)
	}

	changed := false
	txs, deletes, consumed := scanKittyTransmissions(data)
	for _, id := range deletes {
		if w.removeKittyImageLocked(id) {
			changed = true
		}
	}
	for _, tx := range txs {
		if tx.id == "" {
			continue // cannot dedupe or replay without an id
		}
		w.storeKittyImageLocked(tx.id, tx.buf)
		changed = true
	}

	remainder := data[consumed:]
	if len(remainder) > maxKittyGraphicsPendingBytes {
		// An unterminated or oversized graphics sequence: drop it rather than
		// buffer unbounded bytes; parsing resyncs at the next introducer.
		w.kittyGraphicsPending = nil
		return changed
	}
	if len(remainder) == 0 {
		w.kittyGraphicsPending = nil
		return changed
	}
	w.kittyGraphicsPending = append([]byte(nil), remainder...)
	return changed
}

func (w *muxWindow) storeKittyImageLocked(id string, buf []byte) {
	if w.kittyImages == nil {
		w.kittyImages = map[string][]byte{}
	}
	if w.kittyImageSeq == nil {
		w.kittyImageSeq = map[string]uint64{}
	}
	if w.kittyImageToken == nil {
		w.kittyImageToken = map[string]uint32{}
	}
	if _, exists := w.kittyImages[id]; exists {
		w.kittyImageOrder = removeStringOnce(w.kittyImageOrder, id)
	}
	w.kittyImageOrder = append(w.kittyImageOrder, id)
	w.kittyImages[id] = append([]byte(nil), buf...)
	w.kittyImageToken[id] = kittyTransmissionPayloadSignature(buf)
	kittyImageStoreSeq++
	w.kittyImageSeq[id] = kittyImageStoreSeq
	w.enforceKittyImageCapsLocked()
}

func (w *muxWindow) removeKittyImageLocked(id string) bool {
	if _, ok := w.kittyImages[id]; !ok {
		return false
	}
	delete(w.kittyImages, id)
	delete(w.kittyImageSeq, id)
	delete(w.kittyImageToken, id)
	w.kittyImageOrder = removeStringOnce(w.kittyImageOrder, id)
	return true
}

func (w *muxWindow) enforceKittyImageCapsLocked() {
	total := 0
	for _, b := range w.kittyImages {
		total += len(b)
	}
	for len(w.kittyImageOrder) > 0 &&
		(len(w.kittyImageOrder) > maxRetainedKittyImages ||
			(total > maxRetainedKittyImageBytes && len(w.kittyImageOrder) > 1)) {
		oldest := w.kittyImageOrder[0]
		w.kittyImageOrder = w.kittyImageOrder[1:]
		total -= len(w.kittyImages[oldest])
		delete(w.kittyImages, oldest)
		delete(w.kittyImageSeq, oldest)
		delete(w.kittyImageToken, oldest)
	}
}

// kittyImageStoreSeq is a global monotonic counter assigning each stored image
// a store order, used to evict the globally-oldest image under the machine-wide
// budget. Mutated only while the server lock is held.
var kittyImageStoreSeq uint64

// kittyImageGlobalBudgetBytes bounds the total Kitty image bytes retained across
// all windows so a busy multi-window session cannot exhaust memory on a small
// host (e.g. a Raspberry Pi). Computed once from detected system memory; a var
// so tests can override it.
var kittyImageGlobalBudgetBytes = computeKittyImageGlobalBudgetBytes()

// enforceGlobalKittyImageBudgetLocked evicts the globally-oldest retained images
// across every window until the total retained bytes fit the machine-wide
// budget. The server lock must be held.
func (s *muxServer) enforceGlobalKittyImageBudgetLocked() {
	budget := kittyImageGlobalBudgetBytes
	if budget <= 0 {
		return
	}
	total := 0
	count := 0
	for _, w := range s.windows {
		for _, b := range w.kittyImages {
			total += len(b)
			count++
		}
	}
	// Keep at least one image so a single oversized image is never fully
	// dropped (it would just render blank otherwise); the per-window caps still
	// bound any single window.
	for total > budget && count > 1 {
		var victimWin *muxWindow
		var victimID string
		var victimSeq uint64
		found := false
		for _, w := range s.windows {
			for id, seq := range w.kittyImageSeq {
				if _, ok := w.kittyImages[id]; !ok {
					continue
				}
				if !found || seq < victimSeq {
					found = true
					victimSeq = seq
					victimWin = w
					victimID = id
				}
			}
		}
		if !found || victimWin == nil {
			return
		}
		total -= len(victimWin.kittyImages[victimID])
		count--
		victimWin.removeKittyImageLocked(victimID)
	}
}

// computeKittyImageGlobalBudgetBytes derives the machine-wide image cache budget
// from detected system memory, clamped to a safe range. Unknown memory falls
// back to a conservative default.
func computeKittyImageGlobalBudgetBytes() int {
	const (
		floorBytes    = 32 * 1024 * 1024  // always allow some image caching
		ceilingBytes  = 512 * 1024 * 1024 // cap on large machines
		defaultBytes  = 256 * 1024 * 1024 // used when memory is undetectable
		memoryDivisor = 8                 // ~12.5% of RAM for the image cache
	)
	mem := detectSystemMemoryBytes()
	if mem == 0 {
		return defaultBytes
	}
	budget := int(mem / memoryDivisor)
	if budget < floorBytes {
		budget = floorBytes
	}
	if budget > ceilingBytes {
		budget = ceilingBytes
	}
	return budget
}

// kittyImageReplayLocked returns the most-recent retained image transmissions,
// bounded by count and bytes, so a reattaching client repopulates the images
// most likely still on screen without decoding many megabytes on its UI thread.
// Older retained transmissions are omitted; the foreground app re-emits them on
// its next redraw if they are still visible.
//
// Images whose id maps to a matching signature in clientHas are omitted: the
// client already holds identical bytes and would re-parse (then discard) them,
// so re-sending only adds switch latency. The id still counts against the caps
// so the "most recent N" window is unchanged whether or not the client has them.
func (w *muxWindow) kittyImageReplayLocked(clientHas map[string]uint32) []byte {
	if len(w.kittyImageOrder) == 0 {
		return nil
	}
	// Walk newest-first, keeping images until a cap is hit.
	selected := make([]string, 0, maxReplayedKittyImages)
	total := 0
	for i := len(w.kittyImageOrder) - 1; i >= 0; i-- {
		id := w.kittyImageOrder[i]
		buf := w.kittyImages[id]
		if len(selected) >= maxReplayedKittyImages {
			break
		}
		if len(selected) > 0 && total+len(buf) > maxReplayedKittyImageBytes {
			break
		}
		selected = append(selected, id)
		total += len(buf)
	}
	// Emit oldest-kept first so ids are established in chronological order,
	// skipping any the client already holds with identical content.
	var out []byte
	for i := len(selected) - 1; i >= 0; i-- {
		id := selected[i]
		if len(clientHas) > 0 {
			if token, ok := clientHas[id]; ok && token == w.kittyImageToken[id] {
				continue
			}
		}
		out = append(out, w.kittyImages[id]...)
	}
	return out
}

// kittyImageTransmissionsForLocked returns the concatenated store-only
// transmissions of the requested image ids, in request order, skipping ids that
// are unknown or duplicated. Unlike kittyImageReplayLocked this ignores the
// replay caps: the client asks only for the handful of ids it is actually
// missing, so the payload is naturally bounded by demand rather than by a fixed
// "most recent N" window.
func (w *muxWindow) kittyImageTransmissionsForLocked(ids []string) []byte {
	if len(ids) == 0 || len(w.kittyImages) == 0 {
		return nil
	}
	var out []byte
	var seen map[string]struct{}
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		buf, ok := w.kittyImages[id]
		if !ok {
			continue
		}
		if seen == nil {
			seen = make(map[string]struct{}, len(ids))
		}
		seen[id] = struct{}{}
		out = append(out, buf...)
	}
	return out
}

func removeStringOnce(items []string, target string) []string {
	for i, item := range items {
		if item == target {
			return append(items[:i], items[i+1:]...)
		}
	}
	return items
}

// base64DecodeValue maps an ASCII byte to its 6-bit base64 value, or -1 for any
// non-base64 byte (whitespace, padding, control). Package-level so the lenient
// decoder allocates nothing per call.
var base64DecodeValue = func() [256]int8 {
	var table [256]int8
	for i := range table {
		table[i] = -1
	}
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(alphabet); i++ {
		table[alphabet[i]] = int8(i)
	}
	return table
}()

// decodeLenientBase64 decodes base64 the same way the client parser does:
// non-base64 bytes (whitespace, padding) are skipped and 6-bit groups are
// emitted as bytes as they accumulate, tolerating a missing final group. Both
// sides must decode identically for the payload signatures to match.
func decodeLenientBase64(payload []byte) []byte {
	out := make([]byte, 0, len(payload)*3/4+1)
	var accumulator uint32
	var bits int
	for _, c := range payload {
		v := base64DecodeValue[c]
		if v < 0 {
			continue
		}
		accumulator = (accumulator << 6) | uint32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte((accumulator>>uint(bits))&0xff))
		}
	}
	return out
}

// kittyTransmissionPayloadSignature returns the FNV-1a-32 signature of the
// base64-decoded payload of a stored Kitty transmission, matching the client's
// terminalGraphicsSourceSignature over the same bytes. Returns 0 when there is
// no payload, which never matches a client-reported signature.
//
// A transmission larger than a single APC is split into m=1 continuation chunks
// (Kitty caps each APC payload at 4096 base64 bytes), and a stored image buffer
// concatenates every chunk's full APC. The client appends each chunk's decoded
// payload into one buffer before hashing, so the signature MUST cover the whole
// concatenated payload — hashing only the first chunk would never match a
// multi-chunk image (i.e. every non-trivial screenshot), defeating the switch
// replay skip and forcing the whole image set to be re-sent on every switch.
func kittyTransmissionPayloadSignature(buf []byte) uint32 {
	var payload []byte
	for i := 0; i+2 < len(buf); {
		if buf[i] != '\x1b' || buf[i+1] != '_' || buf[i+2] != 'G' {
			i++
			continue
		}
		apcEnd := kittyApcEnd(buf, i)
		if apcEnd < 0 {
			break
		}
		chunk := buf[i:apcEnd]
		if semi := bytes.IndexByte(chunk, ';'); semi >= 0 {
			body := chunk[semi+1:]
			if end := bytes.Index(body, []byte{'\x1b', '\\'}); end >= 0 {
				body = body[:end]
			}
			if bel := bytes.IndexByte(body, '\a'); bel >= 0 {
				body = body[:bel]
			}
			payload = append(payload, decodeLenientBase64(body)...)
		}
		i = apcEnd
	}
	if len(payload) == 0 {
		return 0
	}
	return fnv32ImageSignature(payload)
}

// fnv32ImageSignature mirrors the client's terminalGraphicsSourceSignature: an
// FNV-1a-32 over the exact length (4 little-endian bytes) plus an evenly-spaced
// sample of at most ~4096 bytes. Returns a non-zero value for non-empty input.
func fnv32ImageSignature(b []byte) uint32 {
	if len(b) == 0 {
		return 0
	}
	const (
		fnvOffset = uint32(0x811c9dc5)
		fnvPrime  = uint32(0x01000193)
	)
	hash := fnvOffset
	length := len(b)
	for i := 0; i < 4; i++ {
		hash = (hash ^ uint32(length&0xFF)) * fnvPrime
		length >>= 8
	}
	step := 1
	if len(b) > 4096 {
		step = len(b) / 4096
	}
	for i := 0; i < len(b); i += step {
		hash = (hash ^ uint32(b[i])) * fnvPrime
	}
	if hash == 0 {
		return 1
	}
	return hash
}

// kittyApcEnd returns the index just past the ST (ESC \) that terminates the
// Kitty APC sequence beginning at start, or -1 if it is incomplete. The base64
// payload never contains ESC, so the first ESC \ after the introducer is the
// terminator.
func kittyApcEnd(data []byte, start int) int {
	for i := start + 3; i+1 < len(data); i++ {
		if data[i] == '\x1b' && data[i+1] == '\\' {
			return i + 2
		}
	}
	return -1
}

// kittyControl returns the control portion (the bytes between "_G" and the ';'
// payload separator, or the ST if there is no payload) of the APC sequence that
// spans [start, end).
func kittyControl(data []byte, start, end int) string {
	from := start + 3
	to := end - 2 // before the terminating ESC \
	if to > len(data) {
		to = len(data)
	}
	if semi := bytes.IndexByte(data[from:to], ';'); semi >= 0 {
		to = from + semi
	}
	if from > to {
		return ""
	}
	return string(data[from:to])
}

// parseKittyControl parses a comma-separated key=value Kitty control string.
func parseKittyControl(control string) map[string]string {
	args := map[string]string{}
	if control == "" {
		return args
	}
	for _, pair := range strings.Split(control, ",") {
		if eq := strings.IndexByte(pair, '='); eq >= 0 {
			args[pair[:eq]] = pair[eq+1:]
		}
	}
	return args
}

// rewriteKittyTransmitAction returns a copy of a single Kitty APC sequence with
// a display transmit (a=T) downgraded to a store-only transmit (a=t) so replay
// never draws or moves the cursor. Other sequences are returned unchanged.
func rewriteKittyTransmitAction(seq []byte) []byte {
	from := 3 // past ESC _ G
	to := len(seq)
	if semi := bytes.IndexByte(seq, ';'); semi >= 0 && semi < to {
		to = semi
	}
	idx := bytes.Index(seq[from:to], []byte("a=T"))
	if idx < 0 {
		return seq
	}
	out := make([]byte, len(seq))
	copy(out, seq)
	out[from+idx+2] = 't'
	return out
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
	case 'q':
		// XTVERSION (CSI > q): the child asks the terminal to identify itself,
		// which agents such as Copilot CLI use to unlock richer rendering. The
		// space-intermediate DECSCUSR cursor-style control (CSI Ps SP q) is not
		// a query. Replaying an already-answered XTVERSION would make the
		// terminal send a second, unsolicited identity report.
		return strings.HasPrefix(params, ">")
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

// isReplayUnsafeOscNotification reports whether payload is a desktop
// notification escape (OSC 9 / 777 / 99). These are transient events, so
// replaying them when a window is reattached would re-fire the notification.
func isReplayUnsafeOscNotification(payload []byte) bool {
	code, rest, ok := strings.Cut(string(payload), ";")
	if !ok {
		return false
	}
	switch code {
	case "99", "777":
		return true
	case "9":
		// iTerm2 notifications are `OSC 9 ; <text>`. ConEmu reuses OSC 9 with a
		// numeric sub-command (9;4 progress, 9;9 working dir, ...); leave those
		// alone since they aren't notifications.
		if first, _, hasSub := strings.Cut(rest, ";"); hasSub {
			if _, err := strconv.Atoi(strings.TrimSpace(first)); err == nil {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func (w *muxWindow) processID() int {
	if w == nil || w.proc == nil {
		return 0
	}
	return w.proc.Pid()
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
	return w.themeHintFocusTransitionLocked() ||
		w.themeHintFocusRefreshLocked() ||
		len(w.themeHintRefreshKeysLocked()) > 0
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
// refreshed replies for previously observed color queries. Focus-aware TUIs
// get a FocusIn nudge so they can re-query colors through the normal path.
// Known agent TUIs also get the default background response they already
// tolerate through the tmux refresh path.
//
// The contractually-correct live-query response path in
// handleWindowOutput still answers OSC 10/11/4/17/19 queries the
// foreground process actually emits. Other focus-aware programs can re-query
// after the FocusIn nudge instead of receiving unsolicited OSC bytes.
func (w *muxWindow) themeHintRefreshKeysLocked() []string {
	if !w.themeRefreshModeActiveLocked() {
		return nil
	}
	return w.activeThemeColorQueryKeysLocked()
}

func (w *muxWindow) themeHintFocusTransitionLocked() bool {
	return (w.themeRefreshModeActiveLocked() && w.focusModeActiveLocked()) ||
		w.agentThemeHintFocusTransitionLocked()
}

func (w *muxWindow) themeHintRefreshDataLocked(themeHint []byte) []byte {
	var refreshKeys []string
	refreshKeys = appendThemeQueryKeys(refreshKeys, w.themeHintRefreshKeysLocked())
	refreshKeys = appendThemeQueryKeys(refreshKeys, w.agentThemeHintRefreshKeysLocked())
	themeHintData := themeHintResponsesForKeys(themeHint, refreshKeys)
	if w.agentThemeHintModeReportLocked() {
		themeHintData = append(terminalThemeModeReportFromHint(themeHint), themeHintData...)
	}
	return themeHintData
}

func (w *muxWindow) themeHintFocusRefreshLocked() bool {
	return w.focusModeActiveLocked()
}

func (w *muxWindow) agentThemeHintFocusTransitionLocked() bool {
	if !w.agentThemeHintRefreshLocked() {
		return false
	}
	switch w.agentToolLocked() {
	case "claude", "gemini", "opencode", "antigravity":
		return true
	default:
		return false
	}
}

func (w *muxWindow) agentThemeHintRefreshKeysLocked() []string {
	if !w.agentThemeHintRefreshLocked() {
		return nil
	}
	return []string{"11"}
}

func (w *muxWindow) agentThemeHintModeReportLocked() bool {
	return w.agentThemeHintRefreshLocked() && w.agentToolLocked() == "copilot"
}

func (w *muxWindow) agentThemeHintRefreshLocked() bool {
	return w.focusModeActiveLocked() && w.agentToolLocked() != ""
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

// agentResumeCommandWithFreshFallback wraps a restored agent's --resume command
// so a resume that exits immediately falls back to launching the agent fresh,
// keeping the restored window alive instead of letting it vanish.
//
// After a MonkeyMux helper upgrade every window is recreated by relaunching its
// foreground process. For an agent this is something like `copilot --resume
// <id>`. When that session can no longer be resumed — a window that never
// committed a session before the restart, a session store that lives on another
// machine, a stale id — the CLI prints an error and exits non-zero (Copilot CLI
// reports "No session, task, or name matched" and exits 1). The window's shell
// then has nothing left to run, so the pane closes and the user loses the whole
// window. Falling back to a fresh launch preserves the window; a successful
// resume runs interactively and only exits when the user quits, so the "||"
// branch is reached solely when the resume itself failed to start. An
// intentional close signals the whole process group (SIGHUP), which terminates
// the shell before it can reach the fallback, so closing a window never
// relaunches the agent.
func agentResumeCommandWithFreshFallback(resume string, launch string) string {
	resume = strings.TrimSpace(resume)
	launch = strings.TrimSpace(launch)
	if resume == "" {
		return launch
	}
	if launch == "" || launch == resume {
		return resume
	}
	return resume + " || " + launch
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

// appendPendingTerminalQueriesLocked scans a chunk of the window's child output
// for terminal capability/status queries (device attributes, DSR, XTVERSION)
// and buffers them in pendingTerminalQueries. It is called only while no
// terminal is showing the window, so these queries are not being forwarded to a
// terminal that could answer them; flushPendingTerminalQueriesLocked re-delivers
// them once one attaches. A query split across pty reads is carried in
// pendingTerminalQueryCarry until the rest arrives. OSC colour/theme queries are
// intentionally ignored here: the server already answers those locally from the
// theme hint (see stripLocallyAnsweredThemeQueriesLocked).
func (w *muxWindow) appendPendingTerminalQueriesLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	data := chunk
	if len(w.pendingTerminalQueryCarry) > 0 {
		combined := make([]byte, 0, len(w.pendingTerminalQueryCarry)+len(chunk))
		combined = append(combined, w.pendingTerminalQueryCarry...)
		combined = append(combined, chunk...)
		data = combined
		w.pendingTerminalQueryCarry = nil
	}
	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return
		}
		if escapeIndex+1 >= len(data) {
			w.storePartialPendingTerminalQueryLocked(data[escapeIndex:])
			return
		}
		if data[escapeIndex+1] != '[' {
			data = data[escapeIndex+1:]
			continue
		}
		end := csiSequenceEnd(data, escapeIndex+2)
		if end < 0 {
			w.storePartialPendingTerminalQueryLocked(data[escapeIndex:])
			return
		}
		sequence := data[escapeIndex : end+1]
		if isReplayUnsafeCsiQuery(sequence) &&
			len(w.pendingTerminalQueries)+len(sequence) <= pendingTerminalQueryLimitBytes {
			w.pendingTerminalQueries = append(w.pendingTerminalQueries, sequence...)
		}
		data = data[end+1:]
	}
}

func (w *muxWindow) storePartialPendingTerminalQueryLocked(data []byte) {
	if len(data) > csiBufferLimitBytes {
		w.pendingTerminalQueryCarry = nil
		return
	}
	w.pendingTerminalQueryCarry = append(w.pendingTerminalQueryCarry[:0], data...)
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
	if mode == "1000" || mode == "1002" || mode == "1003" {
		// Remember which foreground process owns mouse tracking so it can be
		// suppressed once that process is no longer in the foreground. Clear it
		// once no mouse-tracking mode remains enabled.
		if w.reportsMouseWheelRawLocked() {
			if enabled {
				w.mouseTrackingProcessID = w.activeForegroundPidLocked()
			}
		} else {
			w.mouseTrackingProcessID = 0
		}
	}
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

func terminalThemeModeReportFromHint(hint []byte) []byte {
	const darkReport = "\x1b[?997;1n"
	const lightReport = "\x1b[?997;2n"
	darkIndex := bytes.Index(hint, []byte(darkReport))
	lightIndex := bytes.Index(hint, []byte(lightReport))
	if darkIndex < 0 && lightIndex < 0 {
		return nil
	}
	if lightIndex < 0 || (darkIndex >= 0 && darkIndex < lightIndex) {
		return []byte(darkReport)
	}
	return []byte(lightReport)
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
		if window.proc != nil {
			window.proc.Hangup()
		}
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

func inheritedEnvironment(base []string) []string {
	result := make([]string, len(base))
	copy(result, base)
	return result
}

func terminalEnvironment(base []string) []string {
	env := inheritedEnvironment(base)
	env = appendEnvironmentDefault(env, "TERM", "xterm-256color", terminalTermIsUsable)
	env = appendEnvironmentDefault(env, "COLORTERM", "truecolor", terminalColorTermIsTrueColor)
	env = appendEnvironmentDefault(env, "TERM_PROGRAM", "kitty", terminalProgramSupportsInlineImages)
	env = appendEnvironmentDefault(env, "KITTY_WINDOW_ID", "1", terminalEnvironmentValueIsPresent)
	env = appendEnvironmentDefault(env, "FORCE_HYPERLINK", "1", terminalEnvironmentValueIsPresent)
	return env
}

func appendEnvironmentDefault(
	env []string,
	key string,
	value string,
	valid func(string) bool,
) []string {
	prefix := key + "="
	defaultEntry := prefix + value
	replacement := defaultEntry
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) && valid(strings.TrimPrefix(entry, prefix)) {
			replacement = entry
			break
		}
	}

	result := make([]string, 0, len(env)+1)
	inserted := false
	for _, entry := range env {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
			continue
		}
		if !inserted {
			result = append(result, replacement)
			inserted = true
		}
	}
	if !inserted {
		result = append(result, defaultEntry)
	}
	return result
}

func terminalColorTermIsTrueColor(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	return normalized == "truecolor" || normalized == "24bit"
}

func terminalTermIsUsable(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	return normalized != "" && normalized != "dumb"
}

func terminalProgramSupportsInlineImages(value string) bool {
	normalized := strings.TrimSpace(strings.ToLower(value))
	switch normalized {
	case "kitty", "wezterm", "ghostty":
		return true
	default:
		return false
	}
}

func terminalEnvironmentValueIsPresent(value string) bool {
	return strings.TrimSpace(value) != ""
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

// resolveStartupDirectory returns a directory that exists and can be used as a
// new window's working directory. A restored window can reference a directory
// that no longer exists — a git worktree, temp build dir, or scratch checkout
// removed between sessions is common — and starting the PTY there fails with
// "chdir: no such file or directory", which previously dropped the window from
// the restore entirely. To keep every window, fall back to the nearest existing
// ancestor of the requested directory, then the home directory, then the serve
// process's own working directory.
func resolveStartupDirectory(requested string) string {
	candidate := strings.TrimSpace(requested)
	if candidate == "" {
		// No directory requested: preserve the historical behavior of
		// inheriting the serve process's working directory.
		if current, err := os.Getwd(); err == nil && directoryExists(current) {
			return current
		}
		if home, err := os.UserHomeDir(); err == nil && directoryExists(home) {
			return home
		}
		return ""
	}
	if expanded, err := expandHomePath(candidate); err == nil {
		candidate = expanded
	}
	if directoryExists(candidate) {
		return candidate
	}
	// The requested directory is gone. Walk up to the nearest existing ancestor
	// so a removed leaf directory falls back close to where the window used to
	// live, then fall back to home, then the process's own working directory.
	for candidate != "" {
		parent := filepath.Dir(candidate)
		if parent == candidate {
			break
		}
		candidate = parent
		if directoryExists(candidate) {
			return candidate
		}
	}
	if home, err := os.UserHomeDir(); err == nil && directoryExists(home) {
		return home
	}
	if current, err := os.Getwd(); err == nil && directoryExists(current) {
		return current
	}
	return ""
}

func directoryExists(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
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
