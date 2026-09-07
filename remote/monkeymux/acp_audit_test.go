package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

func newAuditAcpBridge() *acpBridge {
	return &acpBridge{
		id:                   "0123456789abcdef0123456789abcdef",
		state:                "running",
		clients:              make(map[string]*acpBridgeClient),
		pendingRequests:      make(map[string]struct{}),
		inFlightTurns:        make(map[string]struct{}),
		sessionSetupRequests: make(map[string]string),
		done:                 make(chan struct{}),
	}
}

type auditAcpWriteCloser struct {
	write func([]byte) (int, error)
}

func (w auditAcpWriteCloser) Write(data []byte) (int, error) { return w.write(data) }
func (w auditAcpWriteCloser) Close() error                   { return nil }

func TestAcpAuditFastProviderResponse(t *testing.T) {
	for _, method := range []string{"initialize", "session/new", "session/load", "session/prompt"} {
		t.Run(method, func(t *testing.T) {
			bridge := newAuditAcpBridge()
			var input bytes.Buffer
			bridge.stdin = auditAcpWriteCloser{write: func(data []byte) (int, error) {
				input.Write(data)
				if bytes.Contains(data, []byte{'\n'}) {
					bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","id":1,"result":{"sessionId":"returned-session"}}`), "", nil)
				}
				return len(data), nil
			}}
			status := auditAcpSendAndStatus(t, bridge, json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"`+method+`","params":{"sessionId":"requested-session"}}`))
			if status.InFlightTurn != 0 {
				t.Errorf("completed request still in flight: %d", status.InFlightTurn)
			}
			if isAcpSessionSetupMethod(method) && status.SessionID != "returned-session" {
				t.Errorf("session ID = %q, want provider's returned-session", status.SessionID)
			}
			bridge.mu.Lock()
			defer bridge.mu.Unlock()
			if len(bridge.sessionSetupRequests) != 0 || len(bridge.initializeRequestIDs) != 0 {
				t.Error("completed request retained in tracking maps")
			}
		})
	}
}

func auditAcpSendAndStatus(t *testing.T, bridge *acpBridge, data json.RawMessage) *acpBridgeInfo {
	t.Helper()
	server, peer := net.Pipe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		bridge.handleConnection(server)
	}()
	t.Cleanup(func() {
		peer.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("attach did not exit")
		}
	})
	peer.SetDeadline(time.Now().Add(3 * time.Second))
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "hello"}); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(peer)
	if _, err := readAcpWireFrame(reader); err != nil {
		t.Fatal(err)
	}
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "input", Data: data}); err != nil {
		t.Fatal(err)
	}
	if err := writeAcpWireFrame(peer, acpWireMessage{Version: 1, Type: "status"}); err != nil {
		t.Fatal(err)
	}
	for {
		message, err := readAcpWireFrame(reader)
		if err != nil {
			t.Fatal(err)
		}
		if message.Type == "status" {
			return message.Bridge
		}
	}
}

func TestAcpAuditFailedProviderWriteDoesNotRetainRequest(t *testing.T) {
	for _, method := range []string{"initialize", "session/new", "session/load", "session/prompt"} {
		t.Run(method, func(t *testing.T) {
			bridge := newAuditAcpBridge()
			bridge.sessionID = "existing-session"
			bridge.stdin = auditAcpWriteCloser{write: func([]byte) (int, error) { return 0, io.ErrClosedPipe }}
			status := auditAcpSendAndStatus(t, bridge, json.RawMessage(`{"id":1,"method":"`+method+`","params":{"sessionId":"failed-session"}}`))
			if status.InFlightTurn != 0 || status.SessionID != "existing-session" {
				t.Fatalf("failed write changed metadata: %+v", status)
			}
			bridge.mu.Lock()
			defer bridge.mu.Unlock()
			if len(bridge.sessionSetupRequests) != 0 || len(bridge.initializeRequestIDs) != 0 {
				t.Error("failed write retained request")
			}
		})
	}
}

func TestAcpAuditStopInterruptsBlockedProviderWrite(t *testing.T) {
	input, peer := net.Pipe()
	defer peer.Close()
	bridge := newAuditAcpBridge()
	bridge.stdin = input
	writeDone := make(chan error, 1)
	go func() { writeDone <- bridge.writeProvider(json.RawMessage(`{"method":"notification"}`)) }()
	// The provider never reads. Even if stop wins the scheduling race, the
	// write must fail, rather than prevent stop from closing the pipe.
	select {
	case err := <-writeDone:
		t.Fatalf("write completed before shutdown: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	stopDone := make(chan struct{})
	go func() { bridge.stop(); close(stopDone) }()
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		peer.Close() // Release the original implementation before failing.
		<-stopDone
		t.Error("stop waited for a provider that never reads stdin")
	}
	select {
	case err := <-writeDone:
		if err == nil {
			t.Error("blocked write succeeded after stop")
		}
	case <-time.After(time.Second):
		t.Error("provider write did not unblock")
	}
}

type auditAcpExhaustedReader struct{ readPastLimit bool }

func (r *auditAcpExhaustedReader) Read([]byte) (int, error) {
	r.readPastLimit = true
	return 0, errors.New("provider is still waiting without sending a newline")
}

func TestAcpAuditOversizedFrameDoesNotDrain(t *testing.T) {
	tail := &auditAcpExhaustedReader{}
	reader := bufio.NewReader(io.MultiReader(strings.NewReader(strings.Repeat("x", acpMaxFrameBytes+4096)), tail))
	if _, err := readBoundedAcpLine(reader); err == nil {
		t.Fatal("oversized frame accepted")
	}
	if tail.readPastLimit {
		t.Fatal("oversized frame reader waited for more input instead of rejecting immediately")
	}
}

func TestAcpAuditReplayTrimWithinBudgetDoesNotAllocate(t *testing.T) {
	bridge := newAuditAcpBridge()
	for i := 0; i < 1000; i++ {
		bridge.appendReplayLocked(acpWireMessage{Sequence: uint64(i + 1)}, "")
	}
	if allocations := testing.AllocsPerRun(100, bridge.trimReplayLocked); allocations != 0 {
		t.Fatalf("trimming unchanged replay allocates %.0f times per call", allocations)
	}
}
