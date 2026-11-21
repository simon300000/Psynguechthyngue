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

func TestPendingFolderDiscoverySessionValidationPlanAndFiniteCap(t *testing.T) {
	if got, want := pendingFolderDiscoverySessionPlanDigest(
		"task", "device", strings.Repeat("0", 64), "0",
	), "a93131b2dd7347a7735366a61efbde3ea63b50f749bf6da371477cba10a5da17"; got != want {
		t.Fatalf("pending folder discovery plan digest ABI = %s, want %s", got, want)
	}

	deviceID := protocol.NewDeviceID([]byte("pending discovery validation peer"))
	request := commandRequest{
		SessionID:                     "discovery-session",
		OfferingDeviceID:              deviceID.String(),
		TaskID:                        "discover-offers",
		ExpectedConfigurationRevision: strings.Repeat("a", 64),
		MaximumNetworkBytes:           "8388608",
	}
	request.PlanDigest = pendingFolderDiscoverySessionPlanDigest(
		request.TaskID,
		request.OfferingDeviceID,
		request.ExpectedConfigurationRevision,
		request.MaximumNetworkBytes,
	)
	descriptor, validationErr := validateOpenSessionCommand(request, sessionModePendingFolderDiscovery)
	if validationErr != nil || descriptor.Mode != sessionModePendingFolderDiscovery || descriptor.FolderID != "" {
		t.Fatalf("valid discovery session rejected: descriptor=%+v err=%+v", descriptor, validationErr)
	}

	for name, maximum := range map[string]string{
		"zero":         "0",
		"maximum":      "8388608",
		"unlimited":    "unlimited",
		"too-large":    "8388609",
		"leading-zero": "01",
		"missing":      "",
	} {
		t.Run(name, func(t *testing.T) {
			candidate := request
			candidate.MaximumNetworkBytes = maximum
			candidate.PlanDigest = pendingFolderDiscoverySessionPlanDigest(candidate.TaskID, candidate.OfferingDeviceID, candidate.ExpectedConfigurationRevision, maximum)
			_, err := validateOpenSessionCommand(candidate, sessionModePendingFolderDiscovery)
			valid := maximum == "0" || maximum == "8388608"
			if valid && err != nil {
				t.Fatalf("finite cap %q was rejected: %+v", maximum, err)
			}
			if !valid && (err == nil || err.Code != "invalid_session") {
				t.Fatalf("unsafe cap %q was accepted: %+v", maximum, err)
			}
		})
	}

	withFolder := request
	withFolder.FolderID = "must-not-be-scoped"
	if _, err := validateOpenSessionCommand(withFolder, sessionModePendingFolderDiscovery); err == nil || err.Code != "invalid_session" {
		t.Fatalf("discovery session accepted folderID: %+v", err)
	}
	core := &Core{session: &descriptor}
	if err := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "sync",
		SessionID:                     descriptor.SessionID,
		TaskID:                        descriptor.TaskID,
		PlanDigest:                    descriptor.PlanDigest,
		ExpectedConfigurationRevision: descriptor.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           descriptor.MaximumNetworkBytes,
	}); err == nil || err.Code != "wrong_session_mode" {
		t.Fatalf("discovery session accepted a folder transfer command: %+v", err)
	}
	if err := core.preflightDataSessionLocked(
		descriptor.SessionID,
		descriptor.TaskID,
		descriptor.PlanDigest,
		descriptor.ExpectedConfigurationRevision,
		descriptor.MaximumNetworkBytes,
		"",
		"any-folder",
		false,
	); err == nil || err.Code != "wrong_session_mode" {
		t.Fatalf("discovery session accepted a folder data/query API: %+v", err)
	}
}

func TestPendingFolderDiscoverySummaryStoreIsStrictBoundedAndDeviceAuthoritative(t *testing.T) {
	home := t.TempDir()
	store, err := loadPendingFolderDiscoverySummaryStore(home)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 10, 4, 5, 6, 7, time.UTC)
	targetID := protocol.NewDeviceID([]byte("pending discovery store target"))
	otherID := protocol.NewDeviceID([]byte("pending discovery store other"))
	other := pendingFolderDiscoverySummaryForTest(otherID, "other-folder", now)
	if _, truncated, err := store.replaceDevice(otherID, []pendingFolderDiscoverySummary{other}, false); err != nil || truncated {
		t.Fatalf("seed unrelated summary: truncated=%t err=%v", truncated, err)
	}

	target := make([]pendingFolderDiscoverySummary, maxPendingFolderDiscoverySummaries+8)
	for index := range target {
		target[index] = pendingFolderDiscoverySummaryForTest(targetID, fmt.Sprintf("folder-%03d", index), now)
	}
	stored, truncated, err := store.replaceDevice(targetID, target, false)
	if err != nil {
		t.Fatal(err)
	}
	if !truncated || len(stored) != maxPendingFolderDiscoverySummaries-1 {
		t.Fatalf("global summary bound was not deterministic: stored=%d truncated=%t", len(stored), truncated)
	}
	all, truncatedDevices, healthy := store.snapshot()
	if !healthy || len(all) != maxPendingFolderDiscoverySummaries || !truncatedDevices[targetID] {
		t.Fatalf("bounded store state is wrong: records=%d truncated=%v healthy=%t", len(all), truncatedDevices, healthy)
	}
	if all[0].OfferingDeviceID == "" {
		t.Fatal("summary snapshot lost canonical scope")
	}

	replacement := pendingFolderDiscoverySummaryForTest(targetID, "replacement-folder", now.Add(time.Minute))
	if _, truncated, err := store.replaceDevice(targetID, []pendingFolderDiscoverySummary{replacement}, false); err != nil || truncated {
		t.Fatalf("authoritative replacement failed: truncated=%t err=%v", truncated, err)
	}
	all, truncatedDevices, _ = store.snapshot()
	if len(all) != 2 || len(truncatedDevices) != 0 {
		t.Fatalf("authoritative target replacement did not preserve only unrelated records: records=%+v truncated=%v", all, truncatedDevices)
	}
	if all[0].OfferingDeviceID != otherID.String() && all[1].OfferingDeviceID != otherID.String() {
		t.Fatal("target replacement deleted another device summary")
	}

	info, err := os.Lstat(store.path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		t.Fatalf("summary store mode is unsafe: info=%+v err=%v", info, err)
	}
	reloaded, err := loadPendingFolderDiscoverySummaryStore(home)
	if err != nil {
		t.Fatal(err)
	}
	loaded, _, healthy := reloaded.snapshot()
	if !healthy || len(loaded) != 2 {
		t.Fatalf("summary store did not survive restart: records=%+v healthy=%t", loaded, healthy)
	}
}

func TestPendingFolderDiscoverySummaryStoreRejectsDuplicateKeysAndSymlink(t *testing.T) {
	home := t.TempDir()
	directory := filepath.Join(home, "Bridge")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "pending-folder-discovery-summaries-v1.json")
	duplicate := []byte(`{"schemaVersion":1,"schemaVersion":1,"summaries":[],"truncatedOfferingDeviceIDs":[]}`)
	if err := os.WriteFile(path, duplicate, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPendingFolderDiscoverySummaryStore(home); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate JSON key was accepted: %v", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, path); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPendingFolderDiscoverySummaryStore(home); err == nil || !strings.Contains(err.Error(), "non-symlink") {
		t.Fatalf("symlink summary store was accepted: %v", err)
	}
}

func TestPendingFolderDiscoverySummaryStoreAtomicFailureAndDuplicateBatchAreFailClosed(t *testing.T) {
	home := t.TempDir()
	failWrites := false
	store, err := loadPendingFolderDiscoverySummaryStoreWithWriter(home, func(path string, data []byte) error {
		if failWrites {
			return errors.New("injected summary write failure")
		}
		return writePendingFolderObservationProofFile(path, data)
	})
	if err != nil {
		t.Fatal(err)
	}
	deviceID := protocol.NewDeviceID([]byte("atomic discovery summary peer"))
	now := time.Now().UTC().Truncate(time.Millisecond)
	first := pendingFolderDiscoverySummaryForTest(deviceID, "atomic-first", now)
	if _, _, err := store.replaceDevice(deviceID, []pendingFolderDiscoverySummary{first}, false); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	duplicate := pendingFolderDiscoverySummaryForTest(deviceID, "duplicate-folder", now.Add(time.Second))
	if _, _, err := store.replaceDevice(deviceID, []pendingFolderDiscoverySummary{duplicate, duplicate}, false); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate batch was accepted: %v", err)
	}
	if after, err := os.ReadFile(store.path); err != nil || !bytes.Equal(after, before) {
		t.Fatalf("duplicate batch changed durable state: err=%v", err)
	}
	mixedEpoch := pendingFolderDiscoverySummaryForTest(deviceID, "mixed-epoch-folder", now.Add(time.Second))
	mixedEpoch.ConnectionEpoch = stableOfferVersion("different-discovery-epoch")
	if _, _, err := store.replaceDevice(deviceID, []pendingFolderDiscoverySummary{duplicate, mixedEpoch}, false); err == nil || !strings.Contains(err.Error(), "mixes connection epochs") {
		t.Fatalf("mixed-epoch batch was accepted: %v", err)
	}
	if after, err := os.ReadFile(store.path); err != nil || !bytes.Equal(after, before) {
		t.Fatalf("mixed-epoch batch changed durable state: err=%v", err)
	}

	failWrites = true
	second := pendingFolderDiscoverySummaryForTest(deviceID, "atomic-second", now.Add(2*time.Second))
	if _, _, err := store.replaceDevice(deviceID, []pendingFolderDiscoverySummary{second}, false); err == nil {
		t.Fatal("injected atomic save failure was ignored")
	}
	if after, err := os.ReadFile(store.path); err != nil || !bytes.Equal(after, before) {
		t.Fatalf("failed atomic save changed durable state: err=%v", err)
	}
	reloaded, err := loadPendingFolderDiscoverySummaryStore(home)
	if err != nil {
		t.Fatal(err)
	}
	loaded, _, healthy := reloaded.snapshot()
	if !healthy || len(loaded) != 1 || loaded[0].FolderID != first.FolderID {
		t.Fatalf("failed save created a ghost summary: %+v healthy=%t", loaded, healthy)
	}
}

func TestPendingFolderDiscoverySummaryStoreBoundsTruncatedDeviceMetadata(t *testing.T) {
	store, err := loadPendingFolderDiscoverySummaryStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	store.mu.Lock()
	for index := 0; index < maxPendingFolderDiscoverySummaries; index++ {
		deviceID := protocol.NewDeviceID([]byte(fmt.Sprintf("truncated discovery device %03d", index)))
		store.truncatedDevices[deviceID] = true
	}
	if err := store.saveLocked(); err != nil {
		store.mu.Unlock()
		t.Fatal(err)
	}
	store.mu.Unlock()
	before, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	targetID := protocol.NewDeviceID([]byte("truncated metadata overflow target"))
	summary := pendingFolderDiscoverySummaryForTest(targetID, "truncated-overflow-folder", time.Now().UTC().Truncate(time.Millisecond))
	if _, _, err := store.replaceDevice(targetID, []pendingFolderDiscoverySummary{summary}, true); err == nil || !strings.Contains(err.Error(), "truncated-device limit") {
		t.Fatalf("truncated-device metadata overflow was accepted: %v", err)
	}
	if after, err := os.ReadFile(store.path); err != nil || !bytes.Equal(after, before) {
		t.Fatalf("truncated-device overflow changed durable state: err=%v", err)
	}
	if _, _, healthy := store.snapshot(); !healthy {
		t.Fatal("preflight capacity rejection poisoned the summary store")
	}
}

func TestPendingFolderDiscoveryZeroCapCannotWriteSummary(t *testing.T) {
	store, err := loadPendingFolderDiscoverySummaryStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	localID := protocol.NewDeviceID([]byte("zero cap discovery local"))
	descriptor := sessionDescriptor{
		SessionID:           "zero-cap-discovery",
		Mode:                sessionModePendingFolderDiscovery,
		OfferingDeviceID:    protocol.NewDeviceID([]byte("zero cap discovery peer")).String(),
		MaximumNetworkBytes: "0",
	}
	core := &Core{
		lifecycle: lifecycleRunning,
		session:   &descriptor,
		runtime: &runtimeState{
			mode:          sessionModePendingFolderDiscovery,
			configuration: config.Wrap("", config.New(localID), localID, events.NoopLogger),
		},
		pendingFolderDiscoverySummaries: store,
	}
	if captureErr := core.capturePendingFolderDiscoveryLocked(commandRequest{}); captureErr == nil || captureErr.Code != "network_byte_limit_reached" {
		t.Fatalf("zero-cap discovery capture was accepted: %+v", captureErr)
	}
	if _, err := os.Lstat(store.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("zero-cap discovery wrote a summary: %v", err)
	}
}

func TestPendingFolderDiscoveryRefreshIsDeterministicallyBounded(t *testing.T) {
	localID := protocol.NewDeviceID([]byte("bounded discovery local"))
	remoteID := protocol.NewDeviceID([]byte("bounded discovery peer"))
	descriptor := sessionDescriptor{
		SessionID:           "bounded-discovery",
		Mode:                sessionModePendingFolderDiscovery,
		OfferingDeviceID:    remoteID.String(),
		MaximumNetworkBytes: "8192",
	}
	subscription := &observationTestSubscription{events: make(chan events.Event, 2)}
	core := &Core{
		localDeviceID: localID,
		session:       &descriptor,
		runtime: &runtimeState{
			mode:                                 sessionModePendingFolderDiscovery,
			pendingFolderObservationSubscription: subscription,
		},
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	offers := make([]model.PendingFolderObservation, maxPendingFolderDiscoverySummaries+8)
	for index := range offers {
		value := len(offers) - index - 1
		offers[index] = model.PendingFolderObservation{
			FolderID: fmt.Sprintf("bounded-%03d", value),
			Label:    "Bounded",
			LastSeen: now,
		}
	}
	subscription.events <- events.Event{Time: now, Data: model.ClusterConfigReceivedEventData{
		Device: remoteID, ConnectionID: "bounded-private-connection", ConnectionEpoch: 71, PendingFolders: offers,
	}}
	if err := core.refreshPendingFolderObservationLocked(); err != nil {
		t.Fatal(err)
	}
	observation := core.runtime.pendingFolderObservation
	if observation == nil || !observation.sourceTruncated || observation.duplicateOffer || len(observation.offers) != maxPendingFolderDiscoverySummaries {
		t.Fatalf("unbounded discovery refresh state: %+v", observation)
	}
	if _, retained := observation.offers["bounded-000"]; !retained {
		t.Fatal("deterministic bounded projection omitted the smallest folder ID")
	}
	if _, retained := observation.offers["bounded-511"]; !retained {
		t.Fatal("deterministic bounded projection omitted its inclusive boundary")
	}
	if _, retained := observation.offers["bounded-512"]; retained {
		t.Fatal("deterministic bounded projection retained an out-of-bound folder")
	}
	duplicate := model.PendingFolderObservation{FolderID: "bounded-duplicate", Label: "Duplicate", LastSeen: now}
	subscription.events <- events.Event{Time: now.Add(time.Second), Data: model.ClusterConfigReceivedEventData{
		Device: remoteID, ConnectionID: "bounded-private-connection-2", ConnectionEpoch: 72, PendingFolders: []model.PendingFolderObservation{duplicate, duplicate},
	}}
	if err := core.refreshPendingFolderObservationLocked(); err != nil {
		t.Fatal(err)
	}
	if core.runtime.pendingFolderObservation == nil || !core.runtime.pendingFolderObservation.duplicateOffer {
		t.Fatal("retained duplicate folder evidence did not fail closed")
	}
}

func pendingFolderDiscoverySummaryForTest(deviceID protocol.DeviceID, folderID string, observedAt time.Time) pendingFolderDiscoverySummary {
	offer := pendingFolderOffer{
		FolderID:         folderID,
		Label:            "Folder " + folderID,
		OfferingDeviceID: deviceID,
		LastSeen:         observedAt.Add(-time.Second),
	}
	return pendingFolderDiscoverySummaryFromOffer(offer, stableOfferVersion("discovery-epoch", deviceID.String()), observedAt)
}

func TestDerivePendingFolderDiscoveryConfigurationIsZeroFolderTargetOnlyAndCanonicalPure(t *testing.T) {
	localID := protocol.NewDeviceID([]byte("pending discovery local"))
	targetID := protocol.NewDeviceID([]byte("pending discovery target"))
	otherID := protocol.NewDeviceID([]byte("pending discovery unrelated"))
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

	effective, deriveErr := deriveEffectivePendingFolderDiscoveryConfiguration(canonical, sessionDescriptor{
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
		t.Fatal("deriving discovery configuration mutated the canonical value")
	}
	if len(effective.Folders) != 0 {
		t.Fatalf("discovery effective configuration retained folders: %+v", effective.Folders)
	}
	if len(effective.Devices) != 2 {
		t.Fatalf("discovery effective configuration retained unrelated devices: %+v", effective.Devices)
	}
	target, _, ok := effective.Device(targetID)
	if !ok || target.Paused || target.AutoAcceptFolders || target.Introducer {
		t.Fatalf("target discovery device policy is unsafe: %+v", target)
	}
	if _, _, ok := effective.Device(otherID); ok {
		t.Fatal("unrelated device remained in discovery effective configuration")
	}

	paused := canonical.Copy()
	target.Paused = true
	paused.SetDevice(target)
	if _, err := deriveEffectivePendingFolderDiscoveryConfiguration(paused, sessionDescriptor{OfferingDeviceID: targetID.String()}, localID); err == nil || err.Code != "device_paused" {
		t.Fatalf("paused target was accepted: %+v", err)
	}
	if _, err := deriveEffectivePendingFolderDiscoveryConfiguration(canonical, sessionDescriptor{OfferingDeviceID: otherID.String()}, localID); err != nil {
		t.Fatalf("configured active peer was rejected: %+v", err)
	}
	if _, err := deriveEffectivePendingFolderDiscoveryConfiguration(canonical, sessionDescriptor{OfferingDeviceID: protocol.NewDeviceID([]byte("unknown discovery peer")).String()}, localID); err == nil || err.Code != "device_not_found" {
		t.Fatalf("unconfigured target was accepted: %+v", err)
	}
}

func TestPendingFolderDiscoveryCleanInstallCapturePersistsRedactedRevalidationOnlySummaries(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	current := core
	t.Cleanup(func() {
		if current != nil {
			_ = current.Close()
		}
	})
	identity := core.IdentityBlob()
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("discovery-seed-open", "openConfiguration", "discovery-seed"))
	targetID := protocol.NewDeviceID([]byte("clean discovery target"))
	assertCommandOK(t, core, boundCommandForTest(
		"discovery-seed-device", "addDevice", "discovery-seed", "", targetID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Discovery target", "paused": "false"},
	))
	if len(core.runtime.configuration.RawCopy().Folders) != 0 {
		t.Fatal("clean discovery fixture unexpectedly has a configured folder")
	}
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("discovery-seed-close", "closeSession", "discovery-seed"))
	canonicalPath := filepath.Join(home, "Config", "config.xml")
	canonicalBefore, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}

	descriptor := sessionDescriptor{
		SessionID:                     "discovery-runtime",
		Mode:                          sessionModePendingFolderDiscovery,
		OfferingDeviceID:              targetID.String(),
		TaskID:                        "discover-clean-offers",
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "8388608",
	}
	descriptor.PlanDigest = pendingFolderDiscoverySessionPlanDigest(descriptor.TaskID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes)
	assertCommandOK(t, core, discoverySessionCommandForTest("discovery-open", "openPendingFolderDiscoverySession", descriptor, true))
	if core.runtime == nil || core.runtime.mode != sessionModePendingFolderDiscovery || core.runtime.app == nil || core.runtime.networkBudgetToken == 0 {
		t.Fatalf("discovery runtime was not fully constructed: %+v", core.runtime)
	}
	effective := core.runtime.configuration.RawCopy()
	if len(effective.Folders) != 0 || len(effective.Devices) != 2 {
		t.Fatalf("discovery runtime is not zero-folder target-only: folders=%d devices=%+v", len(effective.Folders), effective.Devices)
	}
	if after, err := os.ReadFile(canonicalPath); err != nil || !bytes.Equal(after, canonicalBefore) {
		t.Fatalf("opening discovery changed canonical config: %v", err)
	}

	const rawTargetConnectionID = "raw-discovery-target-connection-sentinel"
	const rawWrongConnectionID = "raw-discovery-wrong-peer-sentinel"
	wrongID := protocol.NewDeviceID([]byte("wrong discovery event peer"))
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          wrongID,
		ConnectionID:    rawWrongConnectionID,
		ConnectionEpoch: 7,
		PendingFolders: []model.PendingFolderObservation{{
			FolderID: "wrong-peer-folder",
			Label:    "Must not leak",
			LastSeen: time.Now().UTC().Add(-time.Second),
		}},
	})
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    rawTargetConnectionID,
		ConnectionEpoch: 8,
		PendingFolders: []model.PendingFolderObservation{
			{FolderID: "discovered-one", Label: "First", LastSeen: time.Now().UTC().Add(-time.Second)},
			{FolderID: "discovered-two", Label: "evil\nlabel", LastSeen: time.Now().UTC().Add(-time.Second), ReceiveEncrypted: true, RemoteEncrypted: true},
		},
	})
	epochCurrent := false
	validatorCalled := false
	core.pendingFolderObservationEpochCurrentForTests = func(deviceID protocol.DeviceID, connectionID string, generation uint64) bool {
		validatorCalled = true
		return epochCurrent && deviceID == targetID && connectionID == rawTargetConnectionID && generation == 8
	}
	deadline := time.Now().Add(5 * time.Second)
	for attempt := 0; !validatorCalled; attempt++ {
		retired := decodeTestEnvelope(t, mustCommand(t, core, discoverySessionCommandForTest(fmt.Sprintf("discovery-retired-%d", attempt), "capturePendingFolderDiscovery", descriptor, true)))
		assertEnvelopeErrorCode(t, retired, "pending_folder_discovery_pending")
		if time.Now().After(deadline) {
			t.Fatal("authoritative discovery event was not delivered")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := os.Lstat(core.pendingFolderDiscoverySummaries.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("retired receive-owner wrote a summary: %v", err)
	}

	epochCurrent = true
	responseText := mustCommand(t, core, discoverySessionCommandForTest("discovery-capture", "capturePendingFolderDiscovery", descriptor, true))
	if strings.Contains(responseText, rawTargetConnectionID) || strings.Contains(responseText, rawWrongConnectionID) || strings.Contains(responseText, "wrong-peer-folder") {
		t.Fatalf("discovery response leaked private or wrong-peer state: %s", responseText)
	}
	response := decodeTestEnvelope(t, responseText)
	if !response.OK {
		t.Fatalf("discovery capture failed: %+v", response.Error)
	}
	var payload commandPayload
	if err := json.Unmarshal(response.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	batch := payload.PendingFolderDiscovery
	if batch == nil || batch.OfferingDeviceID != targetID.String() || len(batch.Offers) != 2 || batch.Truncated || !isCanonicalStableVersion(batch.ConnectionEpoch) {
		t.Fatalf("unexpected discovery batch: %+v", batch)
	}
	if batch.Offers[1].Label != "" || !batch.Offers[1].ReceiveEncrypted || !batch.Offers[1].RemoteEncrypted {
		t.Fatalf("untrusted discovery metadata was not safely projected: %+v", batch.Offers[1])
	}
	stored, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{rawTargetConnectionID, rawWrongConnectionID, "wrong-peer-folder", "tcp://", "/private/"} {
		if bytes.Contains(stored, []byte(forbidden)) {
			t.Fatalf("summary store leaked forbidden data %q: %s", forbidden, stored)
		}
	}
	assertCommandOK(t, core, discoverySessionCommandForTest("discovery-close", "closeSession", descriptor, false))
	if after, err := os.ReadFile(canonicalPath); err != nil || !bytes.Equal(after, canonicalBefore) {
		t.Fatalf("closing discovery changed canonical config: %v", err)
	}

	assertCommandOK(t, core, configurationSessionCommandForTest("discovery-config-open", "openConfiguration", "discovery-config"))
	snapshot := snapshotForTest(t, core, "discovery-summary-snapshot")
	if !snapshot.PendingFoldersAvailable || len(snapshot.PendingFolders) != 2 {
		t.Fatalf("configuration snapshot omitted durable discoveries: %+v", snapshot.PendingFolders)
	}
	for _, offer := range snapshot.PendingFolders {
		if offer.EvidenceSource != "durableSummary" || !offer.RequiresNetworkRevalidation {
			t.Fatalf("durable summary was presented as live authority: %+v", offer)
		}
	}
	withoutProof := decodeTestEnvelope(t, mustCommand(t, core, boundCommandForTest(
		"discovery-no-proof", "ignorePendingFolder", "discovery-config", "discovered-one", "", "", "", core.configurationRevision,
		map[string]string{"offeringDeviceID": targetID.String(), "offerVersion": snapshot.PendingFolders[0].OfferVersion},
	)))
	assertEnvelopeErrorCode(t, withoutProof, "network_observation_required")
	assertCommandOK(t, core, configurationSessionCommandForTest("discovery-config-close", "closeSession", "discovery-config"))

	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	current = nil
	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	current = reloaded
	reloaded.disableNetworkingForTests = true
	assertCommandOK(t, reloaded, configurationSessionCommandForTest("discovery-restart-open", "openConfiguration", "discovery-restart"))
	restarted := snapshotForTest(t, reloaded, "discovery-restart-snapshot")
	if len(restarted.PendingFolders) != 2 || restarted.PendingFolders[0].EvidenceSource != "durableSummary" || !restarted.PendingFolders[0].RequiresNetworkRevalidation {
		t.Fatalf("restart lost or upgraded discovery summaries: %+v", restarted.PendingFolders)
	}
}

func TestPendingFolderDiscoveryCaptureFiltersSuppressedAndConfiguredFolders(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("filter-seed-open", "openConfiguration", "filter-seed"))
	targetID := protocol.NewDeviceID([]byte("discovery filtering target"))
	assertCommandOK(t, core, boundCommandForTest(
		"filter-seed-device", "addDevice", "filter-seed", "", targetID.String(), "", "", core.configurationRevision,
		map[string]string{"name": "Filter target", "paused": "false"},
	))
	now := time.Now().UTC().Truncate(time.Millisecond)
	core.pendingFolderObservationProofs.now = func() time.Time { return now }
	suppressionProof := pendingFolderObservationProofForTest(now, targetID, "suppressed-discovery-folder", core.configurationRevision, "filter-proof")
	if err := core.pendingFolderObservationProofs.put(suppressionProof); err != nil {
		t.Fatal(err)
	}
	ignored := decodeTestEnvelope(t, mustCommand(t, core, marshalCommandForTest(t, proofBackedIgnoreRequestForTest(
		"filter-ignore", "filter-seed", core.configurationRevision, suppressionProof,
	))))
	if !ignored.OK {
		t.Fatalf("seed suppression failed: %+v", ignored.Error)
	}
	assertCommandOK(t, core, boundCommandForTest(
		"filter-configured-folder", "addFolder", "filter-seed", "configured-discovery-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": t.TempDir(), "paused": "false", "deviceIDs": targetID.String()},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("filter-seed-close", "closeSession", "filter-seed"))

	descriptor := sessionDescriptor{
		SessionID:                     "filter-discovery",
		Mode:                          sessionModePendingFolderDiscovery,
		OfferingDeviceID:              targetID.String(),
		TaskID:                        "filter-discovery-offers",
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "8192",
	}
	descriptor.PlanDigest = pendingFolderDiscoverySessionPlanDigest(descriptor.TaskID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes)
	assertCommandOK(t, core, discoverySessionCommandForTest("filter-open", "openPendingFolderDiscoverySession", descriptor, true))
	core.pendingFolderObservationEpochCurrentForTests = func(deviceID protocol.DeviceID, connectionID string, generation uint64) bool {
		return deviceID == targetID && connectionID == "filter-private-connection" && generation == 51
	}
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "filter-private-connection",
		ConnectionEpoch: 51,
		PendingFolders: []model.PendingFolderObservation{
			{FolderID: "suppressed-discovery-folder", Label: "Suppressed", LastSeen: now},
			{FolderID: "configured-discovery-folder", Label: "Configured", LastSeen: now},
			{FolderID: "visible-discovery-folder", Label: "Visible", LastSeen: now},
		},
	})
	var captured commandPayload
	deadline := time.Now().Add(5 * time.Second)
	for attempt := 0; ; attempt++ {
		response := decodeTestEnvelope(t, mustCommand(t, core, discoverySessionCommandForTest(fmt.Sprintf("filter-capture-%d", attempt), "capturePendingFolderDiscovery", descriptor, true)))
		if response.OK {
			if err := json.Unmarshal(response.Payload, &captured); err != nil {
				t.Fatal(err)
			}
			break
		}
		if response.Error.Code != "pending_folder_discovery_pending" || time.Now().After(deadline) {
			t.Fatalf("filtered discovery capture failed: %+v", response.Error)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if captured.PendingFolderDiscovery == nil || len(captured.PendingFolderDiscovery.Offers) != 1 || captured.PendingFolderDiscovery.Offers[0].FolderID != "visible-discovery-folder" {
		t.Fatalf("suppressed or configured folder entered the discovery batch: %+v", captured.PendingFolderDiscovery)
	}
	stored, _, healthy := core.pendingFolderDiscoverySummaries.snapshot()
	if !healthy || len(stored) != 1 || stored[0].FolderID != "visible-discovery-folder" {
		t.Fatalf("suppressed or configured folder entered the durable store: %+v healthy=%t", stored, healthy)
	}
	assertCommandOK(t, core, discoverySessionCommandForTest("filter-close", "closeSession", descriptor, false))
}

func TestPendingFolderDiscoveryDuplicateDriftAndAuthoritativeReplacementAreFailClosed(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	assertCommandOK(t, core, configurationSessionCommandForTest("replace-seed-open", "openConfiguration", "replace-seed"))
	targetID := protocol.NewDeviceID([]byte("discovery replacement target"))
	otherID := protocol.NewDeviceID([]byte("discovery replacement unrelated"))
	for index, deviceID := range []protocol.DeviceID{targetID, otherID} {
		assertCommandOK(t, core, boundCommandForTest(
			fmt.Sprintf("replace-seed-device-%d", index), "addDevice", "replace-seed", "", deviceID.String(), "", "", core.configurationRevision,
			map[string]string{"name": fmt.Sprintf("Replacement peer %d", index), "paused": "false"},
		))
	}
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("replace-seed-close", "closeSession", "replace-seed"))
	canonicalPath := filepath.Join(home, "Config", "config.xml")
	canonicalBefore, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}

	descriptor := sessionDescriptor{
		SessionID:                     "replace-discovery",
		Mode:                          sessionModePendingFolderDiscovery,
		OfferingDeviceID:              targetID.String(),
		TaskID:                        "replace-discovery-offers",
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "65536",
	}
	descriptor.PlanDigest = pendingFolderDiscoverySessionPlanDigest(descriptor.TaskID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes)
	assertCommandOK(t, core, discoverySessionCommandForTest("replace-open", "openPendingFolderDiscoverySession", descriptor, true))
	core.pendingFolderObservationEpochCurrentForTests = func(deviceID protocol.DeviceID, connectionID string, generation uint64) bool {
		return deviceID == targetID && connectionID == fmt.Sprintf("private-replacement-%d", generation)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	unrelated := pendingFolderDiscoverySummaryForTest(otherID, "unrelated-preserved", now)
	if _, _, err := core.pendingFolderDiscoverySummaries.replaceDevice(otherID, []pendingFolderDiscoverySummary{unrelated}, false); err != nil {
		t.Fatal(err)
	}
	beforeDuplicate, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path)
	if err != nil {
		t.Fatal(err)
	}

	duplicateOffer := model.PendingFolderObservation{FolderID: "duplicate-discovery", Label: "Duplicate", LastSeen: now}
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-60",
		ConnectionEpoch: 60,
		PendingFolders:  []model.PendingFolderObservation{duplicateOffer, duplicateOffer},
	})
	duplicateResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 60, "duplicate")
	assertEnvelopeErrorCode(t, duplicateResponse, "pending_folder_discovery_pending")
	if after, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path); err != nil || !bytes.Equal(after, beforeDuplicate) {
		t.Fatalf("duplicate offer batch changed durable summaries: err=%v", err)
	}

	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-61",
		ConnectionEpoch: 61,
		PendingFolders: []model.PendingFolderObservation{
			{FolderID: "replace-old", Label: "Old", LastSeen: now},
			{FolderID: "replace-change", Label: "Before", LastSeen: now},
		},
	})
	firstResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 61, "replace-first")
	if !firstResponse.OK {
		t.Fatalf("first authoritative replacement failed: %+v", firstResponse.Error)
	}
	firstPayload := decodeDiscoveryCommandPayloadForTest(t, firstResponse)
	if firstPayload.PendingFolderDiscovery == nil || len(firstPayload.PendingFolderDiscovery.Offers) != 2 {
		t.Fatalf("first authoritative batch is incomplete: %+v", firstPayload.PendingFolderDiscovery)
	}
	firstEpoch := firstPayload.PendingFolderDiscovery.ConnectionEpoch
	firstChangedVersion := firstPayload.PendingFolderDiscovery.Offers[0].OfferVersion
	for _, offer := range firstPayload.PendingFolderDiscovery.Offers {
		if offer.FolderID == "replace-change" {
			firstChangedVersion = offer.OfferVersion
		}
	}

	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-62",
		ConnectionEpoch: 62,
		PendingFolders: []model.PendingFolderObservation{
			{FolderID: "replace-change", Label: "After", LastSeen: now.Add(time.Second)},
			{FolderID: "replace-new", Label: "New", LastSeen: now.Add(time.Second)},
		},
	})
	secondResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 62, "replace-second")
	if !secondResponse.OK {
		t.Fatalf("second authoritative replacement failed: %+v", secondResponse.Error)
	}
	secondPayload := decodeDiscoveryCommandPayloadForTest(t, secondResponse)
	if secondPayload.PendingFolderDiscovery == nil || len(secondPayload.PendingFolderDiscovery.Offers) != 2 || secondPayload.PendingFolderDiscovery.ConnectionEpoch == firstEpoch {
		t.Fatalf("new receive epoch did not replace the batch: %+v", secondPayload.PendingFolderDiscovery)
	}
	changedVersion := ""
	for _, offer := range secondPayload.PendingFolderDiscovery.Offers {
		if offer.FolderID == "replace-old" {
			t.Fatal("old target offer survived authoritative replacement")
		}
		if offer.FolderID == "replace-change" {
			changedVersion = offer.OfferVersion
		}
	}
	if changedVersion == "" || changedVersion == firstChangedVersion {
		t.Fatal("changed offer metadata did not advance offerVersion")
	}
	stored, _, healthy := core.pendingFolderDiscoverySummaries.snapshot()
	seen := make(map[string]bool)
	for _, summary := range stored {
		seen[summary.OfferingDeviceID+"/"+summary.FolderID] = true
	}
	if !healthy || !seen[otherID.String()+"/unrelated-preserved"] || !seen[targetID.String()+"/replace-change"] || !seen[targetID.String()+"/replace-new"] || seen[targetID.String()+"/replace-old"] {
		t.Fatalf("authoritative replacement crossed device scope: %+v", stored)
	}

	beforeDrift, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path)
	if err != nil {
		t.Fatal(err)
	}
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-63",
		ConnectionEpoch: 63,
		PendingFolders:  []model.PendingFolderObservation{{FolderID: "drift-must-not-write", Label: "Drift", LastSeen: now.Add(2 * time.Second)}},
	})
	if err := writePausedCanonicalDeviceForTest(canonicalPath, core.localDeviceID, targetID); err != nil {
		t.Fatal(err)
	}
	driftResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 63, "paused-drift")
	assertEnvelopeErrorCode(t, driftResponse, "configuration_revision_mismatch")
	if after, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path); err != nil || !bytes.Equal(after, beforeDrift) {
		t.Fatalf("paused/revision drift changed summaries: err=%v", err)
	}
	if err := os.WriteFile(canonicalPath, canonicalBefore, 0o600); err != nil {
		t.Fatal(err)
	}
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-64",
		ConnectionEpoch: 64,
		PendingFolders:  []model.PendingFolderObservation{{FolderID: "removed-must-not-write", Label: "Removed", LastSeen: now.Add(3 * time.Second)}},
	})
	if err := writeRemovedCanonicalDeviceForTest(canonicalPath, core.localDeviceID, targetID); err != nil {
		t.Fatal(err)
	}
	removedResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 64, "removed-drift")
	assertEnvelopeErrorCode(t, removedResponse, "configuration_revision_mismatch")
	if after, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path); err != nil || !bytes.Equal(after, beforeDrift) {
		t.Fatalf("removed/revision drift changed summaries: err=%v", err)
	}
	if err := os.WriteFile(canonicalPath, canonicalBefore, 0o600); err != nil {
		t.Fatal(err)
	}
	beforeStoreFailure, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path)
	if err != nil {
		t.Fatal(err)
	}
	core.pendingFolderDiscoverySummaries.mu.Lock()
	core.pendingFolderDiscoverySummaries.writeFile = func(string, []byte) error {
		return errors.New("injected discovery capture store failure")
	}
	core.pendingFolderDiscoverySummaries.mu.Unlock()
	core.runtime.eventLogger.Log(events.ClusterConfigReceived, model.ClusterConfigReceivedEventData{
		Device:          targetID,
		ConnectionID:    "private-replacement-65",
		ConnectionEpoch: 65,
		PendingFolders:  []model.PendingFolderObservation{{FolderID: "store-failure-must-not-write", Label: "Failure", LastSeen: now.Add(4 * time.Second)}},
	})
	storeFailureResponse := waitForDiscoveryObservationGenerationForTest(t, core, descriptor, 65, "store-failure")
	assertEnvelopeErrorCode(t, storeFailureResponse, "pending_folder_discovery_store_unavailable")
	if after, err := os.ReadFile(core.pendingFolderDiscoverySummaries.path); err != nil || !bytes.Equal(after, beforeStoreFailure) {
		t.Fatalf("capture store failure changed durable summaries: err=%v", err)
	}
	activeTotals := networkTransferTotalsForTest(t, core, "discovery-store-failure-active-totals")
	if !activeTotals.BudgetLimited || activeTotals.BudgetLimitBytes != 65536 {
		t.Fatalf("capture store failure lost active budget totals: %+v", activeTotals)
	}
	assertCommandOK(t, core, discoverySessionCommandForTest("replace-close", "closeSession", descriptor, false))
	finalTotals := networkTransferTotalsForTest(t, core, "discovery-store-failure-final-totals")
	if !finalTotals.BudgetLimited || finalTotals.BudgetLimitBytes != 65536 {
		t.Fatalf("capture store failure lost final budget totals: %+v", finalTotals)
	}
	if after, err := os.ReadFile(canonicalPath); err != nil || !bytes.Equal(after, canonicalBefore) {
		t.Fatalf("discovery close changed restored canonical configuration: %v", err)
	}
}

func waitForDiscoveryObservationGenerationForTest(t *testing.T, core *Core, descriptor sessionDescriptor, generation uint64, stem string) decodedEnvelope {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for attempt := 0; ; attempt++ {
		response := decodeTestEnvelope(t, mustCommand(t, core, discoverySessionCommandForTest(fmt.Sprintf("%s-%d", stem, attempt), "capturePendingFolderDiscovery", descriptor, true)))
		if core.runtime != nil && core.runtime.pendingFolderObservation != nil && core.runtime.pendingFolderObservation.generation >= generation {
			return response
		}
		if time.Now().After(deadline) {
			t.Fatalf("discovery observation generation %d was not delivered", generation)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func decodeDiscoveryCommandPayloadForTest(t *testing.T, envelope decodedEnvelope) commandPayload {
	t.Helper()
	var payload commandPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func writePausedCanonicalDeviceForTest(path string, localID, targetID protocol.DeviceID) error {
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	canonical, _, err := config.ReadXML(bytes.NewReader(contents), localID)
	if err != nil {
		return err
	}
	device, _, exists := canonical.Device(targetID)
	if !exists {
		return errors.New("target device is missing from test canonical configuration")
	}
	device.Paused = true
	canonical.SetDevice(device)
	var encoded bytes.Buffer
	if err := canonical.WriteXML(&encoded); err != nil {
		return err
	}
	return os.WriteFile(path, encoded.Bytes(), 0o600)
}

func writeRemovedCanonicalDeviceForTest(path string, localID, targetID protocol.DeviceID) error {
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	canonical, _, err := config.ReadXML(bytes.NewReader(contents), localID)
	if err != nil {
		return err
	}
	devices := canonical.Devices[:0]
	for _, device := range canonical.Devices {
		if device.DeviceID != targetID {
			devices = append(devices, device)
		}
	}
	canonical.Devices = devices
	var encoded bytes.Buffer
	if err := canonical.WriteXML(&encoded); err != nil {
		return err
	}
	return os.WriteFile(path, encoded.Bytes(), 0o600)
}

func discoverySessionCommandForTest(requestID, command string, descriptor sessionDescriptor, includeTarget bool) string {
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
		request.OfferingDeviceID = descriptor.OfferingDeviceID
	}
	return marshalCommandForTest(nil, request)
}
