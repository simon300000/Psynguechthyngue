// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestPendingDeviceSuppressionIsPrivatePersistentAndReversible(t *testing.T) {
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

	deviceID := protocol.NewDeviceID([]byte("suppressed pending device"))
	const privateLabel = "private pending label marker"
	const privateAddress = "tcp://198.51.100.55:22000/private-address-marker"
	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{
			"deviceID": deviceID.String(),
			"name":     privateLabel,
			"address":  privateAddress,
		}},
	})
	offer := findPendingDevice(t, waitForPendingDevice(t, core, deviceID.String()), deviceID.String())

	stale := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"ignore-device-stale",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": stableOfferVersion("stale-device-offer")},
	)))
	assertEnvelopeErrorCode(t, stale, "offer_version_conflict")
	extra := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"ignore-device-extra",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion, "address": privateAddress},
	)))
	assertEnvelopeErrorCode(t, extra, "invalid_request")

	ignoreRequest := commandForTest(
		"ignore-device-valid",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
	)
	assertCommandOK(t, core, ignoreRequest)
	if !core.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("device suppression was not committed to Syncthing config")
	}
	raw := core.runtime.configuration.RawCopy()
	ignored, ok := latestIgnoredDevice(raw.IgnoredDevices, deviceID)
	if !ok || ignored.Name != "" || ignored.Address != "" || ignored.Time.IsZero() {
		t.Fatalf("device suppression retained untrusted metadata: %+v", ignored)
	}
	payload := snapshotForTest(t, core, "ignored-device-snapshot")
	if containsPendingDevice(payload, deviceID.String()) {
		t.Fatal("suppressed device remained pending")
	}
	suppressed := findSuppressedPendingDevice(t, payload, deviceID.String())
	if !payload.SuppressedPendingStateAvailable || payload.SuppressedPendingDevicesTruncated {
		t.Fatalf("suppressed device projection is unavailable: %+v", payload)
	}

	accept := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"accept-after-ignore-device",
		"acceptDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
	)))
	assertEnvelopeErrorCode(t, accept, "pending_device_not_found")

	// A late event must not resurrect a suppressed offer in an authoritative snapshot.
	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": deviceID.String(), "name": "late private label"}},
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, present := core.pendingDevices.record(deviceID); present {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("late pending-device event was not delivered")
		}
		time.Sleep(10 * time.Millisecond)
	}
	payload = snapshotForTest(t, core, "ignored-device-late-event")
	if containsPendingDevice(payload, deviceID.String()) {
		t.Fatal("late event resurrected a suppressed device")
	}
	if _, present := core.pendingDevices.record(deviceID); present {
		t.Fatal("authoritative snapshot did not prune the late suppressed-device projection")
	}

	configData, err := os.ReadFile(filepath.Join(home, "Config", "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{privateLabel, privateAddress, "late private label"} {
		if strings.Contains(string(configData), marker) {
			t.Fatalf("Syncthing config retained untrusted pending metadata %q", marker)
		}
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
	if !reloaded.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("device suppression did not survive reconstruction")
	}
	reloadedPayload := snapshotForTest(t, reloaded, "ignored-device-reloaded")
	findSuppressedPendingDevice(t, reloadedPayload, deviceID.String())

	badUndo := decodeTestEnvelope(t, reloaded.CommandJSON(commandForTest(
		"unignore-device-stale",
		"unignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"suppressionVersion": stableOfferVersion("stale-device-suppression")},
	)))
	assertEnvelopeErrorCode(t, badUndo, "suppression_version_conflict")
	assertCommandOK(t, reloaded, commandForTest(
		"unignore-device-valid",
		"unignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"suppressionVersion": suppressed.SuppressionVersion},
	))
	if reloaded.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("device suppression was not removed")
	}
	if containsSuppressedPendingDevice(snapshotForTest(t, reloaded, "unignored-device"), deviceID.String()) {
		t.Fatal("removed device suppression remained in snapshot")
	}
	assertCommandOK(t, reloaded, commandForTest(
		"unignore-device-idempotent",
		"unignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"suppressionVersion": suppressed.SuppressionVersion},
	))

	reloaded.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": deviceID.String(), "name": "reannounced"}},
	})
	reannounced := findPendingDevice(t, waitForPendingDevice(t, reloaded, deviceID.String()), deviceID.String())
	assertCommandOK(t, reloaded, commandForTest(
		"reignore-device",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": reannounced.OfferVersion},
	))
	resuppressed := findSuppressedPendingDevice(
		t,
		snapshotForTest(t, reloaded, "resuppressed-device"),
		deviceID.String(),
	)
	if resuppressed.SuppressionVersion == suppressed.SuppressionVersion {
		t.Fatal("re-suppression reused the prior suppression version")
	}
	staleAfterResuppression := decodeTestEnvelope(t, reloaded.CommandJSON(commandForTest(
		"unignore-device-after-resuppression",
		"unignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"suppressionVersion": suppressed.SuppressionVersion},
	)))
	assertEnvelopeErrorCode(t, staleAfterResuppression, "suppression_version_conflict")
	if !reloaded.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("stale undo removed a newer device suppression")
	}
}

func TestPendingFolderSuppressionIsScopedAllowsEncryptedAndIsReversible(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	firstDevice := protocol.NewDeviceID([]byte("first suppression folder peer"))
	secondDevice := protocol.NewDeviceID([]byte("second suppression folder peer"))
	assertCommandOK(t, core, commandForTest("suppress-folder-first-device", "addDevice", "", firstDevice.String(), nil))
	assertCommandOK(t, core, commandForTest("suppress-folder-second-device", "addDevice", "", secondDevice.String(), nil))

	firstOffer := pendingFolderOffer{
		FolderID:         "same-folder",
		Label:            "private first folder label",
		OfferingDeviceID: firstDevice,
		LastSeen:         time.Date(2026, 8, 9, 6, 7, 8, 0, time.UTC),
		RemoteEncrypted:  true,
	}
	secondOffer := firstOffer
	secondOffer.Label = "private second folder label"
	secondOffer.OfferingDeviceID = secondDevice
	secondOffer.LastSeen = firstOffer.LastSeen.Add(time.Second)
	secondOffer.RemoteEncrypted = false
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(firstOffer, secondOffer)
	stale := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"ignore-folder-stale",
		"ignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": firstDevice.String(),
			"offerVersion":     stableOfferVersion("stale-folder-offer"),
		},
	)))
	assertEnvelopeErrorCode(t, stale, "offer_version_conflict")

	extra := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"ignore-folder-extra",
		"ignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": firstDevice.String(),
			"offerVersion":     pendingFolderOfferVersion(firstOffer),
			"path":             "/private/remote/path",
		},
	)))
	assertEnvelopeErrorCode(t, extra, "invalid_request")
	assertCommandOK(t, core, commandForTest(
		"ignore-folder-valid",
		"ignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": firstDevice.String(),
			"offerVersion":     pendingFolderOfferVersion(firstOffer),
		},
	))
	firstConfig, ok := core.runtime.configuration.Device(firstDevice)
	if !ok || !firstConfig.IgnoredFolder(firstOffer.FolderID) {
		t.Fatal("folder suppression was not committed to the offering device")
	}
	ignoredFolder, ok := latestIgnoredFolder(firstConfig.IgnoredFolders, firstOffer.FolderID)
	if !ok || ignoredFolder.Label != "" || ignoredFolder.Time.IsZero() {
		t.Fatalf("folder suppression retained untrusted metadata: %+v", ignoredFolder)
	}
	secondConfig, _ := core.runtime.configuration.Device(secondDevice)
	if secondConfig.IgnoredFolder(firstOffer.FolderID) {
		t.Fatal("folder suppression leaked to a different offering device")
	}

	payload := snapshotForTest(t, core, "ignored-folder-scoped")
	if len(payload.PendingFolders) != 1 || payload.PendingFolders[0].OfferingDeviceID != secondDevice.String() {
		t.Fatalf("folder suppression did not preserve the other peer offer: %+v", payload.PendingFolders)
	}
	suppressed := findSuppressedPendingFolder(t, payload, firstOffer.FolderID, firstDevice.String())

	accept := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"accept-after-ignore-folder",
		"acceptFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": firstDevice.String(),
			"offerVersion":     pendingFolderOfferVersion(firstOffer),
			"path":             t.TempDir(),
			"type":             "receiveOnly",
			"deviceIDs":        firstDevice.String(),
		},
	)))
	assertEnvelopeErrorCode(t, accept, "pending_folder_not_found")
	staleUndo := decodeTestEnvelope(t, core.CommandJSON(commandForTest(
		"unignore-folder-stale",
		"unignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID":   firstDevice.String(),
			"suppressionVersion": stableOfferVersion("stale-folder-suppression"),
		},
	)))
	assertEnvelopeErrorCode(t, staleUndo, "suppression_version_conflict")

	assertCommandOK(t, core, commandForTest(
		"unignore-folder-valid",
		"unignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID":   firstDevice.String(),
			"suppressionVersion": suppressed.SuppressionVersion,
		},
	))
	firstConfig, _ = core.runtime.configuration.Device(firstDevice)
	if firstConfig.IgnoredFolder(firstOffer.FolderID) {
		t.Fatal("folder suppression was not removed")
	}
	if containsSuppressedPendingFolder(
		snapshotForTest(t, core, "unignored-folder"),
		firstOffer.FolderID,
		firstDevice.String(),
	) {
		t.Fatal("removed folder suppression remained in snapshot")
	}
	assertCommandOK(t, core, commandForTest(
		"unignore-folder-idempotent",
		"unignorePendingFolder",
		firstOffer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID":   firstDevice.String(),
			"suppressionVersion": suppressed.SuppressionVersion,
		},
	))
}

func TestPendingFolderSuppressionSurvivesCoreReconstruction(t *testing.T) {
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
	deviceID := protocol.NewDeviceID([]byte("restart suppression folder peer"))
	assertCommandOK(t, core, commandForTest("restart-suppression-device", "addDevice", "", deviceID.String(), nil))
	offer := pendingFolderOffer{
		FolderID:         "restart-suppressed-folder",
		OfferingDeviceID: deviceID,
		LastSeen:         time.Date(2026, 8, 9, 9, 10, 11, 0, time.UTC),
	}
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	assertCommandOK(t, core, commandForTest(
		"restart-ignore-folder",
		"ignorePendingFolder",
		offer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": deviceID.String(),
			"offerVersion":     pendingFolderOfferVersion(offer),
		},
	))
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
	device, ok := reloaded.runtime.configuration.Device(deviceID)
	if !ok || !device.IgnoredFolder(offer.FolderID) {
		t.Fatal("folder suppression did not survive reconstruction")
	}
	findSuppressedPendingFolder(
		t,
		snapshotForTest(t, reloaded, "restart-suppressed-folder"),
		offer.FolderID,
		deviceID.String(),
	)
}

func TestSuppressedPendingSnapshotCapsBothCollections(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	offeringDevice := protocol.NewDeviceID([]byte("suppression snapshot cap peer"))
	assertCommandOK(t, core, commandForTest("suppression-cap-peer", "addDevice", "", offeringDevice.String(), nil))

	waiter, err := core.runtime.configuration.Modify(func(current *config.Configuration) {
		for index := 0; index < maxSuppressedPendingSnapshots+1; index++ {
			deviceID := protocol.NewDeviceID([]byte("ignored snapshot device " + time.Unix(int64(index), 0).String()))
			current.IgnoredDevices = append(current.IgnoredDevices, config.ObservedDevice{
				ID:   deviceID,
				Time: time.Unix(int64(index+1), 0).UTC(),
			})
		}
		device, _, ok := current.Device(offeringDevice)
		if !ok {
			return
		}
		for index := 0; index < maxSuppressedPendingSnapshots+1; index++ {
			device.IgnoredFolders = append(device.IgnoredFolders, config.ObservedFolder{
				ID:   "ignored-folder-" + time.Unix(int64(index), 0).Format("150405.000000000"),
				Time: time.Unix(int64(index+1), 0).UTC(),
			})
		}
		current.SetDevice(device)
	})
	if err != nil {
		t.Fatal(err)
	}
	waiter.Wait()
	if err := core.runtime.configuration.Save(); err != nil {
		t.Fatal(err)
	}
	payload := snapshotForTest(t, core, "suppression-snapshot-cap")
	if len(payload.SuppressedPendingDevices) != maxSuppressedPendingSnapshots ||
		!payload.SuppressedPendingDevicesTruncated {
		t.Fatalf("device suppression cap was not enforced: %d truncated=%t", len(payload.SuppressedPendingDevices), payload.SuppressedPendingDevicesTruncated)
	}
	if len(payload.SuppressedPendingFolders) != maxSuppressedPendingSnapshots ||
		!payload.SuppressedPendingFoldersTruncated {
		t.Fatalf("folder suppression cap was not enforced: %d truncated=%t", len(payload.SuppressedPendingFolders), payload.SuppressedPendingFoldersTruncated)
	}
}

func TestPendingSuppressionCommandsReplayFailedLedgerEntriesSafely(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	deviceID := protocol.NewDeviceID([]byte("suppression replay peer"))
	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": deviceID.String(), "name": "Replay Peer"}},
	})
	offer := findPendingDevice(t, waitForPendingDevice(t, core, deviceID.String()), deviceID.String())
	request := commandForTest(
		"replay-ignore-pending-device",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
	)
	var parsed commandRequest
	if err := decodeRequest(request, &parsed); err != nil {
		t.Fatal(err)
	}
	digest, err := commandDigest(parsed)
	if err != nil {
		t.Fatal(err)
	}
	failed, err := failureEnvelope(parsed.RequestID, "command", "configuration_save_failed", "the configuration was not saved")
	if err != nil {
		t.Fatal(err)
	}
	core.commandLedger.entries[parsed.RequestID] = commandLedgerEntry{
		RequestID: parsed.RequestID,
		Digest:    hex.EncodeToString(digest[:]),
		State:     commandStateCompleted,
		Response:  failed,
	}
	if err := core.commandLedger.save(); err != nil {
		t.Fatal(err)
	}
	response := core.CommandJSON(request)
	if response == failed {
		t.Fatal("completed suppression failure was replayed instead of safely retried")
	}
	if envelope := decodeTestEnvelope(t, response); !envelope.OK {
		t.Fatalf("replay-safe suppression did not succeed: %+v", envelope.Error)
	}
	if !core.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("replayed suppression did not reach its desired postcondition")
	}

	// A new request for the already-achieved postcondition remains idempotent
	// even though the original pending offer has been removed.
	assertCommandOK(t, core, commandForTest(
		"ignore-device-idempotent",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
	))
}

func TestPendingSuppressionRetriesAfterLedgerCompletionWriteFailure(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	deviceID := protocol.NewDeviceID([]byte("suppression completion failure peer"))
	core.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": deviceID.String(), "name": "Completion Failure Peer"}},
	})
	offer := findPendingDevice(t, waitForPendingDevice(t, core, deviceID.String()), deviceID.String())
	request := commandForTest(
		"replay-ignore-after-ledger-completion-failure",
		"ignorePendingDevice",
		"",
		deviceID.String(),
		map[string]string{"offerVersion": offer.OfferVersion},
	)

	originalWrite := core.commandLedger.writeFile
	writes := 0
	core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected suppression completion write failure")
		}
		return originalWrite(path, data)
	}
	response := decodeTestEnvelope(t, core.CommandJSON(request))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if !core.runtime.configuration.IgnoredDevice(deviceID) {
		t.Fatal("suppression was not applied before the ledger completion failure")
	}
	entry := core.commandLedger.entries["replay-ignore-after-ledger-completion-failure"]
	if entry.State != commandStatePending || entry.Response != "" {
		t.Fatalf("ledger completion failure did not remain replayable: %+v", entry)
	}

	generationAfterFailure := core.generation
	core.commandLedger.writeFile = originalWrite
	retry := decodeTestEnvelope(t, core.CommandJSON(request))
	if !retry.OK {
		t.Fatalf("replay after ledger completion failure did not succeed: %+v", retry.Error)
	}
	if core.generation <= generationAfterFailure {
		t.Fatal("already-achieved suppression replay did not force a configuration Save")
	}
}

func TestPendingSuppressionCommandReplayClassification(t *testing.T) {
	for _, command := range []string{
		"ignorePendingDevice",
		"unignorePendingDevice",
		"ignorePendingFolder",
		"unignorePendingFolder",
	} {
		if !commandCanReplayAfterFailure(command) {
			t.Fatalf("postcondition-idempotent command %s is not replay-safe", command)
		}
	}
	if commandCanReplayAfterFailure("acceptDevice") || commandCanReplayAfterFailure("acceptFolder") {
		t.Fatal("acceptance commands must remain non-replay-safe")
	}
}

func findSuppressedPendingDevice(t *testing.T, payload snapshotPayload, deviceID string) suppressedPendingDeviceSnapshot {
	t.Helper()
	for _, suppressed := range payload.SuppressedPendingDevices {
		if suppressed.DeviceID == deviceID {
			return suppressed
		}
	}
	t.Fatalf("suppressed pending device %s is missing", deviceID)
	return suppressedPendingDeviceSnapshot{}
}

func containsSuppressedPendingDevice(payload snapshotPayload, deviceID string) bool {
	for _, suppressed := range payload.SuppressedPendingDevices {
		if suppressed.DeviceID == deviceID {
			return true
		}
	}
	return false
}

func findSuppressedPendingFolder(t *testing.T, payload snapshotPayload, folderID, deviceID string) suppressedPendingFolderSnapshot {
	t.Helper()
	for _, suppressed := range payload.SuppressedPendingFolders {
		if suppressed.FolderID == folderID && suppressed.OfferingDeviceID == deviceID {
			return suppressed
		}
	}
	t.Fatalf("suppressed pending folder %s from %s is missing", folderID, deviceID)
	return suppressedPendingFolderSnapshot{}
}

func containsSuppressedPendingFolder(payload snapshotPayload, folderID, deviceID string) bool {
	for _, suppressed := range payload.SuppressedPendingFolders {
		if suppressed.FolderID == folderID && suppressed.OfferingDeviceID == deviceID {
			return true
		}
	}
	return false
}
