//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// newAcpProviderCommand intentionally does not use ConPTY. ACP providers
// communicate over stdin/stdout pipes, which remain byte-for-byte NDJSON.
func newAcpProviderCommand(command string) *exec.Cmd {
	shell := commandShellPath()
	var cmd *exec.Cmd
	if isCmdShell(shell) {
		cmd = exec.Command(shell, "/c", command) // nosemgrep
	} else {
		cmd = exec.Command(shell, "-NoLogo", "-NonInteractive", "-Command", command) // nosemgrep
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
	}
	return cmd
}

func acpProviderProcessGroupHasLiveMember(cmd *exec.Cmd) (bool, error) {
	if cmd == nil || cmd.Process == nil {
		return false, nil
	}
	return processIDAlive(cmd.Process.Pid), nil
}

func stopAcpProvider(cmd *exec.Cmd, _ <-chan struct{}) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pid := cmd.Process.Pid
	if pid > 0 {
		kill := exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(pid))
		kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if kill.Run() == nil {
			return
		}
	}
	_ = cmd.Process.Kill()
}
