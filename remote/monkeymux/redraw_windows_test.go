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
