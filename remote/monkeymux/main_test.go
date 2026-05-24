package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/creack/pty"
)

func replayPrefixForTest(window *muxWindow) string {
	return activeWindowReplayPrefix + string(terminalTitleReplaySequence(window))
}

func replayPostHistorySuffixForTest(cursorVisible bool) string {
	return terminalParserResetSequence + terminalCharacterSetResetSequence +
		cursorVisibilityReplaySequence(cursorVisible)
}

func openTestPty(t *testing.T) *os.File {
	t.Helper()
	ptmx, tty, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = ptmx.Close()
		_ = tty.Close()
	})
	return ptmx
}

func assertPtySize(t *testing.T, file *os.File, columns int, rows int) {
	t.Helper()
	size, err := pty.GetsizeFull(file)
	if err != nil {
		t.Fatal(err)
	}
	if int(size.Cols) != columns || int(size.Rows) != rows {
		t.Fatalf(
			"pty size = %dx%d, want %dx%d",
			size.Cols,
			size.Rows,
			columns,
			rows,
		)
	}
}

func TestInheritedEnvironmentPassesThroughLaunchEnvironment(t *testing.T) {
	base := []string{
		"PATH=/custom/bin:/usr/bin",
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"SHELL=/bin/zsh",
		"EMPTY=",
		"PATH=/second-path-entry",
	}

	env := inheritedEnvironment(base)

	if !reflect.DeepEqual(env, base) {
		t.Fatalf("environment = %#v, want exact pass-through %#v", env, base)
	}
	env[0] = "PATH=/changed"
	if base[0] == env[0] {
		t.Fatal("inherited environment aliases source slice")
	}
}

func TestInheritedEnvironmentDoesNotAddMissingValues(t *testing.T) {
	env := inheritedEnvironment([]string{"USER=test"})

	if !reflect.DeepEqual(env, []string{"USER=test"}) {
		t.Fatalf("environment = %#v, want no synthesized values", env)
	}
}

func TestTerminalEnvironmentAddsTrueColorDefaults(t *testing.T) {
	base := []string{"USER=test"}

	env := terminalEnvironment(base)

	if !containsEnv(env, "TERM=xterm-256color") {
		t.Fatalf("terminal environment = %#v, want TERM=xterm-256color", env)
	}
	if !containsEnv(env, "COLORTERM=truecolor") {
		t.Fatalf("terminal environment = %#v, want COLORTERM=truecolor", env)
	}
	if !reflect.DeepEqual(base, []string{"USER=test"}) {
		t.Fatalf("terminal environment mutated base = %#v", base)
	}
}

func TestTerminalEnvironmentPreservesExistingTrueColorHints(t *testing.T) {
	base := []string{
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"USER=test",
	}

	env := terminalEnvironment(base)

	if !reflect.DeepEqual(env, base) {
		t.Fatalf("terminal environment = %#v, want existing hints preserved", env)
	}
}

func TestTerminalEnvironmentReplacesUnusableTerminalHints(t *testing.T) {
	env := terminalEnvironment([]string{"TERM=dumb", "COLORTERM=color", "USER=test"})

	if got := lastEnvValue(env, "TERM"); got != "xterm-256color" {
		t.Fatalf("TERM = %q in %#v, want xterm-256color", got, env)
	}
	if got := lastEnvValue(env, "COLORTERM"); got != "truecolor" {
		t.Fatalf("COLORTERM = %q in %#v, want truecolor", got, env)
	}
}

func TestExpandHomePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	expanded, err := expandHomePath("~/Code/flutty")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, "Code/flutty"); expanded != want {
		t.Fatalf("expanded path = %q, want %q", expanded, want)
	}

	unchanged, err := expandHomePath("~other/project")
	if err != nil {
		t.Fatal(err)
	}
	if unchanged != "~other/project" {
		t.Fatalf("non-current-user expansion = %q", unchanged)
	}
}

func TestShellCommandUsesLoginShell(t *testing.T) {
	cmd := shellCommand("/bin/zsh")

	if got := cmd.Path; got != "/bin/zsh" {
		t.Fatalf("path = %q, want shell path", got)
	}
	if got := cmd.Args[0]; got != "-zsh" {
		t.Fatalf("argv0 = %q, want login shell argv0", got)
	}
}

func TestShellCommandForScriptUsesInteractiveLoginShellWithoutTypingCommand(t *testing.T) {
	cmd := shellCommandForScript("/bin/zsh", "codex --yolo")

	if got := cmd.Path; got != "/bin/zsh" {
		t.Fatalf("path = %q, want shell path", got)
	}
	if got := cmd.Args[0]; got != "-zsh" {
		t.Fatalf("argv0 = %q, want login shell argv0", got)
	}
	if got := cmd.Args[1]; got != "-i" {
		t.Fatalf("shell interactive flag = %q, want -i", got)
	}
	if got := cmd.Args[2]; got != "-c" {
		t.Fatalf("shell command flag = %q, want -c", got)
	}
	if got := cmd.Args[3]; got != "codex --yolo" {
		t.Fatalf("script = %q, want launch command", got)
	}
}

func containsEnv(env []string, entry string) bool {
	for _, candidate := range env {
		if candidate == entry {
			return true
		}
	}
	return false
}

func lastEnvValue(env []string, key string) string {
	prefix := key + "="
	value := ""
	for _, candidate := range env {
		if strings.HasPrefix(candidate, prefix) {
			value = strings.TrimPrefix(candidate, prefix)
		}
	}
	return value
}

func TestDefaultShellPathFallsBackToSh(t *testing.T) {
	t.Setenv("SHELL", "")

	if got := defaultShellPath(); got != "/bin/sh" {
		t.Fatalf("default shell path = %q, want /bin/sh", got)
	}
}

func TestNormalizeServerUpdatePolicy(t *testing.T) {
	for _, test := range []struct {
		input string
		want  string
	}{
		{"", serverUpdatePolicyPrompt},
		{"prompt", serverUpdatePolicyPrompt},
		{" never ", serverUpdatePolicyNever},
		{"ALWAYS", serverUpdatePolicyAlways},
	} {
		got, err := normalizeServerUpdatePolicy(test.input)
		if err != nil {
			t.Fatalf("normalizeServerUpdatePolicy(%q) error: %v", test.input, err)
		}
		if got != test.want {
			t.Fatalf("normalizeServerUpdatePolicy(%q) = %q, want %q", test.input, got, test.want)
		}
	}

	if _, err := normalizeServerUpdatePolicy("sometimes"); err == nil {
		t.Fatal("invalid update policy succeeded")
	}
}

func TestShouldUpdateRunningServerNeverIsSilent(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("y\n"),
		&output,
		"work",
		runningServerStatus{version: "0.1.0"},
		serverUpdatePolicyNever,
	)

	if update {
		t.Fatal("never policy requested update")
	}
	if output.Len() != 0 {
		t.Fatalf("never policy wrote prompt: %q", output.String())
	}
}

func TestShouldUpdateRunningServerAlwaysSkipsPrompt(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("n\n"),
		&output,
		"work",
		runningServerStatus{version: "0.1.0"},
		serverUpdatePolicyAlways,
	)

	if !update {
		t.Fatal("always policy did not request update")
	}
	if output.Len() != 0 {
		t.Fatalf("always policy wrote prompt: %q", output.String())
	}
}

func TestShouldUpdateRunningServerPromptUsesTerminalPrompt(t *testing.T) {
	var output bytes.Buffer
	update := shouldUpdateRunningServer(
		strings.NewReader("y\n"),
		&output,
		"work",
		runningServerStatus{
			version:      "0.1.0",
			capabilities: []string{"shutdown"},
		},
		serverUpdatePolicyPrompt,
	)

	if !update {
		t.Fatal("prompt policy did not honor yes answer")
	}
	if !strings.Contains(output.String(), "Update now?") {
		t.Fatalf("prompt policy output = %q, want update prompt", output.String())
	}
}

func TestHasAttachClientReportsAttachConnection(t *testing.T) {
	server := newMuxServer("test")
	if server.hasAttachClient() {
		t.Fatal("new server reported attach client")
	}

	server.mu.Lock()
	server.attachConn = &recordingConn{}
	server.mu.Unlock()
	if !server.hasAttachClient() {
		t.Fatal("server did not report attach client")
	}
}

func TestInactiveWindowOutputIsBufferedForSwitch(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@2", []byte("background output"))

	if got := attach.String(); got != "" {
		t.Fatalf("inactive output was written to attach: %q", got)
	}
	if got := string(inactiveWindow.history); got != "background output" {
		t.Fatalf("inactive history = %q, want buffered output", got)
	}
	if inactiveWindow.alert {
		t.Fatal("ordinary inactive output marked the window alert")
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	want := replayPrefixForTest(inactiveWindow) + "background output" +
		replayPostHistorySuffixForTest(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
	if inactiveWindow.alert {
		t.Fatal("selected window alert was not cleared")
	}
}

func TestSelectWindowSignalsResizeAfterReplay(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach
	inactiveWindow.history = []byte("background output")

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) + "background output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	foregroundProcessGroupForWindow = func(window *muxWindow) int {
		if window == inactiveWindow {
			return 4242
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize signaled before replay was written: got %q, want %q", got, wantReplay)
		}
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	if !reflect.DeepEqual(signaled, []int{4242}) {
		t.Fatalf("signaled process groups = %#v, want [4242]", signaled)
	}
}

func TestAttachSignalsResizeAfterReplay(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("foreground output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(window) + "foreground output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 4343
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize signaled before replay was written: got %q, want %q", got, wantReplay)
		}
	}

	server.handleAttach(
		attach,
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 120, Height: 40},
	)

	if !reflect.DeepEqual(signaled, []int{4343}) {
		t.Fatalf("signaled process groups = %#v, want [4343]", signaled)
	}
}

func TestResizeUpdatesInactiveWindowPtys(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.resize(132, 43)

	assertPtySize(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 132, 43)
}

func TestAttachUpdatesInactiveWindowPtys(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Width: 132, Height: 43},
	)

	assertPtySize(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 132, 43)
}

func TestAttachIgnoresOversizedThemeHint(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{{id: "@1", index: 0, lastActivity: time.Now()}}
	server.activeID = "@1"

	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{
			Width:  132,
			Height: 43,
			Data:   strings.Repeat("x", themeHintLimitBytes+1),
		},
	)

	if len(server.themeHint) != 0 {
		t.Fatalf("theme hint length = %d, want 0", len(server.themeHint))
	}
}

func TestCreateWindowUsesServerTerminalSize(t *testing.T) {
	server := newMuxServerWithSize("test", 132, 43)
	t.Cleanup(server.close)

	window, err := server.createWindow(createWindowOptions{
		args: []string{"/bin/sh", "-c", "sleep 0.2"},
	})
	if err != nil {
		t.Fatal(err)
	}

	assertPtySize(t, window.pty, 132, 43)
}

func TestSameSizeResizeDoesNotSignalFocusAwareTui(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		focusModeEnabled:  true,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 40)

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestSameSizeResizeDoesNotSignalShell(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "zsh",
		focusModeEnabled:  true,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 40)

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestAttachWriteSkipsStaleActiveWindowOutput(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@2"
	server.attachConn = attach

	server.writeAttachIfActive("@1", attach, []byte("stale old output"))
	server.writeAttachIfActive("@2", attach, []byte("fresh new output"))

	if got := attach.String(); got != "fresh new output" {
		t.Fatalf("attach output = %q, want only fresh active output", got)
	}
}

func TestAttachInputDropsFocusReportsUntilActiveWindowEnablesFocus(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	window := &muxWindow{id: "@1", index: 0, pty: writer, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.writeActiveFromAttach([]byte("typed\x1b[I\x1b[Oinput"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(output); got != "typedinput" {
		t.Fatalf("pty input = %q, want focus reports stripped", got)
	}
}

func TestAttachInputPreservesFocusReportsForActiveFocusAwareWindow(t *testing.T) {
	server := newMuxServer("test")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	window := &muxWindow{
		id:               "@1",
		index:            0,
		pty:              writer,
		lastActivity:     time.Now(),
		focusModeEnabled: true,
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.writeActiveFromAttach([]byte("typed\x1b[I\x1b[Oinput"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(output); got != "typed\x1b[I\x1b[Oinput" {
		t.Fatalf("pty input = %q, want focus reports preserved", got)
	}
}

func TestInactiveWindowBellMarksAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("background output\a"))

	if !inactiveWindow.alert {
		t.Fatal("inactive bell did not mark the window alert")
	}
}

func TestActiveReplayIncludesWindowHistory(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("previous screen"), lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.mu.Lock()
	server.attachConn = attach
	replay := server.activeReplayLocked()
	server.mu.Unlock()
	server.writeAttach(attach, replay)

	window := server.windows[0]
	want := replayPrefixForTest(window) + "previous screen" +
		replayPostHistorySuffixForTest(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
}

func TestActiveReplayIsCappedForResponsiveSwitching(t *testing.T) {
	server := newMuxServer("test")
	history := bytes.Repeat([]byte("a"), windowReplayLimitBytes+4096)
	copy(history[len(history)-6:], []byte("suffix"))
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: history, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	replay := server.activeReplayLocked()

	window := server.windows[0]
	if len(replay) > len(replayPrefixForTest(window))+windowReplayLimitBytes+2048 {
		t.Fatalf("replay length = %d, want capped near %d", len(replay), len(replayPrefixForTest(window))+windowReplayLimitBytes)
	}
	if !strings.HasSuffix(
		strings.TrimSuffix(string(replay), replayPostHistorySuffixForTest(true)),
		"suffix",
	) {
		t.Fatalf("replay did not preserve recent output suffix")
	}
}

func TestActiveReplayKeepsFullAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"\x1b[?1049h" +
			"alternate-screen-start" +
			strings.Repeat("\x1b]66;semantic\a", windowReplayLimitBytes/8) +
			"alternate-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked(history)
	replay := string(server.activeReplayLocked())

	if !strings.Contains(replay, "alternate-screen-start") {
		t.Fatalf("alternate-screen replay was capped before screen start")
	}
	if !strings.Contains(
		replay,
		"\x1b[?1049h"+terminalScreenClearSequence+"\x1b[?1049halternate-screen-start",
	) {
		t.Fatalf("alternate-screen replay did not clear stale alternate buffer before history: %q", replay)
	}
	if !strings.Contains(replay, "alternate-screen-end") {
		t.Fatalf("alternate-screen replay lost screen end")
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplayPrefixClearsMainAndAlternateScreens(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("shell prompt"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.Contains(replayPrefixForTest(window), terminalAllScreensClearSequence) {
		t.Fatal("replay prefix does not clear both main and alternate screens")
	}
	clearIndex := strings.Index(replay, terminalAllScreensClearSequence)
	historyIndex := strings.Index(replay, "shell prompt")
	if clearIndex < 0 || historyIndex < 0 || clearIndex > historyIndex {
		t.Fatalf("main-screen replay did not clear stale alternate buffer before history: %q", replay)
	}
}

func TestActiveReplayCapsExitedAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"\x1b[?1049h" +
			"stale-alt-screen-start" +
			strings.Repeat("main-screen-output", windowReplayLimitBytes/8) +
			"main-screen-suffix",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked([]byte("\x1b[?1049h\x1b[?1049l"))
	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "stale-alt-screen-start") {
		t.Fatalf("main-screen replay retained stale alternate-screen prefix")
	}
	if !strings.Contains(replay, "main-screen-suffix") {
		t.Fatalf("main-screen replay lost recent suffix")
	}
}

func TestReplayStripsTerminalResponseQueries(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:    "@1",
			index: 0,
			history: []byte(
				"before" +
					"\x1b[c" +
					"\x1b[>0c" +
					"\x1b[6n" +
					"\x1b]11;?\x07" +
					"\x1b]2;Gemini\x07" +
					"after",
			),
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	for _, stripped := range []string{
		"\x1b[c",
		"\x1b[>0c",
		"\x1b[6n",
		"\x1b]11;?\x07",
	} {
		if strings.Contains(replay, stripped) {
			t.Fatalf("replay retained terminal query %q in %q", stripped, replay)
		}
	}
	if !strings.Contains(replay, "\x1b]2;Gemini\x07") {
		t.Fatalf("replay stripped title update: %q", replay)
	}
	if !strings.Contains(replay, "before") || !strings.Contains(replay, "after") {
		t.Fatalf("replay = %q, want normal output preserved", replay)
	}
}

func TestReplayStripDoesNotCopyCleanHistory(t *testing.T) {
	history := []byte("prompt\x1b]2;Gemini\x07safe")

	replay := stripTerminalQueriesFromReplay(history)

	if len(replay) == 0 {
		t.Fatal("replay is empty")
	}
	replay[0] = 'P'
	if history[0] != 'P' {
		t.Fatal("clean replay history was copied, want original slice reused")
	}
}

func TestActiveOutputStillPassesTerminalQueriesThrough(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("live\x1b[c\x1b]11;?\x07query"))

	if got := attach.String(); got != "live\x1b[c\x1b]11;?\x07query" {
		t.Fatalf("active attach output = %q, want unmodified live query", got)
	}
}

// TestActiveOutputStripsLocallyAnsweredThemeQueryFromAttach guards against the
// "hermes spew" regression: when MonkeyMux can answer an OSC theme query from
// its cached theme hint, the query bytes must be removed from the chunk
// forwarded to the attach (SSH client) side. Otherwise the client would also
// answer the query, and that duplicate response would round-trip back through
// the attach input pipe into the active window's PTY, where the TUI renders
// it as literal text.
func TestActiveOutputStripsLocallyAnsweredThemeQueryFromAttach(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		pty:               inputWriter,
		lastActivity:      time.Now(),
	}
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 42
		}
		return 0
	}

	attach := &recordingConn{}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach
	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	server.themeHint = []byte(backgroundReport)

	server.handleWindowOutput("@1", []byte("hello\x1b]11;?\x1b\\world"))

	if got := attach.String(); got != "helloworld" {
		t.Fatalf("active attach output = %q, want OSC 11 query stripped", got)
	}

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("window pty got = %q, want background report %q", got, backgroundReport)
	}
}

func TestActiveOutputStripsSplitLocallyAnsweredThemeQueryFromAttach(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		pty:               inputWriter,
		lastActivity:      time.Now(),
	}
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 42
		}
		return 0
	}

	attach := &recordingConn{}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach
	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	server.themeHint = []byte(backgroundReport)

	server.handleWindowOutput("@1", []byte("hello\x1b]11;?"))
	if got := attach.String(); got != "hello" {
		t.Fatalf("active attach output after partial query = %q, want prefix only", got)
	}

	server.handleWindowOutput("@1", []byte("\x1b\\world"))

	if got := attach.String(); got != "helloworld" {
		t.Fatalf("active attach output = %q, want split OSC 11 query stripped", got)
	}

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("window pty got = %q, want background report %q", got, backgroundReport)
	}
}

// TestActiveOutputKeepsUnansweredPaletteQueryInAttach verifies that when the
// theme hint cannot answer every key in a multi-key OSC 4 palette query, the
// query is left intact so the SSH client can still reply.
func TestActiveOutputKeepsUnansweredPaletteQueryInAttach(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = attach
	server.themeHint = []byte("\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\")

	server.handleWindowOutput("@1", []byte("\x1b]4;0;?;7;?\x1b\\"))

	if got := attach.String(); got != "\x1b]4;0;?;7;?\x1b\\" {
		t.Fatalf("active attach output = %q, want palette query preserved", got)
	}
}

func TestStripLocallyAnsweredThemeQueriesLeavesNormalOutput(t *testing.T) {
	chunk := []byte("plain text without queries\x1b]2;Title\x07")
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != string(chunk) {
		t.Fatalf("got = %q, want unchanged %q", got, chunk)
	}
}

func TestStripLocallyAnsweredThemeQueriesIsNoopWithoutHint(t *testing.T) {
	chunk := []byte("\x1b]11;?\x1b\\")

	got := stripLocallyAnsweredThemeQueries(chunk, nil)
	if string(got) != string(chunk) {
		t.Fatalf("got = %q, want unchanged %q", got, chunk)
	}
}

func TestStripLocallyAnsweredThemeQueriesStripsAnsweredQuery(t *testing.T) {
	chunk := []byte("before\x1b]11;?\x07middle\x1b]4;5;?\x1b\\after")
	hint := []byte(
		"\x1b]11;rgb:1111/2222/3333\x1b\\" +
			"\x1b]4;5;rgb:aaaa/bbbb/cccc\x1b\\",
	)

	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != "beforemiddleafter" {
		t.Fatalf("got = %q, want %q", got, "beforemiddleafter")
	}
}

func TestStripLocallyAnsweredThemeQueriesBuffersSplitAnsweredQuery(t *testing.T) {
	window := &muxWindow{}
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("before\x1b]11;?"),
		hint,
	)
	if string(first) != "before" {
		t.Fatalf("first chunk = %q, want prefix only", first)
	}
	if string(window.attachOscBuffer) != "\x1b]11;?" {
		t.Fatalf("attach OSC buffer = %q, want split query", window.attachOscBuffer)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked([]byte("\x1b\\after"), hint)
	if string(second) != "after" {
		t.Fatalf("second chunk = %q, want answered query stripped", second)
	}
	if len(window.attachOscBuffer) != 0 {
		t.Fatalf("attach OSC buffer = %q, want empty", window.attachOscBuffer)
	}
}

func TestStripLocallyAnsweredThemeQueriesForwardsSplitUnansweredQuery(t *testing.T) {
	window := &muxWindow{}
	hint := []byte("\x1b]10;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("before\x1b]11;?"),
		hint,
	)
	if string(first) != "before" {
		t.Fatalf("first chunk = %q, want prefix only", first)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked([]byte("\x1b\\after"), hint)
	if string(second) != "\x1b]11;?\x1b\\after" {
		t.Fatalf("second chunk = %q, want unanswered query forwarded", second)
	}
}

func TestCreateWindowClearsAttachBeforePromptOutput(t *testing.T) {
	server := newMuxServer("test")
	t.Cleanup(server.close)
	attach := &recordingConn{}
	server.attachConn = attach
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("old"), lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.nextID = 1

	_, err := server.createWindow(createWindowOptions{
		args: []string{"/bin/sh", "-c", "printf monkeymux-prompt; sleep 0.2"},
	})
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(time.Second)
	for !strings.Contains(attach.String(), "monkeymux-prompt") &&
		time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}

	output := attach.String()
	wantPrefix := replayPrefixForTest(&muxWindow{name: "sh", paneTitle: "sh"}) +
		replayPostHistorySuffixForTest(true)
	if !strings.HasPrefix(output, wantPrefix) {
		t.Fatalf("attach output = %q, want replay prefix before prompt", output)
	}
	afterPrefix := strings.TrimPrefix(output, wantPrefix)
	if !strings.Contains(afterPrefix, "monkeymux-prompt") {
		t.Fatalf("attach output = %q, want prompt after replay prefix", output)
	}
	if strings.Contains(afterPrefix, activeWindowReplayPrefix) {
		t.Fatalf("attach output = %q, replay prefix repeated after prompt", output)
	}
}

func TestWindowHistoryTrimsToLimit(t *testing.T) {
	window := &muxWindow{}

	window.appendHistoryLocked(bytes.Repeat([]byte("a"), windowHistoryLimitBytes-2))
	window.appendHistoryLocked([]byte("bcdef"))

	if got := len(window.history); got > 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, want <= %d", got, 2*windowHistoryLimitBytes)
	}
	if got := len(window.historyTailLocked()); got != windowHistoryLimitBytes {
		t.Fatalf("history tail length = %d, want %d", got, windowHistoryLimitBytes)
	}
	if got := string(window.history[len(window.history)-5:]); got != "bcdef" {
		t.Fatalf("history suffix = %q, want bcdef", got)
	}
}

func TestWindowHistoryAmortizedTrim(t *testing.T) {
	window := &muxWindow{}
	chunk := bytes.Repeat([]byte("x"), 4096)
	// Fill past the soft limit so subsequent writes exercise the trim path.
	for i := 0; i < (3*windowHistoryLimitBytes)/len(chunk); i++ {
		window.appendHistoryLocked(chunk)
	}
	if got := len(window.history); got > 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, exceeds amortization budget %d", got, 2*windowHistoryLimitBytes)
	}
	if got := len(window.historyTailLocked()); got != windowHistoryLimitBytes {
		t.Fatalf("history tail length = %d, want %d", got, windowHistoryLimitBytes)
	}
}

func TestWindowMetadataTracksOscTitleAsPaneTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("\x1b]2;Claude Code · flutty\x1b\\"))

	if window.name != "zsh" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Claude Code · flutty" {
		t.Fatalf("pane title = %q, want OSC title", window.paneTitle)
	}
}

func TestWindowTitleUpdatesStillBroadcast(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	control := &recordingConn{}
	client := newControlClient(control)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "Copilot CLI",
		command:           "copilot",
		foregroundCommand: "copilot",
		foregroundPid:     4242,
		paneTitle:         "Copilot CLI",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach
	server.controls[client] = struct{}{}

	server.handleWindowOutput("@1", []byte("\x1b]2;Search one\x07"))
	firstBroadcasts := strings.Count(control.String(), `"type":"window_updated"`)
	if firstBroadcasts != 1 {
		t.Fatalf("first title update broadcasts = %d, want 1", firstBroadcasts)
	}

	server.handleWindowOutput("@1", []byte("\x1b]2;Search two\x07"))

	if got := strings.Count(control.String(), `"type":"window_updated"`); got != 2 {
		t.Fatalf("title update broadcasts = %d, want 2", got)
	}
	if window.name != "Copilot CLI" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Search two" {
		t.Fatalf("pane title = %q, want latest OSC title", window.paneTitle)
	}
}

func TestWindowSnapshotReportsTerminalMouseModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Mouse app",
		privateModes: map[string]bool{"1000": true, "1006": true},
		lastActivity: time.Now(),
	}

	snapshot := server.snapshot(window)

	if !snapshot.TerminalReportsMouseWheel {
		t.Fatal("snapshot did not report mouse wheel mode")
	}
	if !snapshot.TerminalMouseReportSgr {
		t.Fatal("snapshot did not report SGR mouse mode")
	}
}

func TestRestoreSnapshotPreservesTerminalModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                       "@1",
		index:                    0,
		name:                     "Mouse app",
		privateModes:             map[string]bool{"1049": true, "7": false, "9999": true},
		insertModeEnabled:        true,
		insertModeKnown:          true,
		applicationKeypadEnabled: true,
		applicationKeypadKnown:   true,
		lastActivity:             time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	restore := server.restoreSnapshot()
	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	state := restore.Windows[0]
	if !state.PrivateModes["1049"] {
		t.Fatal("restore did not preserve alternate-screen mode")
	}
	if enabled, ok := state.PrivateModes["7"]; !ok || enabled {
		t.Fatalf("restore wrap mode = %v, %v, want present false", enabled, ok)
	}
	if _, ok := state.PrivateModes["9999"]; ok {
		t.Fatal("restore preserved untracked private mode")
	}
	if !state.InsertModeKnown || !state.InsertModeEnabled {
		t.Fatal("restore did not preserve insert mode")
	}
	if !state.ApplicationKeypadKnown || !state.ApplicationKeypadEnabled {
		t.Fatal("restore did not preserve application keypad mode")
	}

	options := createWindowOptionsForRestore(state, false)
	if enabled, ok := options.privateModes["7"]; !ok || enabled {
		t.Fatalf("restored options wrap mode = %v, %v, want present false", enabled, ok)
	}
	if !options.privateModes["1049"] {
		t.Fatalf("restored options private modes = %#v", options.privateModes)
	}
	if !options.insertModeKnown || !options.insertModeEnabled {
		t.Fatal("restored options did not preserve insert mode")
	}
	if !options.applicationKeypadKnown || !options.applicationKeypadEnabled {
		t.Fatal("restored options did not preserve application keypad mode")
	}
}

func TestActiveReplaySetsWindowTitle(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:           "@1",
			index:        0,
			name:         "Copilot CLI",
			paneTitle:    "Copilot CLI",
			history:      []byte("prompt"),
			lastActivity: time.Now(),
		},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	for _, sequence := range []string{
		"\x1b]0;Copilot CLI\x07",
		"\x1b]1;Copilot CLI\x07",
		"\x1b]2;Copilot CLI\x07",
	} {
		if !strings.Contains(replay, sequence) {
			t.Fatalf("replay = %q, want title sequence %q", replay, sequence)
		}
	}
}

func TestTerminalTitleReplaySanitizesControlCharacters(t *testing.T) {
	window := &muxWindow{name: "bad\x1b\a title"}

	replay := string(terminalTitleReplaySequence(window))

	if strings.Contains(replay, "bad\x1b") || strings.Contains(replay, "\a title") {
		t.Fatalf("title replay retained payload control characters: %q", replay)
	}
	if !strings.Contains(replay, "bad title") {
		t.Fatalf("title replay = %q, want sanitized title text", replay)
	}
}

func TestWindowMetadataTracksSplitOscTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("prefix\x1b]0;Copilot"))
	window.observeTerminalMetadataLocked([]byte(" CLI\aafter"))

	if window.name != "zsh" {
		t.Fatalf("name = %q, want stable window name", window.name)
	}
	if window.paneTitle != "Copilot CLI" {
		t.Fatalf("pane title = %q, want split OSC title", window.paneTitle)
	}
	if string(window.oscBuffer) != "" {
		t.Fatalf("osc buffer = %q, want empty", window.oscBuffer)
	}
}

func TestWindowMetadataTracksOsc7Path(t *testing.T) {
	window := &muxWindow{cwd: "/tmp"}

	window.observeTerminalMetadataLocked(
		[]byte("\x1b]7;file://host/Users/depoll/Code/flutty\x1b\\"),
	)

	if window.cwd != "/Users/depoll/Code/flutty" {
		t.Fatalf("cwd = %q, want OSC 7 path", window.cwd)
	}
}

func TestActiveReplayRestoresCursorVisibility(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("prompt"), lastActivity: time.Now()},
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.HasSuffix(replay, cursorVisibilityReplaySequence(true)) {
		t.Fatalf("replay = %q, want visible cursor suffix", replay)
	}
}

func TestActiveReplayPreservesHiddenCursor(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("start\x1b[?25l"))
	replay := string(server.activeReplayLocked())

	if !strings.HasSuffix(replay, cursorVisibilityReplaySequence(false)) {
		t.Fatalf("replay = %q, want hidden cursor suffix", replay)
	}
}

func TestReplayPrefixResetsStaleInputModes(t *testing.T) {
	for _, sequence := range []string{
		"\x1b[?1000l",
		"\x1b[?1002l",
		"\x1b[?1003l",
		"\x1b[?1006l",
		"\x1b[?1004l",
		"\x1b[?1007l",
		"\x1b[?2004l",
		"\x1b[?1l",
		"\x1b[?6l",
		"\x1b[?7h",
		"\x1b[4l",
	} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not reset %q", activeWindowReplayPrefix, sequence)
		}
	}
	if !strings.Contains(activeWindowReplayPrefix, "\x1b>") {
		t.Fatalf("replay prefix %q does not reset application keypad mode", activeWindowReplayPrefix)
	}
}

func TestReplayPrefixClearsScrollbackAndMargins(t *testing.T) {
	for _, sequence := range []string{"\x1b[r", "\x1b[2J", "\x1b[3J", "\x1b(B"} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not include %q", activeWindowReplayPrefix, sequence)
		}
	}
}

func TestReplayPrefixResetsCharacterSetShift(t *testing.T) {
	if !strings.HasPrefix(activeWindowReplayPrefix, terminalParserResetSequence) {
		t.Fatalf("replay prefix %q does not start by resetting parser state", activeWindowReplayPrefix)
	}
	for _, sequence := range []string{"\x0f", "\x1b(B", "\x1b)B"} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not reset character set with %q", activeWindowReplayPrefix, sequence)
		}
	}
}

func TestReplayParserFenceDoesNotEmitVisibleCancelByte(t *testing.T) {
	if terminalParserResetSequence != "\x1b\\" {
		t.Fatalf("parser fence = %q, want ST-only fence", terminalParserResetSequence)
	}
	if strings.ContainsAny(terminalParserResetSequence, "\x18\x1a") {
		t.Fatalf("parser fence = %q, must not include visible cancel controls", terminalParserResetSequence)
	}
}

func TestActiveReplayDoesNotRestoreStaleFocusMode(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                 "@1",
		index:              0,
		foregroundPid:      222,
		privateModes:       map[string]bool{"1004": true},
		focusModeEnabled:   true,
		focusModeProcessID: 111,
		lastActivity:       time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := strings.TrimPrefix(string(server.activeReplayLocked()), activeWindowReplayPrefix)

	if strings.Contains(replay, "\x1b[?1004h") {
		t.Fatalf("replay restored stale focus mode: %q", replay)
	}
}

func TestActiveReplayRestoresTrackedEditorModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("nano screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked(
		[]byte("\x1b[?1049h\x1b[?1h\x1b[?1007h\x1b=\x1b[?2004h\x1b[4h"),
	)

	replay := string(server.activeReplayLocked())
	preModes := string(terminalModePreReplaySequence(window))
	preHistoryClear := string(terminalPreHistoryClearSequence(window))
	postModes := string(terminalModePostReplaySequence(window))
	want := replayPrefixForTest(window) + preModes + preHistoryClear + "nano screen" +
		terminalParserResetSequence + postModes +
		terminalCharacterSetResetSequence + cursorVisibilityReplaySequence(true)
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
	for _, sequence := range []string{
		"\x1b[?1049h",
		"\x1b[?1h",
		"\x1b[?1007h",
		"\x1b[?2004h",
		"\x1b[4h",
		"\x1b=",
	} {
		if !strings.Contains(preModes, sequence) {
			t.Fatalf("pre-history modes = %q, want %q", preModes, sequence)
		}
	}
	for _, sequence := range []string{
		"\x1b[?1h",
		"\x1b[?1007h",
		"\x1b[?2004h",
		"\x1b[4h",
		"\x1b=",
	} {
		if !strings.Contains(postModes, sequence) {
			t.Fatalf("post-history modes = %q, want %q", postModes, sequence)
		}
	}
	if strings.Contains(postModes, "\x1b[?1049h") {
		t.Fatalf("post-history modes = %q, should not switch buffers after replay", postModes)
	}
}

func TestTerminalModeTrackingHandlesSplitSequences(t *testing.T) {
	window := &muxWindow{}

	window.observeTerminalModesLocked([]byte("\x1b[?1;200"))
	window.observeTerminalModesLocked([]byte("4h\x1b"))
	window.observeTerminalModesLocked([]byte("="))

	preModes := string(terminalModePreReplaySequence(window))
	for _, sequence := range []string{"\x1b[?1h", "\x1b[?2004h", "\x1b="} {
		if !strings.Contains(preModes, sequence) {
			t.Fatalf("pre-history modes = %q, want %q", preModes, sequence)
		}
	}
}

func TestActiveReplayRestoresResetEditorModesAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{id: "@1", history: []byte("stale\x1b[4h")}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	window.observeTerminalModesLocked([]byte("\x1b[4h\x1b[4l\x1b=\x1b>"))

	postModes := string(terminalModePostReplaySequence(window))
	for _, sequence := range []string{"\x1b[4l", "\x1b>"} {
		if !strings.Contains(postModes, sequence) {
			t.Fatalf("post-history modes = %q, want reset %q", postModes, sequence)
		}
	}
	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		"stale\x1b[4h"+terminalParserResetSequence+postModes+
			terminalCharacterSetResetSequence+cursorVisibilityReplaySequence(true),
	) {
		t.Fatalf("replay did not restore reset modes after history")
	}
}

func TestActiveReplayResetsCharacterSetAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	history := "prompt\x1b)0\x0eqqq"
	window := &muxWindow{id: "@1", history: []byte(history)}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		history+replayPostHistorySuffixForTest(true),
	) {
		t.Fatalf("replay did not reset shifted character set after history")
	}
}

func TestActiveReplayTerminatesUnfinishedControlStringAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	history := "screen\x1b]2;unterminated title"
	window := &muxWindow{id: "@1", history: []byte(history)}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	if !strings.HasSuffix(
		string(server.activeReplayLocked()),
		history+replayPostHistorySuffixForTest(true),
	) {
		t.Fatalf("replay did not terminate unfinished control string after history")
	}
}

func TestWindowProcessIDReportsShellPid(t *testing.T) {
	window := &muxWindow{cmd: &exec.Cmd{Process: &os.Process{Pid: 12345}}}

	if got := window.processID(); got != 12345 {
		t.Fatalf("processID = %d, want 12345", got)
	}
}

func TestWindowSnapshotPrefersForegroundProcessMetadata(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "flutty",
		command:           "zsh",
		foregroundPid:     23456,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	snapshot := server.snapshot(window)

	if snapshot.CurrentCommand != "codex" {
		t.Fatalf("current command = %q, want codex", snapshot.CurrentCommand)
	}
	if snapshot.PanePid != 23456 {
		t.Fatalf("pane pid = %d, want foreground pid", snapshot.PanePid)
	}
	if snapshot.AgentTool != "codex" {
		t.Fatalf("agent tool = %q, want codex", snapshot.AgentTool)
	}
}

func TestWindowSnapshotIncludesLaunchAgentTool(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		name:              "Gemini CLI",
		command:           "zsh",
		agentTool:         "gemini",
		foregroundPid:     23456,
		foregroundCommand: "zsh",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	snapshot := server.snapshot(window)

	if snapshot.AgentTool != "gemini" {
		t.Fatalf("agent tool = %q, want gemini", snapshot.AgentTool)
	}
}

func TestCommandNameFromProcessFieldsDetectsNodeBackedAgents(t *testing.T) {
	tests := []struct {
		name    string
		command string
		args    string
		want    string
	}{
		{
			name:    "gemini node shim",
			command: "node",
			args:    "node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js",
			want:    "gemini",
		},
		{
			name:    "codex node shim",
			command: "node",
			args:    "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
			want:    "codex",
		},
		{
			name:    "plain node script",
			command: "node",
			args:    "node /tmp/build.js",
			want:    "node",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := commandNameFromProcessFields(tt.command, tt.args); got != tt.want {
				t.Fatalf("commandNameFromProcessFields() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestFirstShellWordSkipsWrappers(t *testing.T) {
	tests := []struct {
		command string
		want    string
	}{
		{command: "cd ~/repo && codex resume abc", want: "codex"},
		{command: "cd ~/repo && npx @google/gemini-cli --yolo", want: "gemini"},
		{command: `GEMINI_API_KEY=redacted gemini --yolo`, want: "gemini"},
		{command: `OPENCODE_PERMISSION='{"*":"allow"}' opencode`, want: "opencode"},
	}

	for _, tt := range tests {
		if got := firstShellWord(tt.command); got != tt.want {
			t.Fatalf("firstShellWord(%q) = %q, want %q", tt.command, got, tt.want)
		}
	}
}

func TestAgentToolFromCommandTextDetectsWrappedNodeAgents(t *testing.T) {
	tests := []struct {
		command string
		want    string
	}{
		{command: "cd ~/repo && npx @google/gemini-cli --yolo", want: "gemini"},
		{command: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js", want: "codex"},
	}

	for _, tt := range tests {
		if got := agentToolFromCommandText(tt.command); got != tt.want {
			t.Fatalf("agentToolFromCommandText(%q) = %q, want %q", tt.command, got, tt.want)
		}
	}
}

func TestAgentSessionIDFromArgsParsesResumeCommands(t *testing.T) {
	tests := []struct {
		tool string
		args string
		want string
	}{
		{tool: "claude", args: "claude --resume abc123", want: "abc123"},
		{tool: "copilot", args: "copilot --resume 'session one'", want: "session one"},
		{tool: "codex", args: "codex resume run-42", want: "run-42"},
		{tool: "gemini", args: `gemini --resume="gemini session"`, want: "gemini session"},
		{tool: "opencode", args: "opencode --session opencode-9", want: "opencode-9"},
		{tool: "antigravity", args: `agy --conversation "antigravity session"`, want: "antigravity session"},
	}

	for _, tt := range tests {
		if got := agentSessionIDFromArgs(tt.tool, tt.args); got != tt.want {
			t.Fatalf("agentSessionIDFromArgs(%q, %q) = %q, want %q", tt.tool, tt.args, got, tt.want)
		}
	}
}

func TestCloseActiveWindowSelectsNextWindowImmediately(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("one"), lastActivity: time.Now()},
		{id: "@2", index: 1, history: []byte("two"), lastActivity: time.Now()},
		{id: "@3", index: 2, history: []byte("three"), lastActivity: time.Now()},
	}
	server.activeID = "@2"
	server.attachConn = attach

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	if got := server.activeWindowID(); got != "@3" {
		t.Fatalf("active window = %q, want next window @3", got)
	}
	if !server.windows[1].closed {
		t.Fatal("closed window was not marked closed immediately")
	}
	want := replayPrefixForTest(server.windows[2]) + "three" +
		replayPostHistorySuffixForTest(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
}

func TestCloseLastIndexedActiveWindowWrapsToFirstWindow(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("one"), lastActivity: time.Now()},
		{id: "@2", index: 1, history: []byte("two"), lastActivity: time.Now()},
	}
	server.activeID = "@2"
	server.attachConn = attach

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	if got := server.activeWindowID(); got != "@1" {
		t.Fatalf("active window = %q, want wrapped window @1", got)
	}
	want := replayPrefixForTest(server.windows[0]) + "one" +
		replayPostHistorySuffixForTest(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
}

func TestCloseWindowRemovesFromSnapshotsImmediately(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		{id: "@2", index: 1, lastActivity: time.Now()},
		{id: "@3", index: 2, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	shouldShutdown, err := server.closeWindow("@2")
	if err != nil {
		t.Fatal(err)
	}
	if shouldShutdown {
		t.Fatal("closing one of several windows requested shutdown")
	}

	snapshots := server.snapshots()
	if len(snapshots) != 2 {
		t.Fatalf("snapshot count = %d, want 2", len(snapshots))
	}
	if snapshots[0].ID != "@1" || snapshots[0].Index != 0 {
		t.Fatalf("first snapshot = %#v, want @1 at index 0", snapshots[0])
	}
	if snapshots[1].ID != "@3" || snapshots[1].Index != 1 {
		t.Fatalf("second snapshot = %#v, want @3 at index 1", snapshots[1])
	}
}

func TestCloseLastWindowRequestsShutdown(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	shouldShutdown, err := server.closeWindow("@1")
	if err != nil {
		t.Fatal(err)
	}
	if !shouldShutdown {
		t.Fatal("closing the last window did not request shutdown")
	}
	if got := server.activeWindowID(); got != "" {
		t.Fatalf("active window = %q, want none", got)
	}
	if snapshots := server.snapshots(); len(snapshots) != 0 {
		t.Fatalf("snapshot count = %d, want 0", len(snapshots))
	}
}

func TestRestoreSnapshotIncludesShellHistory(t *testing.T) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{
			id:                    "@1",
			index:                 0,
			name:                  "zsh",
			command:               "zsh",
			foregroundCommand:     "zsh",
			history:               []byte("shell history"),
			lastActivity:          time.Now(),
			cursorVisible:         false,
			cursorVisibilityKnown: true,
		},
		{
			id:                "@2",
			index:             1,
			name:              "Codex",
			command:           "codex",
			foregroundCommand: "codex",
			agentTool:         "codex",
			history:           []byte("agent history"),
			lastActivity:      time.Now(),
		},
	}
	server.activeID = "@1"

	restore := server.restoreSnapshot()

	if got := len(restore.Windows); got != 2 {
		t.Fatalf("restore window count = %d, want 2", got)
	}
	if got := restore.Windows[0].HistoryBase64; got != base64.StdEncoding.EncodeToString([]byte("shell history")) {
		t.Fatalf("shell history = %q, want encoded shell history", got)
	}
	if !restore.Windows[0].Active {
		t.Fatal("active shell window was not marked active")
	}
	if !restore.Windows[0].CursorVisibilityKnown || restore.Windows[0].CursorVisible {
		t.Fatalf("cursor visibility = known:%v visible:%v, want known hidden", restore.Windows[0].CursorVisibilityKnown, restore.Windows[0].CursorVisible)
	}
	if got := restore.Windows[1].HistoryBase64; got != "" {
		t.Fatalf("agent history = %q, want no replayed agent history", got)
	}
}

func TestCreateWindowOptionsForRestorePreservesShellHistory(t *testing.T) {
	state := restoreWindowState{
		Name:                  "Project shell",
		Cwd:                   "/tmp/project",
		CurrentCommand:        "zsh",
		PaneTitle:             "Project shell",
		HistoryBase64:         base64.StdEncoding.EncodeToString([]byte("prompt")),
		CursorVisible:         false,
		CursorVisibilityKnown: true,
	}

	options := createWindowOptionsForRestore(state, false)

	if options.command != "" {
		t.Fatalf("command = %q, want login shell", options.command)
	}
	if got := string(options.history); got != "prompt" {
		t.Fatalf("history = %q, want prompt", got)
	}
	if options.cwd != "/tmp/project" {
		t.Fatalf("cwd = %q, want /tmp/project", options.cwd)
	}
	if !options.cursorVisibilityKnown || options.cursorVisible {
		t.Fatalf("cursor visibility = known:%v visible:%v, want known hidden", options.cursorVisibilityKnown, options.cursorVisible)
	}
}

func TestCreateWindowOptionsForRestoreBuildsAgentResumeCommand(t *testing.T) {
	state := restoreWindowState{
		Name:           "Copilot CLI",
		Cwd:            "/tmp/project",
		CurrentCommand: "copilot",
		AgentTool:      "copilot",
		AgentSessionID: "session's id",
		HistoryBase64:  base64.StdEncoding.EncodeToString([]byte("old agent screen")),
	}

	options := createWindowOptionsForRestore(state, false)

	if got := options.command; got != "copilot --resume 'session'\"'\"'s id'" {
		t.Fatalf("command = %q, want quoted copilot resume", got)
	}
	if len(options.history) != 0 {
		t.Fatalf("agent restore history length = %d, want 0", len(options.history))
	}
	if options.agentTool != "copilot" {
		t.Fatalf("agent tool = %q, want copilot", options.agentTool)
	}
}

func TestReadRestoreFileKeepsCallerOwnedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "caller-restore.json")
	restore := serverRestore{SchemaVersion: restoreSchemaVersion}
	data, err := json.Marshal(restore)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("restore file was removed, want caller-owned file preserved: %v", err)
	}
}

func TestReadRestoreFileDeletesManagedFileOnlyAfterValidation(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	runDir, err := runtimeDirectory()
	if err != nil {
		t.Fatal(err)
	}
	invalidPath := filepath.Join(
		runDir,
		"monkeymux-restore-aaaaaaaaaaaaaaaaaaaaaaaa-1.json",
	)
	if err := os.WriteFile(invalidPath, []byte(`{"schemaVersion":999}`), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(invalidPath); err == nil {
		t.Fatal("readRestoreFile invalid schema error = nil, want error")
	}
	if _, err := os.Stat(invalidPath); err != nil {
		t.Fatalf("invalid restore file was removed before validation: %v", err)
	}

	validPath := filepath.Join(
		runDir,
		"monkeymux-restore-bbbbbbbbbbbbbbbbbbbbbbbb-2.json",
	)
	restore := serverRestore{SchemaVersion: restoreSchemaVersion}
	data, err := json.Marshal(restore)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := readRestoreFile(validPath); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(validPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("managed restore file stat error = %v, want not exist", err)
	}
}

func TestCreateWindowOptionsForRestoreBuildsYoloAgentCommands(t *testing.T) {
	tests := []struct {
		name      string
		state     restoreWindowState
		want      string
		agentTool string
	}{
		{
			name: "copilot resume",
			state: restoreWindowState{
				Name:           "Copilot CLI",
				CurrentCommand: "copilot",
				AgentTool:      "copilot",
				AgentSessionID: "session-123",
			},
			want:      "copilot --yolo --resume 'session-123'",
			agentTool: "copilot",
		},
		{
			name: "codex launch",
			state: restoreWindowState{
				Name:           "Codex",
				CurrentCommand: "codex",
				AgentTool:      "codex",
			},
			want:      "codex --yolo",
			agentTool: "codex",
		},
		{
			name: "opencode resume",
			state: restoreWindowState{
				Name:           "OpenCode",
				CurrentCommand: "opencode",
				AgentTool:      "opencode",
				AgentSessionID: "_continue",
			},
			want:      `OPENCODE_PERMISSION='{"*":"allow"}' opencode --continue`,
			agentTool: "opencode",
		},
		{
			name: "antigravity resume",
			state: restoreWindowState{
				Name:           "Antigravity",
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
				AgentSessionID: "session-456",
			},
			want:      `agy --dangerously-skip-permissions --conversation 'session-456'`,
			agentTool: "antigravity",
		},
		{
			name: "antigravity resume continue",
			state: restoreWindowState{
				Name:           "Antigravity",
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
				AgentSessionID: "_continue",
			},
			want:      `agy --dangerously-skip-permissions --continue`,
			agentTool: "antigravity",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			options := createWindowOptionsForRestore(tc.state, true)
			if got := options.command; got != tc.want {
				t.Fatalf("command = %q, want %q", got, tc.want)
			}
			if options.agentTool != tc.agentTool {
				t.Fatalf("agent tool = %q, want %q", options.agentTool, tc.agentTool)
			}
		})
	}
}

func TestThemeHintUsesSafeRefreshCapabilities(t *testing.T) {
	focusWindow := &muxWindow{foregroundCommand: "unknown-tui"}
	focusWindow.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	focusWindow.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	colorQueryWindow := &muxWindow{
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
	}
	colorQueryWindow.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	colorQueryWindow.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))
	plainWindow := &muxWindow{foregroundCommand: "codex"}
	plainFocusWindow := &muxWindow{foregroundCommand: "unknown-tui"}
	plainFocusWindow.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	plainQueryWindow := &muxWindow{
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
	}
	plainQueryWindow.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))

	if !focusWindow.supportsThemeHintLocked() {
		t.Fatal("DEC 2031 + focus-aware window did not support theme hints")
	}
	if !colorQueryWindow.supportsThemeHintLocked() {
		t.Fatal("DEC 2031 + OSC 11 query window did not support theme hints")
	}
	if plainWindow.supportsThemeHintLocked() {
		t.Fatal("window without focus mode or OSC 11 query supported theme hints")
	}
	if plainFocusWindow.supportsThemeHintLocked() {
		t.Fatal("focus-aware window without DEC 2031 supported theme hints")
	}
	if plainQueryWindow.supportsThemeHintLocked() {
		t.Fatal("OSC 11 query window without DEC 2031 supported theme hints")
	}

	focusWindow.observeTerminalModesLocked([]byte("\x1b[?1004l"))
	if focusWindow.supportsThemeHintLocked() {
		t.Fatal("window supported theme hints after focus mode disabled")
	}

	colorQueryWindow.foregroundPid = 43
	if colorQueryWindow.supportsThemeHintLocked() {
		t.Fatal("stale OSC 11 query supported theme hints after foreground pid changed")
	}

	colorQueryWindow.foregroundPid = 42
	colorQueryWindow.observeTerminalModesLocked([]byte("\x1b[?2031l"))
	if colorQueryWindow.supportsThemeHintLocked() {
		t.Fatal("window supported theme hints after DEC 2031 disabled")
	}
}

func TestThemeHintVerifiesForegroundPidWithoutThrottle(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	window := &muxWindow{
		id:                         "@1",
		foregroundCommand:          "unknown-tui",
		foregroundPid:              42,
		themeColorQueryPid:         42,
		themeColorQueryKeys:        map[string]bool{"11": true},
		lastProcessMetadataRefresh: time.Now(),
		pty:                        inputWriter,
	}
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 43
		}
		return 0
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent with stale foreground pid")
	}
}

// TestThemeHintDoesNotReSendObservedBackgroundReport guards the
// "hermes spew on every resume" regression. Even when a TUI has
// previously issued an OSC 11 query (and the daemon answered it via
// the live-query path), sendThemeHint must NOT proactively re-push the
// cached response on subsequent theme refreshes. Many TUIs (Nous Hermes,
// Codex, Claude Code) only handle the first response; later unsolicited
// pushes surface as literal "]11;rgb:..." text in their input composer.
func TestThemeHintDoesNotReSendObservedBackgroundReport(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		pty:               inputWriter,
	}
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 42
		}
		return 0
	}
	window.observeTerminalMetadataLocked([]byte("\x1b]11;?\x1b\\"))
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent")
	}
}

func TestThemeHintAnswersFutureBackgroundQuery(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		pty:               inputWriter,
	}
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 42
		}
		return 0
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent before the window requested a background color")
	}

	server.handleWindowOutput("@1", []byte("\x1b]11;?\x1b\\"))

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, backgroundReport)
	})
	if got != backgroundReport {
		t.Fatalf("theme hint = %q, want %q", got, backgroundReport)
	}
}

func TestThemeHintAnswersFuturePaletteQuery(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		foregroundPid:     42,
		pty:               inputWriter,
	}
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 42
		}
		return 0
	}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:1111/2222/3333\x1b\\"
	const paletteReport0 = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	const paletteReport1 = "\x1b]4;1;rgb:dddd/eeee/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport + paletteReport0 + paletteReport1) {
		t.Fatal("theme hint was sent before the window requested a color")
	}

	server.handleWindowOutput("@1", []byte("\x1b]4;0;?\x1b\\"))

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, paletteReport0)
	})
	if got != paletteReport0 {
		t.Fatalf("theme hint = %q, want only palette response %q", got, paletteReport0)
	}
}

func TestThemeHintDoesNotSendBackgroundReportWithoutQuery(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{id: "@1", foregroundCommand: "zsh", pty: inputWriter}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent")
	}
}

// TestThemeHintDoesNotPushUnsolicitedReportsToFocusAwareTui guards the
// "hermes spew" regression. When a focus-aware TUI (Codex, Claude Code,
// Nous Hermes, etc.) has never issued an OSC 10/11/4 query, the daemon
// must NOT push synthetic OSC color responses to it on theme refresh.
// Modern agent CLIs treat unsolicited stdin bytes as keyboard input, so a
// proactive response surfaces as literal "]11;rgb:..." text inside their
// input composer. The synthetic focus transition must not be emitted either:
// Hermes renders that as a growing prompt marker on each re-enter.
func TestThemeHintDoesNotPushUnsolicitedReportsToFocusAwareTui(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "codex",
		pty:               inputWriter,
	}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	const paletteReport = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	if server.sendThemeHint(foregroundReport + backgroundReport + paletteReport) {
		t.Fatal("theme hint was sent")
	}
}

func TestThemeHintDoesNotSignalResizeRedraw(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "codex",
		pty:               inputWriter,
	}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 6262
		}
		return 0
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	if server.sendThemeHint(foregroundReport + backgroundReport) {
		t.Fatal("theme hint was sent")
	}

	if len(signaled) != 0 {
		t.Fatalf("signaled process groups = %#v, want none", signaled)
	}
}

func TestSendThemeHintIgnoresOversizedPayload(t *testing.T) {
	server := newMuxServer("test")
	server.themeHint = []byte("existing")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	if server.sendThemeHint(strings.Repeat("x", themeHintLimitBytes+1)) {
		t.Fatal("oversized theme hint was sent")
	}
	if got := string(server.themeHint); got != "existing" {
		t.Fatalf("theme hint = %q, want existing", got)
	}
}

func TestThemeHintReSendsObservedPaletteReportsToColorSchemeUpdatesTui(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{
		id:                "@1",
		foregroundCommand: "unknown-tui",
		pty:               inputWriter,
	}
	foregroundProcessGroup := 42
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return foregroundProcessGroup
		}
		return 0
	}
	window.observeTerminalMetadataLocked([]byte("\x1b]4;0;?\x1b\\"))
	window.observeTerminalModesLocked([]byte("\x1b[?2031h"))
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	const paletteReport0 = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	const paletteReport1 = "\x1b]4;1;rgb:dddd/eeee/ffff\x1b\\"
	if !server.sendThemeHint(
		foregroundReport + backgroundReport + paletteReport0 + paletteReport1,
	) {
		t.Fatal("theme hint was not sent")
	}

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if !strings.HasPrefix(got, paletteReport0) {
		t.Fatalf(
			"theme hint = %q, want queried palette report prefix %q",
			got,
			paletteReport0,
		)
	}
	if strings.Contains(got, foregroundReport) || strings.Contains(got, backgroundReport) {
		t.Fatalf(
			"theme hint = %q, did not expect unqueried default color reports",
			got,
		)
	}
	if strings.Contains(got, paletteReport1) {
		t.Fatalf("theme hint = %q, did not expect unqueried palette report", got)
	}
	if !strings.Contains(got, "\x1b[O") || !strings.Contains(got, "\x1b[I") {
		t.Fatalf("theme hint = %q, want focus transition", got)
	}
}

func TestThemeHintIgnoresWindowsWithoutThemeCapabilities(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	window := &muxWindow{id: "@1", foregroundCommand: "zsh", pty: inputWriter}
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	if server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was sent")
	}
}

func readPipeUntil(
	t *testing.T,
	reader *os.File,
	predicate func(output string) bool,
) string {
	t.Helper()
	result := make(chan string, 1)
	go func() {
		var output strings.Builder
		buffer := make([]byte, 64)
		for {
			n, err := reader.Read(buffer)
			if n > 0 {
				output.Write(buffer[:n])
				current := output.String()
				if predicate(current) {
					result <- current
					return
				}
			}
			if err != nil {
				result <- output.String()
				return
			}
		}
	}()

	select {
	case output := <-result:
		if !predicate(output) {
			t.Fatalf("pipe output = %q, predicate was not satisfied", output)
		}
		return output
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for pipe output")
		return ""
	}
}

func TestRunShellCommandUsesServerEnvironment(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("MONKEYMUX_TEST_ENV", "ok")
	server := newMuxServer("test")

	output, exitCode, err := server.runShellCommand("printf %s \"$MONKEYMUX_TEST_ENV\"")
	if err != nil {
		t.Fatalf("runShellCommand returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("exitCode = %d, want 0", exitCode)
	}
	if output != "ok" {
		t.Fatalf("output = %q, want ok", output)
	}
}

func BenchmarkStripTerminalQueriesFromReplayClean(b *testing.B) {
	history := bytes.Repeat([]byte("normal terminal output\n"), 4096)
	b.ReportAllocs()
	b.SetBytes(int64(len(history)))

	for i := 0; i < b.N; i++ {
		replay := stripTerminalQueriesFromReplay(history)
		if len(replay) != len(history) {
			b.Fatalf("replay length = %d, want %d", len(replay), len(history))
		}
	}
}

func BenchmarkStripTerminalQueriesFromReplayWithQueries(b *testing.B) {
	history := bytes.Repeat(
		[]byte("before\x1b[c\x1b[6n\x1b]11;?\x07after\n"),
		4096,
	)
	b.ReportAllocs()
	b.SetBytes(int64(len(history)))

	for i := 0; i < b.N; i++ {
		replay := stripTerminalQueriesFromReplay(history)
		if bytes.Contains(replay, []byte("\x1b[c")) {
			b.Fatal("unsafe device attribute query was not stripped")
		}
	}
}

func BenchmarkHandleWindowOutputActive(b *testing.B) {
	server := newMuxServer("test")
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = discardConn{}
	chunk := bytes.Repeat([]byte("screen output\n"), 2048)
	b.ReportAllocs()
	b.SetBytes(int64(len(chunk)))

	for i := 0; i < b.N; i++ {
		server.handleWindowOutput("@1", chunk)
	}
}

func TestRunShellCommandReportsExitCode(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")

	_, exitCode, err := server.runShellCommand("exit 7")
	if err != nil {
		t.Fatalf("runShellCommand returned error: %v", err)
	}
	if exitCode != 7 {
		t.Fatalf("exitCode = %d, want 7", exitCode)
	}
}

func TestRunShellCommandBoundsOutput(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")

	output, _, err := server.runShellCommand("yes x")
	if !errors.Is(err, errRunCommandOutputLimit) {
		t.Fatalf("runShellCommand error = %v, want output limit", err)
	}
	if len(output) != runCommandOutputMaxBytes {
		t.Fatalf(
			"output length = %d, want %d",
			len(output),
			runCommandOutputMaxBytes,
		)
	}
}

func TestControlRunCommandRequestsRunInParallel(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")
	serverConn, clientConn := net.Pipe()
	defer func() {
		_ = clientConn.Close()
	}()
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleControl(serverConn, bufio.NewReader(serverConn))
	}()

	decoder := json.NewDecoder(clientConn)
	readResponse := func() controlResponse {
		t.Helper()
		if err := clientConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	writeRequest := func(request controlMessage) {
		t.Helper()
		if err := clientConn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := json.NewEncoder(clientConn).Encode(request); err != nil {
			t.Fatal(err)
		}
	}

	if response := readResponse(); response.Type != "hello" {
		t.Fatalf("first response type = %q, want hello", response.Type)
	}
	if response := readResponse(); response.Type != "window_list" {
		t.Fatalf("second response type = %q, want window_list", response.Type)
	}

	writeRequest(controlMessage{
		ID:      "slow",
		Type:    "run_command",
		Command: "sleep 0.4; printf slow",
	})
	writeRequest(controlMessage{
		ID:      "fast",
		Type:    "run_command",
		Command: "printf fast",
	})

	if response := readResponse(); response.ID != "fast" || response.Data != "fast" {
		t.Fatalf("first command response = %#v, want fast command output", response)
	}
	if response := readResponse(); response.ID != "slow" || response.Data != "slow" {
		t.Fatalf("second command response = %#v, want slow command output", response)
	}

	_ = clientConn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("control handler did not stop")
	}
}

func TestControlClientCloseCancelsRunCommand(t *testing.T) {
	t.Setenv("SHELL", "/bin/sh")
	server := newMuxServer("test")
	client := newControlClient(nil)
	done := make(chan error, 1)

	startedAt := time.Now()
	go func() {
		_, _, err := client.runShellCommand(server, "slow-command", "sleep 30")
		done <- err
	}()
	waitForTrackedCommand(t, client)

	client.close()

	select {
	case err := <-done:
		if !errors.Is(err, errRunCommandCanceled) {
			t.Fatalf("runShellCommand error = %v, want canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runShellCommand did not stop after client close")
	}
	if elapsed := time.Since(startedAt); elapsed >= 2*time.Second {
		t.Fatalf("command ran for %s after client close", elapsed)
	}
}

func waitForTrackedCommand(t *testing.T, client *controlClient) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		client.commandsMu.Lock()
		count := len(client.commands)
		client.commandsMu.Unlock()
		if count > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("command was not tracked")
}

func TestPromptForServerUpdateDefaultsToKeepingExistingSession(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if promptForServerUpdate(strings.NewReader("\n"), &output, "main", status) {
		t.Fatal("empty prompt response updated server")
	}
	if got := output.String(); !strings.Contains(got, "update skipped") {
		t.Fatalf("prompt output = %q, want skipped message", got)
	}
}

func TestPromptForServerUpdateAcceptsYes(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if !promptForServerUpdate(strings.NewReader("yes\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
}

func TestPromptForServerUpdateWarnsWhenShutdownIsUnavailable(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if !promptForServerUpdate(strings.NewReader("y\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
	if got := output.String(); !strings.Contains(got, "may abandon") {
		t.Fatalf("prompt output = %q, want abandon warning", got)
	}
}

func TestPromptForServerUpdateDescribesWindowRestore(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{
		version:      "0.1.1",
		capabilities: []string{"shutdown"},
	}

	if !promptForServerUpdate(strings.NewReader("y\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
	if got := output.String(); !strings.Contains(got, "try to restore existing windows") {
		t.Fatalf("prompt output = %q, want restore message", got)
	}
}

func TestPromptForServerUpdateSkipsOnReadError(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{version: "0.1.0"}

	if promptForServerUpdate(errReader{}, &output, "main", status) {
		t.Fatal("failed prompt read updated server")
	}
	if got := output.String(); !strings.Contains(got, "update skipped") {
		t.Fatalf("prompt output = %q, want skipped message", got)
	}
}

func TestRunningServerStatusSupportsCapability(t *testing.T) {
	status := runningServerStatus{
		version:      "0.1.0",
		capabilities: []string{"attach", "shutdown"},
	}

	if !status.supportsCapability("shutdown") {
		t.Fatal("expected shutdown capability")
	}
	if status.supportsCapability("missing") {
		t.Fatal("unexpected missing capability")
	}
}

type recordingConn struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

type errReader struct{}

type discardConn struct{}

func (errReader) Read([]byte) (int, error) {
	return 0, io.ErrUnexpectedEOF
}

func (discardConn) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (discardConn) Write(data []byte) (int, error) {
	return len(data), nil
}

func (discardConn) Close() error {
	return nil
}

func (discardConn) LocalAddr() net.Addr {
	return testAddr("local")
}

func (discardConn) RemoteAddr() net.Addr {
	return testAddr("remote")
}

func (discardConn) SetDeadline(time.Time) error {
	return nil
}

func (discardConn) SetReadDeadline(time.Time) error {
	return nil
}

func (discardConn) SetWriteDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (c *recordingConn) Write(data []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(data)
}

func (c *recordingConn) Close() error {
	return nil
}

func (c *recordingConn) LocalAddr() net.Addr {
	return testAddr("local")
}

func (c *recordingConn) RemoteAddr() net.Addr {
	return testAddr("remote")
}

func (c *recordingConn) SetDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) SetReadDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) SetWriteDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

type testAddr string

func (a testAddr) Network() string {
	return string(a)
}

func (a testAddr) String() string {
	return string(a)
}
