//go:build !windows

package main

import (
	"errors"
	"os"
	"testing"
	"time"
)

func TestRejectedWindowReapsStartedProcess(t *testing.T) {
	before := readProcessTable()
	if before == nil {
		t.Fatal("cannot inspect child processes")
	}
	server := newMuxServer("rejected-process")
	server.close()
	if _, err := server.createWindow(createWindowOptions{args: []string{"/bin/sh", "-c", "sleep 30"}}); !errors.Is(err, errServerClosed) {
		t.Fatalf("createWindow = %v, want errServerClosed", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		processes := readProcessTable()
		if processes == nil {
			t.Fatal("cannot inspect rejected child process")
		}
		var children []int
		for pid, process := range processes {
			// A PTY child starts its own session. Exclude the ps probe itself
			// and children belonging to earlier tests.
			if process.ppid == os.Getpid() && process.pgid == pid {
				if _, existed := before[pid]; !existed {
					children = append(children, pid)
				}
			}
		}
		if len(children) == 0 {
			return
		}
		if time.Now().After(deadline) {
			for _, pid := range children {
				if process, err := os.FindProcess(pid); err == nil {
					_ = process.Kill()
					_, _ = process.Wait()
				}
			}
			t.Fatalf("rejected PTY children were not reaped: %v", children)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
