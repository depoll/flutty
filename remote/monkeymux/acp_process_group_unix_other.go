//go:build !windows && !linux && !darwin

package main

import (
	"errors"
	"os/exec"
)

func acpProviderProcessGroupHasLiveMember(*exec.Cmd) (bool, error) {
	return false, errors.New("process-group inspection is unavailable")
}
