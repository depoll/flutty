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
	if cmd == nil || cmd.Process == nil || !acpProviderProcessGroupAlive(cmd) {
		return
	}
	if cmd.Process.Pid > 0 {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)

	timer := time.NewTimer(grace)
	defer timer.Stop()
	poll := time.NewTicker(10 * time.Millisecond)
	defer poll.Stop()
	done := providerDone
	for {
		if !acpProviderProcessGroupAlive(cmd) {
			return
		}
		select {
		case <-done:
			// cmd.Wait only reaped the shell wrapper. Disable this always-ready
			// channel and keep polling because children may still occupy the
			// process group after ignoring SIGTERM.
			done = nil
		case <-poll.C:
		case <-timer.C:
			if acpProviderProcessGroupAlive(cmd) {
				force(cmd)
			}
			return
		}
	}
}

func acpProviderProcessGroupAlive(cmd *exec.Cmd) bool {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return false
	}
	err := syscall.Kill(-cmd.Process.Pid, 0)
	return err == nil || err == syscall.EPERM
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
