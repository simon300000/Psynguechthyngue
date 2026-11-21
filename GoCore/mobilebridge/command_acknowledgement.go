// SPDX-License-Identifier: MIT

package mobilebridge

const commandAcknowledgementKind = "commandAcknowledgement"

type commandAcknowledgementPayload struct {
	Acknowledged bool `json:"acknowledged"`
	Removed      bool `json:"removed"`
}

// AcknowledgeCommand durably removes one completed command ledger entry after
// the caller has persisted the shared result and acknowledged its own command
// queue record. Pending request IDs are never deleted; a valid unknown ID is
// an idempotent success so startup cleanup can acknowledge pre-ledger history.
// The single String result keeps NSError off the gomobile boundary.
func (c *Core) AcknowledgeCommand(requestID string) (response string) {
	publicRequestID := requestID
	if len(publicRequestID) > maxRequestIDSize {
		publicRequestID = ""
	}
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(publicRequestID, commandAcknowledgementKind, "internal_error", "the embedded core could not acknowledge the command")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(publicRequestID, commandAcknowledgementKind, "core_unavailable", "the embedded core is unavailable")
	}
	if validationErr := validateRequest(envelopeSchemaVersion, requestID); validationErr != nil {
		return stableFailureEnvelope(publicRequestID, commandAcknowledgementKind, validationErr.Code, validationErr.Message)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(requestID, commandAcknowledgementKind, "core_closed", "the embedded core is closed")
	}
	if c.commandLedger == nil {
		return stableFailureEnvelope(requestID, commandAcknowledgementKind, "internal_error", "the embedded core could not acknowledge the command")
	}
	found, pending, err := c.commandLedger.acknowledgeCompleted(requestID)
	if err != nil {
		return stableFailureEnvelope(requestID, commandAcknowledgementKind, "internal_error", "the embedded core could not durably acknowledge the command")
	}
	if !found {
		return stableSuccessEnvelope(requestID, commandAcknowledgementKind, commandAcknowledgementPayload{Acknowledged: true, Removed: false})
	}
	if pending {
		return stableFailureEnvelope(requestID, commandAcknowledgementKind, "command_pending", "pending commands cannot be acknowledged")
	}
	return stableSuccessEnvelope(requestID, commandAcknowledgementKind, commandAcknowledgementPayload{Acknowledged: true, Removed: true})
}
