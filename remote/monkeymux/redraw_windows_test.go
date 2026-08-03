//go:build windows

package main

import (
	"reflect"
	"testing"
)

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
