package main

import (
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestResolveStartupDirectoryFallsBackToNearestAncestor(t *testing.T) {
	base := t.TempDir()
	missing := filepath.Join(base, "removed", "child")

	if got := resolveStartupDirectory(base); got != base {
		t.Fatalf("resolveStartupDirectory(existing) = %q, want %q", got, base)
	}
	if got := resolveStartupDirectory(missing); got != base {
		t.Fatalf("resolveStartupDirectory(missing) = %q, want nearest ancestor %q", got, base)
	}

	// A blank request falls back to a directory that exists rather than "".
	if got := resolveStartupDirectory("  "); !directoryExists(got) {
		t.Fatalf("resolveStartupDirectory(blank) = %q, want an existing directory", got)
	}
}

// TestRestoreKeepsWindowsWithMissingCwd reproduces the "does not restore all my
// windows" regression: a restored window whose saved working directory no
// longer exists must still be recreated (falling back to an existing directory)
// instead of being silently dropped.
func TestRestoreKeepsWindowsWithMissingCwd(t *testing.T) {
	base := t.TempDir()
	missing := filepath.Join(base, "worktree-removed-after-upgrade")

	server := newMuxServerWithSize("restore-cwd", 100, 30)
	t.Cleanup(server.close)

	restore := &serverRestore{
		SchemaVersion: restoreSchemaVersion,
		Windows: []restoreWindowState{
			{ID: "@1", Index: 0, Name: "kept", Cwd: base, Active: true},
			{ID: "@2", Index: 1, Name: "missing", Cwd: missing},
			{ID: "@3", Index: 2, Name: "blank", Cwd: ""},
		},
	}
	if err := server.restoreOrCreateInitialWindow(restore, createWindowOptions{}); err != nil {
		t.Fatalf("restoreOrCreateInitialWindow: %v", err)
	}

	snaps := server.snapshots()
	if len(snaps) != 3 {
		t.Fatalf("restored %d windows, want 3: %+v", len(snaps), snaps)
	}

	byName := map[string]windowSnapshot{}
	for _, snap := range snaps {
		byName[snap.Name] = snap
	}
	missingWindow, ok := byName["missing"]
	if !ok {
		t.Fatalf("window with missing cwd was dropped: %+v", snaps)
	}
	if missingWindow.CurrentPath != base {
		t.Fatalf("missing-cwd window path = %q, want fallback to %q", missingWindow.CurrentPath, base)
	}
	if _, ok := byName["kept"]; !ok {
		t.Fatalf("kept window missing from restore: %+v", snaps)
	}
	if _, ok := byName["blank"]; !ok {
		t.Fatalf("blank-cwd window missing from restore: %+v", snaps)
	}
}

func withStubbedRestoreRedraw(t *testing.T) *[]func() {
	t.Helper()
	var mu sync.Mutex
	actions := &[]func(){}
	originalSchedule := scheduleRestoreRedraw
	originalSimulate := simulateForegroundResize
	originalSignal := signalForegroundResize
	originalPgrp := foregroundProcessGroupForWindow
	t.Cleanup(func() {
		scheduleRestoreRedraw = originalSchedule
		simulateForegroundResize = originalSimulate
		signalForegroundResize = originalSignal
		foregroundProcessGroupForWindow = originalPgrp
	})
	scheduleRestoreRedraw = func(_ time.Duration, action func()) {
		mu.Lock()
		*actions = append(*actions, action)
		mu.Unlock()
	}
	// Keep redraw side effects inert and off real PTYs/process groups.
	simulateForegroundResize = func(*muxWindow, int, int) {}
	signalForegroundResize = func(int) {}
	foregroundProcessGroupForWindow = func(*muxWindow) int { return 0 }
	return actions
}

// TestRestoreArmsForegroundRedrawFollowUps covers the "restored windows don't
// render until resized" regression: a restored agent window that becomes
// visible schedules follow-up redraws (so a slow-to-start agent is repainted
// without the user resizing), and each follow-up forces a redraw.
func TestRestoreArmsForegroundRedrawFollowUps(t *testing.T) {
	actions := withStubbedRestoreRedraw(t)

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(simulated, window.id)
	}

	server := newMuxServer("restore-redraw")
	server.width = 120
	server.height = 40
	window := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "claude",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		window,
	}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach
	server.markRestoreRedrawPending([]string{"@2"})

	if err := server.selectWindow("@2"); err != nil {
		t.Fatalf("selectWindow: %v", err)
	}
	if len(*actions) != len(restoreRedrawFollowUpDelays) {
		t.Fatalf("scheduled %d follow-ups, want %d", len(*actions), len(restoreRedrawFollowUpDelays))
	}

	before := len(simulated)
	(*actions)[0]()
	if len(simulated) != before+1 || simulated[len(simulated)-1] != "@2" {
		t.Fatalf("follow-up did not force a redraw of @2: %#v", simulated)
	}

	// Follow-ups are armed only once per restored window.
	*actions = (*actions)[:0]
	if err := server.selectWindow("@2"); err != nil {
		t.Fatalf("selectWindow (second): %v", err)
	}
	if len(*actions) != 0 {
		t.Fatalf("re-armed %d follow-ups on second select, want 0", len(*actions))
	}
}

func TestRestoreRedrawFollowUpSkipsInactiveOrDetachedWindow(t *testing.T) {
	withStubbedRestoreRedraw(t)

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(simulated, window.id)
	}

	server := newMuxServer("restore-redraw-skip")
	server.width = 100
	server.height = 30
	window := &muxWindow{id: "@1", index: 0, agentTool: "codex", lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	attach := &recordingConn{}
	server.attachConn = attach

	// Not the active window anymore.
	server.activeID = "@other"
	server.redrawRestoredWindow(attach, "@1")
	if len(simulated) != 0 {
		t.Fatalf("redraw fired for non-active window: %#v", simulated)
	}

	// Active again but a different client is attached.
	server.activeID = "@1"
	server.redrawRestoredWindow(&recordingConn{}, "@1")
	if len(simulated) != 0 {
		t.Fatalf("redraw fired for detached client: %#v", simulated)
	}

	// Active and attached: the redraw runs.
	server.redrawRestoredWindow(attach, "@1")
	if !reflect.DeepEqual(simulated, []string{"@1"}) {
		t.Fatalf("redraw did not run for active attached window: %#v", simulated)
	}
}

func TestScheduleRestoreRedrawFollowUpsIgnoresNilConn(t *testing.T) {
	actions := withStubbedRestoreRedraw(t)
	server := newMuxServer("restore-redraw-nil")
	server.markRestoreRedrawPending([]string{"@1"})

	server.scheduleRestoreRedrawFollowUps(nil, "@1")
	if len(*actions) != 0 {
		t.Fatalf("scheduled follow-ups without an attached client: %d", len(*actions))
	}
	// The pending entry is preserved for the next real attach.
	if !server.restoreRedrawPending["@1"] {
		t.Fatal("pending redraw entry was consumed without an attached client")
	}
}
