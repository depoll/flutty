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
	prefix := activeWindowReplayPrefixBeforeAlt
	if window.replayNeedsRedrawLocked() {
		prefix = attachSessionEnterSequence + prefix + activeWindowReplayPrefixAfterAltClear
	} else {
		prefix = attachSessionExitSequence + prefix + activeWindowReplayPrefixAfterAltHistory
	}
	return prefix + string(terminalTitleReplaySequence(window))
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

	if err := server.selectWindow("@2", terminalResizeRequest{}); err != nil {
		t.Fatal(err)
	}

	want := replayPrefixForTest(inactiveWindow) + "background output" +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
	if inactiveWindow.alert {
		t.Fatal("selected window alert was not cleared")
	}
}

func TestSelectWindowResizesPtyWithoutPostReplayNudge(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	inactiveWindow := &muxWindow{
		id:           "@2",
		index:        1,
		pty:          slave,
		lastActivity: time.Now(),
	}
	t.Cleanup(func() {
		_ = master.Close()
		_ = inactiveWindow.closePty()
	})
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		inactiveWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 48
	server.height = 40
	inactiveWindow.history = []byte("background output")

	originalNudgeForegroundResize := nudgeForegroundResize
	defer func() {
		nudgeForegroundResize = originalNudgeForegroundResize
	}()

	wantReplay := replayPrefixForTest(inactiveWindow) + "background output" +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	var nudged []*muxWindow
	nudgeForegroundResize = func(window *muxWindow, width int, height int) {
		nudged = append(nudged, window)
	}

	if err := server.selectWindow("@2", terminalResizeRequest{}); err != nil {
		t.Fatal(err)
	}

	if got := attach.String(); got != wantReplay {
		t.Fatalf("attach output = %q, want %q", got, wantReplay)
	}
	size, err := pty.GetsizeFull(slave)
	if err != nil {
		t.Fatal(err)
	}
	if size.Cols != 48 || size.Rows != 40 {
		t.Fatalf("pty size = %dx%d, want 48x40", size.Cols, size.Rows)
	}
	if len(nudged) != 0 {
		t.Fatalf("nudged windows = %#v, want none", nudged)
	}
}

func TestSelectWindowAppliesRequestedSizeBeforeReplayAndRedraw(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	codexWindow := &muxWindow{
		id:           "@2",
		index:        1,
		name:         "Codex",
		agentTool:    "codex",
		pty:          slave,
		history:      []byte("codex history"),
		lastActivity: time.Now(),
	}
	t.Cleanup(func() {
		_ = master.Close()
		_ = codexWindow.closePty()
	})
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		codexWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 80
	server.height = 24

	originalNudgeForegroundSameSize := nudgeForegroundSameSize
	defer func() {
		nudgeForegroundSameSize = originalNudgeForegroundSameSize
	}()

	var sameSizeNudged []struct {
		window *muxWindow
		width  int
		height int
	}
	nudgeForegroundSameSize = func(window *muxWindow, width int, height int) {
		sameSizeNudged = append(sameSizeNudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}

	if err := server.selectWindow("@2", terminalResizeRequest{width: 100, height: 32}); err != nil {
		t.Fatal(err)
	}

	size, err := pty.GetsizeFull(slave)
	if err != nil {
		t.Fatal(err)
	}
	if size.Cols != 100 || size.Rows != 32 {
		t.Fatalf("pty size = %dx%d, want 100x32", size.Cols, size.Rows)
	}
	if server.width != 100 || server.height != 32 {
		t.Fatalf("server size = %dx%d, want 100x32", server.width, server.height)
	}
	wantSameSizeNudged := []struct {
		window *muxWindow
		width  int
		height int
	}{{window: codexWindow, width: 100, height: 32}}
	if !reflect.DeepEqual(sameSizeNudged, wantSameSizeNudged) {
		t.Fatalf("same-size nudged windows = %#v, want %#v", sameSizeNudged, wantSameSizeNudged)
	}
}

func TestSelectCodexWindowClearsReplayHistoryAndSignalsRedraw(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	agentWindow := &muxWindow{
		id:            "@2",
		index:         1,
		name:          "Codex",
		agentTool:     "codex",
		replayHistory: []byte("stale codex partial frame"),
		// Most TUI agents (claude-code, opencode, gemini, plus Codex's
		// transcript overlay) own the outer alt buffer. Those replays must
		// clear screen + scrollback so xterm.dart's circular buffer does
		// not crash on cursor-addressed redraws.
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		agentWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 48
	server.height = 40

	originalNudgeForegroundSameSize := nudgeForegroundSameSize
	originalNudgeForegroundResize := nudgeForegroundResize
	defer func() {
		nudgeForegroundSameSize = originalNudgeForegroundSameSize
		nudgeForegroundResize = originalNudgeForegroundResize
	}()

	var sameSizeNudged []struct {
		window *muxWindow
		width  int
		height int
	}
	var resizeNudged []struct {
		window *muxWindow
		width  int
		height int
	}
	nudgeForegroundSameSize = func(window *muxWindow, width int, height int) {
		sameSizeNudged = append(sameSizeNudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}
	nudgeForegroundResize = func(window *muxWindow, width int, height int) {
		resizeNudged = append(resizeNudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}

	if err := server.selectWindow("@2", terminalResizeRequest{}); err != nil {
		t.Fatal(err)
	}

	wantReplay := replayPrefixForTest(agentWindow) +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	if got := attach.String(); got != wantReplay {
		t.Fatalf("attach output = %q, want %q", got, wantReplay)
	}
	if strings.Contains(attach.String(), "stale codex partial frame") {
		t.Fatalf("agent replay included stale history: %q", attach.String())
	}
	wantSameSizeNudged := []struct {
		window *muxWindow
		width  int
		height int
	}{{window: agentWindow, width: 48, height: 40}}
	if !reflect.DeepEqual(sameSizeNudged, wantSameSizeNudged) {
		t.Fatalf("same-size nudged windows = %#v, want %#v", sameSizeNudged, wantSameSizeNudged)
	}
	if len(resizeNudged) != 0 {
		t.Fatalf("resize nudged windows = %#v, want none", resizeNudged)
	}
}

func TestSelectAlternateBufferWindowClearsReplayHistoryAndNudgesRedraw(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	altWindow := &muxWindow{
		id:            "@2",
		index:         1,
		name:          "editor",
		replayHistory: []byte("stale fullscreen frame"),
		privateModes:  map[string]bool{"1049": true},
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		altWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 90
	server.height = 30

	originalNudgeForegroundResize := nudgeForegroundResize
	defer func() {
		nudgeForegroundResize = originalNudgeForegroundResize
	}()

	var nudged []struct {
		window *muxWindow
		width  int
		height int
	}
	nudgeForegroundResize = func(window *muxWindow, width int, height int) {
		nudged = append(nudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}

	if err := server.selectWindow("@2", terminalResizeRequest{}); err != nil {
		t.Fatal(err)
	}

	wantReplay := replayPrefixForTest(altWindow) +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	if got := attach.String(); got != wantReplay {
		t.Fatalf("attach output = %q, want %q", got, wantReplay)
	}
	if strings.Contains(attach.String(), "stale fullscreen frame") {
		t.Fatalf("alternate-buffer replay included stale history: %q", attach.String())
	}
	wantNudged := []struct {
		window *muxWindow
		width  int
		height int
	}{{window: altWindow, width: 90, height: 30}}
	if !reflect.DeepEqual(nudged, wantNudged) {
		t.Fatalf("nudged windows = %#v, want %#v", nudged, wantNudged)
	}
}

func TestNudgeForegroundResizeAppliesNudgeImmediatelyAndRestoresAsync(t *testing.T) {
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{pty: slave}
	t.Cleanup(func() {
		_ = master.Close()
		_ = window.closePty()
	})
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 40, Cols: 48}); err != nil {
		t.Fatal(err)
	}

	nudgeForegroundResize(window, 48, 40)

	size, err := pty.GetsizeFull(slave)
	if err != nil {
		t.Fatal(err)
	}
	if size.Cols != 49 || size.Rows != 40 {
		t.Fatalf("immediate pty size = %dx%d, want 49x40", size.Cols, size.Rows)
	}

	deadline := time.Now().Add(nudgeRestoreDelay + 250*time.Millisecond)
	for time.Now().Before(deadline) {
		size, err = pty.GetsizeFull(slave)
		if err != nil {
			t.Fatal(err)
		}
		if size.Cols == 48 && size.Rows == 40 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("pty size did not restore; got %dx%d, want 48x40", size.Cols, size.Rows)
}

func TestNudgeForegroundResizeSkipsRestoreAfterWindowClose(t *testing.T) {
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{pty: slave}
	t.Cleanup(func() {
		_ = master.Close()
		_ = window.closePty()
	})
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 40, Cols: 48}); err != nil {
		t.Fatal(err)
	}

	nudgeForegroundResize(window, 48, 40)
	if err := window.closePty(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(nudgeRestoreDelay + 25*time.Millisecond)
}

func TestNudgeForegroundSameSizeKeepsPtyGeometry(t *testing.T) {
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{pty: slave}
	t.Cleanup(func() {
		_ = master.Close()
		_ = window.closePty()
	})
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 40, Cols: 48}); err != nil {
		t.Fatal(err)
	}

	originalForegroundProcessGroupForWindow := foregroundProcessGroupForWindow
	originalSignalForegroundResize := signalForegroundResize
	defer func() {
		foregroundProcessGroupForWindow = originalForegroundProcessGroupForWindow
		signalForegroundResize = originalSignalForegroundResize
	}()

	var signaled []int
	foregroundProcessGroupForWindow = func(window *muxWindow) int {
		return 4242
	}
	signalForegroundResize = func(processGroup int) {
		signaled = append(signaled, processGroup)
	}

	nudgeForegroundSameSize(window, 48, 40)

	size, err := pty.GetsizeFull(slave)
	if err != nil {
		t.Fatal(err)
	}
	if size.Cols != 48 || size.Rows != 40 {
		t.Fatalf("pty size = %dx%d, want unchanged 48x40", size.Cols, size.Rows)
	}
	if !reflect.DeepEqual(signaled, []int{4242}) {
		t.Fatalf("signaled process groups = %#v, want [4242]", signaled)
	}
}

func TestResizeRedrawsCodexAtNewSize(t *testing.T) {
	server := newMuxServer("test")
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	codexWindow := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Codex",
		agentTool:    "codex",
		pty:          slave,
		lastActivity: time.Now(),
	}
	t.Cleanup(func() {
		_ = master.Close()
		_ = codexWindow.closePty()
	})
	server.windows = []*muxWindow{codexWindow}
	server.activeID = "@1"
	server.width = 80
	server.height = 24

	originalNudgeForegroundSameSize := nudgeForegroundSameSize
	defer func() {
		nudgeForegroundSameSize = originalNudgeForegroundSameSize
	}()

	var sameSizeNudged []struct {
		window *muxWindow
		width  int
		height int
	}
	nudgeForegroundSameSize = func(window *muxWindow, width int, height int) {
		sameSizeNudged = append(sameSizeNudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}

	server.resize(100, 32)

	size, err := pty.GetsizeFull(slave)
	if err != nil {
		t.Fatal(err)
	}
	if size.Cols != 100 || size.Rows != 32 {
		t.Fatalf("pty size = %dx%d, want 100x32", size.Cols, size.Rows)
	}
	wantSameSizeNudged := []struct {
		window *muxWindow
		width  int
		height int
	}{{window: codexWindow, width: 100, height: 32}}
	if !reflect.DeepEqual(sameSizeNudged, wantSameSizeNudged) {
		t.Fatalf("same-size nudged windows = %#v, want %#v", sameSizeNudged, wantSameSizeNudged)
	}
}

func TestResizeClearsCodexInlineViewportBandBeforeRedraw(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 24, Cols: 80}); err != nil {
		t.Fatal(err)
	}
	codexWindow := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Codex",
		agentTool:    "codex",
		pty:          slave,
		lastActivity: time.Now(),
	}
	t.Cleanup(func() {
		_ = master.Close()
		_ = codexWindow.closePty()
	})
	server.windows = []*muxWindow{codexWindow}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 80
	server.height = 24

	originalNudgeForegroundSameSize := nudgeForegroundSameSize
	defer func() {
		nudgeForegroundSameSize = originalNudgeForegroundSameSize
	}()

	var sameSizeNudged []struct {
		window *muxWindow
		width  int
		height int
	}
	nudgeForegroundSameSize = func(window *muxWindow, width int, height int) {
		sameSizeNudged = append(sameSizeNudged, struct {
			window *muxWindow
			width  int
			height int
		}{window: window, width: width, height: height})
	}

	server.resize(100, 32)

	wantClear := codexVisibleRedrawSequence
	if got := attach.String(); got != wantClear {
		t.Fatalf("attach output = %q, want Codex visible redraw invalidation %q", got, wantClear)
	}
	wantSameSizeNudged := []struct {
		window *muxWindow
		width  int
		height int
	}{{window: codexWindow, width: 100, height: 32}}
	if !reflect.DeepEqual(sameSizeNudged, wantSameSizeNudged) {
		t.Fatalf("same-size nudged windows = %#v, want %#v", sameSizeNudged, wantSameSizeNudged)
	}
}

func TestResizeForwarderStateSkipsUnchangedSizes(t *testing.T) {
	var state resizeForwarderState

	if !state.shouldSend(80, 24) {
		t.Fatal("initial resize should be sent")
	}
	if state.shouldSend(80, 24) {
		t.Fatal("unchanged resize should be skipped")
	}
	if !state.shouldSend(81, 24) {
		t.Fatal("changed resize should be sent")
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
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
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
	trimmedReplay := strings.TrimSuffix(
		string(replay),
		cursorVisibilityReplaySequence(true),
	)
	trimmedReplay = strings.TrimSuffix(trimmedReplay, postHistoryReplayResetSequence)
	if !strings.HasSuffix(trimmedReplay, "suffix") {
		t.Fatalf("replay did not preserve recent output suffix")
	}
}

func TestReplayStripsTerminalResponseQueries(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:    "@1",
		index: 0,
		history: []byte(
			"before" +
				"\x1b[c" +
				"\x1b[>0c" +
				"\x1b[6n" +
				"\x1b[?996n" +
				"\x1b[14t" +
				"\x1b[16t" +
				"\x1b[22;2t" +
				"\x1b[?1049h" +
				"\x1b[?1049l" +
				"\x1b[?2026h" +
				"\x1b[?2026l" +
				"\x1b[?2026$p" +
				"\x1b[?2027$p" +
				"\x1b[1;2r" +
				"\x1b]11;?\x07" +
				"\x1b]2;Gemini\x07" +
				"after",
		),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		window,
	}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())
	historyReplay := strings.TrimPrefix(replay, replayPrefixForTest(window))
	historyReplay = strings.TrimSuffix(
		historyReplay,
		cursorVisibilityReplaySequence(true),
	)
	historyReplay = strings.TrimSuffix(historyReplay, postHistoryReplayResetSequence)

	for _, stripped := range []string{
		"\x1b[c",
		"\x1b[>0c",
		"\x1b[6n",
		"\x1b[?996n",
		"\x1b[14t",
		"\x1b[16t",
		"\x1b[22;2t",
		"\x1b[?1049h",
		"\x1b[?1049l",
		"\x1b[?2026h",
		"\x1b[?2026l",
		"\x1b[?2026$p",
		"\x1b[?2027$p",
		"\x1b[1;2r",
		"\x1b]11;?\x07",
	} {
		if strings.Contains(historyReplay, stripped) {
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

	server.handleWindowOutput("@1", []byte("live\x1b[c\x1b[14t\x1b[?2026$p\x1b]11;?\x07query"))

	if got := attach.String(); got != "live\x1b[c\x1b[14t\x1b[?2026$p\x1b]11;?\x07query" {
		t.Fatalf("active attach output = %q, want unmodified live query", got)
	}
}

func TestActiveOutputFiltersNestedAlternateBufferModes(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput(
		"@1",
		[]byte("before\x1b[?1049hinside\x1b[?1049lafter"),
	)

	want := "before" + nestedAlternateBufferTransitionSequence + "inside" +
		nestedAlternateBufferTransitionSequence + "after"
	if got := attach.String(); got != want {
		t.Fatalf("active attach output = %q, want %q", got, want)
	}
	if got := string(window.history); got != "before\x1b[?1049hinside\x1b[?1049lafter" {
		t.Fatalf("history = %q, want raw PTY bytes", got)
	}
	if got := string(window.replayHistory); got != want {
		t.Fatalf("replay history = %q, want attach-visible bytes %q", got, want)
	}
}

func TestCodexActiveOutputStripsNestedAlternateBufferModes(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		agentTool:    "codex",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	chunk := []byte("before\x1b[?1049;2004hinside")
	server.handleWindowOutput("@1", chunk)

	want := codexVisibleRedrawSequence + "before\x1b[?2004hinside"
	if got := attach.String(); got != want {
		t.Fatalf("active attach output = %q, want nested Codex alt-buffer stripped to %q", got, want)
	}
	if got := string(window.history); got != string(chunk) {
		t.Fatalf("history = %q, want raw PTY bytes", got)
	}
	if got := string(window.replayHistory); got != "" {
		t.Fatalf("replay history = %q, want redraw-only replay after Codex enters alt buffer", got)
	}
}

func TestAgentToolFromShellCommandArgsDetectsCodex(t *testing.T) {
	args := []string{
		"/bin/zsh",
		"-lc",
		"cd /tmp/proof && HOME=/Users/example codex resume abc123",
	}

	if got := agentToolFromCommandArgs(args); got != "codex" {
		t.Fatalf("agentToolFromCommandArgs() = %q, want codex", got)
	}
}

func TestAgentToolFromTitleDetectsOpenAICodex(t *testing.T) {
	if got := agentToolFromTerminalTitle("OpenAI Codex (v0.130.0)"); got != "codex" {
		t.Fatalf("agentToolFromTerminalTitle() = %q, want codex", got)
	}
}

func TestActiveOutputPreservesStandaloneCursorSaveRestoreMode(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{id: "@1", index: 0, lastActivity: time.Now()}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("before\x1b[?1048hinside\x1b[?1048lafter"))

	want := "before\x1b[?1048hinside\x1b[?1048lafter"
	if got := attach.String(); got != want {
		t.Fatalf("active attach output = %q, want %q", got, want)
	}
	if got := string(window.replayHistory); got != want {
		t.Fatalf("replay history = %q, want %q", got, want)
	}
}

func TestInactiveAgentOutputDoesNotReplaceVisibleReplayHistory(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	agentWindow := &muxWindow{
		id:            "@2",
		index:         1,
		agentTool:     "codex",
		replayHistory: []byte("visible codex screen"),
		// Treat this window as an alt-buffer agent so the replay still
		// follows the clear+redraw path; the inline-viewport case is
		// covered by TestInlineViewportAgentReplaysHistoryForScrollback.
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		agentWindow,
	}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput(
		"@2",
		[]byte("\x1b[2;1H\x1b[K\x1b[3;1H\x1b[K"),
	)

	if got := string(agentWindow.history); got == "" {
		t.Fatal("raw inactive agent output was not retained in history")
	}
	if got := string(agentWindow.replayHistory); got != "visible codex screen" {
		t.Fatalf("replay history = %q, want last attached screen", got)
	}
	if got := string(agentWindow.pendingReplayControls); got != "" {
		t.Fatalf("pending replay controls = %q, want empty", got)
	}

	if err := server.selectWindow("@2", terminalResizeRequest{}); err != nil {
		t.Fatal(err)
	}

	want := replayPrefixForTest(agentWindow) +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
}

func TestInactiveAgentVisibleOutputDoesNotBuildReplayFrame(t *testing.T) {
	server := newMuxServer("test")
	agentWindow := &muxWindow{
		id:            "@2",
		index:         1,
		agentTool:     "codex",
		replayHistory: []byte("old visible screen"),
		// Alt-buffer agents (claude-code, opencode, gemini, Codex's
		// transcript overlay) keep their replay frame frozen so reattach
		// just nudges the agent to redraw via SIGWINCH instead of replaying
		// cursor-addressed bytes that would crash xterm.dart.
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		agentWindow,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("\x1b[2;1H\x1b[K"))
	server.handleWindowOutput("@2", []byte("\x1b[2;1Hnew codex screen"))

	want := "old visible screen"
	if got := string(agentWindow.replayHistory); got != want {
		t.Fatalf("replay history = %q, want %q", got, want)
	}
	if got := string(agentWindow.pendingReplayControls); got != "" {
		t.Fatalf("pending replay controls = %q, want empty", got)
	}
}

// TestCodexAgentReplaysMainBufferHistoryAndNudgesRedraw asserts that Codex
// keeps main-buffer history replay for scrollback while also getting a redraw
// nudge so its cursor-addressed viewport is repainted after replay.
func TestCodexAgentReplaysMainBufferHistoryAndNudgesRedraw(t *testing.T) {
	server := newMuxServer("test")
	codexWindow := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Codex",
		agentTool:    "codex",
		history:      []byte("first turn\nsecond turn\nthird turn\n> prompt"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{codexWindow}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	for _, marker := range []string{"first turn", "second turn", "third turn", "> prompt"} {
		if !strings.Contains(replay, marker) {
			t.Fatalf("replay = %q, want Codex history marker %q for scrollback", replay, marker)
		}
	}
	promptIndex := strings.Index(replay, "> prompt")
	visibleClearIndex := strings.LastIndex(
		replay,
		postHistoryVisibleScreenClearSequence,
	)
	if visibleClearIndex < 0 {
		t.Fatalf("replay = %q, want visible-screen clear before Codex redraw", replay)
	}
	if visibleClearIndex < promptIndex {
		t.Fatalf(
			"replay = %q, visible-screen clear must happen after history replay",
			replay,
		)
	}
	if !strings.Contains(replay, "\x1b[3J") {
		t.Fatalf("replay = %q, should clear stale local scrollback before Codex history replay", replay)
	}
	if !strings.Contains(replay, attachSessionExitSequence) {
		t.Fatalf("replay = %q, should leave attach-owned alt buffer for Codex main-buffer scrollback", replay)
	}
	redrawEnterIndex := strings.LastIndex(replay, attachSessionEnterSequence)
	if redrawEnterIndex < 0 {
		t.Fatalf("replay = %q, should enter attach-owned alt buffer before Codex redraw", replay)
	}
	if redrawEnterIndex < promptIndex {
		t.Fatalf(
			"replay = %q, attach-owned alt buffer should be re-entered after history replay",
			replay,
		)
	}
	if server.activeRedrawWindowLocked() != codexWindow {
		t.Fatal("Codex window should be nudged to redraw after replay")
	}
	redrawNudge := server.activeRedrawNudgeLocked()
	if redrawNudge.window != codexWindow {
		t.Fatalf("Codex redraw nudge window = %#v, want Codex window", redrawNudge.window)
	}
	if !redrawNudge.sameSize {
		t.Fatal("Codex redraw nudge should use same-size WINCH instead of a transient PTY resize")
	}
}

func TestRedrawActiveClearsCodexInlineViewportBeforeNudge(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "Codex",
		agentTool:    "codex",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach
	server.width = 100
	server.height = 32

	originalNudgeForegroundSameSize := nudgeForegroundSameSize
	defer func() {
		nudgeForegroundSameSize = originalNudgeForegroundSameSize
	}()
	var nudged *muxWindow
	nudgeForegroundSameSize = func(window *muxWindow, width int, height int) {
		nudged = window
	}

	server.redrawActive()

	if got := attach.String(); got != codexVisibleRedrawSequence {
		t.Fatalf("attach output = %q, want Codex visible redraw invalidation", got)
	}
	if nudged != window {
		t.Fatalf("redraw nudge window = %#v, want Codex window", nudged)
	}
}

func TestThemeHintClearsCodexInlineViewportBeforeFocusNudge(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	window := &muxWindow{
		id:               "@1",
		index:            0,
		name:             "Codex",
		agentTool:        "codex",
		focusModeEnabled: true,
		pty:              slave,
		lastActivity:     time.Now(),
	}
	t.Cleanup(func() {
		_ = master.Close()
		_ = window.closePty()
	})
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	if !server.sendThemeHint("\x1b[I") {
		t.Fatal("sendThemeHint returned false, want true")
	}
	if got := attach.String(); got != codexVisibleRedrawSequence {
		t.Fatalf("attach output = %q, want Codex visible redraw invalidation before focus nudge", got)
	}
}

func TestNewInlineWindowClearsPreviousLocalScrollback(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@2",
		index:        1,
		name:         "Copilot CLI",
		agentTool:    "copilot",
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, history: []byte("previous window"), lastActivity: time.Now()},
		window,
	}
	server.activeID = "@2"

	replay := string(server.activeReplayLocked())

	if strings.Contains(replay, "previous window") {
		t.Fatalf("replay = %q, should not include prior window history", replay)
	}
	if !strings.Contains(replay, "\x1b[3J") {
		t.Fatalf("replay = %q, want scrollback clear even when new inline window has no history yet", replay)
	}
	if !strings.HasPrefix(replay, attachSessionExitSequence) {
		t.Fatalf("replay = %q, want inline replay to leave attach-owned alt buffer", replay)
	}
}

// TestAltBufferAgentSkipsHistoryAndClearsScrollback asserts that an agent
// known to own the outer alt buffer (e.g. claude-code) still falls back to
// the clear+redraw path on reattach, leaving xterm.dart's circular buffer
// untouched.
func TestAltBufferAgentSkipsHistoryAndClearsScrollback(t *testing.T) {
	server := newMuxServer("test")
	altAgentWindow := &muxWindow{
		id:           "@1",
		index:        0,
		name:         "claude",
		agentTool:    "claude-code",
		history:      []byte("\x1b[1;1Hframe1\x1b[2;1Hframe2"),
		privateModes: map[string]bool{"1049": true},
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{altAgentWindow}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	if !strings.Contains(replay, "\x1b[3J") {
		t.Fatalf("replay = %q, want ED-3 scrollback clear for alt-buffer agent", replay)
	}
	if strings.Contains(replay, "frame1") || strings.Contains(replay, "frame2") {
		t.Fatalf("replay = %q, history must be skipped for alt-buffer agent", replay)
	}
	if strings.Contains(replay, attachSessionExitSequence) {
		t.Fatalf("replay = %q, alt-buffer agent must stay in attach-owned alt buffer", replay)
	}
	if !strings.Contains(replay, attachSessionEnterSequence) {
		t.Fatalf("replay = %q, alt-buffer agent must enter attach-owned alt buffer", replay)
	}
}

func TestInactiveReplayCaptureUsesSeparatePartialBuffer(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@2",
		index:         1,
		replayHistory: []byte("screen"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
		window,
	}
	server.activeID = "@1"

	server.handleWindowOutput("@2", []byte("before\x1b[31"))

	if got := string(window.attachOutputBuffer); got != "" {
		t.Fatalf("live attach partial buffer = %q, want empty", got)
	}
	if got := string(window.replayCaptureBuffer); got != "\x1b[31" {
		t.Fatalf("replay partial buffer = %q, want split CSI suffix", got)
	}
	if got := string(window.attachOutputForClientLocked([]byte("live"))); got != "live" {
		t.Fatalf("live attach output = %q, want no replay partial prefix", got)
	}

	server.handleWindowOutput("@2", []byte("mafter"))

	want := "screenbefore\x1b[31mafter"
	if got := string(window.replayHistory); got != want {
		t.Fatalf("replay history = %q, want %q", got, want)
	}
}

func TestActiveControlOnlyOutputDoesNotReplaceVisibleReplayHistory(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:            "@1",
		index:         0,
		replayHistory: []byte("visible screen"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("\x1b[2;1H\x1b[K\x1b[3;1H\x1b[K"))

	if got := string(window.history); got == "" {
		t.Fatal("raw control-only output was not retained in history")
	}
	if got := string(window.replayHistory); got != "visible screen" {
		t.Fatalf("replay history = %q, want last visible screen", got)
	}
	if got := string(window.pendingReplayControls); got != "\x1b[2;1H\x1b[K\x1b[3;1H\x1b[K" {
		t.Fatalf("pending replay controls = %q, want control-only frame", got)
	}
	if got := attach.String(); got == "" {
		t.Fatal("active control-only output was not passed through to attach")
	}
}

func TestActiveReplayIncludesPendingControlOnlyOutput(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@1",
		index:         0,
		replayHistory: []byte("visible screen"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("\x1b[2;1H\x1b[48;5;250m\x1b[K"))

	if got := string(window.replayHistory); got != "visible screen" {
		t.Fatalf("replay history = %q, want last visible screen", got)
	}
	if got := string(window.pendingReplayControls); got != "\x1b[2;1H\x1b[48;5;250m\x1b[K" {
		t.Fatalf("pending replay controls = %q, want composer background redraw", got)
	}
	replay := string(server.activeReplayLocked())
	if !strings.Contains(replay, "visible screen\x1b[2;1H\x1b[48;5;250m\x1b[K") {
		t.Fatalf("replay = %q, want pending composer background controls included", replay)
	}
}

func TestCodexSynchronizedCursorFrameDoesNotBuildReplayHistory(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:            "@1",
		index:         0,
		agentTool:     "codex",
		replayHistory: []byte("prompt\n"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput(
		"@1",
		[]byte(
			"assistant line\n"+
				"\x1b[?2026h"+
				"\x1b[23;1H\x1b[Kstale status"+
				"\x1b[24;1H> stale composer"+
				"\x1b[?2026l",
		),
	)

	if got := attach.String(); !strings.Contains(got, "stale status") {
		t.Fatalf("live attach output = %q, want synchronized frame passed through", got)
	}
	if got := string(window.replayHistory); strings.Contains(got, "stale") {
		t.Fatalf("replay history = %q, want cursor-addressed synchronized frame omitted", got)
	}
	if got := string(window.replayHistory); !strings.Contains(got, "assistant line") {
		t.Fatalf("replay history = %q, want non-frame output preserved", got)
	}
	if got := string(window.replaySyncOutputBuffer); got != "" {
		t.Fatalf("sync replay buffer = %q, want empty after complete frame", got)
	}
}

func TestCodexSynchronizedReplayFilterBuffersSplitFrame(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@1",
		index:         0,
		agentTool:     "codex",
		replayHistory: []byte("prompt\n"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput(
		"@1",
		[]byte("\x1b[?2026h\x1b[23;1Hpartial status"),
	)

	if got := string(window.replayHistory); strings.Contains(got, "partial status") {
		t.Fatalf("replay history = %q, want split synchronized frame buffered", got)
	}
	if got := string(window.replaySyncOutputBuffer); !strings.Contains(got, "partial status") {
		t.Fatalf("sync replay buffer = %q, want partial frame held", got)
	}

	server.handleWindowOutput("@1", []byte("\x1b[?2026lafter\n"))

	if got := string(window.replayHistory); strings.Contains(got, "partial status") {
		t.Fatalf("replay history = %q, want completed cursor frame omitted", got)
	}
	if got := string(window.replayHistory); !strings.Contains(got, "after\n") {
		t.Fatalf("replay history = %q, want post-frame output preserved", got)
	}
	if got := string(window.replaySyncOutputBuffer); got != "" {
		t.Fatalf("sync replay buffer = %q, want empty after frame close", got)
	}
}

func TestCodexSynchronizedLinearOutputStillBuildsReplayHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:            "@1",
		index:         0,
		agentTool:     "codex",
		replayHistory: []byte("prompt\n"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	server.handleWindowOutput("@1", []byte("\x1b[?2026hlinear output\n\x1b[?2026l"))

	if got := string(window.replayHistory); !strings.Contains(got, "linear output\n") {
		t.Fatalf("replay history = %q, want linear synchronized output preserved", got)
	}
	if got := string(window.replayHistory); strings.Contains(got, "\x1b[?2026") {
		t.Fatalf("replay history = %q, want synchronized-output controls stripped", got)
	}
}

func TestControlOnlyOutputIsCapturedWhenVisibleTextFollows(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	window := &muxWindow{
		id:            "@1",
		index:         0,
		replayHistory: []byte("visible screen"),
		lastActivity:  time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("\x1b[2;1H\x1b[K"))
	server.handleWindowOutput("@1", []byte("\x1b[2;1Hnew visible text"))

	want := "visible screen\x1b[2;1H\x1b[K\x1b[2;1Hnew visible text"
	if got := string(window.replayHistory); got != want {
		t.Fatalf("replay history = %q, want %q", got, want)
	}
	if got := string(window.pendingReplayControls); got != "" {
		t.Fatalf("pending replay controls = %q, want empty", got)
	}
}

func TestActiveOutputFiltersSplitNestedAlternateBufferMode(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("before\x1b[?10"))
	server.handleWindowOutput("@1", []byte("49hafter"))

	want := "before" + nestedAlternateBufferTransitionSequence + "after"
	if got := attach.String(); got != want {
		t.Fatalf("active attach output = %q, want %q", got, want)
	}
}

func TestActiveOutputPreservesModesGroupedWithNestedAlternateBuffer(t *testing.T) {
	server := newMuxServer("test")
	attach := &recordingConn{}
	server.windows = []*muxWindow{
		{id: "@1", index: 0, lastActivity: time.Now()},
	}
	server.activeID = "@1"
	server.attachConn = attach

	server.handleWindowOutput("@1", []byte("\x1b[?1049;25;2004h"))

	want := nestedAlternateBufferTransitionSequence + "\x1b[?25;2004h"
	if got := attach.String(); got != want {
		t.Fatalf("active attach output = %q, want %q", got, want)
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
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
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
		"\x1b[?1007l",
		"\x1b[?1004l",
		"\x1b[?2004l",
		"\x1b[?2026l",
		"\x1b[?2027l",
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

func TestAttachSessionOwnsOuterAlternateBuffer(t *testing.T) {
	if attachSessionEnterSequence != "\x1b[?1049h" {
		t.Fatalf("attach enter sequence = %q, want outer alternate buffer enter", attachSessionEnterSequence)
	}
	if attachSessionExitSequence != "\x1b[?1049l" {
		t.Fatalf("attach exit sequence = %q, want outer alternate buffer leave", attachSessionExitSequence)
	}
	if strings.Contains(activeWindowReplayPrefix, "\x1b[?1049") {
		t.Fatalf("replay prefix %q should not toggle the attach-owned alternate buffer", activeWindowReplayPrefix)
	}
}

func TestTrackedAlternateBufferReplayReentersOuterAlternateBuffer(t *testing.T) {
	window := &muxWindow{id: "@1", lastActivity: time.Now()}
	window.observeTerminalModesLocked([]byte("\x1b[?1049h"))

	replayPrefix := replayPrefixForTest(window)

	if !strings.Contains(replayPrefix, attachSessionEnterSequence) {
		t.Fatalf("tracked alt replay prefix %q should re-enter the attach-owned alternate buffer", replayPrefix)
	}
	if strings.Contains(replayPrefix, attachSessionExitSequence) {
		t.Fatalf("tracked alt replay prefix %q should not leave the attach-owned alternate buffer", replayPrefix)
	}
}

func TestActiveReplayEndsBufferedModesAfterHistory(t *testing.T) {
	server := newMuxServer("test")
	window := &muxWindow{
		id:           "@1",
		index:        0,
		history:      []byte("prompt\x1b[?2026h\x1b[?2027hbuffered tui frame"),
		lastActivity: time.Now(),
	}
	server.windows = []*muxWindow{window}
	server.activeID = "@1"

	replay := string(server.activeReplayLocked())

	want := replayPrefixForTest(window) + "prompt\x1b[?2027hbuffered tui frame" +
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
	if strings.Contains(replay, "\x1b[?2026h") {
		t.Fatalf("replay = %q, want synchronized-output enable stripped from replayed history", replay)
	}
	for _, sequence := range []string{
		synchronizedOutputResetSequence,
		graphemeClusterResetSequence,
	} {
		if lastReset := strings.LastIndex(replay, sequence); lastReset < strings.LastIndex(replay, "buffered tui frame") {
			t.Fatalf("replay = %q, want reset %q after history", replay, sequence)
		}
	}
}

func TestReplayPrefixClearsScrollbackAndMargins(t *testing.T) {
	for _, sequence := range []string{"\x1b[r", "\x1b[2J", "\x1b[3J", "\x0f", "\x1b(B", "\x1b)B"} {
		if !strings.Contains(activeWindowReplayPrefix, sequence) {
			t.Fatalf("replay prefix %q does not include %q", activeWindowReplayPrefix, sequence)
		}
	}
}

func TestNestedAlternateBufferRewriteResetsCharsets(t *testing.T) {
	if !strings.HasPrefix(nestedAlternateBufferTransitionSequence, terminalCharsetResetSequence) {
		t.Fatalf(
			"nested alternate buffer rewrite = %q, want charset reset prefix %q",
			nestedAlternateBufferTransitionSequence,
			terminalCharsetResetSequence,
		)
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
	postModes := string(terminalModePostReplaySequence(window))
	want := replayPrefixForTest(window) + preModes +
		postHistoryReplayResetSequence + postModes +
		cursorVisibilityReplaySequence(true)
	if replay != want {
		t.Fatalf("replay = %q, want %q", replay, want)
	}
	if !strings.Contains(replayPrefixForTest(window), attachSessionEnterSequence) {
		t.Fatalf("replay prefix for tracked alt window = %q, should re-enter outer alt buffer", replayPrefixForTest(window))
	}
	if strings.Contains(replayPrefixForTest(window), attachSessionExitSequence) {
		t.Fatalf("replay prefix for tracked alt window = %q, should not leave outer alt buffer", replayPrefixForTest(window))
	}
	for _, sequence := range []string{
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
	if strings.Contains(preModes, "\x1b[?1049") {
		t.Fatalf("pre-history modes = %q, should leave outer alt buffer ownership to replay prefix", preModes)
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
		"stale\x1b[4h"+postHistoryReplayResetSequence+postModes+
			cursorVisibilityReplaySequence(true),
	) {
		t.Fatalf("replay did not restore reset modes after history")
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
	}

	for _, tt := range tests {
		if got := agentSessionIDFromArgs(tt.tool, tt.args); got != tt.want {
			t.Fatalf("agentSessionIDFromArgs(%q, %q) = %q, want %q", tt.tool, tt.args, got, tt.want)
		}
	}
}

func TestLatestCodexSessionIDFromHistoryFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "history.jsonl")
	history := strings.Join([]string{
		`{"session_id":"older","ts":1,"text":"one"}`,
		`not json`,
		`{"session_id":"newer","ts":2,"text":"two"}`,
		``,
	}, "\n")
	if err := os.WriteFile(path, []byte(history), 0o600); err != nil {
		t.Fatal(err)
	}

	if got := latestCodexSessionIDFromHistoryFile(path); got != "newer" {
		t.Fatalf("latestCodexSessionIDFromHistoryFile() = %q, want newer", got)
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
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
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
		postHistoryReplayResetSequence + cursorVisibilityReplaySequence(true)
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
				Cwd:            "/tmp/project with space",
				CurrentCommand: "copilot",
				AgentTool:      "copilot",
				AgentSessionID: "session-123",
			},
			want:      "copilot --yolo --add-dir '/tmp/project with space' --resume 'session-123'",
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

func TestThemeHintOnlyTargetsFocusAwareAgentWindows(t *testing.T) {
	agentWindow := &muxWindow{foregroundCommand: "codex"}
	agentWindow.observeTerminalModesLocked([]byte("\x1b[?1004h"))
	agentWithoutFocus := &muxWindow{foregroundCommand: "gemini"}
	shellWindow := &muxWindow{foregroundCommand: "zsh"}
	shellWindow.observeTerminalModesLocked([]byte("\x1b[?1004h"))

	if !agentWindow.supportsThemeHintLocked() {
		t.Fatal("focus-aware agent foreground window did not support theme hints")
	}
	if agentWithoutFocus.supportsThemeHintLocked() {
		t.Fatal("agent foreground window without focus mode supported theme hints")
	}
	if shellWindow.supportsThemeHintLocked() {
		t.Fatal("focus-aware shell foreground window unexpectedly supported theme hints")
	}

	agentWindow.observeTerminalModesLocked([]byte("\x1b[?1004l"))
	if agentWindow.supportsThemeHintLocked() {
		t.Fatal("agent foreground window supported theme hints after focus mode disabled")
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
