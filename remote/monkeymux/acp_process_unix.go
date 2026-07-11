//go:build !windows

package main

import (
	"os/exec"
	"syscall"
	"time"
)

// newAcpProviderCommand deliberately uses ordinary pipes, not a terminal. ACP
// is an NDJSON protocol and a PTY would corrupt framing and terminal semantics.
func newAcpProviderCommand(command string) *exec.Cmd {
	cmd := exec.Command(commandShellPath(), "-c", command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

func stopAcpProvider(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	go func() {
		time.Sleep(2 * time.Second)
		if cmd.Process != nil {
			if cmd.Process.Pid > 0 {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
			_ = cmd.Process.Kill()
		}
	}()
}
