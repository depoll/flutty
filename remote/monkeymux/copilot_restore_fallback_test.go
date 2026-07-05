package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeCopilotSession creates a fake ~/.copilot/session-state/<id> dir with a
// session.start events log recording cwd and, optionally, an inuse.<pid>.lock.
// The events log mtime (session recency) and the lock mtime are set to modTime.
func writeCopilotSession(
	t *testing.T,
	stateDir string,
	id string,
	cwd string,
	lockPid int,
	modTime time.Time,
) {
	t.Helper()
	dir := filepath.Join(stateDir, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	events := `{"type":"session.start","data":{"sessionId":"` + id +
		`","context":{"cwd":"` + cwd + `"}}}` + "\n"
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte(events), 0o600); err != nil {
		t.Fatal(err)
	}
	if !modTime.IsZero() {
		if err := os.Chtimes(eventsPath, modTime, modTime); err != nil {
			t.Fatal(err)
		}
	}
	if lockPid > 0 {
		lock := filepath.Join(dir, "inuse."+itoaPositive(lockPid)+".lock")
		if err := os.WriteFile(lock, []byte(itoaPositive(lockPid)), 0o644); err != nil {
			t.Fatal(err)
		}
		if !modTime.IsZero() {
			if err := os.Chtimes(lock, modTime, modTime); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func itoaPositive(n int) string {
	if n == 0 {
		return "0"
	}
	buf := []byte{}
	for n > 0 {
		buf = append([]byte{byte('0' + n%10)}, buf...)
		n /= 10
	}
	return string(buf)
}

// TestDiscoverCopilotSessionIDsPrefersFreshSessionOnStaleLock reproduces the
// stale-lock overwrite: a stale inuse lock whose PID was reused by a live
// copilot must not shadow the live session just because its dir name sorts
// later. Discovery keeps the freshest (most recently locked) session for a
// pane.
func TestDiscoverCopilotSessionIDsPrefersFreshSessionOnStaleLock(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	stateDir := filepath.Join(home, ".copilot", "session-state")

	now := time.Now()
	// The live session was locked seconds ago; the stale dir (whose lock PID
	// 201 was reused) was locked long ago but sorts AFTER the live one.
	writeCopilotSession(t, stateDir, "aaa-live", "/work", 201, now)
	writeCopilotSession(t, stateDir, "zzz-stale", "/work", 201, now.Add(-72*time.Hour))

	processes := map[int]processInfo{
		200: {pid: 200, ppid: 1, comm: "copilot", args: "copilot"},
		201: {pid: 201, ppid: 200, comm: "copilot", args: "/opt/copilot"},
	}
	got := discoverCopilotSessionIDs(processes, map[int]struct{}{200: {}})
	if got[200] != "aaa-live" {
		t.Fatalf("pane 200 -> %q, want fresh session aaa-live (not the stale-lock dir)", got[200])
	}
}

// TestEnrichRestoreCopilotFallsBackToCwd covers the core regression: when the
// live process table no longer maps a restored copilot window to its session
// (here: an empty process table, as after a slow ps or a reaped process), the
// window still resumes the most recent copilot session recorded for its cwd
// instead of relaunching blank.
func TestEnrichRestoreCopilotFallsBackToCwd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	stateDir := filepath.Join(home, ".copilot", "session-state")
	project := filepath.Join(home, "project")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	writeCopilotSession(t, stateDir, "old-session", project, 0, now.Add(-48*time.Hour))
	writeCopilotSession(t, stateDir, "recent-session", project, 0, now)
	writeCopilotSession(t, stateDir, "other-dir", filepath.Join(home, "elsewhere"), 0, now)

	restore := &serverRestore{
		Windows: []restoreWindowState{
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project},
		},
	}
	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "recent-session" {
		t.Fatalf("session id = %q, want most-recent session for cwd (recent-session)", got)
	}
	options := createWindowOptionsForRestore(restore.Windows[0], false)
	if options.command != "copilot --resume 'recent-session' || copilot" {
		t.Fatalf("command = %q, want copilot resume with fresh fallback", options.command)
	}
}

// TestAssignCopilotSessionsByWorkingDirectoryDedups verifies two copilot
// windows sharing a directory receive distinct sessions (most recent first) and
// that a session already claimed elsewhere is never reused.
func TestAssignCopilotSessionsByWorkingDirectoryDedups(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	stateDir := filepath.Join(home, ".copilot", "session-state")
	project := filepath.Join(home, "shared")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	writeCopilotSession(t, stateDir, "sess-newest", project, 0, now)
	writeCopilotSession(t, stateDir, "sess-middle", project, 0, now.Add(-time.Hour))
	writeCopilotSession(t, stateDir, "sess-oldest", project, 0, now.Add(-2*time.Hour))

	restore := &serverRestore{
		Windows: []restoreWindowState{
			// Already resolved by the process table — must be left untouched and
			// not reused for the other windows.
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project, AgentSessionID: "sess-middle"},
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project},
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: project},
		},
	}
	assignCopilotSessionsByWorkingDirectory(restore)

	if restore.Windows[0].AgentSessionID != "sess-middle" {
		t.Fatalf("window 0 changed to %q, want untouched sess-middle", restore.Windows[0].AgentSessionID)
	}
	if restore.Windows[1].AgentSessionID != "sess-newest" {
		t.Fatalf("window 1 = %q, want sess-newest", restore.Windows[1].AgentSessionID)
	}
	if restore.Windows[2].AgentSessionID != "sess-oldest" {
		t.Fatalf("window 2 = %q, want sess-oldest (sess-middle already used)", restore.Windows[2].AgentSessionID)
	}
}

// TestAssignCopilotSessionsByWorkingDirectoryNormalizesPaths confirms a window
// cwd and a session cwd match through ~ expansion and symlink resolution.
func TestAssignCopilotSessionsByWorkingDirectoryNormalizesPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	stateDir := filepath.Join(home, ".copilot", "session-state")

	realDir := filepath.Join(home, "real-project")
	if err := os.MkdirAll(realDir, 0o755); err != nil {
		t.Fatal(err)
	}
	linkDir := filepath.Join(home, "linked-project")
	if err := os.Symlink(realDir, linkDir); err != nil {
		t.Skipf("symlinks unsupported: %v", err)
	}
	// Session recorded under the real path; window remembers the symlinked path.
	writeCopilotSession(t, stateDir, "linked-session", realDir, 0, time.Now())

	restore := &serverRestore{
		Windows: []restoreWindowState{
			{Name: "Copilot CLI", AgentTool: "copilot", Cwd: linkDir},
		},
	}
	assignCopilotSessionsByWorkingDirectory(restore)
	if got := restore.Windows[0].AgentSessionID; got != "linked-session" {
		t.Fatalf("session id = %q, want linked-session via symlink normalization", got)
	}
}
