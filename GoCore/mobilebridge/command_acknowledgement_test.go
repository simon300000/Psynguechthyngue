// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"
)

func TestAcknowledgeCommandAllowsMoreThanLedgerCapacity(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	// This test exercises the state machine beyond the durable entry bound
	// without issuing more than twelve thousand physical fsync calls. Dedicated
	// tests below retain the real atomic writer for acknowledgement behavior.
	core.commandLedger.writeFile = func(string, []byte) error { return nil }
	for index := 0; index < maxCommandLedgerEntries+64; index++ {
		requestID := fmt.Sprintf("ack-capacity-%04d", index)
		command := decodeTestEnvelope(t, mustCommand(t, core, commandForTest(requestID, "ping", "", "", nil)))
		if !command.OK {
			t.Fatalf("command %d reached a false-full ledger: %+v", index, command.Error)
		}
		acknowledgement := decodeTestEnvelope(t, core.AcknowledgeCommand(requestID))
		if !acknowledgement.OK || acknowledgement.Kind != commandAcknowledgementKind {
			t.Fatalf("acknowledgement %d failed: %+v", index, acknowledgement.Error)
		}
		var payload commandAcknowledgementPayload
		if err := json.Unmarshal(acknowledgement.Payload, &payload); err != nil {
			t.Fatal(err)
		}
		if !payload.Acknowledged || !payload.Removed {
			t.Fatalf("acknowledgement %d returned the wrong payload: %+v", index, payload)
		}
	}
	if len(core.commandLedger.entries) != 0 {
		t.Fatalf("acknowledged commands still consume ledger capacity: %d", len(core.commandLedger.entries))
	}
}

func TestAcknowledgeCommandWriteFailureRetainsCompletedEntry(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	requestID := "ack-write-failure"
	request := commandForTest(requestID, "ping", "", "", nil)
	completed := mustCommand(t, core, request)
	if envelope := decodeTestEnvelope(t, completed); !envelope.OK {
		t.Fatalf("fixture command failed: %+v", envelope.Error)
	}
	originalWrite := core.commandLedger.writeFile
	core.commandLedger.writeFile = func(string, []byte) error {
		return errors.New("injected acknowledgement write failure")
	}
	failed := decodeTestEnvelope(t, core.AcknowledgeCommand(requestID))
	assertEnvelopeErrorCode(t, failed, "internal_error")
	entry, exists := core.commandLedger.entries[requestID]
	if !exists || entry.State != commandStateCompleted || entry.Response != completed {
		t.Fatalf("failed acknowledgement lost its completed entry: %+v", entry)
	}
	if replay := mustCommand(t, core, request); replay != completed {
		t.Fatalf("failed acknowledgement changed replay behavior:\nfirst:  %s\nreplay: %s", completed, replay)
	}

	core.commandLedger.writeFile = originalWrite
	succeeded := decodeTestEnvelope(t, core.AcknowledgeCommand(requestID))
	if !succeeded.OK {
		t.Fatalf("acknowledgement did not recover after writer restoration: %+v", succeeded.Error)
	}
	if _, exists := core.commandLedger.entries[requestID]; exists {
		t.Fatal("successful acknowledgement retained the completed entry")
	}
}

func TestAcknowledgeCommandRejectsPendingAndInvalidButUnknownIsIdempotent(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	request := commandForTest("pending-ack", "addDevice", "", "device", nil)
	digest := mustCommandDigestForTest(t, request)
	if err := core.commandLedger.recordPending("pending-ack", digest); err != nil {
		t.Fatal(err)
	}
	pending := decodeTestEnvelope(t, core.AcknowledgeCommand("pending-ack"))
	assertEnvelopeErrorCode(t, pending, "command_pending")
	if entry := core.commandLedger.entries["pending-ack"]; entry.State != commandStatePending {
		t.Fatalf("pending acknowledgement changed the entry: %+v", entry)
	}

	invalid := decodeTestEnvelope(t, core.AcknowledgeCommand(""))
	assertEnvelopeErrorCode(t, invalid, "invalid_request_id")
	unknown := decodeTestEnvelope(t, core.AcknowledgeCommand("pre-ledger-completed-command"))
	if !unknown.OK || unknown.Kind != commandAcknowledgementKind {
		t.Fatalf("unknown valid request ID was not an idempotent acknowledgement: %+v", unknown)
	}
	var payload commandAcknowledgementPayload
	if err := json.Unmarshal(unknown.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if !payload.Acknowledged || payload.Removed {
		t.Fatalf("unknown acknowledgement returned the wrong no-op payload: %+v", payload)
	}
}
