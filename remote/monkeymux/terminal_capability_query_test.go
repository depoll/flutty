package main

import (
	"bufio"
	"strings"
	"testing"
	"time"
)

// xtversionQuery is XTVERSION (CSI > q); da1Query is primary device attributes
// (CSI c). Agents such as Copilot CLI emit these at startup and gate richer
// rendering on the terminal's answers.
const (
	xtversionQuery = "\x1b[>q"
	da1Query       = "\x1b[c"
)

func TestXtversionClassifiedAsReplayUnsafeQuery(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     bool
	}{
		{"xtversion", xtversionQuery, true},
		{"da1", da1Query, true},
		{"da2", "\x1b[>0c", true},
		{"dsr cursor position", "\x1b[6n", true},
		{"decscusr cursor style is not a query", "\x1b[2 q", false},
		{"sgr is not a query", "\x1b[0m", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isReplayUnsafeCsiQuery([]byte(tc.sequence)); got != tc.want {
				t.Fatalf("isReplayUnsafeCsiQuery(%q) = %v, want %v", tc.sequence, got, tc.want)
			}
		})
	}
}

// TestPendingCapabilityQueriesDeliveredOnAttach reproduces the upgrade-restore
// race: an agent window is relaunched and emits its startup capability queries
// while no client is attached. Foreground-redraw windows do not replay history,
// so the queries must be re-delivered to the terminal when it attaches.
func TestPendingCapabilityQueriesDeliveredOnAttach(t *testing.T) {
	server := newMuxServer("cap-attach")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// Detached: the relaunched agent queries the terminal before the client
	// reattaches, so attachConn is still nil.
	server.handleWindowOutput("@1", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery+da1Query {
		t.Fatalf("pending queries = %q, want XTVERSION+DA1 buffered while detached", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	attach := &recordingConn{}
	server.handleAttach(
		attach,
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 80, Height: 24},
	)

	got := attach.String()
	if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
		t.Fatalf("attach output = %q, want XTVERSION+DA1 delivered to terminal", got)
	}

	server.mu.Lock()
	remaining := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("pending queries not cleared after flush: %d bytes remain", remaining)
	}
}

// TestPendingCapabilityQueriesDeliveredOnWindowSwitch covers a restored agent
// window that starts in the background: its startup queries are buffered and
// re-delivered when the user switches to it.
func TestPendingCapabilityQueriesDeliveredOnWindowSwitch(t *testing.T) {
	server := newMuxServer("cap-switch")
	background := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach

	// Background window: not active, so its queries are not forwarded.
	server.handleWindowOutput("@2", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := string(background.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery+da1Query {
		t.Fatalf("pending queries = %q, want XTVERSION+DA1 buffered while backgrounded", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	got := attach.String()
	if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
		t.Fatalf("switch output = %q, want XTVERSION+DA1 delivered to terminal", got)
	}

	server.mu.Lock()
	remaining := len(background.pendingTerminalQueries)
	server.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("pending queries not cleared after switch: %d bytes remain", remaining)
	}
}

// TestCapabilityQueriesNotBufferedWhenTerminalAttached verifies that when a
// terminal is already showing the window, its queries are forwarded live (and
// answered by that terminal), not buffered as pending.
func TestCapabilityQueriesNotBufferedWhenTerminalAttached(t *testing.T) {
	server := newMuxServer("cap-live")
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte(xtversionQuery+da1Query))

	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != 0 {
		t.Fatalf("queries buffered while terminal attached: %d bytes", pending)
	}
	if got := attach.String(); !strings.Contains(got, xtversionQuery) {
		t.Fatalf("attach output = %q, want live-forwarded query", got)
	}
}

// TestPendingCapabilityQuerySplitAcrossReads verifies a query sequence split
// across pty reads is reassembled via the carry buffer.
func TestPendingCapabilityQuerySplitAcrossReads(t *testing.T) {
	server := newMuxServer("cap-split")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("\x1b[>"))
	server.handleWindowOutput("@1", []byte("q"))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery {
		t.Fatalf("pending queries = %q, want reassembled XTVERSION", pending)
	}
}

// stubForegroundResize replaces the foreground-resize hooks with no-ops so tests
// that drive the redraw path do not issue real syscalls, returning a restore
// function.
func stubForegroundResize(t *testing.T) func() {
	t.Helper()
	originalSignal := signalForegroundResize
	originalSimulate := simulateForegroundResize
	originalProcessGroup := foregroundProcessGroupForWindow
	signalForegroundResize = func(int) {}
	simulateForegroundResize = func(*muxWindow, int, int) {}
	foregroundProcessGroupForWindow = func(*muxWindow) int { return 0 }
	return func() {
		signalForegroundResize = originalSignal
		simulateForegroundResize = originalSimulate
		foregroundProcessGroupForWindow = originalProcessGroup
	}
}
