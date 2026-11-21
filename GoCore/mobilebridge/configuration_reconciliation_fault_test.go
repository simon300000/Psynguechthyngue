// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestConfigurationCommandsReconcileRealCompletionFailuresWithoutReplay(t *testing.T) {
	home := t.TempDir()
	core := newRunningConfigurationReconciliationCore(t, home, nil)
	identity := core.IdentityBlob()
	current := core
	t.Cleanup(func() { _ = current.Close() })
	remote := protocol.NewDeviceID([]byte("configuration reconciliation matrix peer"))
	folderID := "configuration-reconciliation-folder"
	firstPath := t.TempDir()
	secondPath := t.TempDir()

	addDevice := commandForTest("reconcile-add-device", "addDevice", "", remote.String(), map[string]string{
		"name":      "Initial Peer",
		"addresses": `["dynamic","tcp://127.0.0.1:22000"]`,
		"paused":    "false",
	})
	injectConfigurationCompletionFailure(t, current, addDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, addDevice, 2)
	device, ok := current.runtime.configuration.Device(remote)
	if !ok || device.Name != "Initial Peer" || device.Paused || len(device.Addresses) != 2 {
		t.Fatalf("addDevice postcondition was not durable: %+v", device)
	}

	editDevice := commandForTest("reconcile-edit-device", "editDevice", "", remote.String(), map[string]string{
		"name":      "Edited Peer",
		"addresses": "tcp://127.0.0.1:23000",
		"paused":    "true",
	})
	injectConfigurationCompletionFailure(t, current, editDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, editDevice, 3)
	device, _ = current.runtime.configuration.Device(remote)
	if device.Name != "Edited Peer" || !device.Paused || len(device.Addresses) != 1 {
		t.Fatalf("editDevice postcondition was not durable: %+v", device)
	}

	resumeDevice := commandForTest("reconcile-resume-device", "resume", "", remote.String(), nil)
	injectConfigurationCompletionFailure(t, current, resumeDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, resumeDevice, 4)
	device, _ = current.runtime.configuration.Device(remote)
	if device.Paused {
		t.Fatal("device resume postcondition was not durable")
	}

	pauseDevice := commandForTest("reconcile-pause-device", "pause", "", remote.String(), nil)
	injectConfigurationCompletionFailure(t, current, pauseDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, pauseDevice, 5)
	device, _ = current.runtime.configuration.Device(remote)
	if !device.Paused {
		t.Fatal("device pause postcondition was not durable")
	}

	addFolder := commandForTest("reconcile-add-folder", "addFolder", folderID, "", map[string]string{
		"label":           "Initial Folder",
		"path":            firstPath,
		"type":            "sendOnly",
		"paused":          "true",
		"deviceIDs":       remote.String(),
		"rescanIntervalS": "120",
	})
	injectConfigurationCompletionFailure(t, current, addFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, addFolder, 6)
	folder, ok := current.runtime.configuration.Folder(folderID)
	if !ok || folder.Label != "Initial Folder" || folder.Path != filepath.Clean(firstPath) ||
		bridgeFolderType(folder.Type) != "sendOnly" || !folder.Paused || folder.RescanIntervalS != 120 || !folder.SharedWith(remote) {
		t.Fatalf("addFolder postcondition was not durable: %+v", folder)
	}

	editFolder := commandForTest("reconcile-edit-folder", "editFolder", folderID, "", map[string]string{
		"label":           "Edited Folder",
		"path":            secondPath,
		"type":            "sendReceive",
		"paused":          "false",
		"deviceIDs":       remote.String(),
		"rescanIntervalS": "300",
	})
	injectConfigurationCompletionFailure(t, current, editFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, editFolder, 7)
	folder, _ = current.runtime.configuration.Folder(folderID)
	if folder.Label != "Edited Folder" || folder.Path != filepath.Clean(secondPath) ||
		bridgeFolderType(folder.Type) != "sendReceive" || folder.Paused || folder.RescanIntervalS != 300 || !folder.SharedWith(remote) {
		t.Fatalf("editFolder postcondition was not durable: %+v", folder)
	}

	pauseFolder := commandForTest("reconcile-pause-folder", "pause", folderID, "", nil)
	injectConfigurationCompletionFailure(t, current, pauseFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, pauseFolder, 8)
	folder, _ = current.runtime.configuration.Folder(folderID)
	if !folder.Paused {
		t.Fatal("folder pause postcondition was not durable")
	}

	resumeFolder := commandForTest("reconcile-resume-folder", "resume", folderID, "", nil)
	injectConfigurationCompletionFailure(t, current, resumeFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, resumeFolder, 9)
	folder, _ = current.runtime.configuration.Folder(folderID)
	if folder.Paused {
		t.Fatal("folder resume postcondition was not durable")
	}

	removeFolder := commandForTest(
		"reconcile-remove-folder",
		"removeFolder",
		folderID,
		"",
		map[string]string{"deleteData": "false"},
	)
	injectConfigurationCompletionFailure(t, current, removeFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, removeFolder, 10)
	if _, exists := current.runtime.configuration.Folder(folderID); exists {
		t.Fatal("removeFolder postcondition was not durable")
	}

	removeDevice := commandForTest("reconcile-remove-device", "removeDevice", "", remote.String(), nil)
	injectConfigurationCompletionFailure(t, current, removeDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, removeDevice, 11)
	if _, exists := current.runtime.configuration.Device(remote); exists {
		t.Fatal("removeDevice postcondition was not durable")
	}
}

func TestAcceptanceCommandsReconcileRealCompletionFailuresAfterPendingStateConsumption(t *testing.T) {
	home := t.TempDir()
	core := newRunningConfigurationReconciliationCore(t, home, nil)
	identity := core.IdentityBlob()
	current := core
	t.Cleanup(func() { _ = current.Close() })
	offeringDevice := protocol.NewDeviceID([]byte("configuration reconciliation accepted peer"))
	current.runtime.eventLogger.Log(events.PendingDevicesChanged, map[string]any{
		"added": []map[string]string{{"deviceID": offeringDevice.String(), "name": "Observed Peer"}},
	})
	offer := findPendingDevice(t, waitForPendingDevice(t, current, offeringDevice.String()), offeringDevice.String())
	acceptDevice := commandForTest(
		"reconcile-accept-device",
		"acceptDevice",
		"",
		offeringDevice.String(),
		map[string]string{
			"offerVersion": offer.OfferVersion,
			"name":         "Accepted Peer",
			"paused":       "false",
		},
	)
	injectConfigurationCompletionFailure(t, current, acceptDevice)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, acceptDevice, 2)
	device, ok := current.runtime.configuration.Device(offeringDevice)
	if !ok || device.Name != "Accepted Peer" || device.Paused {
		t.Fatalf("acceptDevice postcondition was not durable: %+v", device)
	}

	folderPath := t.TempDir()
	pending := pendingFolderOffer{
		FolderID:         "accepted-reconciliation-folder",
		Label:            "Observed Folder",
		OfferingDeviceID: offeringDevice,
		LastSeen:         time.Now().UTC(),
	}
	current.pendingFolderOffersForTests = pendingFolderSourceForTest(pending)
	acceptFolder := commandForTest(
		"reconcile-accept-folder",
		"acceptFolder",
		pending.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": offeringDevice.String(),
			"offerVersion":     pendingFolderOfferVersion(pending),
			"label":            "Accepted Folder",
			"path":             folderPath,
			"type":             "sendReceive",
			"paused":           "false",
			"deviceIDs":        offeringDevice.String(),
			"rescanIntervalS":  "600",
		},
	)
	injectConfigurationCompletionFailure(t, current, acceptFolder)
	current = restartAndAcknowledgeConfiguration(t, current, home, identity, acceptFolder, 3)
	folder, ok := current.runtime.configuration.Folder(pending.FolderID)
	if !ok || folder.Label != "Accepted Folder" || folder.Path != filepath.Clean(folderPath) ||
		folder.RescanIntervalS != 600 || !folder.SharedWith(offeringDevice) {
		t.Fatalf("acceptFolder postcondition was not durable: %+v", folder)
	}
}

func newRunningConfigurationReconciliationCore(t *testing.T, home string, identity []byte) *Core {
	t.Helper()
	core, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		_ = core.Close()
		t.Fatal(err)
	}
	return core
}

func injectConfigurationCompletionFailure(t *testing.T, core *Core, request string) {
	t.Helper()
	originalWrite := core.commandLedger.writeFile
	writes := 0
	core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected configuration completion write failure")
		}
		return originalWrite(path, data)
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	core.commandLedger.writeFile = originalWrite
	assertEnvelopeErrorCode(t, response, "internal_error")
	parsed := mustCommandRequestForTest(t, request)
	entry := core.commandLedger.entries[parsed.RequestID]
	if entry.State != commandStatePending || entry.Response != "" {
		t.Fatalf("completion failure did not remain pending: %+v", entry)
	}
}

func restartAndAcknowledgeConfiguration(
	t *testing.T,
	core *Core,
	home string,
	identity []byte,
	request string,
	ownerEpoch uint64,
) *Core {
	t.Helper()
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	reloaded := newRunningConfigurationReconciliationCore(t, home, identity)
	parsed := mustCommandRequestForTest(t, request)
	beforeReplayGeneration := reloaded.generation
	replay := decodeTestEnvelope(t, mustCommand(t, reloaded, request))
	assertEnvelopeErrorCode(t, replay, "indeterminate_prior_attempt")
	if reloaded.generation != beforeReplayGeneration {
		_ = reloaded.Close()
		t.Fatalf("pending configuration command %q replayed after restart", parsed.RequestID)
	}
	acknowledgement := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, request, reloaded.generation, ownerEpoch),
	))
	if !acknowledgement.OK {
		_ = reloaded.Close()
		t.Fatalf("configuration proof acknowledgement failed: %+v", acknowledgement.Error)
	}
	if _, exists := reloaded.commandLedger.entries[parsed.RequestID]; exists {
		_ = reloaded.Close()
		t.Fatal("configuration proof acknowledgement retained the ledger entry")
	}
	return reloaded
}
