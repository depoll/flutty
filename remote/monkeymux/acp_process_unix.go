//go:build !windows

package main

import (
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// newAcpProviderCommand deliberately uses ordinary pipes, not a terminal. ACP
// is an NDJSON protocol and a PTY would corrupt framing and terminal semantics.
func newAcpProviderCommand(command string) *exec.Cmd {
	// The ACP launch command is intentionally interpreted by the remote user's shell; provider presets validate/quote their arguments before this boundary.
	cmd := exec.Command(commandShellPath(), "-c", command) // nosemgrep: dangerous-exec-command
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

func stopAcpProvider(cmd *exec.Cmd, providerOutputDone <-chan struct{}) {
	stopAcpProviderAfter(
		cmd,
		providerOutputDone,
		2*time.Second,
		forceStopAcpProvider,
	)
}

// stopAcpProviderAfter must run while the provider reap gate is closed. Keeping
// the process-group leader unreaped reserves its PID/PGID, so every group signal
// below targets the original provider tree rather than a recycled process group.
func stopAcpProviderAfter(
	cmd *exec.Cmd,
	providerOutputDone <-chan struct{},
	grace time.Duration,
	force func(*exec.Cmd),
) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	_ = cmd.Process.Signal(syscall.SIGTERM)

	timer := time.NewTimer(grace)
	defer timer.Stop()
	poll := time.NewTicker(10 * time.Millisecond)
	defer poll.Stop()
	outputDone := providerOutputDone
	for {
		if live, err := acpProviderProcessGroupHasLiveMember(cmd); err == nil && !live {
			return
		}
		select {
		case <-outputDone:
			// Output EOF is only a wake-up hint. A descendant may have closed its
			// inherited descriptors while remaining alive in the provider group.
			outputDone = nil
		case <-poll.C:
		case <-timer.C:
			force(cmd)
			return
		}
	}
}

// acpProviderProcessGroupHasLiveMember excludes zombie members. During calls
// from the stop path the unreaped leader keeps the PGID reserved, so a matching
// live member is guaranteed to belong to this provider group.
func acpProviderProcessGroupHasLiveMember(cmd *exec.Cmd) (bool, error) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return false, nil
	}
	output, err := runProcessQuery("ps", "-eo", "pid=,pgid=,state=")
	if err != nil {
		return false, err
	}
	pgid := cmd.Process.Pid
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		memberGroup, err := strconv.Atoi(fields[1])
		if err != nil || memberGroup != pgid {
			continue
		}
		state := fields[2]
		if state != "" && state[0] != 'Z' && state[0] != 'X' {
			return true, nil
		}
	}
	return false, nil
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
