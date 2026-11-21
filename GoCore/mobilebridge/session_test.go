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

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

func TestConfigurationSessionRunsOfflineAndProjectsCanonicalConfiguration(t *testing.T) {
	home := t.TempDir()
	folderPath := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	assertCommandOK(t, core, configurationSessionCommandForTest("open-config", "openConfiguration", "config-session"))
	if core.runtime == nil || core.runtime.mode != sessionModeConfiguration {
		t.Fatal("configuration session did not install a configuration runtime")
	}
	if core.runtime.app != nil || core.runtime.closeDatabase != nil || core.runtime.appStarted {
		t.Fatal("configuration session constructed a Syncthing App or opened its database")
	}

	remoteID := protocol.NewDeviceID([]byte("offline configuration peer")).String()
	assertCommandOK(t, core, boundCommandForTest(
		"offline-add-device", "addDevice", "config-session", "", remoteID, "", "", core.configurationRevision,
		map[string]string{"name": "Offline peer", "paused": "false"},
	))
	assertCommandOK(t, core, boundCommandForTest(
		"offline-add-folder", "addFolder", "config-session", "offline-folder", "", "", "", core.configurationRevision,
		map[string]string{
			"label":     "Offline folder",
			"path":      folderPath,
			"paused":    "false",
			"deviceIDs": remoteID,
		},
	))
	assertCommandOK(t, core, boundCommandForTest(
		"offline-pause-folder", "pause", "config-session", "offline-folder", "", "", "", core.configurationRevision, nil,
	))

	snapshot := snapshotForTest(t, core, "offline-config-snapshot")
	if snapshot.Session == nil || snapshot.Session.Mode != sessionModeConfiguration || snapshot.ConfigurationRevision == "" {
		t.Fatalf("configuration snapshot lost session or revision: %+v", snapshot)
	}
	device := findDeviceSnapshot(t, snapshot, remoteID)
	if device.Name != "Offline peer" || device.Paused || device.Connected || device.LastSeen != "" {
		t.Fatalf("configuration snapshot mixed runtime device state into canonical state: %+v", device)
	}
	folder := findFolderSnapshot(t, snapshot, "offline-folder")
	if folder.Label != "Offline folder" || folder.Path != filepath.Clean(folderPath) || !folder.Paused || len(folder.DeviceIDs) != 2 {
		t.Fatalf("configuration snapshot did not project canonical folder state: %+v", folder)
	}
	if folder.CompletionPercent != 0 || folder.PendingUploadBytes != 0 || folder.PendingDownloadBytes != 0 || folder.State != "" {
		t.Fatalf("configuration snapshot invented unavailable folder runtime state: %+v", folder)
	}
	if snapshot.PendingFoldersAvailable || len(snapshot.PendingDevices) != 0 || snapshot.PendingDeviceObservationScope != "unavailable_in_configuration_session" {
		t.Fatalf("configuration snapshot claimed live pending-offer evidence: %+v", snapshot)
	}

	closeResponse := decodeTestEnvelope(t, core.CommandJSON(configurationSessionCommandForTest("close-config", "closeSession", "config-session")))
	if !closeResponse.OK {
		t.Fatalf("close configuration session failed: %+v", closeResponse.Error)
	}
	var closeConfigurationReceipt commandPayload
	if err := json.Unmarshal(closeResponse.Payload, &closeConfigurationReceipt); err != nil {
		t.Fatal(err)
	}
	closedRevision, err := configurationFileRevision(filepath.Join(home, "Config", "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	if closeConfigurationReceipt.ConfigurationRevision != closedRevision ||
		closeConfigurationReceipt.SessionID != "config-session" ||
		closeConfigurationReceipt.SessionMode != sessionModeConfiguration {
		t.Fatalf("configuration close receipt was not bound to the final reread state: %+v", closeConfigurationReceipt)
	}
	if core.runtime != nil || core.session != nil {
		t.Fatal("configuration session resources remained active after close")
	}

	assertCommandOK(t, core, configurationSessionCommandForTest("reopen-config", "openConfiguration", "config-session-2"))
	reloaded := snapshotForTest(t, core, "offline-config-reloaded")
	if !findFolderSnapshot(t, reloaded, "offline-folder").Paused {
		t.Fatal("offline pause did not survive strict save and reread")
	}
	assertCommandOK(t, core, boundCommandForTest(
		"offline-remove-folder", "removeFolder", "config-session-2", "offline-folder", "", "", "", core.configurationRevision,
		map[string]string{"deleteData": "false"},
	))
	assertCommandOK(t, core, boundCommandForTest(
		"offline-remove-device", "removeDevice", "config-session-2", "", remoteID, "", "", core.configurationRevision, nil,
	))
	assertCommandOK(t, core, configurationSessionCommandForTest("close-config-2", "closeSession", "config-session-2"))
	if _, err := os.Stat(filepath.Join(home, "Config", "config.xml")); err != nil {
		t.Fatalf("canonical configuration is unavailable after close: %v", err)
	}
}

func TestNetworkSessionUsesEphemeralSingleFolderConfigurationAndSemanticLedgerDigest(t *testing.T) {
	home := t.TempDir()
	targetPath := t.TempDir()
	otherPath := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	assertCommandOK(t, core, configurationSessionCommandForTest("seed-open", "openConfiguration", "seed-config"))
	targetDevice := protocol.NewDeviceID([]byte("scoped target peer")).String()
	otherDevice := protocol.NewDeviceID([]byte("scoped unrelated peer")).String()
	for index, deviceID := range []string{targetDevice, otherDevice} {
		assertCommandOK(t, core, boundCommandForTest(
			fmt.Sprintf("seed-device-%d", index), "addDevice", "seed-config", "", deviceID, "", "", core.configurationRevision,
			map[string]string{"name": fmt.Sprintf("Peer %d", index), "paused": "false"},
		))
	}
	assertCommandOK(t, core, boundCommandForTest(
		"seed-target-folder", "addFolder", "seed-config", "target-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": targetPath, "paused": "false", "deviceIDs": targetDevice},
	))
	assertCommandOK(t, core, boundCommandForTest(
		"seed-other-folder", "addFolder", "seed-config", "other-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": otherPath, "paused": "false", "deviceIDs": otherDevice},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("seed-close", "closeSession", "seed-config"))
	canonicalPath := filepath.Join(home, "Config", "config.xml")
	canonicalBefore, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}

	taskID := "task-target-folder"
	planDigest := networkSessionPlanDigest(taskID, "target-folder", revision, "unlimited")
	assertCommandOK(t, core, networkSessionCommandForTest(
		"network-open-1", "openNetworkSession", "network-session-1", "target-folder", taskID, planDigest, revision,
	))
	effectiveTarget, ok := core.runtime.configuration.Folder("target-folder")
	if !ok || effectiveTarget.Paused {
		t.Fatalf("target folder was not active in effective configuration: %+v", effectiveTarget)
	}
	effectiveOther, ok := core.runtime.configuration.Folder("other-folder")
	if !ok || !effectiveOther.Paused {
		t.Fatalf("non-target folder was not paused in effective configuration: %+v", effectiveOther)
	}
	effectiveOtherDevice, ok := core.runtime.configuration.Device(protocol.NewDeviceID([]byte("scoped unrelated peer")))
	if !ok || !effectiveOtherDevice.Paused {
		t.Fatalf("unrelated device was not paused in effective configuration: %+v", effectiveOtherDevice)
	}

	snapshot := snapshotForTest(t, core, "network-canonical-snapshot")
	if findFolderSnapshot(t, snapshot, "other-folder").Paused {
		t.Fatal("network snapshot leaked ephemeral non-target folder pause into canonical state")
	}
	if findDeviceSnapshot(t, snapshot, otherDevice).Paused {
		t.Fatal("network snapshot leaked ephemeral unrelated-device pause into canonical state")
	}
	canonicalDuring, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonicalBefore, canonicalDuring) {
		t.Fatal("opening a scoped network session changed canonical config.xml")
	}

	ledgerBeforeRejection := len(core.commandLedger.entries)
	outOfScope := decodeTestEnvelope(t, core.CommandJSON(boundCommandForTest(
		"wrong-folder", "rescan", "network-session-1", "other-folder", "", taskID, planDigest, revision, nil,
	)))
	assertEnvelopeErrorCode(t, outOfScope, "folder_out_of_scope")
	wrongMode := decodeTestEnvelope(t, core.CommandJSON(boundCommandForTest(
		"wrong-mode", "pause", "network-session-1", "target-folder", "", taskID, planDigest, revision, nil,
	)))
	assertEnvelopeErrorCode(t, wrongMode, "wrong_session_mode")
	wrongSession := decodeTestEnvelope(t, core.CommandJSON(boundCommandForTest(
		"wrong-session", "ping", "different-session", "", "", taskID, planDigest, revision, nil,
	)))
	assertEnvelopeErrorCode(t, wrongSession, "session_scope_mismatch")
	if len(core.commandLedger.entries) != ledgerBeforeRejection {
		t.Fatal("session preflight rejection wrote the durable command ledger")
	}

	pingFirstText := boundCommandForTest(
		"semantic-ping", "ping", "network-session-1", "", "", taskID, planDigest, revision, nil,
	)
	pingFirst := core.CommandJSON(pingFirstText)
	if !decodeTestEnvelope(t, pingFirst).OK {
		t.Fatal("first session-bound semantic command failed")
	}
	closeFirst := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandForTest(
		"network-close-1", "closeSession", "network-session-1", "", taskID, planDigest, revision,
	)))
	if !closeFirst.OK {
		t.Fatalf("network close failed: %+v", closeFirst.Error)
	}
	var closeReceipt commandPayload
	if err := json.Unmarshal(closeFirst.Payload, &closeReceipt); err != nil {
		t.Fatal(err)
	}
	if closeReceipt.SessionID != "network-session-1" || closeReceipt.SessionMode != sessionModeNetwork ||
		closeReceipt.FolderID != "target-folder" || closeReceipt.TaskID != taskID ||
		closeReceipt.PlanDigest != planDigest || closeReceipt.ExpectedConfigurationRevision != revision {
		t.Fatalf("network close receipt lost the active session descriptor: %+v", closeReceipt)
	}
	if after, err := os.ReadFile(canonicalPath); err != nil || !bytes.Equal(canonicalBefore, after) {
		t.Fatalf("closing a scoped network session changed canonical config.xml: %v", err)
	}

	assertCommandOK(t, core, networkSessionCommandForTest(
		"network-open-2", "openNetworkSession", "network-session-2", "target-folder", taskID, planDigest, revision,
	))
	pingSecond := core.CommandJSON(boundCommandForTest(
		"semantic-ping", "ping", "network-session-2", "", "", taskID, planDigest, revision, nil,
	))
	if pingSecond != pingFirst {
		t.Fatalf("same semantic requestID did not replay across ephemeral sessions:\nfirst:  %s\nsecond: %s", pingFirst, pingSecond)
	}
	assertCommandOK(t, core, networkSessionCommandForTest(
		"network-close-2", "closeSession", "network-session-2", "", taskID, planDigest, revision,
	))
}

func TestNetworkOperationsBindPlanEffectiveModeAndPayloadDirections(t *testing.T) {
	revision := strings.Repeat("a", 64)
	canonical := config.Configuration{Folders: []config.FolderConfiguration{{
		ID:   "directional-folder",
		Type: config.FolderTypeSendReceive,
	}}}
	localDeviceID := protocol.NewDeviceID([]byte("directional local device"))
	tests := []struct {
		operation    string
		wantType     config.FolderType
		wantUpload   bool
		wantDownload bool
	}{
		{networkOperationSync, config.FolderTypeSendReceive, true, true},
		{networkOperationUpload, config.FolderTypeSendOnly, true, false},
		{networkOperationDownload, config.FolderTypeReceiveOnly, false, true},
		{networkOperationMaterialize, config.FolderTypeSendOnly, false, true},
		{networkOperationExchangeIndex, config.FolderTypeSendOnly, false, false},
		{networkOperationLocalMutation, config.FolderTypeSendOnly, false, false},
	}
	seenPlans := make(map[string]string, len(tests))
	for _, test := range tests {
		t.Run(test.operation, func(t *testing.T) {
			plan := networkSessionPlanDigestForOperation("directional-task", "directional-folder", revision, "4096", test.operation)
			if previous, exists := seenPlans[plan]; exists {
				t.Fatalf("operation plan collided with %s", previous)
			}
			seenPlans[plan] = test.operation
			request := commandRequest{
				SessionID:                     "directional-session",
				FolderID:                      "directional-folder",
				TaskID:                        "directional-task",
				PlanDigest:                    plan,
				ExpectedConfigurationRevision: revision,
				MaximumNetworkBytes:           "4096",
				NetworkOperation:              test.operation,
			}
			descriptor, validationErr := validateOpenSessionCommand(request, sessionModeNetwork)
			if validationErr != nil {
				t.Fatalf("validation failed: %+v", validationErr)
			}
			effective, scopeErr := deriveEffectiveNetworkConfiguration(canonical, descriptor, localDeviceID)
			if scopeErr != nil {
				t.Fatalf("effective configuration failed: %+v", scopeErr)
			}
			folder, _, ok := effective.Folder("directional-folder")
			if !ok || folder.Type != test.wantType {
				t.Fatalf("effective folder type = %v, want %v", folder.Type, test.wantType)
			}
			upload, download := networkOperationPayloadDirections(test.operation)
			if upload != test.wantUpload || download != test.wantDownload {
				t.Fatalf("payload directions = (%t,%t), want (%t,%t)", upload, download, test.wantUpload, test.wantDownload)
			}
		})
	}

	receiveOnly := canonical.Copy()
	receiveOnly.Folders[0].Type = config.FolderTypeReceiveOnly
	if _, err := deriveEffectiveNetworkConfiguration(receiveOnly, sessionDescriptor{FolderID: "directional-folder", NetworkOperation: networkOperationUpload}, localDeviceID); err == nil || err.Code != "operation_not_allowed" {
		t.Fatalf("receive-only folder accepted upload: %+v", err)
	}
	sendOnly := canonical.Copy()
	sendOnly.Folders[0].Type = config.FolderTypeSendOnly
	if _, err := deriveEffectiveNetworkConfiguration(sendOnly, sessionDescriptor{FolderID: "directional-folder", NetworkOperation: networkOperationDownload}, localDeviceID); err == nil || err.Code != "operation_not_allowed" {
		t.Fatalf("send-only folder accepted download: %+v", err)
	}
	if _, err := deriveEffectiveNetworkConfiguration(receiveOnly, sessionDescriptor{FolderID: "directional-folder", NetworkOperation: networkOperationLocalMutation}, localDeviceID); err == nil || err.Code != "operation_not_allowed" {
		t.Fatalf("receive-only folder accepted local mutation: %+v", err)
	}

	remoteDeviceID := protocol.NewDeviceID([]byte("local mutation remote device"))
	localMutationConfig := canonical.Copy()
	localMutationConfig.Devices = []config.DeviceConfiguration{{
		DeviceID: remoteDeviceID,
	}}
	localMutationConfig.Folders[0].Devices = []config.FolderDeviceConfiguration{{
		DeviceID: remoteDeviceID,
	}}
	effective, err := deriveEffectiveNetworkConfiguration(
		localMutationConfig,
		sessionDescriptor{
			FolderID:         "directional-folder",
			NetworkOperation: networkOperationLocalMutation,
		},
		localDeviceID,
	)
	if err != nil {
		t.Fatalf("local mutation effective configuration failed: %+v", err)
	}
	remote, _, ok := effective.Device(remoteDeviceID)
	if !ok || !remote.Paused {
		t.Fatalf("local mutation did not pause remote device: %+v", remote)
	}
}

func TestNetworkSessionRejectsStaleConfigurationRevisionAndUnboundPlan(t *testing.T) {
	home := t.TempDir()
	firstPath := t.TempDir()
	secondPath := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	assertCommandOK(t, core, configurationSessionCommandForTest("stale-seed-open", "openConfiguration", "stale-seed"))
	assertCommandOK(t, core, boundCommandForTest(
		"stale-seed-folder", "addFolder", "stale-seed", "incarnation-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": firstPath, "label": "First incarnation", "paused": "false"},
	))
	staleRevision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("stale-seed-close", "closeSession", "stale-seed"))

	assertCommandOK(t, core, configurationSessionCommandForTest("replace-open", "openConfiguration", "replace-config"))
	assertCommandOK(t, core, boundCommandForTest(
		"replace-remove", "removeFolder", "replace-config", "incarnation-folder", "", "", "", core.configurationRevision,
		map[string]string{"deleteData": "false"},
	))
	assertCommandOK(t, core, boundCommandForTest(
		"replace-add", "addFolder", "replace-config", "incarnation-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": secondPath, "label": "Second incarnation", "paused": "false"},
	))
	currentRevision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("replace-close", "closeSession", "replace-config"))
	if currentRevision == staleRevision {
		t.Fatal("folder replacement did not change canonical configuration revision")
	}

	taskID := "stale-plan-task"
	stale := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandForTest(
		"stale-network-open", "openNetworkSession", "stale-network", "incarnation-folder", taskID,
		networkSessionPlanDigest(taskID, "incarnation-folder", staleRevision, "unlimited"), staleRevision,
	)))
	assertEnvelopeErrorCode(t, stale, "configuration_revision_mismatch")
	if core.runtime != nil || core.session != nil || core.lifecycle != lifecycleStopped {
		t.Fatal("stale configuration revision left partial network runtime state")
	}

	unbound := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandForTest(
		"unbound-network-open", "openNetworkSession", "unbound-network", "incarnation-folder", taskID,
		fmt.Sprintf("%064x", 1), currentRevision,
	)))
	assertEnvelopeErrorCode(t, unbound, "plan_digest_mismatch")
	if core.runtime != nil || core.session != nil {
		t.Fatal("unbound plan digest left partial network runtime state")
	}

	currentPlan := networkSessionPlanDigest(taskID, "incarnation-folder", currentRevision, "unlimited")
	assertCommandOK(t, core, networkSessionCommandForTest(
		"current-network-open", "openNetworkSession", "current-network", "incarnation-folder", taskID, currentPlan, currentRevision,
	))
	assertCommandOK(t, core, networkSessionCommandForTest(
		"current-network-close", "closeSession", "current-network", "", taskID, currentPlan, currentRevision,
	))
}

func TestSessionLifecycleNeverConsumesCommandLedgerCapacity(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	assertCommandOK(t, core, configurationSessionCommandForTest("capacity-open", "openConfiguration", "capacity-session"))
	baseline := len(core.commandLedger.entries)
	for index := 0; index < maxCommandLedgerEntries+1; index++ {
		response := decodeTestEnvelope(t, core.CommandJSON(configurationSessionCommandForTest(
			fmt.Sprintf("capacity-open-%04d", index), "openConfiguration", "capacity-session",
		)))
		if !response.OK {
			t.Fatalf("idempotent lifecycle open %d failed: %+v", index, response.Error)
		}
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("capacity-close", "closeSession", "capacity-session"))
	if len(core.commandLedger.entries) != baseline {
		t.Fatalf("session lifecycle consumed command ledger capacity: before %d, after %d", baseline, len(core.commandLedger.entries))
	}
}

func TestExplicitSessionCommandSupportMatrix(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	core.configurationRevision = fmt.Sprintf("%064x", 1)
	core.session = &sessionDescriptor{SessionID: "matrix-config", Mode: sessionModeConfiguration}
	for _, command := range []string{
		"addDevice", "editDevice", "removeDevice", "acceptDevice", "ignorePendingDevice", "unignorePendingDevice",
		"addFolder", "editFolder", "removeFolder", "pause", "resume", "unignorePendingFolder",
		"disposeRecovery", "disposeRecoveryReviewed", "exportRecovery", "discardRecoveryExport",
	} {
		request := commandRequest{
			Command:   command,
			SessionID: "matrix-config",
		}
		if isConfigurationReconciliationCommand(command) {
			request.CommandConfigurationRevision = core.configurationRevision
		}
		if preflightErr := core.preflightCommandSessionLocked(request); preflightErr != nil {
			t.Fatalf("offline configuration command %s was rejected by session preflight: %+v", command, preflightErr)
		}
	}
	for _, command := range []string{
		"addDevice", "editDevice", "removeDevice", "acceptDevice",
		"addFolder", "editFolder", "removeFolder", "acceptFolder", "pause", "resume",
	} {
		preflightErr := core.preflightCommandSessionLocked(commandRequest{Command: command, SessionID: "matrix-config"})
		if preflightErr == nil || preflightErr.Code != "invalid_request" {
			t.Fatalf("configuration command %s did not require commandConfigurationRevision: %+v", command, preflightErr)
		}
	}
	for _, command := range []string{
		"ignorePendingDevice", "unignorePendingDevice", "ignorePendingFolder", "unignorePendingFolder",
		"disposeRecovery", "disposeRecoveryReviewed", "exportRecovery", "discardRecoveryExport",
	} {
		preflightErr := core.preflightCommandSessionLocked(commandRequest{
			Command:                      command,
			SessionID:                    "matrix-config",
			CommandConfigurationRevision: core.configurationRevision,
		})
		if preflightErr == nil || preflightErr.Code != "invalid_request" {
			t.Fatalf("store-only command %s accepted commandConfigurationRevision: %+v", command, preflightErr)
		}
	}
	invalidCloseRevision := core.preflightCommandSessionLocked(commandRequest{
		Command:                      "closeSession",
		SessionID:                    "matrix-config",
		CommandConfigurationRevision: core.configurationRevision,
	})
	if invalidCloseRevision == nil || invalidCloseRevision.Code != "invalid_request" {
		t.Fatalf("configuration close accepted commandConfigurationRevision: %+v", invalidCloseRevision)
	}
	if _, validationErr := validateOpenSessionCommand(commandRequest{
		SessionID:                    "matrix-other-config",
		CommandConfigurationRevision: core.configurationRevision,
	}, sessionModeConfiguration); validationErr == nil || validationErr.Code != "invalid_session" {
		t.Fatalf("configuration open accepted commandConfigurationRevision: %+v", validationErr)
	}
	for _, command := range []string{"acceptFolder", "ignorePendingFolder"} {
		request := commandRequest{Command: command, SessionID: "matrix-config"}
		if command == "acceptFolder" {
			request.CommandConfigurationRevision = core.configurationRevision
		}
		preflightErr := core.preflightCommandSessionLocked(request)
		if preflightErr == nil || preflightErr.Code != "network_observation_required" {
			t.Fatalf("%s did not expose its explicit live-observation requirement: %+v", command, preflightErr)
		}
	}
	for _, command := range []string{"sync", "rescan", "create", "modify", "move", "delete"} {
		preflightErr := core.preflightCommandSessionLocked(commandRequest{Command: command, SessionID: "matrix-config"})
		if preflightErr == nil || preflightErr.Code != "wrong_session_mode" {
			t.Fatalf("network command %s escaped configuration mode: %+v", command, preflightErr)
		}
	}

	revision := fmt.Sprintf("%064x", 2)
	planDigest := networkSessionPlanDigest("matrix-task", "matrix-folder", revision, "unlimited")
	core.session = &sessionDescriptor{
		SessionID:                     "matrix-network",
		Mode:                          sessionModeNetwork,
		FolderID:                      "matrix-folder",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
	}
	for _, command := range []string{
		"addDevice", "editDevice", "removeDevice", "acceptDevice", "ignorePendingDevice",
		"addFolder", "editFolder", "removeFolder", "acceptFolder", "ignorePendingFolder",
		"pause", "resume", "disposeRecovery", "disposeRecoveryReviewed", "exportRecovery", "discardRecoveryExport",
	} {
		preflightErr := core.preflightCommandSessionLocked(commandRequest{
			Command:                       command,
			SessionID:                     "matrix-network",
			TaskID:                        "matrix-task",
			PlanDigest:                    planDigest,
			ExpectedConfigurationRevision: revision,
			MaximumNetworkBytes:           "unlimited",
			NetworkOperation:              networkOperationSync,
		})
		if preflightErr == nil || preflightErr.Code != "wrong_session_mode" {
			t.Fatalf("configuration command %s escaped network mode: %+v", command, preflightErr)
		}
	}
	if preflightErr := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "sync",
		SessionID:                     "matrix-network",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
		FolderID:                      "matrix-folder",
	}); preflightErr != nil {
		t.Fatalf("scoped network sync was rejected: %+v", preflightErr)
	}
	mutationInSync := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "create",
		SessionID:                     "matrix-network",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
		FolderID:                      "matrix-folder",
	})
	if mutationInSync == nil || mutationInSync.Code != "operation_scope_mismatch" {
		t.Fatalf("sync session accepted a local mutation: %+v", mutationInSync)
	}
	localMutationPlan := networkSessionPlanDigestForOperation(
		"matrix-mutation-task",
		"matrix-folder",
		revision,
		"0",
		networkOperationLocalMutation,
	)
	core.session = &sessionDescriptor{
		SessionID:                     "matrix-mutation",
		Mode:                          sessionModeNetwork,
		FolderID:                      "matrix-folder",
		TaskID:                        "matrix-mutation-task",
		PlanDigest:                    localMutationPlan,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "0",
		NetworkOperation:              networkOperationLocalMutation,
	}
	for _, command := range []string{"create", "modify", "move", "delete", "rescan"} {
		preflightErr := core.preflightCommandSessionLocked(commandRequest{
			Command:                       command,
			SessionID:                     "matrix-mutation",
			TaskID:                        "matrix-mutation-task",
			PlanDigest:                    localMutationPlan,
			ExpectedConfigurationRevision: revision,
			MaximumNetworkBytes:           "0",
			NetworkOperation:              networkOperationLocalMutation,
			FolderID:                      "matrix-folder",
		})
		if preflightErr != nil {
			t.Fatalf("local mutation session rejected %s: %+v", command, preflightErr)
		}
	}
	core.session = &sessionDescriptor{
		SessionID:                     "matrix-network",
		Mode:                          sessionModeNetwork,
		FolderID:                      "matrix-folder",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
	}
	wrongFolder := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "sync",
		SessionID:                     "matrix-network",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
		FolderID:                      "other-folder",
	})
	if wrongFolder == nil || wrongFolder.Code != "folder_out_of_scope" {
		t.Fatalf("out-of-scope network sync was not rejected: %+v", wrongFolder)
	}
	networkCommandRevision := core.preflightCommandSessionLocked(commandRequest{
		Command:                       "ping",
		SessionID:                     "matrix-network",
		TaskID:                        "matrix-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
		CommandConfigurationRevision:  core.configurationRevision,
	})
	if networkCommandRevision == nil || networkCommandRevision.Code != "session_scope_mismatch" {
		t.Fatalf("network command accepted commandConfigurationRevision: %+v", networkCommandRevision)
	}
	core.session = nil
}

func TestExplicitSessionDataPreflightMatrix(t *testing.T) {
	configurationCore := &Core{session: &sessionDescriptor{
		SessionID: "data-config",
		Mode:      sessionModeConfiguration,
	}}
	for _, test := range []struct {
		name              string
		sessionID         string
		taskID            string
		planDigest        string
		revision          string
		folderID          string
		configurationOnly bool
		wantCode          string
	}{
		{name: "recoveries", sessionID: "data-config", configurationOnly: true},
		{name: "items", sessionID: "data-config", wantCode: "wrong_session_mode"},
		{name: "read range", sessionID: "data-config", wantCode: "wrong_session_mode"},
		{name: "wrong session", sessionID: "other-config", configurationOnly: true, wantCode: "session_scope_mismatch"},
		{name: "network binding", sessionID: "data-config", taskID: "unexpected-task", configurationOnly: true, wantCode: "session_scope_mismatch"},
	} {
		t.Run("configuration "+test.name, func(t *testing.T) {
			err := configurationCore.preflightDataSessionLocked(
				test.sessionID,
				test.taskID,
				test.planDigest,
				test.revision,
				"",
				"",
				test.folderID,
				test.configurationOnly,
			)
			assertPreflightCode(t, err, test.wantCode)
		})
	}

	revision := fmt.Sprintf("%064x", 3)
	planDigest := networkSessionPlanDigest("data-task", "data-folder", revision, "unlimited")
	networkCore := &Core{session: &sessionDescriptor{
		SessionID:                     "data-network",
		Mode:                          sessionModeNetwork,
		FolderID:                      "data-folder",
		TaskID:                        "data-task",
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: revision,
		MaximumNetworkBytes:           "unlimited",
		NetworkOperation:              networkOperationSync,
	}}
	for _, test := range []struct {
		name              string
		sessionID         string
		taskID            string
		planDigest        string
		revision          string
		folderID          string
		configurationOnly bool
		wantCode          string
	}{
		{name: "exact data scope", sessionID: "data-network", taskID: "data-task", planDigest: planDigest, revision: revision, folderID: "data-folder"},
		{name: "other folder", sessionID: "data-network", taskID: "data-task", planDigest: planDigest, revision: revision, folderID: "other-folder", wantCode: "folder_out_of_scope"},
		{name: "empty folder", sessionID: "data-network", taskID: "data-task", planDigest: planDigest, revision: revision, wantCode: "folder_out_of_scope"},
		{name: "configuration only", sessionID: "data-network", taskID: "data-task", planDigest: planDigest, revision: revision, folderID: "data-folder", configurationOnly: true, wantCode: "wrong_session_mode"},
		{name: "wrong session", sessionID: "other-network", taskID: "data-task", planDigest: planDigest, revision: revision, folderID: "data-folder", wantCode: "session_scope_mismatch"},
		{name: "wrong task", sessionID: "data-network", taskID: "other-task", planDigest: planDigest, revision: revision, folderID: "data-folder", wantCode: "session_scope_mismatch"},
		{name: "wrong plan", sessionID: "data-network", taskID: "data-task", planDigest: fmt.Sprintf("%064x", 4), revision: revision, folderID: "data-folder", wantCode: "session_scope_mismatch"},
		{name: "wrong revision", sessionID: "data-network", taskID: "data-task", planDigest: planDigest, revision: fmt.Sprintf("%064x", 5), folderID: "data-folder", wantCode: "session_scope_mismatch"},
	} {
		t.Run("network "+test.name, func(t *testing.T) {
			err := networkCore.preflightDataSessionLocked(
				test.sessionID,
				test.taskID,
				test.planDigest,
				test.revision,
				"unlimited",
				networkOperationSync,
				test.folderID,
				test.configurationOnly,
			)
			assertPreflightCode(t, err, test.wantCode)
		})
	}
	for _, test := range []struct {
		maximum  string
		wantCode string
	}{
		{maximum: "", wantCode: "invalid_session"},
		{maximum: "01", wantCode: "invalid_session"},
		{maximum: "0", wantCode: "session_scope_mismatch"},
	} {
		err := networkCore.preflightDataSessionLocked(
			"data-network",
			"data-task",
			planDigest,
			revision,
			test.maximum,
			networkOperationSync,
			"data-folder",
			false,
		)
		assertPreflightCode(t, err, test.wantCode)
	}

	missingBinding := decodeTestEnvelope(t, networkCore.QueryJSON(`{
		"schemaVersion":1,
		"requestID":"query-missing-session-scope",
		"query":"items",
		"folderID":"data-folder"
	}`))
	assertEnvelopeErrorCode(t, missingBinding, "session_scope_mismatch")

	wrongFolder := decodeTestEnvelope(t, networkCore.QueryJSON(fmt.Sprintf(`{
		"schemaVersion":1,
		"requestID":"query-wrong-folder-scope",
		"sessionID":"data-network",
		"taskID":"data-task",
		"planDigest":%q,
		"expectedConfigurationRevision":%q,
		"maximumNetworkBytes":"unlimited",
		"networkOperation":"sync",
		"query":"items",
		"folderID":"other-folder"
	}`, planDigest, revision)))
	assertEnvelopeErrorCode(t, wrongFolder, "folder_out_of_scope")
}

func assertPreflightCode(t *testing.T, err *responseError, wantCode string) {
	t.Helper()
	if wantCode == "" {
		if err != nil {
			t.Fatalf("preflight unexpectedly failed: %+v", err)
		}
		return
	}
	if err == nil || err.Code != wantCode {
		t.Fatalf("preflight error = %+v, want code %q", err, wantCode)
	}
}

func TestNetworkByteBudgetPlanV2ScopeLifecycleAndFinalTotals(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	assertCommandOK(t, core, configurationSessionCommandForTest("budget-seed-open", "openConfiguration", "budget-seed"))
	assertCommandOK(t, core, boundCommandForTest(
		"budget-seed-folder", "addFolder", "budget-seed", "budget-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": t.TempDir(), "paused": "false"},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("budget-seed-close", "closeSession", "budget-seed"))

	const taskID = "budget-task"
	const maximum = "0"
	planDigest := networkSessionPlanDigest(taskID, "budget-folder", revision, maximum)
	open := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-open", "openNetworkSession", "budget-network", "budget-folder", taskID, planDigest, revision, maximum,
	)))
	if !open.OK {
		t.Fatalf("zero-budget session open failed: %+v", open.Error)
	}
	var openReceipt commandPayload
	if err := json.Unmarshal(open.Payload, &openReceipt); err != nil {
		t.Fatal(err)
	}
	if openReceipt.MaximumNetworkBytes != maximum {
		t.Fatalf("open receipt lost maximumNetworkBytes: %+v", openReceipt)
	}
	snapshot := snapshotForTest(t, core, "budget-snapshot")
	if snapshot.Session == nil || snapshot.Session.MaximumNetworkBytes != maximum {
		t.Fatalf("snapshot lost maximumNetworkBytes: %+v", snapshot.Session)
	}

	totals := networkTransferTotalsForTest(t, core, "budget-active-totals")
	if !totals.BudgetLimited || totals.BudgetLimitBytes != 0 || totals.BudgetUsedBytes != 0 || !totals.BudgetExhausted {
		t.Fatalf("zero-budget active totals = %+v", totals)
	}
	syncResponse := decodeTestEnvelope(t, core.CommandJSON(boundCommandWithMaximumForTest(
		"budget-sync", "sync", "budget-network", "budget-folder", "", taskID, planDigest, revision, maximum, nil,
	)))
	assertEnvelopeErrorCode(t, syncResponse, "network_byte_limit_reached")
	_, remoteReadErr := core.readRemoteRangeLocked("budget-folder", protocol.FileInfo{
		Name: "remote.bin",
		Size: 1,
		Blocks: []protocol.BlockInfo{{
			Size: 1,
			Hash: []byte{1},
		}},
	}, 0, 1)
	var rangeErr *readRangeError
	if !errors.As(remoteReadErr, &rangeErr) || rangeErr.code != "network_byte_limit_reached" {
		t.Fatalf("zero-budget remote read error = %v, want network_byte_limit_reached", remoteReadErr)
	}

	ledgerBeforeScopeFailures := len(core.commandLedger.entries)
	wrongMaximum := decodeTestEnvelope(t, core.CommandJSON(boundCommandWithMaximumForTest(
		"budget-wrong-maximum", "ping", "budget-network", "", "", taskID, planDigest, revision, "unlimited", nil,
	)))
	assertEnvelopeErrorCode(t, wrongMaximum, "session_scope_mismatch")
	invalidMaximum := decodeTestEnvelope(t, core.CommandJSON(boundCommandWithMaximumForTest(
		"budget-invalid-maximum", "ping", "budget-network", "", "", taskID, planDigest, revision, "01", nil,
	)))
	assertEnvelopeErrorCode(t, invalidMaximum, "invalid_session")
	wrongQuery := decodeTestEnvelope(t, core.QueryJSON(fmt.Sprintf(`{
		"schemaVersion":1,
		"requestID":"budget-wrong-query",
		"sessionID":"budget-network",
		"taskID":%q,
		"planDigest":%q,
		"expectedConfigurationRevision":%q,
		"maximumNetworkBytes":"unlimited",
		"networkOperation":"sync",
		"query":"items",
		"folderID":"budget-folder"
	}`, taskID, planDigest, revision)))
	assertEnvelopeErrorCode(t, wrongQuery, "session_scope_mismatch")
	invalidQuery := decodeTestEnvelope(t, core.QueryJSON(fmt.Sprintf(`{
		"schemaVersion":1,
		"requestID":"budget-invalid-query",
		"sessionID":"budget-network",
		"taskID":%q,
		"planDigest":%q,
		"expectedConfigurationRevision":%q,
		"maximumNetworkBytes":"01",
		"networkOperation":"sync",
		"query":"items",
		"folderID":"budget-folder"
	}`, taskID, planDigest, revision)))
	assertEnvelopeErrorCode(t, invalidQuery, "invalid_session")
	wrongRead := decodeTestEnvelope(t, core.ReadRangeJSON(fmt.Sprintf(`{
		"schemaVersion":1,
		"requestID":"budget-wrong-read",
		"sessionID":"budget-network",
		"taskID":%q,
		"planDigest":%q,
		"expectedConfigurationRevision":%q,
		"maximumNetworkBytes":"unlimited",
		"networkOperation":"sync",
		"folderID":"budget-folder",
		"itemID":"unreached",
		"contentVersion":"unreached",
		"offset":0,
		"length":1
	}`, taskID, planDigest, revision)))
	assertEnvelopeErrorCode(t, wrongRead, "session_scope_mismatch")
	invalidRead := decodeTestEnvelope(t, core.ReadRangeJSON(fmt.Sprintf(`{
		"schemaVersion":1,
		"requestID":"budget-invalid-read",
		"sessionID":"budget-network",
		"taskID":%q,
		"planDigest":%q,
		"expectedConfigurationRevision":%q,
		"maximumNetworkBytes":"01",
		"networkOperation":"sync",
		"folderID":"budget-folder",
		"itemID":"unreached",
		"contentVersion":"unreached",
		"offset":0,
		"length":1
	}`, taskID, planDigest, revision)))
	assertEnvelopeErrorCode(t, invalidRead, "invalid_session")
	if len(core.commandLedger.entries) != ledgerBeforeScopeFailures {
		t.Fatal("maximumNetworkBytes scope rejection reached the durable command ledger")
	}

	wrongClose := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-wrong-close", "closeSession", "budget-network", "", taskID, planDigest, revision, "unlimited",
	)))
	assertEnvelopeErrorCode(t, wrongClose, "session_scope_mismatch")
	invalidClose := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-invalid-close", "closeSession", "budget-network", "", taskID, planDigest, revision, "01",
	)))
	assertEnvelopeErrorCode(t, invalidClose, "invalid_session")
	closeResponse := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-close", "closeSession", "budget-network", "", taskID, planDigest, revision, maximum,
	)))
	if !closeResponse.OK {
		t.Fatalf("zero-budget close failed: %+v", closeResponse.Error)
	}
	var closeReceipt commandPayload
	if err := json.Unmarshal(closeResponse.Payload, &closeReceipt); err != nil {
		t.Fatal(err)
	}
	if closeReceipt.MaximumNetworkBytes != maximum {
		t.Fatalf("close receipt lost maximumNetworkBytes: %+v", closeReceipt)
	}
	finalTotals := networkTransferTotalsForTest(t, core, "budget-final-totals")
	if !finalTotals.BudgetLimited || finalTotals.BudgetLimitBytes != 0 || finalTotals.BudgetUsedBytes != 0 || !finalTotals.BudgetExhausted {
		t.Fatalf("final totals were not preserved after close: %+v", finalTotals)
	}

	unlimitedPlan := networkSessionPlanDigest(taskID, "budget-folder", revision, "unlimited")
	assertCommandOK(t, core, networkSessionCommandForTest(
		"budget-unlimited-open", "openNetworkSession", "budget-unlimited", "budget-folder", taskID, unlimitedPlan, revision,
	))
	unlimitedTotals := networkTransferTotalsForTest(t, core, "budget-unlimited-totals")
	if unlimitedTotals.BudgetLimited || unlimitedTotals.BudgetLimitBytes != 0 || unlimitedTotals.BudgetExhausted {
		t.Fatalf("unlimited session totals = %+v", unlimitedTotals)
	}
	assertCommandOK(t, core, networkSessionCommandForTest(
		"budget-unlimited-close", "closeSession", "budget-unlimited", "", taskID, unlimitedPlan, revision,
	))

	assertCommandOK(t, core, configurationSessionCommandForTest("budget-config-open", "openConfiguration", "budget-config"))
	configTotals := networkTransferTotalsForTest(t, core, "budget-config-totals")
	if configTotals.BudgetLimited || configTotals.BudgetLimitBytes != 0 || configTotals.BudgetUsedBytes != 0 || configTotals.BudgetExhausted {
		t.Fatalf("configuration session inherited network budget: %+v", configTotals)
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("budget-config-close", "closeSession", "budget-config"))
}

func TestNetworkByteBudgetValidationStartFailureAndCloseFailure(t *testing.T) {
	const digestRevision = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if got, want := networkSessionPlanDigest("task", "folder", digestRevision, "0"), "2d99ee9b3be1fa761f60ac19950b380846fe24438eeb1f3d147268a652360ac4"; got != want {
		t.Fatalf("network plan v3 digest = %s, want %s", got, want)
	}
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	configurationWithBudget := commandRequest{
		SchemaVersion:       envelopeSchemaVersion,
		RequestID:           "budget-invalid-config-open",
		Command:             "openConfiguration",
		SessionID:           "invalid-config",
		MaximumNetworkBytes: "0",
	}
	encoded, err := json.Marshal(configurationWithBudget)
	if err != nil {
		t.Fatal(err)
	}
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(string(encoded))), "invalid_session")

	assertCommandOK(t, core, configurationSessionCommandForTest("budget-failure-seed-open", "openConfiguration", "budget-failure-seed"))
	assertCommandOK(t, core, boundCommandForTest(
		"budget-failure-seed-folder", "addFolder", "budget-failure-seed", "budget-failure-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": t.TempDir(), "paused": "false"},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("budget-failure-seed-close", "closeSession", "budget-failure-seed"))

	for index, invalid := range []string{"", "00", "01", "-1", "+1", " 1", "9223372036854775808", "Unlimited"} {
		response := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
			fmt.Sprintf("budget-invalid-%d", index), "openNetworkSession", fmt.Sprintf("budget-invalid-session-%d", index),
			"budget-failure-folder", "budget-failure-task", fmt.Sprintf("%064x", index+1), revision, invalid,
		)))
		assertEnvelopeErrorCode(t, response, "invalid_session")
	}

	wrongPlan := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-wrong-plan", "openNetworkSession", "budget-wrong-plan-session", "budget-failure-folder", "budget-failure-task",
		networkSessionPlanDigest("budget-failure-task", "budget-failure-folder", revision, "unlimited"), revision, "0",
	)))
	assertEnvelopeErrorCode(t, wrongPlan, "plan_digest_mismatch")

	const maximum = "7"
	planDigest := networkSessionPlanDigest("budget-failure-task", "budget-failure-folder", revision, maximum)
	core.afterNetworkBudgetInstallForTests = func() error { return errors.New("injected post-install failure") }
	failedOpen := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-start-failure", "openNetworkSession", "budget-start-failure-session", "budget-failure-folder", "budget-failure-task", planDigest, revision, maximum,
	)))
	assertEnvelopeErrorCode(t, failedOpen, "session_start_failed")
	core.afterNetworkBudgetInstallForTests = nil
	if core.runtime != nil || core.session != nil {
		t.Fatal("start failure retained a bridge runtime")
	}
	probeOwner, err := protocol.InstallNetworkByteBudget(1)
	if err != nil {
		t.Fatalf("start failure leaked active protocol budget: %v", err)
	}
	if _, err := protocol.ClearNetworkByteBudget(probeOwner); err != nil {
		t.Fatal(err)
	}
	core.startNetworkAppForTests = func(app *syncthing.App) error {
		if err := app.Start(); err != nil {
			return err
		}
		return errors.New("injected failure returned from App.Start wrapper")
	}
	failedAppStart := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-app-start-failure", "openNetworkSession", "budget-app-start-failure-session", "budget-failure-folder", "budget-failure-task", planDigest, revision, maximum,
	)))
	assertEnvelopeErrorCode(t, failedAppStart, "session_start_failed")
	core.startNetworkAppForTests = nil
	if core.runtime != nil || core.session != nil {
		t.Fatal("App.Start failure retained a bridge runtime")
	}
	probeOwner, err = protocol.InstallNetworkByteBudget(1)
	if err != nil {
		t.Fatalf("App.Start failure leaked active protocol budget: %v", err)
	}
	if _, err := protocol.ClearNetworkByteBudget(probeOwner); err != nil {
		t.Fatal(err)
	}

	assertCommandOK(t, core, networkSessionCommandWithMaximumForTest(
		"budget-close-failure-open", "openNetworkSession", "budget-close-failure", "budget-failure-folder", "budget-failure-task", planDigest, revision, maximum,
	))
	// Force only final accounting reconciliation to fail. The owner budget is
	// still cleared, runtime resources drain, and final totals remain readable.
	core.runtime.networkBudgetBaselineIn++
	failedClose := decodeTestEnvelope(t, core.CommandJSON(networkSessionCommandWithMaximumForTest(
		"budget-close-failure-close", "closeSession", "budget-close-failure", "", "budget-failure-task", planDigest, revision, maximum,
	)))
	assertEnvelopeErrorCode(t, failedClose, "session_close_failed")
	if core.runtime != nil || core.session != nil {
		t.Fatal("accounting close failure retained an already-cleared runtime")
	}
	failedCloseTotals := networkTransferTotalsForTest(t, core, "budget-close-failure-totals")
	if !failedCloseTotals.BudgetLimited || failedCloseTotals.BudgetLimitBytes != 7 || failedCloseTotals.BudgetUsedBytes != 0 {
		t.Fatalf("close failure lost final budget report: %+v", failedCloseTotals)
	}
	assertCommandOK(t, core, networkSessionCommandWithMaximumForTest(
		"budget-reopen", "openNetworkSession", "budget-reopen", "budget-failure-folder", "budget-failure-task", planDigest, revision, maximum,
	))
	assertCommandOK(t, core, networkSessionCommandWithMaximumForTest(
		"budget-reopen-close", "closeSession", "budget-reopen", "", "budget-failure-task", planDigest, revision, maximum,
	))
}

func TestConfigurationCommandRevisionFenceAndSemanticReplay(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	assertCommandOK(t, core, configurationSessionCommandForTest("revision-open", "openConfiguration", "revision-session"))
	initialRevision := core.configurationRevision
	folderPath := t.TempDir()
	missingRevision := boundCommandForTest(
		"revision-missing", "addFolder", "revision-session", "revision-folder", "", "", "", "",
		map[string]string{"path": folderPath, "paused": "false"},
	)
	ledgerBefore := len(core.commandLedger.entries)
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(missingRevision)), "invalid_request")
	staleRevision := boundCommandForTest(
		"revision-stale", "addFolder", "revision-session", "revision-folder", "", "", "", fmt.Sprintf("%064x", 9),
		map[string]string{"path": folderPath, "paused": "false"},
	)
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(staleRevision)), "configuration_revision_mismatch")
	if len(core.commandLedger.entries) != ledgerBefore {
		t.Fatal("stale configuration command wrote the ledger")
	}
	if _, exists := core.runtime.configuration.Folder("revision-folder"); exists {
		t.Fatal("stale configuration command mutated the canonical configuration")
	}

	addRequest := boundCommandForTest(
		"revision-add", "addFolder", "revision-session", "revision-folder", "", "", "", initialRevision,
		map[string]string{"path": folderPath, "paused": "false"},
	)
	addResponse := core.CommandJSON(addRequest)
	if !decodeTestEnvelope(t, addResponse).OK {
		t.Fatal("revision-bound add failed")
	}
	postAddRevision := core.configurationRevision
	if postAddRevision == initialRevision {
		t.Fatal("configuration mutation did not advance revision")
	}
	if replay := core.CommandJSON(addRequest); replay != addResponse {
		t.Fatalf("completed success did not replay after its pre-state revision changed:\nfirst: %s\nretry: %s", addResponse, replay)
	}
	conflictingRevision := boundCommandForTest(
		"revision-add", "addFolder", "revision-session", "revision-folder", "", "", "", postAddRevision,
		map[string]string{"path": folderPath, "paused": "false"},
	)
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(conflictingRevision)), "request_id_conflict")

	pendingRequestText := boundCommandForTest(
		"revision-pending-pause", "pause", "revision-session", "revision-folder", "", "", "", postAddRevision, nil,
	)
	var pendingRequest commandRequest
	if err := json.Unmarshal([]byte(pendingRequestText), &pendingRequest); err != nil {
		t.Fatal(err)
	}
	pendingDigest, err := commandDigest(pendingRequest)
	if err != nil {
		t.Fatal(err)
	}
	if err := core.commandLedger.recordPending(pendingRequest.RequestID, pendingDigest); err != nil {
		t.Fatal(err)
	}
	remoteID := protocol.NewDeviceID([]byte("revision fence peer")).String()
	assertCommandOK(t, core, boundCommandForTest(
		"revision-advance", "addDevice", "revision-session", "", remoteID, "", "", core.configurationRevision,
		map[string]string{"name": "Revision peer", "paused": "false"},
	))
	ledgerBeforeRetry, err := os.ReadFile(core.commandLedger.path)
	if err != nil {
		t.Fatal(err)
	}
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(pendingRequestText)), "configuration_revision_mismatch")
	ledgerAfterRetry, err := os.ReadFile(core.commandLedger.path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ledgerBeforeRetry, ledgerAfterRetry) {
		t.Fatal("stale pending retry rewrote the durable ledger")
	}
	if findFolderSnapshot(t, snapshotForTest(t, core, "revision-after-pending"), "revision-folder").Paused {
		t.Fatal("stale pending retry paused the replacement-scoped folder")
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("revision-close", "closeSession", "revision-session"))
}

func networkTransferTotalsForTest(t *testing.T, core *Core, requestID string) networkTransferTotalsPayload {
	t.Helper()
	response := decodeTestEnvelope(t, core.NetworkTransferTotalsJSON(fmt.Sprintf(`{"schemaVersion":1,"requestID":%q}`, requestID)))
	if !response.OK {
		t.Fatalf("network transfer totals failed: %+v", response.Error)
	}
	var payload networkTransferTotalsPayload
	if err := json.Unmarshal(response.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(response.Payload, &fields); err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"receivedBytes", "sentBytes", "budgetLimited", "budgetLimitBytes", "budgetUsedBytes", "budgetExhausted"} {
		if _, exists := fields[required]; !exists {
			t.Fatalf("network transfer totals omitted required field %q: %s", required, response.Payload)
		}
	}
	return payload
}

func TestSessionOpenCancellationLeavesNoRuntimeOrProcessLock(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true

	core.RequestCancel()
	cancelledBefore := decodeTestEnvelope(t, core.CommandJSON(configurationSessionCommandForTest(
		"cancel-before-open", "openConfiguration", "cancel-before-session",
	)))
	assertEnvelopeErrorCode(t, cancelledBefore, "cancelled")
	if core.runtime != nil || core.session != nil || core.lifecycle != lifecycleCreated {
		t.Fatal("cancel-before-open created partial runtime state")
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("after-cancel-before", "openConfiguration", "after-cancel-before"))
	assertCommandOK(t, core, configurationSessionCommandForTest("after-cancel-before-close", "closeSession", "after-cancel-before"))

	entered := make(chan struct{})
	release := make(chan struct{})
	core.afterSessionProcessLockForTests = func() {
		close(entered)
		<-release
	}
	response := make(chan string, 1)
	go func() {
		response <- core.CommandJSON(configurationSessionCommandForTest(
			"cancel-during-open", "openConfiguration", "cancel-during-session",
		))
	}()
	<-entered
	core.RequestCancel()
	close(release)
	cancelledDuring := decodeTestEnvelope(t, <-response)
	assertEnvelopeErrorCode(t, cancelledDuring, "cancelled")
	core.afterSessionProcessLockForTests = nil
	if core.runtime != nil || core.session != nil || core.lifecycle != lifecycleStopped {
		t.Fatal("cancel-during-open retained partial runtime state")
	}
	assertCommandOK(t, core, configurationSessionCommandForTest("after-cancel-during", "openConfiguration", "after-cancel-during"))
	assertCommandOK(t, core, configurationSessionCommandForTest("after-cancel-during-close", "closeSession", "after-cancel-during"))

	// Cancellation after the network database opens must close it and release
	// the same process fence before a retry can start.
	networkFolderPath := t.TempDir()
	assertCommandOK(t, core, configurationSessionCommandForTest("cancel-network-seed-open", "openConfiguration", "cancel-network-seed"))
	assertCommandOK(t, core, boundCommandForTest(
		"cancel-network-seed-folder", "addFolder", "cancel-network-seed", "cancel-network-folder", "", "", "", core.configurationRevision,
		map[string]string{"path": networkFolderPath, "paused": "false"},
	))
	revision := core.configurationRevision
	assertCommandOK(t, core, configurationSessionCommandForTest("cancel-network-seed-close", "closeSession", "cancel-network-seed"))
	taskID := "cancel-network-task"
	planDigest := networkSessionPlanDigest(taskID, "cancel-network-folder", revision, "unlimited")
	databaseOpened := make(chan struct{})
	releaseDatabase := make(chan struct{})
	core.afterSessionDatabaseOpenForTests = func() {
		close(databaseOpened)
		<-releaseDatabase
	}
	networkResponse := make(chan string, 1)
	go func() {
		networkResponse <- core.CommandJSON(networkSessionCommandForTest(
			"cancel-network-open", "openNetworkSession", "cancel-network-session", "cancel-network-folder", taskID, planDigest, revision,
		))
	}()
	<-databaseOpened
	core.RequestCancel()
	close(releaseDatabase)
	cancelledNetwork := decodeTestEnvelope(t, <-networkResponse)
	assertEnvelopeErrorCode(t, cancelledNetwork, "cancelled")
	core.afterSessionDatabaseOpenForTests = nil
	if core.runtime != nil || core.session != nil || core.lifecycle != lifecycleStopped {
		t.Fatal("cancel-after-database-open retained partial network runtime state")
	}
	assertCommandOK(t, core, networkSessionCommandForTest(
		"cancel-network-retry", "openNetworkSession", "cancel-network-retry", "cancel-network-folder", taskID, planDigest, revision,
	))
	assertCommandOK(t, core, networkSessionCommandForTest(
		"cancel-network-retry-close", "closeSession", "cancel-network-retry", "", taskID, planDigest, revision,
	))
}

func configurationSessionCommandForTest(requestID, command, sessionID string) string {
	return boundCommandForTest(requestID, command, sessionID, "", "", "", "", "", nil)
}

func networkSessionCommandForTest(
	requestID, command, sessionID, folderID, taskID, planDigest, configurationRevision string,
) string {
	return networkSessionCommandWithMaximumForTest(
		requestID, command, sessionID, folderID, taskID, planDigest, configurationRevision, "unlimited",
	)
}

func networkSessionCommandWithMaximumForTest(
	requestID, command, sessionID, folderID, taskID, planDigest, configurationRevision, maximumNetworkBytes string,
) string {
	return boundCommandWithMaximumForTest(
		requestID, command, sessionID, folderID, "", taskID, planDigest, configurationRevision, maximumNetworkBytes, nil,
	)
}

func boundCommandForTest(
	requestID, command, sessionID, folderID, itemID, taskID, planDigest, configurationRevision string,
	arguments map[string]string,
) string {
	maximumNetworkBytes := ""
	if taskID != "" {
		maximumNetworkBytes = "unlimited"
	}
	return boundCommandWithMaximumForTest(
		requestID, command, sessionID, folderID, itemID, taskID, planDigest, configurationRevision, maximumNetworkBytes, arguments,
	)
}

func boundCommandWithMaximumForTest(
	requestID, command, sessionID, folderID, itemID, taskID, planDigest, configurationRevision, maximumNetworkBytes string,
	arguments map[string]string,
) string {
	expectedConfigurationRevision := ""
	commandConfigurationRevision := ""
	if taskID != "" {
		expectedConfigurationRevision = configurationRevision
	} else if isConfigurationReconciliationCommand(command) {
		commandConfigurationRevision = configurationRevision
	}
	request := commandRequest{
		SchemaVersion:                 envelopeSchemaVersion,
		RequestID:                     requestID,
		Command:                       command,
		SessionID:                     sessionID,
		TaskID:                        taskID,
		PlanDigest:                    planDigest,
		ExpectedConfigurationRevision: expectedConfigurationRevision,
		MaximumNetworkBytes:           maximumNetworkBytes,
		CommandConfigurationRevision:  commandConfigurationRevision,
		FolderID:                      folderID,
		ItemID:                        itemID,
		Arguments:                     arguments,
	}
	if taskID != "" {
		request.NetworkOperation = networkOperationSync
	}
	data, err := json.Marshal(request)
	if err != nil {
		panic(err)
	}
	return string(data)
}
