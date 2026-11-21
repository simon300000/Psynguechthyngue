// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
)

type phase3Fixture struct {
	core       *Core
	home       string
	folder     string
	folderID   string
	identity   []byte
	rootParent string
}

func newPhase3Fixture(t *testing.T) phase3Fixture {
	t.Helper()
	appGroup := t.TempDir()
	home := filepath.Join(appGroup, "Core")
	folder := filepath.Join(appGroup, "SharedFolder")
	if err := os.MkdirAll(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "initial.txt"), []byte("initial contents"), 0o600); err != nil {
		t.Fatal(err)
	}
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	identity := core.IdentityBlob()
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}
	folderID := "phase3-folder"
	assertCommandOK(t, core, commandForTest("phase3-add-folder", "addFolder", folderID, "", map[string]string{
		"path": folder,
		"type": "sendReceive",
	}))
	assertCommandOK(t, core, commandForTest("phase3-initial-rescan", "rescan", folderID, "", nil))
	return phase3Fixture{
		core:       core,
		home:       home,
		folder:     folder,
		folderID:   folderID,
		identity:   identity,
		rootParent: bridgeFolderIdentifier(folderID),
	}
}

func TestRealFileCRUDStableIdentityRestartAndReadRange(t *testing.T) {
	fixture := newPhase3Fixture(t)
	initial := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "initial.txt")
	if initial.Tombstone || initial.ItemID == "" || len(initial.ContentVersion) != 32 || len(initial.MetadataVersion) != 32 {
		t.Fatalf("unexpected initial query item: %+v", initial)
	}

	rangeRequest, err := json.Marshal(readRangeRequest{
		SchemaVersion:  envelopeSchemaVersion,
		RequestID:      "read-initial",
		FolderID:       fixture.folderID,
		ItemID:         initial.ItemID,
		ContentVersion: base64.StdEncoding.EncodeToString(initial.ContentVersion),
		Offset:         2,
		Length:         7,
	})
	if err != nil {
		t.Fatal(err)
	}
	rangeEnvelope := decodeTestEnvelope(t, fixture.core.ReadRangeJSON(string(rangeRequest)))
	if !rangeEnvelope.OK || rangeEnvelope.Kind != "readRange" {
		t.Fatalf("read range failed: %+v", rangeEnvelope.Error)
	}
	var rangePayload readRangePayload
	if err := json.Unmarshal(rangeEnvelope.Payload, &rangePayload); err != nil {
		t.Fatal(err)
	}
	if string(rangePayload.Data) != "itial c" {
		t.Fatalf("unexpected local range %q", rangePayload.Data)
	}

	wrongVersionRequest := readRangeRequest{
		SchemaVersion:  envelopeSchemaVersion,
		RequestID:      "read-version-conflict",
		FolderID:       fixture.folderID,
		ItemID:         initial.ItemID,
		ContentVersion: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Offset:         0,
		Length:         1,
	}
	wrongVersionJSON, err := json.Marshal(wrongVersionRequest)
	if err != nil {
		t.Fatal(err)
	}
	conflictEnvelope := decodeTestEnvelope(t, fixture.core.ReadRangeJSON(string(wrongVersionJSON)))
	assertEnvelopeErrorCode(t, conflictEnvelope, "version_conflict")
	if conflictEnvelope.RequestID != wrongVersionRequest.RequestID || conflictEnvelope.Kind != "readRange" {
		t.Fatalf("read error envelope lost identity: %+v", conflictEnvelope)
	}
	for index := 0; index < 1_000; index++ {
		query := phase3QueryItems(t, fixture.core, fixture.folderID, false)
		if len(query.Items) == 0 {
			t.Fatalf("query %d after read error returned no items", index)
		}
	}

	createToken := phase3Stage(t, fixture.core, "00000000-0000-4000-8000-000000000001", "created contents")
	assertCommandOK(t, fixture.core, commandForTest("phase3-create", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "created.txt",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    createToken,
	}))
	created := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "created.txt")
	if contents, err := os.ReadFile(filepath.Join(fixture.folder, "created.txt")); err != nil || string(contents) != "created contents" {
		t.Fatalf("create did not install staged contents: %q, %v", contents, err)
	}

	modifyToken := phase3Stage(t, fixture.core, "00000000-0000-4000-8000-000000000002", "modified contents")
	oldContentVersion := base64.StdEncoding.EncodeToString(created.ContentVersion)
	oldMetadataVersion := base64.StdEncoding.EncodeToString(created.MetadataVersion)
	modifyArguments := map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "created.txt",
		"fileProviderOperation": "modifyAndPropagate",
		"stagedContentToken":    modifyToken,
		"baseContentVersion":    oldContentVersion,
		"baseMetadataVersion":   oldMetadataVersion,
	}
	assertCommandOK(t, fixture.core, commandForTest("phase3-modify", "modify", fixture.folderID, created.ItemID, modifyArguments))
	modified := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "created.txt")
	if modified.ItemID != created.ItemID {
		t.Fatalf("modify changed stable item ID: %q -> %q", created.ItemID, modified.ItemID)
	}
	conflict := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("phase3-conflict", "modify", fixture.folderID, created.ItemID, modifyArguments)))
	assertEnvelopeErrorCode(t, conflict, "version_conflict")

	moveRequest := commandForTest("phase3-move", "move", fixture.folderID, modified.ItemID, map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "renamed.txt",
		"fileProviderOperation": "modifyAndPropagate",
		"baseContentVersion":    base64.StdEncoding.EncodeToString(modified.ContentVersion),
		"baseMetadataVersion":   base64.StdEncoding.EncodeToString(modified.MetadataVersion),
	})
	moveResponse := mustCommand(t, fixture.core, moveRequest)
	if envelope := decodeTestEnvelope(t, moveResponse); !envelope.OK {
		t.Fatalf("move failed: %+v", envelope.Error)
	}
	renamed := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "renamed.txt")
	if renamed.ItemID != created.ItemID {
		t.Fatalf("bridge-originated rename did not retain identity: %q -> %q", created.ItemID, renamed.ItemID)
	}
	if _, err := os.Stat(filepath.Join(fixture.folder, "created.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("move source still exists: %v", err)
	}

	if err := fixture.core.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := fixture.core.Start(); err != nil {
		t.Fatal(err)
	}
	if retry := mustCommand(t, fixture.core, moveRequest); retry != moveResponse {
		t.Fatalf("move requestID was not idempotent across Stop/Start:\n%s\n%s", moveResponse, retry)
	}

	deleteRequest := commandForTest("phase3-delete", "delete", fixture.folderID, renamed.ItemID, map[string]string{
		"baseContentVersion":  base64.StdEncoding.EncodeToString(renamed.ContentVersion),
		"baseMetadataVersion": base64.StdEncoding.EncodeToString(renamed.MetadataVersion),
		"propagatesToPeers":   "true",
		"recursive":           "false",
	})
	deleteResponse := mustCommand(t, fixture.core, deleteRequest)
	if envelope := decodeTestEnvelope(t, deleteResponse); !envelope.OK {
		t.Fatalf("delete failed: %+v", envelope.Error)
	}
	if retry := mustCommand(t, fixture.core, deleteRequest); retry != deleteResponse {
		t.Fatal("delete requestID did not return its exact cached response")
	}
	tombstone := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, true), "renamed.txt")
	if !tombstone.Tombstone || tombstone.ItemID != renamed.ItemID {
		t.Fatalf("delete tombstone lost stable identity: %+v", tombstone)
	}

	if err := fixture.core.Close(); err != nil {
		t.Fatal(err)
	}
	reloaded, err := NewCore(fixture.home, fixture.identity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reloaded.Close() })
	reloaded.disableNetworkingForTests = true
	if err := reloaded.Start(); err != nil {
		t.Fatal(err)
	}
	reloadedTombstone := phase3FindItem(t, phase3QueryItems(t, reloaded, fixture.folderID, true), "renamed.txt")
	if reloadedTombstone.ItemID != renamed.ItemID || !reloadedTombstone.Tombstone {
		t.Fatalf("registry did not persist across NewCore: %+v", reloadedTombstone)
	}
}

func TestSystemEvictionObservationWithdrawsSourceAfterBytesAreAlreadyGone(t *testing.T) {
	fixture := newPhase3Fixture(t)
	conflictName := "note.sync-conflict-20260811-103000-DEVICE.txt"
	if err := os.WriteFile(filepath.Join(fixture.folder, conflictName), []byte("conflict"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, fixture.core, commandForTest("conflict-rescan", "rescan", fixture.folderID, "", nil))
	conflict := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), conflictName)
	if conflict.Availability != "conflict" || !conflict.Unuploaded {
		t.Fatalf("conflict copy was advertised as uploaded/evictable: %+v", conflict)
	}

	item := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "initial.txt")
	version := base64.StdEncoding.EncodeToString(item.ContentVersion)
	stillPresent := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"system-eviction-still-present",
		"evict",
		fixture.folderID,
		item.ItemID,
		map[string]string{
			"contentVersion":         version,
			"systemEvictionObserved": "true",
		},
	)))
	assertEnvelopeErrorCode(t, stillPresent, "content_still_materialized")

	withoutReplica := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest(
		"normal-eviction-requires-replica",
		"evict",
		fixture.folderID,
		item.ItemID,
		map[string]string{"contentVersion": version},
	)))
	assertEnvelopeErrorCode(t, withoutReplica, "local_content_state_failed")
	if _, err := os.Stat(filepath.Join(fixture.folder, "initial.txt")); err != nil {
		t.Fatalf("failed normal eviction removed local bytes: %v", err)
	}

	if err := os.Remove(filepath.Join(fixture.folder, "initial.txt")); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, fixture.core, commandForTest(
		"system-eviction-observed",
		"evict",
		fixture.folderID,
		item.ItemID,
		map[string]string{
			"contentVersion":         version,
			"systemEvictionObserved": "true",
		},
	))
	if _, err := os.Stat(filepath.Join(fixture.folder, "initial.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("system-observed eviction unexpectedly restored bytes: %v", err)
	}
}

func TestFileMutationsAllowSendOnlyAndRejectNonWritableFolderStates(t *testing.T) {
	fixture := newPhase3Fixture(t)
	assertCommandOK(t, fixture.core, commandForTest("mutation-send-only", "editFolder", fixture.folderID, "", map[string]string{
		"type": "sendOnly",
	}))

	createToken := phase3Stage(t, fixture.core, "00000000-0000-4000-8000-000000000101", "send-only create")
	assertCommandOK(t, fixture.core, commandForTest("send-only-create", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "send-only.txt",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    createToken,
	}))
	created := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "send-only.txt")

	modifyToken := phase3Stage(t, fixture.core, "00000000-0000-4000-8000-000000000102", "send-only modify")
	assertCommandOK(t, fixture.core, commandForTest("send-only-modify", "modify", fixture.folderID, created.ItemID, map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "send-only.txt",
		"fileProviderOperation": "modifyAndPropagate",
		"stagedContentToken":    modifyToken,
		"baseContentVersion":    base64.StdEncoding.EncodeToString(created.ContentVersion),
		"baseMetadataVersion":   base64.StdEncoding.EncodeToString(created.MetadataVersion),
	}))
	modified := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "send-only.txt")

	assertCommandOK(t, fixture.core, commandForTest("send-only-move", "move", fixture.folderID, modified.ItemID, map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "send-only-renamed.txt",
		"fileProviderOperation": "modifyAndPropagate",
		"baseContentVersion":    base64.StdEncoding.EncodeToString(modified.ContentVersion),
		"baseMetadataVersion":   base64.StdEncoding.EncodeToString(modified.MetadataVersion),
	}))
	renamed := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "send-only-renamed.txt")

	assertCommandOK(t, fixture.core, commandForTest("send-only-delete", "delete", fixture.folderID, renamed.ItemID, map[string]string{
		"baseContentVersion":  base64.StdEncoding.EncodeToString(renamed.ContentVersion),
		"baseMetadataVersion": base64.StdEncoding.EncodeToString(renamed.MetadataVersion),
		"propagatesToPeers":   "true",
		"recursive":           "false",
	}))
	deleted := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, true), "send-only-renamed.txt")
	if !deleted.Tombstone {
		t.Fatalf("send-only delete did not produce a Syncthing tombstone: %+v", deleted)
	}

	for _, folderType := range []string{"receiveOnly"} {
		assertCommandOK(t, fixture.core, commandForTest("mutation-"+folderType, "editFolder", fixture.folderID, "", map[string]string{
			"type": folderType,
		}))
		blocked := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("blocked-"+folderType, "create", fixture.folderID, "", map[string]string{
			"parentIdentifier":      fixture.rootParent,
			"filename":              "blocked-" + folderType,
			"isDirectory":           "true",
			"fileProviderOperation": "createAndPropagate",
		})))
		assertEnvelopeErrorCode(t, blocked, "folder_not_writable")
	}

	assertCommandOK(t, fixture.core, commandForTest("mutation-send-receive", "editFolder", fixture.folderID, "", map[string]string{
		"type": "sendReceive",
	}))
	assertCommandOK(t, fixture.core, commandForTest("mutation-paused", "pause", fixture.folderID, "", nil))
	paused := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("blocked-paused", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "blocked-paused",
		"isDirectory":           "true",
		"fileProviderOperation": "createAndPropagate",
	})))
	assertEnvelopeErrorCode(t, paused, "folder_paused")
}

func TestFolderMutationTypeCapabilityIsExact(t *testing.T) {
	for _, folderType := range []config.FolderType{
		config.FolderTypeSendReceive,
		config.FolderTypeSendOnly,
	} {
		folder := config.FolderConfiguration{
			Type:           folderType,
			FilesystemType: config.FilesystemTypeBasic,
		}
		if !folderSupportsFileMutations(folder) {
			t.Fatalf("basic %s folder unexpectedly rejected local mutation", folderType)
		}
	}

	for _, folderType := range []config.FolderType{
		config.FolderTypeReceiveOnly,
		config.FolderTypeReceiveEncrypted,
	} {
		folder := config.FolderConfiguration{
			Type:           folderType,
			FilesystemType: config.FilesystemTypeBasic,
		}
		if folderSupportsFileMutations(folder) {
			t.Fatalf("basic %s folder unexpectedly accepted local mutation", folderType)
		}
	}

	if folderSupportsFileMutations(config.FolderConfiguration{
		Type:           config.FolderTypeSendReceive,
		FilesystemType: config.FilesystemTypeFake,
	}) {
		t.Fatal("non-basic filesystem unexpectedly accepted local mutation")
	}
}

func TestFileMutationRejectsTraversalSymlinksAndBadStaging(t *testing.T) {
	fixture := newPhase3Fixture(t)

	traversal := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-traversal", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "..",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    "/absolute/contents",
	})))
	assertEnvelopeErrorCode(t, traversal, "invalid_path")

	absoluteToken := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-absolute-stage", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "absolute.txt",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    "/tmp/contents",
	})))
	assertEnvelopeErrorCode(t, absoluteToken, "staged_content_invalid")

	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlinkUUID := "00000000-0000-4000-8000-000000000003"
	symlinkDirectory := filepath.Join(fixture.core.stagingDirectory, symlinkUUID)
	if err := os.MkdirAll(symlinkDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(symlinkDirectory, "contents")); err != nil {
		t.Fatal(err)
	}
	symlinkStage := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-symlink-stage", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      fixture.rootParent,
		"filename":              "symlink-stage.txt",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    symlinkUUID + "/contents",
	})))
	assertEnvelopeErrorCode(t, symlinkStage, "staged_content_invalid")

	if err := os.Symlink(outside, filepath.Join(fixture.folder, "source-link")); err != nil {
		t.Fatal(err)
	}
	assertCommandOK(t, fixture.core, commandForTest("attack-rescan-link", "rescan", fixture.folderID, "", nil))
	link := phase3FindItem(t, phase3QueryItems(t, fixture.core, fixture.folderID, false), "source-link")
	deleteLink := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-delete-link", "delete", fixture.folderID, link.ItemID, map[string]string{
		"baseContentVersion":  base64.StdEncoding.EncodeToString(link.ContentVersion),
		"baseMetadataVersion": base64.StdEncoding.EncodeToString(link.MetadataVersion),
		"propagatesToPeers":   "true",
		"recursive":           "false",
	})))
	assertEnvelopeErrorCode(t, deleteLink, "symlink_rejected")

	parentLink := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-parent-link", "create", fixture.folderID, "", map[string]string{
		"parentIdentifier":      "item-" + link.ItemID,
		"filename":              "child.txt",
		"isDirectory":           "false",
		"fileProviderOperation": "createAndPropagate",
		"stagedContentToken":    phase3Stage(t, fixture.core, "00000000-0000-4000-8000-000000000004", "child"),
	})))
	assertEnvelopeErrorCode(t, parentLink, "invalid_parent")

	realFolder := t.TempDir()
	symlinkFolder := filepath.Join(t.TempDir(), "folder-link")
	if err := os.Symlink(realFolder, symlinkFolder); err != nil {
		t.Fatal(err)
	}
	symlinkRoot := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("attack-folder-root", "addFolder", "symlink-root", "", map[string]string{"path": symlinkFolder})))
	assertEnvelopeErrorCode(t, symlinkRoot, "invalid_path")
}

func TestModifyDoesNotOverwriteConcurrentReplacementAfterVersionCheck(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "destination")
	staged := filepath.Join(directory, "staged")
	replacement := filepath.Join(directory, "replacement")
	if err := os.WriteFile(destination, []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, []byte("requested A"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(replacement, []byte("concurrent C"), 0o600); err != nil {
		t.Fatal(err)
	}
	destinationRef, err := openMutationPath(directory, "destination")
	if err != nil {
		t.Fatal(err)
	}
	defer destinationRef.close()
	baseline, err := captureMutationObjectAt(destinationRef)
	if err != nil {
		t.Fatal(err)
	}
	baselineInfo, err := os.Lstat(destination)
	if err != nil {
		t.Fatal(err)
	}
	beforeCommit := func(command, path string) error {
		if command != "modify" || path != destination {
			return fmt.Errorf("unexpected commit barrier: %s %s", command, path)
		}
		if err := os.Rename(replacement, destination); err != nil {
			return err
		}
		installedInfo, err := os.Lstat(destination)
		if err != nil {
			return err
		}
		if os.SameFile(baselineInfo, installedInfo) {
			return errors.New("test replacement unexpectedly retained the baseline inode")
		}
		contents, err := os.ReadFile(destination)
		if err != nil || string(contents) != "concurrent C" {
			return fmt.Errorf("test replacement was not installed at the commit barrier: %q: %w", contents, err)
		}
		return nil
	}
	rollbackCalled := false
	afterExchange := func(command, installedPath, preservedPath string) error {
		installed, err := os.ReadFile(installedPath)
		if err != nil {
			return err
		}
		preserved, err := os.ReadFile(preservedPath)
		if err != nil {
			return err
		}
		if string(installed) != "requested A" || string(preserved) != "concurrent C" {
			return fmt.Errorf("exchange did not preserve the current objects: installed=%q preserved=%q", installed, preserved)
		}
		return nil
	}
	beforeRollback := func(command, installedPath, preservedPath string) error {
		rollbackCalled = true
		return nil
	}

	failure := replaceMutationFileCAS(staged, destinationRef, baseline, nil, beforeCommit, afterExchange, beforeRollback, nil, nil)
	assertMutationCommitErrorForTest(t, failure, "version_conflict", mutationPhasePrecommit, false)
	if !rollbackCalled {
		t.Fatal("modify conflict did not use the guarded atomic rollback")
	}
	contents, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "concurrent C" {
		t.Fatalf("concurrent replacement was overwritten: %q", contents)
	}
}

func TestModifyFinalRemovalDoesNotUnlinkWriteThroughOldDescriptor(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "destination")
	staged := filepath.Join(directory, "staged")
	if err := os.WriteFile(destination, []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, []byte("requested A"), 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(destination, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	destinationRef, err := openMutationPath(directory, "destination")
	if err != nil {
		t.Fatal(err)
	}
	defer destinationRef.close()
	baseline, err := captureMutationObjectAt(destinationRef)
	if err != nil {
		t.Fatal(err)
	}
	recovery := prepareMutationRecoveryForTest(t, directory, destinationRef, baseline, "modify-final-window", "modify", "destination")
	defer recovery.close()
	beforeFinalRemoval := func(command, path string) error {
		if err := writer.Truncate(0); err != nil {
			return err
		}
		if _, err := writer.WriteAt([]byte("late old inode C"), 0); err != nil {
			return err
		}
		return writer.Sync()
	}

	if failure := replaceMutationFileCAS(staged, destinationRef, baseline, recovery, nil, nil, nil, beforeFinalRemoval, nil); failure != nil {
		t.Fatalf("modify failed before exposing the final-removal race: %+v", failure)
	}
	assertFileContentsAtPathForMutationTest(t, destination, "requested A")
	assertFileContentsAtPathForMutationTest(t, recovery.payload.absolutePath, "late old inode C")
}

func TestDeleteFinalRemovalDoesNotUnlinkWriteThroughOldDescriptor(t *testing.T) {
	directory := t.TempDir()
	quarantine := filepath.Join(directory, "quarantine")
	if err := os.WriteFile(quarantine, []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(quarantine, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	quarantineRef, err := openMutationPath(directory, "quarantine")
	if err != nil {
		t.Fatal(err)
	}
	defer quarantineRef.close()
	baseline, err := captureMutationObjectAt(quarantineRef)
	if err != nil {
		t.Fatal(err)
	}
	recovery := prepareMutationRecoveryForTest(t, directory, quarantineRef, baseline, "delete-final-window", "delete", "quarantine")
	defer recovery.close()
	beforeFinalRemoval := func(string, string) error {
		if err := writer.Truncate(0); err != nil {
			return err
		}
		if _, err := writer.WriteAt([]byte("late deleted inode C"), 0); err != nil {
			return err
		}
		return writer.Sync()
	}

	if err := recovery.retain(quarantineRef, baseline, mutationRecoveryStatusRetained, true, beforeFinalRemoval, nil); err != nil {
		t.Fatal(err)
	}
	assertFileContentsAtPathForMutationTest(t, recovery.payload.absolutePath, "late deleted inode C")
}

func TestDeleteFinalRemovalDoesNotPartiallyRemoveLateDirectoryTree(t *testing.T) {
	directory := t.TempDir()
	quarantine := filepath.Join(directory, "quarantine")
	if err := os.Mkdir(quarantine, 0o700); err != nil {
		t.Fatal(err)
	}
	quarantineRef, err := openMutationPath(directory, "quarantine")
	if err != nil {
		t.Fatal(err)
	}
	defer quarantineRef.close()
	baseline, err := captureMutationObjectAt(quarantineRef)
	if err != nil {
		t.Fatal(err)
	}
	recovery := prepareMutationRecoveryForTest(t, directory, quarantineRef, baseline, "delete-directory-final-window", "delete", "quarantine")
	defer recovery.close()
	lateFile := filepath.Join(quarantine, "late", "nested.txt")
	beforeFinalRemoval := func(string, string) error {
		if err := os.MkdirAll(filepath.Dir(lateFile), 0o700); err != nil {
			return err
		}
		return os.WriteFile(lateFile, []byte("late directory bytes"), 0o600)
	}

	if err := recovery.retain(quarantineRef, baseline, mutationRecoveryStatusRetained, true, beforeFinalRemoval, nil); err != nil {
		t.Fatal(err)
	}
	assertFileContentsAtPathForMutationTest(t, filepath.Join(recovery.payload.absolutePath, "late", "nested.txt"), "late directory bytes")
}

func TestMutationRecoverySurvivesRestartAndDetectsPostRecordWrites(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	quarantine := filepath.Join(folder, "quarantine")
	if err := os.WriteFile(quarantine, []byte("recoverable B"), 0o600); err != nil {
		t.Fatal(err)
	}
	writer, err := os.OpenFile(quarantine, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	quarantineRef, err := openMutationPath(folder, "quarantine")
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := captureMutationObjectAt(quarantineRef)
	if err != nil {
		t.Fatal(err)
	}
	request := commandRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     "private-request-id-must-not-be-persisted",
		Command:       "delete",
		FolderID:      "recovery-restart-folder",
	}
	plan, err := prepareMutationRecovery(home, folder, request, "private/path.txt", quarantineRef, baseline)
	if err != nil {
		t.Fatal(err)
	}
	payloadPath := plan.payload.absolutePath
	manifestDirectory := filepath.Join(home, "Bridge", "MutationRecovery", plan.prepared.RequestIDHash)
	crash := errors.New("injected crash after durable recovery move")
	if err := plan.retain(
		quarantineRef,
		baseline,
		mutationRecoveryStatusRetained,
		true,
		nil,
		func(string) error { return crash },
	); !errors.Is(err, crash) {
		t.Fatalf("unexpected injected crash result: %v", err)
	}
	_ = plan.close()
	_ = quarantineRef.close()
	assertFileContentsAtPathForMutationTest(t, payloadPath, "recoverable B")
	if _, err := os.Stat(filepath.Join(manifestDirectory, mutationRecoveryRetainedName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("retained record was written past the injected crash: %v", err)
	}

	preparedData, err := os.ReadFile(filepath.Join(manifestDirectory, mutationRecoveryPreparedName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(preparedData), request.RequestID) || strings.Contains(string(preparedData), home) || strings.Contains(string(preparedData), folder) {
		t.Fatalf("recovery manifest persisted private request or absolute path data: %s", preparedData)
	}

	restartedSource, err := openMutationPath(folder, "quarantine")
	if err != nil {
		t.Fatal(err)
	}
	defer restartedSource.close()
	restarted, err := prepareMutationRecovery(home, folder, request, "private/path.txt", restartedSource, baseline)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.close()
	if err := restarted.retain(restartedSource, baseline, mutationRecoveryStatusRetained, true, nil, nil); err != nil {
		t.Fatalf("restart did not finalize the durable recovery record: %v", err)
	}
	if _, err := os.Stat(filepath.Join(manifestDirectory, mutationRecoveryRetainedName)); err != nil {
		t.Fatal(err)
	}

	if err := writer.Truncate(0); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.WriteAt([]byte("post-record C"), 0); err != nil {
		t.Fatal(err)
	}
	if err := writer.Sync(); err != nil {
		t.Fatal(err)
	}
	if err := restarted.retain(restartedSource, baseline, mutationRecoveryStatusRetained, true, nil, nil); !errors.Is(err, errMutationRecoveryRequiresManualCleanup) {
		t.Fatalf("post-record mutation was not promoted to manual conflict: %v", err)
	}
	assertFileContentsAtPathForMutationTest(t, payloadPath, "post-record C")
	if _, err := os.Stat(filepath.Join(manifestDirectory, mutationRecoveryConflictName)); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteDoesNotRemoveConcurrentReplacementAfterVersionCheck(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "source")
	quarantine := filepath.Join(directory, "quarantine")
	replacement := filepath.Join(directory, "replacement")
	if err := os.WriteFile(source, []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(replacement, []byte("concurrent C"), 0o600); err != nil {
		t.Fatal(err)
	}
	sourceRef, err := openMutationPath(directory, "source")
	if err != nil {
		t.Fatal(err)
	}
	defer sourceRef.close()
	quarantineRef := sourceRef.withName("quarantine")
	baseline, err := captureMutationObjectAt(sourceRef)
	if err != nil {
		t.Fatal(err)
	}
	baselineInfo, err := os.Lstat(source)
	if err != nil {
		t.Fatal(err)
	}
	beforeCommit := func(command, path string) error {
		if command != "delete" || path != source {
			return fmt.Errorf("unexpected commit barrier: %s %s", command, path)
		}
		if err := os.Rename(replacement, source); err != nil {
			return err
		}
		installedInfo, err := os.Lstat(source)
		if err != nil {
			return err
		}
		if os.SameFile(baselineInfo, installedInfo) {
			return errors.New("test replacement unexpectedly retained the baseline inode")
		}
		contents, err := os.ReadFile(source)
		if err != nil || string(contents) != "concurrent C" {
			return fmt.Errorf("test replacement was not installed at the commit barrier: %q: %w", contents, err)
		}
		return nil
	}
	afterExchange := func(command, installedPath, preservedPath string) error {
		if installedPath != source || preservedPath != quarantine {
			return fmt.Errorf("unexpected quarantine paths: %s %s", installedPath, preservedPath)
		}
		contents, err := os.ReadFile(preservedPath)
		if err != nil || string(contents) != "concurrent C" {
			return fmt.Errorf("quarantine did not retain concurrent replacement: %q: %w", contents, err)
		}
		return nil
	}
	rollbackCalled := false
	beforeRollback := func(command, installedPath, preservedPath string) error {
		rollbackCalled = true
		return nil
	}
	failure := moveMutationObjectCAS("delete", sourceRef, quarantineRef, baseline, "delete_failed", beforeCommit, afterExchange, beforeRollback)
	assertMutationCommitErrorForTest(t, failure, "version_conflict", mutationPhasePrecommit, false)
	if !rollbackCalled {
		t.Fatal("delete conflict did not use the guarded no-replace rollback")
	}
	contents, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "concurrent C" {
		t.Fatalf("concurrent replacement was deleted: %q", contents)
	}
	if _, err := os.Lstat(quarantine); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("quarantine remained after verified rollback: %v", err)
	}
}

func TestMutationCommitRejectsIntermediateAncestorSymlink(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "destination"), []byte("outside B"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "ancestor")); err != nil {
		t.Fatal(err)
	}
	if path, err := openMutationPath(root, "ancestor/destination"); err == nil {
		_ = path.close()
		t.Fatal("mutation path resolution followed an intermediate ancestor symlink")
	}
	contents, err := os.ReadFile(filepath.Join(outside, "destination"))
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "outside B" {
		t.Fatalf("outside destination was modified through an ancestor symlink: %q", contents)
	}
}

func TestMutationCommitRejectsAncestorRebindAfterBaselineCapture(t *testing.T) {
	root := t.TempDir()
	originalParent := filepath.Join(root, "parent")
	movedParent := filepath.Join(root, "parent-original")
	outside := t.TempDir()
	if err := os.Mkdir(originalParent, 0o700); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(originalParent, "destination")
	if err := os.WriteFile(destination, []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	outsideDestination := filepath.Join(outside, "destination")
	if err := os.WriteFile(outsideDestination, []byte("concurrent C"), 0o600); err != nil {
		t.Fatal(err)
	}
	staged := filepath.Join(root, "staged")
	if err := os.WriteFile(staged, []byte("requested A"), 0o600); err != nil {
		t.Fatal(err)
	}
	destinationRef, err := openMutationPath(root, "parent/destination")
	if err != nil {
		t.Fatal(err)
	}
	defer destinationRef.close()
	baseline, err := captureMutationObjectAt(destinationRef)
	if err != nil {
		t.Fatal(err)
	}
	beforeCommit := func(command, path string) error {
		if err := os.Rename(originalParent, movedParent); err != nil {
			return err
		}
		entries, err := os.ReadDir(movedParent)
		if err != nil {
			return err
		}
		temporaryName := ""
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".syncthing.bridge-write-") {
				temporaryName = entry.Name()
				break
			}
		}
		if temporaryName == "" {
			return errors.New("prepared incoming file was not present before ancestor rebind")
		}
		if err := os.WriteFile(filepath.Join(outside, temporaryName), []byte("rebound decoy D"), 0o600); err != nil {
			return err
		}
		return os.Symlink(outside, originalParent)
	}
	failure := replaceMutationFileCAS(staged, destinationRef, baseline, nil, beforeCommit, nil, nil, nil, nil)
	if failure == nil {
		t.Fatal("mutation commit accepted an ancestor rebind after baseline capture")
	}
	outsideContents, err := os.ReadFile(outsideDestination)
	if err != nil {
		t.Fatal(err)
	}
	if string(outsideContents) != "concurrent C" {
		t.Fatalf("rebound destination was overwritten: %q", outsideContents)
	}
	originalContents, err := os.ReadFile(filepath.Join(movedParent, "destination"))
	if err != nil {
		t.Fatal(err)
	}
	if string(originalContents) != "baseline B" {
		t.Fatalf("original destination changed after ancestor rebind: %q", originalContents)
	}
}

func TestDeleteCommitRejectsAncestorRebindAfterBaselineCapture(t *testing.T) {
	root := t.TempDir()
	originalParent := filepath.Join(root, "parent")
	movedParent := filepath.Join(root, "parent-original")
	outside := t.TempDir()
	if err := os.Mkdir(originalParent, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(originalParent, "source"), []byte("baseline B"), 0o600); err != nil {
		t.Fatal(err)
	}
	outsideSource := filepath.Join(outside, "source")
	if err := os.WriteFile(outsideSource, []byte("concurrent C"), 0o600); err != nil {
		t.Fatal(err)
	}
	sourceRef, err := openMutationPath(root, "parent/source")
	if err != nil {
		t.Fatal(err)
	}
	defer sourceRef.close()
	quarantineRef := sourceRef.withName("quarantine")
	baseline, err := captureMutationObjectAt(sourceRef)
	if err != nil {
		t.Fatal(err)
	}
	beforeCommit := func(command, path string) error {
		if err := os.Rename(originalParent, movedParent); err != nil {
			return err
		}
		return os.Symlink(outside, originalParent)
	}
	commitStarted := false
	afterExchange := func(command, installedPath, preservedPath string) error {
		commitStarted = true
		return nil
	}
	failure := moveMutationObjectCAS("delete", sourceRef, quarantineRef, baseline, "delete_failed", beforeCommit, afterExchange, nil)
	assertMutationCommitErrorForTest(t, failure, "version_conflict", mutationPhasePrecommit, false)
	if commitStarted {
		t.Fatal("delete rename ran after its ancestor binding changed")
	}
	assertFileContentsAtPathForMutationTest(t, outsideSource, "concurrent C")
	assertFileContentsAtPathForMutationTest(t, filepath.Join(movedParent, "source"), "baseline B")
}

func assertFileContentsAtPathForMutationTest(t *testing.T, path, expected string) {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != expected {
		t.Fatalf("unexpected contents at %s: %q", path, contents)
	}
}

func prepareMutationRecoveryForTest(
	t *testing.T,
	root string,
	source *mutationPathRef,
	expected mutationObjectState,
	requestID string,
	command string,
	relativePath string,
) *mutationRecoveryPlan {
	t.Helper()
	plan, err := prepareMutationRecovery(
		root,
		root,
		commandRequest{
			SchemaVersion: envelopeSchemaVersion,
			RequestID:     requestID,
			Command:       command,
			FolderID:      "recovery-test-folder",
		},
		relativePath,
		source,
		expected,
	)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}

func assertMutationCommitErrorForTest(t *testing.T, failure *responseError, code, phase string, ambiguous bool) {
	t.Helper()
	if failure == nil || failure.Code != code || failure.MutationPhase != phase || failure.MutationAmbiguous == nil || *failure.MutationAmbiguous != ambiguous {
		t.Fatalf("unexpected mutation failure: %+v", failure)
	}
}

func TestItemRegistryCaseUnicodeCollisionAndAtomicPersistence(t *testing.T) {
	home := t.TempDir()
	registry, err := loadItemIDRegistry(home)
	if err != nil {
		t.Fatal(err)
	}
	id, _, err := registry.itemID("folder", "Case/File.txt", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := registry.itemID("folder", "case/file.txt", false); err == nil {
		t.Fatal("case-fold collision was accepted")
	}
	if _, _, err := registry.itemID("folder", "caf\u00e9.txt", false); err != nil {
		t.Fatal(err)
	}
	if _, _, err := registry.itemID("folder", "cafe\u0301.txt", false); err == nil {
		t.Fatal("Unicode normalization collision was accepted")
	}
	if err := registry.save(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(registry.path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("registry permissions are too broad: %o", info.Mode().Perm())
	}
	reloaded, err := loadItemIDRegistry(home)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := reloaded.pathForItem("folder", id); !ok || got != "Case/File.txt" {
		t.Fatalf("atomic registry reload lost identity: %q, %v", got, ok)
	}
}

func TestItemRegistryRecreateAtDeletedPathGetsNewIdentity(t *testing.T) {
	registry := &itemIDRegistry{
		items:      make(map[string]itemRegistryEntry),
		tombstones: make(map[string]itemRegistryEntry),
		suppressed: make(map[string]itemRegistryEntry),
		ids:        make(map[string]struct{}),
	}
	first, suppressed, err := registry.itemID("folder", "same.txt", false)
	if err != nil || suppressed {
		t.Fatalf("allocate first identity: id=%q suppressed=%v err=%v", first, suppressed, err)
	}
	deleted, suppressed, err := registry.itemID("folder", "same.txt", true)
	if err != nil || suppressed || deleted != first {
		t.Fatalf("transition first identity to tombstone: id=%q suppressed=%v err=%v", deleted, suppressed, err)
	}
	second, suppressed, err := registry.itemID("folder", "same.txt", false)
	if err != nil || suppressed {
		t.Fatalf("allocate recreated identity: id=%q suppressed=%v err=%v", second, suppressed, err)
	}
	if second == first {
		t.Fatal("recreated path reused the deleted object's identity")
	}
	deletedAgain, suppressed, err := registry.itemID("folder", "same.txt", true)
	if err != nil || suppressed || deletedAgain != second {
		t.Fatalf("transition recreated identity to tombstone: id=%q suppressed=%v err=%v", deletedAgain, suppressed, err)
	}
}

func TestCandidatePaginationHandlesOneHundredThousandFixture(t *testing.T) {
	deepCursor := itemQueryCursor{AfterPath: "item-099798"}
	collector := newCandidatePageCollector(deepCursor, 200)
	for index := range 100_000 {
		if !collector.add(indexedCandidate{RelativePath: fmt.Sprintf("item-%06d", index)}) {
			break
		}
	}
	if len(collector.candidates) != 201 || collector.candidates[0].RelativePath != "item-099799" || collector.candidates[200].RelativePath != "item-099999" {
		t.Fatalf("unexpected deep keyset page: first=%q last=%q count=%d", collector.candidates[0].RelativePath, collector.candidates[len(collector.candidates)-1].RelativePath, len(collector.candidates))
	}

	searchCursor := itemQueryCursor{Search: "item-099999"}
	searchCollector := newCandidatePageCollector(searchCursor, 200)
	for index := range 100_000 {
		if !searchCollector.add(indexedCandidate{RelativePath: fmt.Sprintf("item-%06d", index)}) {
			break
		}
	}
	if searchCollector.scanned != 100_000 || len(searchCollector.candidates) != 1 || searchCollector.candidates[0].RelativePath != "item-099999" || searchCollector.scanLimited {
		t.Fatalf("bounded 100k search failed: scanned=%d count=%d limited=%v", searchCollector.scanned, len(searchCollector.candidates), searchCollector.scanLimited)
	}
}

func TestEventQueryBoundsAndSyncRunSlice(t *testing.T) {
	fixture := newPhase3Fixture(t)
	started := time.Now()
	syncResponse := decodeTestEnvelope(t, mustCommand(t, fixture.core, commandForTest("phase3-sync", "sync", fixture.folderID, "", map[string]string{
		"timeoutMS": "2000",
		"settleMS":  "100",
	})))
	if !syncResponse.OK {
		t.Fatalf("bounded sync run failed: %+v", syncResponse.Error)
	}
	if time.Since(started) < 90*time.Millisecond {
		t.Fatal("sync returned before its quiescence settle interval")
	}

	eventsRequest := queryRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     "events-ok",
		Query:         "events",
		Limit:         10,
		TimeoutMS:     0,
	}
	data, err := json.Marshal(eventsRequest)
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeTestEnvelope(t, mustQuery(t, fixture.core, string(data)))
	if !envelope.OK || envelope.Kind != "query" {
		t.Fatalf("event query failed: %+v", envelope.Error)
	}
	var payload eventQueryPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.NextCursor == "" || len(payload.Events) > 10 {
		t.Fatalf("event query was not bounded: %+v", payload)
	}

	eventsRequest.RequestID = "events-too-long"
	eventsRequest.TimeoutMS = 1001
	data, _ = json.Marshal(eventsRequest)
	invalid := decodeTestEnvelope(t, mustQuery(t, fixture.core, string(data)))
	assertEnvelopeErrorCode(t, invalid, "invalid_query")
}

func TestStopCancelsBoundedSyncRun(t *testing.T) {
	fixture := newPhase3Fixture(t)
	responseChannel := make(chan string, 1)
	go func() {
		response := fixture.core.CommandJSON(commandForTest("phase3-sync-cancel", "sync", fixture.folderID, "", map[string]string{
			"timeoutMS": "5000",
			"settleMS":  "1000",
		}))
		responseChannel <- response
	}()
	time.Sleep(50 * time.Millisecond)
	started := time.Now()
	if err := fixture.core.Stop(); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("Stop did not cancel the bounded sync run promptly")
	}
	envelope := decodeTestEnvelope(t, <-responseChannel)
	assertEnvelopeErrorCode(t, envelope, "sync_cancelled")
}

func phase3Stage(t *testing.T, core *Core, uuid, contents string) string {
	t.Helper()
	directory := filepath.Join(core.stagingDirectory, uuid)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "contents"), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return uuid + "/contents"
}

func phase3QueryItems(t *testing.T, core *Core, folderID string, includeDeleted bool) itemQueryPayload {
	t.Helper()
	request := queryRequest{
		SchemaVersion:  envelopeSchemaVersion,
		RequestID:      fmt.Sprintf("items-%d", time.Now().UnixNano()),
		Query:          "items",
		FolderID:       folderID,
		Scope:          "global",
		Limit:          maxQueryLimit,
		IncludeDeleted: includeDeleted,
	}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeTestEnvelope(t, mustQuery(t, core, string(data)))
	if !envelope.OK {
		t.Fatalf("items query failed: %+v", envelope.Error)
	}
	var payload itemQueryPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func phase3FindItem(t *testing.T, payload itemQueryPayload, relativePath string) bridgeIndexItem {
	t.Helper()
	for _, item := range payload.Items {
		if item.RelativePath == relativePath {
			return item
		}
	}
	paths := make([]string, 0, len(payload.Items))
	for _, item := range payload.Items {
		paths = append(paths, item.RelativePath)
	}
	t.Fatalf("item %q not found in %s", relativePath, strings.Join(paths, ", "))
	return bridgeIndexItem{}
}

func mustQuery(t *testing.T, core *Core, request string) string {
	t.Helper()
	return core.QueryJSON(request)
}
