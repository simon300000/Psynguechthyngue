// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestPendingDeviceEventProjectionPersistsAndAcceptsWithoutTrustingAddress(t *testing.T) {
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
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	remoteID := protocol.NewDeviceID([]byte("pending device event peer"))
	removedID := protocol.NewDeviceID([]byte("pending device removed peer"))
	const untrustedAddress = "tcp://198.51.100.42:22000/private-address-marker"
	const arbitraryEventData = "/private/remote/secret-path-marker"
	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]any{
			{
				"deviceID": remoteID.String(),
				"name":     "Unverified Peer",
				"address":  untrustedAddress,
				"path":     arbitraryEventData,
			},
			{
				"deviceID": removedID.String(),
				"name":     "Removed Peer",
			},
		},
		"upstreamError": arbitraryEventData,
	})
	payload := waitForPendingDevice(t, core, remoteID.String())
	if len(payload.PendingDevices) != 2 || payload.PendingDeviceObservationScope != "bridgeEventsPersisted" {
		t.Fatalf("unexpected pending device projection: %+v", payload.PendingDevices)
	}
	rawSnapshot := core.SnapshotJSON(`{"schemaVersion":1,"requestID":"pending-device-privacy"}`)
	if strings.Contains(rawSnapshot, untrustedAddress) || strings.Contains(rawSnapshot, arbitraryEventData) {
		t.Fatalf("snapshot leaked arbitrary pending event data: %s", rawSnapshot)
	}
	storeData, err := os.ReadFile(filepath.Join(home, "Bridge", "pending-devices-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(storeData), untrustedAddress) || strings.Contains(string(storeData), arbitraryEventData) {
		t.Fatalf("pending device store leaked arbitrary event data: %s", storeData)
	}
	if info, err := os.Stat(filepath.Join(home, "Bridge", "pending-devices-v1.json")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("pending device store is not protected: info=%v err=%v", info, err)
	}

	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"removed": []map[string]string{{"deviceID": removedID.String()}},
	})
	waitForPendingDeviceRemoval(t, core, removedID.String())

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
	if err := reloaded.Start(); err != nil {
		t.Fatal(err)
	}
	persisted := waitForPendingDevice(t, reloaded, remoteID.String())
	if containsPendingDevice(persisted, removedID.String()) {
		t.Fatal("removed pending device reappeared after Core reconstruction")
	}
	offer := findPendingDevice(t, persisted, remoteID.String())

	unsupportedAddress := decodeTestEnvelope(t, reloaded.CommandJSON(commandForTest(
		"accept-device-address",
		"acceptDevice",
		"",
		remoteID.String(),
		map[string]string{"offerVersion": offer.OfferVersion, "addresses": untrustedAddress},
	)))
	assertEnvelopeErrorCode(t, unsupportedAddress, "invalid_request")
	staleVersion := decodeTestEnvelope(t, reloaded.CommandJSON(commandForTest(
		"accept-device-stale",
		"acceptDevice",
		"",
		remoteID.String(),
		map[string]string{"offerVersion": "stale"},
	)))
	assertEnvelopeErrorCode(t, staleVersion, "offer_version_conflict")

	assertCommandOK(t, reloaded, commandForTest(
		"accept-device-valid",
		"acceptDevice",
		"",
		remoteID.String(),
		map[string]string{"offerVersion": offer.OfferVersion, "name": "Confirmed Peer"},
	))
	assertPendingDeviceCommandError(
		t,
		reloaded,
		"accept-device-state-conflict",
		remoteID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
		"device_state_conflict",
	)
	configured, ok := reloaded.runtime.configuration.Device(remoteID)
	if !ok || configured.Name != "Confirmed Peer" {
		t.Fatalf("accepted device was not configured: %+v", configured)
	}
	for _, address := range configured.Addresses {
		if strings.Contains(address, "198.51.100.42") || strings.Contains(address, "private-address-marker") {
			t.Fatalf("acceptDevice trusted the observed remote address: %q", address)
		}
	}
	if containsPendingDevice(snapshotForTest(t, reloaded, "accepted-device-snapshot"), remoteID.String()) {
		t.Fatal("accepted device remained pending")
	}
	// A connection event already queued before the configuration update may be
	// delivered late. The next authoritative snapshot must prune that stale
	// projection so removing the configured device later cannot resurrect it.
	reloaded.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": remoteID.String(), "name": "Late Stale Event"}},
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, present := reloaded.pendingDevices.record(remoteID); present {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("late pending device event was not observed")
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = snapshotForTest(t, reloaded, "prune-stale-pending-device")
	if _, present := reloaded.pendingDevices.record(remoteID); present {
		t.Fatal("configured device was retained in the pending device store")
	}

	if err := reloaded.Close(); err != nil {
		t.Fatal(err)
	}
	current = nil
	persistedCore, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	current = persistedCore
	persistedCore.disableNetworkingForTests = true
	if err := persistedCore.Start(); err != nil {
		t.Fatal(err)
	}
	if configured, ok := persistedCore.runtime.configuration.Device(remoteID); !ok || configured.Name != "Confirmed Peer" {
		t.Fatalf("accepted device did not persist across reconstruction: %+v", configured)
	}
}

func TestPendingFolderProjectionAndAcceptanceUsesOnlyCallerManagedConfiguration(t *testing.T) {
	home := t.TempDir()
	managedPath := t.TempDir()
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
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	offeringDeviceID := protocol.NewDeviceID([]byte("pending folder offering peer"))
	otherDeviceID := protocol.NewDeviceID([]byte("pending folder explicit peer"))
	assertCommandOK(t, core, commandForTest("pending-folder-device", "addDevice", "", offeringDeviceID.String(), map[string]string{"name": "Offerer"}))
	assertCommandOK(t, core, commandForTest("pending-folder-other-device", "addDevice", "", otherDeviceID.String(), map[string]string{"name": "Explicit Peer"}))

	offer := pendingFolderOffer{
		FolderID:         "offered-folder",
		Label:            "Remote Label",
		OfferingDeviceID: offeringDeviceID,
		LastSeen:         time.Date(2026, 8, 9, 3, 4, 5, 6, time.UTC),
	}
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	payload := snapshotForTest(t, core, "pending-folder-snapshot")
	if !payload.PendingFoldersAvailable || len(payload.PendingFolders) != 1 {
		t.Fatalf("pending folder projection is unavailable: %+v", payload.PendingFolders)
	}
	projected := payload.PendingFolders[0]
	if projected.FolderID != offer.FolderID || projected.OfferingDeviceID != offeringDeviceID.String() ||
		!projected.RequiresManagedLocalPath || !projected.RequiresExplicitDeviceSelection {
		t.Fatalf("unexpected pending folder projection: %+v", projected)
	}

	baseArguments := map[string]string{
		"offeringDeviceID": offeringDeviceID.String(),
		"offerVersion":     projected.OfferVersion,
		"path":             managedPath,
		"type":             "receiveOnly",
		"deviceIDs":        `[` + quoteJSONForTest(offeringDeviceID.String()) + `,` + quoteJSONForTest(otherDeviceID.String()) + `]`,
		"label":            "Locally Confirmed Label",
	}
	missingOfferer := cloneStringMap(baseArguments)
	missingOfferer["deviceIDs"] = otherDeviceID.String()
	assertPendingCommandError(t, core, "folder-missing-offerer", offer.FolderID, missingOfferer, "offering_device_not_selected")
	stale := cloneStringMap(baseArguments)
	stale["offerVersion"] = "stale"
	assertPendingCommandError(t, core, "folder-stale", offer.FolderID, stale, "offer_version_conflict")
	unknownArgument := cloneStringMap(baseArguments)
	unknownArgument["remotePath"] = "/untrusted/remote/path"
	assertPendingCommandError(t, core, "folder-unknown-argument", offer.FolderID, unknownArgument, "invalid_request")
	invalidPath := cloneStringMap(baseArguments)
	invalidPath["path"] = "../../escape"
	assertPendingCommandError(t, core, "folder-invalid-path", offer.FolderID, invalidPath, "invalid_path")

	assertCommandOK(t, core, commandForTest("accept-folder-valid", "acceptFolder", offer.FolderID, "", baseArguments))
	assertPendingCommandError(t, core, "accept-folder-state-conflict", offer.FolderID, baseArguments, "folder_state_conflict")
	folder, ok := core.runtime.configuration.Folder(offer.FolderID)
	if !ok {
		t.Fatal("accepted folder was not configured")
	}
	if folder.Path != filepath.Clean(managedPath) || folder.Type.String() != "receiveonly" || folder.Label != "Locally Confirmed Label" {
		t.Fatalf("accepted folder did not use caller-managed values: %+v", folder)
	}
	if len(folder.Devices) != 3 || !folder.SharedWith(offeringDeviceID) || !folder.SharedWith(otherDeviceID) || !folder.SharedWith(core.localDeviceID) {
		t.Fatalf("accepted folder has an unexpected share list: %+v", folder.Devices)
	}
	if len(snapshotForTest(t, core, "accepted-folder-snapshot").PendingFolders) != 0 {
		t.Fatal("accepted folder remained in the pending projection")
	}

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
	if err := reloaded.Start(); err != nil {
		t.Fatal(err)
	}
	if persisted, ok := reloaded.runtime.configuration.Folder(offer.FolderID); !ok || persisted.Path != filepath.Clean(managedPath) || !persisted.SharedWith(offeringDeviceID) {
		t.Fatalf("accepted folder did not persist across reconstruction: %+v", persisted)
	}
}

func TestPendingAcceptanceFailsClosedForMissingChangedAndEncryptedOffers(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	offeringDeviceID := protocol.NewDeviceID([]byte("pending failure offering peer"))
	assertCommandOK(t, core, commandForTest("pending-failure-device", "addDevice", "", offeringDeviceID.String(), nil))

	unknownDeviceID := protocol.NewDeviceID([]byte("unknown pending device"))
	assertPendingDeviceCommandError(t, core, "missing-device", unknownDeviceID.String(), map[string]string{"offerVersion": "unknown"}, "pending_device_not_found")

	offer := pendingFolderOffer{
		FolderID:         "encrypted-offer",
		Label:            "Encrypted",
		OfferingDeviceID: offeringDeviceID,
		LastSeen:         time.Date(2026, 8, 9, 4, 5, 6, 0, time.UTC),
		RemoteEncrypted:  true,
	}
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	arguments := map[string]string{
		"offeringDeviceID": offeringDeviceID.String(),
		"offerVersion":     pendingFolderOfferVersion(offer),
		"path":             t.TempDir(),
		"type":             "receiveOnly",
		"deviceIDs":        offeringDeviceID.String(),
	}
	assertPendingCommandError(t, core, "encrypted-folder", offer.FolderID, arguments, "encrypted_folder_type_mismatch")

	offer.ReceiveEncrypted = true
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	invalidEncrypted := cloneStringMap(arguments)
	invalidEncrypted["offerVersion"] = pendingFolderOfferVersion(offer)
	invalidEncrypted["type"] = "receiveEncrypted"
	invalidEncrypted["rescanIntervalS"] = "86400"
	assertPendingCommandError(t, core, "invalid-encrypted-folder", offer.FolderID, invalidEncrypted, "invalid_encrypted_offer")

	offer.RemoteEncrypted = false
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	tooFrequent := cloneStringMap(invalidEncrypted)
	tooFrequent["offerVersion"] = pendingFolderOfferVersion(offer)
	tooFrequent["rescanIntervalS"] = "3600"
	assertPendingCommandError(t, core, "encrypted-folder-frequent-rescan", offer.FolderID, tooFrequent, "invalid_request")
	missingOffer := cloneStringMap(arguments)
	missingOffer["offerVersion"] = pendingFolderOfferVersion(offer)
	assertPendingCommandError(t, core, "missing-folder-offer", "different-folder", missingOffer, "pending_folder_not_found")

	core.pendingFolderOffersForTests = func(protocol.DeviceID) ([]pendingFolderOffer, error) {
		return nil, errors.New("private upstream failure /must/not/leak")
	}
	unavailable := decodeTestEnvelope(t, core.CommandJSON(commandForTest("pending-unavailable", "acceptFolder", "missing", "", arguments)))
	assertEnvelopeErrorCode(t, unavailable, "pending_state_unavailable")
	if strings.Contains(unavailable.Error.Message, "private upstream") || strings.Contains(unavailable.Error.Message, "/must/not/leak") {
		t.Fatalf("acceptFolder leaked an upstream error: %+v", unavailable.Error)
	}
}

func TestPendingDeviceStoreRejectsUnsafeOrInvalidState(t *testing.T) {
	validRecord := pendingDeviceRecord{
		DeviceID: protocol.NewDeviceID([]byte("valid pending store peer")).String(),
		Label:    "Peer",
		LastSeen: time.Date(2026, 8, 9, 1, 2, 3, 0, time.UTC).Format(time.RFC3339Nano),
	}
	validJSON := `{"schemaVersion":1,"devices":[{"deviceID":"` + validRecord.DeviceID + `","label":"Peer","lastSeen":"` + validRecord.LastSeen + `"}]}`

	tests := []struct {
		name  string
		write func(t *testing.T, path string)
	}{
		{
			name: "unknown field",
			write: func(t *testing.T, path string) {
				t.Helper()
				writePendingStoreForTest(t, path, []byte(strings.TrimSuffix(validJSON, "}")+`,"unexpected":"secret"}`), 0o600)
			},
		},
		{
			name: "oversize",
			write: func(t *testing.T, path string) {
				t.Helper()
				writePendingStoreForTest(t, path, make([]byte, maxPendingDeviceStoreSize+1), 0o600)
			},
		},
		{
			name: "wrong permissions",
			write: func(t *testing.T, path string) {
				t.Helper()
				writePendingStoreForTest(t, path, []byte(validJSON), 0o644)
			},
		},
		{
			name: "symlink",
			write: func(t *testing.T, path string) {
				t.Helper()
				target := filepath.Join(filepath.Dir(filepath.Dir(path)), "outside.json")
				if err := os.WriteFile(target, []byte(validJSON), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, path); err != nil {
					t.Fatal(err)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			home := t.TempDir()
			path := filepath.Join(home, "Bridge", "pending-devices-v1.json")
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			test.write(t, path)
			if _, err := loadPendingDeviceStore(home); err == nil {
				t.Fatal("unsafe pending device store was accepted")
			}
		})
	}
}

func pendingFolderSourceForTest(offers ...pendingFolderOffer) func(protocol.DeviceID) ([]pendingFolderOffer, error) {
	return func(filter protocol.DeviceID) ([]pendingFolderOffer, error) {
		result := make([]pendingFolderOffer, 0, len(offers))
		for _, offer := range offers {
			if filter == protocol.EmptyDeviceID || filter == offer.OfferingDeviceID {
				result = append(result, offer)
			}
		}
		return result, nil
	}
}

func waitForPendingDevice(t *testing.T, core *Core, deviceID string) snapshotPayload {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		payload := snapshotForTest(t, core, "wait-pending-device")
		if containsPendingDevice(payload, deviceID) {
			return payload
		}
		if time.Now().After(deadline) {
			t.Fatalf("pending device %s was not projected", deviceID)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func waitForPendingDeviceRemoval(t *testing.T, core *Core, deviceID string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if !containsPendingDevice(snapshotForTest(t, core, "wait-pending-removal"), deviceID) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("pending device %s was not removed", deviceID)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func containsPendingDevice(payload snapshotPayload, deviceID string) bool {
	for _, pending := range payload.PendingDevices {
		if pending.DeviceID == deviceID {
			return true
		}
	}
	return false
}

func findPendingDevice(t *testing.T, payload snapshotPayload, deviceID string) pendingDeviceSnapshot {
	t.Helper()
	for _, pending := range payload.PendingDevices {
		if pending.DeviceID == deviceID {
			return pending
		}
	}
	t.Fatalf("pending device %s is missing", deviceID)
	return pendingDeviceSnapshot{}
}

func assertPendingDeviceCommandError(t *testing.T, core *Core, requestID, deviceID string, arguments map[string]string, code string) {
	t.Helper()
	envelope := decodeTestEnvelope(t, core.CommandJSON(commandForTest(requestID, "acceptDevice", "", deviceID, arguments)))
	assertEnvelopeErrorCode(t, envelope, code)
}

func assertPendingCommandError(t *testing.T, core *Core, requestID, folderID string, arguments map[string]string, code string) {
	t.Helper()
	envelope := decodeTestEnvelope(t, core.CommandJSON(commandForTest(requestID, "acceptFolder", folderID, "", arguments)))
	assertEnvelopeErrorCode(t, envelope, code)
}

func cloneStringMap(source map[string]string) map[string]string {
	copy := make(map[string]string, len(source))
	for key, value := range source {
		copy[key] = value
	}
	return copy
}

func quoteJSONForTest(value string) string {
	return `"` + value + `"`
}

func writePendingStoreForTest(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
}
