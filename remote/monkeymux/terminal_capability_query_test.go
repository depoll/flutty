package main

import (
	"bufio"
	"bytes"
	"io"
	"strings"
	"sync"
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

// capabilityHintFixture is the wire-format hint MonkeySSH sends on attach: the
// static replies its terminal gives for XTVERSION and the device attribute /
// status queries agents emit at startup.
const capabilityHintFixture = "da1\x1f\x1b[?62;22c" +
	"\x1e" + "da2\x1f\x1b[>1;0;0c" +
	"\x1e" + "da3\x1f\x1bP!|00000000\x1b\\" +
	"\x1e" + "xtversion\x1f\x1bP>|kitty(0.32.0)\x1b\\" +
	"\x1e" + "dsr\x1f\x1b[0n"

func TestXtversionClassifiedAsReplayUnsafeQuery(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     bool
	}{
		{"xtversion", xtversionQuery, true},
		{"da1", da1Query, true},
		{"da2", "\x1b[>0c", true},
		{"c1 da1", string([]byte{0x9b, 'c'}), true},
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

func TestC1CapabilityQueryBufferedWhileDetached(t *testing.T) {
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	query := []byte{0x9b, 'c'}

	window.appendPendingTerminalQueriesLocked(query, nil)

	if got := string(window.pendingTerminalQueries); got != string(query) {
		t.Fatalf("pending C1 query = %q, want %q", got, query)
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

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		got := attach.String()
		if strings.Contains(got, xtversionQuery) && strings.Contains(got, da1Query) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	got := attach.String()
	if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
		t.Fatalf(
			"attach output = %q, want XTVERSION+DA1 delivered to terminal",
			got,
		)
	}

	remaining := -1
	for time.Now().Before(deadline) {
		server.mu.Lock()
		remaining = len(window.pendingTerminalQueries) +
			len(window.pendingTerminalQueriesInFlight)
		server.mu.Unlock()
		if remaining == 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
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

// TestCapabilityHintAnswersQueriesWhileDetached covers the upgrade-restore
// regression directly: with the client's capability hint cached, a relaunched
// agent's startup probes are answered immediately instead of waiting for a
// reattach, so it keeps its richer rendering mode.
func TestCapabilityHintAnswersQueriesWhileDetached(t *testing.T) {
	server := newMuxServer("cap-hint-detached")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput("@1", []byte(xtversionQuery+da1Query))

	want := "\x1bP>|kitty(0.32.0)\x1b\\\x1b[?62;22c"
	if got := pty.String(); got != want {
		t.Fatalf("window pty got = %q, want %q", got, want)
	}
	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != 0 {
		t.Fatalf("answered queries still buffered: %d bytes", pending)
	}
}

// TestCapabilityHintAnswersBackgroundWindowQueries covers a restored agent
// window that starts behind the active one: the daemon answers its probes on
// its own pty without disturbing the window the user is looking at.
func TestCapabilityHintAnswersBackgroundWindowQueries(t *testing.T) {
	server := newMuxServer("cap-hint-background")
	pty := &recordingPty{}
	background := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		background,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach
	server.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput("@2", []byte(xtversionQuery))

	if got := pty.String(); got != "\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("background pty got = %q, want the XTVERSION reply", got)
	}
	if got := attach.String(); got != "" {
		t.Fatalf("attach output = %q, want nothing for a background window", got)
	}
}

// TestCapabilityHintLeavesStatefulQueriesBuffered verifies the hint only short
// circuits queries whose answer is constant for a terminal. A cursor position
// report depends on live state, so it must still reach the client.
func TestCapabilityHintLeavesStatefulQueriesBuffered(t *testing.T) {
	server := newMuxServer("cap-hint-stateful")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	const cursorPositionQuery = "\x1b[6n"
	server.handleWindowOutput("@1", []byte(cursorPositionQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no synthesized answer", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != cursorPositionQuery {
		t.Fatalf("pending queries = %q, want the cursor position query", pending)
	}
}

// TestCapabilityHintDefersFenceQueryBehindUnansweredProbe covers the probe
// group contract: agents send capability probes the daemon cannot answer (a
// kitty graphics query here) and terminate the group with DA1. Answering that
// fence from the hint would tell the agent the group is over before the kitty
// reply exists, so the whole group must stay on the buffer-and-replay path.
func TestCapabilityHintDefersFenceQueryBehindUnansweredProbe(t *testing.T) {
	server := newMuxServer("cap-hint-fence")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	const kittyGraphicsQuery = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
	server.handleWindowOutput("@1", []byte(kittyGraphicsQuery+da1Query))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want the fence left unanswered", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != kittyGraphicsQuery+da1Query {
		t.Fatalf(
			"pending queries = %q, want the whole probe group in emission order",
			pending,
		)
	}
}

// TestCapabilityHintAnswersFenceOnceProbeGroupIsEmpty is the companion case:
// with nothing buffered, a standalone XTVERSION probe emitted before the
// unanswerable ones is still answered immediately, which is what restores the
// agent's richer rendering mode.
func TestCapabilityHintAnswersFenceOnceProbeGroupIsEmpty(t *testing.T) {
	server := newMuxServer("cap-hint-order")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	const decrqmQuery = "\x1b[?2026$p"
	server.handleWindowOutput("@1", []byte(xtversionQuery+decrqmQuery+da1Query))

	if got := pty.String(); got != "\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("window pty got = %q, want only the XTVERSION reply", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != decrqmQuery+da1Query {
		t.Fatalf("pending queries = %q, want the unanswered probe group", pending)
	}
}

// TestCapabilityHintAnswersTerminalVersionBehindUnansweredProbe pins the
// exception to the fence rule: XTVERSION never terminates a probe group, so it
// is answered even while an unanswerable probe waits. This is the reply that
// decides an agent's composer rendering, so deferring it would leave the
// upgrade-restore bug unfixed whenever a probe the daemon cannot answer happens
// to come first.
func TestCapabilityHintAnswersTerminalVersionBehindUnansweredProbe(t *testing.T) {
	server := newMuxServer("cap-hint-version")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	const kittyGraphicsQuery = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
	server.handleWindowOutput(
		"@1",
		[]byte(kittyGraphicsQuery+xtversionQuery+da1Query),
	)

	if got := pty.String(); got != "\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("window pty got = %q, want only the XTVERSION reply", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != kittyGraphicsQuery+da1Query {
		t.Fatalf(
			"pending queries = %q, want the kitty probe and its DA1 fence",
			pending,
		)
	}
}

// TestCapabilityHintAnswerBurstIsBounded guards the pty write path: output
// replayed into a background window (ANSI art, a terminal recording) can carry
// thousands of device attribute queries, and an unbounded synthetic reply burst
// would block the window's reader goroutine on a child that is not draining its
// input.
func TestCapabilityHintAnswerBurstIsBounded(t *testing.T) {
	server := newMuxServer("cap-hint-burst")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput(
		"@1",
		[]byte(strings.Repeat(da1Query, 4096)),
	)

	if got := len(pty.String()); got > pendingTerminalQueryLimitBytes {
		t.Fatalf(
			"wrote %d reply bytes to the pty, want at most %d",
			got,
			pendingTerminalQueryLimitBytes,
		)
	}
	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending > pendingTerminalQueryLimitBytes {
		t.Fatalf("buffered %d bytes, want at most %d", pending, pendingTerminalQueryLimitBytes)
	}

	// The buffer is now full, so later chunks must not resume answering fences.
	before := len(pty.String())
	server.handleWindowOutput("@1", []byte(da1Query))
	if got := len(pty.String()); got != before {
		t.Fatalf("wrote %d more reply bytes after the buffer filled", got-before)
	}
}

// TestCapabilityHintVersionAnswersAreBoundedAcrossChunks verifies the XTVERSION
// exemption from the fence gate is still bounded per window: it is never gated
// by the pending buffer, so only the running answer budget keeps a stream of
// XTVERSION queries in unwatched output from flooding the child's stdin.
func TestCapabilityHintVersionAnswersAreBoundedAcrossChunks(t *testing.T) {
	server := newMuxServer("cap-hint-version-burst")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.capabilityHint = []byte(capabilityHintFixture)

	for chunk := 0; chunk < 64; chunk++ {
		server.handleWindowOutput("@1", []byte(strings.Repeat(xtversionQuery, 64)))
	}

	if got := len(pty.String()); got > pendingTerminalQueryLimitBytes {
		t.Fatalf(
			"wrote %d reply bytes across chunks, want at most %d",
			got,
			pendingTerminalQueryLimitBytes,
		)
	}
	if got := len(pty.String()); got == 0 {
		t.Fatal("wrote no replies at all, want the budget spent on real answers")
	}
}

func TestCapabilityQueryKeyMapsStaticQueries(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     string
	}{
		{"da1", da1Query, capabilityHintKeyPrimaryDeviceAttributes},
		{"da1 zero", "\x1b[0c", capabilityHintKeyPrimaryDeviceAttributes},
		{
			"c1 da1",
			string([]byte{0x9b, 'c'}),
			capabilityHintKeyPrimaryDeviceAttributes,
		},
		{"da2", "\x1b[>0c", capabilityHintKeySecondaryDeviceAttributes},
		{"da3", "\x1b[=c", capabilityHintKeyTertiaryDeviceAttributes},
		{"xtversion", xtversionQuery, capabilityHintKeyTerminalVersion},
		{"dsr status", "\x1b[5n", capabilityHintKeyDeviceStatus},
		{"cursor position", "\x1b[6n", ""},
		{"decrqm", "\x1b[?2026$p", ""},
		{"kitty keyboard", "\x1b[?u", ""},
		{"window size", "\x1b[14t", ""},
		{"decscusr", "\x1b[2 q", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := capabilityQueryKey([]byte(tc.sequence)); got != tc.want {
				t.Fatalf(
					"capabilityQueryKey(%q) = %q, want %q",
					tc.sequence,
					got,
					tc.want,
				)
			}
		})
	}
}

func TestCapabilityHintResponseMapParsesRecords(t *testing.T) {
	responses := capabilityHintResponseMap([]byte(capabilityHintFixture))
	if got := string(responses[capabilityHintKeyTerminalVersion]); got !=
		"\x1bP>|kitty(0.32.0)\x1b\\" {
		t.Fatalf("xtversion reply = %q", got)
	}
	if got := string(responses[capabilityHintKeyDeviceStatus]); got != "\x1b[0n" {
		t.Fatalf("dsr reply = %q", got)
	}
	if got := len(responses); got != 5 {
		t.Fatalf("parsed %d replies, want 5", got)
	}
	if capabilityHintResponseMap(nil) != nil {
		t.Fatal("empty hint should parse to no replies")
	}
	if capabilityHintResponseMap([]byte("garbage")) != nil {
		t.Fatal("record without a field separator should be ignored")
	}
}

// recordingPty is a muxPty that captures everything written to the window's
// child, so capability replies can be asserted without a real terminal.
type recordingPty struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (p *recordingPty) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (p *recordingPty) Write(data []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.buf.Write(data)
}

func (p *recordingPty) Close() error {
	return nil
}

func (p *recordingPty) Resize(int, int) error {
	return nil
}

func (p *recordingPty) Fd() uintptr {
	return 0
}

func (p *recordingPty) String() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.buf.String()
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
