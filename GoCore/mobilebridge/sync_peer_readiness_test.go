// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

type syncPeerFixture struct {
	core      *Core
	folderID  string
	remoteID  protocol.DeviceID
	connected *atomic.Bool
	source    *fakeSyncPeerReadinessSource
}

type syncReadinessKey struct {
	device protocol.DeviceID
	folder string
}

type fakeSyncPeerReadinessSource struct {
	mu     sync.RWMutex
	states map[syncReadinessKey]model.RemoteIndexReadiness
	err    error
}

func TestSyncDoesNotSucceedBeforeConfiguredPeerFirstHandshake(t *testing.T) {
	fixture := newPhase3Fixture(t)
	remoteID := protocol.NewDeviceID([]byte("sync offline unverified peer")).String()
	assertCommandOK(t, fixture.core, commandForTest(
		"sync-offline-add-device",
		"addDevice",
		"",
		remoteID,
		map[string]string{"name": "Offline Peer"},
	))
	assertCommandOK(t, fixture.core, commandForTest(
		"sync-offline-share-folder",
		"editFolder",
		fixture.folderID,
		"",
		map[string]string{"deviceIDs": remoteID},
	))

	started := time.Now()
	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-offline-bounded-run",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "100", "settleMS": "1"},
	)))
	assertEnvelopeErrorCode(t, envelope, "sync_incomplete")
	if envelope.Error.Message != "bounded sync run ended with folder progress incomplete or configured peer state offline-unverified" {
		t.Fatalf("offline bounded sync returned an unstable explanation: %q", envelope.Error.Message)
	}
	if elapsed := time.Since(started); elapsed < 80*time.Millisecond || elapsed > time.Second {
		t.Fatalf("offline bounded sync did not honor its deadline: %s", elapsed)
	}
}

func TestSyncWaitsForConnectionAndAuthoritativeRemoteIndexProof(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	started := make(chan struct{})
	fixture.core.syncLoopStartedForTests = started
	response := make(chan string, 1)
	go func() {
		response <- fixture.core.CommandJSON(commandForTest(
			"sync-peer-handshake",
			"sync",
			fixture.folderID,
			"",
			map[string]string{"timeoutMS": "1000", "settleMS": "50"},
		))
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("sync slice did not start")
	}

	select {
	case raw := <-response:
		t.Fatalf("sync returned before the peer connected: %s", raw)
	case <-time.After(75 * time.Millisecond):
	}

	fixture.connect()
	select {
	case raw := <-response:
		t.Fatalf("sync returned on connection alone: %s", raw)
	case <-time.After(75 * time.Millisecond):
	}

	fixture.setState(model.RemoteIndexProofPending)
	select {
	case raw := <-response:
		t.Fatalf("sync returned before the authoritative proof became current: %s", raw)
	case <-time.After(75 * time.Millisecond):
	}

	currentAt := time.Now()
	fixture.setState(model.RemoteIndexProofCurrent)
	select {
	case raw := <-response:
		envelope := decodeTestEnvelope(t, raw)
		if !envelope.OK {
			t.Fatalf("sync did not settle after authoritative proof: %+v", envelope.Error)
		}
		if elapsed := time.Since(currentAt); elapsed < 35*time.Millisecond {
			t.Fatalf("sync skipped its settle interval after proof became current: %s", elapsed)
		}
	case <-time.After(time.Second):
		t.Fatal("sync did not settle after authoritative proof")
	}
}

func TestSyncReconnectRequiresNewCurrentProof(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	fixture.connect()
	fixture.setState(model.RemoteIndexProofCurrent)
	if !fixture.core.runtime.syncPeerReadiness.ready(fixture.remoteID, fixture.folderID) {
		t.Fatal("current direct proof was not ready")
	}

	fixture.disconnect()
	if fixture.core.runtime.syncPeerReadiness.ready(fixture.remoteID, fixture.folderID) {
		t.Fatal("fixture retained proof after receive-primary loss")
	}
	fixture.connect()
	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-peer-reconnected-without-proof",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "100", "settleMS": "1"},
	)))
	assertEnvelopeErrorCode(t, envelope, "sync_incomplete")
}

func TestSyncCompletesForAlreadyIndexedNoChangeReconnect(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	fixture.connect()
	fixture.setState(model.RemoteIndexProofCurrent)
	fixture.disconnect()
	fixture.connect()
	// This simulates the new model connection epoch publishing a direct,
	// exact no-change proof without relying on a RemoteIndexUpdated event.
	fixture.setState(model.RemoteIndexProofCurrent)

	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-peer-already-indexed-reconnect",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "500", "settleMS": "1"},
	)))
	if !envelope.OK {
		t.Fatalf("already-indexed no-change reconnect did not settle: %+v", envelope.Error)
	}
}

func TestSyncClassifiesUnprovableGCTailGap(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	fixture.connect()
	fixture.setState(model.RemoteIndexProofPending)
	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-peer-gc-tail-gap",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "100", "settleMS": "1"},
	)))
	assertEnvelopeErrorCode(t, envelope, "peer_index_proof_unavailable")
}

func TestSyncLifecycleBlockRemainsRetryableIncomplete(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	fixture.connect()
	fixture.setState(model.RemoteIndexProofMissing)
	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-peer-lifecycle-block",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "100", "settleMS": "1"},
	)))
	assertEnvelopeErrorCode(t, envelope, "sync_incomplete")
}

func TestSyncReadinessSourceErrorFailsClosed(t *testing.T) {
	fixture := newSyncPeerFixture(t)
	fixture.connect()
	fixture.source.setError(errors.New("direct proof unavailable"))
	if fixture.core.runtime.syncPeerReadiness.ready(fixture.remoteID, fixture.folderID) {
		t.Fatal("direct readiness source error did not fail closed")
	}
	envelope := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"sync-peer-source-error",
		"sync",
		fixture.folderID,
		"",
		map[string]string{"timeoutMS": "100", "settleMS": "1"},
	)))
	assertEnvelopeErrorCode(t, envelope, "sync_incomplete")
}

func TestSyncReadinessUsesDirectSource(t *testing.T) {
	remoteID := protocol.NewDeviceID([]byte("direct readiness source peer"))
	const folderID = "direct-readiness"
	source := &fakeSyncPeerReadinessSource{
		states: map[syncReadinessKey]model.RemoteIndexReadiness{},
	}
	readiness := newSyncPeerReadiness(source)
	if readiness.ready(remoteID, folderID) {
		t.Fatal("missing direct proof was ready")
	}
	source.set(remoteID, folderID, model.RemoteIndexReadiness{
		State:             model.RemoteIndexProofCurrent,
		ConnectionEpoch:   2,
		AnnouncedIndexID:  71,
		AnnouncedSequence: 18,
		StoredIndexID:     71,
		StoredSequence:    18,
	})
	if !readiness.ready(remoteID, folderID) {
		t.Fatal("current direct proof was not ready")
	}
	source.set(remoteID, folderID, model.RemoteIndexReadiness{State: model.RemoteIndexProofMissing})
	if readiness.ready(remoteID, folderID) {
		t.Fatal("direct source invalidation left stale readiness")
	}
}

func newSyncPeerFixture(t *testing.T) syncPeerFixture {
	t.Helper()
	appGroup := t.TempDir()
	folderPath := filepath.Join(appGroup, "Shared")
	if err := os.MkdirAll(folderPath, 0o700); err != nil {
		t.Fatal(err)
	}
	core, err := NewCore(filepath.Join(appGroup, "Core"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	remoteID := protocol.NewDeviceID([]byte("sync verified peer"))
	assertCommandOK(t, core, commandForTest(
		"sync-verified-add-device",
		"addDevice",
		"",
		remoteID.String(),
		map[string]string{"name": "Verified Peer"},
	))
	folderID := "sync-verified-folder"
	assertCommandOK(t, core, commandForTest(
		"sync-verified-add-folder",
		"addFolder",
		folderID,
		"",
		map[string]string{
			"path":      folderPath,
			"type":      "sendReceive",
			"deviceIDs": remoteID.String(),
		},
	))
	connected := &atomic.Bool{}
	source := &fakeSyncPeerReadinessSource{
		states: make(map[syncReadinessKey]model.RemoteIndexReadiness),
	}
	core.runtime.syncPeerReadiness.source = source
	core.syncPeerConnectedForTests = func(candidate protocol.DeviceID) bool {
		return candidate == remoteID && connected.Load()
	}
	return syncPeerFixture{
		core:      core,
		folderID:  folderID,
		remoteID:  remoteID,
		connected: connected,
		source:    source,
	}
}

func (f syncPeerFixture) connect() {
	f.connected.Store(true)
}

func (f syncPeerFixture) disconnect() {
	f.connected.Store(false)
	f.setState(model.RemoteIndexProofMissing)
}

func (f syncPeerFixture) setState(state model.RemoteIndexReadinessState) {
	f.source.set(f.remoteID, f.folderID, model.RemoteIndexReadiness{State: state})
}

func (s *fakeSyncPeerReadinessSource) RemoteIndexReadiness(device protocol.DeviceID, folder string) (model.RemoteIndexReadiness, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.err != nil {
		return model.RemoteIndexReadiness{}, s.err
	}
	readiness, ok := s.states[syncReadinessKey{device: device, folder: folder}]
	if !ok {
		return model.RemoteIndexReadiness{State: model.RemoteIndexProofMissing}, nil
	}
	return readiness, nil
}

func (s *fakeSyncPeerReadinessSource) set(device protocol.DeviceID, folder string, readiness model.RemoteIndexReadiness) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.states[syncReadinessKey{device: device, folder: folder}] = readiness
}

func (s *fakeSyncPeerReadinessSource) setError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.err = err
}
