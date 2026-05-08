package main

import (
	"bytes"
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
)

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

func TestShellCommandUsesPlainShell(t *testing.T) {
	cmd := shellCommand("/bin/zsh")

	if got := cmd.Args[0]; got != "/bin/zsh" {
		t.Fatalf("argv0 = %q, want plain shell argv0", got)
	}
}

func TestDefaultShellPathFallsBackToSh(t *testing.T) {
	t.Setenv("SHELL", "")

	if got := defaultShellPath(); got != "/bin/sh" {
		t.Fatalf("default shell path = %q, want /bin/sh", got)
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
	if !inactiveWindow.alert {
		t.Fatal("inactive output did not mark the window alert")
	}

	if err := server.selectWindow("@2"); err != nil {
		t.Fatal(err)
	}

	want := activeWindowReplayPrefix + "background output"
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
	if inactiveWindow.alert {
		t.Fatal("selected window alert was not cleared")
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

	want := activeWindowReplayPrefix + "previous screen"
	if got := attach.String(); got != want {
		t.Fatalf("attach output = %q, want %q", got, want)
	}
}

func TestWindowHistoryTrimsToLimit(t *testing.T) {
	window := &muxWindow{}

	window.appendHistoryLocked(bytes.Repeat([]byte("a"), windowHistoryLimitBytes-2))
	window.appendHistoryLocked([]byte("bcdef"))

	if got := len(window.history); got != windowHistoryLimitBytes {
		t.Fatalf("history length = %d, want %d", got, windowHistoryLimitBytes)
	}
	if got := string(window.history[len(window.history)-5:]); got != "bcdef" {
		t.Fatalf("history suffix = %q, want bcdef", got)
	}
}

func TestWindowMetadataTracksOscTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("\x1b]2;Claude Code · flutty\x1b\\"))

	if window.name != "Claude Code · flutty" {
		t.Fatalf("name = %q, want OSC title", window.name)
	}
	if window.paneTitle != "Claude Code · flutty" {
		t.Fatalf("pane title = %q, want OSC title", window.paneTitle)
	}
}

func TestWindowMetadataTracksSplitOscTitle(t *testing.T) {
	window := &muxWindow{name: "zsh", paneTitle: "zsh"}

	window.observeTerminalMetadataLocked([]byte("prefix\x1b]0;Copilot"))
	window.observeTerminalMetadataLocked([]byte(" CLI\aafter"))

	if window.name != "Copilot CLI" {
		t.Fatalf("name = %q, want split OSC title", window.name)
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

func TestReplayPrefixDoesNotForceCursorVisible(t *testing.T) {
	if strings.Contains(activeWindowReplayPrefix, "?25h") {
		t.Fatalf("replay prefix forces cursor visible: %q", activeWindowReplayPrefix)
	}
}

func TestWindowProcessIDReportsShellPid(t *testing.T) {
	window := &muxWindow{cmd: &exec.Cmd{Process: &os.Process{Pid: 12345}}}

	if got := window.processID(); got != 12345 {
		t.Fatalf("processID = %d, want 12345", got)
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

func TestPromptForServerUpdateDescribesSafeShutdown(t *testing.T) {
	var output bytes.Buffer
	status := runningServerStatus{
		version:      "0.1.1",
		capabilities: []string{"shutdown"},
	}

	if !promptForServerUpdate(strings.NewReader("y\n"), &output, "main", status) {
		t.Fatal("yes prompt response did not update server")
	}
	if got := output.String(); !strings.Contains(got, "will close existing") {
		t.Fatalf("prompt output = %q, want close warning", got)
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

func (errReader) Read([]byte) (int, error) {
	return 0, io.ErrUnexpectedEOF
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
