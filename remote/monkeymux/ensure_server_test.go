package main

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestReadWriteSessionPIDFileRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("pid-roundtrip-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	if got := readSessionPID(session); got != os.Getpid() {
		t.Fatalf("readSessionPID = %d, want %d", got, os.Getpid())
	}
	removeSessionPIDFile(session)
	if got := readSessionPID(session); got != 0 {
		t.Fatalf("readSessionPID after remove = %d, want 0", got)
	}
}

func TestRemoveSessionPIDFileKeepsOtherOwners(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("pid-other-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()+100000); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	removeSessionPIDFile(session)
	if got := readSessionPID(session); got == 0 {
		t.Fatal("removeSessionPIDFile deleted another process's pid file")
	}
}

func TestAcquireSessionLockSerializesAndClearsStaleLocks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("lock-%d", time.Now().UnixNano())
	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		secondUnlock, err := acquireSessionLock(session)
		if err != nil {
			done <- err
			return
		}
		secondUnlock()
		done <- nil
	}()

	select {
	case err := <-done:
		t.Fatalf("second lock acquired while first held: %v", err)
	case <-time.After(150 * time.Millisecond):
	}

	unlock()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("second lock after unlock: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("second lock did not acquire after unlock")
	}

	lockPath, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.WriteFile(lockPath, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write stale lock: %v", err)
	}
	unlock, err = acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with stale lock: %v", err)
	}
	unlock()
}

func TestEnsureServerRefusesToStealLivePIDWithoutSocket(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("steal-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}

	err := ensureServer(
		session,
		createWindowOptions{command: "copilot --yolo", name: "Copilot CLI"},
		serverUpdatePolicyNever,
		false,
		80,
		24,
		false,
	)
	if err == nil {
		t.Fatal("ensureServer stole a live session pid")
	}
	if !strings.Contains(err.Error(), "not accepting connections") {
		t.Fatalf("ensureServer error = %q, want not-accepting message", err)
	}

	socket, err := socketPath(session)
	if err != nil {
		t.Fatalf("socketPath: %v", err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket path state = %v, want missing", err)
	}
}

func TestPrepareRunningServerReplacementKeepsServerWithoutSnapshot(
	t *testing.T,
) {
	// A version-skewed server that cannot be dialed yields no restore snapshot.
	// Replacement must be refused rather than green-lighting an empty recreate
	// (the lost-windows failure mode after auto-connect attach).
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("nosnap-%d", time.Now().UnixNano())
	outcome, err := prepareRunningServerReplacement(
		session,
		runningServerStatus{
			version: "0.0.1",
			capabilities: []string{
				"shutdown",
				"upgrade-restore-v1",
				"window-list",
			},
		},
		serverUpdatePolicyAlways,
		false,
	)
	if err != nil {
		t.Fatalf("prepareRunningServerReplacement: %v", err)
	}
	if outcome != nil {
		t.Fatalf("replacement = %#v, want nil when snapshot fails", outcome)
	}
}

func TestPrepareRunningServerReplacementNoopsForCurrentVersion(t *testing.T) {
	outcome, err := prepareRunningServerReplacement(
		"current",
		runningServerStatus{version: monkeyMuxVersion},
		serverUpdatePolicyAlways,
		false,
	)
	if err != nil {
		t.Fatalf("prepareRunningServerReplacement: %v", err)
	}
	if outcome != nil {
		t.Fatalf("replacement = %#v, want nil for current version", outcome)
	}
}
