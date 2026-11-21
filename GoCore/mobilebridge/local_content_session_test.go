// SPDX-License-Identifier: MIT
package mobilebridge

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

func TestLocalContentSessionReadsVerifiedBytesWithNoNetwork(t *testing.T) {
	fixture := newPhase3Fixture(t)
	core := fixture.core
	remote := protocol.NewDeviceID([]byte("local-content-test-remote")).String()
	assertCommandOK(t, core, commandForTest("local-read-peer", "addDevice", "", remote, map[string]string{"name": "Peer"}))
	assertCommandOK(t, core, commandForTest("local-read-share", "editFolder", fixture.folderID, "", map[string]string{"deviceIDs": remote}))
	item := phase3FindItem(t, phase3QueryItems(t, core, fixture.folderID, false), "initial.txt")
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	var reopenErr error
	core, reopenErr = NewCore(fixture.home, fixture.identity)
	if reopenErr != nil {
		t.Fatal(reopenErr)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = false // The production localContent boundary must disable it itself.
	revision, err := configurationFileRevision(filepath.Join(fixture.home, "Config", "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	task, session := "local-content-task", "local-content-session"
	digest := networkSessionPlanDigestForOperation(task, fixture.folderID, revision, "0", networkOperationLocalContent)
	command := func(id, operation string, args map[string]string) string {
		folderTarget := fixture.folderID
		if operation == "closeSession" {
			folderTarget = ""
		}
		value, err := json.Marshal(commandRequest{SchemaVersion: 1, RequestID: id, Command: operation, SessionID: session,
			FolderID: folderTarget, TaskID: task, PlanDigest: digest, ExpectedConfigurationRevision: revision,
			MaximumNetworkBytes: "0", NetworkOperation: networkOperationLocalContent, Arguments: args})
		if err != nil {
			t.Fatal(err)
		}
		return string(value)
	}
	receivedBefore, sentBefore := protocol.TotalInOut()
	assertCommandOK(t, core, command("local-content-open", "openNetworkSession", nil))
	upload, download := networkOperationPayloadDirections(networkOperationLocalContent)
	if upload || download {
		t.Fatal("local content session grants payload directions")
	}
	for _, device := range core.runtime.configuration.RawCopy().Devices {
		if device.DeviceID != core.localDeviceID && !device.Paused {
			t.Fatal("remote peer was not paused")
		}
	}
	request := readRangeRequest{SchemaVersion: 1, RequestID: "local-bytes", SessionID: session, TaskID: task, PlanDigest: digest,
		ExpectedConfigurationRevision: revision, MaximumNetworkBytes: "0", NetworkOperation: networkOperationLocalContent,
		FolderID: fixture.folderID, ItemID: item.ItemID, ContentVersion: base64.StdEncoding.EncodeToString(item.ContentVersion), Length: int(item.Size)}
	read := func(value readRangeRequest) ([]byte, error) {
		core.mu.Lock()
		defer core.mu.Unlock()
		raw, _ := json.Marshal(value)
		return core.readRangeJSONLocked(string(raw))
	}
	bytes, err := read(request)
	if err != nil || string(bytes) != "initial contents" {
		t.Fatalf("offline local read: %q %v", bytes, err)
	}
	assertEnvelopeErrorCode(t, decodeTestEnvelope(t, core.CommandJSON(command("local-create-denied", "create", map[string]string{"filename": "bad.txt"}))), "operation_scope_mismatch")
	if err := os.Remove(filepath.Join(fixture.folder, "initial.txt")); err != nil {
		t.Fatal(err)
	}
	request.RequestID = "absent-local-bytes"
	_, err = read(request)
	if value, ok := err.(*readRangeError); !ok || value.code != "local_content_unavailable" {
		t.Fatalf("missing bytes did not stop locally: %v", err)
	}
	received, sent := protocol.TotalInOut()
	if received != receivedBefore || sent != sentBefore {
		t.Fatalf("local session used network: (%d,%d) -> (%d,%d)", receivedBefore, sentBefore, received, sent)
	}
	assertCommandOK(t, core, command("local-content-close", "closeSession", nil))
}

func TestLocalContentSessionRejectsAnyPositiveOrUnlimitedBudget(t *testing.T) {
	for _, budget := range []string{"1", "unlimited"} {
		request := commandRequest{SchemaVersion: 1, RequestID: "bad-local-budget", Command: "openNetworkSession", SessionID: "local",
			FolderID: "folder", TaskID: "task", PlanDigest: stringRepeatForLocalTest("a", 64), ExpectedConfigurationRevision: stringRepeatForLocalTest("b", 64),
			MaximumNetworkBytes: budget, NetworkOperation: networkOperationLocalContent}
		if _, err := validateOpenSessionCommand(request, sessionModeNetwork); err == nil {
			t.Fatalf("accepted local budget %s", budget)
		}
	}
}

func stringRepeatForLocalTest(value string, count int) string {
	result := ""
	for i := 0; i < count; i++ {
		result += value
	}
	return result
}
