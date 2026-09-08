package main

import (
	"bufio"
	"bytes"
	"io"
	"net"
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

// Keep the terminal attached until queued writes have been observed. An empty
// reader disconnects immediately and races the asynchronous query flush.
func startCapabilityTestAttach(t *testing.T, server *muxServer, hello controlMessage) (*recordingConn, func()) {
	t.Helper()
	input, writer := io.Pipe()
	attach := &recordingConn{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleAttach(attach, bufio.NewReader(input), hello)
	}()
	return attach, func() {
		_ = writer.Close()
		defer input.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("attach handler did not stop after disconnect")
		}
	}
}

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

	window.appendPendingTerminalQueriesLocked(query, nil, nil)

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

	attach, detach := startCapabilityTestAttach(t, server, controlMessage{Width: 80, Height: 24})
	defer detach()

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

// TestCapabilityHintDefersFenceAfterProbeEarlierInChunk covers the gate closing
// mid-chunk: the buffer starts empty, so XTVERSION is answered, but the DECRQM
// probe that follows cannot be answered and buffers, which must then defer the
// DA1 fence behind it even though nothing was pending when the chunk began.
func TestCapabilityHintDefersFenceAfterProbeEarlierInChunk(t *testing.T) {
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

// TestCapabilityHintIsNotBorrowedFromAnotherClient pins the hint to the client
// that sent it. A client that declares no capabilities — an older helper, or a
// plain terminal running `monkeymux attach` — must not have the previous
// client's terminal identity advertised to its windows.
func TestCapabilityHintIsNotBorrowedFromAnotherClient(t *testing.T) {
	server := newMuxServer("cap-hint-client")
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
	// The session was started by a client that declared its capabilities, but
	// the client attached now did not.
	server.capabilityHint = []byte(capabilityHintFixture)
	conn := &recordingConn{}
	server.attachConn = conn
	server.attachClients = map[net.Conn]*attachClient{
		conn: {conn: conn, id: "legacy"},
	}

	server.handleWindowOutput("@2", []byte(xtversionQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no reply for a hintless client", got)
	}
	server.mu.Lock()
	pending := string(background.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != xtversionQuery {
		t.Fatalf("pending queries = %q, want the probe buffered for replay", pending)
	}
}

// TestCapabilityHintDefersFenceBehindProbeSplitAcrossReads pins the fence gate
// across pty reads. A probe can arrive split in half, so the gate must still see
// it: the carry is prepended and rescanned at the front of the next chunk, which
// buffers the probe before the DA1 fence later in that same chunk is examined.
func TestCapabilityHintDefersFenceBehindProbeSplitAcrossReads(t *testing.T) {
	server := newMuxServer("cap-hint-split-fence")
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

	// DECRQM for synchronized output, split mid-sequence across two reads.
	server.handleWindowOutput("@1", []byte("\x1b[?2026"))
	server.handleWindowOutput("@1", []byte("$p"+da1Query))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want the fence left unanswered", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != "\x1b[?2026$p"+da1Query {
		t.Fatalf(
			"pending queries = %q, want the reassembled probe and its fence",
			pending,
		)
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

// TestCapabilityAnswerBudgetResetsWhenWindowIsShown pins the budget reset to
// window visibility rather than to output: a window whose budget was spent
// while unwatched must be able to answer probes again after the user visits it,
// even if it produced nothing while it was on screen.
func TestCapabilityAnswerBudgetResetsWhenWindowIsShown(t *testing.T) {
	restore := stubForegroundResize(t)
	defer restore()

	server := newMuxServer("cap-hint-budget-reset")
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

	// Spend the budget while no terminal is attached.
	server.handleWindowOutput("@1", []byte(strings.Repeat(xtversionQuery, 4096)))
	spent := len(pty.String())
	if spent == 0 || spent > pendingTerminalQueryLimitBytes {
		t.Fatalf("spent %d reply bytes, want a bounded non-zero burst", spent)
	}
	server.handleWindowOutput("@1", []byte(xtversionQuery))
	if got := len(pty.String()); got != spent {
		t.Fatalf("answered %d more bytes with the budget spent", got-spent)
	}

	// A terminal attaches and shows the window without it producing output.
	attach := &recordingConn{}
	server.handleAttach(
		attach,
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 80, Height: 24},
	)

	server.mu.Lock()
	remaining := window.capabilityAnswerBytes
	server.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("budget = %d after the window was shown, want a reset", remaining)
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

// themeHintFixture is the wire-format theme hint MonkeySSH sends on attach: the
// colour-scheme mode report for the client's current theme followed by the OSC
// colour replies the daemon answers palette queries from.
const themeHintFixture = "\x1b[?997;1n" +
	"\x1b]10;rgb:d7d7/e7e7/e3e3\x1b\\" +
	"\x1b]11;rgb:0d0d/1a1a/2020\x1b\\"

// colorSchemeQuery is the DEC colour-scheme status query (CSI ? 996 n). Agents
// such as Copilot CLI emit it at startup to pick a light or dark theme.
const colorSchemeQuery = "\x1b[?996n"

// TestThemeHintAnswersColorSchemeQueryWhileDetached covers the stray-report
// regression: an agent asks whether the terminal is light or dark while its
// window runs unwatched. Buffering that query replays it to the terminal on the
// next attach, and by then the agent may be gone — leaving its `CSI ?997;1n`
// reply echoed as literal `^[[?997;1n` text at the window's shell prompt. The
// cached theme hint holds the answer, so the daemon must answer it right away.
func TestThemeHintAnswersColorSchemeQueryWhileDetached(t *testing.T) {
	server := newMuxServer("theme-hint-detached")
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
	server.themeHint = []byte(themeHintFixture)
	server.capabilityHint = []byte(capabilityHintFixture)

	server.handleWindowOutput("@1", []byte(colorSchemeQuery))

	if got := pty.String(); got != "\x1b[?997;1n" {
		t.Fatalf("window pty got = %q, want the dark colour-scheme report", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != "" {
		t.Fatalf("answered colour-scheme query still buffered: %q", pending)
	}
}

// TestThemeHintAnswersColorSchemeQueryBehindBufferedProbe pins the ordering
// contract: the colour-scheme query is a standalone probe, never a probe group
// terminator, so — like XTVERSION — it is answered even while an unanswerable
// query is already waiting on the terminal.
func TestThemeHintAnswersColorSchemeQueryBehindBufferedProbe(t *testing.T) {
	server := newMuxServer("theme-hint-behind-probe")
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
	server.themeHint = []byte(themeHintFixture)

	const cursorPositionQuery = "\x1b[6n"
	server.handleWindowOutput("@1", []byte(cursorPositionQuery+colorSchemeQuery))

	if got := pty.String(); got != "\x1b[?997;1n" {
		t.Fatalf("window pty got = %q, want the colour-scheme report", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != cursorPositionQuery {
		t.Fatalf("pending queries = %q, want only the cursor position query", pending)
	}
}

// TestColorSchemeQueryBufferedWithoutThemeHint keeps the fallback: a client that
// sent no theme hint (an older helper, or a plain `monkeymux attach`) leaves the
// daemon without an answer, so the query must still reach the terminal.
func TestColorSchemeQueryBufferedWithoutThemeHint(t *testing.T) {
	server := newMuxServer("theme-hint-missing")
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

	server.handleWindowOutput("@1", []byte(colorSchemeQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no synthesized answer", got)
	}
	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != colorSchemeQuery {
		t.Fatalf("pending queries = %q, want the colour-scheme query buffered", pending)
	}
}

// TestColorSchemeQueryForwardedLiveWhenTerminalAttached verifies the live path
// is untouched: a terminal showing the window answers the query itself with its
// current theme, so the daemon must not short circuit it from a cached hint.
func TestColorSchemeQueryForwardedLiveWhenTerminalAttached(t *testing.T) {
	server := newMuxServer("theme-hint-live")
	pty := &recordingPty{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		pty:          pty,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach
	server.themeHint = []byte(themeHintFixture)

	server.handleWindowOutput("@1", []byte(colorSchemeQuery))

	if got := pty.String(); got != "" {
		t.Fatalf("window pty got = %q, want no synthesized answer", got)
	}
	if got := attach.String(); !strings.Contains(got, colorSchemeQuery) {
		t.Fatalf("attach output = %q, want the live-forwarded query", got)
	}
	server.mu.Lock()
	pending := len(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != 0 {
		t.Fatalf("queries buffered while terminal attached: %d bytes", pending)
	}
}

// TestIsTerminalColorSchemeQuery covers the sequence matcher, including the C1
// form and the neighbouring DSR queries it must not claim.
func TestIsTerminalColorSchemeQuery(t *testing.T) {
	cases := []struct {
		name     string
		sequence string
		want     bool
	}{
		{"csi form", colorSchemeQuery, true},
		{"c1 form", string([]byte{0x9b}) + "?996n", true},
		{"colour scheme report is not a query", "\x1b[?997;1n", false},
		{"cursor position dsr", "\x1b[6n", false},
		{"private cursor position dsr", "\x1b[?6n", false},
		{"other private dsr", "\x1b[?9960n", false},
		{"not a dsr final byte", "\x1b[?996c", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isTerminalColorSchemeQuery([]byte(tc.sequence)); got != tc.want {
				t.Fatalf(
					"isTerminalColorSchemeQuery(%q) = %v, want %v",
					tc.sequence,
					got,
					tc.want,
				)
			}
		})
	}
}

// TestBufferedColorSchemeQueryDroppedOnFlush covers a session the daemon had no
// theme hint for when the query was emitted — one started outside MonkeySSH, or
// by a client that declared no theme. The query is buffered, and by the time a
// terminal attaches its reply can no longer be timely: it reaches the window pty
// as input, so a shell now sitting at the prompt would echo it as literal
// `^[[?997;1n` text. Drop it on flush and replay only the rest.
func TestBufferedColorSchemeQueryDroppedOnFlush(t *testing.T) {
	server := newMuxServer("theme-hint-late")
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

	// No theme hint cached yet, so the query has to be buffered.
	server.handleWindowOutput("@1", []byte(colorSchemeQuery+da1Query))

	server.mu.Lock()
	pending := string(window.pendingTerminalQueries)
	server.mu.Unlock()
	if pending != colorSchemeQuery+da1Query {
		t.Fatalf("pending queries = %q, want both queries buffered", pending)
	}

	restore := stubForegroundResize(t)
	defer restore()

	attach, detach := startCapabilityTestAttach(t, server, controlMessage{Width: 80, Height: 24, Data: themeHintFixture})
	defer detach()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(attach.String(), da1Query) {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if got := attach.String(); !strings.Contains(got, da1Query) {
		t.Fatalf("attach output = %q, want DA1 still replayed to the terminal", got)
	}
	if got := attach.String(); strings.Contains(got, colorSchemeQuery) {
		t.Fatalf("attach output = %q, want the stale colour-scheme query dropped", got)
	}
	if got := pty.String(); strings.Contains(got, "\x1b[?997;1n") {
		t.Fatalf("window pty got = %q, want no late colour-scheme report", got)
	}
}

// TestDropStaleTerminalQueries covers the flush-time filter, including a buffer
// that holds nothing else and one whose tail is a partial sequence.
func TestDropStaleTerminalQueries(t *testing.T) {
	cases := []struct {
		name    string
		pending string
		want    string
	}{
		{
			name:    "keeps other queries in order",
			pending: xtversionQuery + colorSchemeQuery + da1Query + colorSchemeQuery,
			want:    xtversionQuery + da1Query,
		},
		{"drops a colour-scheme only buffer", colorSchemeQuery, ""},
		{"drops a clipboard-only buffer", "\x1b]52;c;?\a", ""},
		{"drops a clipboard query with ST", "\x1b]52;;?\x1b\\", ""},
		{"drops a C1 clipboard query", "\x9d52;p;?\x9c", ""},
		{"preserves a clipboard write", "\x1b]52;c;SGVsbG8=\a", "\x1b]52;c;SGVsbG8=\a"},
		{"preserves a clipboard clear", "\x1b]52;c;\a", "\x1b]52;c;\a"},
		{"keeps probes around clipboard reads", xtversionQuery + "\x1b]52;c;?\a" + da1Query, xtversionQuery + da1Query},
		{"keeps a buffer with no colour-scheme query", da1Query, da1Query},
		{"preserves a partial trailing sequence", colorSchemeQuery + "\x1b[>", "\x1b[>"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := string(dropStaleTerminalQueries([]byte(tc.pending)))
			if got != tc.want {
				t.Fatalf("dropStaleTerminalQueries(%q) = %q, want %q", tc.pending, got, tc.want)
			}
		})
	}
}

// Restored agents can query the clipboard before a terminal attaches. These
// requests must not trigger paste permission prompts when replayed later.
func TestBackgroundClipboardQueriesNotDelivered(t *testing.T) {
	for _, onSwitch := range []bool{false, true} {
		name := "attach"
		if onSwitch {
			name = "window switch"
		}
		t.Run(name, func(t *testing.T) {
			server := newMuxServer("clipboard-restore")
			window := &muxWindow{id: "@1", index: 0, agentTool: "copilot", lastActivity: time.Now()}
			server.windows = []*muxWindow{window}
			server.activeID = "@1"
			if onSwitch {
				server.windows = append(server.windows, &muxWindow{id: "@2", index: 1, lastActivity: time.Now()})
				server.activeID = "@2"
			}
			restore := stubForegroundResize(t)
			defer restore()
			var attach *recordingConn
			if onSwitch {
				attach = &recordingConn{}
				server.attachConn = attach
			}
			// Split reads and both OSC encodings among real capability probes.
			server.handleWindowOutput("@1", []byte(xtversionQuery+"\x1b]52;c;"))
			server.handleWindowOutput("@1", []byte("?\a"+"\x9d52;p;?\x1b\\"+da1Query))
			if onSwitch {
				if err := server.selectWindow("@1"); err != nil {
					t.Fatal(err)
				}
			} else {
				var detach func()
				attach, detach = startCapabilityTestAttach(t, server, controlMessage{Width: 80, Height: 24})
				defer detach()
			}
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) && !strings.Contains(attach.String(), da1Query) {
				time.Sleep(time.Millisecond)
			}
			got := attach.String()
			if strings.Contains(got, "52;") {
				t.Fatalf("stale clipboard query delivered to terminal: %q", got)
			}
			if !strings.Contains(got, xtversionQuery) || !strings.Contains(got, da1Query) {
				t.Fatalf("capability queries missing from terminal output: %q", got)
			}
		})
	}
}

func TestLiveClipboardQueryStillDelivered(t *testing.T) {
	server := newMuxServer("clipboard-live")
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach
	query := "\x1b]52;c;?\a"
	server.handleWindowOutput("@1", []byte(query))
	if got := attach.String(); !strings.Contains(got, query) {
		t.Fatalf("live clipboard query missing from terminal output: %q", got)
	}
}
