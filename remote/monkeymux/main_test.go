package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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
	"unicode/utf8"

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

func assertPtySizeEventually(t *testing.T, file *os.File, columns int, rows int) {
	t.Helper()
	deadline := time.Now().Add(250 * time.Millisecond)
	var lastSize *pty.Winsize
	var lastErr error
	for time.Now().Before(deadline) {
		size, err := pty.GetsizeFull(file)
		if err == nil && int(size.Cols) == columns && int(size.Rows) == rows {
			return
		}
		lastSize = size
		lastErr = err
		time.Sleep(5 * time.Millisecond)
	}
	if lastErr != nil {
		t.Fatal(lastErr)
	}
	if lastSize == nil {
		t.Fatalf("pty size unavailable, want %dx%d", columns, rows)
	}
	t.Fatalf(
		"pty size = %dx%d, want %dx%d",
		lastSize.Cols,
		lastSize.Rows,
		columns,
		rows,
	)
}

func setPtySize(t *testing.T, file *os.File, columns int, rows int) {
	t.Helper()
	if err := pty.Setsize(file, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(columns),
	}); err != nil {
		t.Fatal(err)
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

func TestTerminalEnvironmentAddsTerminalCapabilityDefaults(t *testing.T) {
	base := []string{"USER=test"}

	env := terminalEnvironment(base)

	if !containsEnv(env, "TERM=xterm-256color") {
		t.Fatalf("terminal environment = %#v, want TERM=xterm-256color", env)
	}
	if !containsEnv(env, "COLORTERM=truecolor") {
		t.Fatalf("terminal environment = %#v, want COLORTERM=truecolor", env)
	}
	if !containsEnv(env, "TERM_PROGRAM=kitty") {
		t.Fatalf("terminal environment = %#v, want TERM_PROGRAM=kitty", env)
	}
	if !containsEnv(env, "KITTY_WINDOW_ID=1") {
		t.Fatalf("terminal environment = %#v, want KITTY_WINDOW_ID=1", env)
	}
	if !containsEnv(env, "FORCE_HYPERLINK=1") {
		t.Fatalf("terminal environment = %#v, want FORCE_HYPERLINK=1", env)
	}
	if !reflect.DeepEqual(base, []string{"USER=test"}) {
		t.Fatalf("terminal environment mutated base = %#v", base)
	}
}

func TestTerminalEnvironmentPreservesExistingForceHyperlink(t *testing.T) {
	env := terminalEnvironment([]string{"FORCE_HYPERLINK=0", "USER=test"})

	if !containsEnv(env, "FORCE_HYPERLINK=0") {
		t.Fatalf(
			"terminal environment = %#v, want existing FORCE_HYPERLINK=0 preserved",
			env,
		)
	}
}

func TestTerminalEnvironmentPreservesExistingTrueColorHints(t *testing.T) {
	base := []string{
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"USER=test",
	}

	env := terminalEnvironment(base)

	if !containsEnv(env, "TERM=screen-256color") {
		t.Fatalf("terminal environment = %#v, want existing TERM preserved", env)
	}
	if !containsEnv(env, "COLORTERM=24bit") {
		t.Fatalf("terminal environment = %#v, want existing COLORTERM preserved", env)
	}
	if !containsEnv(env, "TERM_PROGRAM=kitty") {
		t.Fatalf("terminal environment = %#v, want TERM_PROGRAM=kitty", env)
	}
	if !containsEnv(env, "KITTY_WINDOW_ID=1") {
		t.Fatalf("terminal environment = %#v, want KITTY_WINDOW_ID=1", env)
	}
}

func TestTerminalEnvironmentReplacesUnusableTerminalHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM=dumb",
		"COLORTERM=color",
		"USER=test",
		"TERM=",
		"COLORTERM=maybe",
	})

	if got := envValues(env, "TERM"); !reflect.DeepEqual(got, []string{"xterm-256color"}) {
		t.Fatalf("TERM values = %#v in %#v, want only xterm-256color", got, env)
	}
	if got := envValues(env, "COLORTERM"); !reflect.DeepEqual(got, []string{"truecolor"}) {
		t.Fatalf("COLORTERM values = %#v in %#v, want only truecolor", got, env)
	}
	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"kitty"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want only kitty", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"1"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want only 1", got, env)
	}
	if !containsEnv(env, "USER=test") {
		t.Fatalf("terminal environment = %#v, want USER preserved", env)
	}
}

func TestTerminalEnvironmentKeepsExistingUsableTerminalHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM=dumb",
		"TERM=xterm-ghostty",
		"COLORTERM=color",
		"COLORTERM=24bit",
		"USER=test",
	})

	if got := envValues(env, "TERM"); !reflect.DeepEqual(got, []string{"xterm-ghostty"}) {
		t.Fatalf("TERM values = %#v in %#v, want only xterm-ghostty", got, env)
	}
	if got := envValues(env, "COLORTERM"); !reflect.DeepEqual(got, []string{"24bit"}) {
		t.Fatalf("COLORTERM values = %#v in %#v, want only 24bit", got, env)
	}
	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"kitty"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want only kitty", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"1"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want only 1", got, env)
	}
}

func TestTerminalEnvironmentPreservesExistingKittyCompatibleHints(t *testing.T) {
	env := terminalEnvironment([]string{
		"TERM_PROGRAM=WezTerm",
		"KITTY_WINDOW_ID=99",
		"USER=test",
	})

	if got := envValues(env, "TERM_PROGRAM"); !reflect.DeepEqual(got, []string{"WezTerm"}) {
		t.Fatalf("TERM_PROGRAM values = %#v in %#v, want existing WezTerm", got, env)
	}
	if got := envValues(env, "KITTY_WINDOW_ID"); !reflect.DeepEqual(got, []string{"99"}) {
		t.Fatalf("KITTY_WINDOW_ID values = %#v in %#v, want existing 99", got, env)
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

func envValues(env []string, key string) []string {
	prefix := key + "="
	values := []string{}
	for _, candidate := range env {
		if strings.HasPrefix(candidate, prefix) {
			values = append(values, strings.TrimPrefix(candidate, prefix))
		}
	}
	return values
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
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) + "background output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(window *muxWindow) int {
		if window == inactiveWindow {
			return 4242
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize simulated before replay was written: got %q, want %q", got, wantReplay)
		}
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
	if !reflect.DeepEqual(simulated, []string{"@2:80x24"}) {
		t.Fatalf("simulated resizes = %#v, want [@2:80x24]", simulated)
	}
}

func TestSelectWindowSkipsSimulatedResizeWithoutAttach(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		history:      []byte("background output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	if len(simulated) != 0 {
		t.Fatalf("simulated resizes = %#v, want none without attach", simulated)
	}
}

func TestSelectWindowSimulatedResizeUsesLatestServerSize(t *testing.T) {
	server := newMuxServerWithSize("test", 80, 24)
	attach := &writeHookConn{
		recordingConn: &recordingConn{},
		onWrite: func() {
			server.resize(100, 30)
		},
	}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		history:      []byte("background output"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach

	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		simulateForegroundResize = originalSimulateForegroundResize
	}()

	var simulated []string
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	if !reflect.DeepEqual(simulated, []string{"@2:100x30"}) {
		t.Fatalf("simulated resizes = %#v, want [@2:100x30]", simulated)
	}
}

func TestSelectWindowUsesForegroundRedrawReplayForAgentWindows(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("stale tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) +
		replayPostHistorySuffixForTest(true)
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		if got := attach.String(); got != "" {
			t.Fatalf("resize simulated after premature replay write: got %q", got)
		}
	}
	signalForegroundResize = func(processGroup int) {
		if got := attach.String(); got != "" {
			t.Fatalf("resize signaled after premature replay write: got %q", got)
		}
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(attach.String(), "stale tui screen") {
		t.Fatalf("redraw replay retained stale TUI history: %q", attach.String())
	}
	if got := attach.String(); got != "" {
		t.Fatalf("foreground redraw replay was written before redraw settled: %q", got)
	}

	server.handleWindowOutput("@2", []byte("settled tui screen"))
	if got := attach.String(); got != "" {
		t.Fatalf("foreground redraw output was forwarded before replay settled: %q", got)
	}

	server.mu.Lock()
	generation := inactiveWindow.redrawForwardingGeneration
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@2", generation)

	want := wantReplay + "settled tui screen"
	if got := attach.String(); got != want {
		t.Fatalf("settled foreground replay = %q, want %q", got, want)
	}
	if strings.Contains(attach.String(), "stale tui screen") {
		t.Fatalf("settled foreground replay retained stale TUI history: %q", attach.String())
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
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	wantReplay := replayPrefixForTest(window) + "foreground output" +
		replayPostHistorySuffixForTest(true)
	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 4343
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
		if got := attach.String(); got != wantReplay {
			t.Fatalf("resize simulated before replay was written: got %q, want %q", got, wantReplay)
		}
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
	if !reflect.DeepEqual(simulated, []string{"@1:120x40"}) {
		t.Fatalf("simulated resizes = %#v, want [@1:120x40]", simulated)
	}
}

func TestResizeOnlyUpdatesActiveWindowPty(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	server.resize(132, 43)

	assertPtySize(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 80, 24)
}

func TestSelectWindowResizesSelectedWindowToLatestTerminalSize(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
	server.windows = []*muxWindow{
		{id: "@1", index: 0, pty: activePty, lastActivity: time.Now()},
		{id: "@2", index: 1, pty: inactivePty, lastActivity: time.Now()},
	}
	server.activeID = "@1"

	originalSignalForegroundResize := signalForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()
	foregroundProcessGroupForWindow = func(_ *muxWindow) int {
		return 0
	}
	signalForegroundResize = func(_ int) {}

	server.resize(132, 43)
	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	assertPtySizeEventually(t, inactivePty, 132, 43)
}

func TestAttachOnlyUpdatesActiveWindowPty(t *testing.T) {
	server := newMuxServer("test")
	activePty := openTestPty(t)
	inactivePty := openTestPty(t)
	setPtySize(t, inactivePty, 80, 24)
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

	assertPtySizeEventually(t, activePty, 132, 43)
	assertPtySize(t, inactivePty, 80, 24)
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

func TestAttachRefreshesFocusAwareThemeHint(t *testing.T) {
	inputReader, inputWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = inputReader.Close()
		_ = inputWriter.Close()
	})

	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "unknown-tui",
		pty:               inputWriter,
		lastActivity:      time.Now(),
	}
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const backgroundReport = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
	server.handleAttach(
		&recordingConn{},
		bufio.NewReader(strings.NewReader("")),
		controlMessage{Data: backgroundReport},
	)

	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect background report", got)
	}
	if strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, did not expect focus-lost report", got)
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

func TestChangedSizeResizeRedrawsForegroundTui(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		privateModes:      map[string]bool{"1002": true, "1006": true, "2004": true},
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40
	attach := &recordingConn{}
	server.attachConn = attach

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resize(120, 55)

	if !reflect.DeepEqual(simulated, []string{"@1:120x55"}) {
		t.Fatalf("simulated resizes = %#v, want [@1:120x55]", simulated)
	}
	if !reflect.DeepEqual(signaled, []int{5151}) {
		t.Fatalf("signaled process groups = %#v, want [5151]", signaled)
	}
	modeReplay := attach.String()
	for _, sequence := range []string{"\x1b[?1002h", "\x1b[?1006h", "\x1b[?2004h"} {
		if !strings.Contains(modeReplay, sequence) {
			t.Fatalf("mode replay %q does not contain %q", modeReplay, sequence)
		}
	}
}

func TestForcedSameSizeResizeRedrawsForegroundTui(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.width = 120
	server.height = 40

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
	}()

	var signaled []int
	var simulated []string
	foregroundProcessGroupForWindow = func(candidate *muxWindow) int {
		if candidate == window {
			return 5151
		}
		return 0
	}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {
		simulated = append(
			simulated,
			fmt.Sprintf("%s:%dx%d", window.id, width, height),
		)
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	server.resizeWithRedraw(120, 40, true)

	if !reflect.DeepEqual(simulated, []string{"@1:120x40"}) {
		t.Fatalf("simulated resizes = %#v, want [@1:120x40]", simulated)
	}
	if !reflect.DeepEqual(signaled, []int{5151}) {
		t.Fatalf("signaled process groups = %#v, want [5151]", signaled)
	}
}

func TestForegroundRedrawTemporarySize(t *testing.T) {
	tests := []struct {
		name       string
		width      int
		height     int
		wantWidth  int
		wantHeight int
		wantOK     bool
	}{
		{
			name:       "uses narrower width",
			width:      120,
			height:     40,
			wantWidth:  119,
			wantHeight: 40,
			wantOK:     true,
		},
		{
			name:       "falls back to shorter height",
			width:      1,
			height:     40,
			wantWidth:  1,
			wantHeight: 39,
			wantOK:     true,
		},
		{
			name:       "cannot shrink single cell",
			width:      1,
			height:     1,
			wantWidth:  1,
			wantHeight: 1,
			wantOK:     false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			gotWidth, gotHeight, gotOK := foregroundRedrawTemporarySize(
				test.width,
				test.height,
			)
			if gotWidth != test.wantWidth ||
				gotHeight != test.wantHeight ||
				gotOK != test.wantOK {
				t.Fatalf(
					"foregroundRedrawTemporarySize(%d, %d) = (%d, %d, %t), want (%d, %d, %t)",
					test.width,
					test.height,
					gotWidth,
					gotHeight,
					gotOK,
					test.wantWidth,
					test.wantHeight,
					test.wantOK,
				)
			}
		})
	}
}

func TestRedrawResizeBuffersIntermediateAttachOutput(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = conn

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("temporary layout"))
	server.handleWindowOutput("@1", []byte("final layout"))
	if got := conn.String(); got != "" {
		t.Fatalf("attach output before redraw settled = %q, want empty", got)
	}

	server.resumePausedAttachForwarding("@1", generation)

	if got := conn.String(); got != "temporary layoutfinal layout" {
		t.Fatalf("attach output after redraw settled = %q, want buffered output", got)
	}
}

func TestRedrawResizeDropsSupersededBufferedAttachOutput(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = conn

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("old intermediate layout"))

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 41)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@1", []byte("new settled layout"))

	server.resumePausedAttachForwarding("@1", generation)

	if got := conn.String(); got != "new settled layout" {
		t.Fatalf("attach output after superseded redraw = %q, want latest output", got)
	}
}

func TestRedrawResizePreservesPendingReplay(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:           "@2",
		index:        1,
		agentTool:    "copilot",
		history:      []byte("stale tui screen"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		window,
	}
	server.activeID = "@1"
	server.attachConn = conn

	originalSignalForegroundResize := signalForegroundResize
	originalSimulateForegroundResize := simulateForegroundResize
	defer func() {
		signalForegroundResize = originalSignalForegroundResize
		simulateForegroundResize = originalSimulateForegroundResize
	}()
	signalForegroundResize = func(processGroup int) {}
	simulateForegroundResize = func(window *muxWindow, width int, height int) {}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}
	server.handleWindowOutput("@2", []byte("first redraw"))

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 41)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()
	server.handleWindowOutput("@2", []byte("settled redraw"))

	server.resumePausedAttachForwarding("@2", generation)

	wantReplay := replayPrefixForTest(window) +
		replayPostHistorySuffixForTest(true)
	want := wantReplay + "settled redraw"
	if got := conn.String(); got != want {
		t.Fatalf("settled replay after resize = %q, want %q", got, want)
	}
	if strings.Contains(conn.String(), "stale tui screen") ||
		strings.Contains(conn.String(), "first redraw") {
		t.Fatalf("settled replay retained stale output: %q", conn.String())
	}
}

func TestRedrawResizeDropsBufferedAttachOutputWhenInactive(t *testing.T) {
	server := newMuxServer("test")
	conn := &recordingConn{}
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "codex",
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{
		window,
		{id: "@2", index: 1, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = conn

	server.mu.Lock()
	server.pauseAttachForwardingForRedrawLocked(window, 120, 40)
	generation := window.redrawForwardingGeneration
	server.mu.Unlock()

	server.handleWindowOutput("@1", []byte("old active redraw"))
	server.mu.Lock()
	server.activeID = "@2"
	server.mu.Unlock()
	server.resumePausedAttachForwarding("@1", generation)

	if got := conn.String(); got != "" {
		t.Fatalf("inactive buffered output = %q, want empty", got)
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

func TestInactiveWindowUtf8BeforeBellMarksAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte{'x', 0xe2, 0x80, 0x9d, '\a'})

	if !inactiveWindow.alert {
		t.Fatal("bell after UTF-8 continuation bytes did not mark the window alert")
	}
}

func TestInactiveWindowOscTerminatorDoesNotMarkAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("\x1b]0;build\x07"))

	if inactiveWindow.alert {
		t.Fatal("OSC title terminator marked the window alert")
	}
	if inactiveWindow.paneTitle != "build" {
		t.Fatalf("pane title = %q, want build", inactiveWindow.paneTitle)
	}
}

func TestInactiveWindowOscUtf8PayloadDoesNotMarkAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte{
		'\x1b', ']', '0', ';', 'u', 't', 'f', '8', ' ', 0xc5, 0x9c, '\a',
	})

	if inactiveWindow.alert {
		t.Fatal("OSC title UTF-8 continuation byte caused a false alert")
	}
}

func TestInactiveWindowSplitOscTerminatorDoesNotMarkAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("\x1b]0;bui"))
	server.handleWindowOutput("@2", []byte("ld\x07"))

	if inactiveWindow.alert {
		t.Fatal("split OSC title terminator marked the window alert")
	}
	if inactiveWindow.paneTitle != "build" {
		t.Fatalf("pane title = %q, want build", inactiveWindow.paneTitle)
	}
}

func TestInactiveWindowBellAfterOscMarksAlert(t *testing.T) {
	server := newMuxServer("test")
	inactiveWindow := &muxWindow{id: "@2", index: 1, lastActivity: time.Now()}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("\x1b]0;build\x07\a"))

	if !inactiveWindow.alert {
		t.Fatal("bell after OSC title did not mark the window alert")
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
		{
			id:                "@1",
			index:             0,
			foregroundCommand: "zsh",
			history:           history,
			lastActivity:      time.Now(),
		},
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

func TestActiveReplayUsesForegroundRedrawForTrackedAlternateScreenHistory(t *testing.T) {
	for _, mode := range []string{"1047", "1049"} {
		t.Run(mode, func(t *testing.T) {
			server := newMuxServer("test")
			enterAlternateScreen := "\x1b[?" + mode + "h"
			history := []byte(
				enterAlternateScreen +
					"alternate-screen-start" +
					strings.Repeat("alternate-screen-history", windowReplayLimitBytes/8) +
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

			if strings.Contains(replay, "alternate-screen-start") ||
				strings.Contains(replay, "alternate-screen-end") {
				t.Fatalf("alternate-screen redraw replay retained stale history: %q", replay)
			}
			if !strings.Contains(
				replay,
				enterAlternateScreen+terminalScreenClearSequence,
			) {
				t.Fatalf("alternate-screen redraw replay did not clear stale alternate buffer: %q", replay)
			}
			if got, want := len(window.history), len(history); got != want {
				t.Fatalf("history length = %d, want %d", got, want)
			}
		})
	}
}

func TestActiveReplayUsesForegroundRedrawForAgentHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"agent-main-screen-start" +
			strings.Repeat("conversation-history", windowHistoryLimitBytes/8) +
			"agent-main-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "agent-main-screen-start") ||
		strings.Contains(replay, "agent-main-screen-end") {
		t.Fatalf("agent redraw replay retained stale history: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplayDropsAgentAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	enterAlternateScreen := "\x1b[?1049h"
	history := []byte(
		enterAlternateScreen +
			"agent-alternate-screen-start" +
			strings.Repeat("conversation-history", windowReplayLimitBytes/8) +
			"agent-alternate-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		history:      history,
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "agent-alternate-screen-start") ||
		strings.Contains(replay, "agent-alternate-screen-end") {
		t.Fatalf("agent alternate-screen replay retained stale history: %q", replay)
	}
	if !strings.Contains(replay, enterAlternateScreen+terminalScreenClearSequence) {
		t.Fatalf("agent alternate-screen replay did not clear stale alternate buffer: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplaySkipsRunawayAgentHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"agent-main-screen-start" +
			strings.Repeat("conversation-history", windowFullReplayHistoryLimitBytes/4) +
			"agent-main-screen-end",
	)
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "copilot",
		history:      history,
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := server.activeReplayLocked()

	if len(replay) > len(replayPrefixForTest(window))+2048 {
		t.Fatalf("redraw replay length = %d, want no retained history", len(replay))
	}
	if strings.Contains(string(replay), "agent-main-screen") {
		t.Fatalf("agent redraw replay retained runaway history: %q", replay)
	}
}

func TestActiveReplayUsesForegroundRedrawForVimAlternateScreenHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte(
		"interactive-main-screen-start" +
			strings.Repeat("tui-history", windowReplayLimitBytes/8) +
			"interactive-main-screen-end",
	)
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "vim",
		history:           history,
		privateModes:      map[string]bool{"1049": true},
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "interactive-main-screen-start") ||
		strings.Contains(replay, "interactive-main-screen-end") {
		t.Fatalf("interactive redraw replay retained stale history: %q", replay)
	}
	if got, want := len(window.history), len(history); got != want {
		t.Fatalf("history length = %d, want %d", got, want)
	}
}

func TestActiveReplayPreservesNonRedrawForegroundHistory(t *testing.T) {
	server := newMuxServer("test")
	history := []byte("tail output\nlatest line\n")
	window := &muxWindow{
		id:                "@1",
		index:             0,
		foregroundCommand: "tail",
		history:           history,
		lastActivity:      time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.Contains(replay, string(history)) {
		t.Fatalf("line-oriented foreground replay = %q, want history", replay)
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
	for _, mode := range []string{"1047", "1049"} {
		t.Run(mode, func(t *testing.T) {
			server := newMuxServer("test")
			history := []byte(
				"\x1b[?" + mode + "h" +
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

			window.observeTerminalModesLocked(
				[]byte("\x1b[?" + mode + "h" + "\x1b[?" + mode + "l"),
			)
			replay := string(server.activeReplayLocked())

			if strings.Contains(replay, "stale-alt-screen-start") {
				t.Fatalf("main-screen replay retained stale alternate-screen prefix")
			}
			if !strings.Contains(replay, "main-screen-suffix") {
				t.Fatalf("main-screen replay lost recent suffix")
			}
		})
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

func TestReplayStripRemovesDesktopNotifications(t *testing.T) {
	history := []byte("before" +
		"\x1b]9;build finished\x07" +
		"\x1b]777;notify;Deploy;done\x07" +
		"\x1b]99;i=1:d=0;Tests\x1b\\" +
		"\x1b]99;i=1:p=body;412 ok\x1b\\" +
		"middle" +
		"\x1b]9;4;1;50\x07" + // ConEmu progress: not a notification
		"after")

	replay := string(stripTerminalQueriesFromReplay(history))

	for _, stripped := range []string{
		"build finished",
		"\x1b]777;notify;Deploy;done\x07",
		"412 ok",
	} {
		if strings.Contains(replay, stripped) {
			t.Fatalf("replay retained notification %q in %q", stripped, replay)
		}
	}
	if !strings.Contains(replay, "\x1b]9;4;1;50\x07") {
		t.Fatalf("replay stripped ConEmu OSC 9 progress: %q", replay)
	}
	if !strings.Contains(replay, "before") ||
		!strings.Contains(replay, "middle") ||
		!strings.Contains(replay, "after") {
		t.Fatalf("replay = %q, want normal output preserved", replay)
	}
}

func TestObserveKittyGraphicsRetainsImageAcrossHistoryEviction(t *testing.T) {
	window := &muxWindow{}

	transmit := []byte(
		"\x1b_Ga=T,U=1,i=10871563,c=8,r=4,f=100,q=2;iVBORw0KGgo=\x1b\\")
	window.observeKittyGraphicsLocked(transmit)
	// Flood with later output that would evict the transmit from any rolling
	// history; the retained cache must be unaffected.
	window.observeKittyGraphicsLocked(
		bytes.Repeat([]byte("placeholder frame "), 100000))

	replay := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(replay, "i=10871563") ||
		!strings.Contains(replay, "iVBORw0KGgo=") {
		t.Fatalf("retained image lost after eviction-scale output: %q", replay)
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("retained transmit not downgraded to store-only: %q", replay)
	}
}

func TestObserveKittyGraphicsReassemblesSplitTransmission(t *testing.T) {
	window := &muxWindow{}

	// Split a single transmission across several observe calls, including a
	// break inside the base64 payload and between continuation chunks.
	full := "\x1b_Ga=T,U=1,i=5,c=8,r=4,f=100,m=1;AAAA\x1b\\" +
		"\x1b_Gm=1;BBBB\x1b\\" +
		"\x1b_Gm=0;CCCC\x1b\\"
	// Feed byte-by-byte to stress chunk-boundary handling.
	for i := 0; i < len(full); i++ {
		window.observeKittyGraphicsLocked([]byte{full[i]})
	}

	replay := string(window.kittyImageReplayLocked(nil))
	for _, want := range []string{"AAAA", "BBBB", "CCCC", "i=5"} {
		if !strings.Contains(replay, want) {
			t.Fatalf("split transmission missing %q: %q", want, replay)
		}
	}
}

func TestObserveKittyGraphicsDeleteRemovesRetainedImage(t *testing.T) {
	window := &muxWindow{}

	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=7,f=100;PAYLOAD\x1b\\"))
	if got := window.kittyImageReplayLocked(nil); !strings.Contains(string(got), "PAYLOAD") {
		t.Fatalf("image id=7 not retained: %q", got)
	}

	window.observeKittyGraphicsLocked([]byte("\x1b_Ga=d,i=7;\x1b\\"))
	if got := window.kittyImageReplayLocked(nil); len(got) != 0 {
		t.Fatalf("deleted image id=7 still retained: %q", got)
	}
}

func TestObserveKittyGraphicsCapsRetainedImageCount(t *testing.T) {
	window := &muxWindow{}

	for i := 0; i < maxRetainedKittyImages+5; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;DATA%d\x1b\\", i, i)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	if len(window.kittyImageOrder) > maxRetainedKittyImages {
		t.Fatalf("retained %d images, want <= %d",
			len(window.kittyImageOrder), maxRetainedKittyImages)
	}
	// The oldest images are evicted; the most recent are kept.
	replay := string(window.kittyImageReplayLocked(nil))
	if strings.Contains(replay, "DATA0") {
		t.Fatalf("oldest image should have been evicted: %q", replay)
	}
	newest := fmt.Sprintf("DATA%d", maxRetainedKittyImages+4)
	if !strings.Contains(replay, newest) {
		t.Fatalf("newest image %q missing: %q", newest, replay)
	}
}

func TestKittyImageReplayCapsCount(t *testing.T) {
	window := &muxWindow{}
	// Transmit more images than the replay count cap. Each is tiny so the byte
	// budget never binds; only the count cap should.
	const transmitted = maxReplayedKittyImages + 8
	for i := 0; i < transmitted; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;D%d\x1b\\", i, i)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	replay := string(window.kittyImageReplayLocked(nil))
	if got := strings.Count(replay, "i="); got > maxReplayedKittyImages {
		t.Fatalf("replayed %d images, want <= %d", got, maxReplayedKittyImages)
	}
	// The most-recent image is replayed; an image older than the cap is not.
	newest := fmt.Sprintf("D%d\x1b", transmitted-1)
	if !strings.Contains(replay, newest) {
		t.Fatalf("newest image %q missing from replay", newest)
	}
	oldestKept := transmitted - maxReplayedKittyImages
	tooOld := fmt.Sprintf("i=%d,", oldestKept-1)
	if strings.Contains(replay, tooOld) {
		t.Fatalf("image %q older than the replay cap should be omitted", tooOld)
	}
}

func TestKittyImageTransmissionsForReplaysRequestedIdsBeyondReplayCap(t *testing.T) {
	window := &muxWindow{}
	// Transmit more images than the replay caps would ever send at once, using
	// distinct payloads so a request can target an early (older-than-cap) id.
	const transmitted = maxReplayedKittyImages + 8
	for i := 0; i < transmitted; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;PAY%d\x1b\\", i, i)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	// An id well outside the "most recent N" replay window is omitted by the
	// bounded switch replay...
	const oldID = "0"
	if strings.Contains(string(window.kittyImageReplayLocked(nil)), "i=0,") {
		t.Fatalf("precondition: id 0 should be beyond the bounded replay cap")
	}
	// ...but a targeted request replays exactly it, ignoring the caps.
	got := string(window.kittyImageTransmissionsForLocked([]string{oldID}))
	if !strings.Contains(got, "i=0,") || !strings.Contains(got, "PAY0") {
		t.Fatalf("requested id 0 not replayed: %q", got)
	}
	if strings.Contains(got, "PAY1") {
		t.Fatalf("only the requested id should be replayed: %q", got)
	}
	if strings.Contains(got, "a=T") {
		t.Fatalf("requested transmit must stay store-only (a=t): %q", got)
	}
}

func TestKittyImageTransmissionsForSkipsUnknownAndDeduplicates(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=11,f=100;ALPHA\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=22,f=100;BETA\x1b\\"))

	// Unknown ids are skipped; a duplicated id is emitted once.
	got := string(window.kittyImageTransmissionsForLocked(
		[]string{"11", "999", "11", ""}))
	if strings.Count(got, "i=11,") != 1 {
		t.Fatalf("id 11 should be replayed exactly once: %q", got)
	}
	if strings.Contains(got, "i=22,") {
		t.Fatalf("unrequested id 22 must not be replayed: %q", got)
	}
	if strings.Contains(got, "i=999") {
		t.Fatalf("unknown id 999 must be skipped: %q", got)
	}
	// No ids requested replays nothing.
	if len(window.kittyImageTransmissionsForLocked(nil)) != 0 {
		t.Fatalf("empty request must replay nothing")
	}
}

func TestKittyImageReplayCapsBytes(t *testing.T) {
	window := &muxWindow{}
	// Use ~1 MiB images and transmit enough total to exceed the byte budget so
	// it binds before the count cap. Derived from the constant so the test stays
	// valid if the cap changes, while staying within the retention caps.
	const imgBytes = 1024 * 1024
	count := maxReplayedKittyImageBytes/imgBytes + 4
	if count > maxRetainedKittyImages {
		count = maxRetainedKittyImages
	}
	big := strings.Repeat("Z", imgBytes)
	for i := 0; i < count; i++ {
		seq := fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;%s\x1b\\", i, big)
		window.observeKittyGraphicsLocked([]byte(seq))
	}

	replay := window.kittyImageReplayLocked(nil)
	if len(replay) > maxReplayedKittyImageBytes+len(big) {
		t.Fatalf("replay %d bytes exceeds budget %d (+one image slack)",
			len(replay), maxReplayedKittyImageBytes)
	}
	// At least one image (the most recent) is always replayed.
	newest := fmt.Sprintf("i=%d,", count-1)
	if !strings.Contains(string(replay), newest) {
		t.Fatalf("most-recent image %q missing from byte-capped replay", newest)
	}
}

func TestKittyImageReplaySkipsImagesClientAlreadyHolds(t *testing.T) {
	window := &muxWindow{}
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=101,f=100;AAAABBBBCCCC\x1b\\"))
	window.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=202,f=100;DDDDEEEEFFFF\x1b\\"))

	// The client reports holding image 101 with its true signature and image
	// 202 with a stale signature (different content). Only 101 may be skipped.
	clientHas := map[string]uint32{
		"101": window.kittyImageToken["101"],
		"202": window.kittyImageToken["202"] ^ 0x1,
	}
	replay := string(window.kittyImageReplayLocked(clientHas))
	if strings.Contains(replay, "i=101") {
		t.Fatalf("image 101 should be skipped; client holds it: %q", replay)
	}
	if !strings.Contains(replay, "i=202") {
		t.Fatalf("image 202 has a stale client signature and must be re-sent: %q",
			replay)
	}
	// A nil skip-set (fresh attach) still replays everything.
	full := string(window.kittyImageReplayLocked(nil))
	if !strings.Contains(full, "i=101") || !strings.Contains(full, "i=202") {
		t.Fatalf("nil skip-set must replay every image: %q", full)
	}
}

func TestKittyTransmissionPayloadSignatureMatchesClientHash(t *testing.T) {
	// "aGVsbG8=" is base64 for "hello"; the client's FNV-1a-32 over "hello" is
	// 3314369016 (verified against the Dart terminalGraphicsSourceSignature).
	buf := []byte("\x1b_Ga=t,i=1,f=100;aGVsbG8=\x1b\\")
	if got := kittyTransmissionPayloadSignature(buf); got != 3314369016 {
		t.Fatalf("payload signature = %d, want 3314369016 (client parity)", got)
	}
	// Whitespace in the payload is ignored, matching the client's lenient decode.
	spaced := []byte("\x1b_Ga=t,i=1,f=100;aGVs bG8=\n\x1b\\")
	if got := kittyTransmissionPayloadSignature(spaced); got != 3314369016 {
		t.Fatalf("whitespace payload signature = %d, want 3314369016", got)
	}
	// No payload yields 0, which never matches a client-reported signature.
	if got := kittyTransmissionPayloadSignature([]byte("\x1b_Ga=d,i=1\x1b\\")); got != 0 {
		t.Fatalf("payload-less transmission signature = %d, want 0", got)
	}
	// A multi-chunk (m=1) transmission must hash the concatenation of every
	// chunk's decoded payload, identically to the same image sent in one chunk.
	// The client appends each decoded chunk into one buffer before hashing, so
	// "hel" ("aGVs") + "lo" ("bG8=") must hash the same as "hello" above. Kitty
	// splits any payload over 4096 base64 bytes this way, so without covering
	// every chunk no real screenshot's signature would ever match the client.
	multi := []byte("\x1b_Ga=t,i=1,f=100,m=1;aGVs\x1b\\\x1b_Gm=0;bG8=\x1b\\")
	if got := kittyTransmissionPayloadSignature(multi); got != 3314369016 {
		t.Fatalf("multi-chunk payload signature = %d, want 3314369016", got)
	}
}

func TestGlobalKittyImageBudgetEvictsAcrossWindows(t *testing.T) {
	saved := kittyImageGlobalBudgetBytes
	defer func() { kittyImageGlobalBudgetBytes = saved }()
	// Tiny budget so a couple of ~1 MiB images exceed it across two windows.
	kittyImageGlobalBudgetBytes = 2 * 1024 * 1024

	w1 := &muxWindow{id: "@1"}
	w2 := &muxWindow{id: "@2"}
	server := newMuxServer("test")
	server.windows = []*muxWindow{w1, w2}

	big := strings.Repeat("Z", 1024*1024)
	store := func(w *muxWindow, id int) {
		w.observeKittyGraphicsLocked(
			[]byte(fmt.Sprintf("\x1b_Ga=T,U=1,i=%d,f=100;%s\x1b\\", id, big)),
		)
		server.enforceGlobalKittyImageBudgetLocked()
	}

	// Store oldest in w1, then newer images in w2; the global cap must evict the
	// older w1 image even though w1 is under its own per-window cap.
	store(w1, 1)
	store(w2, 2)
	store(w2, 3)

	total := 0
	for _, w := range server.windows {
		for _, b := range w.kittyImages {
			total += len(b)
		}
	}
	if total > kittyImageGlobalBudgetBytes {
		t.Fatalf("global image bytes %d exceed budget %d", total,
			kittyImageGlobalBudgetBytes)
	}
	if _, ok := w1.kittyImages["1"]; ok {
		t.Fatalf("oldest image (w1 id=1) should have been globally evicted")
	}
	if _, ok := w2.kittyImages["3"]; !ok {
		t.Fatalf("newest image (w2 id=3) must be retained")
	}
}

func TestGlobalKittyImageBudgetKeepsAtLeastOne(t *testing.T) {
	saved := kittyImageGlobalBudgetBytes
	defer func() { kittyImageGlobalBudgetBytes = saved }()
	// Budget smaller than a single image: it must keep the one image rather than
	// drop everything (which would render blank).
	kittyImageGlobalBudgetBytes = 1024

	w := &muxWindow{id: "@1"}
	server := newMuxServer("test")
	server.windows = []*muxWindow{w}
	w.observeKittyGraphicsLocked(
		[]byte("\x1b_Ga=T,U=1,i=9,f=100;" + strings.Repeat("Z", 4096) + "\x1b\\"),
	)
	server.enforceGlobalKittyImageBudgetLocked()

	if len(w.kittyImages) != 1 {
		t.Fatalf("expected to keep the single image, have %d", len(w.kittyImages))
	}
}

func TestComputeKittyImageGlobalBudgetClampsToRange(t *testing.T) {
	const floor = 32 * 1024 * 1024
	const ceiling = 512 * 1024 * 1024
	got := computeKittyImageGlobalBudgetBytes()
	if got < floor || got > ceiling {
		t.Fatalf("budget %d out of clamp range [%d,%d]", got, floor, ceiling)
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

func TestStripLocallyAnsweredThemeQueriesPreservesOsc8Hyperlinks(t *testing.T) {
	// OSC 8 hyperlinks (BEL- and ST-terminated, with and without an id=
	// parameter) must pass through untouched even while an interleaved theme
	// query the daemon can answer is stripped.
	chunk := []byte(
		"\x1b]8;;https://example.com/a\x07A\x1b]8;;\x07 " +
			"\x1b]11;?\x07" +
			"\x1b]8;id=1;file:///tmp/x\x1b\\B\x1b]8;;\x1b\\",
	)
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	want := "\x1b]8;;https://example.com/a\x07A\x1b]8;;\x07 " +
		"\x1b]8;id=1;file:///tmp/x\x1b\\B\x1b]8;;\x1b\\"
	got := stripLocallyAnsweredThemeQueries(chunk, hint)
	if string(got) != want {
		t.Fatalf("got = %q, want %q", got, want)
	}
}

func TestStripLocallyAnsweredThemeQueriesPreservesSplitOsc8(t *testing.T) {
	// An OSC 8 hyperlink split across read chunks must survive: the partial
	// sequence is buffered, then forwarded intact (never dropped or treated as
	// an answerable theme query).
	window := &muxWindow{}
	hint := []byte("\x1b]11;rgb:1111/2222/3333\x1b\\")

	first := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("label \x1b]8;;https://exa"),
		hint,
	)
	if string(first) != "label " {
		t.Fatalf("first chunk = %q, want prefix before the split OSC 8", first)
	}

	second := window.stripLocallyAnsweredThemeQueriesLocked(
		[]byte("mple.com/x\x07more"),
		hint,
	)
	if string(first)+string(second) != "label \x1b]8;;https://example.com/x\x07more" {
		t.Fatalf("reassembled = %q, want the OSC 8 hyperlink preserved", string(first)+string(second))
	}
	if len(window.attachOscBuffer) != 0 {
		t.Fatalf("attach OSC buffer = %q, want empty", window.attachOscBuffer)
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

func TestWindowHistoryKeepsLargerTailForForegroundRedrawWindows(t *testing.T) {
	window := &muxWindow{agentTool: "codex"}
	history := []byte(
		"agent-history-start" +
			strings.Repeat("conversation-history", windowHistoryLimitBytes/8) +
			"agent-history-end",
	)

	window.appendHistoryLocked(history)

	tail := string(window.historyTailLocked())
	if !strings.Contains(tail, "agent-history-start") {
		t.Fatalf("agent history tail was trimmed at the shell limit")
	}
	if !strings.Contains(tail, "agent-history-end") {
		t.Fatalf("agent history tail lost suffix")
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

func TestHistoryTailAlignsToUtf8Boundary(t *testing.T) {
	// Place a "│" (U+2502, 0xE2 0x94 0x82) so the history-tail cut lands on
	// one of its continuation bytes, reproducing the malformed-UTF-8 replay
	// that breaks strict decoders on the client (composer border missing
	// until next resize).
	box := []byte{0xE2, 0x94, 0x82}
	window := &muxWindow{}
	window.appendHistoryLocked(bytes.Repeat([]byte{'a'}, windowHistoryLimitBytes-1))
	window.appendHistoryLocked(box)
	window.appendHistoryLocked(bytes.Repeat([]byte{'b'}, windowHistoryLimitBytes-2))

	if len(window.history) != 2*windowHistoryLimitBytes {
		t.Fatalf("history length = %d, want %d", len(window.history), 2*windowHistoryLimitBytes)
	}
	if window.history[windowHistoryLimitBytes]&0xC0 != 0x80 {
		t.Fatalf("setup error: byte at cut is not a continuation byte (0x%02x)", window.history[windowHistoryLimitBytes])
	}

	tail := window.historyTailLocked()
	if !utf8.Valid(tail) {
		t.Fatalf("history tail is not valid UTF-8: % x", tail[:min(len(tail), 32)])
	}
	if len(tail) >= windowHistoryLimitBytes {
		t.Fatalf("aligned tail length = %d, want < %d", len(tail), windowHistoryLimitBytes)
	}
}

func TestTrimReplayHistoryAlignsToUtf8WhenNoControlChars(t *testing.T) {
	// 32 KiB of "│" repeated, with no ESC/LF/CR available for the existing
	// scan-forward heuristic. The byte-exact cut would land on a UTF-8
	// continuation byte, so the function must advance to the next starter.
	box := []byte{0xE2, 0x94, 0x82}
	history := bytes.Repeat(box, (windowReplayLimitBytes*2)/len(box))

	trimmed := trimReplayHistoryForAttach(history)
	if !utf8.Valid(trimmed) {
		t.Fatalf("trimmed replay is not valid UTF-8: % x", trimmed[:min(len(trimmed), 32)])
	}
	if len(trimmed) > windowReplayLimitBytes {
		t.Fatalf("trimmed length = %d, want <= %d", len(trimmed), windowReplayLimitBytes)
	}
}

func TestAdvanceToUtf8BoundarySkipsContinuationBytes(t *testing.T) {
	// 0xE2 0x94 0x82 is "│". Starting in the middle should advance past the
	// continuation bytes to the next valid starter.
	data := []byte{'a', 0xE2, 0x94, 0x82, 'b'}
	if got := advanceToUtf8Boundary(data, 2); got != 4 {
		t.Fatalf("advanceToUtf8Boundary middle = %d, want 4", got)
	}
	if got := advanceToUtf8Boundary(data, 1); got != 1 {
		t.Fatalf("advanceToUtf8Boundary starter = %d, want 1", got)
	}
	if got := advanceToUtf8Boundary(data, 0); got != 0 {
		t.Fatalf("advanceToUtf8Boundary ascii = %d, want 0", got)
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

func TestRestoreWindowOptionsDropMouseTrackingModes(t *testing.T) {
	state := restoreWindowState{
		ID:    "@1",
		Index: 0,
		Name:  "shell",
		PrivateModes: map[string]bool{
			"1000": true,
			"1002": true,
			"1003": true,
			"1006": true,
			"1049": true,
			"7":    false,
		},
	}

	options := createWindowOptionsForRestore(state, false)

	for _, mode := range []string{"1000", "1002", "1003", "1006"} {
		if _, ok := options.privateModes[mode]; ok {
			t.Fatalf("restored options retained mouse mode %s: %#v", mode, options.privateModes)
		}
	}
	if !options.privateModes["1049"] {
		t.Fatalf("restored options dropped non-mouse mode: %#v", options.privateModes)
	}
	if enabled, ok := options.privateModes["7"]; !ok || enabled {
		t.Fatalf("restored options wrap mode = %v, %v, want present false", enabled, ok)
	}
}

func TestWindowSnapshotReportsTerminalMouseModes(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Mouse app",
		privateModes: map[string]bool{"1002": true, "1006": true},
		lastActivity: time.Now(),
	}

	snapshot := server.snapshot(window)

	if !snapshot.TerminalReportsMouseWheel {
		t.Fatal("snapshot did not report mouse wheel mode")
	}
	if !snapshot.TerminalMouseReportSgr {
		t.Fatal("snapshot did not report SGR mouse mode")
	}
	if !snapshot.PrivateModes["1002"] {
		t.Fatalf("snapshot private modes = %#v, want SGR drag mode", snapshot.PrivateModes)
	}
	if !snapshot.PrivateModes["1006"] {
		t.Fatalf("snapshot private modes = %#v, want SGR report mode", snapshot.PrivateModes)
	}
}

func TestMouseTrackingClearsWhenOwningProcessExits(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@1",
		index:         0,
		name:          "tui",
		foregroundPid: 100,
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// A TUI in the foreground turns on mouse tracking + SGR reporting.
	window.observeTerminalModesLocked([]byte("\x1b[?1000h\x1b[?1006h"))

	if !window.reportsMouseWheelLocked() {
		t.Fatal("mouse wheel reporting should be active while the TUI is foreground")
	}
	snapshot := server.snapshot(window)
	if !snapshot.TerminalReportsMouseWheel || !snapshot.TerminalMouseReportSgr {
		t.Fatalf("snapshot = %+v, want mouse wheel + SGR while TUI foreground", snapshot)
	}
	replay := string(window.modeReplayForAttachedTerminalLocked())
	if !strings.Contains(replay, "\x1b[?1000h") {
		t.Fatalf("replay = %q, want mouse mode re-enabled while TUI foreground", replay)
	}

	// The TUI exits without disabling mouse mode; the shell returns to the
	// foreground with a different process group.
	window.foregroundPid = 200

	if window.reportsMouseWheelLocked() {
		t.Fatal("mouse wheel reporting must stop once the owning process exits")
	}
	if window.mouseTrackingActiveLocked() {
		t.Fatal("mouse tracking must not be active for a new foreground process")
	}
	snapshot = server.snapshot(window)
	if snapshot.TerminalReportsMouseWheel {
		t.Fatal("snapshot must not report mouse wheel after the owning process exits")
	}
	if snapshot.TerminalMouseReportSgr {
		t.Fatal("snapshot must not report SGR mouse after the owning process exits")
	}
	replay = string(window.modeReplayForAttachedTerminalLocked())
	if strings.Contains(replay, "\x1b[?1000h") {
		t.Fatalf("replay = %q, must not re-enable mouse mode after owner exits", replay)
	}
}

func TestMouseTrackingProcessIDClearsWhenModesDisabled(t *testing.T) {
	window := &muxWindow{id: "@1", foregroundPid: 100, lastActivity: time.Now()}

	window.observeTerminalModesLocked([]byte("\x1b[?1000h\x1b[?1002h"))
	if window.mouseTrackingProcessID != 100 {
		t.Fatalf("mouseTrackingProcessID = %d, want 100", window.mouseTrackingProcessID)
	}

	// Disabling one of several wheel modes keeps the owner while others remain.
	window.observeTerminalModesLocked([]byte("\x1b[?1000l"))
	if window.mouseTrackingProcessID != 100 {
		t.Fatalf("mouseTrackingProcessID = %d, want owner retained while 1002 stays on", window.mouseTrackingProcessID)
	}

	// Disabling the last wheel mode clears the recorded owner.
	window.observeTerminalModesLocked([]byte("\x1b[?1002l"))
	if window.mouseTrackingProcessID != 0 {
		t.Fatalf("mouseTrackingProcessID = %d, want cleared once no wheel mode remains", window.mouseTrackingProcessID)
	}
}

func TestRestoreFromSnapshotPreservesMouseDragMode(t *testing.T) {
	restore := restoreFromWindowSnapshots([]windowSnapshot{
		{
			ID:                        "@1",
			Index:                     0,
			Name:                      "Mouse app",
			PrivateModes:              map[string]bool{"1002": true, "1006": true},
			TerminalReportsMouseWheel: true,
			TerminalMouseReportSgr:    true,
		},
	})

	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	modes := restore.Windows[0].PrivateModes
	if !modes["1002"] {
		t.Fatalf("restore private modes = %#v, want SGR drag mode", modes)
	}
	if !modes["1006"] {
		t.Fatalf("restore private modes = %#v, want SGR report mode", modes)
	}
}

func TestRestoreFromLegacySnapshotPrefersSgrMouseDrag(t *testing.T) {
	restore := restoreFromWindowSnapshots([]windowSnapshot{
		{
			ID:                        "@1",
			Index:                     0,
			Name:                      "Mouse app",
			TerminalReportsMouseWheel: true,
			TerminalMouseReportSgr:    true,
		},
	})

	if restore == nil || len(restore.Windows) != 1 {
		t.Fatalf("restore windows = %#v, want one window", restore)
	}
	modes := restore.Windows[0].PrivateModes
	if !modes["1002"] {
		t.Fatalf("restore private modes = %#v, want legacy SGR drag mode", modes)
	}
	if !modes["1006"] {
		t.Fatalf("restore private modes = %#v, want SGR report mode", modes)
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

func TestAltScreenReplayRestoresKittyImageButNotHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Copilot CLI",
		paneTitle:    "Copilot CLI",
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	// Stream the window output as the live path does: the image is transmitted
	// once and retained, followed by a flood of other output that evicts it
	// from the rolling visible history. The retained image must still replay.
	window.appendHistoryLocked([]byte("visible tui frame\r\n"))
	transmit := []byte(
		"\x1b_Ga=T,U=1,i=10871563,c=8,r=4,f=100,q=2;iVBORw0KGgo=\x1b\\")
	window.appendHistoryLocked(transmit)
	window.observeKittyGraphicsLocked(transmit)
	placeholders := []byte("\x1b[38;2;165;227;11m\U0010eeee\u0305\u0305 cells")
	window.appendHistoryLocked(placeholders)
	window.observeKittyGraphicsLocked(placeholders)
	// Evict the transmit from the rolling history with newer output.
	flood := bytes.Repeat([]byte("x"), windowFullReplayHistoryLimitBytes+1024)
	window.appendHistoryLocked(flood)
	window.observeKittyGraphicsLocked(flood)
	if bytes.Contains(window.historyTailLocked(), transmit) {
		t.Fatal("precondition failed: transmit should have been evicted from history")
	}

	if !window.usesForegroundRedrawReplayLocked() {
		t.Fatal("alt-screen window should use foreground-redraw replay")
	}

	replay := string(server.replayBytesLocked(window))

	// The image bytes are restored from the retained cache (surviving history
	// eviction) so redrawn placeholders have something to composite, but as a
	// store-only transmit (a=t, not a=T).
	if !strings.Contains(replay, "i=10871563") ||
		!strings.Contains(replay, "iVBORw0KGgo=") {
		t.Fatalf("replay dropped the Kitty image transmission: %q", replay)
	}
	if strings.Contains(replay, "a=T") {
		t.Fatalf("replay kept display action a=T (would place image): %q", replay)
	}
	// The visible TUI history and placeholder cells are NOT replayed; the app
	// redraws them itself.
	if strings.Contains(replay, "visible tui frame") ||
		strings.Contains(replay, "\U0010eeee") {
		t.Fatalf("alt-screen replay leaked visible history (double-draw): %q", replay)
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
		"\x1b[?1047l",
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
	want := replayPrefixForTest(window) + preModes + preHistoryClear +
		terminalParserResetSequence + postModes +
		terminalCharacterSetResetSequence + cursorVisibilityReplaySequence(true)
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
	if strings.Contains(replay, "nano screen") {
		t.Fatalf("editor redraw replay retained stale history: %q", replay)
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

func TestTerminalModeReplayRestoresMouseTrackingAfterDisabledModes(t *testing.T) {
	window := &muxWindow{
		privateModes: map[string]bool{
			"1000": false,
			"1002": true,
			"1003": false,
			"1006": true,
		},
	}

	postModes := string(terminalModePostReplaySequence(window))
	if !strings.Contains(postModes, "\x1b[?1006h") {
		t.Fatalf("post-history modes = %q, want SGR mouse mode restored", postModes)
	}
	if got := lastSequence(
		postModes,
		"\x1b[?1000l",
		"\x1b[?1000h",
		"\x1b[?1002l",
		"\x1b[?1002h",
		"\x1b[?1003l",
		"\x1b[?1003h",
	); got != "\x1b[?1002h" {
		t.Fatalf("last mouse tracking replay = %q in %q, want ?1002h", got, postModes)
	}
}

func TestTerminalModePreReplayRestoresAltBufferAfterDisabledAltMode(t *testing.T) {
	window := &muxWindow{
		privateModes: map[string]bool{
			"1047": true,
			"1049": false,
		},
	}

	preModes := string(terminalModePreReplaySequence(window))
	if got := lastSequence(
		preModes,
		"\x1b[?1047l",
		"\x1b[?1047h",
		"\x1b[?1049l",
		"\x1b[?1049h",
	); got != "\x1b[?1047h" {
		t.Fatalf("last alternate-buffer replay = %q in %q, want ?1047h", got, preModes)
	}
}

func lastSequence(value string, candidates ...string) string {
	lastIndex := -1
	lastValue := ""
	for _, candidate := range candidates {
		if index := strings.LastIndex(value, candidate); index > lastIndex {
			lastIndex = index
			lastValue = candidate
		}
	}
	return lastValue
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

func TestDiscoverCodexSessionIDsUsesOpenRolloutFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	sessionID := "123e4567-e89b-12d3-a456-426614174000"
	processOpenFilePathsForMetadata = func(pid int) []string {
		if pid != 200 {
			return nil
		}
		return []string{
			"/Users/alice/.codex/sessions/2026/06/rollout-2026-06-01T06-50-00-" + sessionID + ".jsonl",
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		t.Fatalf("processWorkingDirectoryForMetadata(%d) was called; open file match should win", pid)
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {
			pid:  200,
			ppid: 100,
			comm: "node",
			args: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
		},
	}

	sessions := discoverCodexSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("codex session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverCodexSessionIDsFallsBackToRecentRolloutForCwd(t *testing.T) {
	originalHome := os.Getenv("HOME")
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		_ = os.Setenv("HOME", originalHome)
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	if err := os.Setenv("HOME", home); err != nil {
		t.Fatal(err)
	}
	sessionID := "123e4567-e89b-12d3-a456-426614174001"
	rolloutDir := filepath.Join(home, ".codex", "sessions", "2026", "06")
	if err := os.MkdirAll(rolloutDir, 0o700); err != nil {
		t.Fatal(err)
	}
	rolloutPath := filepath.Join(
		rolloutDir,
		"rollout-2026-06-01T06-50-00-"+sessionID+".jsonl",
	)
	if err := os.WriteFile(
		rolloutPath,
		[]byte(`{"cwd":"/work/project","id":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(pid int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "codex", args: "codex"},
	}

	sessions := discoverCodexSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("codex session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverCodexSessionIDsSkipsAmbiguousCwdFallback(t *testing.T) {
	originalHome := os.Getenv("HOME")
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		_ = os.Setenv("HOME", originalHome)
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	if err := os.Setenv("HOME", home); err != nil {
		t.Fatal(err)
	}
	sessionID := "123e4567-e89b-12d3-a456-426614174002"
	rolloutDir := filepath.Join(home, ".codex", "sessions", "2026", "06")
	if err := os.MkdirAll(rolloutDir, 0o700); err != nil {
		t.Fatal(err)
	}
	rolloutPath := filepath.Join(
		rolloutDir,
		"rollout-2026-06-01T06-50-00-"+sessionID+".jsonl",
	)
	if err := os.WriteFile(
		rolloutPath,
		[]byte(`{"cwd":"/work/project","id":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(pid int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		switch pid {
		case 200, 201:
			return "/work/project"
		default:
			return ""
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "codex", args: "codex"},
		201: {pid: 201, ppid: 101, comm: "codex", args: "codex"},
	}

	sessions := discoverCodexSessionIDs(
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)

	if len(sessions) != 0 {
		t.Fatalf("codex sessions = %#v, want none for ambiguous cwd fallback", sessions)
	}
}

func TestDiscoverOpenCodeSessionIDsUsesProcessArgs(t *testing.T) {
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		t.Fatal("session store should not be read when the ID is in process args")
		return nil
	}
	processWorkingDirectoryForMetadata = func(int) string { return "" }

	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode --session ses_arg"},
	}

	sessions := discoverOpenCodeSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != "ses_arg" {
		t.Fatalf("opencode session id = %q, want ses_arg", got)
	}
}

func TestDiscoverOpenCodeSessionIDsUsesWorkingDirectory(t *testing.T) {
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		return []openCodeSessionEntry{
			{sessionID: "ses_new", directory: "/work/project"},
			{sessionID: "ses_other", directory: "/tmp/other"},
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode"},
	}

	sessions := discoverOpenCodeSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != "ses_new" {
		t.Fatalf("opencode session id = %q, want ses_new", got)
	}
}

func TestDiscoverOpenCodeSessionIDsSkipsAmbiguousWorkingDirectory(t *testing.T) {
	originalReader := openCodeSessionEntriesReader
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		openCodeSessionEntriesReader = originalReader
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})
	openCodeSessionEntriesReader = func() []openCodeSessionEntry {
		return []openCodeSessionEntry{{sessionID: "ses_new", directory: "/work/project"}}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		switch pid {
		case 200, 201:
			return "/work/project"
		default:
			return ""
		}
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		101: {pid: 101, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "opencode", args: "opencode"},
		201: {pid: 201, ppid: 101, comm: "opencode", args: "opencode"},
	}

	sessions := discoverOpenCodeSessionIDs(
		processes,
		map[int]struct{}{100: {}, 101: {}},
	)

	if len(sessions) != 0 {
		t.Fatalf("opencode sessions = %#v, want none for ambiguous cwd fallback", sessions)
	}
}

func TestDiscoverClaudeSessionIDsUsesOpenProjectFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	sessionID := "de4e84a3-cf16-4cc2-8ba7-34587e984d4a"
	processOpenFilePathsForMetadata = func(pid int) []string {
		if pid != 200 {
			return nil
		}
		return []string{
			"/Users/alice/.claude/projects/-Users-alice-Code-proj/" + sessionID + ".jsonl",
		}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		t.Fatalf("processWorkingDirectoryForMetadata(%d) called; open file match should win", pid)
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}

	sessions := discoverClaudeSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverClaudeSessionIDsFallsBackToRecentProjectFileForCwd(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "fa0a7327-666a-4439-8052-8d9e61c16d3f"
	projectDir := filepath.Join(home, ".claude", "projects", "-work-project")
	if err := os.MkdirAll(projectDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(projectDir, sessionID+".jsonl"),
		[]byte(`{"type":"user","cwd":"/work/project","sessionId":"`+sessionID+`"}`+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "claude", args: "claude"},
	}

	sessions := discoverClaudeSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("claude session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverGeminiSessionIDsUsesOpenChatFile(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	sessionID := "bc1ced23-25ac-4971-8f30-8af35ce2f2f1"
	chatsDir := filepath.Join(t.TempDir(), ".gemini", "tmp", "proj", "chats")
	if err := os.MkdirAll(chatsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	chatPath := filepath.Join(chatsDir, "session-abc.json")
	if err := os.WriteFile(
		chatPath,
		[]byte(`{"sessionId":"`+sessionID+`","kind":"main","directories":["/work/project"]}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(pid int) []string {
		if pid != 200 {
			return nil
		}
		return []string{chatPath}
	}
	processWorkingDirectoryForMetadata = func(pid int) string {
		t.Fatalf("processWorkingDirectoryForMetadata(%d) called; open file match should win", pid)
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "gemini", args: "gemini"},
	}

	sessions := discoverGeminiSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("gemini session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverGeminiSessionIDsFallsBackToRecentChatForCwd(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	sessionID := "bc1ced23-25ac-4971-8f30-8af35ce2f2f1"
	chatsDir := filepath.Join(home, ".gemini", "tmp", "proj", "chats")
	if err := os.MkdirAll(chatsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(chatsDir, "session-abc.json"),
		[]byte(`{"sessionId":"`+sessionID+`","kind":"main","directories":["/work/project"],"messages":[`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "gemini", args: "gemini"},
	}

	sessions := discoverGeminiSessionIDs(processes, map[int]struct{}{100: {}})

	if got := sessions[100]; got != sessionID {
		t.Fatalf("gemini session id = %q, want %q", got, sessionID)
	}
}

func TestDiscoverGeminiSessionIDsSkipsSubagentChats(t *testing.T) {
	originalOpenFiles := processOpenFilePathsForMetadata
	originalWorkingDirectory := processWorkingDirectoryForMetadata
	t.Cleanup(func() {
		processOpenFilePathsForMetadata = originalOpenFiles
		processWorkingDirectoryForMetadata = originalWorkingDirectory
	})

	home := t.TempDir()
	t.Setenv("HOME", home)
	chatsDir := filepath.Join(home, ".gemini", "tmp", "proj", "chats")
	if err := os.MkdirAll(chatsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(chatsDir, "session-sub.json"),
		[]byte(`{"sessionId":"sub-1","kind":"subagent","directories":["/work/project"]}`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	processOpenFilePathsForMetadata = func(int) []string { return nil }
	processWorkingDirectoryForMetadata = func(pid int) string {
		if pid == 200 {
			return "/work/project"
		}
		return ""
	}
	processes := map[int]processInfo{
		100: {pid: 100, ppid: 1, comm: "zsh", args: "zsh"},
		200: {pid: 200, ppid: 100, comm: "gemini", args: "gemini"},
	}

	sessions := discoverGeminiSessionIDs(processes, map[int]struct{}{100: {}})

	if len(sessions) != 0 {
		t.Fatalf("gemini sessions = %#v, want none for subagent chats", sessions)
	}
}

func TestParseGeminiSessionMetadataFromTruncatedPrefix(t *testing.T) {
	metadata := parseGeminiSessionMetadata(`{
  "sessionId": "session-large",
  "kind": "main",
  "directories": ["/Users/depoll/Code/flutty"],
  "messages": [
`)
	if metadata.sessionID != "session-large" {
		t.Fatalf("sessionID = %q, want session-large", metadata.sessionID)
	}
	if metadata.isSubagent {
		t.Fatal("isSubagent = true, want false")
	}
	if len(metadata.directories) != 1 ||
		metadata.directories[0] != "/Users/depoll/Code/flutty" {
		t.Fatalf("directories = %#v, want [/Users/depoll/Code/flutty]", metadata.directories)
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

	if got := options.command; got != "copilot --resume 'session'\"'\"'s id' || copilot" {
		t.Fatalf("command = %q, want quoted copilot resume with fresh fallback", got)
	}
	if len(options.history) != 0 {
		t.Fatalf("agent restore history length = %d, want 0", len(options.history))
	}
	if options.agentTool != "copilot" {
		t.Fatalf("agent tool = %q, want copilot", options.agentTool)
	}
}

func TestEnrichRestoreWithAgentSessionIDsUsesAntigravityHistory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	project := filepath.Join(home, "project")
	historyDir := filepath.Join(home, ".gemini", "antigravity-cli")
	if err := os.MkdirAll(historyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	history := strings.Join([]string{
		`{"conversationId":"old-session","workspace":"` + project + `","display":"Old"}`,
		`{"conversationId":"new-session","workspace":"` + project + `","display":"New"}`,
		`{"conversationId":"other-session","workspace":"/tmp/other","display":"Other"}`,
	}, "\n")
	if err := os.WriteFile(
		filepath.Join(historyDir, "history.jsonl"),
		[]byte(history+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	restore := &serverRestore{
		Windows: []restoreWindowState{
			{
				Name:           "Antigravity",
				Cwd:            project,
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
			},
		},
	}

	enrichRestoreWithAgentSessionIDs(restore)

	if got := restore.Windows[0].AgentSessionID; got != "new-session" {
		t.Fatalf("agent session ID = %q, want new-session", got)
	}
	options := createWindowOptionsForRestore(restore.Windows[0], true)
	if got := options.command; got != "agy --dangerously-skip-permissions --conversation 'new-session' || agy --dangerously-skip-permissions" {
		t.Fatalf("command = %q, want Antigravity resume command with fresh fallback", got)
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
			want:      "copilot --yolo --resume 'session-123' || copilot --yolo",
			agentTool: "copilot",
		},
		{
			name: "codex resume",
			state: restoreWindowState{
				Name:           "Codex",
				CurrentCommand: "codex",
				AgentTool:      "codex",
				AgentSessionID: "codex-session",
			},
			want:      "codex --yolo resume 'codex-session' || codex --yolo",
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
			want:      `OPENCODE_PERMISSION='{"*":"allow"}' opencode --continue || OPENCODE_PERMISSION='{"*":"allow"}' opencode`,
			agentTool: "opencode",
		},
		{
			name: "opencode resume by id",
			state: restoreWindowState{
				Name:           "OpenCode",
				CurrentCommand: "opencode",
				AgentTool:      "opencode",
				AgentSessionID: "ses_abc",
			},
			want:      `OPENCODE_PERMISSION='{"*":"allow"}' opencode --session 'ses_abc' || OPENCODE_PERMISSION='{"*":"allow"}' opencode`,
			agentTool: "opencode",
		},
		{
			name: "claude resume",
			state: restoreWindowState{
				Name:           "Claude Code",
				CurrentCommand: "claude",
				AgentTool:      "claude",
				AgentSessionID: "de4e84a3-cf16-4cc2-8ba7-34587e984d4a",
			},
			want:      `claude --dangerously-skip-permissions --resume 'de4e84a3-cf16-4cc2-8ba7-34587e984d4a' || claude --dangerously-skip-permissions`,
			agentTool: "claude",
		},
		{
			name: "gemini resume",
			state: restoreWindowState{
				Name:           "Gemini CLI",
				CurrentCommand: "gemini",
				AgentTool:      "gemini",
				AgentSessionID: "bc1ced23-25ac-4971-8f30-8af35ce2f2f1",
			},
			want:      `gemini --yolo --resume 'bc1ced23-25ac-4971-8f30-8af35ce2f2f1' || gemini --yolo`,
			agentTool: "gemini",
		},
		{
			name: "antigravity resume",
			state: restoreWindowState{
				Name:           "Antigravity",
				CurrentCommand: "agy",
				AgentTool:      "antigravity",
				AgentSessionID: "session-456",
			},
			want:      `agy --dangerously-skip-permissions --conversation 'session-456' || agy --dangerously-skip-permissions`,
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
			want:      `agy --dangerously-skip-permissions --continue || agy --dangerously-skip-permissions`,
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
	copilotFocusWindow := &muxWindow{foregroundCommand: "copilot"}
	copilotFocusWindow.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	copilotPlainWindow := &muxWindow{foregroundCommand: "copilot"}

	if !focusWindow.supportsThemeHintLocked() {
		t.Fatal("DEC 2031 + focus-aware window did not support theme hints")
	}
	if !colorQueryWindow.supportsThemeHintLocked() {
		t.Fatal("DEC 2031 + OSC 11 query window did not support theme hints")
	}
	if !copilotFocusWindow.supportsThemeHintLocked() {
		t.Fatal("Copilot focus-aware window did not support theme hints")
	}
	if copilotPlainWindow.supportsThemeHintLocked() {
		t.Fatal("Copilot window without focus mode supported theme hints")
	}
	if plainWindow.supportsThemeHintLocked() {
		t.Fatal("window without focus mode or OSC 11 query supported theme hints")
	}
	if !plainFocusWindow.supportsThemeHintLocked() {
		t.Fatal("focus-aware window did not support focus refresh")
	}
	if plainQueryWindow.supportsThemeHintLocked() {
		t.Fatal("OSC 11 query window without DEC 2031 supported theme hints")
	}

	focusWindow.observeTerminalModesLocked([]byte("\x1b[?1004l"))
	if focusWindow.supportsThemeHintLocked() {
		t.Fatal("window supported theme hints after focus mode disabled")
	}
	plainFocusWindow.observeTerminalModesLocked([]byte("\x1b[?1004l"))
	if plainFocusWindow.supportsThemeHintLocked() {
		t.Fatal("plain focus-aware window supported theme hints after focus mode disabled")
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
// cached response on subsequent theme refreshes unless the foreground
// tool is known to tolerate it. Many TUIs only handle the first response;
// later unsolicited pushes surface as literal "]11;rgb:..." text in their
// input composer.
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
	if !server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was not sent")
	}
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect unsolicited background report", got)
	}
	if strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, did not expect focus-lost report", got)
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
	if !server.sendThemeHint(backgroundReport) {
		t.Fatal("theme hint was not sent")
	}
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect background report", got)
	}
	if strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, did not expect focus-lost report", got)
	}
}

// TestThemeHintDoesNotPushUnsolicitedColorReportsToFocusAwareTui guards the
// "hermes spew" regression. When an unknown focus-aware TUI has never issued
// an OSC 10/11/4 query, the daemon must NOT push synthetic OSC color
// responses to it on theme refresh. It may send a FocusIn nudge so the TUI
// can re-query through the normal live-query path.
func TestThemeHintDoesNotPushUnsolicitedColorReportsToFocusAwareTui(t *testing.T) {
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
	window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	server := newMuxServer("test")
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
	const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
	const paletteReport = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
	if !server.sendThemeHint(foregroundReport + backgroundReport + paletteReport) {
		t.Fatal("theme hint was not sent")
	}
	got := readPipeUntil(t, inputReader, func(output string) bool {
		return strings.Contains(output, "\x1b[I")
	})
	if strings.Contains(got, foregroundReport) {
		t.Fatalf("theme hint = %q, did not expect foreground report", got)
	}
	if strings.Contains(got, backgroundReport) {
		t.Fatalf("theme hint = %q, did not expect background report", got)
	}
	if strings.Contains(got, paletteReport) {
		t.Fatalf("theme hint = %q, did not expect palette report", got)
	}
	if strings.Contains(got, "\x1b[O") {
		t.Fatalf("theme hint = %q, did not expect focus-lost report", got)
	}
}

func TestThemeHintRefreshesAgentToolsWithoutColorSchemeUpdatesMode(t *testing.T) {
	for _, tt := range []struct {
		name                string
		command             string
		wantModeReport      bool
		wantFocusTransition bool
	}{
		{name: "copilot", command: "copilot", wantModeReport: true},
		{name: "codex", command: "codex"},
		{name: "claude", command: "claude", wantFocusTransition: true},
		{name: "gemini", command: "gemini", wantFocusTransition: true},
		{name: "opencode", command: "opencode", wantFocusTransition: true},
		{name: "antigravity", command: "antigravity", wantFocusTransition: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
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
				foregroundCommand: tt.command,
				pty:               inputWriter,
			}
			window.observeTerminalModesLocked([]byte("\x1b[?1004h"))
			server := newMuxServer("test")
			server.windows = []*muxWindow{window}
			server.activeID = "@1"

			const modeReport = "\x1b[?997;1n"
			const foregroundReport = "\x1b]10;rgb:1111/2222/3333\x1b\\"
			const backgroundReport = "\x1b]11;rgb:4444/5555/6666\x1b\\"
			const paletteReport = "\x1b]4;0;rgb:aaaa/bbbb/cccc\x1b\\"
			if !server.sendThemeHint(
				modeReport + foregroundReport + backgroundReport + paletteReport,
			) {
				t.Fatal("theme hint was not sent")
			}

			got := readPipeUntil(t, inputReader, func(output string) bool {
				return strings.Contains(output, backgroundReport) &&
					strings.Contains(output, "\x1b[I")
			})
			if tt.wantModeReport {
				if !strings.Contains(got, modeReport+backgroundReport) {
					t.Fatalf(
						"theme hint = %q, expected mode report before background report",
						got,
					)
				}
			} else if strings.Contains(got, modeReport) {
				t.Fatalf("theme hint = %q, did not expect theme mode report", got)
			}
			if strings.Contains(got, foregroundReport) {
				t.Fatalf("theme hint = %q, did not expect foreground report", got)
			}
			if strings.Contains(got, paletteReport) {
				t.Fatalf("theme hint = %q, did not expect palette report", got)
			}
			if tt.wantFocusTransition {
				if !strings.Contains(got, "\x1b[O") {
					t.Fatalf("theme hint = %q, expected focus-lost report", got)
				}
			} else if strings.Contains(got, "\x1b[O") {
				t.Fatalf("theme hint = %q, did not expect focus-lost report", got)
			}
		})
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
	if !server.sendThemeHint(foregroundReport + backgroundReport) {
		t.Fatal("theme hint was not sent")
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

type writeHookConn struct {
	*recordingConn
	onWrite func()
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

func (c *writeHookConn) Write(data []byte) (int, error) {
	n, err := c.recordingConn.Write(data)
	if c.onWrite != nil {
		c.onWrite()
	}
	return n, err
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
