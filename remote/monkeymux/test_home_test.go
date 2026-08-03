package main

import (
	"runtime"
	"testing"
)

// setTestHomeDir points os.UserHomeDir at dir for the duration of the test.
//
// os.UserHomeDir reads a different variable per platform (USERPROFILE on
// Windows, HOME elsewhere), so a test that only sets HOME silently keeps
// resolving the real user profile on Windows and reads whatever agent state
// happens to exist there. Setting every variable the lookup consults keeps
// agent-session discovery tests hermetic on all platforms.
func setTestHomeDir(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("HOME", dir)
	if runtime.GOOS == "windows" {
		t.Setenv("USERPROFILE", dir)
	}
}
