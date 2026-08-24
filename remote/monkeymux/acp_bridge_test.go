//go:build !windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestStartAcpBridgeInProcessHostsProviderInServer(t *testing.T) {
	dir := testAcpRuntimeDirectory(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	id, err := startAcpBridgeInProcess(
		ctx,
		"test:cat-acp",
		"Test Agent",
		"cat",
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	info, err := acpBridgeStatus(id)
	if err != nil {
		t.Fatal(err)
	}
	if info.ProviderID != "test:cat-acp" || info.State != "running" {
		t.Fatalf("unexpected bridge metadata: %+v", info)
	}

	conn, err := dialAcpBridge(id)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "command",
		Command: "stop",
	}); err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	_ = conn.Close()
}

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

func TestAcpAdaptiveReplayPolicy(t *testing.T) {
	tests := []struct {
		name                  string
		mode                  string
		lastAck               uint64
		replayBytes           int
		replayIncomplete      bool
		containsClientRequest bool
		want                  string
	}{
		{name: "short complete replay stays direct", mode: "adaptive", replayBytes: acpAdaptiveReplayMaxBytes, want: "direct"},
		{name: "large replay becomes pending-only", mode: "adaptive", replayBytes: acpAdaptiveReplayMaxBytes + 1, want: "pending"},
		{name: "incomplete replay becomes pending-only", mode: "adaptive", replayIncomplete: true, want: "pending"},
		{name: "historical client request becomes pending-only", mode: "adaptive", containsClientRequest: true, want: "pending"},
		{name: "explicit pending remains supported", mode: "pending", replayBytes: 1, want: "pending"},
		{name: "nonzero ack always resumes strictly", mode: "adaptive", lastAck: 1, replayBytes: acpReplayMaxBytes, want: ""},
		{name: "unknown mode stays ordinary", mode: "unknown", replayBytes: acpReplayMaxBytes, want: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			hello := acpWireMessage{ReplayMode: test.mode, LastAck: test.lastAck}
			got := replayModeForAttach(
				hello,
				test.replayBytes,
				test.replayIncomplete,
				test.containsClientRequest,
			)
			if got != test.want {
				t.Fatalf("replayModeForAttach() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestAcpResolvedClientRequestRemainsUnsafeForDirectReplay(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`),
		"",
		nil,
	)
	bridge.mu.Lock()
	bridge.releasePendingReplayLocked(`"permission-1"`)
	replay := append([]acpReplayEvent(nil), bridge.replay...)
	bridge.mu.Unlock()

	if len(replay) != 1 || replay[0].pendingID != "" {
		t.Fatalf("resolved replay = %#v, want retained non-pending event", replay)
	}
	if !replayContainsClientRequest(replay) {
		t.Fatal("resolved client request was incorrectly marked safe for direct replay")
	}
}

func TestAcpCachedInitializeResponseAvoidsDuplicateProviderRequest(t *testing.T) {
	bridge := newOrderingTestBridge()
	providerInput := &testWriteCloser{}
	bridge.stdin = providerInput
	firstInitialize := json.RawMessage(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	if _, ok := bridge.trackInitializeRequest(firstInitialize); !ok {
		t.Fatal("first initialize request was not tracked")
	}
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version: acpBridgeProtocolVersion,
				Type:    "hello",
				LastAck: 1,
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("cached initialize attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	if hello := readTestAcpFrame(t, reader, peer); hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	secondInitialize := json.RawMessage(`{"jsonrpc":"2.0","id":"reattach","method":"initialize","params":{}}`)
	if err := writeAcpWireFrame(peer, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "input",
		BridgeID: bridge.id,
		Data:     secondInitialize,
	}); err != nil {
		t.Fatal(err)
	}
	response := readTestAcpFrame(t, reader, peer)
	var envelope struct {
		ID     string `json:"id"`
		Result struct {
			ProtocolVersion int `json:"protocolVersion"`
		} `json:"result"`
	}
	if response.Type != "output" || json.Unmarshal(response.Data, &envelope) != nil ||
		envelope.ID != "reattach" || envelope.Result.ProtocolVersion != 1 {
		t.Fatalf("cached initialize response = %#v / %#v", response, envelope)
	}
	if providerInput.Len() != 0 {
		t.Fatalf("duplicate initialize reached provider: %q", providerInput.String())
	}
}

func TestAcpAttachQueuesHelloBeforeConcurrentLiveEvent(t *testing.T) {
	bridge := newOrderingTestBridge()
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	live := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	if live.Type != "output" || live.Sequence != 1 {
		t.Fatalf("second attach frame = %#v, want live sequence 1", live)
	}
}

func TestAcpAttachQueuesReplayBeforeConcurrentLiveEvent(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`), "", nil)
	bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`), "", nil)
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	frames := []acpWireMessage{
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
		readTestAcpFrame(t, reader, peer),
	}
	if frames[0].Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", frames[0])
	}
	for index, sequence := range []uint64{1, 2, 3} {
		frame := frames[index+1]
		if frame.Type != "output" || frame.Sequence != sequence {
			t.Fatalf(
				"attach frame %d = %#v, want output sequence %d",
				index+1,
				frame,
				sequence,
			)
		}
	}
}

func TestAcpAdaptiveAttachEchoesDirectForSafeShortReplay(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"session/update"}`),
		"",
		nil,
	)
	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				ReplayMode: "adaptive",
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("adaptive direct attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	replayed := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "direct" {
		t.Fatalf("adaptive hello = %#v, want direct replay", hello)
	}
	if replayed.Type != "output" || replayed.Sequence != 1 {
		t.Fatalf("adaptive direct replay = %#v, want output sequence 1", replayed)
	}
}

func TestAcpFreshAttachSkipsHistoricalReplayButKeepsPending(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"historical"}`),
		"",
		nil,
	)
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	primed := make(chan struct{})
	release := make(chan struct{})
	bridge.beforeClientVisible = func() {
		close(primed)
		<-release
	}
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				ReplayMode: "pending",
			},
		)
	}()
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	<-primed
	close(release)

	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
		"",
		nil,
	)

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	pending := readTestAcpFrame(t, reader, peer)
	replayEnd := readTestAcpFrame(t, reader, peer)
	live := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "pending" ||
		hello.Bridge == nil || hello.Bridge.NextSequence != 2 {
		t.Fatalf("fresh attach hello = %#v", hello)
	}
	if pending.Type != "pending" || pending.Sequence != 0 ||
		!bytes.Contains(pending.Data, []byte("session/request_permission")) {
		t.Fatalf("fresh attach pending frame = %#v", pending)
	}
	if replayEnd.Type != "replay_end" || replayEnd.ReplayMode != "pending" {
		t.Fatalf("fresh attach replay end = %#v", replayEnd)
	}
	if live.Type != "output" || live.Sequence != 3 ||
		!bytes.Contains(live.Data, []byte("live")) {
		t.Fatalf("fresh attach live frame = %#v", live)
	}
}

func TestAcpPendingReplayModeRequiresFreshAck(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"one"}`),
		"",
		nil,
	)
	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"two"}`),
		"",
		nil,
	)

	server, peer := net.Pipe()
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{
				Version:    acpBridgeProtocolVersion,
				Type:       "hello",
				LastAck:    1,
				ReplayMode: "pending",
			},
		)
	}()
	defer func() {
		_ = peer.Close()
		select {
		case <-attachDone:
		case <-time.After(time.Second):
			t.Error("non-fresh attach did not stop")
		}
	}()

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	replayed := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" || hello.ReplayMode != "" {
		t.Fatalf("non-fresh hello = %#v, want ordinary replay", hello)
	}
	if replayed.Type != "output" || replayed.Sequence != 2 {
		t.Fatalf("non-fresh replay = %#v, want sequence 2", replayed)
	}
}

func TestAcpAttachPrimesMaximumPinnedReplay(t *testing.T) {
	bridge := newOrderingTestBridge()
	pinnedCount := acpPendingReplayMaxEvents
	for index := range pinnedCount {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission"}`,
			index,
		))
		if !bridge.publish("output", request, "", nil) {
			t.Fatalf("pending request %d was rejected below the limit", index)
		}
	}
	peer, primed, release, attachDone := startPrimedTestAttach(t, bridge)
	defer finishPrimedTestAttach(t, peer, release, attachDone)
	select {
	case <-primed:
	case <-time.After(time.Second):
		t.Fatal("attach blocked while priming pinned replay")
	}

	published := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"live"}`),
			"",
			nil,
		)
		close(published)
	}()
	close(release)
	<-published

	reader := bufio.NewReader(peer)
	hello := readTestAcpFrame(t, reader, peer)
	if hello.Type != "hello" {
		t.Fatalf("first attach frame = %#v, want hello", hello)
	}
	for sequence := uint64(1); sequence <= uint64(pinnedCount+1); sequence++ {
		frame := readTestAcpFrame(t, reader, peer)
		if frame.Type != "output" || frame.Sequence != sequence {
			t.Fatalf(
				"replay frame sequence %d = %#v, want ordered output",
				sequence,
				frame,
			)
		}
	}
}

func TestAcpPublishSerializesSequenceAndClientVisibility(t *testing.T) {
	bridge := newOrderingTestBridge()
	client := &acpBridgeClient{
		id:         "client",
		send:       make(chan acpWireMessage, 2),
		done:       make(chan struct{}),
		writerDone: make(chan struct{}),
	}
	bridge.clients[client.id] = client

	firstVisible := make(chan struct{})
	releaseFirst := make(chan struct{})
	bridge.beforePublishVisible = func(message acpWireMessage) {
		if message.Sequence == 1 {
			close(firstVisible)
			<-releaseFirst
		}
	}

	firstDone := make(chan struct{})
	go func() {
		bridge.publish(
			"output",
			json.RawMessage(`{"jsonrpc":"2.0","method":"first"}`),
			"",
			nil,
		)
		close(firstDone)
	}()
	<-firstVisible

	secondStarted := make(chan struct{})
	secondDone := make(chan struct{})
	go func() {
		close(secondStarted)
		bridge.publish("state", nil, "exited", nil)
		close(secondDone)
	}()
	<-secondStarted
	select {
	case <-secondDone:
		t.Fatal("later publish became visible before the first publish")
	case <-time.After(25 * time.Millisecond):
	}

	close(releaseFirst)
	<-firstDone
	<-secondDone
	first := <-client.send
	second := <-client.send
	if first.Sequence != 1 || second.Sequence != 2 {
		t.Fatalf(
			"client sequence order = %d, %d, want 1, 2",
			first.Sequence,
			second.Sequence,
		)
	}
}

func TestAcpDetachedClientCannotReclaimWriter(t *testing.T) {
	bridge := newOrderingTestBridge()
	if bridge.clientCanSend("detached") {
		t.Fatal("detached client was allowed to send")
	}
	if bridge.writerClientID != "" {
		t.Fatalf("detached client claimed writer role: %q", bridge.writerClientID)
	}
}

func TestAcpBridgeCapturesSessionIdentityForDurableListing(t *testing.T) {
	bridge := newOrderingTestBridge()
	bridge.providerID = "builtin:pi-acp"
	bridge.cwd = "/repo"
	bridge.observeClientMessage(json.RawMessage(
		`{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/repo"}}`,
	))
	bridge.publish("output", json.RawMessage(
		`{"jsonrpc":"2.0","id":7,"result":{"sessionId":"session-7"}}`,
	), "", nil)

	info := bridge.snapshot()
	if info.ProviderID != "builtin:pi-acp" || info.SessionID != "session-7" ||
		info.Cwd != "/repo" {
		t.Fatalf("durable metadata = %#v", info)
	}
}

func TestAcpProviderExitWaitsForFinalOutputDrain(t *testing.T) {
	cmd := newAcpProviderCommand("exit 0")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	bridge := newOrderingTestBridge()
	bridge.cmd = cmd
	bridge.providerDone = make(chan struct{})
	bridge.providerOutputDone = make(chan struct{})

	waitDone := make(chan struct{})
	go func() {
		bridge.waitForProvider()
		close(waitDone)
	}()
	select {
	case <-bridge.providerDone:
	case <-time.After(time.Second):
		t.Fatal("provider process did not exit")
	}

	bridge.mu.Lock()
	replayBeforeDrain := len(bridge.replay)
	bridge.mu.Unlock()
	if replayBeforeDrain != 0 {
		t.Fatal("provider exit was published before stdout finished draining")
	}

	bridge.publish(
		"output",
		json.RawMessage(`{"jsonrpc":"2.0","method":"final"}`),
		"",
		nil,
	)
	close(bridge.providerOutputDone)
	select {
	case <-waitDone:
	case <-time.After(time.Second):
		t.Fatal("provider exit was not published after stdout drained")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.replay) != 2 {
		t.Fatalf("replay length = %d, want final output and exit", len(bridge.replay))
	}
	if bridge.replay[0].message.Type != "output" ||
		bridge.replay[0].message.Sequence != 1 ||
		bridge.replay[1].message.State != "exited" ||
		bridge.replay[1].message.Sequence != 2 {
		t.Fatalf("provider replay order = %#v", bridge.replay)
	}
}

func TestValidateAcpProviderEnvironmentDetectsLockedCursorKeychain(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor keychain error = %v", err)
	}
	if err := validateAcpProviderEnvironment("builtin:other"); err != nil {
		t.Fatalf("other provider inherited Cursor keychain error: %v", err)
	}
	cursorAgentKeychainProbe = func() int { return 44 }
	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); err != nil {
		t.Fatalf("missing Cursor credential was classified as locked: %v", err)
	}
	t.Setenv("CURSOR_API_KEY", "configured")
	cursorAgentKeychainProbe = func() int { return 36 }
	if err := validateAcpProviderEnvironment(cursorAgentAcpProviderID); err != nil {
		t.Fatalf("API-key Cursor launch probed keychain: %v", err)
	}
}

func TestAcpProviderExitDrainsRealPipeBeforePublishingExit(t *testing.T) {
	const outputCount = 300
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"",
		"test",
		`sleep 0.2; i=0; while [ "$i" -lt 300 ]; do printf '{"jsonrpc":"2.0","method":"final/%s"}\n' "$i"; i=$((i+1)); done`,
		".",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.stop()
	bridge.mu.Lock()
	bridge.beforePublishVisible = func(message acpWireMessage) {
		if message.Type == "output" {
			time.Sleep(100 * time.Microsecond)
		}
	}
	bridge.mu.Unlock()

	select {
	case <-bridge.providerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider process did not exit")
	}
	select {
	case <-bridge.providerOutputDone:
	case <-time.After(2 * time.Second):
		t.Fatal("provider output did not finish draining")
	}

	deadline := time.Now().Add(time.Second)
	for {
		bridge.mu.Lock()
		outputs := 0
		for _, event := range bridge.replay {
			if event.message.Type == "output" {
				outputs++
			}
		}
		replay := append([]acpReplayEvent(nil), bridge.replay...)
		bridge.mu.Unlock()
		exitPublished :=
			len(replay) > 0 && replay[len(replay)-1].message.State == "exited"
		if exitPublished {
			if outputs != outputCount {
				t.Fatalf(
					"retained output frames = %d, want %d before exit",
					outputs,
					outputCount,
				)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("provider exit state was not published")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAcpPendingProviderRequestsAreBoundedByCount(t *testing.T) {
	bridge := newOrderingTestBridge()
	for index := range acpPendingReplayMaxEvents {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission"}`,
			index,
		))
		if !bridge.publish("output", request, "", nil) {
			t.Fatalf("pending request %d was rejected below the limit", index)
		}
	}
	overflow := json.RawMessage(
		`{"jsonrpc":"2.0","id":"overflow","method":"session/request_permission"}`,
	)
	if bridge.publish("output", overflow, "", nil) {
		t.Fatal("pending request above the count limit was retained")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.pendingRequests) != acpPendingReplayMaxEvents {
		t.Fatalf(
			"pending request count = %d, want %d",
			len(bridge.pendingRequests),
			acpPendingReplayMaxEvents,
		)
	}
	if bridge.pendingReplayEvents != acpPendingReplayMaxEvents {
		t.Fatalf(
			"pending replay event count = %d, want %d",
			bridge.pendingReplayEvents,
			acpPendingReplayMaxEvents,
		)
	}
}

func TestAcpPendingProviderRequestsAreBoundedByBytes(t *testing.T) {
	bridge := newOrderingTestBridge()
	value := strings.Repeat("x", acpMaxFrameBytes/2)
	rejected := false
	for index := range acpPendingReplayMaxEvents {
		request := json.RawMessage(fmt.Sprintf(
			`{"jsonrpc":"2.0","id":"permission-%d","method":"session/request_permission","params":{"value":"%s"}}`,
			index,
			value,
		))
		if !bridge.publish("output", request, "", nil) {
			rejected = true
			break
		}
	}
	if !rejected {
		t.Fatal("pending request bytes were not bounded")
	}

	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.pendingReplayBytes > acpPendingReplayMaxBytes {
		t.Fatalf(
			"pending replay bytes = %d, limit %d",
			bridge.pendingReplayBytes,
			acpPendingReplayMaxBytes,
		)
	}
	if bridge.pendingReplayEvents >= acpPendingReplayMaxEvents {
		t.Fatal("byte limit did not trigger before the event limit")
	}
}

type testWriteCloser struct {
	bytes.Buffer
}

func (*testWriteCloser) Close() error { return nil }

func newOrderingTestBridge() *acpBridge {
	now := time.Now()
	return &acpBridge{
		id:                   "0123456789abcdef0123456789abcdef",
		state:                "running",
		startedAt:            now,
		lastActivity:         now,
		clients:              map[string]*acpBridgeClient{},
		pendingRequests:      map[string]struct{}{},
		inFlightTurns:        map[string]struct{}{},
		sessionSetupRequests: map[string]struct{}{},
	}
}

func startPrimedTestAttach(
	t *testing.T,
	bridge *acpBridge,
) (net.Conn, <-chan struct{}, chan struct{}, <-chan struct{}) {
	t.Helper()
	server, peer := net.Pipe()
	primed := make(chan struct{})
	release := make(chan struct{})
	bridge.beforeClientVisible = func() {
		close(primed)
		<-release
	}
	attachDone := make(chan struct{})
	go func() {
		defer close(attachDone)
		bridge.handleAttach(
			server,
			bufio.NewReader(server),
			acpWireMessage{Version: acpBridgeProtocolVersion, Type: "hello"},
		)
	}()
	return peer, primed, release, attachDone
}

func finishPrimedTestAttach(
	t *testing.T,
	peer net.Conn,
	release chan struct{},
	attachDone <-chan struct{},
) {
	t.Helper()
	select {
	case <-release:
	default:
		close(release)
	}
	_ = peer.Close()
	select {
	case <-attachDone:
	case <-time.After(time.Second):
		t.Error("primed attach did not stop")
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

func TestAcpProviderReapGateBlocksWaitUntilGroupCleanup(t *testing.T) {
	cmd := newAcpProviderCommand("sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	bridge := newOrderingTestBridge()
	bridge.cmd = cmd
	bridge.providerDone = make(chan struct{})
	bridge.providerOutputDone = make(chan struct{})
	bridge.providerReapReady = make(chan struct{})
	close(bridge.providerOutputDone)

	go bridge.waitForProvider()
	select {
	case <-bridge.providerDone:
		t.Fatal("provider was reaped while its process group was still live")
	case <-time.After(50 * time.Millisecond):
	}

	bridge.stopProviderProcess()
	select {
	case <-bridge.providerDone:
	case <-time.After(time.Second):
		t.Fatal("provider was not reaped after group cleanup opened the gate")
	}
}

func TestAcpProviderExitCancelsDelayedForceStop(t *testing.T) {
	cmd := newAcpProviderCommand("sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	forced := make(chan struct{}, 1)

	stopAcpProviderAfter(cmd, nil, 250*time.Millisecond, func(*exec.Cmd) {
		forced <- struct{}{}
	})
	_ = cmd.Wait()

	select {
	case <-forced:
		t.Fatal("force stop ran after the provider had exited")
	default:
	}
}

func TestAcpProviderWrapperExitStillForcesSurvivingProcessGroup(t *testing.T) {
	readyPath := filepath.Join(t.TempDir(), "child-ready")
	cmd := newAcpProviderCommand(fmt.Sprintf( // nosemgrep
		"trap 'exit 0' TERM; "+
			"(trap '' TERM; : > %q; while :; do sleep 1; done) & wait",
		readyPath,
	))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	forced := make(chan struct{}, 1)
	leaderReservedBeforeForce := false
	readyDeadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(readyPath); err == nil {
			break
		}
		if time.Now().After(readyDeadline) {
			forceStopAcpProvider(cmd)
			_ = cmd.Wait()
			t.Fatal("TERM-ignoring provider child did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}

	stopAcpProviderAfter(cmd, nil, 100*time.Millisecond, func(cmd *exec.Cmd) {
		snapshot := inspectProcess(cmd.Process.Pid)
		leaderReservedBeforeForce = snapshot.known && !snapshot.running &&
			syscall.Kill(-cmd.Process.Pid, 0) == nil
		forced <- struct{}{}
		forceStopAcpProvider(cmd)
	})

	select {
	case <-forced:
	default:
		t.Fatal("wrapper exit skipped force-stop for a surviving process group")
	}
	if !leaderReservedBeforeForce {
		t.Fatal("provider group leader was not an unreaped zombie before force-stop")
	}
	deadline := time.Now().Add(time.Second)
	groupStopped := false
	for time.Now().Before(deadline) {
		live, err := acpProviderProcessGroupHasLiveMember(cmd)
		if err == nil && !live {
			groupStopped = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = cmd.Wait()
	if !groupStopped {
		t.Fatal("provider process group survived force-stop")
	}
}

func TestAcpConcurrentStopAndProviderWrite(t *testing.T) {
	providerInput, peer := net.Pipe()
	defer peer.Close()
	bridge := &acpBridge{
		stdin:        providerInput,
		clients:      map[string]*acpBridgeClient{},
		providerDone: make(chan struct{}),
		done:         make(chan struct{}),
	}
	payload := json.RawMessage(`{"jsonrpc":"2.0","method":"session/prompt"}`)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		_ = bridge.writeProvider(payload)
	}()

	// net.Pipe writes block until the peer reads, deterministically overlapping
	// the provider write with stop's attempt to close stdin.
	select {
	case <-writerDone:
		t.Fatal("provider write unexpectedly completed before peer read")
	case <-time.After(20 * time.Millisecond):
	}
	stopDone := make(chan struct{})
	go func() {
		bridge.stop()
		close(stopDone)
	}()
	got := make([]byte, len(payload)+1)
	if _, err := io.ReadFull(peer, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, append(append([]byte(nil), payload...), '\n')) {
		t.Fatalf("provider input = %q", got)
	}

	select {
	case <-writerDone:
	case <-time.After(time.Second):
		t.Fatal("provider write did not finish after peer read")
	}
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("provider stop did not finish after write")
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

func TestAcpReplayRetainsManyTinyStreamingUpdates(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	const updates = 4096
	for range updates {
		bridge.publish("output", json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`), "", nil)
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.replay) != updates || bridge.replay[0].message.Sequence != 1 {
		t.Fatalf("retained replay = %d events from %d, want %d events from 1", len(bridge.replay), bridge.replay[0].message.Sequence, updates)
	}
}

func TestAcpReplayOverflowSignalsRetainedSequence(t *testing.T) {
	bridge, cleanup := startTestAcpBridge(t, "cat")
	defer cleanup()
	bridge.mu.Lock()
	bridge.nextSequence = 2
	bridge.appendReplayLocked(acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "output",
		BridgeID: bridge.id,
		Sequence: 2,
		Data:     json.RawMessage(`{"jsonrpc":"2.0","method":"update"}`),
	}, "")
	bridge.mu.Unlock()
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
	bridge.publish("output", json.RawMessage(
		`{"jsonrpc":"2.0","id":"permission-1","method":"session/request_permission"}`,
	), "", nil)
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
	bridge.publish("output", permission, "", nil)
	bridge.mu.Lock()
	bridge.replay = append(bridge.replay, acpReplayEvent{
		message: acpWireMessage{Sequence: 2},
		bytes:   acpReplayMaxBytes,
	})
	bridge.replayBytes += acpReplayMaxBytes
	bridge.trimReplayLocked()
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

func TestCursorAcpProviderRejectsLockedKeychainBeforeLaunch(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		cursorAgentAcpProviderID,
		"Cursor Agent",
		"exit 0",
		".",
	)
	if bridge != nil || !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor bridge = %#v, %v", bridge, err)
	}
}

func TestStartAcpBridgePreservesLockedKeychainError(t *testing.T) {
	originalGOOS := acpRuntimeGOOS
	originalProbe := cursorAgentKeychainProbe
	t.Cleanup(func() {
		acpRuntimeGOOS = originalGOOS
		cursorAgentKeychainProbe = originalProbe
	})
	t.Setenv("CURSOR_API_KEY", "")
	t.Setenv("AGENT_CLI_CREDENTIAL_STORE", "")
	acpRuntimeGOOS = "darwin"
	cursorAgentKeychainProbe = func() int { return 36 }

	bridgeID, err := startAcpBridgeInProcess(
		context.Background(),
		cursorAgentAcpProviderID,
		"Cursor Agent",
		"exit 0",
		".",
	)
	if bridgeID != "" || !errors.Is(err, errCursorAgentKeychainLocked) {
		t.Fatalf("locked Cursor start = %q, %v", bridgeID, err)
	}
}

func TestAcpProviderExitPublishesExitedState(t *testing.T) {
	dir := testAcpRuntimeDirectory(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	bridge, err := newAcpBridge(
		"0123456789abcdef0123456789abcdef",
		"",
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
		"",
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

func TestReplayHasGapIncludesTrailingHighWaterGap(t *testing.T) {
	replay := []acpReplayEvent{
		{message: acpWireMessage{Sequence: 3}},
		{message: acpWireMessage{Sequence: 4}},
	}
	if !replayHasGap(replay, 2, 6) {
		t.Fatal("expected missing trailing sequences 5-6 to be reported")
	}
	if replayHasGap(replay, 2, 4) {
		t.Fatal("contiguous replay through high-water was reported as incomplete")
	}
}

func TestReadProviderOutputFailsMalformedAndOversizedFrames(t *testing.T) {
	for _, test := range []struct {
		name   string
		output string
	}{
		{name: "malformed", output: "not-json\n"},
		{name: "oversized", output: strings.Repeat("x", acpMaxFrameBytes+1) + "\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge := &acpBridge{
				state:        "running",
				providerDone: make(chan struct{}),
			}
			bridge.readProviderOutput(strings.NewReader(test.output))
			if bridge.state != "protocol_error" {
				t.Fatalf("state = %q, want protocol_error", bridge.state)
			}
			if len(bridge.replay) != 1 || bridge.replay[0].message.State != "protocol_error" {
				t.Fatalf("protocol failure replay = %#v", bridge.replay)
			}
		})
	}
}

func startTestAcpBridge(t *testing.T, command string) (*acpBridge, func()) {
	t.Helper()
	dir := testAcpRuntimeDirectory(t)
	t.Setenv("XDG_RUNTIME_DIR", dir)
	id, err := newAcpBridgeID()
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := newAcpBridge(id, "", "test", command, ".")
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
