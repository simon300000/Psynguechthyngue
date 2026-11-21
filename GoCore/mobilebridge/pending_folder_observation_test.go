// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestPendingFolderObservationSessionValidationPlanAndFiniteCap(t *testing.T) {
	if got, want := pendingFolderObservationSessionPlanDigest(
		"task", "folder", "device", strings.Repeat("0", 64), "0",
	), "a9e4de03dcb281f56bbc648351892bdfb7841de76804b9e9b3ccda22485ccef7"; got != want {
		t.Fatalf("pending folder observation plan digest ABI = %s, want %s", got, want)
	}
	deviceID := protocol.NewDeviceID([]byte("pending observation validation peer"))
	revision := strings.Repeat("a", 64)
	request := commandRequest{
		SessionID:                     "observation-session",
		FolderID:                      "offered-folder",
		OfferingDeviceID:              deviceID.String(),
		TaskID:                        "observe-offer",
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "8388608",
	}
	request.PlanDigest = pendingFolderObservationSessionPlanDigest(
		request.TaskID,
		request.FolderID,
		request.OfferingDeviceID,
		request.ExpectedConfigurationRevision,
		request.MaximumNetworkBytes,
	)
	descriptor, validationErr := validateOpenSessionCommand(request, sessionModePendingFolderObservation)
	if validationErr != nil || descriptor.Mode != sessionModePendingFolderObservation || descriptor.OfferingDeviceID != deviceID.String() {
		t.Fatalf("valid observation session rejected: descriptor=%+v err=%+v", descriptor, validationErr)
	}

	for name, maximum := range map[string]string{
		"unlimited":    "unlimited",
		"too-large":    "8388609",
		"leading-zero": "01",
		"missing":      "",
	} {
		t.Run(name, func(t *testing.T) {
			candidate := request
			candidate.MaximumNetworkBytes = maximum
			candidate.PlanDigest = pendingFolderObservationSessionPlanDigest(candidate.TaskID, candidate.FolderID, candidate.OfferingDeviceID, candidate.ExpectedConfigurationRevision, maximum)
			if _, err := validateOpenSessionCommand(candidate, sessionModePendingFolderObservation); err == nil || err.Code != "invalid_session" {
				t.Fatalf("maximumNetworkBytes %q was accepted: %+v", maximum, err)
			}
		})
	}
	if request.PlanDigest == pendingFolderObservationSessionPlanDigest(request.TaskID, request.FolderID, protocol.NewDeviceID([]byte("other observation peer")).String(), revision, request.MaximumNetworkBytes) {
		t.Fatal("observation plan digest did not bind the offering device")
	}

	core := &Core{session: &descriptor}
	if err := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "sync",
		SessionID:                     descriptor.SessionID,
		TaskID:                        descriptor.TaskID,
		PlanDigest:                    descriptor.PlanDigest,
		ExpectedConfigurationRevision: descriptor.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           descriptor.MaximumNetworkBytes,
		FolderID:                      descriptor.FolderID,
	}); err == nil || err.Code != "wrong_session_mode" {
		t.Fatalf("observation session accepted sync: %+v", err)
	}
	if err := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "capturePendingFolderObservation",
		SessionID:                     descriptor.SessionID,
		TaskID:                        descriptor.TaskID,
		PlanDigest:                    descriptor.PlanDigest,
		ExpectedConfigurationRevision: descriptor.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           descriptor.MaximumNetworkBytes,
		FolderID:                      descriptor.FolderID,
		OfferingDeviceID:              protocol.NewDeviceID([]byte("wrong capture peer")).String(),
	}); err == nil || err.Code != "session_scope_mismatch" {
		t.Fatalf("observation session accepted an out-of-scope capture: %+v", err)
	}
}

func TestDerivePendingFolderObservationConfigurationIsZeroFolderTargetOnlyAndCanonicalPure(t *testing.T) {
	localID := protocol.NewDeviceID([]byte("pending observation local"))
	targetID := protocol.NewDeviceID([]byte("pending observation target"))
	otherID := protocol.NewDeviceID([]byte("pending observation unrelated"))
	canonical := config.New(localID)
	canonical.SetDevice(config.DeviceConfiguration{
		DeviceID:          targetID,
		Name:              "Target",
		Addresses:         []string{"tcp://127.0.0.1:22000"},
		AutoAcceptFolders: true,
		Introducer:        true,
	})
	canonical.SetDevice(config.DeviceConfiguration{DeviceID: otherID, Name: "Unrelated"})
	canonical.Folders = append(canonical.Folders, config.FolderConfiguration{ID: "canonical-folder", Path: t.TempDir()})
	before, err := json.Marshal(canonical)
	if err != nil {
		t.Fatal(err)
	}

	effective, deriveErr := deriveEffectivePendingFolderObservationConfiguration(canonical, sessionDescriptor{
		FolderID:         "unknown-folder",
		OfferingDeviceID: targetID.String(),
	}, localID)
	if deriveErr != nil {
		t.Fatal(deriveErr)
	}
	after, err := json.Marshal(canonical)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, before) {
		t.Fatal("deriving observation configuration mutated the canonical value")
	}
	if len(effective.Folders) != 0 {
		t.Fatalf("observation effective configuration retained folders: %+v", effective.Folders)
	}
	if len(effective.Devices) != 2 {
		t.Fatalf("observation effective configuration retained unrelated devices: %+v", effective.Devices)
	}
	target, _, ok := effective.Device(targetID)
	if !ok || target.Paused || target.AutoAcceptFolders || target.Introducer {
		t.Fatalf("target observation device policy is unsafe: %+v", target)
	}
	if _, _, ok := effective.Device(otherID); ok {
		t.Fatal("unrelated device remained in observation effective configuration")
	}

	paused := canonical.Copy()
	target.Paused = true
	paused.SetDevice(target)
	if _, err := deriveEffectivePendingFolderObservationConfiguration(paused, sessionDescriptor{FolderID: "unknown-folder", OfferingDeviceID: targetID.String()}, localID); err == nil || err.Code != "device_paused" {
		t.Fatalf("paused target was accepted: %+v", err)
	}
	if _, err := deriveEffectivePendingFolderObservationConfiguration(canonical, sessionDescriptor{FolderID: "canonical-folder", OfferingDeviceID: targetID.String()}, localID); err == nil || err.Code != "folder_state_conflict" {
		t.Fatalf("configured folder was accepted as pending: %+v", err)
	}
}

func TestPendingFolderObservationProofStoreDurabilityIntegrityTTLAndNoFollow(t *testing.T) {
	home := t.TempDir()
	store, err := loadPendingFolderObservationProofStore(home)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Add(-time.Second)
	store.now = func() time.Time { return now }
	proof := pendingFolderObservationProofForTest(now, protocol.NewDeviceID([]byte("proof store offering device")), "proof-folder", strings.Repeat("b", 64), "proof-session")
	if err := store.put(proof); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(store.path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("proof store mode is unsafe: info=%+v err=%v", info, err)
	}
	data, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("raw-connection-secret")) {
		t.Fatal("proof store exposed a raw connection ID")
	}

	reloaded, err := loadPendingFolderObservationProofStore(home)
	if err != nil {
		t.Fatal(err)
	}
	reloaded.now = func() time.Time { return now.Add(time.Minute) }
	if got, err := reloaded.get(proof.ProofID); err != nil || got != proof {
		t.Fatalf("durable proof did not round trip: got=%+v err=%v", got, err)
	}
	reloaded.now = func() time.Time { return now.Add(pendingFolderObservationProofTTL) }
	if _, err := reloaded.get(proof.ProofID); !errors.Is(err, errObservationProofExpired) {
		t.Fatalf("expired proof remained usable: %v", err)
	}

	var document pendingFolderObservationProofDocument
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	document.Proofs[0].Label = "tampered"
	tampered, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.path, tampered, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPendingFolderObservationProofStore(home); err == nil || !strings.Contains(err.Error(), "integrity") {
		t.Fatalf("tampered proof store loaded: %v", err)
	}

	symlinkHome := t.TempDir()
	bridgeDirectory := filepath.Join(symlinkHome, "Bridge")
	if err := os.MkdirAll(bridgeDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, "untrusted.json"), filepath.Join(bridgeDirectory, "pending-folder-observation-proofs-v1.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPendingFolderObservationProofStore(symlinkHome); err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("symlink proof store was accepted: %v", err)
	}
}

func TestPendingFolderObservationProofStoreRejectsFutureTimeAndClockRollback(t *testing.T) {
	deviceID := protocol.NewDeviceID([]byte("proof clock peer"))
	now := time.Now().UTC().Truncate(time.Millisecond)
	store, err := loadPendingFolderObservationProofStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	clock := now
	store.now = func() time.Time { return clock }

	future := pendingFolderObservationProofForTest(now.Add(time.Second), deviceID, "future-proof-folder", strings.Repeat("e", 64), "future-proof-session")
	if err := store.put(future); !errors.Is(err, errObservationProofNotYetValid) {
		t.Fatalf("future-dated proof was accepted: %v", err)
	}
	data, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatalf("durable high-water mark was not established before proof validation: %v", err)
	}
	var highWaterOnly pendingFolderObservationProofDocument
	if err := json.Unmarshal(data, &highWaterOnly); err != nil {
		t.Fatal(err)
	}
	if highWaterOnly.ClockHighWater != now.Format(time.RFC3339Nano) || len(highWaterOnly.Proofs) != 0 {
		t.Fatalf("future-dated proof reached disk: %+v", highWaterOnly)
	}

	valid := pendingFolderObservationProofForTest(now, deviceID, "clock-proof-folder", strings.Repeat("e", 64), "clock-proof-session")
	if err := store.put(valid); err != nil {
		t.Fatal(err)
	}
	clock = now.Add(time.Second)
	if _, err := store.get(valid.ProofID); err != nil {
		t.Fatalf("monotonic clock advance rejected a valid proof: %v", err)
	}
	clock = now.Add(500 * time.Millisecond)
	if _, err := store.get(valid.ProofID); !errors.Is(err, errObservationProofClockRollback) {
		t.Fatalf("clock rollback did not fail closed: %v", err)
	}
	clock = now.Add(2 * time.Second)
	if _, err := store.get(valid.ProofID); !errors.Is(err, errObservationProofClockRollback) {
		t.Fatalf("clock rollback failure was not sticky for the process: %v", err)
	}

	futureHome := t.TempDir()
	futureDirectory := filepath.Join(futureHome, "Bridge")
	if err := os.Mkdir(futureDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	durableFuture := pendingFolderObservationProofForTest(time.Now().UTC().Add(time.Minute), deviceID, "durable-future-folder", strings.Repeat("f", 64), "durable-future-session")
	document, err := json.Marshal(pendingFolderObservationProofDocument{
		SchemaVersion:  pendingFolderObservationProofSchemaVersion,
		ClockHighWater: now.Format(time.RFC3339Nano),
		Proofs:         []pendingFolderObservationProof{durableFuture},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(futureDirectory, "pending-folder-observation-proofs-v1.json"), document, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPendingFolderObservationProofStoreWithDependencies(futureHome, func() time.Time { return now }, writePendingFolderObservationProofFile); err == nil || !strings.Contains(err.Error(), "postdates") {
		t.Fatalf("proof newer than its durable high-water mark loaded after restart: %v", err)
	}
}

func TestPendingFolderObservationProofStoreDurableClockHighWaterAndLegacyMigration(t *testing.T) {
	deviceID := protocol.NewDeviceID([]byte("durable proof clock peer"))
	observedAt := time.Date(2026, 8, 10, 4, 5, 6, 0, time.UTC)

	t.Run("restart rollback", func(t *testing.T) {
		home := t.TempDir()
		clock := observedAt
		store, err := loadPendingFolderObservationProofStoreWithDependencies(home, func() time.Time { return clock }, writePendingFolderObservationProofFile)
		if err != nil {
			t.Fatal(err)
		}
		proof := pendingFolderObservationProofForTest(observedAt, deviceID, "restart-clock-folder", strings.Repeat("9", 64), "restart-clock-session")
		if err := store.put(proof); err != nil {
			t.Fatal(err)
		}
		clock = observedAt.Add(4 * time.Minute)
		if _, err := store.get(proof.ProofID); err != nil {
			t.Fatalf("valid proof was rejected while advancing the durable clock: %v", err)
		}
		data, err := os.ReadFile(store.path)
		if err != nil {
			t.Fatal(err)
		}
		var document pendingFolderObservationProofDocument
		if err := json.Unmarshal(data, &document); err != nil {
			t.Fatal(err)
		}
		if document.SchemaVersion != pendingFolderObservationProofSchemaVersion || document.ClockHighWater != clock.Format(time.RFC3339Nano) {
			t.Fatalf("advanced clock high-water mark was not durable: %+v", document)
		}

		restartedClock := observedAt.Add(time.Minute)
		if _, err := loadPendingFolderObservationProofStoreWithDependencies(home, func() time.Time { return restartedClock }, writePendingFolderObservationProofFile); !errors.Is(err, errObservationProofClockRollback) {
			t.Fatalf("restart clock rollback authorized a durable proof: %v", err)
		}
	})

	t.Run("high-water persistence failure", func(t *testing.T) {
		home := t.TempDir()
		clock := observedAt
		store, err := loadPendingFolderObservationProofStoreWithDependencies(home, func() time.Time { return clock }, writePendingFolderObservationProofFile)
		if err != nil {
			t.Fatal(err)
		}
		proof := pendingFolderObservationProofForTest(observedAt, deviceID, "failed-clock-folder", strings.Repeat("8", 64), "failed-clock-session")
		if err := store.put(proof); err != nil {
			t.Fatal(err)
		}
		before, err := os.ReadFile(store.path)
		if err != nil {
			t.Fatal(err)
		}
		store.writeFile = func(string, []byte) error { return errors.New("injected clock persistence failure") }
		clock = observedAt.Add(time.Minute)
		if _, err := store.get(proof.ProofID); !errors.Is(err, errObservationProofStoreUnhealthy) {
			t.Fatalf("proof was authorized without persisting the advanced clock: %v", err)
		}
		after, err := os.ReadFile(store.path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(after, before) {
			t.Fatal("failed clock persistence changed the durable proof store")
		}
		store.writeFile = writePendingFolderObservationProofFile
		if _, err := store.get(proof.ProofID); !errors.Is(err, errObservationProofStoreUnhealthy) {
			t.Fatalf("clock persistence failure was not sticky for the process: %v", err)
		}
	})

	t.Run("legacy proofs invalidated", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		proof := pendingFolderObservationProofForTest(observedAt, deviceID, "legacy-clock-folder", strings.Repeat("7", 64), "legacy-clock-session")
		legacyData, err := json.Marshal(pendingFolderObservationProofDocument{
			SchemaVersion: pendingFolderObservationProofLegacySchema,
			Proofs:        []pendingFolderObservationProof{proof},
		})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "pending-folder-observation-proofs-v1.json")
		if err := os.WriteFile(path, legacyData, 0o600); err != nil {
			t.Fatal(err)
		}
		store, err := loadPendingFolderObservationProofStoreWithDependencies(home, func() time.Time { return observedAt }, writePendingFolderObservationProofFile)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.get(proof.ProofID); !errors.Is(err, errObservationProofNotFound) {
			t.Fatalf("legacy proof survived migration without a durable clock boundary: %v", err)
		}
		migratedData, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var migrated pendingFolderObservationProofDocument
		if err := json.Unmarshal(migratedData, &migrated); err != nil {
			t.Fatal(err)
		}
		if migrated.SchemaVersion != pendingFolderObservationProofSchemaVersion || migrated.ClockHighWater != observedAt.Format(time.RFC3339Nano) || len(migrated.Proofs) != 0 {
			t.Fatalf("legacy store was not safely invalidated and migrated: %+v", migrated)
		}
	})

	t.Run("legacy migration write failure", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		legacyData := []byte(`{"schemaVersion":1,"proofs":[]}`)
		path := filepath.Join(directory, "pending-folder-observation-proofs-v1.json")
		if err := os.WriteFile(path, legacyData, 0o600); err != nil {
			t.Fatal(err)
		}
		failedWriter := func(string, []byte) error { return errors.New("injected migration failure") }
		if _, err := loadPendingFolderObservationProofStoreWithDependencies(home, func() time.Time { return observedAt }, failedWriter); !errors.Is(err, errObservationProofStoreUnhealthy) {
			t.Fatalf("legacy store became usable without a durable migration: %v", err)
		}
		unchanged, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(unchanged, legacyData) {
			t.Fatal("failed legacy migration changed the original store")
		}
	})
}

func TestPendingFolderObservationProofStoreBoundsDuplicateKeysAndAtomicFailure(t *testing.T) {
	deviceID := protocol.NewDeviceID([]byte("proof store bounds peer"))
	now := time.Now().UTC().Truncate(time.Millisecond)

	t.Run("capacity", func(t *testing.T) {
		store, err := loadPendingFolderObservationProofStore(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		store.now = func() time.Time { return now }
		for index := 0; index < maxPendingFolderObservationProofs; index++ {
			proof := pendingFolderObservationProofForTest(now, deviceID, fmt.Sprintf("capacity-folder-%03d", index), strings.Repeat("1", 64), "capacity-session")
			store.proofs[proof.ProofID] = proof
		}
		extra := pendingFolderObservationProofForTest(now, deviceID, "capacity-folder-extra", strings.Repeat("1", 64), "capacity-session")
		if err := store.put(extra); !errors.Is(err, errObservationProofStoreFull) {
			t.Fatalf("over-capacity proof was accepted: %v", err)
		}
		if len(store.proofs) != maxPendingFolderObservationProofs {
			t.Fatalf("capacity failure changed proof count: %d", len(store.proofs))
		}
	})

	t.Run("oversized", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "pending-folder-observation-proofs-v1.json")
		if err := os.WriteFile(path, make([]byte, maxPendingFolderObservationProofStoreSize+1), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadPendingFolderObservationProofStore(home); err == nil || !strings.Contains(err.Error(), "exceeds") {
			t.Fatalf("oversized proof store loaded: %v", err)
		}
	})

	t.Run("duplicate JSON key", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "pending-folder-observation-proofs-v1.json")
		data := []byte(`{"schemaVersion":1,"schemaVersion":1,"proofs":[]}`)
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadPendingFolderObservationProofStore(home); err == nil || !strings.Contains(err.Error(), "duplicate JSON key") {
			t.Fatalf("duplicate-key proof store loaded: %v", err)
		}
	})

	t.Run("directory permissions", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(directory, 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := loadPendingFolderObservationProofStore(home); err == nil || !strings.Contains(err.Error(), "0700") {
			t.Fatalf("broad proof directory permissions were accepted: %v", err)
		}
	})

	t.Run("atomic save failure", func(t *testing.T) {
		store, err := loadPendingFolderObservationProofStore(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		store.now = func() time.Time { return now }
		first := pendingFolderObservationProofForTest(now, deviceID, "atomic-first-folder", strings.Repeat("2", 64), "atomic-session")
		if err := store.put(first); err != nil {
			t.Fatal(err)
		}
		before, err := os.ReadFile(store.path)
		if err != nil {
			t.Fatal(err)
		}
		store.writeFile = func(string, []byte) error { return errors.New("injected proof save failure") }
		second := pendingFolderObservationProofForTest(now, deviceID, "atomic-second-folder", strings.Repeat("2", 64), "atomic-session")
		if err := store.put(second); err == nil {
			t.Fatal("injected proof save failure was ignored")
		}
		if _, exists := store.proofs[second.ProofID]; exists {
			t.Fatal("failed proof save changed the in-memory store")
		}
		after, err := os.ReadFile(store.path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(after, before) {
			t.Fatal("failed proof save changed the durable store")
		}
		if got, err := store.get(first.ProofID); err != nil || got != first {
			t.Fatalf("failed proof save lost the prior proof: got=%+v err=%v", got, err)
		}
	})
}

func TestCapturePendingFolderObservationUsesNewestEpochAndNeverSerializesConnectionID(t *testing.T) {
	localID := protocol.NewDeviceID([]byte("capture local device"))
	remoteID := protocol.NewDeviceID([]byte("capture offering device"))
	now := time.Date(2026, 8, 10, 2, 3, 4, 0, time.UTC)
	store, err := loadPendingFolderObservationProofStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return now }
	configuration := config.Wrap("", config.New(localID), localID, events.NoopLogger)
	subscription := &observationTestSubscription{events: make(chan events.Event, 4)}
	descriptor := sessionDescriptor{
		SessionID:                     "capture-session",
		Mode:                          sessionModePendingFolderObservation,
		FolderID:                      "capture-folder",
		OfferingDeviceID:              remoteID.String(),
		TaskID:                        "capture-task",
		ExpectedConfigurationRevision: strings.Repeat("c", 64),
		MaximumNetworkBytes:           "4096",
	}
	descriptor.PlanDigest = pendingFolderObservationSessionPlanDigest(descriptor.TaskID, descriptor.FolderID, descriptor.OfferingDeviceID, descriptor.ExpectedConfigurationRevision, descriptor.MaximumNetworkBytes)
	epochCurrent := false
	core := &Core{
		localDeviceID:                  localID,
		lifecycle:                      lifecycleRunning,
		session:                        &descriptor,
		configurationRevision:          descriptor.ExpectedConfigurationRevision,
		pendingFolderObservationProofs: store,
		pendingFolderObservationEpochCurrentForTests: func(deviceID protocol.DeviceID, connectionID string, generation uint64) bool {
			return epochCurrent && deviceID == remoteID && connectionID == "raw-connection-secret-current" && generation == 12
		},
		runtime: &runtimeState{
			mode:                                 sessionModePendingFolderObservation,
			configuration:                        configuration,
			pendingFolderObservationSubscription: subscription,
		},
	}
	offer := model.PendingFolderObservation{
		FolderID: "capture-folder",
		Label:    "Captured",
		LastSeen: now.Add(-time.Second),
	}
	subscription.events <- events.Event{Time: now.Add(-2 * time.Second), Data: model.ClusterConfigReceivedEventData{
		Device: remoteID, ConnectionID: "raw-connection-secret-old", ConnectionEpoch: 10, PendingFolders: []model.PendingFolderObservation{offer},
	}}
	// A newer successful ClusterConfig without the target supersedes the older
	// offer; capture must not manufacture a proof from the stale epoch.
	subscription.events <- events.Event{Time: now.Add(-time.Second), Data: model.ClusterConfigReceivedEventData{
		Device: remoteID, ConnectionID: "raw-connection-secret-newer", ConnectionEpoch: 11,
	}}
	request := observationCaptureRequestForTest(descriptor, "capture-absent")
	if err := core.capturePendingFolderObservationLocked(request); err == nil || err.Code != "pending_folder_not_found" {
		t.Fatalf("stale offered epoch was accepted: %+v", err)
	}

	subscription.events <- events.Event{Time: now, Data: model.ClusterConfigReceivedEventData{
		Device: remoteID, ConnectionID: "raw-connection-secret-current", ConnectionEpoch: 12, PendingFolders: []model.PendingFolderObservation{offer},
	}}
	request.RequestID = "capture-retired-before-sign"
	if err := core.capturePendingFolderObservationLocked(request); err == nil || err.Code != "pending_folder_observation_pending" {
		t.Fatalf("retired epoch was accepted before proof signing: %+v", err)
	}
	assertPendingFolderObservationProofStoreHasNoProofs(t, store)
	if core.runtime.capturedPendingFolderObservation != nil {
		t.Fatal("retired epoch populated the captured proof response")
	}
	epochCurrent = true
	request.RequestID = "capture-current"
	encodedRequest, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	response, err := core.commandJSONLocked(string(encodedRequest))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(response, "raw-connection-secret") {
		t.Fatal("capture response exposed a raw connection ID")
	}
	envelope := decodeTestEnvelope(t, response)
	if !envelope.OK {
		t.Fatalf("current authoritative observation failed: %+v", envelope.Error)
	}
	var payload commandPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.PendingFolderObservation == nil || payload.PendingFolderObservation.FolderID != "capture-folder" || !isCanonicalStableVersion(payload.PendingFolderObservation.ConnectionEpoch) {
		t.Fatalf("capture payload omitted durable proof: %+v", payload)
	}
	stored, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(stored, []byte("raw-connection-secret")) {
		t.Fatal("durable proof exposed a raw connection ID")
	}
}

func TestCapturePendingFolderObservationRejectsRetiredReceiveOwnerWithoutWritingProof(t *testing.T) {
	for _, transition := range []string{
		"published then closed",
		"connection replacement without new ClusterConfig",
		"same connection epoch rotation",
	} {
		t.Run(transition, func(t *testing.T) {
			localID := protocol.NewDeviceID([]byte("retired capture local " + transition))
			remoteID := protocol.NewDeviceID([]byte("retired capture peer " + transition))
			now := time.Now().UTC().Truncate(time.Millisecond)
			store, err := loadPendingFolderObservationProofStore(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			store.now = func() time.Time { return now }
			subscription := &observationTestSubscription{events: make(chan events.Event, 1)}
			descriptor := sessionDescriptor{
				SessionID:                     "retired-capture-session",
				Mode:                          sessionModePendingFolderObservation,
				FolderID:                      "retired-capture-folder",
				OfferingDeviceID:              remoteID.String(),
				TaskID:                        "retired-capture-task",
				ExpectedConfigurationRevision: strings.Repeat("d", 64),
				MaximumNetworkBytes:           "4096",
			}
			descriptor.PlanDigest = pendingFolderObservationSessionPlanDigest(descriptor.TaskID, descriptor.FolderID, descriptor.OfferingDeviceID, descriptor.ExpectedConfigurationRevision, descriptor.MaximumNetworkBytes)
			rawConnectionID := "raw-retired-connection-" + strings.ReplaceAll(transition, " ", "-")
			validatorCalled := false
			core := &Core{
				localDeviceID:                  localID,
				lifecycle:                      lifecycleRunning,
				session:                        &descriptor,
				configurationRevision:          descriptor.ExpectedConfigurationRevision,
				pendingFolderObservationProofs: store,
				pendingFolderObservationEpochCurrentForTests: func(deviceID protocol.DeviceID, connectionID string, generation uint64) bool {
					validatorCalled = true
					if deviceID != remoteID || connectionID != rawConnectionID || generation != 41 {
						t.Fatal("capture did not validate the exact private receive-owner epoch")
					}
					return false
				},
				runtime: &runtimeState{
					mode:                                 sessionModePendingFolderObservation,
					configuration:                        config.Wrap("", config.New(localID), localID, events.NoopLogger),
					pendingFolderObservationSubscription: subscription,
				},
			}
			subscription.events <- events.Event{Time: now, Data: model.ClusterConfigReceivedEventData{
				Device:          remoteID,
				ConnectionID:    rawConnectionID,
				ConnectionEpoch: 41,
				PendingFolders: []model.PendingFolderObservation{{
					FolderID: descriptor.FolderID,
					Label:    "Retired offer",
					LastSeen: now.Add(-time.Second),
				}},
			}}
			captureErr := core.capturePendingFolderObservationLocked(observationCaptureRequestForTest(descriptor, "retired-capture"))
			if captureErr == nil || captureErr.Code != "pending_folder_observation_pending" || !validatorCalled {
				t.Fatalf("retired receive-owner epoch was accepted: %+v", captureErr)
			}
			if strings.Contains(captureErr.Message, rawConnectionID) {
				t.Fatal("retired capture error exposed the raw connection identity")
			}
			assertPendingFolderObservationProofStoreHasNoProofs(t, store)
			if len(store.proofs) != 0 || core.runtime.capturedPendingFolderObservation != nil {
				t.Fatal("retired receive-owner epoch populated proof state")
			}
		})
	}
}

func TestPendingFolderObservationRuntimeIsEphemeralBoundedAndCanonicalUnchanged(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	assertCommandOK(t, core, configurationSessionCommandForTest("observation-seed-open", "openConfiguration", "observation-seed"))
	targetID := protocol.NewDeviceID([]byte("observation runtime target"))
	otherID := protocol.NewDeviceID([]byte("observation runtime unrelated"))
	for index, deviceID := range []protocol.DeviceID{targetID, otherID} {
		assertCommandOK(t, core, boundCommandForTest(
			"observation-seed-device-"+string(rune('0'+index)),
			"addDevice",
			"observation-seed",
			"",
			deviceID.String(),
			"",
			"",
			core.configurationRevision,
			map[string]string{"name": deviceID.String(), "paused": "false"},
		))
	}
	assertCommandOK(t, core, boundCommandForTest(
		"observation-seed-folder",
		"addFolder",
		"observation-seed",
		"unrelated-folder",
		"",
		"",
		"",
		core.configurationRevision,
		map[string]string{"path": t.TempDir(), "paused": "false", "deviceIDs": otherID.String()},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("observation-seed-close", "closeSession", "observation-seed"))
	canonicalPath := filepath.Join(home, "Config", "config.xml")
	canonicalBefore, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}

	descriptor := sessionDescriptor{
		SessionID:                     "observation-runtime",
		Mode:                          sessionModePendingFolderObservation,
		FolderID:                      "offered-runtime-folder",
		OfferingDeviceID:              targetID.String(),
		TaskID:                        "observe-runtime-offer",
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "8192",
	}
	descriptor.PlanDigest = pendingFolderObservationSessionPlanDigest(descriptor.TaskID, descriptor.FolderID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes)
	assertCommandOK(t, core, observationSessionCommandForTest("observation-runtime-open", "openPendingFolderObservationSession", descriptor, true))
	if core.runtime == nil || core.runtime.mode != sessionModePendingFolderObservation || core.runtime.app == nil || core.runtime.networkBudgetToken == 0 {
		t.Fatalf("observation runtime was not fully constructed: %+v", core.runtime)
	}
	effective := core.runtime.configuration.RawCopy()
	if len(effective.Folders) != 0 || len(effective.Devices) != 2 {
		t.Fatalf("observation runtime scope is not zero-folder target-only: folders=%d devices=%+v", len(effective.Folders), effective.Devices)
	}
	if _, _, ok := effective.Device(targetID); !ok {
		t.Fatal("observation runtime omitted its target device")
	}
	if _, _, ok := effective.Device(otherID); ok {
		t.Fatal("observation runtime retained an unrelated device")
	}
	canonicalDuring, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonicalBefore, canonicalDuring) {
		t.Fatal("opening an observation runtime changed canonical config.xml")
	}
	if response := decodeTestEnvelope(t, mustCommand(t, core, observationSessionCommandForTest("observation-runtime-sync", "sync", descriptor, true))); response.OK || response.Error.Code != "wrong_session_mode" {
		t.Fatalf("observation runtime accepted sync: %+v", response)
	}
	assertCommandOK(t, core, observationSessionCommandForTest("observation-runtime-close", "closeSession", descriptor, false))
	canonicalAfter, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonicalBefore, canonicalAfter) {
		t.Fatal("closing an observation runtime changed canonical config.xml")
	}
}

func TestProofBackedFolderDecisionsConsumeProofAndFenceScopeRevisionAndReplay(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("proof-decision-open", "openConfiguration", "proof-decision"))
	remoteID := protocol.NewDeviceID([]byte("proof decision offering device"))
	assertCommandOK(t, core, boundCommandForTest(
		"proof-decision-device", "addDevice", "proof-decision", "", remoteID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Proof peer", "paused": "false"},
	))

	now := time.Now().UTC().Truncate(time.Millisecond)
	core.pendingFolderObservationProofs.now = func() time.Time { return now }
	revision := core.configurationRevision
	acceptProof := pendingFolderObservationProofForTest(now, remoteID, "proof-accepted-folder", revision, "proof-observation-session")
	if err := core.pendingFolderObservationProofs.put(acceptProof); err != nil {
		t.Fatal(err)
	}
	acceptRequest := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "proof-backed-accept",
		Command:                      "acceptFolder",
		SessionID:                    "proof-decision",
		CommandConfigurationRevision: revision,
		FolderID:                     acceptProof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       acceptProof.OfferVersion,
			"observationProofID": acceptProof.ProofID,
			"path":               t.TempDir(),
			"type":               "sendReceive",
			"paused":             "true",
			"deviceIDs":          remoteID.String(),
		},
	}
	acceptText := marshalCommandForTest(t, acceptRequest)
	accepted := mustCommand(t, core, acceptText)
	if envelope := decodeTestEnvelope(t, accepted); !envelope.OK {
		t.Fatalf("proof-backed accept failed: %+v", envelope.Error)
	}
	if _, ok := core.runtime.configuration.Folder(acceptProof.FolderID); !ok {
		t.Fatal("proof-backed accept did not configure the folder")
	}
	if _, err := core.pendingFolderObservationProofs.get(acceptProof.ProofID); !errors.Is(err, errObservationProofNotFound) {
		t.Fatalf("proof-backed accept did not consume its proof: %v", err)
	}
	if replay := mustCommand(t, core, acceptText); replay != accepted {
		t.Fatal("completed proof-backed accept did not replay exactly before revision preflight")
	}

	revision = core.configurationRevision
	ignoreProof := pendingFolderObservationProofForTest(now.Add(time.Second), remoteID, "proof-ignored-folder", revision, "proof-ignore-session")
	core.pendingFolderObservationProofs.now = func() time.Time { return now.Add(time.Second) }
	if err := core.pendingFolderObservationProofs.put(ignoreProof); err != nil {
		t.Fatal(err)
	}
	wrongScope := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "proof-wrong-scope",
		Command:                      "ignorePendingFolder",
		SessionID:                    "proof-decision",
		CommandConfigurationRevision: revision,
		FolderID:                     "different-folder",
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       ignoreProof.OfferVersion,
			"observationProofID": ignoreProof.ProofID,
		},
	}
	if envelope := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, wrongScope))); envelope.OK || envelope.Error.Code != "observation_proof_scope_mismatch" {
		t.Fatalf("out-of-scope proof was accepted: %+v", envelope)
	}
	ignoreRequest := wrongScope
	ignoreRequest.RequestID = "proof-backed-ignore"
	ignoreRequest.FolderID = ignoreProof.FolderID
	ignored := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, ignoreRequest)))
	if !ignored.OK {
		t.Fatalf("proof-backed ignore failed: %+v", ignored.Error)
	}
	device, ok := core.runtime.configuration.Device(remoteID)
	if !ok || !device.IgnoredFolder(ignoreProof.FolderID) {
		t.Fatal("proof-backed ignore did not persist the suppression")
	}
	if _, err := core.pendingFolderObservationProofs.get(ignoreProof.ProofID); !errors.Is(err, errObservationProofNotFound) {
		t.Fatalf("proof-backed ignore did not consume its proof: %v", err)
	}

	staleRevision := core.configurationRevision
	staleProof := pendingFolderObservationProofForTest(now.Add(2*time.Second), remoteID, "proof-stale-folder", staleRevision, "proof-stale-session")
	core.pendingFolderObservationProofs.now = func() time.Time { return now.Add(2 * time.Second) }
	if err := core.pendingFolderObservationProofs.put(staleProof); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, core, boundCommandForTest(
		"proof-revision-advance", "editDevice", "proof-decision", "", remoteID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Advanced proof peer"},
	))
	staleRequest := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "proof-stale-ignore",
		Command:                      "ignorePendingFolder",
		SessionID:                    "proof-decision",
		CommandConfigurationRevision: staleRevision,
		FolderID:                     staleProof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       staleProof.OfferVersion,
			"observationProofID": staleProof.ProofID,
		},
	}
	ledgerBefore := len(core.commandLedger.entries)
	if envelope := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, staleRequest))); envelope.OK || envelope.Error.Code != "configuration_revision_mismatch" {
		t.Fatalf("stale proof revision was accepted: %+v", envelope)
	}
	if len(core.commandLedger.entries) != ledgerBefore {
		t.Fatal("stale proof revision reached durable command acceptance")
	}
}

func TestProofBackedFolderDecisionRevalidatesTTLAtCommitStart(t *testing.T) {
	t.Run("expires before commit start", func(t *testing.T) {
		core, remoteID, sessionID := newProofConfigurationCoreForTest(t, "proof-expired-boundary")
		observedAt := time.Now().UTC().Truncate(time.Millisecond)
		clock := observedAt
		core.pendingFolderObservationProofs.now = func() time.Time { return clock }
		proof := pendingFolderObservationProofForTest(observedAt, remoteID, "proof-expired-boundary-folder", core.configurationRevision, "proof-expired-boundary-observation")
		if err := core.pendingFolderObservationProofs.put(proof); err != nil {
			t.Fatal(err)
		}
		request := proofBackedIgnoreRequestForTest("proof-expired-boundary-request", sessionID, core.configurationRevision, proof)
		configurationBefore, err := os.ReadFile(core.runtime.configuration.ConfigPath())
		if err != nil {
			t.Fatal(err)
		}
		clockReads := 0
		core.pendingFolderObservationProofs.now = func() time.Time {
			clockReads++
			if clockReads == 1 {
				return observedAt.Add(pendingFolderObservationProofTTL - time.Nanosecond)
			}
			return observedAt.Add(pendingFolderObservationProofTTL)
		}
		response := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, request)))
		if response.OK || response.Error.Code != "observation_proof_expired" {
			t.Fatalf("proof expiring at commit start was accepted: %+v", response)
		}
		if clockReads != 2 {
			t.Fatalf("proof TTL was not checked at both plan and commit boundaries: reads=%d", clockReads)
		}
		configurationAfter, err := os.ReadFile(core.runtime.configuration.ConfigPath())
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(configurationAfter, configurationBefore) {
			t.Fatal("commit-boundary expiry changed canonical configuration")
		}
		device, ok := core.runtime.configuration.Device(remoteID)
		if !ok || device.IgnoredFolder(proof.FolderID) {
			t.Fatal("commit-boundary expiry mutated pending-folder suppression")
		}
		core.pendingFolderObservationProofs.mu.Lock()
		_, retained := core.pendingFolderObservationProofs.proofs[proof.ProofID]
		core.pendingFolderObservationProofs.mu.Unlock()
		if !retained {
			t.Fatal("commit-boundary expiry consumed the unused proof")
		}
	})

	t.Run("expiry after commit start does not abort", func(t *testing.T) {
		core, remoteID, sessionID := newProofConfigurationCoreForTest(t, "proof-valid-boundary")
		observedAt := time.Now().UTC().Truncate(time.Millisecond)
		clock := observedAt
		core.pendingFolderObservationProofs.now = func() time.Time { return clock }
		proof := pendingFolderObservationProofForTest(observedAt, remoteID, "proof-valid-boundary-folder", core.configurationRevision, "proof-valid-boundary-observation")
		if err := core.pendingFolderObservationProofs.put(proof); err != nil {
			t.Fatal(err)
		}
		clock = observedAt.Add(pendingFolderObservationProofTTL - time.Nanosecond)
		originalWrite := core.pendingFolderObservationProofs.writeFile
		consumeWrite := false
		core.pendingFolderObservationProofs.writeFile = func(path string, data []byte) error {
			var document pendingFolderObservationProofDocument
			if err := json.Unmarshal(data, &document); err != nil {
				return err
			}
			if len(document.Proofs) == 0 {
				consumeWrite = true
				if err := originalWrite(path, data); err != nil {
					return err
				}
				clock = observedAt.Add(pendingFolderObservationProofTTL + time.Second)
				return nil
			}
			return originalWrite(path, data)
		}
		request := proofBackedIgnoreRequestForTest("proof-valid-boundary-request", sessionID, core.configurationRevision, proof)
		response := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, request)))
		if !response.OK {
			t.Fatalf("proof valid at commit start was aborted after expiry: %+v", response.Error)
		}
		if !consumeWrite {
			t.Fatal("successful commit did not durably consume its proof")
		}
		device, ok := core.runtime.configuration.Device(remoteID)
		if !ok || !device.IgnoredFolder(proof.FolderID) {
			t.Fatal("proof valid at commit start did not commit suppression")
		}
		if _, err := core.pendingFolderObservationProofs.trustedTime(); err != nil {
			t.Fatalf("post-commit clock advance was treated as rollback: %v", err)
		}
		core.pendingFolderObservationProofs.mu.Lock()
		_, retained := core.pendingFolderObservationProofs.proofs[proof.ProofID]
		core.pendingFolderObservationProofs.mu.Unlock()
		if retained {
			t.Fatal("successful commit retained its consumed proof")
		}
	})
}

func TestProofBackedAcceptsReceiveEncryptedOfferAndConsumesProof(t *testing.T) {
	core, remoteID, sessionID := newProofConfigurationCoreForTest(t, "proof-encrypted-accept")
	now := time.Now().UTC().Truncate(time.Millisecond)
	core.pendingFolderObservationProofs.now = func() time.Time { return now }
	proof := pendingFolderObservationProofForTest(now, remoteID, "proof-encrypted-folder", core.configurationRevision, "proof-encrypted-observation")
	proof.ReceiveEncrypted = true
	offer, err := proof.offer()
	if err != nil {
		t.Fatal(err)
	}
	proof.OfferVersion = pendingFolderOfferVersion(offer)
	proof.ProofID = pendingFolderObservationProofID(proof)
	if err := core.pendingFolderObservationProofs.put(proof); err != nil {
		t.Fatal(err)
	}
	request := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "proof-encrypted-accept-request",
		Command:                      "acceptFolder",
		SessionID:                    sessionID,
		CommandConfigurationRevision: core.configurationRevision,
		FolderID:                     proof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       proof.OfferVersion,
			"observationProofID": proof.ProofID,
			"path":               t.TempDir(),
			"type":               "receiveEncrypted",
			"paused":             "true",
			"deviceIDs":          remoteID.String(),
			"rescanIntervalS":    "86400",
		},
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, request)))
	if !response.OK {
		t.Fatalf("receive-encrypted proof-backed offer was rejected: %+v", response.Error)
	}
	folder, exists := core.runtime.configuration.Folder(proof.FolderID)
	if !exists || folder.Type != config.FolderTypeReceiveEncrypted || folder.RescanIntervalS != 86400 {
		t.Fatalf("receive-encrypted folder was not configured safely: %+v", folder)
	}
	if _, err := core.pendingFolderObservationProofs.get(proof.ProofID); !errors.Is(err, errObservationProofNotFound) {
		t.Fatalf("accepted encrypted offer retained its proof: %v", err)
	}
}

func TestProofBackedAcceptCrashAfterSaveReconcilesPendingLedgerAfterRestart(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("crash-proof-open", "openConfiguration", "crash-proof"))
	remoteID := protocol.NewDeviceID([]byte("crash proof offering device"))
	assertCommandOK(t, core, boundCommandForTest(
		"crash-proof-device", "addDevice", "crash-proof", "", remoteID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Crash proof peer", "paused": "false"},
	))
	now := time.Now().UTC().Truncate(time.Millisecond)
	core.pendingFolderObservationProofs.now = func() time.Time { return now }
	proof := pendingFolderObservationProofForTest(now, remoteID, "crash-proof-folder", core.configurationRevision, "crash-proof-observation")
	if err := core.pendingFolderObservationProofs.put(proof); err != nil {
		t.Fatal(err)
	}
	request := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "crash-proof-accept",
		Command:                      "acceptFolder",
		SessionID:                    "crash-proof",
		CommandConfigurationRevision: core.configurationRevision,
		FolderID:                     proof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       proof.OfferVersion,
			"observationProofID": proof.ProofID,
			"path":               t.TempDir(),
			"type":               "sendReceive",
			"paused":             "true",
			"deviceIDs":          remoteID.String(),
		},
	}
	requestText := marshalCommandForTest(t, request)
	originalWrite := core.commandLedger.writeFile
	writes := 0
	core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected completion persistence crash")
		}
		return originalWrite(path, data)
	}
	failed := decodeTestEnvelope(t, mustCommand(t, core, requestText))
	core.commandLedger.writeFile = originalWrite
	if failed.OK || failed.Error.Code != "internal_error" {
		t.Fatalf("injected completion crash did not fail indeterminately: %+v", failed)
	}
	entry := core.commandLedger.entries[request.RequestID]
	if entry.State != commandStatePending {
		t.Fatalf("completion crash did not leave a pending ledger entry: %+v", entry)
	}
	if _, ok := core.runtime.configuration.Folder(proof.FolderID); !ok {
		t.Fatal("configuration did not commit before injected completion crash")
	}
	if _, err := core.pendingFolderObservationProofs.get(proof.ProofID); !errors.Is(err, errObservationProofNotFound) {
		t.Fatalf("configuration committed but proof was not consumed before completion crash: %v", err)
	}
	identity := core.IdentityBlob()
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	defer reloaded.Close()
	acknowledgement := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, requestText, 1, 1),
	))
	if !acknowledgement.OK {
		t.Fatalf("authoritative restart reconciliation could not clear proof-backed pending command: %+v", acknowledgement.Error)
	}
	if _, exists := reloaded.commandLedger.entries[request.RequestID]; exists {
		t.Fatal("restart reconciliation retained proof-backed pending ledger entry")
	}
}

func TestProofBackedFolderDecisionRereadsDiskRevisionBeforeLedgerAcceptance(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("disk-cas-open", "openConfiguration", "disk-cas"))
	remoteID := protocol.NewDeviceID([]byte("disk cas offering device"))
	assertCommandOK(t, core, boundCommandForTest(
		"disk-cas-device", "addDevice", "disk-cas", "", remoteID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Disk CAS peer", "paused": "false"},
	))
	now := time.Now().UTC().Truncate(time.Millisecond)
	core.pendingFolderObservationProofs.now = func() time.Time { return now }
	proof := pendingFolderObservationProofForTest(now, remoteID, "disk-cas-folder", core.configurationRevision, "disk-cas-observation")
	if err := core.pendingFolderObservationProofs.put(proof); err != nil {
		t.Fatal(err)
	}
	request := commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    "disk-cas-ignore",
		Command:                      "ignorePendingFolder",
		SessionID:                    "disk-cas",
		CommandConfigurationRevision: core.configurationRevision,
		FolderID:                     proof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   remoteID.String(),
			"offerVersion":       proof.OfferVersion,
			"observationProofID": proof.ProofID,
		},
	}
	configurationPath := core.runtime.configuration.ConfigPath()
	original, err := os.ReadFile(configurationPath)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(configurationPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configurationPath, append(append([]byte(nil), original...), '\n'), info.Mode().Perm()); err != nil {
		t.Fatal(err)
	}
	ledgerBefore := len(core.commandLedger.entries)
	response := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, request)))
	if response.OK || response.Error.Code != "configuration_revision_mismatch" {
		t.Fatalf("disk-level configuration drift was accepted: %+v", response)
	}
	if len(core.commandLedger.entries) != ledgerBefore {
		t.Fatal("disk-level configuration drift reached durable command acceptance")
	}
	if err := os.WriteFile(configurationPath, original, info.Mode().Perm()); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("disk-cas-close", "closeSession", "disk-cas"))
}

func observationSessionCommandForTest(requestID, command string, descriptor sessionDescriptor, includeTarget bool) string {
	request := commandRequest{
		SchemaVersion:                 envelopeSchemaVersion,
		RequestID:                     requestID,
		Command:                       command,
		SessionID:                     descriptor.SessionID,
		TaskID:                        descriptor.TaskID,
		PlanDigest:                    descriptor.PlanDigest,
		ExpectedConfigurationRevision: descriptor.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           descriptor.MaximumNetworkBytes,
	}
	if includeTarget {
		request.FolderID = descriptor.FolderID
		request.OfferingDeviceID = descriptor.OfferingDeviceID
	}
	return marshalCommandForTest(nil, request)
}

func marshalCommandForTest(t *testing.T, request commandRequest) string {
	encoded, err := json.Marshal(request)
	if err != nil {
		if t == nil {
			panic(err)
		}
		t.Fatal(err)
	}
	return string(encoded)
}

func assertPendingFolderObservationProofStoreHasNoProofs(t *testing.T, store *pendingFolderObservationProofStore) {
	t.Helper()
	data, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatalf("read durable proof clock state: %v", err)
	}
	var document pendingFolderObservationProofDocument
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatalf("decode durable proof clock state: %v", err)
	}
	if len(document.Proofs) != 0 {
		t.Fatalf("rejected observation wrote a durable proof: %+v", document.Proofs)
	}
}

func pendingFolderObservationProofForTest(now time.Time, deviceID protocol.DeviceID, folderID, revision, sessionID string) pendingFolderObservationProof {
	offer := pendingFolderOffer{
		FolderID:         folderID,
		Label:            "Observed folder",
		OfferingDeviceID: deviceID,
		LastSeen:         now.Add(-time.Second).UTC(),
	}
	proof := pendingFolderObservationProof{
		FolderID:              folderID,
		OfferingDeviceID:      deviceID.String(),
		OfferVersion:          pendingFolderOfferVersion(offer),
		Label:                 offer.Label,
		LastSeen:              offer.LastSeen.Format(time.RFC3339Nano),
		ConfigurationRevision: revision,
		ObservationSessionID:  sessionID,
		ConnectionEpoch:       stableOfferVersion("test-connection-epoch", deviceID.String()),
		ObservedAt:            now.UTC().Format(time.RFC3339Nano),
		ExpiresAt:             now.Add(pendingFolderObservationProofTTL).UTC().Format(time.RFC3339Nano),
	}
	proof.ProofID = pendingFolderObservationProofID(proof)
	return proof
}

func newProofConfigurationCoreForTest(t *testing.T, stem string) (*Core, protocol.DeviceID, string) {
	t.Helper()
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	sessionID := stem + "-session"
	assertCommandOK(t, core, configurationSessionCommandForTest(stem+"-open", "openConfiguration", sessionID))
	remoteID := protocol.NewDeviceID([]byte(stem + " offering device"))
	assertCommandOK(t, core, boundCommandForTest(
		stem+"-device", "addDevice", sessionID, "", remoteID.String(), "", "", core.configurationRevision,
		map[string]string{"name": stem + " peer", "paused": "false"},
	))
	return core, remoteID, sessionID
}

func proofBackedIgnoreRequestForTest(requestID, sessionID, revision string, proof pendingFolderObservationProof) commandRequest {
	return commandRequest{
		SchemaVersion:                envelopeSchemaVersion,
		RequestID:                    requestID,
		Command:                      "ignorePendingFolder",
		SessionID:                    sessionID,
		CommandConfigurationRevision: revision,
		FolderID:                     proof.FolderID,
		Arguments: map[string]string{
			"offeringDeviceID":   proof.OfferingDeviceID,
			"offerVersion":       proof.OfferVersion,
			"observationProofID": proof.ProofID,
		},
	}
}

func observationCaptureRequestForTest(descriptor sessionDescriptor, requestID string) commandRequest {
	return commandRequest{
		SchemaVersion:                 envelopeSchemaVersion,
		RequestID:                     requestID,
		Command:                       "capturePendingFolderObservation",
		SessionID:                     descriptor.SessionID,
		TaskID:                        descriptor.TaskID,
		PlanDigest:                    descriptor.PlanDigest,
		ExpectedConfigurationRevision: descriptor.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           descriptor.MaximumNetworkBytes,
		FolderID:                      descriptor.FolderID,
		OfferingDeviceID:              descriptor.OfferingDeviceID,
	}
}

type observationTestSubscription struct {
	events chan events.Event
}

func (s *observationTestSubscription) C() <-chan events.Event { return s.events }
func (s *observationTestSubscription) Mask() events.EventType { return events.ClusterConfigReceived }
func (s *observationTestSubscription) Unsubscribe()           {}
func (s *observationTestSubscription) Poll(timeout time.Duration) (events.Event, error) {
	select {
	case event := <-s.events:
		return event, nil
	case <-time.After(timeout):
		return events.Event{}, events.ErrTimeout
	}
}
