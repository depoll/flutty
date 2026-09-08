//go:build !windows

package main

import (
	"errors"
	"os"
	"testing"
	"time"
)

func TestRejectedWindowReapsStartedProcess(t *testing.T) {
	for _, command := range []string{"sleep 30", "exit 0"} {
		t.Run(command, func(t *testing.T) { testRejectedWindowReapsStartedProcess(t, command) })
	}
}

func testRejectedWindowReapsStartedProcess(t *testing.T, command string) {
	before := readProcessTable()
	if before == nil {
		t.Fatal("cannot inspect child processes")
	}
	server := newMuxServer("rejected-process")
	server.close()
	start := time.Now()
	window, err := server.createWindow(createWindowOptions{args: []string{"/bin/sh", "-c", command}})
	if !errors.Is(err, errServerClosed) || window != nil {
		t.Fatalf("createWindow = (%v, %v), want (nil, errServerClosed)", window, err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("rejection blocked for %s", elapsed)
	}
	if len(server.windows) != 0 {
		t.Fatal("rejected window was published")
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
			t.Fatalf("rejected PTY children were not reaped: %v", children)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
