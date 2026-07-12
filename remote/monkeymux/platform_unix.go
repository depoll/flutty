//go:build !windows

package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

// unixPty wraps a POSIX pseudo-terminal master file.
type unixPty struct {
	file   *os.File
	mu     sync.Mutex
	closed bool
}

func (p *unixPty) Read(b []byte) (int, error)  { return p.file.Read(b) }
func (p *unixPty) Write(b []byte) (int, error) { return p.file.Write(b) }

func (p *unixPty) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	p.closed = true
	return p.file.Close()
}

func (p *unixPty) Resize(cols int, rows int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return os.ErrClosed
	}
	return pty.Setsize(p.file, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	})
}

func (p *unixPty) Fd() uintptr {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return ^uintptr(0)
	}
	return p.file.Fd()
}

// unixProcess wraps the child process attached to a pty master.
type unixProcess struct {
	cmd *exec.Cmd
}

func (p *unixProcess) Pid() int {
	if p.cmd == nil || p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}

func (p *unixProcess) Wait() error {
	if p.cmd == nil {
		return nil
	}
	return p.cmd.Wait()
}

func (p *unixProcess) Hangup() {
	signalCommandProcessGroup(p.cmd, syscall.SIGHUP)
}

// startWindow launches cmd attached to a new pty sized to cols x rows.
func startWindow(cmd *exec.Cmd, cols int, rows int) (muxPty, muxProcess, error) {
	file, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	})
	if err != nil {
		return nil, nil, err
	}
	return &unixPty{file: file}, &unixProcess{cmd: cmd}, nil
}

// detachedDaemonSysProcAttrs returns the SysProcAttr to use when starting the
// detached server daemon. On POSIX a new session (setsid) detaches it from the
// launching shell's controlling terminal and process group.
func detachedDaemonSysProcAttrs() []*syscall.SysProcAttr {
	return []*syscall.SysProcAttr{{Setsid: true}}
}

// newRunCommand builds the bounded metadata command in its own process group so
// it can be signaled as a group on timeout/cancel.
func newRunCommand(command string) *exec.Cmd {
	cmd := exec.Command(commandShellPath(), "-c", command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

func commandShellPath() string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	switch filepath.Base(shell) {
	case "sh", "bash", "zsh", "ksh", "dash":
		return shell
	default:
		return "/bin/sh"
	}
}

func killCommandProcessGroup(cmd *exec.Cmd) {
	signalCommandProcessGroup(cmd, syscall.SIGKILL)
}

func signalCommandProcessGroup(cmd *exec.Cmd, signal syscall.Signal) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, signal)
	}
	_ = cmd.Process.Signal(signal)
}

var signalForegroundResize = func(processGroup int) {
	if processGroup <= 0 {
		return
	}
	_ = syscall.Kill(-processGroup, syscall.SIGWINCH)
}

// attachOutputWriter returns w unchanged: POSIX pseudo-terminals do not
// interpret win32-input-mode (DEC private mode 9001) requests, so the outer
// conhost corruption the Windows implementation guards against cannot occur.
func attachOutputWriter(w io.Writer) io.Writer {
	return w
}

var foregroundProcessGroupForWindow = func(window *muxWindow) int {
	if window == nil || window.pty == nil {
		return 0
	}
	pgrp, err := unix.IoctlGetInt(int(window.pty.Fd()), unix.TIOCGPGRP)
	if err != nil || pgrp <= 0 {
		return 0
	}
	return pgrp
}

func defaultShellPath() string {
	shell := os.Getenv("SHELL")
	if strings.TrimSpace(shell) == "" {
		return "/bin/sh"
	}
	return shell
}

func shellCommand(shell string) *exec.Cmd {
	cmd := exec.Command(shell)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

func shellCommandForScript(shell string, command string) *exec.Cmd {
	cmd := exec.Command(shell, "-i", "-c", command)
	if base := filepath.Base(shell); base != "" {
		cmd.Args[0] = "-" + base
	}
	return cmd
}

// agentWindowHoldThresholdSeconds bounds how soon after launch an abnormal agent
// exit still holds the window open. Startup failures surface within a couple of
// seconds; a later exit is treated as the user ending the session normally, so
// the window closes as usual.
const agentWindowHoldThresholdSeconds = 12

// holdAgentWindowCommand wraps an agent launch command so the window survives a
// fast, abnormal exit. If the agent exits non-zero within
// agentWindowHoldThresholdSeconds, the terminal is restored to a sane state and
// an interactive shell replaces it, keeping the failure output on screen and
// letting the user recover (for example, `security unlock-keychain` on a locked
// macOS login keychain) and relaunch. A clean exit, or one after the session has
// been running for a while, lets the window close normally. An intentional
// window close signals SIGHUP to the whole process group, terminating this
// wrapping shell before the fallback runs, so closing a window never lingers.
func holdAgentWindowCommand(shell string, command string) string {
	command = strings.TrimSpace(command)
	if command == "" {
		return command
	}
	notice := "[MonkeySSH] Agent exited (status %s) right after launch. " +
		"Keeping this window open so you can read the error above; " +
		"fix it and relaunch, or close the window."
	return "__mm_t0=$(date +%s 2>/dev/null || echo 0); " +
		command + "; __mm_rc=$?; " +
		"__mm_t1=$(date +%s 2>/dev/null || echo 0); " +
		"if [ \"$__mm_rc\" -ne 0 ] && " +
		"[ \"$((__mm_t1 - __mm_t0))\" -lt " +
		strconv.Itoa(agentWindowHoldThresholdSeconds) + " ]; then " +
		"stty sane 2>/dev/null; " +
		"printf '\\r\\n" + notice + "\\r\\n' \"$__mm_rc\"; " +
		"exec " + shellQuote(shell) + " -i; fi"
}

func readProcessTable() map[int]processInfo {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(
		ctx,
		"ps",
		"-eo",
		"pid=,ppid=,pgid=,comm=,args=",
	).Output()
	if err != nil || ctx.Err() != nil {
		return nil
	}
	processes := map[int]processInfo{}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		pgid, err := strconv.Atoi(fields[2])
		if err != nil {
			continue
		}
		args := ""
		if len(fields) > 4 {
			args = strings.Join(fields[4:], " ")
		}
		processes[pid] = processInfo{
			pid:  pid,
			ppid: ppid,
			pgid: pgid,
			comm: fields[3],
			args: args,
		}
	}
	return processes
}

func commandNameForPID(pid int) string {
	ctx, cancel := context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=", "-o", "args=").Output()
	if err == nil && ctx.Err() == nil {
		for _, line := range strings.Split(string(output), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			if command := commandNameFromProcessFields(fields[0], strings.Join(fields[1:], " ")); command != "" {
				return command
			}
		}
	}

	ctx, cancel = context.WithTimeout(context.Background(), processMetadataTimeout)
	defer cancel()
	output, err = exec.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if err != nil || ctx.Err() != nil {
		return ""
	}
	return cleanProcessCommandName(string(output))
}

// detectSystemMemoryBytes returns total physical memory in bytes, or 0 when it
// cannot be determined on this platform.
func detectSystemMemoryBytes() uint64 {
	if bytes := readLinuxMemTotalBytes(); bytes > 0 {
		return bytes
	}
	return readDarwinMemTotalBytes()
}

func readLinuxMemTotalBytes() uint64 {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			if kb, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
				return kb * 1024
			}
		}
		break
	}
	return 0
}

func readDarwinMemTotalBytes() uint64 {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 0
	}
	bytes, err := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 0
	}
	return bytes
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

func forwardResizeSignals(session string, clientID string) func() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGWINCH)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-signals:
				width, height := terminalSize()
				sendResize(session, clientID, width, height)
			case <-done:
				return
			}
		}
	}()
	width, height := terminalSize()
	sendResize(session, clientID, width, height)
	return func() {
		close(done)
		signal.Stop(signals)
	}
}
