// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

func TestCommandLedgerReplaysCompletedMutationExactlyAcrossNewCore(t *testing.T) {
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
	remoteID := protocol.NewDeviceID([]byte("durable command ledger peer")).String()
	request := commandForTest("durable-device-add", "addDevice", "", remoteID, map[string]string{"name": "Durable Peer"})
	first := mustCommand(t, core, request)
	if envelope := decodeTestEnvelope(t, first); !envelope.OK {
		t.Fatalf("initial mutation failed: %+v", envelope.Error)
	}
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}

	reloaded, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reloaded.Close() })
	// Deliberately do not start the reconstructed Core. Re-executing addDevice
	// would fail core_not_running; a durable replay must return the exact bytes.
	if replay := mustCommand(t, reloaded, request); replay != first {
		t.Fatalf("completed mutation was not replayed exactly across NewCore:\nfirst:  %s\nreplay: %s", first, replay)
	}
	conflict := decodeTestEnvelope(t, mustCommand(t, reloaded, commandForTest(
		"durable-device-add",
		"editDevice",
		"",
		remoteID,
		map[string]string{"name": "Conflicting Peer"},
	)))
	assertEnvelopeErrorCode(t, conflict, "request_id_conflict")
}

func TestCommandLedgerPendingRestartFailsClosedWithoutExecution(t *testing.T) {
	home := t.TempDir()
	remoteID := protocol.NewDeviceID([]byte("pending unsafe mutation peer")).String()
	request := commandForTest("pending-add-device", "addDevice", "", remoteID, map[string]string{"name": "Must Not Execute"})
	digest := mustCommandDigestForTest(t, request)
	writeLedgerDocumentForTest(t, home, commandLedgerDocument{
		SchemaVersion: commandLedgerSchemaVersion,
		Entries: []commandLedgerEntry{{
			RequestID: "pending-add-device",
			Digest:    hex.EncodeToString(digest[:]),
			State:     commandStatePending,
		}},
	})

	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, response, "indeterminate_prior_attempt")
	if core.lifecycle != lifecycleCreated || core.runtime != nil {
		t.Fatalf("pending mutation changed lifecycle after reconstruction: lifecycle=%s runtime=%v", core.lifecycle, core.runtime != nil)
	}
	if strings.Contains(response.Error.Message, request) {
		t.Fatal("indeterminate response leaked the original command")
	}
}

func TestCommandLedgerPreflightWriteFailureDoesNotExecute(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	request := commandForTest("preflight-failure", "start", "", "", nil)
	originalWrite := core.commandLedger.writeFile
	core.commandLedger.writeFile = func(string, []byte) error {
		return errors.New("injected preflight write failure")
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if core.lifecycle != lifecycleCreated || core.runtime != nil {
		t.Fatalf("command executed despite failed pending write: lifecycle=%s runtime=%v", core.lifecycle, core.runtime != nil)
	}
	if len(core.commandLedger.entries) != 0 {
		t.Fatalf("failed preflight left an in-memory entry: %+v", core.commandLedger.entries)
	}

	core.disableNetworkingForTests = true
	core.commandLedger.writeFile = originalWrite
	retry := decodeTestEnvelope(t, mustCommand(t, core, request))
	if !retry.OK || core.lifecycle != lifecycleRunning {
		t.Fatalf("same request could not execute after a definite preflight failure: %+v", retry)
	}
}

func TestCommandLedgerCompletionWriteFailureRemainsPending(t *testing.T) {
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
	remoteID := protocol.NewDeviceID([]byte("completion failure mutation peer")).String()
	originalWrite := core.commandLedger.writeFile
	writes := 0
	core.commandLedger.writeFile = func(path string, data []byte) error {
		writes++
		if writes == 2 {
			return errors.New("injected completed write failure")
		}
		return originalWrite(path, data)
	}
	request := commandForTest("completion-failure", "addDevice", "", remoteID, map[string]string{"name": "Applied Once"})
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if core.lifecycle != lifecycleRunning {
		t.Fatalf("operation did not execute before the injected completion failure: %s", core.lifecycle)
	}
	entry := core.commandLedger.entries["completion-failure"]
	if entry.State != commandStatePending || entry.Response != "" {
		t.Fatalf("completion failure did not roll memory back to pending: %+v", entry)
	}
	retry := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, retry, "indeterminate_prior_attempt")

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
	afterRestart := decodeTestEnvelope(t, mustCommand(t, reloaded, request))
	assertEnvelopeErrorCode(t, afterRestart, "indeterminate_prior_attempt")
	configured, parseErr := protocol.DeviceIDFromString(remoteID)
	if parseErr != nil {
		t.Fatal(parseErr)
	}
	if _, ok := reloaded.runtime.configuration.Device(configured); !ok {
		t.Fatal("the mutation applied before completion failure was not persisted")
	}
}

func TestCommandLedgerRejectsUnsafeOrInvalidFiles(t *testing.T) {
	validEmpty, err := json.Marshal(commandLedgerDocument{SchemaVersion: commandLedgerSchemaVersion, Entries: []commandLedgerEntry{}})
	if err != nil {
		t.Fatal(err)
	}
	overLimitEntries := make([]commandLedgerEntry, maxCommandLedgerEntries+1)
	for index := range overLimitEntries {
		digest := sha256.Sum256([]byte(fmt.Sprintf("entry-%d", index)))
		overLimitEntries[index] = commandLedgerEntry{
			RequestID: fmt.Sprintf("entry-%d", index),
			Digest:    hex.EncodeToString(digest[:]),
			State:     commandStatePending,
		}
	}
	overLimitDocument, err := json.Marshal(commandLedgerDocument{SchemaVersion: commandLedgerSchemaVersion, Entries: overLimitEntries})
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name    string
		prepare func(*testing.T, string)
	}{
		{"corrupt", func(t *testing.T, path string) { writeLedgerBytesForTest(t, path, []byte("{"), 0o600) }},
		{"unsupported-schema", func(t *testing.T, path string) {
			writeLedgerBytesForTest(t, path, []byte(`{"schemaVersion":2,"entries":[]}`), 0o600)
		}},
		{"oversize", func(t *testing.T, path string) {
			writeLedgerBytesForTest(t, path, make([]byte, maxCommandLedgerSize+1), 0o600)
		}},
		{"entry-limit", func(t *testing.T, path string) { writeLedgerBytesForTest(t, path, overLimitDocument, 0o600) }},
		{"broad-permissions", func(t *testing.T, path string) { writeLedgerBytesForTest(t, path, validEmpty, 0o644) }},
		{"symlink", func(t *testing.T, path string) {
			target := filepath.Join(t.TempDir(), "outside-ledger.json")
			if err := os.WriteFile(target, validEmpty, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			home := t.TempDir()
			path := filepath.Join(home, "Bridge", "command-ledger-v1.json")
			test.prepare(t, path)
			core, err := NewCore(home, nil)
			if err == nil {
				_ = core.Close()
				t.Fatal("NewCore accepted an unsafe or invalid command ledger")
			}
		})
	}
}

func TestCommandLedgerDoesNotPersistCommandArgumentsOrPaths(t *testing.T) {
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
	folder := filepath.Join(t.TempDir(), "private-folder-value")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	const privateLabel = "PRIVATE_ARGUMENT_VALUE_4C4E6451"
	response := decodeTestEnvelope(t, mustCommand(t, core, commandForTest(
		"private-argument-command",
		"addFolder",
		"private-folder-id",
		"",
		map[string]string{"path": folder, "label": privateLabel, "type": "sendReceive"},
	)))
	if !response.OK {
		t.Fatalf("fixture command failed: %+v", response.Error)
	}
	const privateArgumentKey = "PRIVATE_ARGUMENT_KEY_603BEFF1"
	rejected := decodeTestEnvelope(t, mustCommand(t, core, commandForTest(
		"private-rejected-command",
		"editFolder",
		"private-folder-id",
		"",
		map[string]string{privateArgumentKey: privateLabel},
	)))
	assertEnvelopeErrorCode(t, rejected, "invalid_request")
	ledgerPath := filepath.Join(home, "Bridge", "command-ledger-v1.json")
	data, err := os.ReadFile(ledgerPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{folder, privateLabel, privateArgumentKey, `"arguments"`} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("command ledger persisted private command input %q", secret)
		}
	}
	info, err := os.Lstat(ledgerPath)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o600 {
		t.Fatalf("command ledger has unsafe type or permissions: %s", info.Mode())
	}
	privateNativeError := &responseError{Code: "move_failed", Message: "rename " + folder + ": private failure"}
	if message := publicCommandErrorMessage(privateNativeError); strings.Contains(message, folder) {
		t.Fatalf("persistable command error leaked a filesystem path: %q", message)
	}
}

func TestCommandLedgerFullDoesNotEvictAcceptedRequestIDs(t *testing.T) {
	home := t.TempDir()
	entries := make([]commandLedgerEntry, maxCommandLedgerEntries)
	for index := range entries {
		requestID := fmt.Sprintf("accepted-%04d", index)
		digest := sha256.Sum256([]byte(requestID))
		entries[index] = commandLedgerEntry{
			RequestID: requestID,
			Digest:    hex.EncodeToString(digest[:]),
			State:     commandStatePending,
		}
	}
	writeLedgerDocumentForTest(t, home, commandLedgerDocument{
		SchemaVersion: commandLedgerSchemaVersion,
		Entries:       entries,
	})
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	response := decodeTestEnvelope(t, mustCommand(t, core, commandForTest("new-request", "ping", "", "", nil)))
	assertEnvelopeErrorCode(t, response, "request_cache_full")
	if len(core.commandLedger.entries) != maxCommandLedgerEntries {
		t.Fatalf("full command ledger evicted an accepted request ID: %d entries", len(core.commandLedger.entries))
	}
	if _, ok := core.commandLedger.entries["accepted-0000"]; !ok {
		t.Fatal("oldest accepted request ID was evicted")
	}
}

func mustCommandDigestForTest(t *testing.T, raw string) [sha256.Size]byte {
	t.Helper()
	var request commandRequest
	if err := decodeRequest(raw, &request); err != nil {
		t.Fatal(err)
	}
	digest, err := commandDigest(request)
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

func writeLedgerDocumentForTest(t *testing.T, home string, document commandLedgerDocument) {
	t.Helper()
	data, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	writeLedgerBytesForTest(t, filepath.Join(home, "Bridge", "command-ledger-v1.json"), data, 0o600)
}

func writeLedgerBytesForTest(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
