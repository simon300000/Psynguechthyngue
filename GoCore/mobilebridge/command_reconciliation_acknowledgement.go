// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
)

const (
	reconciledCommandAcknowledgementKind = "reconciledCommandAcknowledgement"
	reconciliationProofKind              = "authoritative_snapshot_requested_state"
	configurationReconciliationProofKind = "authoritative_snapshot_configuration_state"
)

type reconciliationProof struct {
	Kind               string `json:"kind"`
	SnapshotGeneration uint64 `json:"snapshotGeneration"`
	OwnerEpoch         uint64 `json:"ownerEpoch"`
	StateDigest        string `json:"stateDigest"`
}

type reconciledCommandAcknowledgementRequest struct {
	SchemaVersion int                 `json:"schemaVersion"`
	RequestID     string              `json:"requestID"`
	Command       commandRequest      `json:"command"`
	Proof         reconciliationProof `json:"proof"`
}

type reconciledCommandAcknowledgementPayload struct {
	Acknowledged bool   `json:"acknowledged"`
	Removed      bool   `json:"removed"`
	ProofReceipt string `json:"proofReceipt"`
}

// AcknowledgeReconciledCommandJSON durably removes a pending or completed file
// mutation only after the Swift owner has persisted an authoritative
// requested-state proof. The full original command is canonicalized again and
// must match the ledger's pre-execution digest; an ID alone can never clear a
// pending entry. The proof receipt binds that digest to the snapshot/owner
// fence and the state evidence digest used by Swift.
func (c *Core) AcknowledgeReconciledCommandJSON(request string) (response string) {
	requestID := envelopeRequestID(request)
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(requestID, reconciledCommandAcknowledgementKind, "internal_error", "the embedded core could not acknowledge the reconciled command")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(requestID, reconciledCommandAcknowledgementKind, "core_unavailable", "the embedded core is unavailable")
	}

	var parsed reconciledCommandAcknowledgementRequest
	if err := decodeRequest(request, &parsed); err != nil {
		return stableFailureEnvelope(requestID, reconciledCommandAcknowledgementKind, "invalid_request", err.Error())
	}
	if validationErr := validateRequest(parsed.SchemaVersion, parsed.RequestID); validationErr != nil {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, validationErr.Code, validationErr.Message)
	}
	if validationErr := validateRequest(parsed.Command.SchemaVersion, parsed.Command.RequestID); validationErr != nil {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "invalid_original_command", "the original command identity is invalid")
	}
	if parsed.Command.RequestID != parsed.RequestID {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "invalid_original_command", "the original command requestID does not match the acknowledgement")
	}
	isMutation := isMutationCommand(parsed.Command.Command)
	isConfiguration := isConfigurationReconciliationRequest(parsed.Command)
	if !isMutation && !isConfiguration {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "reconciliation_not_allowed", "the command may not use authoritative reconciliation acknowledgement")
	}
	expectedProofKind := reconciliationProofKind
	if isConfiguration {
		expectedProofKind = configurationReconciliationProofKind
	}
	stateDigest, proofOK := validateReconciliationProof(parsed.Proof, expectedProofKind)
	if !proofOK {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "invalid_reconciliation_proof", "the authoritative reconciliation proof is invalid")
	}
	digest, err := commandDigest(parsed.Command)
	if err != nil {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "invalid_original_command", "the original command could not be canonicalized")
	}
	proofReceipt := reconciliationProofReceipt(digest, parsed.Proof, stateDigest)

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "core_closed", "the embedded core is closed")
	}
	if c.commandLedger == nil {
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "internal_error", "the embedded core could not acknowledge the reconciled command")
	}
	var found bool
	var acknowledgementErr error
	if isMutation {
		found, acknowledgementErr = c.commandLedger.acknowledgeReconciledMutation(parsed.RequestID, digest)
	} else {
		found, acknowledgementErr = c.commandLedger.acknowledgeReconciledConfiguration(parsed.RequestID, digest)
	}
	if acknowledgementErr != nil {
		if errors.Is(acknowledgementErr, errCommandRequestDigestConflict) {
			return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "request_digest_conflict", "the supplied original command does not match the pending ledger entry")
		}
		if errors.Is(acknowledgementErr, errConfigurationReconciliationNeedsRestart) {
			return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "reconciliation_restart_required", "configuration reconciliation requires a pending entry loaded by a restarted core")
		}
		return stableFailureEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, "internal_error", "the embedded core could not durably acknowledge the reconciled command")
	}
	return stableSuccessEnvelope(parsed.RequestID, reconciledCommandAcknowledgementKind, reconciledCommandAcknowledgementPayload{
		Acknowledged: true,
		Removed:      found,
		ProofReceipt: proofReceipt,
	})
}

func validateReconciliationProof(proof reconciliationProof, expectedKind string) ([sha256.Size]byte, bool) {
	if proof.Kind != expectedKind || proof.SnapshotGeneration == 0 || proof.OwnerEpoch == 0 {
		return [sha256.Size]byte{}, false
	}
	decoded, err := hex.DecodeString(proof.StateDigest)
	if err != nil || len(decoded) != sha256.Size || hex.EncodeToString(decoded) != proof.StateDigest {
		return [sha256.Size]byte{}, false
	}
	var result [sha256.Size]byte
	copy(result[:], decoded)
	return result, true
}

func reconciliationProofReceipt(commandDigest [sha256.Size]byte, proof reconciliationProof, stateDigest [sha256.Size]byte) string {
	digest := sha256.New()
	digest.Write([]byte("psy-reconciled-command-proof-v1"))
	digest.Write([]byte{0})
	digest.Write(commandDigest[:])
	digest.Write([]byte{0})
	digest.Write([]byte(proof.Kind))
	digest.Write(stateDigest[:])
	var number [8]byte
	binary.BigEndian.PutUint64(number[:], proof.SnapshotGeneration)
	digest.Write(number[:])
	binary.BigEndian.PutUint64(number[:], proof.OwnerEpoch)
	digest.Write(number[:])
	return hex.EncodeToString(digest.Sum(nil))
}

func isConfigurationReconciliationCommand(command string) bool {
	switch command {
	case "addDevice", "editDevice", "removeDevice", "acceptDevice",
		"addFolder", "editFolder", "removeFolder", "acceptFolder",
		"pause", "resume":
		return true
	default:
		return false
	}
}

func isConfigurationReconciliationRequest(request commandRequest) bool {
	if isConfigurationReconciliationCommand(request.Command) {
		return true
	}
	return request.Command == "ignorePendingFolder" && request.Arguments["observationProofID"] != ""
}
