// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestRecoveryExportCreatesExactPrivateSnapshotAndDiscardKeepsSource(t *testing.T) {
	home := t.TempDir()
	folder := t.TempDir()
	record := retainRecoveryRecordForAPITest(
		t,
		home,
		folder,
		"recovery-export-source-request",
		"private/report.txt",
		[]byte("recoverable private bytes"),
	)
	core, err := NewCore(home, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	exportID := "11111111-2222-3333-4444-555555555555"
	partialContainer := filepath.Join(
		home,
		"Bridge",
		mutationRecoveryExportsName,
		mutationRecoveryExportPrefix+exportID,
	)
	if err := os.MkdirAll(partialContainer, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(partialContainer, "partial"), []byte("interrupted"), 0o600); err != nil {
		t.Fatal(err)
	}
	request := recoveryExportCommandForTest(exportID, record, "report Recovery.txt")
	first := mustCommand(t, core, request)
	envelope := decodeTestEnvelope(t, first)
	if !envelope.OK || !strings.Contains(string(envelope.Payload), `"disposition":"exported"`) ||
		!strings.Contains(string(envelope.Payload), `"recoveryID":"`+record.RequestIDHash+`"`) {
		t.Fatalf("recovery export did not return an exact receipt: %+v, %s", envelope.Error, envelope.Payload)
	}
	exported := filepath.Join(
		home,
		"Bridge",
		mutationRecoveryExportsName,
		mutationRecoveryExportPrefix+exportID,
		"report Recovery.txt",
	)
	data, err := os.ReadFile(exported)
	if err != nil || string(data) != "recoverable private bytes" {
		t.Fatalf("unexpected recovery export: %q, %v", data, err)
	}
	retained, err := os.ReadFile(recoveryPayloadPathForTest(home, record))
	if err != nil || string(retained) != "recoverable private bytes" {
		t.Fatalf("export changed retained source: %q, %v", retained, err)
	}
	if replay := mustCommand(t, core, request); replay != first {
		t.Fatal("recovery export retry did not replay the exact durable receipt")
	}

	mismatch := record
	mismatch.ByteCount++
	rejected := decodeTestEnvelope(t, mustCommand(t, core, recoveryExportCommandForTest(
		"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
		mismatch,
		"rejected.txt",
	)))
	assertEnvelopeErrorCode(t, rejected, "recovery_summary_mismatch")
	traversal := decodeTestEnvelope(t, mustCommand(t, core, recoveryExportCommandForTest(
		"bbbbbbbb-cccc-dddd-eeee-ffffffffffff",
		record,
		"../escaped.txt",
	)))
	assertEnvelopeErrorCode(t, traversal, "invalid_recovery_export")

	discard := commandForTest(
		"cccccccc-dddd-eeee-ffff-000000000000",
		"discardRecoveryExport",
		"",
		"",
		map[string]string{"exportID": exportID},
	)
	discarded := decodeTestEnvelope(t, mustCommand(t, core, discard))
	if !discarded.OK || !strings.Contains(string(discarded.Payload), `"disposition":"discarded"`) ||
		!strings.Contains(string(discarded.Payload), `"recoveryID":"`+exportID+`"`) {
		t.Fatalf("recovery export discard did not return an exact receipt: %+v, %s", discarded.Error, discarded.Payload)
	}
	if _, err := os.Stat(filepath.Dir(exported)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("recovery export container remains: %v", err)
	}
	idempotentDiscard := commandForTest(
		"ffffffff-0000-1111-2222-333333333333",
		"discardRecoveryExport",
		"",
		"",
		map[string]string{"exportID": exportID},
	)
	if repeated := decodeTestEnvelope(t, mustCommand(t, core, idempotentDiscard)); !repeated.OK {
		t.Fatalf("idempotent recovery export cleanup failed: %+v", repeated.Error)
	}
	retained, err = os.ReadFile(recoveryPayloadPathForTest(home, record))
	if err != nil || string(retained) != "recoverable private bytes" {
		t.Fatalf("discard changed retained source: %q, %v", retained, err)
	}
}

func TestRecoveryExportCopiesDirectoryAndFolderBoundPayloads(t *testing.T) {
	t.Run("directory", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		sourcePath := filepath.Join(folder, "source-directory")
		if err := os.MkdirAll(filepath.Join(sourcePath, "nested"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sourcePath, "nested", "value.txt"), []byte("nested recovery"), 0o600); err != nil {
			t.Fatal(err)
		}
		source, err := openMutationPath(folder, "source-directory")
		if err != nil {
			t.Fatal(err)
		}
		state, err := captureMutationObjectAt(source)
		if err != nil {
			t.Fatal(err)
		}
		plan, err := prepareMutationRecovery(home, folder, commandRequest{
			SchemaVersion: envelopeSchemaVersion,
			RequestID:     "directory-recovery-export-source",
			Command:       "delete",
			FolderID:      "recovery-api-folder",
		}, "directory", source, state)
		if err != nil {
			t.Fatal(err)
		}
		if err := plan.retain(source, state, mutationRecoveryStatusRetained, true, nil, nil); err != nil {
			t.Fatal(err)
		}
		record := plan.prepared
		record.Status = mutationRecoveryStatusRetained
		if err := plan.close(); err != nil {
			t.Fatal(err)
		}

		core, err := NewCore(home, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = core.Close() })
		core.disableNetworkingForTests = true
		if err := core.Start(); err != nil {
			t.Fatal(err)
		}
		exportID := "dddddddd-eeee-ffff-0000-111111111111"
		envelope := decodeTestEnvelope(t, mustCommand(t, core, recoveryExportCommandForTest(
			exportID,
			record,
			"directory Recovery",
		)))
		if !envelope.OK {
			t.Fatalf("directory recovery export failed: %+v", envelope.Error)
		}
		exported := filepath.Join(
			home, "Bridge", mutationRecoveryExportsName,
			mutationRecoveryExportPrefix+exportID, "directory Recovery", "nested", "value.txt",
		)
		data, err := os.ReadFile(exported)
		if err != nil || string(data) != "nested recovery" {
			t.Fatalf("directory recovery export changed content: %q, %v", data, err)
		}
	})

	t.Run("folder bound", func(t *testing.T) {
		home := t.TempDir()
		folder := t.TempDir()
		record := retainRecoveryRecordForAPITest(
			t, home, folder, "folder-bound-export-source", "fallback.txt", []byte("fallback recovery"),
		)
		record = moveRecoveryPayloadToFolderLocatorForAPITest(t, home, folder, record)
		core, err := NewCore(home, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = core.Close() })
		core.disableNetworkingForTests = true
		if err := core.Start(); err != nil {
			t.Fatal(err)
		}
		setRecoveryFolderPathForAPITest(t, core, record.FolderID, folder)
		exportID := "eeeeeeee-ffff-0000-1111-222222222222"
		envelope := decodeTestEnvelope(t, mustCommand(t, core, recoveryExportCommandForTest(
			exportID,
			record,
			"fallback Recovery.txt",
		)))
		if !envelope.OK {
			t.Fatalf("folder-bound recovery export failed: %+v", envelope.Error)
		}
		data, err := os.ReadFile(filepath.Join(
			home, "Bridge", mutationRecoveryExportsName,
			mutationRecoveryExportPrefix+exportID, "fallback Recovery.txt",
		))
		if err != nil || string(data) != "fallback recovery" {
			t.Fatalf("folder-bound recovery export changed content: %q, %v", data, err)
		}
		retained, err := os.ReadFile(folderRecoveryPayloadPathForAPITest(folder, record))
		if err != nil || string(retained) != "fallback recovery" {
			t.Fatalf("folder-bound source changed: %q, %v", retained, err)
		}
	})
}

func recoveryExportCommandForTest(
	exportID string,
	record mutationRecoveryRecord,
	outputName string,
) string {
	request := commandRequest{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     exportID,
		Command:       "exportRecovery",
		Arguments: map[string]string{
			"recoveryID":   record.RequestIDHash,
			"folderID":     record.FolderID,
			"commandKind":  record.CommandKind,
			"relativePath": record.RelativePath,
			"payloadKind":  record.PayloadKind,
			"digest":       record.ContentDigest,
			"byteCount":    strconv.FormatInt(record.ByteCount, 10),
			"status":       record.Status,
			"exportID":     exportID,
			"outputName":   outputName,
		},
	}
	data, err := json.Marshal(request)
	if err != nil {
		panic(err)
	}
	return string(data)
}
