// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

func TestReconciledAcknowledgementClearsRealPostCommitPendingMutation(t *testing.T) {
	fixture := newPhase3Fixture(t)
	token := phase3Stage(t, fixture.core, "30000000-0000-4000-8000-000000000001", "committed before ledger failure")
	requestText := commandForTest(
		"reconciled-real-create",
		"create",
		fixture.folderID,
		"",
		map[string]string{
			"parentIdentifier":      fixture.rootParent,
			"filename":              "reconciled.txt",
			"isDirectory":           "false",
			"fileProviderOperation": "createAndPropagate",
			"stagedContentToken":    token,
		},
	)

	originalWrite := fixture.core.commandLedger.writeFile
	writes := 0
	fixture.core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected post-commit ledger failure")
		}
		return originalWrite(path, data)
	}
	response := decodeTestEnvelope(t, mustCommand(t, fixture.core, requestText))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if response.Error.MutationPhase != mutationPhaseIndeterminate || response.Error.MutationAmbiguous == nil || !*response.Error.MutationAmbiguous {
		t.Fatalf("post-commit ledger failure lacks stable ambiguity metadata: %+v", response.Error)
	}
	if contents, err := os.ReadFile(filepath.Join(fixture.folder, "reconciled.txt")); err != nil || string(contents) != "committed before ledger failure" {
		t.Fatalf("fixture mutation was not committed before ledger failure: %q, %v", contents, err)
	}
	if entry := fixture.core.commandLedger.entries["reconciled-real-create"]; entry.State != commandStatePending {
		t.Fatalf("completion failure did not retain a pending entry: %+v", entry)
	}

	fixture.core.commandLedger.writeFile = originalWrite
	acknowledgement := decodeTestEnvelope(t, fixture.core.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, requestText, 17, 9),
	))
	if !acknowledgement.OK || acknowledgement.Kind != reconciledCommandAcknowledgementKind {
		t.Fatalf("reconciled acknowledgement failed: %+v", acknowledgement.Error)
	}
	var payload reconciledCommandAcknowledgementPayload
	if err := json.Unmarshal(acknowledgement.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if !payload.Acknowledged || !payload.Removed || payload.ProofReceipt == "" {
		t.Fatalf("unexpected reconciled acknowledgement payload: %+v", payload)
	}
	if _, exists := fixture.core.commandLedger.entries["reconciled-real-create"]; exists {
		t.Fatal("reconciled pending mutation still consumes ledger capacity")
	}
	reloadedLedger, err := loadCommandLedger(fixture.home)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := reloadedLedger.entries["reconciled-real-create"]; exists {
		t.Fatal("reconciled pending mutation remained after durable ledger reload")
	}

	// The proof endpoint is idempotent after an acknowledged entry has already
	// disappeared, but ordinary acknowledgement remains deliberately narrower.
	repeated := decodeTestEnvelope(t, fixture.core.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, requestText, 17, 9),
	))
	if !repeated.OK {
		t.Fatalf("repeated reconciliation was not idempotent: %+v", repeated.Error)
	}
}

func TestReconciledAcknowledgementIsDigestBoundProofBoundAndMutationOnly(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.commandLedger.writeFile = func(string, []byte) error { return nil }

	requestText := commandForTest("proof-bound-pending", "delete", "folder", "stable-id", map[string]string{
		"propagatesToPeers": "true",
		"recursive":         "false",
	})
	request := mustCommandRequestForTest(t, requestText)
	digest, err := commandDigest(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := core.commandLedger.recordPending(request.RequestID, digest); err != nil {
		t.Fatal(err)
	}

	conflictingText := commandForTest("proof-bound-pending", "delete", "folder", "different-id", map[string]string{
		"propagatesToPeers": "true",
		"recursive":         "false",
	})
	conflict := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, conflictingText, 4, 2),
	))
	assertEnvelopeErrorCode(t, conflict, "request_digest_conflict")
	if _, exists := core.commandLedger.entries[request.RequestID]; !exists {
		t.Fatal("digest conflict removed the pending entry")
	}

	invalidProof := reconciledAcknowledgementForTest(t, requestText, 4, 2)
	var decoded map[string]any
	if err := json.Unmarshal([]byte(invalidProof), &decoded); err != nil {
		t.Fatal(err)
	}
	decoded["proof"].(map[string]any)["stateDigest"] = "not-a-digest"
	invalidProofBytes, err := json.Marshal(decoded)
	if err != nil {
		t.Fatal(err)
	}
	invalid := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(string(invalidProofBytes)))
	assertEnvelopeErrorCode(t, invalid, "invalid_reconciliation_proof")
	if _, exists := core.commandLedger.entries[request.RequestID]; !exists {
		t.Fatal("invalid proof removed the pending entry")
	}

	pingText := commandForTest("proof-bound-ping", "ping", "", "", nil)
	ping := mustCommandRequestForTest(t, pingText)
	pingDigest, err := commandDigest(ping)
	if err != nil {
		t.Fatal(err)
	}
	if err := core.commandLedger.recordPending(ping.RequestID, pingDigest); err != nil {
		t.Fatal(err)
	}
	nonMutation := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, pingText, 4, 2),
	))
	assertEnvelopeErrorCode(t, nonMutation, "reconciliation_not_allowed")
	if _, exists := core.commandLedger.entries[ping.RequestID]; !exists {
		t.Fatal("proof endpoint removed a non-mutation command")
	}

	completedText := commandForTest(
		"proof-bound-completed-mutation",
		"delete",
		"folder",
		"completed-stable-id",
		map[string]string{"propagatesToPeers": "true", "recursive": "false"},
	)
	completed := mustCommandRequestForTest(t, completedText)
	completedDigest, err := commandDigest(completed)
	if err != nil {
		t.Fatal(err)
	}
	if err := core.commandLedger.recordPending(completed.RequestID, completedDigest); err != nil {
		t.Fatal(err)
	}
	completedResponse := stableCommandFailureEnvelope(
		completed.RequestID,
		completed.Command,
		"propagation_not_indexed",
		"not indexed",
		mutationPhasePostcommit,
		true,
	)
	if err := core.commandLedger.recordCompleted(completed.RequestID, completedResponse); err != nil {
		t.Fatal(err)
	}
	completedAck := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, completedText, 5, 2),
	))
	if !completedAck.OK {
		t.Fatalf("proof-bound acknowledgement could not clear a completed mutation: %+v", completedAck.Error)
	}
	if _, exists := core.commandLedger.entries[completed.RequestID]; exists {
		t.Fatal("proof-bound acknowledgement retained a completed mutation entry")
	}
}

func TestReconciledAcknowledgementDoesNotLeakPendingCapacity(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.commandLedger.writeFile = func(string, []byte) error { return nil }

	for index := 0; index < maxCommandLedgerEntries+64; index++ {
		requestText := commandForTest(
			fmt.Sprintf("reconciled-capacity-%04d", index),
			"delete",
			"folder",
			fmt.Sprintf("item-%04d", index),
			map[string]string{"propagatesToPeers": "true", "recursive": "false"},
		)
		request := mustCommandRequestForTest(t, requestText)
		digest, err := commandDigest(request)
		if err != nil {
			t.Fatal(err)
		}
		if err := core.commandLedger.recordPending(request.RequestID, digest); err != nil {
			t.Fatalf("record pending %d: %v", index, err)
		}
		acknowledgement := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(
			reconciledAcknowledgementForTest(t, requestText, uint64(index+1), 1),
		))
		if !acknowledgement.OK {
			t.Fatalf("reconciled acknowledgement %d failed: %+v", index, acknowledgement.Error)
		}
	}
	if len(core.commandLedger.entries) != 0 {
		t.Fatalf("reconciled commands leaked ledger capacity: %d", len(core.commandLedger.entries))
	}
}

func TestConfigurationReconciliationRequiresPersistedRestartBoundary(t *testing.T) {
	home := t.TempDir()
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	core.disableNetworkingForTests = true
	identity := core.IdentityBlob()
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	remoteID := protocol.NewDeviceID([]byte("configuration reconciliation restart peer")).String()
	requestText := commandForTest(
		"configuration-reconciliation-restart",
		"addDevice",
		"",
		remoteID,
		map[string]string{
			"name":      "Persisted Once",
			"addresses": `["dynamic","tcp://127.0.0.1:22000"]`,
			"paused":    "true",
		},
	)
	originalWrite := core.commandLedger.writeFile
	writes := 0
	core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected configuration completion write failure")
		}
		return originalWrite(path, data)
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, requestText))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if entry := core.commandLedger.entries["configuration-reconciliation-restart"]; entry.State != commandStatePending {
		t.Fatalf("completion failure did not retain pending state: %+v", entry)
	}
	core.commandLedger.writeFile = originalWrite
	sameCore := decodeTestEnvelope(t, core.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, requestText, 7, 2),
	))
	assertEnvelopeErrorCode(t, sameCore, "reconciliation_restart_required")
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}

	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reloaded.Close() })
	reloaded.disableNetworkingForTests = true
	if err := reloaded.Start(); err != nil {
		t.Fatal(err)
	}
	configuredID, err := protocol.DeviceIDFromString(remoteID)
	if err != nil {
		t.Fatal(err)
	}
	configured, ok := reloaded.runtime.configuration.Device(configuredID)
	if !ok || configured.Name != "Persisted Once" || !configured.Paused || len(configured.Addresses) != 2 {
		t.Fatalf("requested device state was not durable after NewCore: %+v", configured)
	}
	wrongProofKind := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		reconciledAcknowledgementForTest(t, requestText, 8, 3),
	))
	assertEnvelopeErrorCode(t, wrongProofKind, "invalid_reconciliation_proof")
	conflictingText := commandForTest(
		"configuration-reconciliation-restart",
		"addDevice",
		"",
		remoteID,
		map[string]string{"name": "Different Original Command", "paused": "true"},
	)
	digestConflict := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, conflictingText, 8, 3),
	))
	assertEnvelopeErrorCode(t, digestConflict, "request_digest_conflict")
	if _, exists := reloaded.commandLedger.entries["configuration-reconciliation-restart"]; !exists {
		t.Fatal("invalid proof or digest removed the configuration ledger entry")
	}
	originalReloadedWrite := reloaded.commandLedger.writeFile
	reloaded.commandLedger.writeFile = func(string, []byte) error {
		return errors.New("injected reconciliation acknowledgement write failure")
	}
	failedAcknowledgement := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, requestText, 8, 3),
	))
	assertEnvelopeErrorCode(t, failedAcknowledgement, "internal_error")
	if _, exists := reloaded.commandLedger.entries["configuration-reconciliation-restart"]; !exists {
		t.Fatal("failed reconciliation acknowledgement removed the configuration ledger entry")
	}
	if _, retryable := reloaded.commandLedger.startupPending["configuration-reconciliation-restart"]; !retryable {
		t.Fatal("failed reconciliation acknowledgement lost the restarted-core fence")
	}
	reloaded.commandLedger.writeFile = originalReloadedWrite
	acknowledgement := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, requestText, 8, 3),
	))
	if !acknowledgement.OK {
		t.Fatalf("restarted configuration reconciliation failed: %+v", acknowledgement.Error)
	}
	if _, exists := reloaded.commandLedger.entries["configuration-reconciliation-restart"]; exists {
		t.Fatal("reconciled configuration command still consumes ledger capacity")
	}
	unsupported := commandForTest("configuration-proof-sync", "sync", "folder", "", nil)
	unsupportedEnvelope := decodeTestEnvelope(t, reloaded.AcknowledgeReconciledCommandJSON(
		configurationReconciledAcknowledgementForTest(t, unsupported, 8, 3),
	))
	assertEnvelopeErrorCode(t, unsupportedEnvelope, "reconciliation_not_allowed")
}

func TestMutationFailurePhaseDistinguishesDefinitePrecommitFromAmbiguity(t *testing.T) {
	fixture := newPhase3Fixture(t)
	initial := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "initial.txt")

	invalidPath := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"phase-invalid-path",
		"create",
		fixture.folderID,
		"",
		map[string]string{
			"parentIdentifier":      fixture.rootParent,
			"filename":              "..",
			"isDirectory":           "false",
			"fileProviderOperation": "createAndPropagate",
			"stagedContentToken":    "invalid/contents",
		},
	)))
	assertMutationFailurePhaseForTest(t, invalidPath, "invalid_path", mutationPhasePrecommit, false)

	badStageMove := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"phase-invalid-stage-before-move",
		"move",
		fixture.folderID,
		initial.ItemID,
		map[string]string{
			"parentIdentifier":      fixture.rootParent,
			"filename":              "must-not-move.txt",
			"fileProviderOperation": "modifyAndPropagate",
			"stagedContentToken":    "30000000-0000-4000-8000-000000000099/contents",
			"baseContentVersion":    encodeVersionForTest(initial.ContentVersion),
			"baseMetadataVersion":   encodeVersionForTest(initial.MetadataVersion),
		},
	)))
	assertMutationFailurePhaseForTest(t, badStageMove, "staged_content_invalid", mutationPhasePrecommit, false)
	if _, err := os.Stat(filepath.Join(fixture.folder, "initial.txt")); err != nil {
		t.Fatalf("precommit staging rejection moved the source: %v", err)
	}
	if _, err := os.Stat(filepath.Join(fixture.folder, "must-not-move.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("precommit staging rejection created the destination: %v", err)
	}

	postcommit := classifiedMutationFailure("move", commandError("propagation_not_indexed", "not indexed"))
	if postcommit.MutationPhase != mutationPhasePostcommit || postcommit.MutationAmbiguous == nil || !*postcommit.MutationAmbiguous {
		t.Fatalf("postcommit propagation failure was not marked ambiguous: %+v", postcommit)
	}
}

func assertMutationFailurePhaseForTest(t *testing.T, envelope decodedEnvelope, code, phase string, ambiguous bool) {
	t.Helper()
	assertEnvelopeErrorCode(t, envelope, code)
	if envelope.Error.MutationPhase != phase || envelope.Error.MutationAmbiguous == nil || *envelope.Error.MutationAmbiguous != ambiguous {
		t.Fatalf("unexpected mutation failure metadata: %+v", envelope.Error)
	}
}

func encodeVersionForTest(value []byte) string {
	return base64.StdEncoding.EncodeToString(value)
}

func reconciledAcknowledgementForTest(t *testing.T, commandText string, generation, ownerEpoch uint64) string {
	t.Helper()
	command := mustCommandRequestForTest(t, commandText)
	stateDigest := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", command.RequestID, generation, ownerEpoch)))
	request := reconciledCommandAcknowledgementRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     command.RequestID,
		Command:       command,
		Proof: reconciliationProof{
			Kind:               reconciliationProofKind,
			SnapshotGeneration: generation,
			OwnerEpoch:         ownerEpoch,
			StateDigest:        hex.EncodeToString(stateDigest[:]),
		},
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func configurationReconciledAcknowledgementForTest(t *testing.T, commandText string, generation, ownerEpoch uint64) string {
	t.Helper()
	command := mustCommandRequestForTest(t, commandText)
	stateDigest := sha256.Sum256([]byte(fmt.Sprintf("configuration:%s:%d:%d", command.RequestID, generation, ownerEpoch)))
	request := reconciledCommandAcknowledgementRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     command.RequestID,
		Command:       command,
		Proof: reconciliationProof{
			Kind:               "authoritative_snapshot_configuration_state",
			SnapshotGeneration: generation,
			OwnerEpoch:         ownerEpoch,
			StateDigest:        hex.EncodeToString(stateDigest[:]),
		},
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func mustCommandRequestForTest(t *testing.T, raw string) commandRequest {
	t.Helper()
	var request commandRequest
	if err := decodeRequest(raw, &request); err != nil {
		t.Fatal(err)
	}
	return request
}
