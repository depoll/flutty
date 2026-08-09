package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
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

// startForeignProcess starts a long-lived process that is not a MonkeyMux
// helper, so tests can exercise the recycled-pid paths with a pid that really
// is alive on this host.
func startForeignProcess(t *testing.T) int {
	t.Helper()
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.Command("ping", "-n", "120", "127.0.0.1")
	} else {
		cmd = exec.Command("sleep", "120")
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start helper process: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	return cmd.Process.Pid
}

func TestLiveSessionServerPIDRecordKeepsCurrentOwner(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("owner-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	owner := liveSessionServerPIDRecord(session)
	if owner.pid != os.Getpid() {
		t.Fatalf("owner pid = %d, want %d", owner.pid, os.Getpid())
	}
}

func TestLiveSessionServerPIDRecordClearsDeadOwner(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("dead-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	if owner := liveSessionServerPIDRecord(session); owner.pid != 0 {
		t.Fatalf("owner pid = %d, want 0 for a dead process", owner.pid)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
}

// A pid file that outlives its server (SIGKILL, crash, host reboot) must not
// permanently block the session once the operating system hands that pid to an
// unrelated process. Otherwise every attach falls back to a login shell with
// "is running (pid N) but not accepting connections".
func TestLiveSessionServerPIDRecordClearsRecycledPID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("recycled-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(recycledPIDFileContents()), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	agePIDFileBeforeThisProcess(t, path)
	if owner := liveSessionServerPIDRecord(session); owner.pid != 0 {
		t.Fatalf("owner pid = %d, want 0 for a recycled pid", owner.pid)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
}

// Pid files written before identities were recorded carry only a number, so a
// recycled pid is detected by checking the running process image instead.
func TestLiveSessionServerPIDRecordClearsLegacyForeignPID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("legacy-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	foreign := startForeignProcess(t)
	contents := fmt.Sprintf("%d\n", foreign)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	if owner := liveSessionServerPIDRecord(session); owner.pid != 0 {
		t.Fatalf("owner pid = %d, want 0 for a foreign process", owner.pid)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("pid file state = %v, want removed", err)
	}
}

func TestEnsureServerClearsRecycledPIDInsteadOfFailing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("recycled-ensure-%d", time.Now().UnixNano())
	path, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(recycledPIDFileContents()), 0o600); err != nil {
		t.Fatalf("write pid file: %v", err)
	}
	agePIDFileBeforeThisProcess(t, path)

	// ensureServer spawns a real helper here, which the sandboxed test host may
	// refuse; only the refusal-to-start path is asserted.
	err = ensureServer(
		session,
		createWindowOptions{},
		serverUpdatePolicyNever,
		false,
		80,
		24,
		false,
	)
	if err != nil && strings.Contains(err.Error(), "not accepting connections") {
		t.Fatalf("ensureServer refused to start because of a recycled pid: %v", err)
	}
	requestServerShutdown(session)

	// The recycled record must be gone either way, so a helper that never gets
	// as far as spawning still recovers on the next attempt.
	if record, readErr := readPIDRecord(path); readErr == nil &&
		record.pid == os.Getpid() &&
		record.writtenAt.Before(time.Now().Add(-time.Hour)) {
		t.Fatal("ensureServer kept the recycled pid record")
	}
}

func TestAcquireSessionLockClearsLockHeldByRecycledPID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("lock-recycled-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(recycledPIDFileContents()), 0o600); err != nil {
		t.Fatalf("write lock file: %v", err)
	}
	agePIDFileBeforeThisProcess(t, path)

	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with recycled pid lock: %v", err)
	}
	unlock()
}

func TestAcquireSessionLockClearsAbandonedUnparseableLock(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("lock-corrupt-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("write lock file: %v", err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	unlock, err := acquireSessionLock(session)
	if err != nil {
		t.Fatalf("acquireSessionLock with abandoned lock: %v", err)
	}
	unlock()
}

func TestGCKeepsPIDAndLockFilesOfLiveOwners(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("gc-%d", time.Now().UnixNano())
	if err := writeSessionPIDFile(session, os.Getpid()); err != nil {
		t.Fatalf("writeSessionPIDFile: %v", err)
	}
	pidPath, err := sessionPIDPath(session)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}

	dead := fmt.Sprintf("gc-dead-%d", time.Now().UnixNano())
	deadPath, err := sessionPIDPath(dead)
	if err != nil {
		t.Fatalf("sessionPIDPath: %v", err)
	}
	if err := os.WriteFile(deadPath, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write dead pid file: %v", err)
	}

	gcCommand()

	if _, err := os.Stat(pidPath); err != nil {
		t.Fatalf("gc removed the pid file of a live owner: %v", err)
	}
	if _, err := os.Stat(deadPath); !os.IsNotExist(err) {
		t.Fatalf("gc kept a dead pid file: %v", err)
	}
}

func TestGCKeepsInFlightRestoreSnapshots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("restore-gc-%d", time.Now().UnixNano())
	fresh, err := writeRestoreFile(session, &serverRestore{})
	if err != nil {
		t.Fatalf("writeRestoreFile: %v", err)
	}
	abandoned, err := writeRestoreFile(session, &serverRestore{})
	if err != nil {
		t.Fatalf("writeRestoreFile: %v", err)
	}
	old := time.Now().Add(-2 * abandonedRestoreFileAge)
	if err := os.Chtimes(abandoned, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	gcCommand()

	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("gc removed an in-flight restore snapshot: %v", err)
	}
	if _, err := os.Stat(abandoned); !os.IsNotExist(err) {
		t.Fatalf("gc kept an abandoned restore snapshot: %v", err)
	}
}

// recycledPIDFileContents names this process, which is alive but is not the
// process that wrote the file in the scenario under test.
func recycledPIDFileContents() string {
	return fmt.Sprintf("%d\n", os.Getpid())
}

// agePIDFileBeforeThisProcess backdates a session file so it predates the
// process it names. That is what a recycled pid looks like: the file was
// written by a server that has since died, and the pid now belongs to a
// process that started later.
func agePIDFileBeforeThisProcess(t *testing.T, path string) {
	t.Helper()
	old := time.Now().Add(-24 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
}

// Reclaiming a stale session file must not be able to unlink a file that
// another helper has already taken over, or two helpers would hold the same
// session lock at once and could both start a server for it.
func TestAcquireSessionLockIsExclusiveUnderContention(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_RUNTIME_DIR", "")

	session := fmt.Sprintf("lock-race-%d", time.Now().UnixNano())
	path, err := sessionLockPath(session)
	if err != nil {
		t.Fatalf("sessionLockPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Seed a stale lock so every contender races through the reclaim path.
	if err := os.WriteFile(path, []byte("99999999\n"), 0o600); err != nil {
		t.Fatalf("write stale lock: %v", err)
	}

	const (
		contenders = 4
		rounds     = 3
	)
	var (
		mu        sync.Mutex
		held      int
		conflicts int
		wg        sync.WaitGroup
	)
	for i := 0; i < contenders; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for r := 0; r < rounds; r++ {
				unlock, err := acquireSessionLock(session)
				if err != nil {
					t.Errorf("acquireSessionLock: %v", err)
					return
				}
				mu.Lock()
				held++
				if held > 1 {
					conflicts++
				}
				mu.Unlock()
				mu.Lock()
				held--
				mu.Unlock()
				unlock()
			}
		}()
	}
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if conflicts > 0 {
		t.Fatalf("session lock was held by more than one holder %d times", conflicts)
	}
}
