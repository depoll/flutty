package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/term"
)

const (
	monkeyMuxVersion        = "0.1.3"
	defaultColumns          = 80
	defaultRows             = 24
	maxTitleBytes           = 160
	oscBufferLimitBytes     = 4096
	runCommandTimeout       = 8 * time.Second
	socketTimeout           = 2 * time.Second
	windowHistoryLimitBytes = 1024 * 1024
)

const activeWindowReplayPrefix = "\x1b[?1049l\x1b[0m\x1b[H\x1b[2J"

var capabilities = []string{
	"attach",
	"control-json-v1",
	"direct-pass-through",
	"posix-pty",
	"window-list",
	"window-create",
	"window-select",
	"window-close",
	"active-context",
	"inject-input",
	"run-command",
	"focus-hint",
	"shutdown",
}

type controlMessage struct {
	Role        string   `json:"role,omitempty"`
	ID          string   `json:"id,omitempty"`
	Type        string   `json:"type,omitempty"`
	Session     string   `json:"session,omitempty"`
	WindowID    string   `json:"windowId,omitempty"`
	WindowIndex *int     `json:"windowIndex,omitempty"`
	Name        string   `json:"name,omitempty"`
	Cwd         string   `json:"cwd,omitempty"`
	Command     string   `json:"command,omitempty"`
	Args        []string `json:"args,omitempty"`
	Data        string   `json:"data,omitempty"`
	Width       int      `json:"width,omitempty"`
	Height      int      `json:"height,omitempty"`
	PixelWidth  int      `json:"pixelWidth,omitempty"`
	PixelHeight int      `json:"pixelHeight,omitempty"`
}

type controlResponse struct {
	ID             string           `json:"id,omitempty"`
	Type           string           `json:"type"`
	Status         string           `json:"status,omitempty"`
	Error          string           `json:"error,omitempty"`
	Version        string           `json:"version,omitempty"`
	Session        string           `json:"session,omitempty"`
	Capabilities   []string         `json:"capabilities,omitempty"`
	Windows        []windowSnapshot `json:"windows,omitempty"`
	Window         *windowSnapshot  `json:"window,omitempty"`
	CurrentPath    string           `json:"currentPath,omitempty"`
	CurrentCommand string           `json:"currentCommand,omitempty"`
	Data           string           `json:"data,omitempty"`
	ExitCode       int              `json:"exitCode,omitempty"`
}

type windowSnapshot struct {
	ID                       string `json:"id"`
	Index                    int    `json:"index"`
	Name                     string `json:"name"`
	Active                   bool   `json:"active"`
	CurrentCommand           string `json:"currentCommand,omitempty"`
	CurrentPath              string `json:"currentPath,omitempty"`
	PanePid                  int    `json:"panePid,omitempty"`
	Flags                    string `json:"flags,omitempty"`
	PaneTitle                string `json:"paneTitle,omitempty"`
	LastActivityEpochSeconds int64  `json:"lastActivityEpochSeconds,omitempty"`
}

type muxServer struct {
	session string
	width   int
	height  int

	mu         sync.Mutex
	windows    []*muxWindow
	activeID   string
	nextID     int
	listener   net.Listener
	attachConn net.Conn
	attachMu   sync.Mutex
	controls   map[*controlClient]struct{}
	closed     bool
}

type muxWindow struct {
	id           string
	index        int
	name         string
	cwd          string
	command      string
	paneTitle    string
	pty          *os.File
	cmd          *exec.Cmd
	history      []byte
	oscBuffer    []byte
	lastActivity time.Time
	alert        bool
	closed       bool
}

type controlClient struct {
	conn net.Conn
	enc  *json.Encoder
	mu   sync.Mutex
}

func main() {
	if len(os.Args) < 2 {
		usageAndExit()
	}

	switch os.Args[1] {
	case "attach":
		attachCommand(os.Args[2:])
	case "control":
		controlCommand(os.Args[2:])
	case "serve":
		serveCommand(os.Args[2:])
	case "gc":
		gcCommand()
	case "version", "--version", "-v":
		fmt.Println(monkeyMuxVersion)
	default:
		usageAndExit()
	}
}

func usageAndExit() {
	fmt.Fprintln(os.Stderr, "usage: monkeymux attach <session> | control <session> --json | gc | version")
	os.Exit(2)
}

func attachCommand(args []string) {
	fs := flag.NewFlagSet("attach", flag.ExitOnError)
	cwd := fs.String("cwd", "", "initial working directory")
	_ = fs.Parse(args)
	if fs.NArg() != 1 {
		usageAndExit()
	}
	session := fs.Arg(0)
	if err := ensureServer(session, *cwd); err != nil {
		fatal(err)
	}

	conn, err := dialSession(session)
	if err != nil {
		fatal(err)
	}
	defer conn.Close()

	width, height := terminalSize()
	hello := controlMessage{
		Role:    "attach",
		Session: session,
		Width:   width,
		Height:  height,
	}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	restoreTerminal := makeTerminalRaw()
	defer restoreTerminal()

	stopResize := forwardResizeSignals(session)
	defer stopResize()

	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
}

func controlCommand(args []string) {
	fs := flag.NewFlagSet("control", flag.ExitOnError)
	jsonMode := fs.Bool("json", false, "use newline-delimited JSON")
	_ = fs.String("cwd", "", "ignored; only attach starts sessions")
	_ = fs.Parse(args)
	if fs.NArg() != 1 || !*jsonMode {
		usageAndExit()
	}
	session := fs.Arg(0)

	conn, err := dialSession(session)
	if err != nil {
		fatal(fmt.Errorf("monkeymux session %q is not running; attach before opening control", session))
	}
	defer conn.Close()

	hello := controlMessage{Role: "control", Session: session}
	if err := json.NewEncoder(conn).Encode(hello); err != nil {
		fatal(err)
	}

	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(os.Stdout, conn)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(conn, os.Stdin)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, io.EOF) {
		fatal(err)
	}
}

func serveCommand(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	session := fs.String("session", "", "session name")
	cwd := fs.String("cwd", "", "initial working directory")
	_ = fs.Parse(args)
	if strings.TrimSpace(*session) == "" {
		usageAndExit()
	}
	if err := serveSession(*session, *cwd); err != nil {
		fatal(err)
	}
}

func gcCommand() {
	runDir, err := runtimeDirectory()
	if err != nil {
		fatal(err)
	}
	entries, err := os.ReadDir(runDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return
		}
		fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "monkeymux-") {
			continue
		}
		path := filepath.Join(runDir, entry.Name())
		conn, err := net.DialTimeout("unix", path, 150*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			continue
		}
		_ = os.Remove(path)
	}
}

func ensureServer(session string, cwd string) error {
	if status, err := queryRunningServerStatus(session); err == nil {
		if status.version == monkeyMuxVersion {
			return nil
		}
		if !promptForServerUpdate(os.Stdin, os.Stderr, session, status) {
			return nil
		}
		if status.supportsCapability("shutdown") {
			requestServerShutdown(session)
			if !waitForServerExit(session, 2*time.Second) {
				fmt.Fprintf(
					os.Stderr,
					"monkeymux: running session did not exit; continuing with helper %s\r\n",
					status.displayVersion(),
				)
				return nil
			}
		} else {
			fmt.Fprintf(
				os.Stderr,
				"monkeymux: abandoning helper %s socket and starting helper %s\r\n",
				status.displayVersion(),
				monkeyMuxVersion,
			)
		}
	}

	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	_ = os.Remove(socket)

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(exe, "serve", "--session", session)
	if strings.TrimSpace(cwd) != "" {
		cmd.Args = append(cmd.Args, "--cwd", cwd)
	}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Env = inheritedEnvironment(os.Environ())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	_ = cmd.Process.Release()

	deadline := time.Now().Add(socketTimeout)
	for time.Now().Before(deadline) {
		conn, err := dialSession(session)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("monkeymux server did not start for session %q", session)
}

func serveSession(session string, cwd string) error {
	socket, err := socketPath(session)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return err
	}
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(socket)
	}()
	_ = os.Chmod(socket, 0o600)

	server := newMuxServer(session)
	server.listener = listener
	if _, err := server.createWindow(createWindowOptions{cwd: cwd}); err != nil {
		return err
	}
	defer server.close()

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	go func() {
		<-signals
		server.close()
		_ = listener.Close()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if server.isClosed() {
				return nil
			}
			return err
		}
		go server.handleConnection(conn)
	}
}

func newMuxServer(session string) *muxServer {
	return &muxServer{
		session:  session,
		width:    defaultColumns,
		height:   defaultRows,
		controls: map[*controlClient]struct{}{},
	}
}

type createWindowOptions struct {
	name    string
	cwd     string
	command string
	args    []string
}

func (s *muxServer) createWindow(options createWindowOptions) (*muxWindow, error) {
	cwd := strings.TrimSpace(options.cwd)
	if cwd == "" {
		if current, err := os.Getwd(); err == nil {
			cwd = current
		}
	} else if expanded, err := expandHomePath(cwd); err == nil {
		cwd = expanded
	}

	shell := defaultShellPath()
	cmd := shellCommand(shell)
	name := filepath.Base(shell)
	if len(options.args) > 0 {
		cmd = exec.Command(options.args[0], options.args[1:]...)
		name = filepath.Base(options.args[0])
	}
	if strings.TrimSpace(options.name) != "" {
		name = strings.TrimSpace(options.name)
	} else if strings.TrimSpace(options.command) != "" {
		name = firstShellWord(options.command)
	}
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = inheritedEnvironment(os.Environ())

	s.mu.Lock()
	size := &pty.Winsize{Rows: uint16(s.height), Cols: uint16(s.width)}
	s.mu.Unlock()

	file, err := pty.StartWithSize(cmd, size)
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.nextID++
	window := &muxWindow{
		id:           fmt.Sprintf("@%d", s.nextID),
		index:        len(s.windows),
		name:         name,
		cwd:          cwd,
		command:      filepath.Base(cmd.Path),
		paneTitle:    name,
		pty:          file,
		cmd:          cmd,
		lastActivity: time.Now(),
	}
	s.windows = append(s.windows, window)
	s.activeID = window.id
	s.clearAlertsLocked(window.id)
	s.mu.Unlock()

	go s.readWindow(window)
	go func() {
		_ = cmd.Wait()
		s.markWindowClosed(window.id)
	}()

	if strings.TrimSpace(options.command) != "" && len(options.args) == 0 {
		go func() {
			time.Sleep(120 * time.Millisecond)
			_, _ = file.Write([]byte(strings.TrimSpace(options.command) + "\r"))
		}()
	}

	s.broadcast(controlResponse{
		Type:    "window_added",
		Session: s.session,
		Window:  ptrWindowSnapshot(s.snapshot(window)),
	})
	s.broadcastWindowList("window_list")
	return window, nil
}

func (s *muxServer) readWindow(window *muxWindow) {
	buf := make([]byte, 32*1024)
	for {
		n, err := window.pty.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.handleWindowOutput(window.id, chunk)
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) handleWindowOutput(windowID string, chunk []byte) {
	var attach net.Conn
	var shouldWrite bool
	var snapshot *windowSnapshot

	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return
	}
	window.lastActivity = time.Now()
	window.observeTerminalMetadataLocked(chunk)
	window.appendHistoryLocked(chunk)
	if s.activeID == windowID {
		attach = s.attachConn
		shouldWrite = attach != nil
	} else {
		window.alert = true
	}
	snap := s.snapshotLocked(window)
	snapshot = &snap
	s.mu.Unlock()

	if shouldWrite {
		s.writeAttach(attach, chunk)
	}

	s.broadcast(controlResponse{
		Type:    "window_updated",
		Session: s.session,
		Window:  snapshot,
	})
}

func (s *muxServer) markWindowClosed(windowID string) {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return
	}
	window.closed = true
	window.alert = false
	_ = window.pty.Close()
	s.reindexWindowsLocked()
	if s.activeID == windowID {
		s.activeID = ""
		for _, candidate := range s.windows {
			if !candidate.closed {
				s.activeID = candidate.id
				candidate.alert = false
				break
			}
		}
	}
	snapshots := s.snapshotsLocked()
	s.mu.Unlock()

	s.broadcast(controlResponse{
		Type:    "window_removed",
		Session: s.session,
		Window:  &windowSnapshot{ID: windowID},
	})
	s.broadcast(controlResponse{
		Type:    "window_list",
		Session: s.session,
		Windows: snapshots,
	})
}

func (s *muxServer) handleConnection(conn net.Conn) {
	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		_ = conn.Close()
		return
	}
	var hello controlMessage
	if err := json.Unmarshal(line, &hello); err != nil {
		_ = conn.Close()
		return
	}
	switch hello.Role {
	case "attach":
		s.handleAttach(conn, reader, hello)
	case "control":
		s.handleControl(conn, reader)
	default:
		_ = conn.Close()
	}
}

func (s *muxServer) handleAttach(conn net.Conn, reader *bufio.Reader, hello controlMessage) {
	var replay []byte
	s.mu.Lock()
	if s.attachConn != nil {
		_ = s.attachConn.Close()
	}
	s.attachConn = conn
	if hello.Width > 0 && hello.Height > 0 {
		s.width = hello.Width
		s.height = hello.Height
		s.resizeActiveLocked(hello.Width, hello.Height)
	}
	replay = s.activeReplayLocked()
	s.mu.Unlock()
	s.writeAttach(conn, replay)
	s.broadcastWindowList("active_window_changed")

	defer func() {
		s.mu.Lock()
		if s.attachConn == conn {
			s.attachConn = nil
		}
		s.mu.Unlock()
		_ = conn.Close()
	}()

	buf := make([]byte, 32*1024)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			s.writeActive(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func (s *muxServer) handleControl(conn net.Conn, reader *bufio.Reader) {
	client := &controlClient{conn: conn, enc: json.NewEncoder(conn)}
	s.addControl(client)
	defer func() {
		s.removeControl(client)
		_ = conn.Close()
	}()

	client.send(controlResponse{
		Type:         "hello",
		Status:       "ok",
		Version:      monkeyMuxVersion,
		Session:      s.session,
		Capabilities: capabilities,
	})
	client.send(controlResponse{
		Type:    "window_list",
		Status:  "ok",
		Session: s.session,
		Windows: s.snapshots(),
	})

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var request controlMessage
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			client.send(controlResponse{
				Type:   "error",
				Status: "error",
				Error:  err.Error(),
			})
			continue
		}
		s.handleControlRequest(client, request)
	}
}

func (s *muxServer) handleControlRequest(client *controlClient, request controlMessage) {
	switch request.Type {
	case "ping":
		client.send(controlResponse{ID: request.ID, Type: "pong", Status: "ok"})
	case "list_windows":
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_list",
			Status:  "ok",
			Session: s.session,
			Windows: s.snapshots(),
		})
	case "create_window":
		window, err := s.createWindow(createWindowOptions{
			name:    request.Name,
			cwd:     request.Cwd,
			command: request.Command,
			args:    request.Args,
		})
		if err != nil {
			client.sendError(request, err)
			return
		}
		s.selectWindow(window.id)
		client.send(controlResponse{
			ID:      request.ID,
			Type:    "window_created",
			Status:  "ok",
			Session: s.session,
			Window:  ptrWindowSnapshot(s.snapshot(window)),
		})
	case "select_window":
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		if err := s.selectWindow(id); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_selected", Status: "ok"})
	case "close_window", "kill_window":
		id := request.WindowID
		if id == "" && request.WindowIndex != nil {
			id = s.windowIDForIndex(*request.WindowIndex)
		}
		if id == "" {
			client.sendError(request, errors.New("missing target window"))
			return
		}
		if err := s.closeWindow(id); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "window_closed", Status: "ok"})
	case "resize":
		if request.Width <= 0 || request.Height <= 0 {
			client.sendError(request, errors.New("invalid terminal size"))
			return
		}
		s.resize(request.Width, request.Height)
		client.send(controlResponse{ID: request.ID, Type: "resized", Status: "ok"})
	case "query_active_context":
		window := s.activeWindow()
		if window == nil {
			client.sendError(request, errors.New("no active window"))
			return
		}
		client.send(controlResponse{
			ID:             request.ID,
			Type:           "active_context",
			Status:         "ok",
			Session:        s.session,
			CurrentPath:    window.cwd,
			CurrentCommand: window.command,
		})
	case "run_command":
		if strings.TrimSpace(request.Command) == "" {
			client.sendError(request, errors.New("missing command"))
			return
		}
		output, exitCode, err := s.runShellCommand(request.Command)
		if err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{
			ID:       request.ID,
			Type:     "command_output",
			Status:   "ok",
			Session:  s.session,
			Data:     output,
			ExitCode: exitCode,
		})
	case "inject_input":
		id := request.WindowID
		if id == "" {
			id = s.activeWindowID()
		}
		if err := s.writeWindow(id, []byte(request.Data)); err != nil {
			client.sendError(request, err)
			return
		}
		client.send(controlResponse{ID: request.ID, Type: "input_injected", Status: "ok"})
	case "focus_changed":
		id := s.activeWindowID()
		if request.Data != "" {
			_ = s.writeWindow(id, []byte(request.Data))
		} else {
			_ = s.writeWindow(id, []byte("\x1b[I"))
		}
		client.send(controlResponse{ID: request.ID, Type: "focus_hint_sent", Status: "ok"})
	case "theme_changed":
		client.send(controlResponse{ID: request.ID, Type: "theme_hint_ack", Status: "ok"})
	case "shutdown":
		client.send(controlResponse{ID: request.ID, Type: "shutdown", Status: "ok"})
		go s.close()
	default:
		client.sendError(request, fmt.Errorf("unsupported command %q", request.Type))
	}
}

func (s *muxServer) addControl(client *controlClient) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.controls[client] = struct{}{}
}

func (s *muxServer) removeControl(client *controlClient) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.controls, client)
}

func (c *controlClient) send(response controlResponse) {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.enc.Encode(response)
}

func (c *controlClient) sendError(request controlMessage, err error) {
	c.send(controlResponse{
		ID:     request.ID,
		Type:   "error",
		Status: "error",
		Error:  err.Error(),
	})
}

func (s *muxServer) broadcast(response controlResponse) {
	s.mu.Lock()
	clients := make([]*controlClient, 0, len(s.controls))
	for client := range s.controls {
		clients = append(clients, client)
	}
	s.mu.Unlock()
	for _, client := range clients {
		client.send(response)
	}
}

func (s *muxServer) broadcastWindowList(eventType string) {
	s.broadcast(controlResponse{
		Type:    eventType,
		Session: s.session,
		Windows: s.snapshots(),
	})
}

func (s *muxServer) snapshots() []windowSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotsLocked()
}

func (s *muxServer) snapshotsLocked() []windowSnapshot {
	windows := make([]windowSnapshot, 0, len(s.windows))
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		windows = append(windows, s.snapshotLocked(window))
	}
	return windows
}

func (s *muxServer) snapshot(window *muxWindow) windowSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked(window)
}

func (s *muxServer) snapshotLocked(window *muxWindow) windowSnapshot {
	flags := ""
	if window.alert {
		flags = "#"
	}
	return windowSnapshot{
		ID:                       window.id,
		Index:                    window.index,
		Name:                     window.name,
		Active:                   s.activeID == window.id,
		CurrentCommand:           window.command,
		CurrentPath:              window.cwd,
		PanePid:                  window.processID(),
		Flags:                    flags,
		PaneTitle:                window.paneTitle,
		LastActivityEpochSeconds: window.lastActivity.Unix(),
	}
}

func (s *muxServer) runShellCommand(command string) (string, int, error) {
	s.mu.Lock()
	cwd := ""
	if window := s.windowByIDLocked(s.activeID); window != nil {
		cwd = window.cwd
	}
	s.mu.Unlock()

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	switch filepath.Base(shell) {
	case "sh", "bash", "zsh", "ksh", "dash":
	default:
		shell = "/bin/sh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), runCommandTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, shell, "-c", command)
	if cwd != "" {
		cmd.Dir = cwd
	}
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", 0, errors.New("command timed out")
	}
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return "", 0, err
		}
	}
	return string(output), exitCode, nil
}

func (s *muxServer) selectWindow(windowID string) error {
	var attach net.Conn
	var replay []byte
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	s.activeID = windowID
	window.alert = false
	s.resizeActiveLocked(s.width, s.height)
	attach = s.attachConn
	replay = s.replayBytesLocked(window)
	s.mu.Unlock()
	s.writeAttach(attach, replay)
	s.broadcastWindowList("active_window_changed")
	return nil
}

func (s *muxServer) closeWindow(windowID string) error {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	if window == nil || window.closed {
		s.mu.Unlock()
		return fmt.Errorf("window %q not found", windowID)
	}
	openCount := 0
	for _, candidate := range s.windows {
		if !candidate.closed {
			openCount++
		}
	}
	if openCount <= 1 {
		s.mu.Unlock()
		return errors.New("cannot close the last MonkeyMux window")
	}
	_ = window.cmd.Process.Signal(syscall.SIGHUP)
	_ = window.pty.Close()
	s.mu.Unlock()
	return nil
}

func (s *muxServer) resize(width int, height int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.width = width
	s.height = height
	s.resizeActiveLocked(width, height)
}

func (s *muxServer) resizeActiveLocked(width int, height int) {
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed || window.pty == nil {
		return
	}
	_ = pty.Setsize(window.pty, &pty.Winsize{
		Rows: uint16(height),
		Cols: uint16(width),
	})
}

func (s *muxServer) activeReplayLocked() []byte {
	window := s.windowByIDLocked(s.activeID)
	if window == nil || window.closed {
		return nil
	}
	return s.replayBytesLocked(window)
}

func (s *muxServer) replayBytesLocked(window *muxWindow) []byte {
	replay := make([]byte, 0, len(activeWindowReplayPrefix)+len(window.history))
	replay = append(replay, activeWindowReplayPrefix...)
	replay = append(replay, window.history...)
	return replay
}

func (s *muxServer) writeAttach(conn net.Conn, data []byte) {
	if conn == nil || len(data) == 0 {
		return
	}
	s.attachMu.Lock()
	_, err := conn.Write(data)
	s.attachMu.Unlock()
	if err != nil {
		s.mu.Lock()
		if s.attachConn == conn {
			s.attachConn = nil
		}
		s.mu.Unlock()
	}
}

func (s *muxServer) writeActive(data []byte) {
	_ = s.writeWindow(s.activeWindowID(), data)
}

func (s *muxServer) writeWindow(windowID string, data []byte) error {
	s.mu.Lock()
	window := s.windowByIDLocked(windowID)
	s.mu.Unlock()
	if window == nil || window.closed {
		return fmt.Errorf("window %q not found", windowID)
	}
	_, err := window.pty.Write(data)
	return err
}

func (s *muxServer) activeWindow() *muxWindow {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.windowByIDLocked(s.activeID)
}

func (s *muxServer) activeWindowID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.activeID
}

func (s *muxServer) windowIDForIndex(index int) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, window := range s.windows {
		if !window.closed && window.index == index {
			return window.id
		}
	}
	return ""
}

func (s *muxServer) windowByIDLocked(windowID string) *muxWindow {
	for _, window := range s.windows {
		if window.id == windowID {
			return window
		}
	}
	return nil
}

func (w *muxWindow) appendHistoryLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	if len(chunk) >= windowHistoryLimitBytes {
		w.history = append(
			w.history[:0],
			chunk[len(chunk)-windowHistoryLimitBytes:]...,
		)
		return
	}
	w.history = append(w.history, chunk...)
	if overflow := len(w.history) - windowHistoryLimitBytes; overflow > 0 {
		copy(w.history, w.history[overflow:])
		w.history = w.history[:windowHistoryLimitBytes]
	}
}

func (w *muxWindow) processID() int {
	if w == nil || w.cmd == nil || w.cmd.Process == nil {
		return 0
	}
	return w.cmd.Process.Pid
}

func (w *muxWindow) observeTerminalMetadataLocked(chunk []byte) {
	if len(chunk) == 0 {
		return
	}
	data := chunk
	if len(w.oscBuffer) > 0 {
		combined := make([]byte, 0, len(w.oscBuffer)+len(chunk))
		combined = append(combined, w.oscBuffer...)
		combined = append(combined, chunk...)
		data = combined
		w.oscBuffer = nil
	}

	for len(data) > 0 {
		escapeIndex := bytes.IndexByte(data, '\x1b')
		if escapeIndex < 0 {
			return
		}
		if escapeIndex+1 >= len(data) {
			w.storePartialOscLocked(data[escapeIndex:])
			return
		}
		if data[escapeIndex+1] != ']' {
			data = data[escapeIndex+1:]
			continue
		}

		payloadStart := escapeIndex + 2
		payloadEnd, terminatorLength, ok := findOscTerminator(data[payloadStart:])
		if !ok {
			w.storePartialOscLocked(data[escapeIndex:])
			return
		}
		w.applyOscPayloadLocked(string(data[payloadStart : payloadStart+payloadEnd]))
		data = data[payloadStart+payloadEnd+terminatorLength:]
	}
}

func findOscTerminator(data []byte) (payloadEnd int, terminatorLength int, ok bool) {
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '\a':
			return i, 1, true
		case '\x1b':
			if i+1 >= len(data) {
				return 0, 0, false
			}
			if data[i+1] == '\\' {
				return i, 2, true
			}
		}
	}
	return 0, 0, false
}

func (w *muxWindow) storePartialOscLocked(data []byte) {
	if len(data) > oscBufferLimitBytes {
		w.oscBuffer = nil
		return
	}
	w.oscBuffer = append(w.oscBuffer[:0], data...)
}

func (w *muxWindow) applyOscPayloadLocked(payload string) {
	code, value, ok := strings.Cut(payload, ";")
	if !ok {
		return
	}
	switch code {
	case "0", "1", "2":
		title := cleanTerminalTitle(value)
		if title == "" {
			return
		}
		w.paneTitle = title
		w.name = title
	case "7":
		path := pathFromOsc7(value)
		if path != "" {
			w.cwd = path
		}
	}
}

func cleanTerminalTitle(value string) string {
	title := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, value)
	title = strings.Join(strings.Fields(title), " ")
	if len(title) <= maxTitleBytes {
		return title
	}
	for i := range title {
		if i > maxTitleBytes {
			return title[:i]
		}
	}
	return title
}

func pathFromOsc7(value string) string {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "file" {
		return ""
	}
	path, err := url.PathUnescape(parsed.Path)
	if err != nil || !strings.HasPrefix(path, "/") {
		return ""
	}
	return path
}

func (s *muxServer) clearAlertsLocked(activeID string) {
	for _, window := range s.windows {
		if window.id == activeID {
			window.alert = false
		}
	}
}

func (s *muxServer) reindexWindowsLocked() {
	index := 0
	for _, window := range s.windows {
		if window.closed {
			continue
		}
		window.index = index
		index++
	}
}

func (s *muxServer) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	listener := s.listener
	s.listener = nil
	attach := s.attachConn
	s.attachConn = nil
	controls := make([]*controlClient, 0, len(s.controls))
	for control := range s.controls {
		controls = append(controls, control)
	}
	windows := append([]*muxWindow(nil), s.windows...)
	s.mu.Unlock()

	if listener != nil {
		_ = listener.Close()
	}
	if attach != nil {
		_ = attach.Close()
	}
	for _, control := range controls {
		_ = control.conn.Close()
	}
	for _, window := range windows {
		if window.cmd != nil && window.cmd.Process != nil {
			_ = window.cmd.Process.Signal(syscall.SIGHUP)
		}
		if window.pty != nil {
			_ = window.pty.Close()
		}
	}
}

func (s *muxServer) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

type runningServerStatus struct {
	version      string
	capabilities []string
}

func (s runningServerStatus) displayVersion() string {
	if strings.TrimSpace(s.version) == "" {
		return "unknown"
	}
	return s.version
}

func (s runningServerStatus) supportsCapability(capability string) bool {
	for _, value := range s.capabilities {
		if value == capability {
			return true
		}
	}
	return false
}

func promptForServerUpdate(
	reader io.Reader,
	writer io.Writer,
	session string,
	status runningServerStatus,
) bool {
	fmt.Fprintf(
		writer,
		"\r\nMonkeyMux session %q is running with helper %s; this app includes helper %s.\r\n",
		session,
		status.displayVersion(),
		monkeyMuxVersion,
	)
	if status.supportsCapability("shutdown") {
		fmt.Fprint(
			writer,
			"Update now? This will close existing MonkeyMux windows for this session. [y/N] ",
		)
	} else {
		fmt.Fprint(
			writer,
			"Update now? This old helper cannot close itself; updating may abandon existing MonkeyMux windows. [y/N] ",
		)
	}
	answer, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil {
		fmt.Fprint(writer, "\r\nmonkeymux: update skipped; continuing existing session.\r\n")
		return false
	}
	answer = strings.ToLower(strings.TrimSpace(answer))
	if answer == "y" || answer == "yes" {
		return true
	}
	fmt.Fprint(writer, "monkeymux: update skipped; continuing existing session.\r\n")
	return false
}

func queryRunningServerStatus(session string) (runningServerStatus, error) {
	conn, err := dialSession(session)
	if err != nil {
		return runningServerStatus{}, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return runningServerStatus{}, err
	}
	var hello controlResponse
	if err := dec.Decode(&hello); err != nil {
		return runningServerStatus{}, err
	}
	return runningServerStatus{
		version:      hello.Version,
		capabilities: hello.Capabilities,
	}, nil
}

func requestServerShutdown(session string) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(socketTimeout))

	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	if err := enc.Encode(controlMessage{Role: "control", Session: session}); err != nil {
		return
	}
	var ignored controlResponse
	if err := dec.Decode(&ignored); err != nil {
		return
	}
	_ = enc.Encode(controlMessage{
		ID:      strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:    "shutdown",
		Session: session,
	})
}

func waitForServerExit(session string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := dialSession(session)
		if err != nil {
			return true
		}
		_ = conn.Close()
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func defaultShellPath() string {
	shell := os.Getenv("SHELL")
	if strings.TrimSpace(shell) == "" {
		return "/bin/sh"
	}
	return shell
}

func shellCommand(shell string) *exec.Cmd {
	return exec.Command(shell)
}

func inheritedEnvironment(base []string) []string {
	result := make([]string, len(base))
	copy(result, base)
	return result
}

func expandHomePath(path string) (string, error) {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path, err
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~/")), nil
}

func firstShellWord(command string) string {
	fields := strings.Fields(command)
	if len(fields) == 0 {
		return "shell"
	}
	return filepath.Base(fields[0])
}

func terminalSize() (int, int) {
	if size, err := pty.GetsizeFull(os.Stdin); err == nil && size.Cols > 0 && size.Rows > 0 {
		return int(size.Cols), int(size.Rows)
	}
	columns, rows, err := term.GetSize(int(os.Stdin.Fd()))
	if err == nil && columns > 0 && rows > 0 {
		return columns, rows
	}
	return defaultColumns, defaultRows
}

func makeTerminalRaw() func() {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return func() {}
	}
	state, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return func() {}
	}
	return func() {
		_ = term.Restore(int(os.Stdin.Fd()), state)
	}
}

func forwardResizeSignals(session string) func() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGWINCH)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-signals:
				width, height := terminalSize()
				sendResize(session, width, height)
			case <-done:
				return
			}
		}
	}()
	width, height := terminalSize()
	sendResize(session, width, height)
	return func() {
		close(done)
		signal.Stop(signals)
	}
}

func sendResize(session string, width int, height int) {
	conn, err := dialSession(session)
	if err != nil {
		return
	}
	defer conn.Close()
	enc := json.NewEncoder(conn)
	dec := json.NewDecoder(conn)
	_ = enc.Encode(controlMessage{Role: "control", Session: session})
	_ = dec.Decode(&controlResponse{})
	_ = dec.Decode(&controlResponse{})
	_ = enc.Encode(controlMessage{
		ID:      strconv.FormatInt(time.Now().UnixNano(), 10),
		Type:    "resize",
		Width:   width,
		Height:  height,
		Session: session,
	})
}

func socketPath(session string) (string, error) {
	dir, err := runtimeDirectory()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(session))
	return filepath.Join(dir, "monkeymux-"+hex.EncodeToString(sum[:])[:24]+".sock"), nil
}

func runtimeDirectory() (string, error) {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); strings.TrimSpace(dir) != "" {
		path := filepath.Join(dir, "monkeyssh", "monkeymux")
		return path, os.MkdirAll(path, 0o700)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, ".monkeyssh", "run")
	return path, os.MkdirAll(path, 0o700)
}

func dialSession(session string) (net.Conn, error) {
	socket, err := socketPath(session)
	if err != nil {
		return nil, err
	}
	return net.DialTimeout("unix", socket, 500*time.Millisecond)
}

func ptrWindowSnapshot(snapshot windowSnapshot) *windowSnapshot {
	return &snapshot
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "monkeymux: %v\n", err)
	os.Exit(1)
}

func init() {
	if runtime.GOOS == "windows" {
		fmt.Fprintln(os.Stderr, "monkeymux: windows is not supported by this POSIX build")
		os.Exit(1)
	}
}
