// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/syncthing/syncthing/lib/protocol"
)

type durableSyncFixture struct {
	home     string
	folder   string
	folderID string
	identity []byte
}

func TestPendingSyncReplaysSafelyAcrossNewCore(t *testing.T) {
	fixture := prepareDurableSyncFixture(t)
	request := commandForTest("pending-replay-sync", "sync", fixture.folderID, "", map[string]string{
		"timeoutMS": "5000",
		"settleMS":  "1",
	})
	digest := mustCommandDigestForTest(t, request)
	installLedgerEntryForTest(t, fixture.home, commandLedgerEntry{
		RequestID: "pending-replay-sync",
		Digest:    hex.EncodeToString(digest[:]),
		State:     commandStatePending,
	})

	core, err := NewCore(fixture.home, fixture.identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	if !response.OK {
		t.Fatalf("replay-safe pending sync did not execute: %+v", response.Error)
	}
	entry := core.commandLedger.entries["pending-replay-sync"]
	if entry.State != commandStateCompleted || entry.Response == "" {
		t.Fatalf("successful replay was not completed durably: %+v", entry)
	}
}

func TestCompletedSyncFailureCanRetryToSuccess(t *testing.T) {
	fixture := prepareDurableSyncFixture(t)
	request := commandForTest("retry-sync-incomplete", "sync", fixture.folderID, "", map[string]string{
		"timeoutMS": "5000",
		"settleMS":  "1",
	})
	digest := mustCommandDigestForTest(t, request)
	failed, err := failureEnvelope(
		"retry-sync-incomplete",
		"command",
		"sync_incomplete",
		"bounded sync run ended before folders became quiescent",
	)
	if err != nil {
		t.Fatal(err)
	}
	installLedgerEntryForTest(t, fixture.home, commandLedgerEntry{
		RequestID: "retry-sync-incomplete",
		Digest:    hex.EncodeToString(digest[:]),
		State:     commandStateCompleted,
		Response:  failed,
	})

	core, err := NewCore(fixture.home, fixture.identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	retried := mustCommand(t, core, request)
	if retried == failed {
		t.Fatal("completed sync failure was replayed instead of retried")
	}
	if envelope := decodeTestEnvelope(t, retried); !envelope.OK {
		t.Fatalf("completed sync failure did not retry to success: %+v", envelope.Error)
	}
	if replay := mustCommand(t, core, request); replay != retried {
		t.Fatalf("completed sync success was not replayed exactly:\nfirst:  %s\nreplay: %s", retried, replay)
	}
}

func TestUnsafePendingAndCompletedFailureNeverReplay(t *testing.T) {
	t.Run("pending mutation", func(t *testing.T) {
		home := t.TempDir()
		remoteID := protocol.NewDeviceID([]byte("unsafe pending peer")).String()
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
	})

	t.Run("completed mutation failure", func(t *testing.T) {
		home := t.TempDir()
		core, err := NewCore(home, nil)
		if err != nil {
			t.Fatal(err)
		}
		identity := core.IdentityBlob()
		remoteID := protocol.NewDeviceID([]byte("unsafe completed failure peer")).String()
		request := commandForTest("failed-add-device", "addDevice", "", remoteID, map[string]string{"name": "Must Stay Failed"})
		failed := mustCommand(t, core, request)
		assertEnvelopeErrorCode(t, decodeTestEnvelope(t, failed), "core_not_running")
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
		if replay := mustCommand(t, reloaded, request); replay != failed {
			t.Fatalf("unsafe completed failure executed again:\nfirst:  %s\nreplay: %s", failed, replay)
		}
		parsedRemoteID, err := protocol.DeviceIDFromString(remoteID)
		if err != nil {
			t.Fatal(err)
		}
		if _, configured := reloaded.runtime.configuration.Device(parsedRemoteID); configured {
			t.Fatal("unsafe failed addDevice mutation was replayed")
		}
	})
}

func TestReplaySafeTransitionWriteFailurePreventsExecution(t *testing.T) {
	home := t.TempDir()
	request := commandForTest("retry-start-write-failure", "start", "", "", nil)
	digest := mustCommandDigestForTest(t, request)
	failed, err := failureEnvelope("retry-start-write-failure", "command", "command_failed", "the lifecycle command could not be completed")
	if err != nil {
		t.Fatal(err)
	}
	writeLedgerDocumentForTest(t, home, commandLedgerDocument{
		SchemaVersion: commandLedgerSchemaVersion,
		Entries: []commandLedgerEntry{{
			RequestID: "retry-start-write-failure",
			Digest:    hex.EncodeToString(digest[:]),
			State:     commandStateCompleted,
			Response:  failed,
		}},
	})
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	core.commandLedger.writeFile = func(string, []byte) error {
		return errors.New("injected retry transition failure")
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, response, "internal_error")
	if core.lifecycle != lifecycleCreated || core.runtime != nil {
		t.Fatalf("replay-safe command executed before pending transition was durable: %s", core.lifecycle)
	}
	entry := core.commandLedger.entries["retry-start-write-failure"]
	if entry.State != commandStateCompleted || entry.Response != failed {
		t.Fatalf("failed retry transition did not restore the completed entry: %+v", entry)
	}
}

func prepareDurableSyncFixture(t *testing.T) durableSyncFixture {
	t.Helper()
	appGroup := t.TempDir()
	home := filepath.Join(appGroup, "Core")
	folder := filepath.Join(appGroup, "Shared")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	core.disableNetworkingForTests = true
	identity := core.IdentityBlob()
	if err := core.Start(); err != nil {
		_ = core.Close()
		t.Fatal(err)
	}
	folderID := "durable-sync-folder"
	assertCommandOK(t, core, commandForTest("durable-sync-add-folder", "addFolder", folderID, "", map[string]string{
		"path": folder,
		"type": "sendReceive",
	}))
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	return durableSyncFixture{home: home, folder: folder, folderID: folderID, identity: identity}
}

func installLedgerEntryForTest(t *testing.T, home string, entry commandLedgerEntry) {
	t.Helper()
	ledger, err := loadCommandLedger(home)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := ledger.entries[entry.RequestID]; exists {
		t.Fatalf("fixture request ID %q already exists", entry.RequestID)
	}
	ledger.entries[entry.RequestID] = entry
	if err := ledger.save(); err != nil {
		t.Fatal(err)
	}
}
