//go:build !windows

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestAcpWireFramingRoundTrip(t *testing.T) {
	var buffer bytes.Buffer
	want := acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "input",
		BridgeID: "0123456789abcdef0123456789abcdef",
		Data:     json.RawMessage(`{"jsonrpc":"2.0","method":"session/prompt"}`),
	}
	if err := writeAcpWireFrame(&buffer, want); err != nil {
		t.Fatal(err)
	}
	got, err := readAcpWireFrame(bufio.NewReader(&buffer))
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || got.BridgeID != want.BridgeID ||
		!bytes.Equal(got.Data, want.Data) {
		t.Fatalf("wire frame = %#v, want %#v", got, want)
	}
}

func TestAcpDetachedIdleClientStopsWriter(t *testing.T) {
	server, peer := net.Pipe()
	defer peer.Close()
	client := &acpBridgeClient{
		id:         "client",
		conn:       server,
		send:       make(chan acpWireMessage, 1),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}
	bridge := &acpBridge{
		clients: map[string]*acpBridgeClient{client.id: client},
	}
	go bridge.writeClient(client)

	bridge.detachClient(client.id)

	select {
	case <-client.writerDone:
	case <-time.After(time.Second):
		t.Fatal("idle detached client left its writer goroutine running")
	}
}

func TestAcpProviderExitCancelsDelayedForceStop(t *testing.T) {
	cmd := newAcpProviderCommand("sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	forced := make(chan struct{}, 1)

	stopAcpProviderAfter(cmd, done, 250*time.Millisecond, func(*exec.Cmd) {
		forced <- struct{}{}
	})
	_ = cmd.Wait()
	close(done)

	select {
	case <-forced:
		t.Fatal("force stop ran after the provider had exited")
	case <-time.After(300 * time.Millisecond):
	}
}

func TestAcpBridgeStartConnectListStatusAndStop(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()

	ids, err := listAcpBridgeIDs()
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 1 || ids[0] != bridge.id {
		t.Fatalf("bridge IDs = %#v, want %q", ids, bridge.id)
	}
	status, err := acpBridgeStatus(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	if status.ID != bridge.id || status.State != "running" || status.CommandHash == "" {
		t.Fatalf("status = %#v", status)
	}

	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	hello := readTestAcpFrame(t, reader, conn)
	if hello.Type != "hello" || !hello.CanSend || hello.Bridge == nil {
		t.Fatalf("attach hello = %#v", hello)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "command",
		Command: "stop",
	}); err != nil {
		t.Fatal(err)
	}
	bridge.stop()
	select {
	case <-bridge.done:
	case <-time.After(time.Second):
		t.Fatal("bridge did not stop")
	}
}

func TestAcpReconnectReplaysAfterAck(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`), "", nil)

	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
		LastAck:  1,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn) // hello
	replayed := readTestAcpFrame(t, reader, conn)
	if replayed.Type != "output" || replayed.Sequence != 2 {
		t.Fatalf("replayed event = %#v, want sequence 2", replayed)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "ack",
		Ack:     replayed.Sequence,
	}); err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()

	conn, err = dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
		LastAck:  2,
	}); err != nil {
		t.Fatal(err)
	}
	reader = bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"three"}`), "", nil)
	next := readTestAcpFrame(t, reader, conn)
	if next.Type != "output" || next.Sequence != 3 {
		t.Fatalf("next event = %#v, want sequence 3", next)
	}
}

func TestAcpReplayOverflowSignalsRetainedSequence(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	for range acpReplayMaxEvents + 1 {
		bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`), "", nil)
	}
	conn, err := dialAcpBridge(bridge.id)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "hello",
		BridgeID: bridge.id,
	}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	_ = readTestAcpFrame(t, reader, conn)
	overflow := readTestAcpFrame(t, reader, conn)
	if overflow.Type != "overflow" || overflow.RetainedFrom != 2 {
		t.Fatalf("overflow = %#v, want retained sequence 2", overflow)
	}
}

func TestAcpPendingProviderRequestSurvivesDetachAndBlocksIdleCleanup(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.observeProviderMessage(json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`,
	))
	bridge.mu.Lock()
	bridge.lastActivity = time.Now().Add(-acpIdleTimeout - time.Second)
	pending := len(bridge.pendingRequests)
	bridge.mu.Unlock()
	if pending != 1 {
		t.Fatalf("pending request count = %d, want 1", pending)
	}
	if bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("pending provider request allowed idle shutdown")
	}
}

func TestAcpReplayRetainsPendingProviderRequest(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	permission := json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`,
	)
	bridge.observeProviderMessage(permission)
	bridge.publish("output", permission, "", nil)
	for range acpReplayMaxEvents + 1 {
		bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`), "", nil)
	}
	bridge.mu.Lock()
	found := false
	for _, event := range bridge.replay {
		if event.pendingID == `"permission-1"` &&
			bytes.Equal(event.message.Data, permission) {
			found = true
		}
	}
	bridge.mu.Unlock()
	if !found {
		t.Fatal("pending provider request was evicted from replay")
	}
	bridge.observeClientMessage(json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","result":{"outcome":"selected"}}`,
	))
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.pendingRequests) != 0 {
		t.Fatal("provider request remained pending after its real response")
	}
}

func TestAcpIdleCleanupRequiresTrueIdle(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.mu.Lock()
	bridge.lastActivity = time.Now().Add(-acpIdleTimeout - time.Second)
	bridge.mu.Unlock()
	if !bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("true idle bridge was not eligible for cleanup")
	}
	bridge.mu.Lock()
	bridge.inFlightTurns["turn"] = struct{}{}
	bridge.mu.Unlock()
	if bridge.shouldIdleShutdown(time.Now()) {
		t.Fatal("in-flight turn allowed idle shutdown")
	}
}

func TestAcpProviderExitPublishesExitedState(t *testing.T) {
	dir := testAcpRuntimeDirectory(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"test",
		"exit 7",
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		info := bridge.snapshot()
		if info.State == "exited" {
			if bridge.exitCode == nil || *bridge.exitCode != 7 {
				t.Fatalf("exit code = %#v, want 7", bridge.exitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("provider did not enter exited state")
}

func TestAcpProviderCommandUsesPipesNotTerminal(t *testing.T) {
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"test",
		"test ! -t 0 && test ! -t 1",
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if bridge.snapshot().State == "exited" {
			if bridge.exitCode == nil || *bridge.exitCode != 0 {
				t.Fatalf("non-pipe provider exit = %#v", bridge.exitCode)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("provider did not exit")
}

func startTestAcpBridge(t *testing.T, command string) (*acpBridge, func()) {
	t.Helper()
	dir := testAcpRuntimeDirectory(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	id, err := newAcpBridgeID()
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := newAcpBridge(id, "test", command, ".")
	if err != nil {
		t.Fatal(err)
	}
	errs := make(chan error, 1)
	go func() {
		errs <- serveAcpBridge(bridge)
	}()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if conn, err := dialAcpBridge(id); err == nil {
			_ = conn.Close()
			return bridge, func() {
				bridge.stop()
				select {
				case err := <-errs:
					if err != nil {
						t.Errorf("ACP serve: %v", err)
					}
				case <-time.After(time.Second):
					t.Error("ACP server did not stop")
				}
				_ = os.RemoveAll(dir)
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	bridge.stop()
	t.Fatal("ACP socket did not start")
	return nil, nil
}

func testAcpRuntimeDirectory(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp(".", ".acp-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Clean(dir)
}

func readTestAcpFrame(
	t *testing.T,
	reader *bufio.Reader,
	conn net.Conn,
) acpWireMessage {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	message, err := readAcpWireFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	return message
}
