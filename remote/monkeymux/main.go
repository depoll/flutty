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
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf16"
	"unicode/utf8"

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
	monkeyMuxVersion                  = "0.1.103"
	defaultColumns                    = 80
	defaultRows                       = 24
	maxTitleBytes                     = 160
	oscBufferLimitBytes               = 4096
	processMetadataTimeout            = 500 * time.Millisecond
	processMetadataInterval           = 500 * time.Millisecond
	runCommandOutputMaxBytes          = 8 * 1024 * 1024
	runCommandTimeout                 = 20 * time.Second
	socketTimeout                     = 2 * time.Second
	attachWriteTimeout                = time.Second
	terminalResponseFocusGrace        = 2 * time.Second
	focusInputCarryDelay              = 75 * time.Millisecond
	foregroundRedrawResizeDelay       = 40 * time.Millisecond
	foregroundRedrawForwardingPause   = foregroundRedrawResizeDelay + 80*time.Millisecond
	windowUpdateMinInterval           = 750 * time.Millisecond
	windowHistoryLimitBytes           = 128 * 1024
	windowFullReplayHistoryLimitBytes = 512 * 1024
	windowReplayLimitBytes            = 32 * 1024
	csiBufferLimitBytes               = 64
	pendingTerminalQueryLimitBytes    = 512
	terminalResponseCarryLimitBytes   = 64 * 1024
	themeHintLimitBytes               = 1024
	restoreFileMode                   = 0o600
	restoreSchemaVersion              = 1
	attachWriteQueueCapacity          = 32
	attachWriteQueueLimitBytes        = 16 * 1024 * 1024
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
	// conPtySwallowedThemeQueryKeys are the theme-query keys whose queries
	// ConPTY consumes inside conhost instead of forwarding out of the pty.
	conPtySwallowedThemeQueryKeys = []string{"10", "11"}
	trackedPrivateModes           = map[string]struct{}{
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
	"multi-client-attach",
	"tmux-prefix-keys",
	"client-scoped-resize",
	"client-focus",
	"client-viewport-clipping",
	"image-replay-ack",
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
	generation := window.resizeGeneration.Add(1)
	temporaryWidth, temporaryHeight, ok := foregroundRedrawTemporarySize(
		width,
		height,
	)
	if ok {
		window.resizePtyIfCurrent(
			generation,
			temporaryWidth,
			temporaryHeight,
		)
		// Leave the PTY at a temporary size long enough for TUIs that ignore
		// same-size SIGWINCH events to observe a real resize before restoring.
		time.AfterFunc(foregroundRedrawResizeDelay, func() {
			window.resizePtyIfCurrent(generation, width, height)
		})
		return
	}
	window.resizePtyIfCurrent(generation, width, height)
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

func (w *muxWindow) resizePty(width int, height int) {
	if w == nil || w.pty == nil || width <= 0 || height <= 0 {
		return
	}
	w.resizeGeneration.Add(1)
	w.ptyResizeMu.Lock()
	_ = w.pty.Resize(width, height)
	w.ptyResizeMu.Unlock()
}

func (w *muxWindow) resizePtyIfCurrent(
	generation uint64,
	width int,
	height int,
) {
	if w == nil || w.pty == nil || width <= 0 || height <= 0 {
		return
	}
	w.ptyResizeMu.Lock()
	defer w.ptyResizeMu.Unlock()
	if w.resizeGeneration.Load() != generation {
		return
	}
	_ = w.pty.Resize(width, height)
}

func (w *muxWindow) closePty(ptyFile muxPty) error {
	if w == nil || ptyFile == nil {
		return nil
	}
	w.resizeGeneration.Add(1)
	w.ptyResizeMu.Lock()
	defer w.ptyResizeMu.Unlock()
	return ptyFile.Close()
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
		"cursor-agent": {
			regexp.MustCompile(`(?:^|\s)--resume(?:=|\s+)(?:"([^"]+)"|'([^']+)'|(\S+))`),
		},
	}
)

type controlMessage struct {
	Role         string   `json:"role,omitempty"`
	ID           string   `json:"id,omitempty"`
	Type         string   `json:"type,omitempty"`
	Session      string   `json:"session,omitempty"`
	ClientID     string   `json:"clientId,omitempty"`
	WindowID     string   `json:"windowId,omitempty"`
	WindowIndex  *int     `json:"windowIndex,omitempty"`
	Name         string   `json:"name,omitempty"`
	Cwd          string   `json:"cwd,omitempty"`
	Command      string   `json:"command,omitempty"`
	Args         []string `json:"args,omitempty"`
	Data         string   `json:"data,omitempty"`
	Width        int      `json:"width,omitempty"`
	Height       int      `json:"height,omitempty"`
	PixelWidth   int      `json:"pixelWidth,omitempty"`
	PixelHeight  int      `json:"pixelHeight,omitempty"`
	Redraw       bool     `json:"redraw,omitempty"`
	NoPrefix     bool     `json:"noPrefix,omitempty"`
	ClipViewport bool     `json:"clipViewport,omitempty"`
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
	ID                 string           `json:"id,omitempty"`
	Type               string           `json:"type"`
	Status             string           `json:"status,omitempty"`
	Error              string           `json:"error,omitempty"`
	Version            string           `json:"version,omitempty"`
	Session            string           `json:"session,omitempty"`
	Capabilities       []string         `json:"capabilities,omitempty"`
	Windows            []windowSnapshot `json:"windows,omitempty"`
	Window             *windowSnapshot  `json:"window,omitempty"`
	CurrentPath        string           `json:"currentPath,omitempty"`
	CurrentCommand     string           `json:"currentCommand,omitempty"`
	Data               string           `json:"data,omitempty"`
	ExitCode           int              `json:"exitCode,omitempty"`
	HasAttach          bool             `json:"hasForegroundClient,omitempty"`
	AttachCount        int              `json:"foregroundClientCount,omitempty"`
	ImageIDs           []string         `json:"imageIds,omitempty"`
	ImagesAcknowledged bool             `json:"imagesAcknowledged,omitempty"`
	FocusChanged       bool             `json:"focusChanged,omitempty"`
	Restore            *serverRestore   `json:"restore,omitempty"`
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
	TerminalBracketedPaste    bool            `json:"terminalBracketedPasteMode,omitempty"`
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
	session         string
	width           int
	height          int
	publishedWidth  int
	publishedHeight int

	mu                      sync.Mutex
	resizeMu                sync.Mutex
	windows                 []*muxWindow
	activeID                string
	lastActiveID            string
	nextID                  int
	listener                net.Listener
	attachConn              net.Conn
	attachMu                sync.Mutex
	attachClients           map[net.Conn]*attachClient
	nextAttachSequence      uint64
	nextFocusSequence       uint64
	pendingFocusRefreshConn net.Conn
	pendingResizeWidth      int
	pendingResizeHeight     int
	pendingResizeRedraw     bool
	controls                map[*controlClient]struct{}
	themeHint               []byte
	closed                  bool

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
	id                          string
	index                       int
	name                        string
	cwd                         string
	command                     string
	agentTool                   string
	foregroundPid               int
	foregroundCommand           string
	paneTitle                   string
	pty                         muxPty
	ptyResizeMu                 sync.Mutex
	resizeGeneration            atomic.Uint64
	proc                        muxProcess
	history                     []byte
	oscBuffer                   []byte
	attachOscBuffer             []byte
	csiBuffer                   []byte
	terminalBellState           terminalBellParserState
	terminalBellBytes           int
	terminalOutputState         terminalOutputParserState
	terminalOutputBytes         int
	terminalOutputUtf8Remaining int
	terminalOutputForwarding    bool
	lastActivity                time.Time
	outputGeneration            uint64
	lastProcessMetadataRefresh  time.Time
	lastBroadcast               time.Time
	cursorVisible               bool
	cursorVisibilityKnown       bool
	// win32InputMode mirrors DEC private mode 9001, which ConPTY (conhost)
	// enables at startup on Windows to request that terminal input — including
	// escape-sequence replies — be delivered as win32-input-mode key events.
	// ConPTY's input parser drops raw OSC/DCS sequences, so synthetic replies
	// written into the window pty must be re-encoded while this mode is on.
	win32InputMode                       bool
	privateModes                         map[string]bool
	insertModeEnabled                    bool
	insertModeKnown                      bool
	applicationKeypadEnabled             bool
	applicationKeypadKnown               bool
	focusModeEnabled                     bool
	focusModeProcessID                   int
	mouseTrackingProcessID               int
	themeRefreshModeProcessID            int
	themeColorQueryPid                   int
	themeColorQueryKeys                  map[string]bool
	alert                                bool
	closed                               bool
	redrawForwardingPaused               bool
	redrawForwardingGeneration           int
	redrawForwardingReplay               []byte
	redrawForwardingBuffer               []byte
	redrawForwardingFailoverBuffer       []byte
	redrawForwardingSecondaryBuffer      []byte
	redrawForwardingQueryBuffer          []byte
	redrawForwardingPrimaryConn          net.Conn
	redrawForwardingPrimaryNeedsFailover bool
	// pendingTerminalQueries holds capability/status queries (device attributes,
	// DSR, XTVERSION) the child emitted while no terminal was showing this window
	// — e.g. an agent (Copilot CLI) relaunched during an upgrade restore, which
	// queries the terminal at startup before the client reattaches. They are
	// stored in history too, but foreground-redraw windows never replay history,
	// so without re-delivering them on attach the terminal never answers and the
	// agent times out into a less rich rendering mode. pendingTerminalQueryCarry
	// holds a query sequence split across pty reads until the rest arrives.
	pendingTerminalQueries         []byte
	pendingTerminalQueriesInFlight []byte
	pendingTerminalQueryCarry      []byte
	secondaryQueryCarry            []byte
	secondaryQueryPrimary          net.Conn
	queryUtf8Remaining             int
	lastForwardedTerminalQueries   []byte
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

type terminalOutputParserState int

const (
	terminalOutputParserGround terminalOutputParserState = iota
	terminalOutputParserEscape
	terminalOutputParserEscapeIntermediate
	terminalOutputParserCsi
	terminalOutputParserOsc
	terminalOutputParserOscEscape
	terminalOutputParserString
	terminalOutputParserStringEscape
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

type attachFocusResult struct {
	focused        bool
	primaryChanged bool
}

type attachWrite struct {
	data             []byte
	complete         chan error
	responseWindowID string
	responseCount    int
	gate             *attachWriteGate
}

type attachWriteGate struct {
	done    chan struct{}
	deliver atomic.Bool
}

type routedTerminalResponse struct {
	windowID string
	data     []byte
}

type attachInputRouting struct {
	claimsFocus bool
	passthrough []byte
	responses   []routedTerminalResponse
}

type attachClient struct {
	conn                               net.Conn
	id                                 string
	width                              int
	height                             int
	terminalWidth                      int
	terminalHeight                     int
	clipViewport                       bool
	sequence                           uint64
	focusSequence                      atomic.Uint64
	prefixEnabled                      bool
	prefixPending                      bool
	confirmCloseID                     string
	inputMu                            sync.Mutex
	activityMu                         sync.Mutex
	terminalResponseUntil              time.Time
	terminalResponseCarry              []byte
	terminalResponseContinuation       byte
	terminalResponseContinuationEscape bool
	terminalResponseContinuationUtf8   int
	terminalResponseWindows            []string
	terminalResponseActiveWindow       string
	terminalResponseCarryGeneration    uint64
	inputUtf8Remaining                 int
	focusInputCarry                    []byte
	focusInputGeneration               uint64
	focusSequenceSnapshot              func() uint64
	focusClaim                         func(uint64)
	inputPassthrough                   func([]byte)
	replayMu                           sync.Mutex
	replayedWindowID                   string
	replayedOutputGeneration           uint64

	queue       chan attachWrite
	done        chan struct{}
	closeOnce   sync.Once
	queueMu     sync.Mutex
	queuedBytes int
	queueClosed bool
}

func main() {
	if len(os.Args) < 2 {
		attachCommand(nil)
		return
	}

	switch os.Args[1] {
	case "attach":
		attachCommand(os.Args[2:])
	case "attach-session", "a", "at":
		attachCommand(os.Args[2:])
	case "new-session", "new":
		newSessionCommand(os.Args[2:])
	case "list-sessions", "ls", "sessions":
		listSessionsCommand(os.Args[2:])
	case "kill-session":
		killSessionCommand(os.Args[2:])
	case "control":
		controlCommand(os.Args[2:])
	case "serve":
		serveCommand(os.Args[2:])
	case "gc":
		gcCommand()
	case "version", "--version", "-v":
		fmt.Println(monkeyMuxVersion)
	case "help", "--help", "-h":
		printUsage(os.Stdout)
	default:
		usageAndExit()
	}
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "MonkeyMux - persistent terminal windows for MonkeySSH")
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "Usage:")
	fmt.Fprintln(writer, "  monkeymux                              attach or choose a session")
	fmt.Fprintln(writer, "  monkeymux attach [-t NAME] [NAME]      attach, creating NAME if needed")
	fmt.Fprintln(writer, "  monkeymux new-session [-d] [-s NAME] [COMMAND...]")
	fmt.Fprintln(writer, "  monkeymux list-sessions")
	fmt.Fprintln(writer, "  monkeymux kill-session -t NAME")
	fmt.Fprintln(writer, "  monkeymux version")
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "Inside a session (prefix Ctrl-B):")
	fmt.Fprintln(writer, "  c       create window       n / p   next / previous window")
	fmt.Fprintln(writer, "  0..9    select window       l       last window")
	fmt.Fprintln(writer, "  &       close window        d       detach this client")
	fmt.Fprintln(writer, "  Ctrl-B  send a literal Ctrl-B")
}

func usageAndExit() {
	printUsage(os.Stderr)
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
	clientID := fs.String("client-id", "", "stable foreground client identifier")
	clipViewport := fs.Bool("clip-viewport", false, "clip a shared terminal grid to this client's viewport")
	noPrefix := fs.Bool("no-prefix", false, "disable Ctrl-B window commands")
	quiet := fs.Bool("quiet", false, "suppress attach and detach messages")
	target := fs.String("t", "", "target session")
	_ = fs.Parse(args)
	if fs.NArg() > 1 || (*target != "" && fs.NArg() != 0) {
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
	session := strings.TrimSpace(*target)
	if fs.NArg() == 1 {
		session = strings.TrimSpace(fs.Arg(0))
	}
	if session == "" {
		session, err = defaultAttachSession(os.Stdin, os.Stderr)
		if err != nil {
			fatal(err)
		}
	}
	if err := validateSessionName(session); err != nil {
		fatal(err)
	}
	resolvedClientID := strings.TrimSpace(*clientID)
	if resolvedClientID == "" {
		resolvedClientID = fmt.Sprintf(
			"cli-%d-%d",
			os.Getpid(),
			time.Now().UnixNano(),
		)
	}
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
		Role:         "attach",
		Session:      session,
		ClientID:     resolvedClientID,
		Width:        width,
		Height:       height,
		Data:         string(themeHint),
		NoPrefix:     *noPrefix,
		ClipViewport: *clipViewport,
	}
	if !*quiet {
		fmt.Fprintf(
			os.Stderr,
			"monkeymux: attached to %s (prefix Ctrl-B; run `monkeymux help` for keys)\r\n",
			session,
		)
	}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	restoreRawTerminal := makeTerminalRaw()
	terminalRestored := false
	restoreTerminal := func() {
		if terminalRestored {
			return
		}
		terminalRestored = true
		restoreRawTerminal()
	}
	defer restoreTerminal()

	stopResize := forwardResizeSignals(session, resolvedClientID)
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

	attachOut := attachOutputWriter(os.Stdout)
	_, copyErr := io.Copy(attachOut, conn)
	// Flush any partial sequence the output filter buffered so trailing bytes are
	// not dropped when the session ends mid-sequence (no-op unless the writer
	// buffers, e.g. the Windows win32-input-mode request stripper).
	if flusher, ok := attachOut.(interface{ Flush() error }); ok {
		_ = flusher.Flush()
	}
	if copyErr != nil && !errors.Is(copyErr, io.EOF) {
		fatal(copyErr)
	}
	restoreTerminal()
	if !*quiet {
		if _, err := queryRunningServerStatus(session); err == nil {
			fmt.Fprintf(os.Stderr, "\r\nmonkeymux: detached from %s\r\n", session)
		} else {
			fmt.Fprintf(os.Stderr, "\r\nmonkeymux: session %s ended\r\n", session)
		}
	}
}

type runningSessionInfo struct {
	name        string
	version     string
	windows     []windowSnapshot
	attachCount int
	lastActive  int64
}

func newSessionCommand(args []string) {
	fs := flag.NewFlagSet("new-session", flag.ExitOnError)
	session := fs.String("s", "main", "session name")
	cwd := fs.String("c", "", "initial working directory")
	name := fs.String("n", "", "initial window name")
	detached := fs.Bool("d", false, "start without attaching")
	attachExisting := fs.Bool("A", false, "attach if the session already exists")
	noPrefix := fs.Bool("no-prefix", false, "disable Ctrl-B window commands")
	quiet := fs.Bool("quiet", false, "suppress attach and detach messages")
	_ = fs.Parse(args)

	target := strings.TrimSpace(*session)
	if err := validateSessionName(target); err != nil {
		fatal(err)
	}
	_, runningErr := queryRunningServerStatus(target)
	if runningErr == nil && !*attachExisting {
		fatal(fmt.Errorf(
			"session %q already exists; use new-session -A or attach",
			target,
		))
	}

	width, height := terminalSize()
	if err := ensureServer(
		target,
		createWindowOptions{
			cwd:  *cwd,
			name: *name,
			args: append([]string(nil), fs.Args()...),
		},
		serverUpdatePolicyPrompt,
		false,
		width,
		height,
	); err != nil {
		fatal(err)
	}
	if *detached {
		if !*quiet {
			fmt.Fprintf(os.Stdout, "monkeymux: session %s started\r\n", target)
		}
		return
	}

	attachArgs := make([]string, 0, 3)
	if *noPrefix {
		attachArgs = append(attachArgs, "--no-prefix")
	}
	if *quiet {
		attachArgs = append(attachArgs, "--quiet")
	}
	attachArgs = append(attachArgs, target)
	attachCommand(attachArgs)
}

func listSessionsCommand(args []string) {
	fs := flag.NewFlagSet("list-sessions", flag.ExitOnError)
	_ = fs.Parse(args)
	if fs.NArg() != 0 {
		usageAndExit()
	}
	sessions, err := listRunningSessions()
	if err != nil {
		fatal(err)
	}
	if len(sessions) == 0 {
		fmt.Fprintln(os.Stdout, "no MonkeyMux sessions")
		return
	}
	sort.Slice(sessions, func(i int, j int) bool {
		return sessions[i].name < sessions[j].name
	})
	for _, session := range sessions {
		active := ""
		for _, window := range session.windows {
			if window.Active {
				active = firstNonEmptyString(
					window.PaneTitle,
					window.Name,
					window.CurrentCommand,
				)
				break
			}
		}
		clientLabel := "clients"
		if session.attachCount == 1 {
			clientLabel = "client"
		}
		fmt.Fprintf(
			os.Stdout,
			"%s: %d windows (%d %s)",
			safeDisplayText(session.name),
			len(session.windows),
			session.attachCount,
			clientLabel,
		)
		if active != "" {
			fmt.Fprintf(os.Stdout, " [active: %s]", safeDisplayText(active))
		}
		fmt.Fprintln(os.Stdout)
	}
}

func killSessionCommand(args []string) {
	fs := flag.NewFlagSet("kill-session", flag.ExitOnError)
	target := fs.String("t", "", "target session")
	_ = fs.Parse(args)
	if fs.NArg() != 0 {
		usageAndExit()
	}
	session := strings.TrimSpace(*target)
	if session == "" {
		sessions, err := listRunningSessions()
		if err != nil {
			fatal(err)
		}
		if len(sessions) != 1 {
			fatal(errors.New("specify a session with -t"))
		}
		session = sessions[0].name
	}
	if err := validateSessionName(session); err != nil {
		fatal(err)
	}
	if _, err := queryRunningServerStatus(session); err != nil {
		fatal(fmt.Errorf("session %q is not running", session))
	}
	requestServerShutdown(session)
	if !waitForServerExit(session, 2*time.Second) {
		fatal(fmt.Errorf("session %q did not stop", session))
	}
	fmt.Fprintf(os.Stdout, "monkeymux: session %s stopped\r\n", safeDisplayText(session))
}

func defaultAttachSession(reader io.Reader, writer io.Writer) (string, error) {
	sessions, err := listRunningSessions()
	if err != nil {
		return "", err
	}
	if len(sessions) == 0 {
		return "main", nil
	}
	if len(sessions) == 1 {
		return sessions[0].name, nil
	}
	sort.Slice(sessions, func(i int, j int) bool {
		if sessions[i].lastActive == sessions[j].lastActive {
			return sessions[i].name < sessions[j].name
		}
		return sessions[i].lastActive > sessions[j].lastActive
	})
	if file, ok := reader.(*os.File); ok && !term.IsTerminal(int(file.Fd())) {
		return "", errors.New("multiple sessions are running; specify one with -t")
	}

	fmt.Fprintln(writer, "MonkeyMux sessions:")
	for index, session := range sessions {
		fmt.Fprintf(
			writer,
			"  %d. %s  %d windows, %d clients\r\n",
			index+1,
			safeDisplayText(session.name),
			len(session.windows),
			session.attachCount,
		)
	}
	fmt.Fprintf(writer, "Attach [1], or enter a new session name: ")
	line, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	selection := strings.TrimSpace(line)
	if selection == "" {
		return sessions[0].name, nil
	}
	if index, parseErr := strconv.Atoi(selection); parseErr == nil {
		if index < 1 || index > len(sessions) {
			return "", fmt.Errorf("session selection %d is out of range", index)
		}
		return sessions[index-1].name, nil
	}
	if err := validateSessionName(selection); err != nil {
		return "", err
	}
	return selection, nil
}

func listRunningSessions() ([]runningSessionInfo, error) {
	runDir, err := runtimeDirectory()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(runDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	sessions := make([]runningSessionInfo, 0)
	for _, entry := range entries {
		if entry.IsDir() ||
			!strings.HasPrefix(entry.Name(), "monkeymux-") ||
			!strings.HasSuffix(entry.Name(), ".sock") {
			continue
		}
		session, err := querySessionAtSocket(filepath.Join(runDir, entry.Name()))
		if err != nil || strings.TrimSpace(session.name) == "" {
			continue
		}
		sessions = append(sessions, session)
	}
	return sessions, nil
}

func querySessionAtSocket(path string) (runningSessionInfo, error) {
	conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
	if err != nil {
		return runningSessionInfo{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))
	if err := json.NewEncoder(conn).Encode(controlMessage{Role: "control"}); err != nil {
		return runningSessionInfo{}, err
	}

	decoder := json.NewDecoder(conn)
	info := runningSessionInfo{}
	for info.name == "" || info.windows == nil {
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			return runningSessionInfo{}, err
		}
		switch response.Type {
		case "hello":
			info.name = response.Session
			info.version = response.Version
			info.attachCount = response.AttachCount
		case "window_list":
			info.windows = response.Windows
			for _, window := range response.Windows {
				if window.LastActivityEpochSeconds > info.lastActive {
					info.lastActive = window.LastActivityEpochSeconds
				}
			}
		}
	}
	return info, nil
}

func validateSessionName(value string) error {
	if strings.TrimSpace(value) == "" {
		return errors.New("session name cannot be empty")
	}
	if len(value) > 128 {
		return errors.New("session name is too long")
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return errors.New("session name cannot contain control characters")
		}
	}
	return nil
}

func safeDisplayText(value string) string {
	return strings.Map(func(character rune) rune {
		if character < 0x20 || character == 0x7f {
			return -1
		}
		return character
	}, value)
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
	argsBase64 := fs.String("args-base64", "", "base64-encoded initial argv")
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
	initialArgs, err := decodeArgsBase64(*argsBase64)
	if err != nil {
		fatal(err)
	}
	if err := serveSession(*session, createWindowOptions{
		cwd:       *cwd,
		name:      *name,
		command:   *command,
		args:      initialArgs,
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

func decodeArgsBase64(encoded string) ([]string, error) {
	encoded = strings.TrimSpace(encoded)
	if encoded == "" {
		return nil, nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid initial argv: %w", err)
	}
	if len(decoded) > 1024*1024 {
		return nil, errors.New("initial argv is too large")
	}
	var args []string
	if err := json.Unmarshal(decoded, &args); err != nil {
		return nil, fmt.Errorf("invalid initial argv: %w", err)
	}
	if len(args) > 4096 {
		return nil, errors.New("initial argv has too many arguments")
	}
	return args, nil
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
	if len(initialWindow.args) > 0 {
		encodedArgs, err := json.Marshal(initialWindow.args)
		if err != nil {
			return err
		}
		serveArgs = append(
			serveArgs,
			"--args-base64",
			base64.StdEncoding.EncodeToString(encodedArgs),
		)
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
	if window.TerminalBracketedPaste {
		modes["2004"] = true
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
	hasCursorWindows := false
	for _, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) != "" {
			continue
		}
		tool := agentToolForRestore(window)
		if tool == "antigravity" {
			hasAntigravityWindows = true
		}
		if tool == "cursor-agent" {
			hasCursorWindows = true
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
	cursorSessions := map[int]string{}
	if hasCursorWindows {
		cursorSessions = discoverCursorSessionIDs(restore)
	}
	if len(panePids) == 0 {
		for i, sessionID := range antigravitySessions {
			restore.Windows[i].AgentSessionID = sessionID
		}
		for i, sessionID := range cursorSessions {
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
		if tool == "cursor-agent" {
			if sessionID := cursorSessions[i]; sessionID != "" {
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

// ── Cursor Agent ─────────────────────────────────────────────────────────────
// Cursor persists chats under ~/.cursor/chats/<workspaceHash>/<chatId>/meta.json.
// A fresh `cursor-agent` launch carries no resumable id in its process args, so
// after a MonkeyMux helper update recreates its windows the id is recovered from
// the chat store keyed by the pane's working directory (matching meta.json cwd).

type cursorChatEntry struct {
	chatID    string
	cwd       string
	updatedAt int64
}

func discoverCursorSessionIDs(restore *serverRestore) map[int]string {
	entries := readCursorChatEntries()
	if len(entries) == 0 {
		return nil
	}
	latestSessionID := latestCursorSessionID(entries)
	needsFallback := cursorRestoreWindowCount(restore) == 1
	sessions := map[int]string{}
	for i, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) != "" ||
			agentToolForRestore(window) != "cursor-agent" {
			continue
		}
		if sessionID := cursorSessionIDForWorkspace(entries, window.Cwd); sessionID != "" {
			sessions[i] = sessionID
			continue
		}
		if needsFallback && latestSessionID != "" {
			sessions[i] = latestSessionID
		}
	}
	return sessions
}

func cursorRestoreWindowCount(restore *serverRestore) int {
	if restore == nil {
		return 0
	}
	count := 0
	for _, window := range restore.Windows {
		if strings.TrimSpace(window.AgentSessionID) == "" &&
			agentToolForRestore(window) == "cursor-agent" {
			count++
		}
	}
	return count
}

// readCursorChatEntries reads recent Cursor chat metadata, ordered oldest to
// newest so the newest match wins a reverse scan.
func readCursorChatEntries() []cursorChatEntry {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	chatsRoot := filepath.Join(home, ".cursor", "chats")
	workspaceDirs, err := os.ReadDir(chatsRoot)
	if err != nil {
		return nil
	}
	entries := []cursorChatEntry{}
	for _, workspaceDir := range workspaceDirs {
		if !workspaceDir.IsDir() {
			continue
		}
		chatDirs, err := os.ReadDir(filepath.Join(chatsRoot, workspaceDir.Name()))
		if err != nil {
			continue
		}
		for _, chatDir := range chatDirs {
			if !chatDir.IsDir() {
				continue
			}
			metaPath := filepath.Join(
				chatsRoot,
				workspaceDir.Name(),
				chatDir.Name(),
				"meta.json",
			)
			if entry, ok := readCursorChatMeta(metaPath, chatDir.Name()); ok {
				entries = append(entries, entry)
			}
		}
	}
	sort.SliceStable(entries, func(a, b int) bool {
		return entries[a].updatedAt < entries[b].updatedAt
	})
	return entries
}

func readCursorChatMeta(path string, chatID string) (cursorChatEntry, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return cursorChatEntry{}, false
	}
	var raw struct {
		Cwd             string `json:"cwd"`
		UpdatedAtMs     int64  `json:"updatedAtMs"`
		CreatedAtMs     int64  `json:"createdAtMs"`
		HasConversation *bool  `json:"hasConversation"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return cursorChatEntry{}, false
	}
	if raw.HasConversation != nil && !*raw.HasConversation {
		return cursorChatEntry{}, false
	}
	sessionID := strings.TrimSpace(chatID)
	if sessionID == "" {
		return cursorChatEntry{}, false
	}
	updatedAt := raw.UpdatedAtMs
	if updatedAt == 0 {
		updatedAt = raw.CreatedAtMs
	}
	return cursorChatEntry{
		chatID:    sessionID,
		cwd:       normalizedCursorWorkspacePath(raw.Cwd),
		updatedAt: updatedAt,
	}, true
}

func latestCursorSessionID(entries []cursorChatEntry) string {
	for i := len(entries) - 1; i >= 0; i-- {
		if sessionID := strings.TrimSpace(entries[i].chatID); sessionID != "" {
			return sessionID
		}
	}
	return ""
}

func cursorSessionIDForWorkspace(entries []cursorChatEntry, workspace string) string {
	normalizedWorkspace := normalizedCursorWorkspacePath(workspace)
	if normalizedWorkspace == "" {
		return ""
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if entries[i].cwd == normalizedWorkspace {
			return entries[i].chatID
		}
	}
	return ""
}

func normalizedCursorWorkspacePath(value string) string {
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
		session:         session,
		width:           width,
		height:          height,
		publishedWidth:  width,
		publishedHeight: height,
		attachClients:   map[net.Conn]*attachClient{},
		controls:        map[*controlClient]struct{}{},
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
func (s *muxServer) scheduleRestoreRedrawFollowUps(windowID string) {
	s.mu.Lock()
	hasAttach := s.attachCountLocked() > 0
	s.mu.Unlock()
	if !hasAttach || !s.takeRestoreRedrawPending(windowID) {
		return
	}
	for _, delay := range restoreRedrawFollowUpDelays {
		scheduleRestoreRedraw(delay, func() {
			s.redrawRestoredWindow(windowID)
		})
	}
}

func (s *muxServer) redrawRestoredWindow(windowID string) {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	if s.attachCountLocked() == 0 || s.activeID != windowID {
		s.mu.Unlock()
		return
	}
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed || !window.usesForegroundRedrawReplayLocked() {
		s.mu.Unlock()
		return
	}
	width, height := s.primaryAttachSizeLocked()
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
	var replay []byte
	var snapshots []windowSnapshot
	var addedSnapshot *windowSnapshot
	var foregroundProcessGroup int
	var refreshPendingFocus bool
	var refreshPendingResize bool
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
	// Keep agent windows open when the agent exits abnormally right after
	// launching, so a fast startup failure (for example a locked macOS login
	// keychain that makes cursor-agent print an error and exit immediately)
	// stays on screen instead of the window closing before it can be read.
	if len(options.args) == 0 &&
		strings.TrimSpace(options.command) != "" &&
		agentTool != "" {
		cmd = shellCommandForScript(
			shell,
			holdAgentWindowCommand(shell, strings.TrimSpace(options.command)),
		)
	}
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
	cols, rows := s.publishedWidth, s.publishedHeight
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
	if s.activeID != "" && s.activeID != window.id {
		s.lastActiveID = s.activeID
	}
	s.activeID = window.id
	// Seed the Kitty image cache from any restored history so an image shown
	// before a server restart can still be replayed on the next reattach.
	if window.observeKittyGraphicsLocked(window.history) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	s.clearAlertsLocked(window.id)
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	snapshots = s.snapshotsLocked()
	addedSnapshot = snapshotByID(snapshots, window.id)
	refreshPendingFocus =
		s.pendingFocusRefreshConn != nil &&
			s.pendingFocusRefreshConn == s.attachConn
	refreshPendingResize =
		s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0
	s.mu.Unlock()

	s.attachMu.Lock()
	redrew := s.broadcastAttachReplayAndResizeLocked(replay, window)
	s.attachMu.Unlock()
	if refreshPendingFocus || refreshPendingResize {
		s.refreshPendingClientViewport(refreshPendingFocus, refreshPendingResize)
	}
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
	var failoverForwarded []byte
	var secondaryForwarded []byte
	var terminalQueries []byte
	var themeHint []byte
	var themeHintData []byte
	var shouldWrite bool
	var refreshPendingFocus bool
	var refreshPendingResize bool
	var snapshot *windowSnapshot
	var maxAttachSequence uint64
	var outputGeneration uint64
	now := time.Now()

	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return
	}
	window.terminalOutputForwarding =
		s.activeID == windowID && s.attachCountLocked() > 0
	before := window.broadcastIdentityLocked()
	wasAlert := window.alert
	window.lastActivity = now
	window.refreshProcessMetadataLocked(now)
	// Modes are observed before metadata so a `CSI ? 9001 h` arriving in the
	// same chunk as a colour query is already reflected when the query is
	// answered below (and when the answer is encoded in writeWindow).
	window.observeTerminalModesLocked(chunk)
	queryKeys := window.observeTerminalMetadataLocked(chunk)
	terminalBell := window.observeTerminalBellLocked(chunk)
	window.observeTerminalOutputStateLocked(chunk)
	if len(queryKeys) > 0 && len(s.themeHint) > 0 {
		themeHint = append([]byte(nil), s.themeHint...)
		themeHintData = themeHintResponsesForKeys(themeHint, queryKeys)
	}
	window.appendHistoryLocked(chunk)
	window.outputGeneration++
	outputGeneration = window.outputGeneration
	if window.observeKittyGraphicsLocked(chunk) {
		s.enforceGlobalKittyImageBudgetLocked()
	}
	if s.activeID == windowID {
		attach = s.attachConn
		shouldWrite = s.attachCountLocked() > 0
		maxAttachSequence = s.nextAttachSequence
	} else if terminalBell {
		window.alert = true
	}
	forwarded = window.stripLocallyAnsweredThemeQueriesLocked(chunk, themeHint)
	if !shouldWrite {
		// No terminal is showing this window, so its capability queries will not
		// be forwarded and answered. Buffer them so they can be delivered — and
		// answered — once a terminal attaches or the window is selected.
		if len(window.secondaryQueryCarry) > 0 {
			forwarded = append(
				append([]byte(nil), window.secondaryQueryCarry...),
				forwarded...,
			)
			window.secondaryQueryCarry = nil
			window.secondaryQueryPrimary = nil
		}
		window.appendPendingTerminalQueriesLocked(forwarded)
	} else if len(window.pendingTerminalQueryCarry) > 0 {
		forwarded = append(
			append([]byte(nil), window.pendingTerminalQueryCarry...),
			forwarded...,
		)
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
		hadQueryCarry := len(window.secondaryQueryCarry) > 0
		queryCarry := append([]byte(nil), window.secondaryQueryCarry...)
		queryPrimaryMissing := false
		if hadQueryCarry && window.secondaryQueryPrimary != nil {
			if s.isAttachConnectionLocked(window.secondaryQueryPrimary) {
				attach = window.secondaryQueryPrimary
			} else {
				queryPrimaryMissing = true
			}
		}
		secondaryForwarded = window.secondaryAttachOutputLocked(forwarded)
		terminalQueries = append(
			terminalQueries,
			window.lastForwardedTerminalQueries...,
		)
		failoverForwarded = forwarded
		if hadQueryCarry {
			failoverForwarded = append(queryCarry, forwarded...)
		}
		if queryPrimaryMissing && !window.redrawForwardingPaused {
			forwarded = append(queryCarry, forwarded...)
		} else if queryPrimaryMissing {
			attach = s.attachConn
			window.redrawForwardingPrimaryConn = attach
			window.redrawForwardingPrimaryNeedsFailover = true
		} else if window.redrawForwardingPaused &&
			hadQueryCarry &&
			window.redrawForwardingPrimaryConn != attach {
			window.redrawForwardingPrimaryConn = attach
		}
		if len(window.secondaryQueryCarry) > 0 {
			if !hadQueryCarry || queryPrimaryMissing {
				window.secondaryQueryPrimary = attach
			}
		} else {
			window.secondaryQueryPrimary = nil
		}
		if len(forwarded) > 0 && window.redrawForwardingPaused {
			window.redrawForwardingBuffer = append(
				window.redrawForwardingBuffer,
				forwarded...,
			)
			window.redrawForwardingFailoverBuffer = append(
				window.redrawForwardingFailoverBuffer,
				failoverForwarded...,
			)
			window.redrawForwardingSecondaryBuffer = append(
				window.redrawForwardingSecondaryBuffer,
				secondaryForwarded...,
			)
			window.redrawForwardingQueryBuffer = append(
				window.redrawForwardingQueryBuffer,
				terminalQueries...,
			)
			shouldWrite = false
			forwarded = nil
			secondaryForwarded = nil
			terminalQueries = nil
		}
	}
	s.mu.Unlock()

	if len(themeHintData) > 0 {
		_ = s.writeWindow(windowID, themeHintData)
	}

	if shouldWrite {
		if len(forwarded) > 0 {
			s.writeAttachOutputIfActive(
				windowID,
				attach,
				forwarded,
				failoverForwarded,
				secondaryForwarded,
				terminalQueries,
				maxAttachSequence,
				outputGeneration,
			)
		}
	}
	s.mu.Lock()
	window = s.windowByIDLocked(windowID)
	if window != nil && !window.closed {
		window.terminalOutputForwarding = false
		refreshPendingFocus =
			s.pendingFocusRefreshConn != nil &&
				s.pendingFocusRefreshConn == s.attachConn &&
				len(window.secondaryQueryCarry) == 0 &&
				window.queryUtf8Remaining == 0 &&
				window.terminalOutputIsGroundLocked() &&
				!window.redrawForwardingPaused
		refreshPendingResize =
			s.pendingResizeWidth > 0 &&
				s.pendingResizeHeight > 0 &&
				terminalViewportTransitionSafe(window)
	}
	s.mu.Unlock()

	if snapshot != nil {
		s.broadcast(controlResponse{
			Type:    "window_updated",
			Session: s.session,
			Window:  snapshot,
		})
	}
	if refreshPendingFocus || refreshPendingResize {
		s.refreshPendingClientViewport(refreshPendingFocus, refreshPendingResize)
	}
}

func (s *muxServer) markWindowClosed(windowID string) {
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var windowPty muxPty
	var resetViewportParser bool

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
	if s.lastActiveID == windowID {
		s.lastActiveID = ""
	}
	// Capture the pty and close it after releasing s.mu (see below): on Windows
	// muxPty.Close() calls ClosePseudoConsole, which blocks until the output
	// pipe is drained by readWindow -> handleWindowOutput, and that reader needs
	// s.mu. Closing under the lock would deadlock the whole server.
	windowPty = window.pty
	s.reindexWindowsLocked()
	if s.activeID == windowID {
		resetViewportParser =
			s.pendingFocusRefreshConn != nil ||
				(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
		s.activeID = ""
		s.pendingFocusRefreshConn = nil
		for _, candidate := range s.windows {
			if !candidate.closed {
				s.activeID = candidate.id
				candidate.alert = false
				s.pendingResizeWidth = 0
				s.pendingResizeHeight = 0
				s.pendingResizeRedraw = false
				if resetViewportParser {
					s.enqueueAttachViewportResizeAfterResetLocked(
						s.width,
						s.height,
					)
				} else {
					s.enqueueAttachViewportResizeLocked(s.width, s.height)
				}
				s.publishedWidth = s.width
				s.publishedHeight = s.height
				s.resizeActiveLocked(s.width, s.height)
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
		redrew = s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
	}
	s.attachMu.Unlock()

	// Now that s.mu/s.attachMu are released, tear down the pty. On Windows this
	// blocks until readWindow drains the final ConPTY output (which needs s.mu),
	// so it must happen after unlocking.
	if windowPty != nil {
		_ = window.closePty(windowPty)
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

func newAttachClient(conn net.Conn, hello controlMessage) *attachClient {
	clientID := strings.TrimSpace(hello.ClientID)
	if clientID == "" {
		clientID = fmt.Sprintf("client-%d-%d", os.Getpid(), time.Now().UnixNano())
	}
	terminalWidth := hello.Width
	terminalHeight := hello.Height
	if hello.ClipViewport {
		// A clipping-aware client starts unconfirmed so the server always sends
		// the initial canonical grid, even when it matches the client's viewport.
		terminalWidth = 0
		terminalHeight = 0
	}
	client := &attachClient{
		conn:           conn,
		id:             clientID,
		width:          hello.Width,
		height:         hello.Height,
		terminalWidth:  terminalWidth,
		terminalHeight: terminalHeight,
		clipViewport:   hello.ClipViewport,
		prefixEnabled:  !hello.NoPrefix,
		queue:          make(chan attachWrite, attachWriteQueueCapacity),
		done:           make(chan struct{}),
	}
	go client.writeLoop()
	return client
}

func (c *attachClient) writeLoop() {
	defer c.failQueuedWrites(io.ErrClosedPipe)
	for {
		select {
		case write := <-c.queue:
			if write.gate != nil {
				select {
				case <-write.gate.done:
					if !write.gate.deliver.Load() {
						c.finishQueuedWrite(write, nil)
						continue
					}
				case <-c.done:
					c.finishQueuedWrite(write, io.ErrClosedPipe)
					return
				}
			}
			if write.responseWindowID != "" && write.responseCount > 0 {
				c.expectTerminalResponses(
					write.responseWindowID,
					write.responseCount,
				)
			}
			_ = c.conn.SetWriteDeadline(time.Now().Add(attachWriteTimeout))
			err := writeConnection(c.conn, write.data)
			_ = c.conn.SetWriteDeadline(time.Time{})
			c.finishQueuedWrite(write, err)
			if err != nil {
				c.close()
				return
			}
		case <-c.done:
			return
		}
	}
}

func (c *attachClient) finishQueuedWrite(write attachWrite, err error) {
	c.queueMu.Lock()
	c.queuedBytes -= len(write.data)
	c.queueMu.Unlock()
	if write.complete != nil {
		write.complete <- err
		close(write.complete)
	}
}

func (c *attachClient) failQueuedWrites(err error) {
	for {
		select {
		case write := <-c.queue:
			c.finishQueuedWrite(write, err)
		default:
			return
		}
	}
}

func writeConnection(conn net.Conn, data []byte) error {
	for len(data) > 0 {
		written, err := conn.Write(data)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[written:]
	}
	return nil
}

func (c *attachClient) enqueue(data []byte, wait bool) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, "", 0, nil)
}

func (c *attachClient) enqueueTerminalQuery(
	data []byte,
	wait bool,
	windowID string,
	responseCount int,
) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, windowID, responseCount, nil)
}

func (c *attachClient) enqueueConditionalTerminalQuery(
	data []byte,
	wait bool,
	windowID string,
	responseCount int,
	gate *attachWriteGate,
) (<-chan error, bool) {
	return c.enqueueWrite(data, wait, windowID, responseCount, gate)
}

func (c *attachClient) enqueueWrite(
	data []byte,
	wait bool,
	responseWindowID string,
	responseCount int,
	gate *attachWriteGate,
) (<-chan error, bool) {
	if len(data) == 0 {
		return nil, true
	}
	if len(data) > attachWriteQueueLimitBytes {
		c.close()
		return nil, false
	}
	write := attachWrite{
		data:             append([]byte(nil), data...),
		responseWindowID: responseWindowID,
		responseCount:    responseCount,
		gate:             gate,
	}
	if wait {
		write.complete = make(chan error, 1)
	}
	c.queueMu.Lock()
	queueClosed := c.queueClosed
	if queueClosed ||
		c.queuedBytes+len(write.data) > attachWriteQueueLimitBytes {
		c.queueMu.Unlock()
		if !queueClosed {
			c.close()
		}
		return nil, false
	}
	c.queuedBytes += len(write.data)
	select {
	case c.queue <- write:
		c.queueMu.Unlock()
		return write.complete, true
	default:
		c.queuedBytes -= len(write.data)
		c.queueMu.Unlock()
		c.close()
		return nil, false
	}
}

func (c *attachClient) waitForWrite(completion <-chan error) bool {
	if completion == nil {
		return true
	}
	err, ok := <-completion
	return ok && err == nil
}

func (c *attachClient) close() {
	c.closeOnce.Do(func() {
		c.queueMu.Lock()
		c.queueClosed = true
		close(c.done)
		c.queueMu.Unlock()
		_ = c.conn.Close()
	})
}

func (c *attachClient) markOutputReplay(windowID string, generation uint64) {
	c.replayMu.Lock()
	c.replayedWindowID = windowID
	c.replayedOutputGeneration = generation
	c.replayMu.Unlock()
}

func (c *attachClient) clearOutputReplay() {
	c.replayMu.Lock()
	c.replayedWindowID = ""
	c.replayedOutputGeneration = 0
	c.replayMu.Unlock()
}

func (c *attachClient) suppressesReplayedOutput(
	windowID string,
	generation uint64,
) bool {
	if generation == 0 {
		return false
	}
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if c.replayedWindowID != windowID {
		return false
	}
	if generation <= c.replayedOutputGeneration {
		return true
	}
	c.replayedWindowID = ""
	c.replayedOutputGeneration = 0
	return false
}

func (c *attachClient) expectTerminalResponse(windowID string) {
	c.expectTerminalResponses(windowID, 1)
}

func (c *attachClient) expectTerminalResponses(windowID string, count int) {
	if c == nil || windowID == "" {
		return
	}
	if count < 1 {
		count = 1
	}
	now := time.Now()
	var expiredInput []byte
	var expiredFocusSequence uint64
	var claim func(uint64)
	var passthrough func([]byte)
	inputLocked := false
	c.activityMu.Lock()
	if !c.terminalResponseUntil.IsZero() &&
		now.After(c.terminalResponseUntil) {
		if len(c.terminalResponseCarry) > 0 {
			c.inputMu.Lock()
			inputLocked = true
			expiredInput = append(
				expiredInput,
				c.terminalResponseCarry...,
			)
			if c.focusSequenceSnapshot != nil {
				expiredFocusSequence = c.focusSequenceSnapshot()
			}
			claim = c.focusClaim
			passthrough = c.inputPassthrough
		}
		c.resetTerminalResponseStateLocked()
	}
	c.terminalResponseUntil = now.Add(terminalResponseFocusGrace)
	for range count {
		c.terminalResponseWindows = append(
			c.terminalResponseWindows,
			windowID,
		)
	}
	if len(c.terminalResponseCarry) > 0 {
		c.scheduleTerminalResponseCarryLocked()
	}
	c.activityMu.Unlock()
	if !inputLocked {
		return
	}
	defer c.inputMu.Unlock()
	select {
	case <-c.done:
		return
	default:
	}
	if claim != nil {
		claim(expiredFocusSequence)
	}
	if passthrough != nil {
		passthrough(expiredInput)
	}
}

func (c *attachClient) inputClaimsFocus(data []byte) bool {
	return c.routeInput(data).claimsFocus
}

func (c *attachClient) routeInput(data []byte) attachInputRouting {
	result := attachInputRouting{passthrough: data}
	if c == nil || len(data) == 0 {
		return result
	}
	c.activityMu.Lock()
	defer c.activityMu.Unlock()
	previousInputUtf8Remaining := c.inputUtf8Remaining
	leadingInputUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousInputUtf8Remaining,
	)
	c.inputUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousInputUtf8Remaining,
		leadingInputUtf8Prefix,
	)
	now := time.Now()
	if !c.terminalResponseUntil.IsZero() &&
		now.After(c.terminalResponseUntil) {
		userInput := data
		if len(c.terminalResponseCarry) > 0 {
			userInput = make(
				[]byte,
				0,
				len(c.terminalResponseCarry)+len(data),
			)
			userInput = append(userInput, c.terminalResponseCarry...)
			userInput = append(userInput, data...)
		}
		c.resetTerminalResponseStateLocked()
		c.routeUserInputLocked(userInput, &result)
		return result
	}
	if !c.hasExpectedTerminalResponseLocked() &&
		len(c.terminalResponseCarry) == 0 {
		c.routeUserInputLocked(data, &result)
		return result
	}

	responseInput := data
	combined := responseInput
	responseLeadingUtf8Prefix := leadingInputUtf8Prefix
	if c.terminalResponseContinuation != 0 {
		responseLeadingUtf8Prefix = 0
		remaining, complete, trailingEscape, utf8Remaining :=
			consumeTerminalResponseContinuation(
				responseInput,
				c.terminalResponseContinuation,
				c.terminalResponseContinuationEscape,
				c.terminalResponseContinuationUtf8,
			)
		c.terminalResponseContinuationEscape = trailingEscape
		c.terminalResponseContinuationUtf8 = utf8Remaining
		windowID := c.currentTerminalResponseWindowLocked()
		if !complete {
			c.renewTerminalResponseDeadlineLocked()
			result.passthrough = nil
			result.responses = append(
				result.responses,
				routedTerminalResponse{
					windowID: windowID,
					data:     append([]byte(nil), responseInput...),
				},
			)
			return result
		}
		consumed := len(responseInput) - len(remaining)
		if consumed > 0 {
			result.responses = append(
				result.responses,
				routedTerminalResponse{
					windowID: windowID,
					data: append(
						[]byte(nil),
						responseInput[:consumed]...,
					),
				},
			)
		}
		c.finishTerminalResponseLocked()
		if c.hasExpectedTerminalResponseLocked() {
			c.renewTerminalResponseDeadlineLocked()
		}
		c.terminalResponseContinuation = 0
		c.terminalResponseContinuationEscape = false
		c.terminalResponseContinuationUtf8 = 0
		if len(remaining) == 0 {
			result.passthrough = nil
			return result
		}
		combined = remaining
		responseInput = remaining
	}
	if len(c.terminalResponseCarry) > 0 {
		responseLeadingUtf8Prefix = 0
		combined = make(
			[]byte,
			0,
			len(c.terminalResponseCarry)+len(responseInput),
		)
		combined = append(combined, c.terminalResponseCarry...)
		combined = append(combined, responseInput...)
		c.terminalResponseCarry = nil
		c.terminalResponseCarryGeneration++
	}
	responseEnds, incompleteStart, continuation, passthroughStart :=
		scanTerminalResponseInput(combined, responseLeadingUtf8Prefix)
	responseStart := 0
	for _, responseEnd := range responseEnds {
		if !c.hasExpectedTerminalResponseLocked() {
			passthroughStart = responseStart
			incompleteStart = -1
			break
		}
		windowID := c.currentTerminalResponseWindowLocked()
		result.responses = append(
			result.responses,
			routedTerminalResponse{
				windowID: windowID,
				data: append(
					[]byte(nil),
					combined[responseStart:responseEnd]...,
				),
			},
		)
		c.finishTerminalResponseSequenceLocked(
			windowID,
			combined[responseStart:responseEnd],
		)
		if c.hasExpectedTerminalResponseLocked() {
			c.renewTerminalResponseDeadlineLocked()
		}
		responseStart = responseEnd
	}
	if incompleteStart >= 0 {
		if !c.hasExpectedTerminalResponseLocked() {
			c.routeUserInputLocked(combined[responseStart:], &result)
			return result
		}
		incomplete := combined[incompleteStart:]
		c.renewTerminalResponseDeadlineLocked()
		if len(incomplete) <= terminalResponseCarryLimitBytes {
			c.storeTerminalResponseCarryLocked(incomplete)
		} else if continuation != 0 {
			windowID := c.currentTerminalResponseWindowLocked()
			c.terminalResponseContinuation = continuation
			c.terminalResponseContinuationEscape =
				incomplete[len(incomplete)-1] == '\x1b'
			c.terminalResponseContinuationUtf8 =
				trailingUtf8ContinuationCount(incomplete)
			result.responses = append(
				result.responses,
				routedTerminalResponse{
					windowID: windowID,
					data:     append([]byte(nil), incomplete...),
				},
			)
		}
		result.passthrough = nil
		return result
	}
	if passthroughStart >= len(combined) {
		result.passthrough = nil
		return result
	}
	c.routeUserInputLocked(combined[passthroughStart:], &result)
	return result
}

func (c *attachClient) routeUserInputLocked(
	data []byte,
	result *attachInputRouting,
) {
	result.passthrough = data
	if len(data) == 0 {
		return
	}
	c.focusInputGeneration++
	focusGeneration := c.focusInputGeneration
	combinedFocusInput := data
	if len(c.focusInputCarry) > 0 {
		combinedFocusInput = make(
			[]byte,
			0,
			len(c.focusInputCarry)+len(data),
		)
		combinedFocusInput = append(combinedFocusInput, c.focusInputCarry...)
		combinedFocusInput = append(combinedFocusInput, data...)
		c.focusInputCarry = nil
	}
	filteredInput, focusCarry := stripFocusOutInput(combinedFocusInput)
	c.focusInputCarry = append(c.focusInputCarry[:0], focusCarry...)
	if len(c.focusInputCarry) > 0 {
		focusSequence := uint64(0)
		if c.focusSequenceSnapshot != nil {
			focusSequence = c.focusSequenceSnapshot()
		}
		time.AfterFunc(focusInputCarryDelay, func() {
			c.resolveAmbiguousFocusInput(focusGeneration, focusSequence)
		})
	}
	result.claimsFocus = len(filteredInput) > 0
}

func (c *attachClient) hasExpectedTerminalResponseLocked() bool {
	return c.terminalResponseActiveWindow != "" ||
		len(c.terminalResponseWindows) > 0
}

func (c *attachClient) resetTerminalResponseStateLocked() {
	c.terminalResponseCarry = nil
	c.terminalResponseCarryGeneration++
	c.terminalResponseContinuation = 0
	c.terminalResponseContinuationEscape = false
	c.terminalResponseContinuationUtf8 = 0
	c.terminalResponseWindows = nil
	c.terminalResponseActiveWindow = ""
	c.terminalResponseUntil = time.Time{}
}

func (c *attachClient) renewTerminalResponseDeadlineLocked() {
	c.terminalResponseUntil = time.Now().Add(terminalResponseFocusGrace)
	if len(c.terminalResponseCarry) > 0 {
		c.scheduleTerminalResponseCarryLocked()
	}
}

func (c *attachClient) storeTerminalResponseCarryLocked(
	data []byte,
) {
	c.terminalResponseCarry = append(c.terminalResponseCarry[:0], data...)
	c.scheduleTerminalResponseCarryLocked()
}

func (c *attachClient) scheduleTerminalResponseCarryLocked() {
	c.terminalResponseCarryGeneration++
	generation := c.terminalResponseCarryGeneration
	focusSequence := uint64(0)
	if c.focusSequenceSnapshot != nil {
		focusSequence = c.focusSequenceSnapshot()
	}
	delay := time.Until(c.terminalResponseUntil)
	if delay < 0 {
		delay = 0
	}
	time.AfterFunc(delay, func() {
		c.resolveAmbiguousTerminalResponseInput(generation, focusSequence)
	})
}

func (c *attachClient) resolveAmbiguousTerminalResponseInput(
	generation uint64,
	focusSequence uint64,
) {
	c.activityMu.Lock()
	if c.terminalResponseCarryGeneration != generation ||
		len(c.terminalResponseCarry) == 0 {
		c.activityMu.Unlock()
		return
	}
	c.inputMu.Lock()
	data := append([]byte(nil), c.terminalResponseCarry...)
	c.terminalResponseCarry = nil
	c.terminalResponseCarryGeneration++
	if !c.terminalResponseUntil.IsZero() &&
		time.Now().After(c.terminalResponseUntil) {
		c.resetTerminalResponseStateLocked()
	}
	claim := c.focusClaim
	passthrough := c.inputPassthrough
	c.activityMu.Unlock()
	defer c.inputMu.Unlock()

	select {
	case <-c.done:
		return
	default:
	}
	if claim != nil {
		claim(focusSequence)
	}
	if passthrough != nil {
		passthrough(data)
	}
}

func (c *attachClient) currentTerminalResponseWindowLocked() string {
	if c.terminalResponseActiveWindow != "" {
		return c.terminalResponseActiveWindow
	}
	if len(c.terminalResponseWindows) == 0 {
		return ""
	}
	c.terminalResponseActiveWindow = c.terminalResponseWindows[0]
	c.terminalResponseWindows = c.terminalResponseWindows[1:]
	return c.terminalResponseActiveWindow
}

func (c *attachClient) finishTerminalResponseLocked() {
	c.terminalResponseActiveWindow = ""
	if len(c.terminalResponseWindows) == 0 {
		c.terminalResponseUntil = time.Time{}
	}
}

func (c *attachClient) finishTerminalResponseSequenceLocked(
	windowID string,
	sequence []byte,
) {
	c.finishTerminalResponseLocked()
	remaining := terminalResponseSequenceExpectationCount(sequence) - 1
	for remaining > 0 &&
		len(c.terminalResponseWindows) > 0 &&
		c.terminalResponseWindows[0] == windowID {
		c.terminalResponseWindows = c.terminalResponseWindows[1:]
		remaining--
	}
	if len(c.terminalResponseWindows) == 0 {
		c.terminalResponseUntil = time.Time{}
	}
}

func (c *attachClient) resolveAmbiguousFocusInput(
	generation uint64,
	focusSequence uint64,
) {
	c.activityMu.Lock()
	if c.focusInputGeneration != generation || len(c.focusInputCarry) == 0 {
		c.activityMu.Unlock()
		return
	}
	c.focusInputCarry = nil
	c.focusInputGeneration++
	claim := c.focusClaim
	c.activityMu.Unlock()
	if claim != nil {
		claim(focusSequence)
	}
}

func (s *muxServer) primaryAttachSizeLocked() (int, int) {
	width := s.width
	height := s.height
	client := s.primaryAttachClientLocked()
	if client == nil {
		return width, height
	}
	if client.width > 0 {
		width = client.width
	}
	if client.height > 0 {
		height = client.height
	}
	return width, height
}

func (s *muxServer) hasViewportClippingClientLocked() bool {
	for _, client := range s.attachClients {
		if client.clipViewport {
			return true
		}
	}
	return false
}

func terminalViewportTransitionSafe(window *muxWindow) bool {
	return window == nil ||
		window.closed ||
		(!window.terminalOutputForwarding &&
			!window.redrawForwardingPaused &&
			len(window.secondaryQueryCarry) == 0 &&
			window.queryUtf8Remaining == 0 &&
			window.terminalOutputIsGroundLocked())
}

func (s *muxServer) primaryAttachClientLocked() *attachClient {
	return s.attachClients[s.attachConn]
}

func (s *muxServer) attachClientByIDLocked(clientID string) *attachClient {
	normalizedID := strings.TrimSpace(clientID)
	if normalizedID == "" {
		return s.primaryAttachClientLocked()
	}
	var matched *attachClient
	for _, client := range s.attachClients {
		if client.id != normalizedID {
			continue
		}
		if matched == nil || client.sequence > matched.sequence {
			matched = client
		}
	}
	return matched
}

func moreRecentlyFocusedAttachClient(
	first *attachClient,
	second *attachClient,
) bool {
	firstFocus := first.focusSequence.Load()
	secondFocus := second.focusSequence.Load()
	if firstFocus != secondFocus {
		return firstFocus > secondFocus
	}
	return first.sequence > second.sequence
}

func (s *muxServer) isAttachConnectionLocked(conn net.Conn) bool {
	if conn == nil {
		return false
	}
	if len(s.attachClients) == 0 {
		return s.attachConn == conn
	}
	_, ok := s.attachClients[conn]
	return ok
}

func (s *muxServer) attachCountLocked() int {
	if len(s.attachClients) > 0 {
		return len(s.attachClients)
	}
	if s.attachConn != nil {
		return 1
	}
	return 0
}

func (s *muxServer) promoteAttachClient(client *attachClient) {
	s.focusAttachClient(client, 0, 0, true)
}

func (s *muxServer) focusSequenceSnapshot() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.nextFocusSequence
}

func (s *muxServer) focusAttachClientIfUnchanged(
	client *attachClient,
	expectedFocusSequence uint64,
) bool {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	if client == nil {
		return false
	}
	s.mu.Lock()
	if s.nextFocusSequence != expectedFocusSequence {
		s.mu.Unlock()
		return false
	}
	registered := s.attachClients[client.conn]
	if registered == nil {
		s.mu.Unlock()
		return false
	}
	primaryChanged := s.attachConn != registered.conn
	if primaryChanged {
		s.pendingFocusRefreshConn = nil
	}
	s.nextFocusSequence++
	registered.focusSequence.Store(s.nextFocusSequence)
	s.attachConn = registered.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	sizeChanged :=
		targetWidth != s.publishedWidth ||
			targetHeight != s.publishedHeight
	s.mu.Unlock()
	s.applyFocusedClientViewport(
		registered,
		targetWidth,
		targetHeight,
		sizeChanged,
		primaryChanged,
	)
	return true
}

func (s *muxServer) focusAttachClientByID(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) bool {
	return s.focusAttachClientByIDWithResult(
		clientID,
		width,
		height,
		forceRedraw,
	).focused
}

func (s *muxServer) focusAttachClientByIDWithResult(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) attachFocusResult {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	client := s.attachClientByIDLocked(clientID)
	s.mu.Unlock()
	return s.focusAttachClientLocked(client, width, height, forceRedraw)
}

func (s *muxServer) focusAttachClient(
	client *attachClient,
	width int,
	height int,
	forceRedraw bool,
) bool {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	return s.focusAttachClientLocked(
		client,
		width,
		height,
		forceRedraw,
	).focused
}

func (s *muxServer) focusAttachClientLocked(
	client *attachClient,
	width int,
	height int,
	forceRedraw bool,
) attachFocusResult {
	if client == nil {
		return attachFocusResult{}
	}
	s.mu.Lock()
	registered := s.attachClients[client.conn]
	if registered == nil {
		s.mu.Unlock()
		return attachFocusResult{}
	}
	if width > 0 {
		registered.width = width
	}
	if height > 0 {
		registered.height = height
	}
	primaryChanged := s.attachConn != registered.conn
	if primaryChanged {
		s.pendingFocusRefreshConn = nil
	}
	s.nextFocusSequence++
	registered.focusSequence.Store(s.nextFocusSequence)
	s.attachConn = registered.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	sizeChanged :=
		targetWidth != s.publishedWidth ||
			targetHeight != s.publishedHeight
	s.mu.Unlock()
	s.applyFocusedClientViewport(
		registered,
		targetWidth,
		targetHeight,
		sizeChanged,
		primaryChanged && forceRedraw,
	)
	return attachFocusResult{
		focused:        true,
		primaryChanged: primaryChanged,
	}
}

func (s *muxServer) applyFocusedClientViewport(
	client *attachClient,
	width int,
	height int,
	sizeChanged bool,
	refreshOnHandoff bool,
) {
	if refreshOnHandoff {
		s.replayFocusedWindowToClient(client, width, height)
		return
	}
	if sizeChanged {
		s.resizeWithRedraw(width, height, false)
	}
}

func (s *muxServer) refreshPendingFocusedClient() {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	conn := s.pendingFocusRefreshConn
	if conn == nil {
		s.mu.Unlock()
		return
	}
	s.pendingFocusRefreshConn = nil
	client := s.attachClients[conn]
	if client == nil || s.attachConn != conn {
		s.mu.Unlock()
		return
	}
	width, height := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	s.replayFocusedWindowToClient(client, width, height)
}

func (s *muxServer) refreshPendingClientViewport(
	refreshFocus bool,
	refreshResize bool,
) {
	if refreshFocus {
		s.refreshPendingFocusedClient()
	}
	if refreshResize {
		s.refreshPendingViewportResize()
	}
}

func (s *muxServer) removeAttachClient(client *attachClient) {
	if client == nil {
		return
	}
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	var width int
	var height int
	var sizeChanged bool
	var primaryRemoved bool
	s.mu.Lock()
	if _, ok := s.attachClients[client.conn]; !ok {
		s.mu.Unlock()
		client.close()
		return
	}
	delete(s.attachClients, client.conn)
	if s.pendingFocusRefreshConn == client.conn {
		s.pendingFocusRefreshConn = nil
	}
	if s.attachConn == client.conn {
		primaryRemoved = true
		s.attachConn = nil
		var replacement *attachClient
		for _, candidate := range s.attachClients {
			if replacement == nil ||
				candidate.focusSequence.Load() >
					replacement.focusSequence.Load() ||
				(candidate.focusSequence.Load() ==
					replacement.focusSequence.Load() &&
					candidate.sequence > replacement.sequence) {
				replacement = candidate
			}
		}
		if replacement != nil {
			s.attachConn = replacement.conn
		}
	}
	width, height = s.primaryAttachSizeLocked()
	if primaryRemoved {
		s.pendingResizeWidth = 0
		s.pendingResizeHeight = 0
		s.pendingResizeRedraw = false
		if s.attachConn == nil {
			width = s.publishedWidth
			height = s.publishedHeight
		}
		s.width = width
		s.height = height
	}
	sizeChanged =
		width != s.publishedWidth ||
			height != s.publishedHeight
	s.mu.Unlock()
	client.close()
	if sizeChanged {
		s.resizeWithRedraw(width, height, false)
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
	client := newAttachClient(conn, hello)
	client.focusSequenceSnapshot = s.focusSequenceSnapshot
	client.focusClaim = func(expectedFocusSequence uint64) {
		s.focusAttachClientIfUnchanged(client, expectedFocusSequence)
	}
	client.inputPassthrough = func(data []byte) {
		_ = s.handleAttachInput(client, data)
	}
	s.resizeMu.Lock()
	s.attachMu.Lock()
	s.mu.Lock()
	if s.attachClients == nil {
		s.attachClients = map[net.Conn]*attachClient{}
	}
	s.nextAttachSequence++
	client.sequence = s.nextAttachSequence
	s.nextFocusSequence++
	client.focusSequence.Store(s.nextFocusSequence)
	s.attachClients[conn] = client
	s.attachConn = conn
	if themeHint := themeHintDataFromString(hello.Data); len(themeHint) > 0 {
		s.themeHint = append(s.themeHint[:0], themeHint...)
	}
	width, height := s.primaryAttachSizeLocked()
	window := s.windowByIDLocked(s.activeID)
	if width > 0 &&
		height > 0 &&
		terminalViewportTransitionSafe(window) {
		s.pendingFocusRefreshConn = nil
		s.pendingResizeWidth = 0
		s.pendingResizeHeight = 0
		s.pendingResizeRedraw = false
		s.width = width
		s.height = height
		s.enqueueAttachViewportResizeLocked(width, height)
		s.publishedWidth = width
		s.publishedHeight = height
		s.resizeActiveLocked(width, height)
	} else if width > 0 && height > 0 {
		s.width = width
		s.height = height
		s.pendingFocusRefreshConn = conn
		s.enqueueAttachViewportResizeLocked(
			s.publishedWidth,
			s.publishedHeight,
		)
	} else {
		s.pendingFocusRefreshConn = nil
	}
	replay = s.activeReplayLocked()
	if window != nil {
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

	completion, queued := client.enqueue(replay, true)
	s.attachMu.Unlock()
	s.resizeMu.Unlock()
	if queued {
		queued = client.waitForWrite(completion)
	}
	s.attachMu.Lock()
	redrew := false
	if queued {
		redrew = s.simulateForegroundResizeIfAttached(conn, redrawWindow)
	}
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
	s.scheduleRestoreRedrawFollowUps(activeWindowID)

	defer func() {
		s.removeAttachClient(client)
	}()

	buf := make([]byte, 32*1024)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			routing := client.routeInput(buf[:n])
			if routing.claimsFocus {
				s.promoteAttachClient(client)
			}
			for _, response := range routing.responses {
				if response.windowID == "" {
					s.writeActiveFromAttach(response.data)
					continue
				}
				_ = s.writeWindow(response.windowID, response.data)
			}
			if len(routing.passthrough) > 0 &&
				s.handleAttachInputSerialized(client, routing.passthrough) {
				return
			}
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
		AttachCount:  s.attachCount(),
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
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
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
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		clientImages := request.HaveImageSignatures
		if !s.canUseClientImageSignatures(request.ClientID) {
			clientImages = nil
		}
		if err := s.selectWindowWithSkip(id, clientImages); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_selected", Status: "ok"})
	case "request_images":
		served := s.replayRequestedImages(request.ClientID, request.ImageIDs)
		client.send(controlResponse{
			ID:                 request.ID,
			Type:               "images_replayed",
			Status:             "ok",
			ImageIDs:           served,
			ImagesAcknowledged: true,
		})
	case "close_window", "kill_window":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
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
		s.resizeForClient(
			request.ClientID,
			request.Width,
			request.Height,
			request.Redraw,
		)
		client.send(controlResponse{ID: request.ID, Type: "resized", Status: "ok"})
	case "focus_client":
		if strings.TrimSpace(request.ClientID) == "" {
			client.sendError(request, errors.New("missing client id"))
			return
		}
		if request.Width <= 0 || request.Height <= 0 {
			client.sendError(request, errors.New("invalid terminal size"))
			return
		}
		result := s.focusAttachClientByIDWithResult(
			request.ClientID,
			request.Width,
			request.Height,
			request.Redraw,
		)
		if !result.focused {
			client.sendError(request, errors.New("foreground client is not attached"))
			return
		}
		client.send(controlResponse{
			ID:           request.ID,
			Type:         "client_focused",
			Status:       "ok",
			FocusChanged: result.primaryChanged,
		})
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
		hasAttach := s.hasAttachClient()
		if strings.TrimSpace(request.ClientID) != "" {
			hasAttach = s.hasAttachClientByID(request.ClientID)
		}
		client.send(controlResponse{
			ID:          request.ID,
			Type:        "attach_state",
			Status:      "ok",
			Session:     s.session,
			HasAttach:   hasAttach,
			AttachCount: s.attachCount(),
		})
	case "run_command":
		if strings.TrimSpace(request.Command) == "" {
			client.sendError(request, errors.New("missing command"))
			return
		}
		client.runShellCommandAsync(s, request)
	case "inject_input":
		s.focusAttachClientByID(request.ClientID, 0, 0, false)
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
		s.focusAttachClientByID(request.ClientID, request.Width, request.Height, false)
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
	return s.attachCountLocked() > 0
}

func (s *muxServer) hasAttachClientByID(clientID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attachClientByIDLocked(clientID) != nil
}

func (s *muxServer) attachCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attachCountLocked()
}

func (s *muxServer) canUseClientImageSignatures(clientID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() != 1 {
		return false
	}
	if len(s.attachClients) == 0 {
		return true
	}
	normalizedID := strings.TrimSpace(clientID)
	if normalizedID == "" {
		return true
	}
	for _, client := range s.attachClients {
		return client.id == normalizedID
	}
	return false
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
		TerminalBracketedPaste:    window.privateModes["2004"],
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
// Served ids are returned only after the attach write completes, which applies
// backpressure between the client's bounded repair batches.
func (s *muxServer) replayRequestedImages(
	clientID string,
	ids []string,
) []string {
	if len(ids) == 0 {
		return nil
	}
	var attach net.Conn
	var client *attachClient
	var payload []byte
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return nil
	}
	attach = s.attachConn
	if normalizedID := strings.TrimSpace(clientID); normalizedID != "" {
		client = s.attachClientByIDLocked(normalizedID)
		attach = nil
		if client != nil {
			attach = client.conn
		}
	} else {
		client = s.attachClients[attach]
	}
	if attach == nil {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return nil
	}
	payload, ids = window.kittyImageTransmissionsForLocked(ids)
	s.mu.Unlock()
	if len(payload) == 0 {
		s.attachMu.Unlock()
		return nil
	}
	if client != nil {
		completion, queued := client.enqueue(payload, true)
		s.attachMu.Unlock()
		if !queued || !client.waitForWrite(completion) {
			return nil
		}
		return ids
	}
	queued := s.writeAttachLocked(attach, payload)
	s.attachMu.Unlock()
	if !queued {
		return nil
	}
	return ids
}

// selectWindowWithSkip activates a window and streams its reattach replay,
// omitting retained Kitty images the client reports already holding in
// clientHas (nil replays every retained image).
func (s *muxServer) selectWindowWithSkip(
	windowID string,
	clientHas map[string]uint32,
) error {
	var replay []byte
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var primary net.Conn
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	resetViewportParser :=
		s.pendingFocusRefreshConn != nil ||
			(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
	if s.activeID != windowID {
		s.lastActiveID = s.activeID
		s.activeID = windowID
	}
	window.alert = false
	s.pendingFocusRefreshConn = nil
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	if resetViewportParser {
		s.enqueueAttachViewportResizeAfterResetLocked(s.width, s.height)
	} else {
		s.enqueueAttachViewportResizeLocked(s.width, s.height)
	}
	s.publishedWidth = s.width
	s.publishedHeight = s.height
	s.resizeActiveLocked(s.width, s.height)
	if s.attachCountLocked() > 1 {
		clientHas = nil
	}
	primary = s.attachConn
	replay = s.replayBytesLockedWithSkip(window, clientHas)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	redrawWindow = window
	s.mu.Unlock()
	redrew := s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
	s.flushPendingTerminalQueriesLocked(primary, windowID)
	s.attachMu.Unlock()
	s.broadcastWindowList("active_window_changed")
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	s.scheduleRestoreRedrawFollowUps(windowID)
	return nil
}

func (s *muxServer) closeWindow(windowID string) (bool, error) {
	var replay []byte
	var activeChanged bool
	var foregroundProcessGroup int
	var redrawWindow *muxWindow
	var redrew bool
	var shouldShutdown bool
	var process muxProcess
	var windowPty muxPty
	var snapshots []windowSnapshot
	var resetViewportParser bool

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
		resetViewportParser =
			s.pendingFocusRefreshConn != nil ||
				(s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0)
		replacement := s.replacementWindowForClosedLocked(window)
		if replacement != nil {
			s.activeID = replacement.id
			s.pendingFocusRefreshConn = nil
			replacement.alert = false
			s.pendingResizeWidth = 0
			s.pendingResizeHeight = 0
			s.pendingResizeRedraw = false
			if resetViewportParser {
				s.enqueueAttachViewportResizeAfterResetLocked(
					s.width,
					s.height,
				)
			} else {
				s.enqueueAttachViewportResizeLocked(s.width, s.height)
			}
			s.publishedWidth = s.width
			s.publishedHeight = s.height
			s.resizeActiveLocked(s.width, s.height)
			replay = s.replayBytesLocked(replacement)
			foregroundProcessGroup = replacement.foregroundProcessGroupLocked()
			redrawWindow = replacement
			activeChanged = true
		} else {
			s.activeID = ""
			s.pendingFocusRefreshConn = nil
		}
	}
	window.closed = true
	window.alert = false
	if s.lastActiveID == windowID {
		s.lastActiveID = ""
	}
	process = window.proc
	windowPty = window.pty
	s.reindexWindowsLocked()
	snapshots = s.snapshotsLocked()
	shouldShutdown = openCount <= 1 || len(snapshots) == 0
	s.mu.Unlock()
	if activeChanged {
		redrew = s.broadcastAttachReplayAndResizeLocked(replay, redrawWindow)
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
		_ = window.closePty(windowPty)
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

func (s *muxServer) resizeForClient(
	clientID string,
	width int,
	height int,
	forceRedraw bool,
) {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	if len(s.attachClients) == 0 {
		s.mu.Unlock()
		if strings.TrimSpace(clientID) == "" {
			s.resizeWithRedraw(width, height, forceRedraw)
		}
		return
	}

	client := s.attachClientByIDLocked(clientID)
	if client == nil {
		s.mu.Unlock()
		return
	}
	client.width = width
	client.height = height
	isPrimary := s.attachConn == client.conn
	targetWidth, targetHeight := s.primaryAttachSizeLocked()
	s.mu.Unlock()
	if isPrimary {
		s.resizeWithRedraw(targetWidth, targetHeight, forceRedraw)
	}
}

func (s *muxServer) resizeWithRedraw(width int, height int, forceRedraw bool) {
	var attach net.Conn
	var modeReplay []byte
	var foregroundProcessGroup int
	var shouldSignal bool

	s.mu.Lock()
	serializeViewport := s.hasViewportClippingClientLocked()
	s.mu.Unlock()
	if serializeViewport {
		s.attachMu.Lock()
		defer s.attachMu.Unlock()
	}

	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	if serializeViewport && !terminalViewportTransitionSafe(window) {
		s.width = width
		s.height = height
		s.pendingResizeWidth = width
		s.pendingResizeHeight = height
		s.pendingResizeRedraw = s.pendingResizeRedraw || forceRedraw
		s.mu.Unlock()
		return
	}
	hadPendingResize :=
		s.pendingResizeWidth > 0 && s.pendingResizeHeight > 0
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	sizeChanged :=
		s.width != width ||
			s.height != height ||
			s.publishedWidth != width ||
			s.publishedHeight != height ||
			hadPendingResize
	s.width = width
	s.height = height
	if sizeChanged && serializeViewport {
		s.enqueueAttachViewportResizeLocked(width, height)
	}
	s.publishedWidth = width
	s.publishedHeight = height
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
	if serializeViewport {
		if attach != nil {
			s.writeAllAttachesLocked(modeReplay)
		}
	} else {
		s.writeAttach(attach, modeReplay)
	}
	if shouldSignal {
		signalForegroundResize(foregroundProcessGroup)
	}
}

func (s *muxServer) refreshPendingViewportResize() {
	s.resizeMu.Lock()
	defer s.resizeMu.Unlock()
	s.mu.Lock()
	width := s.pendingResizeWidth
	height := s.pendingResizeHeight
	forceRedraw := s.pendingResizeRedraw
	s.mu.Unlock()
	if width <= 0 || height <= 0 {
		return
	}
	s.resizeWithRedraw(width, height, forceRedraw)
}

func (s *muxServer) resizeActiveLocked(width int, height int) {
	window := s.windowByIDLocked(s.activeID)
	s.resizeWindowLocked(window, width, height)
}

func (s *muxServer) resizeWindowLocked(window *muxWindow, width int, height int) {
	if window == nil || window.closed || window.pty == nil {
		return
	}
	window.resizePty(width, height)
}

func (s *muxServer) writeAttachReplayAndResizeLocked(
	conn net.Conn,
	replay []byte,
	window *muxWindow,
) bool {
	s.writeAttachLocked(conn, replay)
	return s.simulateForegroundResizeIfAttached(conn, window)
}

func (s *muxServer) broadcastAttachReplayAndResizeLocked(
	replay []byte,
	window *muxWindow,
) bool {
	if s.deferAttachReplayForRedrawLocked(replay, window) {
		return true
	}
	s.writeAllAttachesLocked(replay)
	return s.simulateForegroundResizeIfAnyAttached(window)
}

func (s *muxServer) deferAttachReplayForRedrawLocked(
	replay []byte,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() == 0 ||
		window == nil ||
		window.closed ||
		!window.usesForegroundRedrawReplayLocked() {
		return false
	}
	if _, _, ok := foregroundRedrawTemporarySize(
		s.publishedWidth,
		s.publishedHeight,
	); !ok {
		return false
	}
	// Foreground-redraw panes repaint in response to the synthetic resize. Keep
	// the reset replay with that repaint so attach clients never paint the
	// intermediate cleared/stale frame.
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	window.redrawForwardingReplay = append(
		window.redrawForwardingReplay[:0],
		replay...,
	)
	simulateForegroundResize(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) simulateForegroundResizeIfAttached(
	conn net.Conn,
	window *muxWindow,
) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.isAttachConnectionLocked(conn) || window == nil || window.closed {
		return false
	}
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	simulateForegroundResize(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) simulateForegroundResizeIfAnyAttached(window *muxWindow) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attachCountLocked() == 0 || window == nil || window.closed {
		return false
	}
	s.pauseAttachForwardingForRedrawLocked(
		window,
		s.publishedWidth,
		s.publishedHeight,
	)
	simulateForegroundResize(window, s.publishedWidth, s.publishedHeight)
	return true
}

func (s *muxServer) pauseAttachForwardingForRedrawLocked(
	window *muxWindow,
	width int,
	height int,
) {
	if window == nil ||
		window.closed ||
		s.attachCountLocked() == 0 ||
		!window.usesForegroundRedrawReplayLocked() {
		return
	}
	if _, _, ok := foregroundRedrawTemporarySize(width, height); !ok {
		return
	}
	preservedQueries := append(
		[]byte(nil),
		window.redrawForwardingQueryBuffer...,
	)
	preservedPrimary := window.redrawForwardingPrimaryConn
	window.redrawForwardingBuffer = append(
		window.redrawForwardingBuffer[:0],
		preservedQueries...,
	)
	window.redrawForwardingFailoverBuffer = append(
		window.redrawForwardingFailoverBuffer[:0],
		preservedQueries...,
	)
	window.redrawForwardingSecondaryBuffer = nil
	window.redrawForwardingQueryBuffer = append(
		window.redrawForwardingQueryBuffer[:0],
		preservedQueries...,
	)
	if len(preservedQueries) > 0 &&
		s.isAttachConnectionLocked(preservedPrimary) {
		window.redrawForwardingPrimaryConn = preservedPrimary
	} else {
		window.redrawForwardingPrimaryConn = s.attachConn
	}
	window.redrawForwardingPrimaryNeedsFailover =
		len(preservedQueries) > 0 &&
			!s.isAttachConnectionLocked(preservedPrimary)
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
	var replay []byte
	var buffered []byte
	var failoverBuffered []byte
	var secondaryBuffered []byte
	var queryData []byte
	var primary net.Conn
	var primaryNeedsFailover bool
	var clients []*attachClient
	var legacy net.Conn
	var refreshPendingFocus bool
	var refreshPendingResize bool
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil ||
		window.closed ||
		!window.redrawForwardingPaused ||
		window.redrawForwardingGeneration != generation {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	replay = append([]byte(nil), window.redrawForwardingReplay...)
	buffered = append([]byte(nil), window.redrawForwardingBuffer...)
	failoverBuffered = append(
		[]byte(nil),
		window.redrawForwardingFailoverBuffer...,
	)
	secondaryBuffered = append(
		[]byte(nil),
		window.redrawForwardingSecondaryBuffer...,
	)
	queryData = append([]byte(nil), window.redrawForwardingQueryBuffer...)
	primary = window.redrawForwardingPrimaryConn
	if !s.isAttachConnectionLocked(primary) {
		primary = s.attachConn
		primaryNeedsFailover = true
	}
	primaryNeedsFailover =
		primaryNeedsFailover || window.redrawForwardingPrimaryNeedsFailover
	window.redrawForwardingReplay = nil
	window.redrawForwardingBuffer = nil
	window.redrawForwardingFailoverBuffer = nil
	window.redrawForwardingSecondaryBuffer = nil
	window.redrawForwardingQueryBuffer = nil
	window.redrawForwardingPrimaryConn = nil
	window.redrawForwardingPrimaryNeedsFailover = false
	window.redrawForwardingPaused = false
	refreshPendingFocus =
		s.pendingFocusRefreshConn != nil &&
			s.pendingFocusRefreshConn == s.attachConn &&
			len(window.secondaryQueryCarry) == 0 &&
			window.queryUtf8Remaining == 0 &&
			window.terminalOutputIsGroundLocked()
	refreshPendingResize =
		s.pendingResizeWidth > 0 &&
			s.pendingResizeHeight > 0 &&
			terminalViewportTransitionSafe(window)
	if s.activeID == windowID {
		clients = make([]*attachClient, 0, len(s.attachClients))
		for _, client := range s.attachClients {
			clients = append(clients, client)
		}
		if len(clients) == 0 {
			legacy = s.attachConn
		}
	}
	s.mu.Unlock()
	primaryOutput := append(replay, buffered...)
	failoverOutput := append(
		append([]byte(nil), replay...),
		failoverBuffered...,
	)
	secondaryOutput := append(append([]byte(nil), replay...), secondaryBuffered...)
	if legacy != nil {
		s.writeAttachLocked(legacy, primaryOutput)
		s.attachMu.Unlock()
		return
	}
	var primaryClient *attachClient
	for _, client := range clients {
		if client.conn == primary {
			primaryClient = client
			break
		}
	}
	var deliveredPrimary *attachClient
	if len(queryData) > 0 {
		type queryFallback struct {
			client              *attachClient
			queryCompletion     <-chan error
			queryGate           *attachWriteGate
			secondaryOutputGate *attachWriteGate
		}
		responseCount := terminalQueryResponseCount(queryData)
		initialOutput := primaryOutput
		if primaryNeedsFailover {
			initialOutput = failoverOutput
		}
		var primaryCompletion <-chan error
		primaryQueued := false
		if primaryClient != nil {
			primaryCompletion, primaryQueued =
				primaryClient.enqueueTerminalQuery(
					initialOutput,
					true,
					windowID,
					responseCount,
				)
		}
		sortedClients := append([]*attachClient(nil), clients...)
		sort.Slice(sortedClients, func(i int, j int) bool {
			return moreRecentlyFocusedAttachClient(
				sortedClients[i],
				sortedClients[j],
			)
		})
		fallbacks := make([]queryFallback, 0, len(sortedClients))
		for _, client := range sortedClients {
			if client == primaryClient {
				continue
			}
			queryGate := &attachWriteGate{done: make(chan struct{})}
			queryCompletion, queued :=
				client.enqueueConditionalTerminalQuery(
					failoverOutput,
					true,
					windowID,
					responseCount,
					queryGate,
				)
			if !queued {
				continue
			}
			fallback := queryFallback{
				client:          client,
				queryCompletion: queryCompletion,
				queryGate:       queryGate,
			}
			if len(secondaryOutput) > 0 {
				secondaryGate := &attachWriteGate{done: make(chan struct{})}
				if _, queued := client.enqueueWrite(
					secondaryOutput,
					false,
					"",
					0,
					secondaryGate,
				); queued {
					fallback.secondaryOutputGate = secondaryGate
				}
			}
			fallbacks = append(fallbacks, fallback)
		}
		s.attachMu.Unlock()
		primaryDelivered := primaryQueued &&
			primaryClient.waitForWrite(primaryCompletion)
		for _, fallback := range fallbacks {
			tryFallback := !primaryDelivered
			fallback.queryGate.deliver.Store(tryFallback)
			close(fallback.queryGate.done)
			if tryFallback &&
				fallback.client.waitForWrite(fallback.queryCompletion) {
				primaryDelivered = true
			}
			if fallback.secondaryOutputGate != nil {
				fallback.secondaryOutputGate.deliver.Store(!tryFallback)
				close(fallback.secondaryOutputGate.done)
			}
		}
		if !primaryDelivered {
			s.redeliverTerminalQueries(
				windowID,
				queryData,
				nil,
				nil,
			)
		}
		if refreshPendingFocus || refreshPendingResize {
			go s.refreshPendingClientViewport(
				refreshPendingFocus,
				refreshPendingResize,
			)
		}
		return
	}
	if primaryClient != nil {
		_, queued := primaryClient.enqueue(primaryOutput, false)
		if queued {
			deliveredPrimary = primaryClient
		}
	}
	if deliveredPrimary == nil {
		sort.Slice(clients, func(i int, j int) bool {
			return moreRecentlyFocusedAttachClient(clients[i], clients[j])
		})
		for _, client := range clients {
			if client == primaryClient {
				continue
			}
			_, queued := client.enqueue(failoverOutput, false)
			if !queued {
				continue
			}
			deliveredPrimary = client
			break
		}
	}
	for _, client := range clients {
		if client == deliveredPrimary || len(secondaryOutput) == 0 {
			continue
		}
		_, _ = client.enqueue(secondaryOutput, false)
	}
	if refreshPendingFocus || refreshPendingResize {
		go s.refreshPendingClientViewport(
			refreshPendingFocus,
			refreshPendingResize,
		)
	}
	s.attachMu.Unlock()
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
	if len(data) == 0 {
		return
	}
	s.attachMu.Lock()
	s.writeAllAttachesLocked(data)
	s.attachMu.Unlock()
}

func (s *muxServer) writeAttachLocked(conn net.Conn, data []byte) bool {
	if conn == nil || len(data) == 0 {
		return false
	}
	s.mu.Lock()
	client := s.attachClients[conn]
	legacy := len(s.attachClients) == 0 && s.attachConn == conn
	s.mu.Unlock()
	if client != nil {
		_, queued := client.enqueue(data, false)
		return queued
	}
	if !legacy {
		return false
	}
	err := writeConnection(conn, data)
	if err != nil {
		s.mu.Lock()
		if s.attachConn == conn {
			s.attachConn = nil
		}
		s.mu.Unlock()
		return false
	}
	return true
}

func (s *muxServer) writeAllAttachesLocked(data []byte) {
	if len(data) == 0 {
		return
	}
	s.mu.Lock()
	clients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		clients = append(clients, client)
	}
	legacy := net.Conn(nil)
	if len(clients) == 0 {
		legacy = s.attachConn
	}
	s.mu.Unlock()
	for _, client := range clients {
		_, _ = client.enqueue(data, false)
	}
	if legacy != nil {
		s.writeAttachLocked(legacy, data)
	}
}

func terminalViewportResizeSequence(
	width int,
	height int,
	resetParser bool,
) []byte {
	if width <= 0 || height <= 0 {
		return nil
	}
	sequence := fmt.Sprintf("\x1b[?8;%d;%dt", height, width)
	if resetParser {
		sequence = terminalParserResetSequence + sequence
	}
	return []byte(sequence)
}

// enqueueAttachViewportResizeLocked keeps clipping-aware clients on the shared
// PTY grid while each client retains its own viewport dimensions for focus.
// The caller holds attachMu and mu and invokes this before resizing the PTY, so
// the sequence is queued before the corresponding redraw output.
func (s *muxServer) enqueueAttachViewportResizeLocked(width int, height int) {
	s.enqueueAttachViewportTransitionLocked(width, height, false)
}

func (s *muxServer) enqueueAttachViewportResizeAfterResetLocked(
	width int,
	height int,
) {
	s.enqueueAttachViewportTransitionLocked(width, height, true)
}

func (s *muxServer) enqueueAttachViewportTransitionLocked(
	width int,
	height int,
	resetParser bool,
) {
	sequence := terminalViewportResizeSequence(width, height, resetParser)
	if len(sequence) == 0 {
		return
	}
	for _, client := range s.attachClients {
		if !client.clipViewport ||
			(client.terminalWidth == width && client.terminalHeight == height) {
			continue
		}
		client.terminalWidth = width
		client.terminalHeight = height
		_, _ = client.enqueue(sequence, false)
	}
}

func (s *muxServer) writeAttachOutputIfActive(
	windowID string,
	primary net.Conn,
	primaryData []byte,
	failoverPrimaryData []byte,
	secondaryData []byte,
	queryData []byte,
	maxAttachSequence uint64,
	outputGeneration uint64,
) {
	if len(primaryData) == 0 {
		return
	}
	s.attachMu.Lock()

	s.mu.Lock()
	if s.activeID != windowID {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	clients := make([]*attachClient, 0, len(s.attachClients))
	allClients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		allClients = append(allClients, client)
		if client.sequence <= maxAttachSequence {
			clients = append(clients, client)
		}
	}
	legacy := len(s.attachClients) == 0 && s.attachConn == primary
	currentPrimary := s.attachConn
	s.mu.Unlock()

	if legacy {
		s.writeAttachLocked(primary, primaryData)
		s.attachMu.Unlock()
		return
	}
	var primaryClient *attachClient
	for _, client := range clients {
		if client.conn == primary {
			primaryClient = client
			break
		}
	}
	var deliveredPrimary *attachClient
	if len(queryData) > 0 {
		responseCount := terminalQueryResponseCount(queryData)
		type queryFallback struct {
			client              *attachClient
			queryCompletion     <-chan error
			queryGate           *attachWriteGate
			secondaryOutputGate *attachWriteGate
		}
		var primaryCompletion <-chan error
		primaryQueued := false
		if primaryClient != nil {
			data := primaryData
			if primaryClient.suppressesReplayedOutput(
				windowID,
				outputGeneration,
			) {
				data = queryData
			}
			primaryCompletion, primaryQueued =
				primaryClient.enqueueTerminalQuery(
					data,
					true,
					windowID,
					responseCount,
				)
		}
		sort.Slice(allClients, func(i int, j int) bool {
			iCurrent := allClients[i].conn == currentPrimary
			jCurrent := allClients[j].conn == currentPrimary
			if iCurrent != jCurrent {
				return iCurrent
			}
			return moreRecentlyFocusedAttachClient(
				allClients[i],
				allClients[j],
			)
		})
		fallbacks := make([]queryFallback, 0, len(allClients))
		for _, client := range allClients {
			if client == primaryClient {
				continue
			}
			suppressesOutput := client.suppressesReplayedOutput(
				windowID,
				outputGeneration,
			)
			data := queryData
			if client.sequence <= maxAttachSequence && !suppressesOutput {
				data = failoverPrimaryData
			}
			queryGate := &attachWriteGate{done: make(chan struct{})}
			queryCompletion, queued :=
				client.enqueueConditionalTerminalQuery(
					data,
					true,
					windowID,
					responseCount,
					queryGate,
				)
			if !queued {
				continue
			}
			fallback := queryFallback{
				client:          client,
				queryCompletion: queryCompletion,
				queryGate:       queryGate,
			}
			if client.sequence <= maxAttachSequence &&
				len(secondaryData) > 0 &&
				!suppressesOutput {
				secondaryGate := &attachWriteGate{done: make(chan struct{})}
				if _, queued := client.enqueueWrite(
					secondaryData,
					false,
					"",
					0,
					secondaryGate,
				); queued {
					fallback.secondaryOutputGate = secondaryGate
				}
			}
			fallbacks = append(fallbacks, fallback)
		}
		s.attachMu.Unlock()

		primaryDelivered := primaryQueued &&
			primaryClient.waitForWrite(primaryCompletion)
		for _, fallback := range fallbacks {
			tryFallback := !primaryDelivered
			fallback.queryGate.deliver.Store(tryFallback)
			close(fallback.queryGate.done)
			if tryFallback &&
				fallback.client.waitForWrite(fallback.queryCompletion) {
				primaryDelivered = true
			}
			if fallback.secondaryOutputGate != nil {
				fallback.secondaryOutputGate.deliver.Store(!tryFallback)
				close(fallback.secondaryOutputGate.done)
			}
		}
		if !primaryDelivered {
			s.redeliverTerminalQueries(
				windowID,
				queryData,
				nil,
				nil,
			)
		}
		return
	}
	if primaryClient != nil {
		if primaryClient.suppressesReplayedOutput(windowID, outputGeneration) {
			deliveredPrimary = primaryClient
		} else {
			_, queued := primaryClient.enqueue(primaryData, false)
			if queued {
				deliveredPrimary = primaryClient
			}
		}
	}
	if deliveredPrimary == nil {
		sort.Slice(clients, func(i int, j int) bool {
			iCurrent := clients[i].conn == currentPrimary
			jCurrent := clients[j].conn == currentPrimary
			if iCurrent != jCurrent {
				return iCurrent
			}
			return moreRecentlyFocusedAttachClient(clients[i], clients[j])
		})
		for _, client := range clients {
			if client == primaryClient {
				continue
			}
			if client.suppressesReplayedOutput(windowID, outputGeneration) {
				deliveredPrimary = client
				break
			}
			_, queued := client.enqueue(failoverPrimaryData, false)
			if queued {
				deliveredPrimary = client
				break
			}
		}
	}
	for _, client := range clients {
		if client == deliveredPrimary ||
			len(secondaryData) == 0 ||
			client.suppressesReplayedOutput(windowID, outputGeneration) {
			continue
		}
		_, _ = client.enqueue(secondaryData, false)
	}
	s.attachMu.Unlock()
}

func (s *muxServer) writeAttachIfActive(windowID string, conn net.Conn, data []byte) {
	s.writeAttachOutputIfActive(
		windowID,
		conn,
		data,
		data,
		data,
		nil,
		^uint64(0),
		0,
	)
}

func (s *muxServer) enqueuePrimaryAttachLocked(
	preferred net.Conn,
	data []byte,
	tracked bool,
	windowID string,
) (*attachClient, <-chan error, bool) {
	if len(data) == 0 {
		return nil, nil, true
	}
	s.mu.Lock()
	clients := make([]*attachClient, 0, len(s.attachClients))
	currentPrimary := s.attachConn
	for _, client := range s.attachClients {
		clients = append(clients, client)
	}
	legacy := len(clients) == 0 && currentPrimary == preferred
	s.mu.Unlock()
	if legacy {
		return nil, nil, s.writeAttachLocked(preferred, data)
	}
	sort.Slice(clients, func(i int, j int) bool {
		iPreferred := clients[i].conn == preferred
		jPreferred := clients[j].conn == preferred
		if iPreferred != jPreferred {
			return iPreferred
		}
		iCurrent := clients[i].conn == currentPrimary
		jCurrent := clients[j].conn == currentPrimary
		if iCurrent != jCurrent {
			return iCurrent
		}
		return moreRecentlyFocusedAttachClient(clients[i], clients[j])
	})
	responseCount := terminalQueryResponseCount(data)
	for _, client := range clients {
		completion, queued := client.enqueueTerminalQuery(
			data,
			tracked,
			windowID,
			responseCount,
		)
		if !queued {
			continue
		}
		return client, completion, true
	}
	return nil, nil, false
}

func (s *muxServer) watchTerminalQueryWrite(
	windowID string,
	client *attachClient,
	completion <-chan error,
	queries []byte,
	onSuccess func(),
	onDeferred func(),
) {
	if client == nil || completion == nil {
		if onSuccess != nil {
			onSuccess()
		}
		return
	}
	go func() {
		writeErr, ok := <-completion
		if !ok {
			writeErr = io.ErrClosedPipe
		}
		if writeErr == nil {
			if onSuccess != nil {
				onSuccess()
			}
			return
		}
		s.redeliverTerminalQueries(
			windowID,
			queries,
			onSuccess,
			onDeferred,
		)
	}()
}

func (s *muxServer) redeliverTerminalQueries(
	windowID string,
	queries []byte,
	onSuccess func(),
	onDeferred func(),
) {
	if len(queries) == 0 {
		return
	}
	s.attachMu.Lock()
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return
	}
	if s.activeID != windowID || s.attachCountLocked() == 0 {
		if onDeferred == nil {
			s.storePendingTerminalQueriesLocked(window, queries)
		}
		s.mu.Unlock()
		s.attachMu.Unlock()
		if onDeferred != nil {
			onDeferred()
		}
		return
	}
	preferred := s.attachConn
	s.mu.Unlock()
	client, completion, queued := s.enqueuePrimaryAttachLocked(
		preferred,
		queries,
		true,
		windowID,
	)
	if !queued {
		if onDeferred == nil {
			s.mu.Lock()
			window = s.windowByIDLocked(windowID)
			if window != nil && !window.closed {
				s.storePendingTerminalQueriesLocked(window, queries)
			}
			s.mu.Unlock()
		}
		s.attachMu.Unlock()
		if onDeferred != nil {
			onDeferred()
		}
		return
	}
	s.attachMu.Unlock()
	if client == nil {
		if onSuccess != nil {
			onSuccess()
		}
		return
	}
	s.watchTerminalQueryWrite(
		windowID,
		client,
		completion,
		queries,
		onSuccess,
		onDeferred,
	)
}

func (s *muxServer) storePendingTerminalQueriesLocked(
	window *muxWindow,
	queries []byte,
) {
	if window == nil ||
		len(queries) == 0 ||
		bytes.Contains(window.pendingTerminalQueries, queries) ||
		len(window.pendingTerminalQueries)+len(queries) >
			pendingTerminalQueryLimitBytes {
		return
	}
	window.pendingTerminalQueries = append(
		window.pendingTerminalQueries,
		queries...,
	)
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
		len(window.pendingTerminalQueriesInFlight) == 0 &&
		len(window.pendingTerminalQueries) > 0 {
		pending = append([]byte(nil), window.pendingTerminalQueries...)
		window.pendingTerminalQueries = nil
		window.pendingTerminalQueriesInFlight = append(
			window.pendingTerminalQueriesInFlight[:0],
			pending...,
		)
	}
	s.mu.Unlock()
	if len(pending) == 0 {
		return
	}
	client, completion, queued := s.enqueuePrimaryAttachLocked(
		conn,
		pending,
		true,
		windowID,
	)
	if !queued {
		s.restorePendingTerminalQueries(windowID, pending)
		return
	}
	if client != nil {
		s.watchTerminalQueryWrite(
			windowID,
			client,
			completion,
			pending,
			func() {
				s.clearPendingTerminalQueriesInFlight(windowID, pending)
			},
			func() {
				s.restorePendingTerminalQueries(windowID, pending)
			},
		)
		return
	}
	s.clearPendingTerminalQueriesInFlight(windowID, pending)
}

func (s *muxServer) clearPendingTerminalQueriesInFlight(
	windowID string,
	pending []byte,
) {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window != nil &&
		bytes.Equal(window.pendingTerminalQueriesInFlight, pending) {
		window.pendingTerminalQueriesInFlight = nil
	}
	s.mu.Unlock()
}

func (s *muxServer) restorePendingTerminalQueries(
	windowID string,
	pending []byte,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	window := s.windowByIDLocked(windowID)
	if window == nil ||
		!bytes.Equal(window.pendingTerminalQueriesInFlight, pending) {
		return
	}
	window.pendingTerminalQueriesInFlight = nil
	if len(pending)+len(window.pendingTerminalQueries) >
		pendingTerminalQueryLimitBytes {
		return
	}
	restored := make([]byte, 0, len(pending)+len(window.pendingTerminalQueries))
	restored = append(restored, pending...)
	restored = append(restored, window.pendingTerminalQueries...)
	window.pendingTerminalQueries = restored
}

func (s *muxServer) writeActive(data []byte) {
	_ = s.writeWindow(s.activeWindowID(), data)
}

func (s *muxServer) handleAttachInputSerialized(
	client *attachClient,
	data []byte,
) bool {
	client.inputMu.Lock()
	defer client.inputMu.Unlock()
	return s.handleAttachInput(client, data)
}

func (s *muxServer) handleAttachInput(client *attachClient, data []byte) bool {
	if client == nil || len(data) == 0 {
		return false
	}
	if !client.prefixEnabled {
		s.writeActiveFromAttach(data)
		return false
	}

	pending := make([]byte, 0, len(data))
	flush := func() {
		if len(pending) == 0 {
			return
		}
		s.writeActiveFromAttach(pending)
		pending = pending[:0]
	}
	for _, value := range data {
		if client.confirmCloseID != "" {
			windowID := client.confirmCloseID
			client.confirmCloseID = ""
			if value == 'y' || value == 'Y' {
				shouldShutdown, err := s.closeWindow(windowID)
				if err != nil {
					s.ringAttachBell(client)
					s.replayActiveWindowToClient(client)
				} else if shouldShutdown {
					go s.close()
				}
			} else {
				s.replayActiveWindowToClient(client)
			}
			continue
		}
		if client.prefixPending {
			client.prefixPending = false
			flush()
			if s.handleAttachPrefixCommand(client, value) {
				return true
			}
			continue
		}
		if value == 0x02 {
			flush()
			client.prefixPending = true
			continue
		}
		pending = append(pending, value)
	}
	flush()
	return false
}

func (s *muxServer) handleAttachPrefixCommand(
	client *attachClient,
	command byte,
) bool {
	var err error
	switch command {
	case 0x02:
		s.writeActiveFromAttach([]byte{0x02})
	case 'c':
		err = s.createWindowFromActiveDirectory()
	case 'n':
		err = s.selectRelativeWindow(1)
	case 'p':
		err = s.selectRelativeWindow(-1)
	case 'l':
		err = s.selectLastWindow()
	case '&':
		err = s.requestCloseActiveWindow(client)
	case 'd':
		client.close()
		return true
	default:
		if command >= '0' && command <= '9' {
			err = s.selectWindowByIndex(int(command - '0'))
		} else {
			err = fmt.Errorf("unsupported prefix command")
		}
	}
	if err != nil {
		s.ringAttachBell(client)
	}
	return false
}

func (s *muxServer) createWindowFromActiveDirectory() error {
	s.mu.Lock()
	window := s.windowByIDLocked(s.activeID)
	cwd := ""
	if window != nil && !window.closed {
		window.refreshProcessMetadataLocked(time.Now())
		cwd = window.cwd
	}
	s.mu.Unlock()
	_, err := s.createWindow(createWindowOptions{cwd: cwd})
	return err
}

func (s *muxServer) selectRelativeWindow(offset int) error {
	s.mu.Lock()
	open := make([]string, 0, len(s.windows))
	activeIndex := -1
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		if window.id == s.activeID {
			activeIndex = len(open)
		}
		open = append(open, window.id)
	}
	s.mu.Unlock()
	if len(open) == 0 || activeIndex < 0 {
		return errors.New("no active window")
	}
	target := (activeIndex + offset) % len(open)
	if target < 0 {
		target += len(open)
	}
	return s.selectWindow(open[target])
}

func (s *muxServer) selectWindowByIndex(index int) error {
	id := s.windowIDForIndex(index)
	if id == "" {
		return fmt.Errorf("window index %d not found", index)
	}
	return s.selectWindow(id)
}

func (s *muxServer) selectLastWindow() error {
	s.mu.Lock()
	id := s.lastActiveID
	window := s.windowByIDLocked(id)
	if window == nil || window.closed {
		id = ""
	}
	s.mu.Unlock()
	if id == "" {
		return errors.New("no last window")
	}
	return s.selectWindow(id)
}

func (s *muxServer) requestCloseActiveWindow(client *attachClient) error {
	id := s.activeWindowID()
	if id == "" {
		return errors.New("no active window")
	}
	client.confirmCloseID = id
	s.attachMu.Lock()
	s.writeAttachLocked(
		client.conn,
		[]byte("\r\n[monkeymux] close current window? (y/n) "),
	)
	s.attachMu.Unlock()
	return nil
}

func (s *muxServer) replayActiveWindowToClient(client *attachClient) {
	if client == nil {
		return
	}
	var replay []byte
	var window *muxWindow
	var foregroundProcessGroup int
	var windowID string
	s.attachMu.Lock()
	s.mu.Lock()
	window = s.windowByIDLocked(s.activeID)
	if window != nil && !window.closed {
		windowID = window.id
		replay = s.replayBytesLocked(window)
		foregroundProcessGroup = window.foregroundProcessGroupLocked()
	}
	s.mu.Unlock()
	if window == nil {
		s.attachMu.Unlock()
		return
	}
	redrew := s.writeAttachReplayAndResizeLocked(client.conn, replay, window)
	s.flushPendingTerminalQueriesLocked(client.conn, windowID)
	s.attachMu.Unlock()
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
}

func (s *muxServer) replayFocusedWindowToClient(
	client *attachClient,
	width int,
	height int,
) bool {
	if client == nil {
		return false
	}
	var foregroundProcessGroup int
	var windowID string
	var window *muxWindow
	var replay []byte
	s.attachMu.Lock()
	s.mu.Lock()
	if s.attachConn != client.conn ||
		s.attachClients[client.conn] != client {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	window = s.windowByIDLocked(s.activeID)
	if !terminalViewportTransitionSafe(window) {
		s.width = width
		s.height = height
		s.pendingFocusRefreshConn = client.conn
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	s.pendingFocusRefreshConn = nil
	s.pendingResizeWidth = 0
	s.pendingResizeHeight = 0
	s.pendingResizeRedraw = false
	s.width = width
	s.height = height
	s.enqueueAttachViewportResizeLocked(width, height)
	s.publishedWidth = width
	s.publishedHeight = height
	if window == nil || window.closed {
		s.mu.Unlock()
		s.attachMu.Unlock()
		return false
	}
	s.resizeActiveLocked(width, height)
	windowID = window.id
	replay = s.replayBytesLocked(window)
	foregroundProcessGroup = window.foregroundProcessGroupLocked()
	client.markOutputReplay(windowID, window.outputGeneration)
	_, queued := client.enqueue(replay, false)
	s.mu.Unlock()
	if !queued {
		client.clearOutputReplay()
		s.attachMu.Unlock()
		return false
	}
	redrew := s.simulateForegroundResizeIfAttached(client.conn, window)
	s.flushPendingTerminalQueriesLocked(client.conn, windowID)
	s.attachMu.Unlock()
	if redrew {
		signalForegroundResize(foregroundProcessGroup)
	}
	return true
}

func (s *muxServer) ringAttachBell(client *attachClient) {
	if client == nil {
		return
	}
	s.attachMu.Lock()
	s.writeAttachLocked(client.conn, []byte{'\a'})
	s.attachMu.Unlock()
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
	win32InputMode := window != nil && window.win32InputMode
	s.mu.Unlock()
	if window == nil || window.closed {
		return fmt.Errorf("window %q not found", windowID)
	}
	if win32InputMode {
		// ConPTY's input parser drops raw OSC/DCS sequences, so synthetic
		// replies (theme hints, clipboard responses, relayed query answers)
		// must be re-encoded as win32-input-mode key events to survive the
		// trip through conhost to the child process.
		data = encodeTerminalResponsesForWin32InputMode(data)
	}
	_, err := window.pty.Write(data)
	return err
}

// terminalOscOrDcsSequencePattern matches complete OSC (`ESC ] ... BEL|ST`) and
// DCS (`ESC P ... ST`) sequences. CSI sequences and plain text are left alone:
// ConPTY's input parser passes those through unmodified.
var terminalOscOrDcsSequencePattern = regexp.MustCompile(
	`\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|P[^\x1b]*\x1b\\)`,
)

// encodeTerminalResponsesForWin32InputMode re-encodes any OSC/DCS sequences in
// data as win32-input-mode key events (`CSI Vk;Sc;Uc;Kd;Cs;Rc _`), the format
// ConPTY expects for terminal input while DEC private mode 9001 is enabled.
// All other bytes pass through untouched.
func encodeTerminalResponsesForWin32InputMode(data []byte) []byte {
	if !bytes.Contains(data, []byte("\x1b]")) && !bytes.Contains(data, []byte("\x1bP")) {
		return data
	}
	var output bytes.Buffer
	cursor := 0
	for _, match := range terminalOscOrDcsSequencePattern.FindAllIndex(data, -1) {
		output.Write(data[cursor:match[0]])
		writeWin32InputModeKeyEvents(&output, data[match[0]:match[1]])
		cursor = match[1]
	}
	output.Write(data[cursor:])
	return output.Bytes()
}

func writeWin32InputModeKeyEvents(output *bytes.Buffer, sequence []byte) {
	for _, codeUnit := range utf16.Encode([]rune(string(sequence))) {
		// Only the Unicode char, key-down, and repeat-count fields are set,
		// mirroring how Windows Terminal forwards characters that have no
		// associated virtual key.
		fmt.Fprintf(output, "\x1b[0;0;%d;1;0;1_", codeUnit)
	}
}

// win32InputModeRequests are the DEC private mode 9001 (win32-input-mode)
// enable/disable sequences a foreground child emits to negotiate rich keyboard
// input with its terminal.
var win32InputModeRequests = [][]byte{
	[]byte("\x1b[?9001h"),
	[]byte("\x1b[?9001l"),
}

// win32InputModeRequestStripper removes win32-input-mode (DEC private mode 9001)
// requests from a stream of window output before it reaches os.Stdout.
//
// On Windows the `monkeymux attach` process runs inside the SSH server's own
// ConPTY (conhost). That conhost watches the attach process's output for a
// `CSI ? 9001 h` and, on seeing one, switches its input delivery to
// win32-input-mode — decomposing the client's raw VT input (e.g. an arrow key's
// `ESC [ A`) into individual character key events. Those char events survive the
// relay to the window's own ConPTY as a bare ESC followed by literal `[A`, which
// PSReadLine and other line editors treat as an Escape keypress plus typed text
// instead of a cursor key (so Up/Down stop recalling history). The window's
// child still negotiates win32-input-mode directly with its own ConPTY, so
// hiding the request from the outer conhost is safe and keeps arrow keys intact.
type win32InputModeRequestStripper struct {
	dst   io.Writer
	carry []byte
}

func newWin32InputModeRequestStripper(dst io.Writer) *win32InputModeRequestStripper {
	return &win32InputModeRequestStripper{dst: dst}
}

func (s *win32InputModeRequestStripper) Write(p []byte) (int, error) {
	out, carry := stripWin32InputModeRequests(s.carry, p)
	s.carry = carry
	if len(out) > 0 {
		if _, err := s.dst.Write(out); err != nil {
			return 0, err
		}
	}
	return len(p), nil
}

// Flush writes any buffered partial sequence to the destination. It must be
// called once the source stream ends so a trailing run that looked like the
// start of a win32-input-mode request (but was never completed) is not dropped.
func (s *win32InputModeRequestStripper) Flush() error {
	if len(s.carry) == 0 {
		return nil
	}
	carry := s.carry
	s.carry = nil
	_, err := s.dst.Write(carry)
	return err
}

// stripWin32InputModeRequests removes any complete win32-input-mode requests from
// prev+data and returns the bytes to emit plus a carry holding a trailing partial
// that could still complete into a request on the next write. A trailing byte run
// is only carried when it is a strict prefix of a request sequence, so ordinary
// escape sequences are never delayed by more than the bytes they share with the
// `ESC [ ? 9 0 0 1` prefix.
func stripWin32InputModeRequests(prev, data []byte) (out, carry []byte) {
	buf := data
	if len(prev) > 0 {
		buf = append(append(make([]byte, 0, len(prev)+len(data)), prev...), data...)
	}
	out = make([]byte, 0, len(buf))
	i := 0
	for i < len(buf) {
		next := bytes.IndexByte(buf[i:], '\x1b')
		if next < 0 {
			out = append(out, buf[i:]...)
			return out, nil
		}
		escape := i + next
		out = append(out, buf[i:escape]...)
		rest := buf[escape:]
		if stripped, ok := matchWin32InputModeRequest(rest); ok {
			i = escape + stripped
			continue
		}
		if isWin32InputModeRequestPrefix(rest) {
			carry = append(make([]byte, 0, len(rest)), rest...)
			return out, carry
		}
		out = append(out, '\x1b')
		i = escape + 1
	}
	return out, nil
}

// matchWin32InputModeRequest reports whether rest begins with a complete
// win32-input-mode request and, if so, its length.
func matchWin32InputModeRequest(rest []byte) (length int, ok bool) {
	for _, request := range win32InputModeRequests {
		if bytes.HasPrefix(rest, request) {
			return len(request), true
		}
	}
	return 0, false
}

// isWin32InputModeRequestPrefix reports whether rest is a non-empty strict prefix
// of a win32-input-mode request (so it might complete into one on the next
// write).
func isWin32InputModeRequestPrefix(rest []byte) bool {
	for _, request := range win32InputModeRequests {
		if len(rest) < len(request) && bytes.HasPrefix(request, rest) {
			return true
		}
	}
	return false
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
		if b == 0x18 || b == 0x1a {
			w.resetTerminalBellParserLocked()
			continue
		}
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

func (w *muxWindow) observeTerminalOutputStateLocked(data []byte) {
	for _, value := range data {
		if w.terminalOutputUtf8Remaining > 0 {
			if value&0xc0 == 0x80 {
				w.terminalOutputUtf8Remaining--
				continue
			}
			w.terminalOutputUtf8Remaining = 0
		}
		if remaining := utf8ContinuationCount(value); remaining > 0 {
			w.terminalOutputUtf8Remaining = remaining
			continue
		}
		if value == 0x18 || value == 0x1a {
			w.resetTerminalOutputParserLocked()
			continue
		}
		switch w.terminalOutputState {
		case terminalOutputParserGround:
			switch value {
			case '\x1b':
				w.terminalOutputState = terminalOutputParserEscape
			case 0x90, 0x98, 0x9e, 0x9f:
				w.terminalOutputState = terminalOutputParserString
			case 0x9b:
				w.terminalOutputState = terminalOutputParserCsi
			case 0x9d:
				w.terminalOutputState = terminalOutputParserOsc
			}
		case terminalOutputParserEscape:
			switch {
			case value == '\x1b':
				w.terminalOutputState = terminalOutputParserEscape
			case value == '[':
				w.terminalOutputState = terminalOutputParserCsi
			case value == ']':
				w.terminalOutputState = terminalOutputParserOsc
			case value == 'P' || value == 'X' || value == '^' || value == '_':
				w.terminalOutputState = terminalOutputParserString
			case value >= 0x20 && value <= 0x2f:
				w.terminalOutputState = terminalOutputParserEscapeIntermediate
			default:
				w.resetTerminalOutputParserLocked()
			}
		case terminalOutputParserEscapeIntermediate:
			switch {
			case value == '\x1b':
				w.terminalOutputState = terminalOutputParserEscape
			case value >= 0x20 && value <= 0x2f:
			case value >= 0x30 && value <= 0x7e:
				w.resetTerminalOutputParserLocked()
			default:
				w.resetTerminalOutputParserLocked()
			}
		case terminalOutputParserCsi:
			switch {
			case value == '\x1b':
				w.terminalOutputState = terminalOutputParserEscape
			case value >= 0x40 && value <= 0x7e:
				w.resetTerminalOutputParserLocked()
			}
		case terminalOutputParserOsc:
			switch value {
			case '\a', 0x9c:
				w.resetTerminalOutputParserLocked()
			case '\x1b':
				w.terminalOutputState = terminalOutputParserOscEscape
			}
		case terminalOutputParserOscEscape:
			switch value {
			case '\\', '\a', 0x9c:
				w.resetTerminalOutputParserLocked()
			case '\x1b':
				w.terminalOutputState = terminalOutputParserOscEscape
			default:
				w.terminalOutputState = terminalOutputParserOsc
			}
		case terminalOutputParserString:
			switch value {
			case 0x9c:
				w.resetTerminalOutputParserLocked()
			case '\x1b':
				w.terminalOutputState = terminalOutputParserStringEscape
			}
		case terminalOutputParserStringEscape:
			switch value {
			case '\\', 0x9c:
				w.resetTerminalOutputParserLocked()
			case '\x1b':
				w.terminalOutputState = terminalOutputParserStringEscape
			default:
				w.terminalOutputState = terminalOutputParserString
			}
		}
		if w.terminalOutputState != terminalOutputParserGround {
			w.terminalOutputBytes++
			if w.terminalOutputBytes > maxKittyGraphicsPendingBytes {
				w.resetTerminalOutputParserLocked()
			}
		}
	}
}

func (w *muxWindow) resetTerminalOutputParserLocked() {
	w.terminalOutputState = terminalOutputParserGround
	w.terminalOutputBytes = 0
}

func (w *muxWindow) terminalOutputIsGroundLocked() bool {
	return w.terminalOutputState == terminalOutputParserGround &&
		w.terminalOutputUtf8Remaining == 0
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
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAt(data, i)
		if incomplete {
			break
		}
		if !recognized {
			i++
			continue
		}
		shouldStrip := isQuery ||
			isReplayUnsafeOscNotificationSequence(data[i:sequenceEnd])
		if !shouldStrip {
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

func terminalQueriesFromData(data []byte) []byte {
	var queries []byte
	for index := 0; index < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAt(data, index)
		if incomplete {
			break
		}
		if !recognized {
			index++
			continue
		}
		if isQuery &&
			len(queries)+(sequenceEnd-index) <= pendingTerminalQueryLimitBytes {
			queries = append(queries, data[index:sequenceEnd]...)
		}
		index = sequenceEnd
	}
	return queries
}

func terminalQueryResponseCount(data []byte) int {
	count := 0
	for index := 0; index < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAt(data, index)
		if incomplete {
			break
		}
		if !recognized {
			index++
			continue
		}
		if isQuery {
			count += terminalQuerySequenceResponseCount(
				data[index:sequenceEnd],
			)
		}
		index = sequenceEnd
	}
	return count
}

func terminalQuerySequenceResponseCount(sequence []byte) int {
	payloadStart := 0
	osc := false
	dcs := false
	switch {
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == ']':
		payloadStart = 2
		osc = true
	case len(sequence) >= 1 && sequence[0] == 0x9d:
		payloadStart = 1
		osc = true
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == 'P':
		payloadStart = 2
		dcs = true
	case len(sequence) >= 1 && sequence[0] == 0x90:
		payloadStart = 1
		dcs = true
	default:
		return 1
	}
	findTerminator := findStringTerminator
	if osc {
		findTerminator = findOscTerminator
	}
	end, _, ok := findTerminator(sequence[payloadStart:])
	if !ok {
		return 1
	}
	payload := sequence[payloadStart : payloadStart+end]
	if dcs {
		if !bytes.HasPrefix(payload, []byte("+q")) {
			return 1
		}
		count := 0
		for _, capability := range bytes.Split(payload[2:], []byte{';'}) {
			if len(capability) > 0 {
				count++
			}
		}
		if count > 0 {
			return count
		}
		return 0
	}
	code, value, ok := strings.Cut(
		string(payload),
		";",
	)
	if !ok || code != "4" {
		return 1
	}
	args := strings.Split(value, ";")
	count := 0
	for index := 0; index+1 < len(args); index += 2 {
		paletteIndex, err := strconv.Atoi(strings.TrimSpace(args[index]))
		if err != nil ||
			paletteIndex < 0 ||
			paletteIndex > 255 ||
			strings.TrimSpace(args[index+1]) != "?" {
			continue
		}
		count++
	}
	if count == 0 {
		return 1
	}
	return count
}

func terminalResponseSequenceExpectationCount(sequence []byte) int {
	payloadStart := 0
	switch {
	case len(sequence) >= 2 &&
		sequence[0] == '\x1b' &&
		sequence[1] == 'P':
		payloadStart = 2
	case len(sequence) >= 1 && sequence[0] == 0x90:
		payloadStart = 1
	default:
		return 1
	}
	end, _, ok := findStringTerminator(sequence[payloadStart:])
	if !ok {
		return 1
	}
	payload := sequence[payloadStart : payloadStart+end]
	if !bytes.HasPrefix(payload, []byte("0+r")) &&
		!bytes.HasPrefix(payload, []byte("1+r")) {
		return 1
	}
	count := 0
	for _, capability := range bytes.Split(payload[3:], []byte{';'}) {
		if len(capability) > 0 {
			count++
		}
	}
	if count > 0 {
		return count
	}
	return 1
}

func (w *muxWindow) secondaryAttachOutputLocked(chunk []byte) []byte {
	w.lastForwardedTerminalQueries = nil
	if len(chunk) == 0 && len(w.secondaryQueryCarry) == 0 {
		return chunk
	}
	data := chunk
	previousUtf8Remaining := w.queryUtf8Remaining
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousUtf8Remaining,
	)
	w.queryUtf8Remaining = 0
	if len(w.secondaryQueryCarry) > 0 {
		combined := make([]byte, 0, len(w.secondaryQueryCarry)+len(chunk))
		combined = append(combined, w.secondaryQueryCarry...)
		combined = append(combined, chunk...)
		data = combined
		w.secondaryQueryCarry = nil
		leadingUtf8Prefix = 0
	}

	output := make([]byte, 0, len(data))
	copyStart := 0
	for i := 0; i < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAtWithUtf8Prefix(
				data,
				i,
				leadingUtf8Prefix,
			)
		if incomplete {
			w.queryUtf8Remaining = 0
			output = append(output, data[copyStart:i]...)
			if !w.storeSecondaryQueryCarryLocked(data[i:]) {
				output = append(output, data[i:]...)
			}
			return output
		}
		if !recognized {
			i++
			continue
		}
		if isQuery {
			if len(w.lastForwardedTerminalQueries)+sequenceEnd-i <=
				pendingTerminalQueryLimitBytes {
				w.lastForwardedTerminalQueries = append(
					w.lastForwardedTerminalQueries,
					data[i:sequenceEnd]...,
				)
			}
			output = append(output, data[copyStart:i]...)
			copyStart = sequenceEnd
		}
		i = sequenceEnd
	}
	output = append(output, data[copyStart:]...)
	w.queryUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousUtf8Remaining,
		leadingUtf8Prefix,
	)
	return output
}

func (w *muxWindow) storeSecondaryQueryCarryLocked(data []byte) bool {
	if len(data) > oscBufferLimitBytes {
		w.secondaryQueryCarry = nil
		return false
	}
	w.secondaryQueryCarry = append(w.secondaryQueryCarry[:0], data...)
	return true
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
// are unknown or duplicated. Missing-image repair uses the same byte and count
// limits as ordinary replay so one request cannot monopolize an attach queue.
func (w *muxWindow) kittyImageTransmissionsForLocked(
	ids []string,
) ([]byte, []string) {
	if len(ids) == 0 || len(w.kittyImages) == 0 {
		return nil, nil
	}
	var out []byte
	var served []string
	var seen map[string]struct{}
	for _, id := range ids {
		if len(seen) >= maxReplayedKittyImages {
			break
		}
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
		if len(buf) > maxReplayedKittyImageBytes ||
			len(out)+len(buf) > maxReplayedKittyImageBytes {
			continue
		}
		if seen == nil {
			seen = make(map[string]struct{}, len(ids))
		}
		seen[id] = struct{}{}
		out = append(out, buf...)
		served = append(served, id)
	}
	return out, served
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

func terminalQuerySequenceAt(
	data []byte,
	index int,
) (int, bool, bool, bool) {
	return terminalQuerySequenceAtWithUtf8Prefix(data, index, 0)
}

func terminalQuerySequenceAtWithUtf8Prefix(
	data []byte,
	index int,
	leadingUtf8Prefix int,
) (int, bool, bool, bool) {
	if index < 0 || index >= len(data) {
		return -1, false, false, false
	}
	if index < leadingUtf8Prefix && data[index]&0xc0 == 0x80 {
		return -1, false, false, false
	}
	introducer := data[index]
	payloadStart := index + 1
	escaped := false
	if introducer == '\x1b' {
		if index+1 >= len(data) {
			return -1, false, true, true
		}
		escaped = true
		introducer = data[index+1]
		payloadStart = index + 2
	} else if isUtf8ContinuationAt(data, index) {
		return -1, false, false, false
	}
	switch introducer {
	case '[':
		if !escaped {
			return -1, false, false, false
		}
		end := csiSequenceEnd(data, payloadStart)
		if end < 0 {
			return -1, false, true, true
		}
		sequenceEnd := end + 1
		return sequenceEnd,
			isReplayUnsafeCsiQuery(data[index:sequenceEnd]),
			false,
			true
	case 0x9b:
		end := csiSequenceEnd(data, payloadStart)
		if end < 0 {
			return -1, false, true, true
		}
		sequenceEnd := end + 1
		return sequenceEnd,
			isReplayUnsafeCsiQuery(data[index:sequenceEnd]),
			false,
			true
	case ']':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeOscQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x9d:
		end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeOscQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 'P':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeDcsQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x90:
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeDcsQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case '_':
		if !escaped {
			return -1, false, false, false
		}
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeKittyQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	case 0x9f:
		end, terminatorLength, ok := findStringTerminator(data[payloadStart:])
		if !ok {
			return -1, false, true, true
		}
		return payloadStart + end + terminatorLength,
			isReplayUnsafeKittyQuery(data[payloadStart : payloadStart+end]),
			false,
			true
	default:
		return -1, false, false, false
	}
}

func leadingUtf8ContinuationPrefix(data []byte, remaining int) int {
	count := 0
	for count < len(data) &&
		count < remaining &&
		data[count]&0xc0 == 0x80 {
		count++
	}
	return count
}

func nextQueryUtf8Remaining(
	data []byte,
	previousRemaining int,
	leadingPrefix int,
) int {
	if leadingPrefix == len(data) && leadingPrefix < previousRemaining {
		return previousRemaining - leadingPrefix
	}
	return trailingUtf8ContinuationCount(data)
}

func isReplayUnsafeOscNotificationSequence(sequence []byte) bool {
	payloadStart := 0
	switch {
	case len(sequence) >= 2 && sequence[0] == '\x1b' && sequence[1] == ']':
		payloadStart = 2
	case len(sequence) >= 1 && sequence[0] == 0x9d:
		payloadStart = 1
	default:
		return false
	}
	end, _, ok := findOscTerminator(sequence[payloadStart:])
	return ok && isReplayUnsafeOscNotification(
		sequence[payloadStart:payloadStart+end],
	)
}

func isReplayUnsafeCsiQuery(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch final {
	case 'c':
		return params == "" ||
			params == "0" ||
			strings.HasPrefix(params, "?") ||
			strings.HasPrefix(params, ">") ||
			strings.HasPrefix(params, "=")
	case 'n':
		return params == "5" ||
			params == "6" ||
			params == "?6" ||
			params == "?15" ||
			params == "?25" ||
			params == "?26" ||
			params == "?53" ||
			params == "?996"
	case 'q':
		// XTVERSION (CSI > q): the child asks the terminal to identify itself,
		// which agents such as Copilot CLI use to unlock richer rendering. The
		// space-intermediate DECSCUSR cursor-style control (CSI Ps SP q) is not
		// a query. Replaying an already-answered XTVERSION would make the
		// terminal send a second, unsolicited identity report.
		return strings.HasPrefix(params, ">")
	case 'p':
		return strings.HasSuffix(params, "$")
	case 't':
		primary, _, _ := strings.Cut(params, ";")
		switch primary {
		case "14", "15", "16", "18", "19", "20", "21":
			return true
		default:
			return false
		}
	case 'u':
		return params == "?"
	default:
		return false
	}
}

func scanTerminalResponseInput(
	data []byte,
	leadingUtf8Prefix int,
) ([]int, int, byte, int) {
	if len(data) == 0 {
		return nil, -1, 0, 0
	}
	var responseEnds []int
	for index := 0; index < len(data); {
		if index < leadingUtf8Prefix &&
			data[index]&0xc0 == 0x80 {
			return responseEnds, -1, 0, index
		}
		sequenceEnd := -1
		isResponse := false
		introducer := data[index]
		payloadStart := index + 1
		escaped := false
		if introducer == '\x1b' {
			if index+1 >= len(data) {
				return responseEnds, index, 0, len(data)
			}
			escaped = true
			introducer = data[index+1]
			payloadStart = index + 2
		}
		switch introducer {
		case '[':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end := csiSequenceEnd(data, payloadStart)
			if end < 0 {
				return responseEnds, index, 0, len(data)
			}
			sequenceEnd = end + 1
			isResponse = isTerminalResponseCsi(data[index:sequenceEnd])
		case 0x9b:
			end := csiSequenceEnd(data, payloadStart)
			if end < 0 {
				return responseEnds, index, 0, len(data)
			}
			sequenceEnd = end + 1
			isResponse = isTerminalResponseCsi(data[index:sequenceEnd])
		case ']':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
			if !ok {
				return responseEnds, index, ']', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseOsc(
				data[payloadStart : payloadStart+end],
			)
		case 0x9d:
			end, terminatorLength, ok := findOscTerminator(data[payloadStart:])
			if !ok {
				return responseEnds, index, ']', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseOsc(
				data[payloadStart : payloadStart+end],
			)
		case 'P':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, 'P', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseDcs(
				data[payloadStart : payloadStart+end],
			)
		case 0x90:
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, 'P', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseDcs(
				data[payloadStart : payloadStart+end],
			)
		case '_':
			if !escaped {
				return responseEnds, -1, 0, index
			}
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, '_', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseKitty(
				data[payloadStart : payloadStart+end],
			)
		case 0x9f:
			end, terminatorLength, ok := findStringTerminator(
				data[payloadStart:],
			)
			if !ok {
				return responseEnds, index, '_', len(data)
			}
			sequenceEnd = payloadStart + end + terminatorLength
			isResponse = isTerminalResponseKitty(
				data[payloadStart : payloadStart+end],
			)
		default:
			return responseEnds, -1, 0, index
		}
		if !isResponse {
			return responseEnds, -1, 0, index
		}
		responseEnds = append(responseEnds, sequenceEnd)
		index = sequenceEnd
	}
	return responseEnds, -1, 0, len(data)
}

func stripFocusOutInput(data []byte) ([]byte, []byte) {
	var output []byte
	copyStart := 0
	for index := 0; index < len(data); {
		sequenceLength := 0
		switch {
		case bytes.HasPrefix(data[index:], []byte("\x1b[O")):
			sequenceLength = 3
		case bytes.HasPrefix(data[index:], []byte{0x9b, 'O'}):
			sequenceLength = 2
		case bytes.Equal(data[index:], []byte{'\x1b'}) ||
			bytes.Equal(data[index:], []byte("\x1b[")) ||
			bytes.Equal(data[index:], []byte{0x9b}):
			if output == nil {
				output = append([]byte(nil), data[:index]...)
			} else {
				output = append(output, data[copyStart:index]...)
			}
			return output, append([]byte(nil), data[index:]...)
		default:
			index++
			continue
		}
		if output == nil {
			output = make([]byte, 0, len(data)-sequenceLength)
		}
		output = append(output, data[copyStart:index]...)
		index += sequenceLength
		copyStart = index
	}
	if output == nil {
		return data, nil
	}
	output = append(output, data[copyStart:]...)
	return output, nil
}

func consumeTerminalResponseContinuation(
	data []byte,
	kind byte,
	leadingEscape bool,
	utf8Remaining int,
) ([]byte, bool, bool, int) {
	if leadingEscape && len(data) > 0 && data[0] == '\\' {
		return data[1:], true, false, 0
	}
	for index := 0; index < len(data); index++ {
		if utf8Remaining > 0 {
			if data[index]&0xc0 == 0x80 {
				utf8Remaining--
				continue
			}
			utf8Remaining = 0
		}
		if remaining := utf8ContinuationCount(data[index]); remaining > 0 {
			utf8Remaining = remaining
			continue
		}
		if data[index] == 0x9c ||
			(kind == ']' && data[index] == '\a') {
			return data[index+1:], true, false, 0
		}
		if data[index] == '\x1b' &&
			index+1 < len(data) &&
			data[index+1] == '\\' {
			return data[index+2:], true, false, 0
		}
	}
	return nil,
		false,
		len(data) > 0 && data[len(data)-1] == '\x1b',
		utf8Remaining
}

func utf8ContinuationCount(lead byte) int {
	switch {
	case lead >= 0xc2 && lead <= 0xdf:
		return 1
	case lead >= 0xe0 && lead <= 0xef:
		return 2
	case lead >= 0xf0 && lead <= 0xf4:
		return 3
	default:
		return 0
	}
}

func trailingUtf8ContinuationCount(data []byte) int {
	if len(data) == 0 {
		return 0
	}
	_, size := utf8.DecodeLastRune(data)
	if size > 1 {
		return 0
	}
	for index := len(data) - 1; index >= 0 && len(data)-index <= 4; index-- {
		remaining := utf8ContinuationCount(data[index])
		if remaining == 0 {
			continue
		}
		available := len(data) - index - 1
		if available < remaining {
			return remaining - available
		}
		return 0
	}
	return 0
}

func isTerminalResponseCsi(sequence []byte) bool {
	bodyStart := 0
	switch {
	case len(sequence) >= 3 && sequence[0] == '\x1b' && sequence[1] == '[':
		bodyStart = 2
	case len(sequence) >= 2 && sequence[0] == 0x9b:
		bodyStart = 1
	default:
		return false
	}
	final := sequence[len(sequence)-1]
	params := string(sequence[bodyStart : len(sequence)-1])
	switch final {
	case 'c':
		return strings.HasPrefix(params, "?") ||
			strings.HasPrefix(params, ">") ||
			strings.HasPrefix(params, "=")
	case 'n':
		return params == "0" || strings.HasPrefix(params, "?")
	case 'R':
		return terminalResponseNumericParams(
			strings.TrimPrefix(params, "?"),
		)
	case 't':
		first, _, ok := strings.Cut(params, ";")
		return ok && containsString([]string{"4", "5", "6", "8", "9"}, first)
	case 'y':
		return strings.HasSuffix(params, "$")
	case 'u':
		return strings.HasPrefix(params, "?")
	default:
		return false
	}
}

func terminalResponseNumericParams(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && character != ';' {
			return false
		}
	}
	return true
}

func isTerminalResponseOsc(payload []byte) bool {
	if len(payload) > 0 && (payload[0] == 'L' || payload[0] == 'l') {
		return true
	}
	code, value, ok := strings.Cut(string(payload), ";")
	if !ok || value == "?" {
		return false
	}
	switch code {
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "52":
		return true
	default:
		return false
	}
}

func isTerminalResponseDcs(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte(">|")) ||
		bytes.HasPrefix(payload, []byte("!|")) ||
		bytes.HasPrefix(payload, []byte("0+r")) ||
		bytes.HasPrefix(payload, []byte("1+r")) ||
		bytes.HasPrefix(payload, []byte("0$r")) ||
		bytes.HasPrefix(payload, []byte("1$r"))
}

func isTerminalResponseKitty(payload []byte) bool {
	if len(payload) < 2 || payload[0] != 'G' {
		return false
	}
	separator := bytes.IndexByte(payload, ';')
	if separator < 0 || separator+1 >= len(payload) {
		return false
	}
	response := payload[separator+1:]
	return bytes.HasPrefix(response, []byte("OK")) ||
		bytes.HasPrefix(response, []byte("ERROR")) ||
		bytes.HasPrefix(response, []byte("ENOTSUP"))
}

func isReplayUnsafeOscQuery(payload []byte) bool {
	code, value, ok := strings.Cut(string(payload), ";")
	if !ok || !strings.Contains(value, "?") {
		return false
	}
	switch code {
	case "4", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "52":
		return true
	default:
		return false
	}
}

func isReplayUnsafeDcsQuery(payload []byte) bool {
	return bytes.HasPrefix(payload, []byte("$q")) ||
		bytes.HasPrefix(payload, []byte("+q"))
}

func isReplayUnsafeKittyQuery(payload []byte) bool {
	if len(payload) < 2 || payload[0] != 'G' {
		return false
	}
	control := payload[1:]
	if separator := bytes.IndexByte(control, ';'); separator >= 0 {
		control = control[:separator]
	}
	for _, field := range bytes.Split(control, []byte{','}) {
		if bytes.Equal(field, []byte("a=q")) {
			return true
		}
	}
	return false
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
	var themeHintData []byte
	// On Windows ConPTY (win32-input-mode) an OSC color report written into the
	// window pty is re-encoded as win32-input-mode key events, which conhost
	// then delivers to the foreground app as a run of typed characters. Apps
	// that read console input records instead of a VT stream (e.g. Codex) render
	// that as literal `]11;rgb:...` text in their composer. Unsolicited refresh
	// pushes have no matching read on the app side, so skip the OSC reports
	// there; the live query-response path in handleWindowOutput still answers
	// OSC color queries the app actually makes, and focus-aware apps still get a
	// FocusIn nudge to re-query through that safe path.
	if !w.win32InputMode {
		var refreshKeys []string
		refreshKeys = appendThemeQueryKeys(refreshKeys, w.themeHintRefreshKeysLocked())
		refreshKeys = appendThemeQueryKeys(refreshKeys, w.agentThemeHintRefreshKeysLocked())
		themeHintData = themeHintResponsesForKeys(themeHint, refreshKeys)
	}
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
	case strings.Contains(lowered, "cursor-agent/versions/"):
		// The `cursor-agent`/`agent` launchers are Node wrappers whose argv[0]
		// (often the generic `agent`) is ambiguous, so match the versioned
		// install path instead.
		return "cursor-agent"
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
	case "cursor-agent":
		return "cursor-agent"
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
	case "cursor-agent":
		if startInYoloMode {
			return "cursor-agent --force"
		}
		return "cursor-agent"
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
	case "cursor-agent":
		commandPrefix := "cursor-agent"
		if startInYoloMode {
			commandPrefix = "cursor-agent --force"
		}
		if sessionID == "_continue" {
			return commandPrefix + " --continue"
		}
		return commandPrefix + " --resume " + quotedSessionID
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
	case normalized == "cursor agent" ||
		normalized == "cursor-agent" || normalized == "cursor cli" ||
		strings.HasPrefix(normalized, "cursor agent "):
		return "cursor-agent"
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
// for terminal capability/status queries (CSI, OSC, and DCS)
// and buffers them in pendingTerminalQueries. It is called only while no
// terminal is showing the window, so these queries are not being forwarded to a
// terminal that could answer them; flushPendingTerminalQueriesLocked re-delivers
// them once one attaches. A query split across pty reads is carried in
// pendingTerminalQueryCarry until the rest arrives. Queries answered from the
// cached theme hint are stripped before reaching this scanner.
func (w *muxWindow) appendPendingTerminalQueriesLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	data := chunk
	previousUtf8Remaining := w.queryUtf8Remaining
	leadingUtf8Prefix := leadingUtf8ContinuationPrefix(
		data,
		previousUtf8Remaining,
	)
	w.queryUtf8Remaining = 0
	if len(w.pendingTerminalQueryCarry) > 0 {
		combined := make([]byte, 0, len(w.pendingTerminalQueryCarry)+len(chunk))
		combined = append(combined, w.pendingTerminalQueryCarry...)
		combined = append(combined, chunk...)
		data = combined
		w.pendingTerminalQueryCarry = nil
		leadingUtf8Prefix = 0
	}
	for index := 0; index < len(data); {
		sequenceEnd, isQuery, incomplete, recognized :=
			terminalQuerySequenceAtWithUtf8Prefix(
				data,
				index,
				leadingUtf8Prefix,
			)
		if incomplete {
			w.queryUtf8Remaining = 0
			w.storePartialPendingTerminalQueryLocked(data[index:])
			return
		}
		if !recognized {
			index++
			continue
		}
		sequence := data[index:sequenceEnd]
		if isQuery &&
			len(w.pendingTerminalQueries)+len(sequence) <= pendingTerminalQueryLimitBytes {
			w.pendingTerminalQueries = append(w.pendingTerminalQueries, sequence...)
		}
		index = sequenceEnd
	}
	w.queryUtf8Remaining = nextQueryUtf8Remaining(
		data,
		previousUtf8Remaining,
		leadingUtf8Prefix,
	)
}

func (w *muxWindow) storePartialPendingTerminalQueryLocked(data []byte) {
	if len(data) > pendingTerminalQueryLimitBytes {
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
	if mode == "9001" {
		w.win32InputMode = enabled
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
		case 0x9c:
			if !isUtf8ContinuationAt(data, i) {
				return i, 1, true
			}
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

func findStringTerminator(
	data []byte,
) (payloadEnd int, terminatorLength int, ok bool) {
	for index := 0; index < len(data); index++ {
		if data[index] == 0x9c && !isUtf8ContinuationAt(data, index) {
			return index, 1, true
		}
		if data[index] == '\x1b' &&
			index+1 < len(data) &&
			data[index+1] == '\\' {
			return index, 2, true
		}
	}
	return 0, 0, false
}

func isUtf8ContinuationAt(data []byte, index int) bool {
	if index <= 0 || index >= len(data) || data[index]&0xc0 != 0x80 {
		return false
	}
	for start := index - 1; start >= 0 && index-start <= 3; start-- {
		if data[start]&0xc0 == 0x80 {
			continue
		}
		expected := utf8ContinuationCount(data[start])
		return expected > 0 && index-start <= expected
	}
	return false
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
	if w.win32InputMode {
		// ConPTY forwards the child's OSC 4 palette queries out of the pty but
		// swallows its OSC 10/11 default-colour queries, so a colour
		// interrogation observed under win32-input-mode implies the swallowed
		// default foreground/background queries as well. Answering them
		// unprompted is the only way the child ever learns those colours.
		queryKeys = appendThemeQueryKeys(queryKeys, conPtySwallowedThemeQueryKeys)
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
	attach := net.Conn(nil)
	attachClients := make([]*attachClient, 0, len(s.attachClients))
	for _, client := range s.attachClients {
		attachClients = append(attachClients, client)
	}
	if len(attachClients) == 0 {
		attach = s.attachConn
	}
	s.attachConn = nil
	s.attachClients = map[net.Conn]*attachClient{}
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
	for _, client := range attachClients {
		client.close()
	}
	for _, control := range controls {
		_ = control.conn.Close()
	}
	for _, window := range windows {
		if window.proc != nil {
			window.proc.Hangup()
		}
		if window.pty != nil {
			_ = window.closePty(window.pty)
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

func sendResize(session string, clientID string, width int, height int) {
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
		ID:       strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:     "resize",
		ClientID: clientID,
		Width:    width,
		Height:   height,
		Session:  session,
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
