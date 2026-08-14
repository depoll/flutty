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
	shellState := restoreWindowState{CurrentCommand: "zsh", PaneTitle: "Pi - notes"}
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
		{PanePid: 100, CurrentCommand: "node", AgentTool: "pi", Cwd: project},
		{PanePid: 101, CurrentCommand: "node", AgentTool: "pi", Cwd: project},
	}}

	got := discoverPiSessions(
		restore,
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)
	if got[0].sessionID != "first-session" || got[1].sessionID != "second-session" {
		t.Fatalf("mutual Pi assignments = %#v, want first and second sessions", got)
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
