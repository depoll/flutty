package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestAcpTrimReplayKeepsPendingAndNewestEvents(t *testing.T) {
	for _, test := range []struct {
		name    string
		weights []int
		pending map[int]bool
		want    []uint64
	}{
		{"oldest", []int{20, 20, 20}, nil, []uint64{2, 3}},
		{"pinned gaps", []int{10, 15, 10, 15, 10}, map[int]bool{0: true, 2: true}, []uint64{1, 3, 5}},
		{"only pending", []int{30, 30}, map[int]bool{0: true, 1: true}, []uint64{1, 2}},
		{"one oversized", []int{1, 50}, nil, []uint64{2}},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge := newAuditAcpBridge()
			for i, weight := range test.weights {
				event := acpReplayEvent{
					message: acpWireMessage{Sequence: uint64(i + 1), Data: json.RawMessage(`{"result":{}}`)},
					bytes:   weight * 1024 * 1024,
				}
				if test.pending[i] {
					event.pendingID = "permission"
					event.clientRequest = true
					bridge.pendingReplayEvents++
					bridge.pendingReplayBytes += event.bytes
				}
				bridge.replay = append(bridge.replay, event)
				bridge.replayBytes += event.bytes
			}
			pendingEvents, pendingBytes := bridge.pendingReplayEvents, bridge.pendingReplayBytes
			bridge.trimReplayLocked()
			var got []uint64
			bytes := 0
			for _, event := range bridge.replay {
				got = append(got, event.message.Sequence)
				bytes += event.bytes
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Errorf("retained sequences = %v, want %v", got, test.want)
			}
			if bridge.replayBytes != bytes || bridge.pendingReplayEvents != pendingEvents || bridge.pendingReplayBytes != pendingBytes {
				t.Error("replay accounting changed incorrectly")
			}
			for _, event := range bridge.replay[len(bridge.replay):cap(bridge.replay)] {
				if !reflect.DeepEqual(event, acpReplayEvent{}) {
					t.Error("unused replay capacity retains evicted payloads")
				}
			}
		})
	}
}

func TestAcpTrimReplayDoesNotAllocatePerEviction(t *testing.T) {
	bridge := newAuditAcpBridge()
	seed := []acpReplayEvent{
		{bytes: acpReplayMaxBytes / 2},
		{bytes: acpReplayMaxBytes / 2, pendingID: "permission"},
		{bytes: acpReplayMaxBytes / 2},
	}
	storage := make([]acpReplayEvent, len(seed))
	allocations := testing.AllocsPerRun(100, func() {
		copy(storage, seed)
		bridge.replay = storage
		bridge.replayBytes = 3 * (acpReplayMaxBytes / 2)
		bridge.trimReplayLocked()
	})
	if allocations != 0 {
		t.Errorf("allocations per eviction = %g, want zero", allocations)
	}
}
