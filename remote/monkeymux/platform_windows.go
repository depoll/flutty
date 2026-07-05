//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// conPtyMinimumBuild is the first Windows 10 build (1809) that ships the
// ConPTY (pseudo console) APIs used by MonkeyMux on Windows.
const conPtyMinimumBuild = 17763

// conPtyMaxDimension bounds pseudo console dimensions so the int->int16
// conversion for windows.Coord can never wrap into a negative or zero value
// (which ConPTY rejects). Real terminals are far smaller than this.
const conPtyMaxDimension = 0x7fff

// conPtyCoord clamps cols/rows into the valid positive int16 range and returns
// the corresponding windows.Coord. Callers pass raw dimensions from control and
// attach messages, which are only validated as > 0 upstream.
func conPtyCoord(cols int, rows int) windows.Coord {
	return windows.Coord{X: clampConPtyDimension(cols), Y: clampConPtyDimension(rows)}
}

func clampConPtyDimension(value int) int16 {
	if value < 1 {
		return 1
	}
	if value > conPtyMaxDimension {
		return conPtyMaxDimension
	}
	return int16(value)
}

// winPty wraps a Windows pseudo console (ConPTY) and the two pipe endpoints the
// parent uses to talk to the attached child process.
type winPty struct {
	hpc       windows.Handle
	writeFile *os.File // parent writes child's stdin (input pipe write end)
	readFile  *os.File // parent reads child's stdout (output pipe read end)

	mu        sync.Mutex
	closed    bool
	closeOnce sync.Once
}

func (p *winPty) Read(b []byte) (int, error)  { return p.readFile.Read(b) }
func (p *winPty) Write(b []byte) (int, error) { return p.writeFile.Write(b) }

func (p *winPty) Resize(cols int, rows int) error {
	if cols <= 0 || rows <= 0 {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}
	return windows.ResizePseudoConsole(p.hpc, conPtyCoord(cols, rows))
}

func (p *winPty) Fd() uintptr { return 0 }

func (p *winPty) Close() error {
	p.closeOnce.Do(func() {
		p.mu.Lock()
		p.closed = true
		p.mu.Unlock()
		// Closing the pseudo console terminates the attached process tree and
		// causes the output pipe to reach EOF (after any final frame is
		// flushed), so the reader goroutine unblocks and exits.
		windows.ClosePseudoConsole(p.hpc)
		_ = p.readFile.Close()
		_ = p.writeFile.Close()
	})
	return nil
}

// winProcess wraps the child process launched into a ConPTY.
type winProcess struct {
	handle windows.Handle
	pid    int
	pty    *winPty

	waitOnce sync.Once
	waitErr  error
}

func (p *winProcess) Pid() int { return p.pid }

func (p *winProcess) Wait() error {
	p.waitOnce.Do(func() {
		event, err := windows.WaitForSingleObject(p.handle, windows.INFINITE)
		if event == windows.WAIT_FAILED {
			p.waitErr = err
		}
		windows.CloseHandle(p.handle)
	})
	return p.waitErr
}

func (p *winProcess) Hangup() {
	// There is no SIGHUP on Windows; closing the pseudo console terminates the
	// attached process tree, which is the closest equivalent.
	if p.pty != nil {
		_ = p.pty.Close()
	}
}

// startWindow launches cmd attached to a new ConPTY sized to cols x rows.
func startWindow(cmd *exec.Cmd, cols int, rows int) (muxPty, muxProcess, error) {
	if cols <= 0 {
		cols = defaultColumns
	}
	if rows <= 0 {
		rows = defaultRows
	}

	argv := commandLineArgs(cmd)
	commandLine := windows.ComposeCommandLine(argv)

	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	env = ensureSystemRoot(env)

	writeHandle, readHandle, hpc, procHandle, pid, err := startConPty(
		commandLine,
		env,
		cmd.Dir,
		cols,
		rows,
	)
	if err != nil {
		return nil, nil, err
	}

	windowPty := &winPty{
		hpc:       hpc,
		writeFile: os.NewFile(uintptr(writeHandle), "monkeymux-conpty-in"),
		readFile:  os.NewFile(uintptr(readHandle), "monkeymux-conpty-out"),
	}
	proc := &winProcess{handle: procHandle, pid: int(pid), pty: windowPty}
	return windowPty, proc, nil
}

// commandLineArgs returns argv for cmd, preferring the resolved executable path
// as argv[0] so CreateProcess launches the intended binary.
func commandLineArgs(cmd *exec.Cmd) []string {
	if len(cmd.Args) == 0 {
		if cmd.Path != "" {
			return []string{cmd.Path}
		}
		return []string{""}
	}
	if cmd.Path != "" {
		argv := make([]string, len(cmd.Args))
		argv[0] = cmd.Path
		copy(argv[1:], cmd.Args[1:])
		return argv
	}
	return cmd.Args
}

// startConPty creates a ConPTY of size cols x rows and launches commandLine
// attached to it. It returns the parent-side stdin write handle, stdout read
// handle, the pseudo console handle, the process handle and pid.
func startConPty(
	commandLine string,
	env []string,
	workdir string,
	cols int,
	rows int,
) (writeHandle, readHandle, hpcon, processHandle windows.Handle, pid uint32, err error) {
	if info := windows.RtlGetVersion(); info != nil {
		if info.MajorVersion < 10 ||
			(info.MajorVersion == 10 && info.BuildNumber < conPtyMinimumBuild) {
			err = fmt.Errorf(
				"MonkeyMux requires Windows 10 1809 (build %d), found build %d",
				conPtyMinimumBuild,
				info.BuildNumber,
			)
			return
		}
	}

	// input pipe:  ptyIn (read)  -> ConPTY,   cmdIn (write)  -> parent
	// output pipe: cmdOut (read) -> parent,   ptyOut (write) -> ConPTY
	var ptyIn, ptyOut, cmdIn, cmdOut windows.Handle
	if err = windows.CreatePipe(&ptyIn, &cmdIn, nil, 0); err != nil {
		err = fmt.Errorf("create input pipe: %w", err)
		return
	}
	if err = windows.CreatePipe(&cmdOut, &ptyOut, nil, 0); err != nil {
		windows.CloseHandle(ptyIn)
		windows.CloseHandle(cmdIn)
		err = fmt.Errorf("create output pipe: %w", err)
		return
	}

	closeAll := func() {
		windows.CloseHandle(ptyIn)
		windows.CloseHandle(ptyOut)
		windows.CloseHandle(cmdIn)
		windows.CloseHandle(cmdOut)
	}

	size := conPtyCoord(cols, rows)
	if err = windows.CreatePseudoConsole(size, ptyIn, ptyOut, 0, &hpcon); err != nil {
		closeAll()
		err = fmt.Errorf("create pseudo console: %w", err)
		return
	}

	attrs, attrErr := windows.NewProcThreadAttributeList(1)
	if attrErr != nil {
		windows.ClosePseudoConsole(hpcon)
		hpcon = 0
		closeAll()
		err = fmt.Errorf("allocate attribute list: %w", attrErr)
		return
	}
	defer attrs.Delete()

	// For PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE the attribute value is the HPCON
	// handle itself (passed by value in the pointer slot), per the Win32 ConPTY
	// sample. Reinterpret the handle's bits as an unsafe.Pointer via a pointer
	// cast rather than an int->pointer conversion so `go vet` does not flag it.
	pseudoConsoleValue := *(*unsafe.Pointer)(unsafe.Pointer(&hpcon))
	if err = attrs.Update(
		windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		pseudoConsoleValue,
		unsafe.Sizeof(hpcon),
	); err != nil {
		windows.ClosePseudoConsole(hpcon)
		hpcon = 0
		closeAll()
		err = fmt.Errorf("set pseudo console attribute: %w", err)
		return
	}

	var startupInfo windows.StartupInfoEx
	startupInfo.ProcThreadAttributeList = attrs.List()
	startupInfo.Cb = uint32(unsafe.Sizeof(startupInfo))

	commandLinePtr, cmdErr := windows.UTF16PtrFromString(commandLine)
	if cmdErr != nil {
		windows.ClosePseudoConsole(hpcon)
		hpcon = 0
		closeAll()
		err = fmt.Errorf("encode command line: %w", cmdErr)
		return
	}

	var dirPtr *uint16
	if strings.TrimSpace(workdir) != "" {
		dirPtr, err = windows.UTF16PtrFromString(workdir)
		if err != nil {
			windows.ClosePseudoConsole(hpcon)
			hpcon = 0
			closeAll()
			err = fmt.Errorf("encode working directory: %w", err)
			return
		}
	}

	creationFlags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT)
	var envBlock *uint16
	if len(env) > 0 {
		creationFlags |= uint32(windows.CREATE_UNICODE_ENVIRONMENT)
		envBlock, err = buildEnvBlock(env)
		if err != nil {
			windows.ClosePseudoConsole(hpcon)
			hpcon = 0
			closeAll()
			err = fmt.Errorf("encode environment: %w", err)
			return
		}
	}

	var procInfo windows.ProcessInformation
	if err = windows.CreateProcess(
		nil,
		commandLinePtr,
		nil,
		nil,
		false,
		creationFlags,
		envBlock,
		dirPtr,
		&startupInfo.StartupInfo,
		&procInfo,
	); err != nil {
		windows.ClosePseudoConsole(hpcon)
		hpcon = 0
		closeAll()
		err = fmt.Errorf("create process: %w", err)
		return
	}

	// The pseudo console holds its own references to these ends; releasing our
	// copies lets I/O detect a broken channel when the session ends.
	windows.CloseHandle(ptyIn)
	windows.CloseHandle(ptyOut)
	windows.CloseHandle(procInfo.Thread)

	return cmdIn, cmdOut, hpcon, procInfo.Process, procInfo.ProcessId, nil
}

// buildEnvBlock encodes env as a double-NUL terminated UTF-16 environment block
// for CreateProcess.
func buildEnvBlock(env []string) (*uint16, error) {
	var block []uint16
	for _, entry := range env {
		if entry == "" {
			continue
		}
		encoded, err := windows.UTF16FromString(entry)
		if err != nil {
			return nil, fmt.Errorf("environment entry %q: %w", entry, err)
		}
		block = append(block, encoded...)
	}
	block = append(block, 0)
	return &block[0], nil
}

// ensureSystemRoot guarantees SystemRoot is present so system DLLs resolve.
func ensureSystemRoot(env []string) []string {
	for _, entry := range env {
		if strings.HasPrefix(strings.ToUpper(entry), "SYSTEMROOT=") {
			return env
		}
	}
	if root := os.Getenv("SystemRoot"); root != "" {
		return append(env, "SystemRoot="+root)
	}
	return env
}

// configureDetachedDaemon detaches the serve daemon from the launching console
// and process group so it survives after the launching shell exits.
func configureDetachedDaemon(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP,
	}
}

// newRunCommand builds the bounded metadata command using the platform shell.
func newRunCommand(command string) *exec.Cmd {
	shell := commandShellPath()
	var cmd *exec.Cmd
	if isCmdShell(shell) {
		cmd = exec.Command(shell, "/c", command)
	} else {
		cmd = exec.Command(shell, "-NoLogo", "-NonInteractive", "-Command", command)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}
	return cmd
}

func commandShellPath() string {
	if comspec := strings.TrimSpace(os.Getenv("ComSpec")); comspec != "" {
		return comspec
	}
	return "cmd.exe"
}

func killCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	if pid > 0 {
		// taskkill terminates the whole tree; fall back to Kill on failure.
		kill := exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(pid))
		kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if err := kill.Run(); err == nil {
			return
		}
	}
	_ = cmd.Process.Kill()
}

// signalForegroundResize is a no-op on Windows: ResizePseudoConsole already
// notifies the attached child of size changes.
var signalForegroundResize = func(processGroup int) {}

// foregroundProcessGroupForWindow approximates the POSIX foreground process
// group with the window's own process id. Windows has no controlling-terminal
// foreground group, but pairing this with a parent-based process table lets
// MonkeyMux still surface agents launched inside the window's shell.
var foregroundProcessGroupForWindow = func(window *muxWindow) int {
	if window == nil || window.proc == nil {
		return 0
	}
	return window.proc.Pid()
}

func defaultShellPath() string {
	if shell := strings.TrimSpace(os.Getenv("MONKEYMUX_SHELL")); shell != "" {
		return shell
	}
	if path, err := exec.LookPath("pwsh.exe"); err == nil {
		return path
	}
	if path, err := exec.LookPath("powershell.exe"); err == nil {
		return path
	}
	if comspec := strings.TrimSpace(os.Getenv("ComSpec")); comspec != "" {
		return comspec
	}
	return "cmd.exe"
}

func shellCommand(shell string) *exec.Cmd {
	return exec.Command(shell)
}

func shellCommandForScript(shell string, command string) *exec.Cmd {
	if isCmdShell(shell) {
		return exec.Command(shell, "/c", command)
	}
	return exec.Command(shell, "-NoLogo", "-Command", command)
}

func isCmdShell(shell string) bool {
	base := strings.ToLower(filepath.Base(shell))
	return base == "cmd" || base == "cmd.exe"
}

// readProcessTable enumerates running processes via the Toolhelp snapshot API.
// Windows has no process groups, so pgid is approximated with the parent pid so
// that direct children of a window's shell can be correlated. Full argument
// lists are unavailable through Toolhelp, so args mirrors the executable name.
func readProcessTable() map[int]processInfo {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(snapshot)

	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	if err := windows.Process32First(snapshot, &entry); err != nil {
		return nil
	}

	processes := map[int]processInfo{}
	for {
		pid := int(entry.ProcessID)
		ppid := int(entry.ParentProcessID)
		comm := windows.UTF16ToString(entry.ExeFile[:])
		processes[pid] = processInfo{
			pid:  pid,
			ppid: ppid,
			pgid: ppid,
			comm: comm,
			args: comm,
		}
		if err := windows.Process32Next(snapshot, &entry); err != nil {
			break
		}
	}
	return processes
}

func commandNameForPID(pid int) string {
	if pid <= 0 {
		return ""
	}
	table := cachedProcessTable(time.Now())
	if info, ok := table[pid]; ok {
		return commandNameFromProcessFields(info.comm, info.args)
	}
	return ""
}

type memoryStatusEx struct {
	length               uint32
	memoryLoad           uint32
	totalPhys            uint64
	availPhys            uint64
	totalPageFile        uint64
	availPageFile        uint64
	totalVirtual         uint64
	availVirtual         uint64
	availExtendedVirtual uint64
}

var procGlobalMemoryStatusEx = windows.NewLazySystemDLL("kernel32.dll").
	NewProc("GlobalMemoryStatusEx")

// detectSystemMemoryBytes returns total physical memory in bytes, or 0 when it
// cannot be determined.
func detectSystemMemoryBytes() uint64 {
	var status memoryStatusEx
	status.length = uint32(unsafe.Sizeof(status))
	ret, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&status)))
	if ret == 0 {
		return 0
	}
	return status.totalPhys
}

func terminalSize() (int, int) {
	if columns, rows, err := term.GetSize(int(os.Stdout.Fd())); err == nil &&
		columns > 0 && rows > 0 {
		return columns, rows
	}
	if columns, rows, err := term.GetSize(int(os.Stdin.Fd())); err == nil &&
		columns > 0 && rows > 0 {
		return columns, rows
	}
	return defaultColumns, defaultRows
}

// forwardResizeSignals sends the initial terminal size and then polls for
// changes. Windows has no SIGWINCH; interactive resizes primarily arrive over
// the MonkeyMux control channel, and this poller covers local console resizes.
func forwardResizeSignals(session string) func() {
	done := make(chan struct{})
	go func() {
		lastWidth, lastHeight := terminalSize()
		sendResize(session, lastWidth, lastHeight)
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				width, height := terminalSize()
				if width != lastWidth || height != lastHeight {
					lastWidth, lastHeight = width, height
					sendResize(session, width, height)
				}
			case <-done:
				return
			}
		}
	}()
	return func() { close(done) }
}
