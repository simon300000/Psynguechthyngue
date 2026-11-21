// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/syncthing/syncthing/lib/config"
)

type recoveryQueryPayloadForTest struct {
	Query      string                   `json:"query"`
	Recoveries []recoverySummaryForTest `json:"recoveries"`
	NextCursor string                   `json:"nextCursor"`
	HasMore    bool                     `json:"hasMore"`
}

type recoverySummaryForTest struct {
	RecoveryID   string `json:"recoveryID"`
	FolderID     string `json:"folderID"`
	CommandKind  string `json:"commandKind"`
	RelativePath string `json:"relativePath"`
	PayloadKind  string `json:"payloadKind"`
	Digest       string `json:"digest"`
	Bytes        int64  `json:"bytes"`
	CreatedAt    string `json:"createdAt"`
	Status       string `json:"status"`
}

func TestRecoveryQueryIsOpaquePaginatedAndStrict(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	privateRequestID := "private-recovery-request-uuid"
	record := retainRecoveryRecordForAPITest(t, home, folder, privateRequestID, "private/item.txt", []byte("recoverable"))

	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	raw := mustQuery(t, core, `{"schemaVersion":1,"requestID":"recovery-list","query":"recoveries","limit":1}`)
	envelope := decodeTestEnvelope(t, raw)
	if !envelope.OK {
		t.Fatalf("recovery query failed: %+v", envelope.Error)
	}
	var payload recoveryQueryPayloadForTest
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Query != "recoveries" || payload.HasMore || payload.NextCursor != "" || len(payload.Recoveries) != 1 {
		t.Fatalf("unexpected recovery page: %+v", payload)
	}
	summary := payload.Recoveries[0]
	if summary.RecoveryID != record.RequestIDHash || summary.FolderID != record.FolderID ||
		summary.CommandKind != record.CommandKind || summary.RelativePath != record.RelativePath ||
		summary.PayloadKind != record.PayloadKind || summary.Digest != record.ContentDigest ||
		summary.Bytes != record.ByteCount || summary.CreatedAt != record.CreatedAt ||
		summary.Status != mutationRecoveryStatusRetained {
		t.Fatalf("unexpected recovery summary: %+v", summary)
	}
	for _, secret := range []string{
		privateRequestID,
		home,
		folder,
		"relativeRecoveryLocator",
		"RequestIDHash",
	} {
		if strings.Contains(raw, secret) {
			t.Fatalf("recovery query leaked private storage data %q: %s", secret, raw)
		}
	}

	strict := decodeTestEnvelope(t, mustQuery(t, core, `{"schemaVersion":1,"requestID":"recovery-strict","query":"recoveries","folderID":"not-accepted"}`))
	assertEnvelopeErrorCode(t, strict, "invalid_query")
	explicitDefault := decodeTestEnvelope(t, mustQuery(t, core, `{"schemaVersion":1,"requestID":"recovery-explicit-default","query":"recoveries","includeDeleted":false}`))
	assertEnvelopeErrorCode(t, explicitDefault, "invalid_query")
	unknown := decodeTestEnvelope(t, mustQuery(t, core, `{"schemaVersion":1,"requestID":"recovery-unknown","query":"recoveries","unknown":true}`))
	assertEnvelopeErrorCode(t, unknown, "invalid_request")
}

func TestDisposeRecoveryRequiresExactConfirmationAndFreesCapacity(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	var first mutationRecoveryRecord
	var conflictedCapacityRecord mutationRecoveryRecord
	var preparedCapacityRecord mutationRecoveryRecord
	for index := 0; index < maxMutationRecoveryRecords; index++ {
		record := retainRecoveryRecordForAPITest(
			t,
			home,
			folder,
			fmt.Sprintf("capacity-request-%03d", index),
			fmt.Sprintf("item-%03d.txt", index),
			[]byte(fmt.Sprintf("payload-%03d", index)),
		)
		if index == 0 {
			first = record
		} else if index == 1 {
			conflictedCapacityRecord = record
		} else if index == 2 {
			preparedCapacityRecord = record
		}
	}
	assertRecoveryCapacityExhaustedForAPITest(t, home, folder, "capacity-request-512")

	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	unconfirmed := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-unconfirmed", first, mutationRecoveryStatusRetained, false,
	)))
	assertEnvelopeErrorCode(t, unconfirmed, "recovery_confirmation_required")

	mismatch := first
	mismatch.ByteCount++
	mismatched := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-mismatch", mismatch, mutationRecoveryStatusRetained, true,
	)))
	assertEnvelopeErrorCode(t, mismatched, "recovery_summary_mismatch")

	disposed := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-confirmed", first, mutationRecoveryStatusRetained, true,
	)))
	if !disposed.OK || !strings.Contains(string(disposed.Payload), `"disposition":"disposed"`) ||
		!strings.Contains(string(disposed.Payload), `"recoveryID":"`+first.RequestIDHash+`"`) {
		t.Fatalf("normal disposal did not return an opaque receipt: %+v, %s", disposed.Error, disposed.Payload)
	}
	if _, err := os.Stat(filepath.Join(home, "Bridge", "MutationRecovery", first.RequestIDHash)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("disposed recovery manifest remains: %v", err)
	}

	retainRecoveryRecordForAPITest(
		t,
		home,
		folder,
		"capacity-request-512",
		"item-512.txt",
		[]byte("payload-512"),
	)
	assertRecoveryCapacityExhaustedForAPITest(t, home, folder, "capacity-request-513")

	manifest, err := openMutationDirectoryPath(recoveryManifestPathForTest(home, conflictedCapacityRecord))
	if err != nil {
		t.Fatal(err)
	}
	conflict := conflictedCapacityRecord
	conflict.Status = mutationRecoveryStatusConflict
	if err := writeMutationRecoveryRecord(manifest, mutationRecoveryConflictName, conflict); err != nil {
		_ = manifest.Close()
		t.Fatal(err)
	}
	_ = manifest.Close()
	assertCommandOK(t, core, disposeRecoveryReviewedCommandForTest(
		"capacity-dispose-conflict", conflict, mutationRecoveryStatusConflict, true,
	))
	retainRecoveryRecordForAPITest(t, home, folder, "capacity-request-513", "item-513.txt", []byte("payload-513"))
	assertRecoveryCapacityExhaustedForAPITest(t, home, folder, "capacity-request-514")

	manifest, err = openMutationDirectoryPath(recoveryManifestPathForTest(home, preparedCapacityRecord))
	if err != nil {
		t.Fatal(err)
	}
	if err := unlinkMutationRecordIfPresent(manifest, mutationRecoveryRetainedName); err != nil {
		_ = manifest.Close()
		t.Fatal(err)
	}
	if err := manifest.Sync(); err != nil {
		_ = manifest.Close()
		t.Fatal(err)
	}
	_ = manifest.Close()
	preparedCapacityRecord.Status = mutationRecoveryStatusPrepared
	assertCommandOK(t, core, disposeRecoveryReviewedCommandForTest(
		"capacity-dispose-prepared", preparedCapacityRecord, mutationRecoveryStatusPrepared, true,
	))
	retainRecoveryRecordForAPITest(t, home, folder, "capacity-request-514", "item-514.txt", []byte("payload-514"))
}

func TestReviewedDisposalClosesConflictAndPreparedCapacityStates(t *testing.T) {
	t.Run("conflict requires reviewed command and returns opaque receipt", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "reviewed-conflict", "conflict.txt", []byte("recoverable"))
		manifest, err := openMutationDirectoryPath(recoveryManifestPathForTest(home, record))
		if err != nil {
			t.Fatal(err)
		}
		conflict := record
		conflict.Status = mutationRecoveryStatusConflict
		if err := writeMutationRecoveryRecord(manifest, mutationRecoveryConflictName, conflict); err != nil {
			_ = manifest.Close()
			t.Fatal(err)
		}
		_ = manifest.Close()

		core := newRunningRecoveryCoreForTest(t, home, nil)
		normal := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"normal-rejects-conflict", conflict, mutationRecoveryStatusRetained, true,
		)))
		assertEnvelopeErrorCode(t, normal, "recovery_not_disposable")
		unconfirmed := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryReviewedCommandForTest(
			"reviewed-unconfirmed", conflict, mutationRecoveryStatusConflict, false,
		)))
		assertEnvelopeErrorCode(t, unconfirmed, "recovery_confirmation_required")

		request := disposeRecoveryReviewedCommandForTest("reviewed-conflict-dispose", conflict, mutationRecoveryStatusConflict, true)
		firstRaw := mustCommand(t, core, request)
		first := decodeTestEnvelope(t, firstRaw)
		if !first.OK {
			t.Fatalf("reviewed conflict disposal failed: %+v", first.Error)
		}
		var receipt struct {
			Disposition string `json:"disposition"`
			RecoveryID  string `json:"recoveryID"`
			ReceiptHash string `json:"receiptHash"`
		}
		if err := json.Unmarshal(first.Payload, &receipt); err != nil {
			t.Fatal(err)
		}
		if receipt.Disposition != "disposed" || receipt.RecoveryID != conflict.RequestIDHash || !validMutationRecoveryID(receipt.ReceiptHash) {
			t.Fatalf("unexpected reviewed disposal receipt: %+v", receipt)
		}
		if replay := mustCommand(t, core, request); replay != firstRaw {
			t.Fatalf("completed reviewed disposal did not replay its exact receipt\nfirst:  %s\nreplay: %s", firstRaw, replay)
		}
		if strings.Contains(firstRaw, home) || strings.Contains(firstRaw, folder) {
			t.Fatalf("reviewed disposal receipt leaked private data: %s", firstRaw)
		}
	})

	t.Run("prepared without payload can be exactly reviewed", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := prepareRecoveryRecordForAPITest(t, home, folder, "reviewed-prepared", "prepared.txt", []byte("not moved"))
		core := newRunningRecoveryCoreForTest(t, home, nil)
		page := queryRecoveryPageForTest(t, core, "list-prepared", "", 10)
		if len(page.Recoveries) != 1 || page.Recoveries[0].Status != mutationRecoveryStatusPrepared {
			t.Fatalf("prepared recovery was not listed for review: %+v", page)
		}
		normal := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"normal-rejects-prepared", record, mutationRecoveryStatusPrepared, true,
		)))
		assertEnvelopeErrorCode(t, normal, "recovery_not_disposable")
		wrongKind := record
		wrongKind.PayloadKind = "directory"
		mismatch := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryReviewedCommandForTest(
			"reviewed-prepared-wrong-kind", wrongKind, mutationRecoveryStatusPrepared, true,
		)))
		assertEnvelopeErrorCode(t, mismatch, "recovery_summary_mismatch")
		assertCommandOK(t, core, disposeRecoveryReviewedCommandForTest(
			"reviewed-prepared-dispose", record, mutationRecoveryStatusPrepared, true,
		))
		if _, err := os.Stat(recoveryManifestPathForTest(home, record)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("reviewed prepared recovery remains: %v", err)
		}
	})
}

func TestReviewedDisposalRestartResumesAfterDurableApproval(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	record := retainRecoveryRecordForAPITest(t, home, folder, "reviewed-restart", "conflict.txt", []byte("recoverable"))
	manifest, err := openMutationDirectoryPath(recoveryManifestPathForTest(home, record))
	if err != nil {
		t.Fatal(err)
	}
	conflict := record
	conflict.Status = mutationRecoveryStatusConflict
	if err := writeMutationRecoveryRecord(manifest, mutationRecoveryConflictName, conflict); err != nil {
		_ = manifest.Close()
		t.Fatal(err)
	}
	_ = manifest.Close()
	core := newRunningRecoveryCoreForTest(t, home, nil)
	identity := core.IdentityBlob()
	core.afterRecoveryApprovalForTests = func() error { return errors.New("injected interruption") }
	request := disposeRecoveryReviewedCommandForTest("reviewed-restart-command", conflict, mutationRecoveryStatusConflict, true)
	interrupted := decodeTestEnvelope(t, mustCommand(t, core, request))
	assertEnvelopeErrorCode(t, interrupted, "recovery_disposal_interrupted")
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := newRunningRecoveryCoreForTest(t, home, identity)
	page := queryRecoveryPageForTest(t, restarted, "reviewed-restart-list", "", 10)
	if len(page.Recoveries) != 1 || page.Recoveries[0].Status != mutationRecoveryStatusDisposalApproved {
		t.Fatalf("reviewed approval did not survive restart: %+v", page)
	}
	assertCommandOK(t, restarted, request)
}

func TestFolderRecoveryLocatorRejectsConfigurationChangeAndAncestorRebind(t *testing.T) {
	t.Run("configured path changed", func(t *testing.T) {
		home := t.TempDir()
		originalFolder := t.TempDir()
		changedFolder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, originalFolder, "folder-path-change", "folder.txt", []byte("recoverable"))
		record = moveRecoveryPayloadToFolderLocatorForAPITest(t, home, originalFolder, record)
		core := newRunningRecoveryCoreForTest(t, home, nil)
		setRecoveryFolderPathForAPITest(t, core, record.FolderID, originalFolder)
		setRecoveryFolderPathForAPITest(t, core, record.FolderID, changedFolder)
		response := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"dispose-after-folder-path-change", record, mutationRecoveryStatusRetained, true,
		)))
		assertEnvelopeErrorCode(t, response, "recovery_location_unavailable")
		assertFileContentsAtPathForMutationTest(t, folderRecoveryPayloadPathForAPITest(originalFolder, record), "recoverable")
	})

	t.Run("ancestor rebound after approval", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "folder-ancestor-rebind", "folder.txt", []byte("recoverable"))
		record = moveRecoveryPayloadToFolderLocatorForAPITest(t, home, folder, record)
		core := newRunningRecoveryCoreForTest(t, home, nil)
		setRecoveryFolderPathForAPITest(t, core, record.FolderID, folder)
		versions := filepath.Join(folder, ".stversions")
		preserved := filepath.Join(folder, ".stversions-preserved")
		core.afterRecoveryApprovalForTests = func() error {
			if err := os.Rename(versions, preserved); err != nil {
				return err
			}
			return os.MkdirAll(filepath.Dir(folderRecoveryPayloadPathForAPITest(folder, record)), 0o700)
		}
		response := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"dispose-after-ancestor-rebind", record, mutationRecoveryStatusRetained, true,
		)))
		assertEnvelopeErrorCode(t, response, "recovery_changed")
		retry := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryReviewedCommandForTest(
			"dispose-after-ancestor-rebind-retry", record, mutationRecoveryStatusConflict, true,
		)))
		assertEnvelopeErrorCode(t, retry, "recovery_location_unavailable")
		preservedPayload := filepath.Join(preserved, ".psy-bridge-recovery", record.RequestIDHash, mutationRecoveryPayloadName)
		assertFileContentsAtPathForMutationTest(t, preservedPayload, "recoverable")
	})
}

func TestRecoveryQueryPaginatesWithOpaqueCursor(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	first := retainRecoveryRecordForAPITest(t, home, folder, "page-first", "first.txt", []byte("first"))
	second := retainRecoveryRecordForAPITest(t, home, folder, "page-second", "second.txt", []byte("second"))
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	pageOne := queryRecoveryPageForTest(t, core, "page-one", "", 1)
	if !pageOne.HasMore || pageOne.NextCursor == "" || len(pageOne.Recoveries) != 1 {
		t.Fatalf("unexpected first recovery page: %+v", pageOne)
	}
	pageTwo := queryRecoveryPageForTest(t, core, "page-two", pageOne.NextCursor, 1)
	if pageTwo.HasMore || pageTwo.NextCursor != "" || len(pageTwo.Recoveries) != 1 {
		t.Fatalf("unexpected second recovery page: %+v", pageTwo)
	}
	listed := map[string]bool{
		pageOne.Recoveries[0].RecoveryID: true,
		pageTwo.Recoveries[0].RecoveryID: true,
	}
	if !listed[first.RequestIDHash] || !listed[second.RequestIDHash] {
		t.Fatalf("pagination lost a recovery record: %+v", listed)
	}
	badCursor := decodeTestEnvelope(t, mustQuery(t, core, `{"schemaVersion":1,"requestID":"page-bad","query":"recoveries","cursor":"not-a-cursor"}`))
	assertEnvelopeErrorCode(t, badCursor, "invalid_cursor")
}

func TestDisposeRecoveryRejectsChangedAndSymlinkPayloadsWithoutFollowing(t *testing.T) {
	t.Run("changed payload", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "changed-payload", "changed.txt", []byte("baseline"))
		payload := recoveryPayloadPathForTest(home, record)
		if err := os.WriteFile(payload, []byte("changed after listing"), 0o600); err != nil {
			t.Fatal(err)
		}
		core := newRunningRecoveryCoreForTest(t, home, nil)
		response := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"dispose-changed", record, mutationRecoveryStatusRetained, true,
		)))
		assertEnvelopeErrorCode(t, response, "recovery_changed")
		assertFileContentsAtPathForMutationTest(t, payload, "changed after listing")
	})

	t.Run("top-level symlink", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "symlink-payload", "symlink.txt", []byte("baseline"))
		payload := recoveryPayloadPathForTest(home, record)
		preserved := filepath.Join(t.TempDir(), "preserved")
		if err := os.Rename(payload, preserved); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(t.TempDir(), "target")
		if err := os.WriteFile(target, []byte("must survive"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, payload); err != nil {
			t.Fatal(err)
		}
		core := newRunningRecoveryCoreForTest(t, home, nil)
		response := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
			"dispose-symlink", record, mutationRecoveryStatusRetained, true,
		)))
		assertEnvelopeErrorCode(t, response, "recovery_changed")
		assertFileContentsAtPathForMutationTest(t, target, "must survive")
		assertFileContentsAtPathForMutationTest(t, preserved, "baseline")
	})
}

func TestRecoveryRecordCorruptionAndPathSwapFailClosedWithoutPathLeak(t *testing.T) {
	t.Run("corrupt record", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "corrupt-record", "corrupt.txt", []byte("recoverable"))
		manifest := recoveryManifestPathForTest(home, record)
		if err := os.WriteFile(filepath.Join(manifest, mutationRecoveryRetainedName), []byte(`{"schemaVersion":1,"unknown":true}`), 0o600); err != nil {
			t.Fatal(err)
		}
		core := newRunningRecoveryCoreForTest(t, home, nil)
		raw := mustQuery(t, core, `{"schemaVersion":1,"requestID":"query-corrupt","query":"recoveries"}`)
		envelope := decodeTestEnvelope(t, raw)
		assertEnvelopeErrorCode(t, envelope, "recovery_store_corrupt")
		if strings.Contains(raw, home) || strings.Contains(raw, folder) {
			t.Fatalf("corruption response leaked a private path: %s", raw)
		}
		snapshot := decodeTestEnvelope(t, mustSnapshot(t, core, `{"schemaVersion":1,"requestID":"snapshot-with-corrupt-recovery"}`))
		if !snapshot.OK {
			t.Fatalf("corrupt recovery store blocked the ordinary snapshot: %+v", snapshot.Error)
		}
	})

	t.Run("manifest symlink swap", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(t, home, folder, "manifest-swap", "swap.txt", []byte("recoverable"))
		manifest := recoveryManifestPathForTest(home, record)
		preserved := filepath.Join(home, "Bridge", "preserved-manifest")
		if err := os.Rename(manifest, preserved); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(preserved, manifest); err != nil {
			t.Fatal(err)
		}
		core := newRunningRecoveryCoreForTest(t, home, nil)
		raw := mustQuery(t, core, `{"schemaVersion":1,"requestID":"query-swapped","query":"recoveries"}`)
		envelope := decodeTestEnvelope(t, raw)
		assertEnvelopeErrorCode(t, envelope, "recovery_store_corrupt")
		if strings.Contains(raw, home) || strings.Contains(raw, folder) {
			t.Fatalf("path-swap response leaked a private path: %s", raw)
		}
		assertFileContentsAtPathForMutationTest(t, filepath.Join(preserved, mutationRecoveryPayloadName), "recoverable")
	})
}

func TestDisposeRecoveryRemovesDirectoryTreeWithoutFollowingNestedSymlink(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	externalTarget := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(externalTarget, []byte("outside survives"), 0o600); err != nil {
		t.Fatal(err)
	}
	record := retainDirectoryRecoveryForAPITest(t, home, folder, "directory-tree", externalTarget)
	if record.PayloadKind != "directory" || record.ByteCount <= 0 {
		t.Fatalf("directory recovery did not summarize its full tree: %+v", record)
	}
	core := newRunningRecoveryCoreForTest(t, home, nil)
	assertCommandOK(t, core, disposeRecoveryCommandForTest(
		"dispose-directory-tree", record, mutationRecoveryStatusRetained, true,
	))
	assertFileContentsAtPathForMutationTest(t, externalTarget, "outside survives")
	if _, err := os.Stat(recoveryManifestPathForTest(home, record)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("directory recovery manifest remains after disposal: %v", err)
	}
}

func TestDisposeRecoveryRestartResumesEveryDurableCleanupStage(t *testing.T) {
	stages := []struct {
		name string
		set  func(*Core, func() error)
	}{
		{name: "after approval", set: func(core *Core, hook func() error) { core.afterRecoveryApprovalForTests = hook }},
		{name: "after rename", set: func(core *Core, hook func() error) { core.afterRecoveryRenameForTests = hook }},
		{name: "after payload delete", set: func(core *Core, hook func() error) { core.afterRecoveryDeleteForTests = hook }},
		{name: "before record directory removal", set: func(core *Core, hook func() error) { core.beforeRecoveryRecordRemovalForTests = hook }},
	}
	for _, stage := range stages {
		t.Run(stage.name, func(t *testing.T) {
			home := t.TempDir()
			folder := t.TempDir()
			record := retainRecoveryRecordForAPITest(t, home, folder, "restart-"+stage.name, "restart.txt", []byte("recoverable"))
			core := newRunningRecoveryCoreForTest(t, home, nil)
			identity := core.IdentityBlob()
			injected := false
			stage.set(core, func() error {
				if injected {
					return nil
				}
				injected = true
				return errors.New("injected interruption")
			})
			first := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
				"dispose-before-restart", record, mutationRecoveryStatusRetained, true,
			)))
			assertEnvelopeErrorCode(t, first, "recovery_disposal_interrupted")
			if err := core.Close(); err != nil {
				t.Fatal(err)
			}

			restarted := newRunningRecoveryCoreForTest(t, home, identity)
			page := queryRecoveryPageForTest(t, restarted, "list-after-restart", "", 10)
			if stage.name == "before record directory removal" {
				if len(page.Recoveries) != 0 {
					t.Fatalf("completed payload cleanup remained publicly unresolved: %+v", page)
				}
			} else if len(page.Recoveries) != 1 || page.Recoveries[0].Status != mutationRecoveryStatusDisposalApproved {
				t.Fatalf("restart did not expose durable cleanup state: %+v", page)
			}
			assertCommandOK(t, restarted, disposeRecoveryCommandForTest(
				"dispose-before-restart", record, mutationRecoveryStatusRetained, true,
			))
			if _, err := os.Stat(recoveryManifestPathForTest(home, record)); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("recovery manifest remains after restarted cleanup: %v", err)
			}
		})
	}
}

func TestDisposeRecoveryDetectsPayloadChangeAfterAtomicRename(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	record := retainRecoveryRecordForAPITest(t, home, folder, "changed-after-rename", "changed.txt", []byte("baseline"))
	core := newRunningRecoveryCoreForTest(t, home, nil)
	core.afterRecoveryRenameForTests = func() error {
		return os.WriteFile(
			filepath.Join(recoveryManifestPathForTest(home, record), mutationRecoveryDisposingName),
			[]byte("changed after rename"),
			0o600,
		)
	}
	response := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-change-after-rename", record, mutationRecoveryStatusRetained, true,
	)))
	assertEnvelopeErrorCode(t, response, "recovery_changed")
	assertFileContentsAtPathForMutationTest(
		t,
		filepath.Join(recoveryManifestPathForTest(home, record), mutationRecoveryDisposingName),
		"changed after rename",
	)
}

func TestDisposeRecoveryStrictSchemaRejectsPreparedConflictAndExtraFields(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	record := retainRecoveryRecordForAPITest(t, home, folder, "strict-disposal", "strict.txt", []byte("recoverable"))
	core := newRunningRecoveryCoreForTest(t, home, nil)

	var request commandRequest
	if err := json.Unmarshal([]byte(disposeRecoveryCommandForTest(
		"dispose-extra", record, mutationRecoveryStatusRetained, true,
	)), &request); err != nil {
		t.Fatal(err)
	}
	request.Arguments["unexpected"] = "value"
	extraData, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	extra := decodeTestEnvelope(t, mustCommand(t, core, string(extraData)))
	assertEnvelopeErrorCode(t, extra, "invalid_request")

	request = commandRequest{}
	if err := json.Unmarshal([]byte(disposeRecoveryCommandForTest(
		"dispose-target", record, mutationRecoveryStatusRetained, true,
	)), &request); err != nil {
		t.Fatal(err)
	}
	request.FolderID = "not-accepted"
	targetData, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	target := decodeTestEnvelope(t, mustCommand(t, core, string(targetData)))
	assertEnvelopeErrorCode(t, target, "invalid_request")

	prepared := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-prepared", record, mutationRecoveryStatusPrepared, true,
	)))
	assertEnvelopeErrorCode(t, prepared, "recovery_not_disposable")

	manifest, err := openMutationDirectoryPath(recoveryManifestPathForTest(home, record))
	if err != nil {
		t.Fatal(err)
	}
	conflict := record
	conflict.Status = mutationRecoveryStatusConflict
	if err := writeMutationRecoveryRecord(manifest, mutationRecoveryConflictName, conflict); err != nil {
		_ = manifest.Close()
		t.Fatal(err)
	}
	_ = manifest.Close()
	conflicted := decodeTestEnvelope(t, mustCommand(t, core, disposeRecoveryCommandForTest(
		"dispose-conflict", record, mutationRecoveryStatusRetained, true,
	)))
	assertEnvelopeErrorCode(t, conflicted, "recovery_not_disposable")
}

func queryRecoveryPageForTest(t *testing.T, core *Core, requestID, cursor string, limit int) recoveryQueryPayloadForTest {
	t.Helper()
	request := map[string]any{
		"schemaVersion": 1,
		"requestID":     requestID,
		"query":         "recoveries",
		"limit":         limit,
	}
	if cursor != "" {
		request["cursor"] = cursor
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeTestEnvelope(t, mustQuery(t, core, string(data)))
	if !envelope.OK {
		t.Fatalf("recovery query failed: %+v", envelope.Error)
	}
	var payload recoveryQueryPayloadForTest
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func newRunningRecoveryCoreForTest(t *testing.T, home string, identity []byte) *Core {
	t.Helper()
	core, err := NewCore(home, identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	return core
}

func recoveryManifestPathForTest(home string, record mutationRecoveryRecord) string {
	return filepath.Join(home, "Bridge", "MutationRecovery", record.RequestIDHash)
}

func recoveryPayloadPathForTest(home string, record mutationRecoveryRecord) string {
	return filepath.Join(recoveryManifestPathForTest(home, record), mutationRecoveryPayloadName)
}

func retainDirectoryRecoveryForAPITest(
	t *testing.T,
	home, folder, requestID, externalTarget string,
) mutationRecoveryRecord {
	t.Helper()
	sourceName := "directory-source"
	sourcePath := filepath.Join(folder, sourceName)
	if err := os.MkdirAll(filepath.Join(sourcePath, "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourcePath, "root.txt"), []byte("root bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourcePath, "nested", "child.txt"), []byte("child bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(externalTarget, filepath.Join(sourcePath, "nested", "outside-link")); err != nil {
		t.Fatal(err)
	}
	source, err := openMutationPath(folder, sourceName)
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()
	state, err := captureMutationObjectAt(source)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := prepareMutationRecovery(
		home,
		folder,
		commandRequest{
			SchemaVersion: envelopeSchemaVersion,
			RequestID:     requestID,
			Command:       "delete",
			FolderID:      "recovery-api-folder",
		},
		"directory",
		source,
		state,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer plan.close()
	if err := plan.retain(source, state, mutationRecoveryStatusRetained, true, nil, nil); err != nil {
		t.Fatal(err)
	}
	record, err := readMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryRetainedName)
	if err != nil || record == nil {
		t.Fatalf("read retained directory recovery record: %+v, %v", record, err)
	}
	return *record
}

func retainRecoveryRecordForAPITest(
	t *testing.T,
	home, folder, requestID, relativePath string,
	contents []byte,
) mutationRecoveryRecord {
	t.Helper()
	sourceName := "source-" + strings.ReplaceAll(requestID, "/", "-")
	sourcePath := filepath.Join(folder, sourceName)
	if err := os.WriteFile(sourcePath, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := openMutationPath(folder, sourceName)
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()
	state, err := captureMutationObjectAt(source)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := prepareMutationRecovery(
		home,
		folder,
		commandRequest{
			SchemaVersion: envelopeSchemaVersion,
			RequestID:     requestID,
			Command:       "modify",
			FolderID:      "recovery-api-folder",
		},
		relativePath,
		source,
		state,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer plan.close()
	if err := plan.retain(source, state, mutationRecoveryStatusRetained, true, nil, nil); err != nil {
		t.Fatal(err)
	}
	record, err := readMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryRetainedName)
	if err != nil || record == nil {
		t.Fatalf("read retained recovery record: %+v, %v", record, err)
	}
	return *record
}

func assertRecoveryCapacityExhaustedForAPITest(t *testing.T, home, folder, requestID string) {
	t.Helper()
	sourceName := "source-" + requestID
	if err := os.WriteFile(filepath.Join(folder, sourceName), []byte("overflow"), 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := openMutationPath(folder, sourceName)
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()
	state, err := captureMutationObjectAt(source)
	if err != nil {
		t.Fatal(err)
	}
	_, err = prepareMutationRecovery(
		home,
		folder,
		commandRequest{
			SchemaVersion: envelopeSchemaVersion,
			RequestID:     requestID,
			Command:       "modify",
			FolderID:      "recovery-api-folder",
		},
		"overflow.txt",
		source,
		state,
	)
	if err == nil || !strings.Contains(err.Error(), "capacity is exhausted") {
		t.Fatalf("expected recovery capacity exhaustion, got %v", err)
	}
}

func disposeRecoveryCommandForTest(
	requestID string,
	record mutationRecoveryRecord,
	status string,
	confirmed bool,
) string {
	return commandForTest(requestID, "disposeRecovery", "", "", map[string]string{
		"recoveryID": record.RequestIDHash,
		"digest":     record.ContentDigest,
		"byteCount":  strconv.FormatInt(record.ByteCount, 10),
		"status":     status,
		"confirmed":  strconv.FormatBool(confirmed),
	})
}

func disposeRecoveryReviewedCommandForTest(
	requestID string,
	record mutationRecoveryRecord,
	status string,
	confirmed bool,
) string {
	return commandForTest(requestID, "disposeRecoveryReviewed", "", "", map[string]string{
		"recoveryID":  record.RequestIDHash,
		"payloadKind": record.PayloadKind,
		"digest":      record.ContentDigest,
		"byteCount":   strconv.FormatInt(record.ByteCount, 10),
		"status":      status,
		"confirmed":   strconv.FormatBool(confirmed),
	})
}

func prepareRecoveryRecordForAPITest(
	t *testing.T,
	home, folder, requestID, relativePath string,
	contents []byte,
) mutationRecoveryRecord {
	t.Helper()
	sourceName := "prepared-source-" + requestID
	if err := os.WriteFile(filepath.Join(folder, sourceName), contents, 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := openMutationPath(folder, sourceName)
	if err != nil {
		t.Fatal(err)
	}
	defer source.close()
	state, err := captureMutationObjectAt(source)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := prepareMutationRecovery(home, folder, commandRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     requestID,
		Command:       "modify",
		FolderID:      "recovery-api-folder",
	}, relativePath, source, state)
	if err != nil {
		t.Fatal(err)
	}
	defer plan.close()
	return plan.prepared
}

func moveRecoveryPayloadToFolderLocatorForAPITest(
	t *testing.T,
	home, folder string,
	record mutationRecoveryRecord,
) mutationRecoveryRecord {
	t.Helper()
	destination := folderRecoveryPayloadPathForAPITest(folder, record)
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(recoveryPayloadPathForTest(home, record), destination); err != nil {
		t.Fatal(err)
	}
	record.RelativeRecoveryLocator = "folder:.stversions/.psy-bridge-recovery/" + record.RequestIDHash + "/" + mutationRecoveryPayloadName
	rootDigest := sha256.Sum256([]byte(filepath.Clean(folder)))
	record.RecoveryRootDigest = fmt.Sprintf("%x", rootDigest[:])
	operationDirectory, err := openMutationDirectoryPath(filepath.Dir(destination))
	if err != nil {
		t.Fatal(err)
	}
	record.RecoveryRootIdentity, err = mutationDirectoryIdentity(operationDirectory)
	_ = operationDirectory.Close()
	if err != nil {
		t.Fatal(err)
	}
	manifest := recoveryManifestPathForTest(home, record)
	for _, name := range []string{mutationRecoveryPreparedName, mutationRecoveryRetainedName} {
		data, err := os.ReadFile(filepath.Join(manifest, name))
		if err != nil {
			t.Fatal(err)
		}
		var stored mutationRecoveryRecord
		if err := json.Unmarshal(data, &stored); err != nil {
			t.Fatal(err)
		}
		stored.RelativeRecoveryLocator = record.RelativeRecoveryLocator
		stored.RecoveryRootDigest = record.RecoveryRootDigest
		stored.RecoveryRootIdentity = record.RecoveryRootIdentity
		updated, err := json.Marshal(stored)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(manifest, name), updated, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return record
}

func folderRecoveryPayloadPathForAPITest(folder string, record mutationRecoveryRecord) string {
	return filepath.Join(folder, ".stversions", ".psy-bridge-recovery", record.RequestIDHash, mutationRecoveryPayloadName)
}

func setRecoveryFolderPathForAPITest(t *testing.T, core *Core, folderID, path string) {
	t.Helper()
	waiter, err := core.runtime.configuration.Modify(func(current *config.Configuration) {
		folder, _, exists := current.Folder(folderID)
		if !exists {
			folder = current.Defaults.Folder.Copy()
			folder.ID = folderID
			folder.Paused = true
		}
		folder.Path = filepath.Clean(path)
		applyEmbeddedFolderPolicy(&folder)
		current.SetFolder(folder)
	})
	if err != nil {
		t.Fatal(err)
	}
	waiter.Wait()
}
