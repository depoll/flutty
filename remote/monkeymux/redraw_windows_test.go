//go:build windows

package main

import (
	"io"
	"reflect"
	"sync"
	"testing"
	"time"
)

type recordedTerminalSize struct {
	width  int
	height int
}

type resizeRecordingPty struct {
	mu    sync.Mutex
	sizes []recordedTerminalSize
}

func (p *resizeRecordingPty) Read([]byte) (int, error) { return 0, io.EOF }

func (p *resizeRecordingPty) Write(data []byte) (int, error) {
	return len(data), nil
}

func (p *resizeRecordingPty) Close() error { return nil }

func (p *resizeRecordingPty) Resize(width int, height int) error {
	p.mu.Lock()
	p.sizes = append(
		p.sizes,
		recordedTerminalSize{width: width, height: height},
	)
	p.mu.Unlock()
	return nil
}

func (p *resizeRecordingPty) Fd() uintptr { return 0 }

func (p *resizeRecordingPty) snapshot() []recordedTerminalSize {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]recordedTerminalSize(nil), p.sizes...)
}

func TestForcedSameSizeRedrawUsesSyntheticWindowsFallback(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	server.attachConn = conn

	originalSimulateForegroundResize := simulateForegroundResize
	t.Cleanup(func() {
		simulateForegroundResize = originalSimulateForegroundResize
	})
	var simulated []string
	simulateForegroundResize = func(
		candidate *muxWindow,
		_ int,
		_ int,
	) {
		simulated = append(simulated, candidate.id)
	}

	server.resizeWithRedraw(120, 40, true, false, "")

	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("same-size redraw fallback = %#v, want [@1]", simulated)
	}
}

func TestForegroundRedrawTemporarySizePrefersHeightOnWindows(t *testing.T) {
	width, height, ok := foregroundRedrawTemporarySize(120, 40)

	if width != 120 || height != 39 || !ok {
		t.Fatalf(
			"temporary Windows redraw size = %dx%d, %t; want 120x39, true",
			width,
			height,
			ok,
		)
	}
}

func TestSingleCellRedrawUsesTemporaryWindowsExpansion(t *testing.T) {
	server := newMuxServerWithSize("test", 1, 1)
	pty := &resizeRecordingPty{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		pty:               pty,
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.attachConn = &recordingConn{}

	server.resizeWithRedraw(1, 1, true, false, "")

	deadline := time.Now().Add(time.Second)
	for len(pty.snapshot()) < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	want := []recordedTerminalSize{
		{width: 1, height: 1},
		{width: 2, height: 1},
		{width: 1, height: 1},
	}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("single-cell redraw sizes = %#v, want %#v", got, want)
	}
}

func TestDeferredSameSizeRedrawKeepsSyntheticWindowsFallback(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		foregroundCommand:        "codex",
		terminalOutputForwarding: true,
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	server.attachConn = conn
	server.attachClients[conn] = &attachClient{
		conn:         conn,
		id:           "primary",
		width:        120,
		height:       40,
		clipViewport: true,
	}

	originalSimulateForegroundResize := simulateForegroundResize
	t.Cleanup(func() {
		simulateForegroundResize = originalSimulateForegroundResize
	})
	var simulated []string
	simulateForegroundResize = func(
		candidate *muxWindow,
		_ int,
		_ int,
	) {
		simulated = append(simulated, candidate.id)
	}

	server.resizeWithRedraw(120, 40, true, false, "")
	if len(simulated) != 0 {
		t.Fatalf("deferred redraw ran before transition settled: %#v", simulated)
	}

	server.mu.Lock()
	window.terminalOutputForwarding = false
	server.mu.Unlock()
	server.refreshPendingViewportResize()

	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("deferred redraw fallback = %#v, want [@1]", simulated)
	}
}

func TestChangedSizeRedrawSkipsSyntheticWindowsFallback(t *testing.T) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	server.attachConn = &recordingConn{}

	originalSimulateForegroundResize := simulateForegroundResize
	t.Cleanup(func() {
		simulateForegroundResize = originalSimulateForegroundResize
	})
	var simulated []string
	simulateForegroundResize = func(
		candidate *muxWindow,
		_ int,
		_ int,
	) {
		simulated = append(simulated, candidate.id)
	}

	server.resizeWithRedraw(100, 30, true, false, "")

	if len(simulated) != 0 {
		t.Fatalf("changed-size redraw used synthetic fallback: %#v", simulated)
	}
}

func TestDeferredChangedSizeRedrawSkipsSyntheticWindowsFallback(
	t *testing.T,
) {
	server := newMuxServerWithSize("test", 120, 40)
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		foregroundCommand:        "codex",
		terminalOutputForwarding: true,
	}
	server.windows = []*muxWindow{window}
	server.activeID = window.id
	conn := &recordingConn{}
	server.attachConn = conn
	server.attachClients[conn] = &attachClient{
		conn:         conn,
		id:           "primary",
		width:        120,
		height:       40,
		clipViewport: true,
	}

	originalSimulateForegroundResize := simulateForegroundResize
	t.Cleanup(func() {
		simulateForegroundResize = originalSimulateForegroundResize
	})
	var simulated []string
	simulateForegroundResize = func(
		candidate *muxWindow,
		_ int,
		_ int,
	) {
		simulated = append(simulated, candidate.id)
	}

	server.resizeWithRedraw(100, 30, true, false, "")
	if len(simulated) != 0 {
		t.Fatalf("deferred resize ran before transition settled: %#v", simulated)
	}

	server.mu.Lock()
	window.terminalOutputForwarding = false
	server.mu.Unlock()
	server.refreshPendingViewportResize()

	if len(simulated) != 0 {
		t.Fatalf(
			"deferred changed-size redraw used synthetic fallback: %#v",
			simulated,
		)
	}
}

func TestSelectWindowDeliversTargetGeometryWithoutIntermediateSize(t *testing.T) {
	// Manufacturing a temporary size on top of a real geometry change makes the
	// foreground app lay out and emit an entire frame for a geometry that never
	// existed. The client paints that frame before the real one replaces it,
	// which is the "wrong size, then it resizes" flash, and on a long agent
	// transcript it doubles the bytes crossing the wire.
	server := newMuxServerWithSize("test", 80, 24)
	pty := &resizeRecordingPty{}
	target := &muxWindow{
		id:                "@2",
		index:             1,
		foregroundCommand: "codex",
		pty:               pty,
		ptyWidth:          59,
		ptyHeight:         47,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		target,
	}
	server.activeID = "@1"
	conn := &recordingConn{}
	client := newAttachClient(conn, controlMessage{
		ClientID:     "phone",
		Width:        80,
		Height:       24,
		ClipViewport: true,
	})
	t.Cleanup(client.close)
	server.mu.Lock()
	server.attachClients[conn] = client
	server.attachConn = conn
	server.mu.Unlock()

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	time.Sleep(4 * foregroundRedrawResizeDelay)
	want := []recordedTerminalSize{{width: 80, height: 24}}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("switch resizes = %#v, want %#v", got, want)
	}
}

func TestForegroundRedrawKeepsSyntheticSizeWhenGeometryIsUnchanged(t *testing.T) {
	// With no real size change to deliver there is nothing for the app to
	// notice, so the temporary size is the only way to ask for a repaint.
	pty := &resizeRecordingPty{}
	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "codex",
		pty:               pty,
		ptyWidth:          80,
		ptyHeight:         24,
	}

	deliverForegroundGeometry(window, 80, 24)

	deadline := time.Now().Add(time.Second)
	for len(pty.snapshot()) < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	want := []recordedTerminalSize{
		{width: 80, height: 23},
		{width: 80, height: 24},
	}
	if got := pty.snapshot(); !reflect.DeepEqual(got, want) {
		t.Fatalf("same-size redraw sizes = %#v, want %#v", got, want)
	}
}
