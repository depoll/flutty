package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writePiTestSession(t *testing.T, path string, id string, cwd string, modified time.Time) {
	t.Helper()
	writePiTestSessionTimes(t, path, id, cwd, modified, modified)
}

func writePiTestSessionTimes(
	t *testing.T,
	path string,
	id string,
	cwd string,
	created time.Time,
	modified time.Time,
) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(
		"{\"type\":\"session\",\"id\":%q,\"timestamp\":%q,\"cwd\":%q}\n",
		id,
		created.UTC().Format(time.RFC3339Nano),
		cwd,
	)
	if err := os.WriteFile(path, []byte(header), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func writePiTestRelocatedSession(
	t *testing.T,
	path string,
	id string,
	cwd string,
	parent string,
	created time.Time,
	modified time.Time,
) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(
		"{\"type\":\"session\",\"id\":%q,\"timestamp\":%q,\"cwd\":%q,\"parentSession\":%q}\n",
		id,
		created.UTC().Format(time.RFC3339Nano),
		cwd,
		parent,
	)
	if err := os.WriteFile(path, []byte(header), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

// Pi's worktree flow relocates a running session into a bucket named for the
// new worktree cwd and deletes the original file, leaving only the header's
// parentSession pointing at the pane's working directory. The pane must still
// resume that session after a helper upgrade rather than launching a fresh Pi.
func TestDiscoverPiSessionsResumesSessionRelocatedToWorktree(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	originCreated := started.Add(500 * time.Millisecond)
	// The deleted origin file only survives as the parentSession path.
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		originCreated.Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	writePiTestRelocatedSession(
		t,
		filepath.Join(root, piEncodedSessionDirName(worktree), "relocated.jsonl"),
		"relocated-session",
		worktree,
		deletedOrigin,
		started.Add(30*time.Minute),
		started.Add(45*time.Minute),
	)
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "relocated-session" {
		t.Fatalf("relocated Pi session = %#v, want relocated-session", got)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand:  "pi",
		AgentSessionID:  got.sessionID,
		AgentSessionDir: got.sessionDir,
	}, false)
	if !strings.Contains(options.command, "--session relocated-session") {
		t.Fatalf("relocated restore command = %q, want a resume", options.command)
	}
}

func TestPiSessionOriginResolvesChainAndFileNameTimestamp(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	created := time.Date(2026, 8, 15, 6, 56, 17, 353*int(time.Millisecond), time.UTC)
	origin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		"2026-08-15T06-56-17-353Z_origin-session.jsonl",
	)
	middle := filepath.Join(root, piEncodedSessionDirName(worktree), "middle.jsonl")
	newest := filepath.Join(root, piEncodedSessionDirName(worktree), "newest.jsonl")
	writePiTestRelocatedSession(t, middle, "middle-session", worktree, origin, created.Add(time.Minute), created.Add(2*time.Minute))
	writePiTestRelocatedSession(t, newest, "newest-session", worktree, middle, created.Add(3*time.Minute), created.Add(4*time.Minute))

	entries := readPiSessionEntries(root)
	if len(entries) != 2 {
		t.Fatalf("entries = %d, want 2", len(entries))
	}
	for _, entry := range entries {
		if entry.originDir != piEncodedSessionDirName(project) {
			t.Fatalf("%s origin dir = %q, want project bucket", entry.sessionID, entry.originDir)
		}
		if !entry.originCreatedAt.Equal(created) {
			t.Fatalf("%s origin createdAt = %s, want %s", entry.sessionID, entry.originCreatedAt, created)
		}
	}
}

// A relocated session that is later rotated (/new) leaves the intermediate
// file on disk, so the pane's chain has several links that all resolve to the
// same origin. The pane must resume the leaf it is actually on.
func TestDiscoverPiSessionsResumesLeafOfRelocatedThenRotatedChain(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		started.Add(500*time.Millisecond).Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	middle := filepath.Join(root, piEncodedSessionDirName(worktree), "middle.jsonl")
	newest := filepath.Join(root, piEncodedSessionDirName(worktree), "newest.jsonl")
	writePiTestRelocatedSession(t, middle, "middle-session", worktree, deletedOrigin, started.Add(20*time.Minute), started.Add(25*time.Minute))
	writePiTestRelocatedSession(t, newest, "newest-session", worktree, middle, started.Add(30*time.Minute), started.Add(45*time.Minute))

	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "newest-session" {
		t.Fatalf("multi-hop Pi chain = %#v, want newest-session leaf", got)
	}
}

// Forks share a parent without superseding each other, so a branched history
// has no single leaf and must decline rather than guess a conversation.
func TestDiscoverPiSessionsDeclinesForkedChainBranches(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	worktree := filepath.Join(root, "worktree")
	started := time.Now().Add(-time.Hour).UTC()
	deletedOrigin := filepath.Join(
		root,
		piEncodedSessionDirName(project),
		started.Add(500*time.Millisecond).Format("2006-01-02T15-04-05-000Z")+"_origin-session.jsonl",
	)
	bucket := piEncodedSessionDirName(worktree)
	writePiTestRelocatedSession(t, filepath.Join(root, bucket, "branch-a.jsonl"), "branch-a", worktree, deletedOrigin, started.Add(20*time.Minute), started.Add(25*time.Minute))
	writePiTestRelocatedSession(t, filepath.Join(root, bucket, "branch-b.jsonl"), "branch-b", worktree, deletedOrigin, started.Add(30*time.Minute), started.Add(35*time.Minute))

	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("forked Pi chain = %#v, want fresh launch", got)
	}
}

func TestPiEncodedSessionDirNameMatchesPiLayout(t *testing.T) {
	if got, want := piEncodedSessionDirName("/Users/demo/Code/MonkeySSH"), "--Users-demo-Code-MonkeySSH--"; got != want {
		t.Fatalf("piEncodedSessionDirName = %q, want %q", got, want)
	}
	if got := piEncodedSessionDirName(""); got != "" {
		t.Fatalf("empty cwd encoding = %q, want empty", got)
	}
}

func TestPiAgentToolMappingAndResumeCommand(t *testing.T) {
	for _, name := range []string{"pi", "/Users/demo/.local/bin/pi"} {
		if got := agentToolFromCommandName(name); got != "pi" {
			t.Fatalf("agentToolFromCommandName(%q) = %q, want pi", name, got)
		}
	}
	for _, title := range []string{"Pi", "Pi - restore work - project"} {
		if got := agentToolFromTerminalTitle(title); got != "pi" {
			t.Fatalf("agentToolFromTerminalTitle(%q) = %q, want pi", title, got)
		}
	}
	for _, title := range []string{"Pi notes", "Pi calculator", "Pi · restore work"} {
		if got := agentToolFromTerminalTitle(title); got != "" {
			t.Fatalf("agentToolFromTerminalTitle(%q) = %q, want no classification", title, got)
		}
	}
	shellState := restoreWindowState{
		CurrentCommand: "zsh",
		PaneTitle:      "Pi - notes",
		AgentTool:      "pi",
	}
	if got := agentToolForRestore(shellState); got != "" {
		t.Fatalf("shell window with Pi-like title classified as %q", got)
	}
	if got := createWindowOptionsForRestore(shellState, false).command; got != "" {
		t.Fatalf("shell window with Pi-like title restore command = %q", got)
	}
	if got := agentSessionIDFromArgs("pi", "pi --session 'session-id'"); got != "session-id" {
		t.Fatalf("agentSessionIDFromArgs = %q, want session-id", got)
	}

	options := createWindowOptionsForRestore(restoreWindowState{
		Name:           "Pi",
		CurrentCommand: "pi",
		AgentSessionID: "session-id",
	}, true)
	want := piResumeCommandWithFreshFallback("pi --session session-id", "pi")
	if options.agentTool != "pi" || options.command != want {
		t.Fatalf("Pi restore options = tool:%q command:%q, want tool pi command %q", options.agentTool, options.command, want)
	}
}

func TestNewWindowAgentToolDoesNotConfirmNameOnlyMatch(t *testing.T) {
	if tool, confirmed := newWindowAgentTool(createWindowOptions{}, "Pi"); tool != "pi" || confirmed {
		t.Fatalf("name-only classification = %q, %v; want pi, false", tool, confirmed)
	}
	if tool, confirmed := newWindowAgentTool(
		createWindowOptions{agentTool: "pi"},
		"shell",
	); tool != "pi" || !confirmed {
		t.Fatalf("explicit classification = %q, %v; want pi, true", tool, confirmed)
	}
	if tool, confirmed := newWindowAgentTool(
		createWindowOptions{command: "pi"},
		"shell",
	); tool != "pi" || !confirmed {
		t.Fatalf("command classification = %q, %v; want pi, true", tool, confirmed)
	}
}

func TestPiResumeCommandRejectsShellMetacharacters(t *testing.T) {
	for _, id := range []string{"session's-id", "session&id", "$(touch-pwned)", "session id"} {
		if got := piResumeCommand(id, ""); got != "" {
			t.Fatalf("piResumeCommand(%q) = %q, want refusal", id, got)
		}
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand: "pi",
		AgentSessionID: "session&id",
	}, false)
	if options.command != "pi" {
		t.Fatalf("unsafe session command = %q, want fresh pi", options.command)
	}
}

func TestEnrichRestoreWithAgentSessionIDsUsesUnambiguousPiSession(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	now := time.Now()
	writePiTestSession(t, filepath.Join(root, "project", "primary.jsonl"), "primary-session", project, now)
	writePiTestSession(t, filepath.Join(root, "project", "primary", "child", "run-0", "session.jsonl"), "child-session", project, now.Add(time.Minute))
	writePiTestSession(t, filepath.Join(root, "other", "other.jsonl"), "other-session", filepath.Join(root, "other"), now.Add(2*time.Minute))

	restore := &serverRestore{Windows: []restoreWindowState{{
		Name: "Pi", Cwd: project, CurrentCommand: "pi", AgentTool: "pi",
	}}}
	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "primary-session" {
		t.Fatalf("Pi session = %q, want primary-session", got)
	}
	if got := restore.Windows[0].AgentSessionDir; got != filepath.Join(root, "project") {
		t.Fatalf("Pi session dir = %q, want project bucket", got)
	}
}

func TestDiscoverPiSessionsDeclinesAmbiguousCwdFallback(t *testing.T) {
	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	now := time.Now()
	writePiTestSession(t, filepath.Join(root, "project", "one.jsonl"), "session-one", project, now)
	writePiTestSession(t, filepath.Join(root, "project", "two.jsonl"), "session-two", project, now.Add(time.Second))

	for _, windows := range [][]restoreWindowState{
		{{CurrentCommand: "pi", AgentTool: "pi", Cwd: project}},
		{
			{CurrentCommand: "pi", AgentTool: "pi", Cwd: project},
			{CurrentCommand: "pi", AgentTool: "pi", Cwd: project},
		},
	} {
		restore := &serverRestore{Windows: windows}
		if got := discoverPiSessions(restore, nil, nil); len(got) != 0 {
			t.Fatalf("ambiguous Pi fallback = %#v, want none", got)
		}
	}
}

func TestDiscoverPiSessionsUsesProcessStartWhenPiClosesSessionFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	processStarted := time.Now().Add(-time.Minute).UTC()
	writePiTestSession(
		t,
		filepath.Join(root, "project", "old.jsonl"),
		"old-session",
		project,
		processStarted.Add(-time.Hour),
	)
	writePiTestSession(
		t,
		filepath.Join(root, "project", "current.jsonl"),
		"current-session",
		project,
		processStarted.Add(500*time.Millisecond),
	)
	processStartedAtForMetadata = func(pid int) time.Time {
		if pid == 200 {
			return processStarted
		}
		return time.Time{}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {
			pid:  200,
			ppid: 100,
			comm: "node",
			args: "node /usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
		},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "node", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "current-session" || got.sessionDir != filepath.Join(root, "project") {
		t.Fatalf("process-correlated Pi session = %#v, want current-session", got)
	}
}

func TestPiSessionsCreatedForProcessStartDeclinesAmbiguousMatches(t *testing.T) {
	started := time.Now().UTC()
	entries := []piSessionEntry{
		{sessionID: "one", createdAt: started, modTime: started},
		{sessionID: "two", createdAt: started.Add(time.Second), modTime: started.Add(time.Second)},
	}
	if got := piSessionsCreatedForProcessStart(entries, started); len(got) != 2 {
		t.Fatalf("created-at matches = %#v, want both ambiguous sessions", got)
	}
}

func TestDiscoverPiSessionsDeclinesInitialSessionAfterRotation(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-time.Hour).UTC()
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "initial.jsonl"),
		"initial-session",
		project,
		started.Add(500*time.Millisecond),
		started.Add(10*time.Minute),
	)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "rotated.jsonl"),
		"rotated-session",
		project,
		started.Add(20*time.Minute),
		started.Add(30*time.Minute),
	)
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("rotated Pi session match = %#v, want fresh fallback", got)
	}
}

func TestDiscoverPiSessionsDeclinesInitialSessionAfterResume(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	started := time.Now().Add(-time.Hour).UTC()
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "initial.jsonl"),
		"initial-session",
		project,
		started.Add(500*time.Millisecond),
		started.Add(5*time.Minute),
	)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "resumed.jsonl"),
		"resumed-session",
		project,
		started.Add(-time.Hour),
		started.Add(30*time.Minute),
	)
	processStartedAtForMetadata = func(int) time.Time { return started }
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	if got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}}); len(got) != 0 {
		t.Fatalf("resumed Pi session match = %#v, want fresh fallback rather than initial session", got)
	}
}

func TestDiscoverPiSessionsAssignsTwoKnownNodeProcessesMutually(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalProcessStart := processStartedAtForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processStartedAtForMetadata = originalProcessStart
	})
	processOpenFilePathsForMetadata = func(int) []string { return nil }

	root := t.TempDir()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", root)
	project := filepath.Join(root, "project")
	firstStart := time.Now().Add(-time.Hour).UTC()
	secondStart := firstStart.Add(time.Minute)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "first.jsonl"),
		"first-session",
		project,
		firstStart.Add(500*time.Millisecond),
		firstStart.Add(10*time.Minute),
	)
	writePiTestSessionTimes(
		t,
		filepath.Join(root, "project", "second.jsonl"),
		"second-session",
		project,
		secondStart.Add(500*time.Millisecond),
		secondStart.Add(10*time.Minute),
	)
	processStartedAtForMetadata = func(pid int) time.Time {
		switch pid {
		case 200:
			return firstStart
		case 201:
			return secondStart
		default:
			return time.Time{}
		}
	}
	// Windows Toolhelp exposes node.exe but not its package-path argv. The
	// known Pi pane classification still lets the closest runtime participate.
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "node.exe", args: "node.exe"},
		201: {pid: 201, ppid: 101, comm: "node.exe", args: "node.exe"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{
		{PanePid: 100, CurrentCommand: "cmd.exe", AgentTool: "pi", Cwd: project},
		{PanePid: 101, CurrentCommand: "powershell.exe", AgentTool: "pi", Cwd: project},
	}}

	got := discoverPiSessions(
		restore,
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)
	if got[0].sessionID != "first-session" || got[1].sessionID != "second-session" {
		t.Fatalf("mutual Pi assignments = %#v, want first and second sessions", got)
	}
	for i := range restore.Windows {
		if !restore.Windows[i].AgentToolConfirmed || agentToolForRestore(restore.Windows[i]) != "pi" {
			t.Fatalf("Windows-like Pi pane %d was not process-confirmed: %#v", i, restore.Windows[i])
		}
	}
}

func TestDiscoverPiSessionsDeclinesOverlappingProcessStarts(t *testing.T) {
	started := time.Now().UTC()
	entries := []piSessionEntry{
		{sessionID: "one", createdAt: started.Add(time.Second)},
		{sessionID: "two", createdAt: started.Add(2 * time.Second)},
	}
	if got := piSessionsCreatedForProcessStart(entries, started); len(got) != 2 {
		t.Fatalf("first overlapping process matches = %#v, want ambiguity", got)
	}
	if got := piSessionsCreatedForProcessStart(entries, started.Add(time.Second)); len(got) != 2 {
		t.Fatalf("second overlapping process matches = %#v, want ambiguity", got)
	}
}

func TestDiscoverPiSessionsUsesLiveOpenFileAndSkipsNestedPiProcess(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	t.Cleanup(func() { processOpenFilePathsForMetadata = originalOpenFiles })
	root := t.TempDir()
	project := filepath.Join(root, "project")
	current := filepath.Join(root, "sessions", "current.jsonl")
	other := filepath.Join(root, "sessions", "other.jsonl")
	child := filepath.Join(root, "sessions", "children", "child.jsonl")
	writePiTestSession(t, current, "current-session", project, time.Now())
	writePiTestSession(t, other, "other-session", project, time.Now().Add(time.Second))
	writePiTestSession(t, child, "child-session", project, time.Now().Add(2*time.Second))
	processOpenFilePathsForMetadata = func(pid int) []string {
		switch pid {
		case 200:
			return []string{current}
		case 300:
			return []string{child}
		default:
			return nil
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi"},
		300: {pid: 300, ppid: 200, comm: "pi", args: "pi --session child-session"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if got.sessionID != "current-session" || got.sessionDir != filepath.Dir(current) {
		t.Fatalf("live Pi session = %#v, want current open file", got)
	}
}

func TestDiscoverPiSessionsHonorsProcessSessionDir(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	t.Cleanup(func() { processOpenFilePathsForMetadata = originalOpenFiles })
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	project := t.TempDir()
	custom := filepath.Join(project, ".sessions")
	writePiTestSession(t, filepath.Join(custom, "current.jsonl"), "custom-session", project, time.Now())
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi --session-dir .sessions"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}

	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if want := filepath.Join(normalizedPiWorkingDirectory(project), ".sessions"); got.sessionID != "custom-session" || got.sessionDir != want {
		t.Fatalf("custom-dir Pi session = %#v, want custom session in %q", got, want)
	}
	options := createWindowOptionsForRestore(restoreWindowState{
		CurrentCommand: "pi", AgentSessionID: got.sessionID, AgentSessionDir: got.sessionDir,
	}, false)
	if !strings.Contains(options.command, "--session-dir") || !strings.Contains(options.command, "--session custom-session") {
		t.Fatalf("custom-dir restore command = %q", options.command)
	}
}

func TestDiscoverPiSessionsReservesExplicitProcessSession(t *testing.T) {
	project := t.TempDir()
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "pi", args: "pi --session exact-session --session-dir sessions"},
	}
	restore := &serverRestore{Windows: []restoreWindowState{{
		PanePid: 100, CurrentCommand: "pi", AgentTool: "pi", Cwd: project,
	}}}
	got := discoverPiSessions(restore, processes, map[int]struct{}{100: {}})[0]
	if want := filepath.Join(normalizedPiWorkingDirectory(project), "sessions"); got.sessionID != "exact-session" || got.sessionDir != want {
		t.Fatalf("explicit Pi session = %#v, want exact-session in %q", got, want)
	}
}

func TestPiSessionRootUsesProjectThenGlobalSettings(t *testing.T) {
	project := t.TempDir()
	agentDir := filepath.Join(t.TempDir(), "agent")
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", "")
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	if err := os.MkdirAll(filepath.Join(project, ".pi"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(agentDir, 0o700); err != nil {
		t.Fatal(err)
	}
	globalDir := filepath.Join(t.TempDir(), "global-sessions")
	if err := os.WriteFile(filepath.Join(agentDir, "settings.json"), []byte(fmt.Sprintf(`{"sessionDir":%q}`, globalDir)), 0o600); err != nil {
		t.Fatal(err)
	}
	projectSettings := filepath.Join(project, ".pi", "settings.json")
	if err := os.WriteFile(projectSettings, []byte(`{"sessionDir":".project-sessions"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := piSessionRootForWorkingDirectory(project), filepath.Join(normalizedPiWorkingDirectory(project), ".project-sessions"); got != want {
		t.Fatalf("project sessionDir = %q, want %q", got, want)
	}
	if err := os.Remove(projectSettings); err != nil {
		t.Fatal(err)
	}
	if got := piSessionRootForWorkingDirectory(project); got != globalDir {
		t.Fatalf("global sessionDir = %q, want %q", got, globalDir)
	}
}

func TestReadPiSessionEntrySkipsLeadingNonHeaderLines(t *testing.T) {
	project := t.TempDir()
	path := filepath.Join(t.TempDir(), "session.jsonl")
	content := "\nnot-json\n" + fmt.Sprintf("{\"type\":\"session\",\"id\":%q,\"cwd\":%q}\n", "session-id", project)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	entry, ok := readPiSessionEntry(path)
	if !ok || entry.sessionID != "session-id" || entry.cwd != normalizedPiWorkingDirectory(project) {
		t.Fatalf("Pi session entry = %#v, %v", entry, ok)
	}
}
