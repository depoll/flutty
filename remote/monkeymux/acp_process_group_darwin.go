//go:build darwin

package main

import (
	"os/exec"

	"golang.org/x/sys/unix"
)

// acpProviderProcessGroupHasLiveMember asks the kernel only for this process
// group, avoiding repeated full process-table scans during failed shutdown.
func acpProviderProcessGroupHasLiveMember(cmd *exec.Cmd) (bool, error) {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return false, nil
	}
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.pgrp", cmd.Process.Pid)
	if err != nil {
		return false, err
	}
	const zombieState = 5 // SZOMB from Darwin's sys/proc.h.
	for _, process := range processes {
		if process.Proc.P_stat != zombieState {
			return true, nil
		}
	}
	return false, nil
}
