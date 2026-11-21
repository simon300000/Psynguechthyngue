// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
)

const (
	mutationPhasePrecommit     = "precommit"
	mutationPhasePostcommit    = "postcommit"
	mutationPhaseIndeterminate = "indeterminate"
)

func (c *Core) commandJSONLocked(request string) (string, error) {
	var parsed commandRequest
	if decodeErr := decodeRequest(request, &parsed); decodeErr != nil {
		return failureEnvelope(parsed.RequestID, "command", "invalid_request", decodeErr.Error())
	}
	if validationErr := validateRequest(parsed.SchemaVersion, parsed.RequestID); validationErr != nil {
		return failureEnvelope(parsed.RequestID, "command", validationErr.Code, validationErr.Message)
	}
	if parsed.Command == "" {
		return failureEnvelope(parsed.RequestID, "command", "invalid_request", "command must not be empty")
	}
	if sessionErr := c.preflightCommandSessionLocked(parsed); sessionErr != nil {
		return failureEnvelope(parsed.RequestID, "command", sessionErr.Code, sessionErr.Message)
	}
	if isSessionLifecycleCommand(parsed.Command) {
		var closingSession *sessionDescriptor
		if parsed.Command == "closeSession" && c.session != nil {
			closing := *c.session
			closingSession = &closing
		}
		operationErr := c.executeCommandLocked(parsed)
		if operationErr != nil {
			publicError := *operationErr
			publicError.Message = publicCommandErrorMessage(operationErr)
			return failureEnvelopeWithError(parsed.RequestID, "command", &publicError)
		}
		payload := c.successCommandPayload(parsed)
		if closingSession != nil {
			applySessionDescriptorToCommandPayload(&payload, *closingSession)
		}
		return successEnvelope(parsed.RequestID, "command", payload)
	}
	digest, err := commandDigest(parsed)
	if err != nil {
		return "", err
	}
	replayableAfterFailure := commandRequestCanReplayAfterFailure(parsed)
	terminalResponse, terminal, terminalErr := c.commandLedger.terminalCompletedCommandDecision(parsed.RequestID, digest, parsed.Command, replayableAfterFailure)
	if terminalErr != nil {
		return commandFailureEnvelope(parsed, "internal_error", "the embedded core could not durably replay the command", mutationPhasePrecommit, false)
	}
	if terminal {
		return terminalResponse, nil
	}
	if preconditionErr := c.preflightCommandConfigurationRevisionLocked(parsed); preconditionErr != nil {
		return failureEnvelope(parsed.RequestID, "command", preconditionErr.Code, preconditionErr.Message)
	}
	priorResponse, execute, found, decisionErr := c.commandLedger.existingCommandDecision(parsed.RequestID, digest, parsed.Command, replayableAfterFailure)
	if decisionErr != nil {
		return commandFailureEnvelope(parsed, "internal_error", "the embedded core could not durably retry the command", mutationPhasePrecommit, false)
	}
	if found && !execute {
		return priorResponse, nil
	}
	if !found {
		if len(c.commandLedger.entries) >= maxCommandLedgerEntries {
			return commandFailureEnvelope(parsed, "request_cache_full", "command ledger is full; no new requestIDs can be accepted", mutationPhasePrecommit, false)
		}
		// A durable pending entry is the commit point for accepting a command. It
		// must reach storage before any operation is attempted, otherwise a process
		// death after mutation but before the caller observes the result could cause
		// an unsafe replay under the same request ID.
		if err := c.commandLedger.recordPending(parsed.RequestID, digest); err != nil {
			return commandFailureEnvelope(parsed, "internal_error", "the embedded core could not durably accept the command", mutationPhasePrecommit, false)
		}
	}

	var operationErr *responseError
	if c.stopRequested.Load() {
		operationErr = cancelledCommandFailure(parsed.Command, nil)
	} else {
		operationErr = c.executeCommandLocked(parsed)
		if operationErr != nil && c.stopRequested.Load() {
			operationErr = cancelledCommandFailure(parsed.Command, operationErr)
		}
	}
	var response string
	if operationErr != nil {
		operationErr = classifiedMutationFailure(parsed.Command, operationErr)
		publicError := *operationErr
		publicError.Message = publicCommandErrorMessage(operationErr)
		response, err = failureEnvelopeWithError(parsed.RequestID, "command", &publicError)
	} else {
		response, err = successEnvelope(parsed.RequestID, "command", c.successCommandPayload(parsed))
	}
	if err != nil {
		return "", err
	}
	if err := c.commandLedger.recordCompleted(parsed.RequestID, response); err != nil {
		return commandFailureEnvelope(parsed, "internal_error", "the embedded core could not durably complete the command", mutationPhaseIndeterminate, true)
	}
	return response, nil
}

func (c *Core) preflightCommandConfigurationRevisionLocked(request commandRequest) *responseError {
	if c.session == nil || c.session.Mode != sessionModeConfiguration || !isConfigurationReconciliationRequest(request) {
		return nil
	}
	if request.CommandConfigurationRevision != c.configurationRevision {
		return commandError("configuration_revision_mismatch", "the canonical configuration changed after the command was planned")
	}
	diskRevision, err := configurationFileRevision(c.runtime.configuration.ConfigPath())
	if err != nil {
		return commandError("configuration_verify_failed", "the canonical configuration revision could not be reread")
	}
	if diskRevision != c.configurationRevision || diskRevision != request.CommandConfigurationRevision {
		return commandError("configuration_revision_mismatch", "the canonical configuration changed after the command was planned")
	}
	return nil
}

func (c *Core) successCommandPayload(request commandRequest) commandPayload {
	payload := commandPayload{
		Command:               request.Command,
		Lifecycle:             c.lifecycle,
		Generation:            c.generation,
		ConfigurationRevision: c.configurationRevision,
	}
	if isSessionLifecycleCommand(request.Command) {
		if c.session != nil {
			applySessionDescriptorToCommandPayload(&payload, *c.session)
		} else if request.Command == "openConfiguration" {
			payload.SessionID = request.SessionID
			payload.SessionMode = sessionModeConfiguration
		} else if request.Command == "openNetworkSession" {
			payload.SessionID = request.SessionID
			payload.FolderID = request.FolderID
			payload.TaskID = request.TaskID
			payload.PlanDigest = request.PlanDigest
			payload.ExpectedConfigurationRevision = request.ExpectedConfigurationRevision
			payload.MaximumNetworkBytes = request.MaximumNetworkBytes
			payload.NetworkOperation = request.NetworkOperation
			payload.SessionMode = sessionModeNetwork
		} else if request.Command == "openPendingFolderObservationSession" {
			payload.SessionID = request.SessionID
			payload.FolderID = request.FolderID
			payload.OfferingDeviceID = request.OfferingDeviceID
			payload.TaskID = request.TaskID
			payload.PlanDigest = request.PlanDigest
			payload.ExpectedConfigurationRevision = request.ExpectedConfigurationRevision
			payload.MaximumNetworkBytes = request.MaximumNetworkBytes
			payload.SessionMode = sessionModePendingFolderObservation
		} else if request.Command == "openPendingFolderDiscoverySession" {
			payload.SessionID = request.SessionID
			payload.OfferingDeviceID = request.OfferingDeviceID
			payload.TaskID = request.TaskID
			payload.PlanDigest = request.PlanDigest
			payload.ExpectedConfigurationRevision = request.ExpectedConfigurationRevision
			payload.MaximumNetworkBytes = request.MaximumNetworkBytes
			payload.SessionMode = sessionModePendingFolderDiscovery
		}
	}
	if request.Command == "capturePendingFolderObservation" && c.runtime != nil && c.runtime.capturedPendingFolderObservation != nil {
		proof := *c.runtime.capturedPendingFolderObservation
		payload.PendingFolderObservation = &proof
	}
	if request.Command == "capturePendingFolderDiscovery" && c.runtime != nil && c.runtime.capturedPendingFolderDiscovery != nil {
		batch := *c.runtime.capturedPendingFolderDiscovery
		batch.Offers = append([]pendingFolderDiscoverySummary(nil), batch.Offers...)
		payload.PendingFolderDiscovery = &batch
	}
	if request.Command != "disposeRecovery" && request.Command != "disposeRecoveryReviewed" &&
		request.Command != "exportRecovery" && request.Command != "discardRecoveryExport" {
		return payload
	}
	payload.RecoveryID = request.Arguments["recoveryID"]
	switch request.Command {
	case "exportRecovery":
		payload.Disposition = "exported"
	case "discardRecoveryExport":
		payload.Disposition = "discarded"
		payload.RecoveryID = request.Arguments["exportID"]
	default:
		payload.Disposition = "disposed"
	}
	receipt := sha256.Sum256([]byte(strings.Join([]string{
		"psy-recovery-disposition-v1",
		request.Command,
		request.Arguments["recoveryID"],
		request.Arguments["exportID"],
		request.Arguments["outputName"],
		request.Arguments["payloadKind"],
		request.Arguments["digest"],
		request.Arguments["byteCount"],
		request.Arguments["status"],
	}, "\x00")))
	payload.ReceiptHash = fmt.Sprintf("%x", receipt[:])
	return payload
}

func applySessionDescriptorToCommandPayload(payload *commandPayload, session sessionDescriptor) {
	payload.SessionID = session.SessionID
	payload.SessionMode = session.Mode
	payload.FolderID = session.FolderID
	payload.OfferingDeviceID = session.OfferingDeviceID
	payload.TaskID = session.TaskID
	payload.PlanDigest = session.PlanDigest
	payload.ExpectedConfigurationRevision = session.ExpectedConfigurationRevision
	payload.MaximumNetworkBytes = session.MaximumNetworkBytes
	payload.NetworkOperation = session.NetworkOperation
}

func isMutationCommand(command string) bool {
	switch command {
	case "create", "modify", "move", "delete":
		return true
	default:
		return false
	}
}

func commandFailureEnvelope(request commandRequest, code, message, phase string, ambiguous bool) (string, error) {
	if !isMutationCommand(request.Command) {
		return failureEnvelope(request.RequestID, "command", code, message)
	}
	return failureEnvelopeWithError(request.RequestID, "command", mutationFailure(code, message, phase, ambiguous))
}

func stableCommandFailureEnvelope(requestID, command, code, message, phase string, ambiguous bool) string {
	if !isMutationCommand(command) {
		return stableFailureEnvelope(requestID, "command", code, message)
	}
	response, err := failureEnvelopeWithError(requestID, "command", mutationFailure(code, message, phase, ambiguous))
	if err != nil {
		return fallbackEnvelope
	}
	return response
}

func mutationFailure(code, message, phase string, ambiguous bool) *responseError {
	value := ambiguous
	return &responseError{
		Code:              code,
		Message:           message,
		MutationPhase:     phase,
		MutationAmbiguous: &value,
	}
}

func classifiedMutationFailure(command string, operationErr *responseError) *responseError {
	if operationErr == nil || !isMutationCommand(command) {
		return operationErr
	}
	if operationErr.MutationPhase != "" && operationErr.MutationAmbiguous != nil {
		return operationErr
	}
	phase := mutationPhaseIndeterminate
	ambiguous := true
	switch operationErr.Code {
	case "core_not_running", "invalid_request", "invalid_folder_id", "invalid_folder_root",
		"folder_not_found", "folder_paused", "folder_not_writable", "invalid_item_id",
		"invalid_parent", "invalid_path", "path_escape", "protected_path", "symlink_rejected",
		"item_not_found", "item_type_changed", "destination_exists", "directory_not_empty",
		"delete_must_propagate", "invalid_base_version", "version_conflict",
		"path_identity_conflict", "staged_content_invalid":
		phase = mutationPhasePrecommit
		ambiguous = false
	case "propagation_not_indexed":
		phase = mutationPhasePostcommit
	}
	return mutationFailure(operationErr.Code, operationErr.Message, phase, ambiguous)
}

func cancelledCommandFailure(command string, operationErr *responseError) *responseError {
	if command == "sync" {
		return commandError("sync_cancelled", "bounded sync run was cancelled")
	}
	if !isMutationCommand(command) {
		return commandError("cancelled", "the command was cancelled")
	}
	phase := mutationPhasePrecommit
	ambiguous := false
	if operationErr != nil && operationErr.MutationPhase != "" && operationErr.MutationAmbiguous != nil {
		phase = operationErr.MutationPhase
		ambiguous = *operationErr.MutationAmbiguous
	}
	return mutationFailure("cancelled", "the file operation was cancelled", phase, ambiguous)
}

func commandDigest(request commandRequest) ([sha256.Size]byte, error) {
	// Session bindings are execution fences, not durable command semantics. A
	// queued command may be retried after process death in a newly planned
	// session; its requestID must continue to identify the same business
	// operation instead of conflicting solely because the ephemeral owner/task
	// changed. The active binding is validated before any ledger decision.
	request.SessionID = ""
	request.TaskID = ""
	request.PlanDigest = ""
	request.ExpectedConfigurationRevision = ""
	request.MaximumNetworkBytes = ""
	canonical, err := json.Marshal(request)
	if err != nil {
		return [sha256.Size]byte{}, fmt.Errorf("encode canonical command: %w", err)
	}
	return sha256.Sum256(canonical), nil
}

func isSessionLifecycleCommand(command string) bool {
	switch command {
	case "openConfiguration", "openNetworkSession", "openPendingFolderObservationSession", "capturePendingFolderObservation", "openPendingFolderDiscoverySession", "capturePendingFolderDiscovery", "closeSession":
		return true
	default:
		return false
	}
}

func (c *Core) executeCommandLocked(request commandRequest) *responseError {
	switch request.Command {
	case "ping":
		if err := requireNoTargetOrArguments(request); err != nil {
			return err
		}
		return nil
	case "start":
		if err := requireNoTargetOrArguments(request); err != nil {
			return err
		}
		if err := c.startLocked(); err != nil {
			return commandError("command_failed", err.Error())
		}
		return nil
	case "openConfiguration":
		return c.openSessionCommandLocked(request, sessionModeConfiguration)
	case "openNetworkSession":
		return c.openSessionCommandLocked(request, sessionModeNetwork)
	case "openPendingFolderObservationSession":
		return c.openSessionCommandLocked(request, sessionModePendingFolderObservation)
	case "capturePendingFolderObservation":
		return c.capturePendingFolderObservationLocked(request)
	case "openPendingFolderDiscoverySession":
		return c.openSessionCommandLocked(request, sessionModePendingFolderDiscovery)
	case "capturePendingFolderDiscovery":
		return c.capturePendingFolderDiscoveryLocked(request)
	case "closeSession":
		return c.closeSessionCommandLocked()
	case "stop":
		if err := requireNoTargetOrArguments(request); err != nil {
			return err
		}
		if err := c.stopLocked(); err != nil {
			return commandError("command_failed", err.Error())
		}
		return nil
	case "addDevice":
		return c.addDeviceLocked(request)
	case "acceptDevice":
		return c.acceptDeviceLocked(request)
	case "ignorePendingDevice":
		return c.ignorePendingDeviceLocked(request)
	case "unignorePendingDevice":
		return c.unignorePendingDeviceLocked(request)
	case "editDevice":
		return c.editDeviceLocked(request)
	case "removeDevice":
		return c.removeDeviceLocked(request)
	case "addFolder":
		return c.addFolderLocked(request)
	case "acceptFolder":
		return c.acceptFolderLocked(request)
	case "ignorePendingFolder":
		return c.ignorePendingFolderLocked(request)
	case "unignorePendingFolder":
		return c.unignorePendingFolderLocked(request)
	case "editFolder":
		return c.editFolderLocked(request)
	case "removeFolder":
		return c.removeFolderLocked(request)
	case "pause":
		return c.setPausedLocked(request, true)
	case "resume":
		return c.setPausedLocked(request, false)
	case "rescan":
		return c.rescanLocked(request)
	case "create":
		return c.createItemLocked(request)
	case "modify":
		return c.modifyItemLocked(request)
	case "move":
		return c.moveItemLocked(request)
	case "delete":
		return c.deleteItemLocked(request)
	case "evict":
		return c.evictLocalContentLocked(request)
	case "materialize":
		return c.materializeLocalContentLocked(request, true)
	case "pin":
		return c.materializeLocalContentLocked(request, false)
	case "disposeRecovery":
		return c.disposeRecoveryLocked(request, false)
	case "disposeRecoveryReviewed":
		return c.disposeRecoveryLocked(request, true)
	case "exportRecovery":
		return c.exportRecoveryLocked(request)
	case "discardRecoveryExport":
		return c.discardRecoveryExportLocked(request)
	case "sync":
		return c.syncLocked(request)
	case "upload", "download", "exchangeIndex":
		return c.syncLocked(request)
	default:
		return commandError("unsupported_command", "command is not supported by this bridge version")
	}
}

func requireNoTargetOrArguments(request commandRequest) *responseError {
	if request.FolderID != "" || request.ItemID != "" || len(request.Arguments) != 0 {
		return commandError("invalid_request", "command does not accept folderID, itemID, or arguments")
	}
	return nil
}

func requireArgumentKeys(arguments map[string]string, allowed ...string) *responseError {
	allowedSet := make(map[string]struct{}, len(allowed))
	for _, key := range allowed {
		allowedSet[key] = struct{}{}
	}
	for key := range arguments {
		if _, ok := allowedSet[key]; !ok {
			return commandError("invalid_request", "command contains an unsupported argument")
		}
	}
	return nil
}

func requiredCommandArgument(arguments map[string]string, key string) (string, bool) {
	value, ok := arguments[key]
	if !ok || value == "" || value != strings.TrimSpace(value) {
		return "", false
	}
	return value, true
}

func commandError(code, message string) *responseError {
	return &responseError{Code: code, Message: message}
}

// publicCommandErrorMessage prevents filesystem and configuration errors from
// copying application-owned paths into the exact response retained by the
// durable command ledger. Other bridge validation errors are already fixed
// vocabulary and remain specific enough for callers to act on their code.
func publicCommandErrorMessage(operationErr *responseError) string {
	switch operationErr.Code {
	case "cancelled":
		return "the command was cancelled"
	case "command_failed":
		return "the lifecycle command could not be completed"
	case "rescan_failed":
		return "the folder rescan could not be completed"
	case "invalid_path":
		return "the requested path is invalid or unavailable"
	case "invalid_parent":
		return "the destination parent is invalid or unavailable"
	case "create_failed", "modify_failed", "move_failed", "delete_failed", "mutation_inconsistent":
		return "the requested file operation could not be completed"
	case "item_identity_conflict", "identity_registry_save_failed":
		return "the item identity update could not be completed"
	case "index_read_failed":
		return "the item index could not be read"
	case "local_content_state_failed", "evict_failed":
		return "the local content could not be released safely"
	case "configuration_rejected", "configuration_save_failed":
		return "the configuration update could not be completed"
	case "configuration_verify_failed":
		return "the saved configuration could not be verified"
	case "session_start_failed", "session_close_failed":
		return "the requested bridge session transition could not be completed"
	case "configuration_revision_mismatch":
		return "the canonical configuration changed after the session was planned"
	case "configuration_not_initialized", "configuration_version_mismatch":
		return "the canonical configuration requires a configuration session before networking"
	case "network_observation_required":
		return "the command requires a current network observation"
	case "plan_digest_mismatch":
		return "the network session plan does not match the canonical configuration"
	case "network_byte_limit_reached":
		return "the aggregate protocol byte limit was reached"
	default:
		return operationErr.Message
	}
}
