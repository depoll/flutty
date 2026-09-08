package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func auditMuxConnection(t *testing.T, server *muxServer) net.Conn {
	t.Helper()
	conn, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.handleConnection(conn)
	}()
	t.Cleanup(func() {
		_ = peer.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("connection handler did not exit")
		}
	})
	_ = peer.SetDeadline(time.Now().Add(3 * time.Second))
	return peer
}

func TestControlHelloAfterShutdownIsRejected(t *testing.T) {
	server := newMuxServer("late-control")
	peer := auditMuxConnection(t, server)
	server.close()
	if _, err := io.WriteString(peer, "{\"role\":\"control\"}\n"); err != nil {
		t.Fatal(err)
	}
	_, err := bufio.NewReader(peer).ReadByte()
	if !errors.Is(err, io.EOF) {
		t.Errorf("late control received %v, want EOF without a hello", err)
	}
	server.mu.Lock()
	count := len(server.controls)
	server.mu.Unlock()
	if count != 0 {
		t.Errorf("closed server registered %d controls", count)
	}
}

func TestMuxHelloRejectsOversizeWithoutWaitingForNewline(t *testing.T) {
	server := newMuxServer("oversized-hello")
	defer server.close()
	peer := auditMuxConnection(t, server)
	// Keep the peer open and omit the delimiter. Draining a rejected frame
	// would let a stalled peer retain the handler indefinitely.
	_, err := io.WriteString(peer, strings.Repeat("x", 1024*1024+8192))
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("oversized hello waited for more bytes instead of closing")
	}
	if _, err := bufio.NewReader(peer).ReadByte(); !errors.Is(err, io.EOF) {
		t.Fatalf("oversized hello read = %v, want EOF", err)
	}
}

func TestMuxHelloPreservesBufferedControlRequest(t *testing.T) {
	server := newMuxServer("buffered-control")
	defer server.close()
	peer := auditMuxConnection(t, server)
	if _, err := io.WriteString(peer, "{\"role\":\"control\"}\n{\"type\":\"ping\",\"id\":\"probe\"}\n"); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(peer)
	for _, want := range []string{"hello", "window_list", "pong"} {
		var response controlResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		if response.Type != want {
			t.Fatalf("response = %q, want %q", response.Type, want)
		}
		if want == "pong" && response.ID != "probe" {
			t.Errorf("pong ID = %q, want probe", response.ID)
		}
	}
}

func TestStartWindowPreservesCommandError(t *testing.T) {
	cmd := exec.Command(filepath.Join(t.TempDir(), "missing-executable"))
	cmd.Err = exec.ErrDot
	pty, process, err := startWindow(cmd, 80, 24)
	if pty != nil || process != nil {
		t.Fatal("invalid command started a PTY or process")
	}
	if !errors.Is(err, exec.ErrDot) {
		t.Fatalf("startWindow error = %v, want exec.ErrDot", err)
	}
}
