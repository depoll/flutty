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

func stopAcpProvider(cmd *exec.Cmd, providerDone <-chan struct{}) {
	stopAcpProviderAfter(
		cmd,
		providerDone,
		2*time.Second,
		forceStopAcpProvider,
	)
}

func stopAcpProviderAfter(
	cmd *exec.Cmd,
	providerDone <-chan struct{},
	grace time.Duration,
	force func(*exec.Cmd),
) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	select {
	case <-providerDone:
		return
	default:
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-providerDone:
		return
	case <-timer.C:
	}
	// The bridge's sole Wait caller closes providerDone immediately after it
	// reaps the original child. Never issue a delayed PID/process-group kill
	// after that signal: a recycled PID or PGID could otherwise belong to an
	// unrelated user process. This path is synchronous so a detached `acp serve`
	// helper cannot exit before the force-stop sequence completes.
	select {
	case <-providerDone:
		return
	default:
		force(cmd)
	}
}

func forceStopAcpProvider(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	_ = cmd.Process.Kill()
}
