// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

func TestConfigurationCommandsSnapshotAndRestartPersistence(t *testing.T) {
	home := t.TempDir()
	folderPath := t.TempDir()
	userFile := filepath.Join(folderPath, "keep-me.txt")
	if err := os.WriteFile(userFile, []byte("user data"), 0o600); err != nil {
		t.Fatal(err)
	}
	remoteID := protocol.NewDeviceID([]byte("mobilebridge integration peer")).String()

	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	currentCore := core
	t.Cleanup(func() {
		if currentCore != nil {
			_ = currentCore.Close()
		}
	})
	core.disableNetworkingForTests = true
	identity := core.IdentityBlob()
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	assertCommandOK(t, core, commandForTest("device-add", "addDevice", "", remoteID, map[string]string{
		"name":      "Peer One",
		"addresses": "dynamic",
		"paused":    "false",
	}))
	assertCommandOK(t, core, commandForTest("device-edit", "editDevice", "", remoteID, map[string]string{
		"name":      "Peer Two",
		"addresses": `["dynamic","tcp://127.0.0.1:22000"]`,
	}))
	assertCommandOK(t, core, commandForTest("device-pause", "pause", "", remoteID, nil))
	assertCommandOK(t, core, commandForTest("device-resume", "resume", "", remoteID, nil))

	assertCommandOK(t, core, commandForTest("folder-add", "addFolder", "folder-one", "", map[string]string{
		"label":           "Initial Label",
		"path":            folderPath,
		"type":            "sendOnly",
		"paused":          "true",
		"deviceIDs":       remoteID,
		"rescanIntervalS": "120",
	}))
	assertCommandOK(t, core, commandForTest("folder-edit", "editFolder", "folder-one", "", map[string]string{
		"label": "Persisted Label",
		"type":  "sendReceive",
	}))
	assertCommandOK(t, core, commandForTest("folder-resume", "resume", "folder-one", "", nil))
	assertCommandOK(t, core, commandForTest("folder-rescan", "rescan", "folder-one", "", nil))
	assertCommandOK(t, core, commandForTest("folder-pause", "pause", "folder-one", "", nil))
	assertCommandOK(t, core, commandForTest("folder-resume-2", "resume", "folder-one", "", nil))

	payload := snapshotForTest(t, core, "configured-snapshot")
	if payload.DeviceID == "" || payload.Generation <= 1 || !payload.Running {
		t.Fatalf("unexpected configured snapshot metadata: %+v", payload)
	}
	device := findDeviceSnapshot(t, payload, remoteID)
	if device.Name != "Peer Two" || device.Paused || len(device.Addresses) != 2 {
		t.Fatalf("device config did not round trip through the real wrapper: %+v", device)
	}
	for attempt := 0; device.PendingBytes != int64(len("user data")) && attempt < 100; attempt++ {
		time.Sleep(20 * time.Millisecond)
		device = findDeviceSnapshot(
			t,
			snapshotForTest(t, core, "pending-device-snapshot-"+strconv.Itoa(attempt)),
			remoteID,
		)
	}
	if device.PendingBytes != int64(len("user data")) {
		t.Fatalf("offline peer pending upload bytes did not match the indexed file: %+v", device)
	}
	folder := findFolderSnapshot(t, payload, "folder-one")
	if folder.Label != "Persisted Label" || folder.Path != filepath.Clean(folderPath) || folder.Type != "sendReceive" || folder.Paused || folder.RescanIntervalS != 120 {
		t.Fatalf("folder config did not round trip through the real wrapper: %+v", folder)
	}
	if len(folder.DeviceIDs) != 2 {
		t.Fatalf("folder should include local and remote devices: %+v", folder.DeviceIDs)
	}

	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	currentCore = nil
	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	currentCore = reloaded
	reloaded.disableNetworkingForTests = true
	if err := reloaded.Start(); err != nil {
		t.Fatal(err)
	}
	persisted := snapshotForTest(t, reloaded, "persisted-snapshot")
	if got := findDeviceSnapshot(t, persisted, remoteID).Name; got != "Peer Two" {
		t.Fatalf("device edit was not persisted across reconstruction: %q", got)
	}
	persistedFolder := findFolderSnapshot(t, persisted, "folder-one")
	if persistedFolder.Label != "Persisted Label" || persistedFolder.RescanIntervalS != 120 {
		t.Fatalf("folder edit and rescan interval were not persisted across reconstruction: %+v", persistedFolder)
	}

	assertCommandOK(t, reloaded, commandForTest("folder-remove", "removeFolder", "folder-one", "", map[string]string{"deleteData": "false"}))
	if contents, err := os.ReadFile(userFile); err != nil || string(contents) != "user data" {
		t.Fatalf("removing folder configuration changed synchronized user data: contents %q, err %v", contents, err)
	}
	assertCommandOK(t, reloaded, commandForTest("device-remove", "removeDevice", "", remoteID, nil))
	removed := snapshotForTest(t, reloaded, "removed-snapshot")
	if containsDeviceSnapshot(removed, remoteID) || containsFolderSnapshot(removed, "folder-one") {
		t.Fatalf("removed configuration remains in snapshot: %+v", removed)
	}
}

func TestDeviceTransferRatesUseMonotonicConnectionStatistics(t *testing.T) {
	home := t.TempDir()
	remoteID := protocol.NewDeviceID([]byte("mobilebridge rate peer"))
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, core, commandForTest("rate-device-add", "addDevice", "", remoteID.String(), map[string]string{
		"name":      "Rate Peer",
		"addresses": "dynamic",
		"paused":    "false",
	}))

	startedAt := time.Unix(1_700_000_000, 0).UTC()
	statistics := deviceConnectionStatistics{
		At:            startedAt.Add(time.Second),
		StartedAt:     startedAt,
		InBytesTotal:  100,
		OutBytesTotal: 200,
		Connections:   1,
	}
	core.connectionStatisticsForTests = func() map[protocol.DeviceID]deviceConnectionStatistics {
		return map[protocol.DeviceID]deviceConnectionStatistics{remoteID: statistics}
	}

	first := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-first"), remoteID.String())
	if first.UploadBytesPerSecond != 0 || first.DownloadBytesPerSecond != 0 {
		t.Fatalf("first connection sample invented a rate: %+v", first)
	}

	statistics.At = statistics.At.Add(2 * time.Second)
	statistics.InBytesTotal += 600
	statistics.OutBytesTotal += 1_000
	second := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-second"), remoteID.String())
	if second.UploadBytesPerSecond != 500 || second.DownloadBytesPerSecond != 300 {
		t.Fatalf("device rates = upload %d/download %d, want 500/300: %+v", second.UploadBytesPerSecond, second.DownloadBytesPerSecond, second)
	}

	repeated := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-repeated"), remoteID.String())
	if repeated.UploadBytesPerSecond != 500 || repeated.DownloadBytesPerSecond != 300 {
		t.Fatalf("repeated snapshot lost the last completed rate sample: %+v", repeated)
	}

	statistics.At = statistics.At.Add(time.Second)
	zero := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-zero"), remoteID.String())
	if zero.UploadBytesPerSecond != 0 || zero.DownloadBytesPerSecond != 0 {
		t.Fatalf("no-traffic sample retained a stale rate: %+v", zero)
	}

	statistics.StartedAt = statistics.At
	statistics.At = statistics.At.Add(time.Second)
	statistics.InBytesTotal = 10
	statistics.OutBytesTotal = 20
	reconnected := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-reconnected"), remoteID.String())
	if reconnected.UploadBytesPerSecond != 0 || reconnected.DownloadBytesPerSecond != 0 {
		t.Fatalf("replacement connection bridged counters across epochs: %+v", reconnected)
	}

	core.connectionStatisticsForTests = func() map[protocol.DeviceID]deviceConnectionStatistics { return nil }
	disconnected := findDeviceSnapshot(t, snapshotForTest(t, core, "rate-disconnected"), remoteID.String())
	if disconnected.UploadBytesPerSecond != 0 || disconnected.DownloadBytesPerSecond != 0 {
		t.Fatalf("disconnected peer retained a transfer rate: %+v", disconnected)
	}
}

func TestCommandRequestIDIdempotencyAndStrictValidation(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	remoteID := protocol.NewDeviceID([]byte("mobilebridge idempotent peer")).String()
	request := commandForTest("same-request", "addDevice", "", remoteID, map[string]string{"name": "Once"})
	first := mustCommand(t, core, request)
	second := mustCommand(t, core, request)
	if first != second {
		t.Fatalf("duplicate requestID did not return the exact cached response:\nfirst:  %s\nsecond: %s", first, second)
	}
	devices := core.runtime.configuration.DeviceList()
	deviceCount := 0
	for _, device := range devices {
		if device.DeviceID.String() == remoteID {
			deviceCount++
		}
	}
	if deviceCount != 1 {
		t.Fatalf("duplicate request applied %d times: %+v", deviceCount, devices)
	}
	if err := core.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	if afterRestart := mustCommand(t, core, request); afterRestart != first {
		t.Fatalf("requestID cache did not survive a Core stop/start restart:\nfirst:   %s\nrestart: %s", first, afterRestart)
	}

	conflict := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("same-request", "editDevice", "", remoteID, map[string]string{"name": "Different"})))
	assertEnvelopeErrorCode(t, conflict, "request_id_conflict")

	unknownTopLevel := decodeTestEnvelope(t, mustCommand(t, core, `{"schemaVersion":1,"requestID":"unknown-top","command":"ping","unexpected":true}`))
	assertEnvelopeErrorCode(t, unknownTopLevel, "invalid_request")
	unknownArgument := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("unknown-argument", "editDevice", "", remoteID, map[string]string{"mystery": "value"})))
	assertEnvelopeErrorCode(t, unknownArgument, "invalid_request")

	unsupported := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("unsupported-sync", "sync", "folder", "", nil)))
	assertEnvelopeErrorCode(t, unsupported, "folder_not_found")
	unsupportedMutation := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("unsupported-delete", "delete", "folder", "item", map[string]string{"path": "file"})))
	assertEnvelopeErrorCode(t, unsupportedMutation, "folder_not_found")
}

func TestConfigurationCommandsRejectInvalidIDsAndPaths(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	invalidDevice := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("bad-device", "addDevice", "", "not-a-device-id", nil)))
	assertEnvelopeErrorCode(t, invalidDevice, "invalid_device_id")
	invalidFolderID := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("bad-folder-id", "addFolder", "bad\nfolder", "", map[string]string{"path": t.TempDir()})))
	assertEnvelopeErrorCode(t, invalidFolderID, "invalid_folder_id")
	relativePath := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("relative-path", "addFolder", "relative", "", map[string]string{"path": "relative/path"})))
	assertEnvelopeErrorCode(t, relativePath, "invalid_path")
	homePath := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("home-path", "addFolder", "home", "", map[string]string{"path": home})))
	assertEnvelopeErrorCode(t, homePath, "invalid_path")
	missingPath := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("missing-path", "addFolder", "missing", "", map[string]string{"path": filepath.Join(t.TempDir(), "does-not-exist")})))
	assertEnvelopeErrorCode(t, missingPath, "invalid_path")
	deleteData := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("delete-data", "removeFolder", "missing", "", map[string]string{"deleteData": "true"})))
	assertEnvelopeErrorCode(t, deleteData, "unsupported_destructive_option")

	notRunningCoreHome := t.TempDir()
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	notRunning, err := NewCore(notRunningCoreHome, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer notRunning.Close()
	notRunningResponse := decodeTestEnvelope(t, mustCommand(t, notRunning, commandForTest("not-running", "addFolder", "folder", "", map[string]string{"path": t.TempDir()})))
	assertEnvelopeErrorCode(t, notRunningResponse, "core_not_running")
}

func commandForTest(requestID, command, folderID, itemID string, arguments map[string]string) string {
	request := commandRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     requestID,
		Command:       command,
		FolderID:      folderID,
		ItemID:        itemID,
		Arguments:     arguments,
	}
	data, err := json.Marshal(request)
	if err != nil {
		panic(err)
	}
	return string(data)
}

func assertCommandOK(t *testing.T, core *Core, request string) decodedEnvelope {
	t.Helper()
	envelope := decodeTestEnvelope(t, mustCommand(t, core, request))
	if !envelope.OK {
		t.Fatalf("command failed: %+v (request %s)", envelope.Error, request)
	}
	return envelope
}

func snapshotForTest(t *testing.T, core *Core, requestID string) snapshotPayload {
	t.Helper()
	envelope := decodeTestEnvelope(t, mustSnapshot(t, core, `{"schemaVersion":1,"requestID":"`+requestID+`"}`))
	if !envelope.OK {
		t.Fatalf("snapshot failed: %+v", envelope.Error)
	}
	var payload snapshotPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func findDeviceSnapshot(t *testing.T, payload snapshotPayload, deviceID string) deviceSnapshot {
	t.Helper()
	for _, device := range payload.Devices {
		if device.DeviceID == deviceID {
			return device
		}
	}
	t.Fatalf("device %s is missing from snapshot", deviceID)
	return deviceSnapshot{}
}

func findFolderSnapshot(t *testing.T, payload snapshotPayload, folderID string) folderSnapshot {
	t.Helper()
	for _, folder := range payload.Folders {
		if folder.FolderID == folderID {
			return folder
		}
	}
	t.Fatalf("folder %s is missing from snapshot", folderID)
	return folderSnapshot{}
}

func containsDeviceSnapshot(payload snapshotPayload, deviceID string) bool {
	for _, device := range payload.Devices {
		if device.DeviceID == deviceID {
			return true
		}
	}
	return false
}

func containsFolderSnapshot(payload snapshotPayload, folderID string) bool {
	for _, folder := range payload.Folders {
		if folder.FolderID == folderID {
			return true
		}
	}
	return false
}

func assertEnvelopeErrorCode(t *testing.T, envelope decodedEnvelope, code string) {
	t.Helper()
	if envelope.OK || envelope.Error == nil || envelope.Error.Code != code {
		t.Fatalf("expected error code %q, got %+v", code, envelope)
	}
}
