// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const (
	commandLedgerSchemaVersion = 1
	maxCommandLedgerEntries    = 4096
	maxCommandLedgerSize       = 16 << 20

	commandStatePending   = "pending"
	commandStateCompleted = "completed"
)

var (
	errCommandRequestDigestConflict            = errors.New("command request digest conflict")
	errConfigurationReconciliationNeedsRestart = errors.New("configuration reconciliation requires a restarted core")
)

type commandLedgerEntry struct {
	RequestID string `json:"requestID"`
	Digest    string `json:"digest"`
	State     string `json:"state"`
	Response  string `json:"response,omitempty"`
}

type commandLedgerDocument struct {
	SchemaVersion int                  `json:"schemaVersion"`
	Entries       []commandLedgerEntry `json:"entries"`
}

type commandLedger struct {
	path           string
	entries        map[string]commandLedgerEntry
	startupPending map[string]string
	writeFile      func(string, []byte) error
}

func loadCommandLedger(home string) (*commandLedger, error) {
	ledger := &commandLedger{
		path:           filepath.Join(home, "Bridge", "command-ledger-v1.json"),
		entries:        make(map[string]commandLedgerEntry),
		startupPending: make(map[string]string),
		writeFile:      writeCommandLedgerFile,
	}
	directory := filepath.Dir(ledger.path)
	if info, err := os.Lstat(directory); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("command ledger directory is not a real directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect command ledger directory: %w", err)
	}

	info, err := os.Lstat(ledger.path)
	if errors.Is(err, os.ErrNotExist) {
		return ledger, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect command ledger: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("command ledger is not a regular non-symlink file")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, errors.New("command ledger permissions must be 0600")
	}
	if info.Size() > maxCommandLedgerSize {
		return nil, errors.New("command ledger exceeds the supported size")
	}

	handle, err := openCommandLedgerNoFollow(ledger.path)
	if err != nil {
		return nil, fmt.Errorf("open command ledger: %w", err)
	}
	defer handle.Close()
	openedInfo, err := handle.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect open command ledger: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || openedInfo.Mode().Perm() != 0o600 || !os.SameFile(info, openedInfo) {
		return nil, errors.New("command ledger changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(handle, maxCommandLedgerSize+1))
	if err != nil {
		return nil, fmt.Errorf("read command ledger: %w", err)
	}
	if len(data) > maxCommandLedgerSize {
		return nil, errors.New("command ledger exceeds the supported size")
	}

	var document commandLedgerDocument
	if err := decodeCommandLedger(data, &document); err != nil {
		return nil, err
	}
	if document.SchemaVersion != commandLedgerSchemaVersion {
		return nil, fmt.Errorf("unsupported command ledger schema %d", document.SchemaVersion)
	}
	if len(document.Entries) > maxCommandLedgerEntries {
		return nil, errors.New("command ledger entry limit exceeded")
	}
	for _, entry := range document.Entries {
		if err := validateCommandLedgerEntry(entry); err != nil {
			return nil, err
		}
		if _, duplicate := ledger.entries[entry.RequestID]; duplicate {
			return nil, errors.New("command ledger contains a duplicate request ID")
		}
		ledger.entries[entry.RequestID] = entry
		if entry.State == commandStatePending {
			ledger.startupPending[entry.RequestID] = entry.Digest
		}
	}
	return ledger, nil
}

func decodeCommandLedger(data []byte, document *commandLedgerDocument) error {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(document); err != nil {
		return fmt.Errorf("decode command ledger: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("command ledger must contain exactly one JSON object")
	}
	return nil
}

func validateCommandLedgerEntry(entry commandLedgerEntry) error {
	if validationErr := validateRequest(envelopeSchemaVersion, entry.RequestID); validationErr != nil {
		return errors.New("command ledger contains an invalid request ID")
	}
	digest, err := hex.DecodeString(entry.Digest)
	if err != nil || len(digest) != sha256.Size || hex.EncodeToString(digest) != entry.Digest {
		return errors.New("command ledger contains an invalid command digest")
	}
	switch entry.State {
	case commandStatePending:
		if entry.Response != "" {
			return errors.New("pending command ledger entry contains a response")
		}
	case commandStateCompleted:
		if err := validatePersistedCommandResponse(entry.RequestID, entry.Response); err != nil {
			return err
		}
	default:
		return errors.New("command ledger contains an invalid state")
	}
	return nil
}

func validatePersistedCommandResponse(requestID, response string) error {
	if response == "" || len(response) > maxJSONRequestSize {
		return errors.New("completed command ledger entry contains an invalid response")
	}
	var envelope responseEnvelope
	if err := decodeRequest(response, &envelope); err != nil {
		return errors.New("completed command ledger entry contains an invalid response")
	}
	if envelope.SchemaVersion != envelopeSchemaVersion || envelope.RequestID != requestID || envelope.Kind != "command" {
		return errors.New("completed command ledger response identity does not match its entry")
	}
	if envelope.OK {
		if envelope.Error != nil || envelope.Payload == nil {
			return errors.New("completed command ledger success response is malformed")
		}
	} else if envelope.Error == nil || envelope.Payload != nil || envelope.Error.Code == "" || envelope.Error.Message == "" {
		return errors.New("completed command ledger failure response is malformed")
	}
	return nil
}

// existingCommandDecision resolves an already accepted request ID. Commands
// in the narrow replay-safe set may durably transition a pending record or a
// completed failure back to pending before another attempt. All other pending
// records fail closed, and all other completed records replay exactly.
func (l *commandLedger) existingCommandDecision(requestID string, digest [sha256.Size]byte, command string, replayableAfterFailure bool) (response string, execute, found bool, err error) {
	entry, ok := l.entries[requestID]
	if !ok {
		return "", false, false, nil
	}
	if entry.Digest != hex.EncodeToString(digest[:]) {
		return stableCommandFailureEnvelope(
			requestID,
			command,
			"request_id_conflict",
			"requestID was already used for a different command",
			mutationPhasePrecommit,
			false,
		), false, true, nil
	}
	if entry.State == commandStateCompleted {
		succeeded, responseErr := persistedCommandResponseSucceeded(entry.Response)
		if responseErr != nil {
			return "", false, true, responseErr
		}
		if succeeded || !replayableAfterFailure {
			return entry.Response, false, true, nil
		}
	} else if !replayableAfterFailure {
		return stableCommandFailureEnvelope(
			requestID,
			command,
			"indeterminate_prior_attempt",
			"the prior attempt may have changed state; refresh before issuing a new requestID",
			mutationPhaseIndeterminate,
			true,
		), false, true, nil
	}
	if err := l.recordRetryPending(entry); err != nil {
		return "", false, true, err
	}
	return "", true, true, nil
}

// terminalCompletedCommandDecision permits exact completed responses to replay
// before a mutable resource precondition is re-evaluated. A successful command
// necessarily changed its pre-state revision, so checking that revision first
// would incorrectly turn an idempotent retry into a stale mutation attempt.
// Replayable failures are deliberately nonterminal and must pass the current
// precondition before existingCommandDecision can record a retry transition.
func (l *commandLedger) terminalCompletedCommandDecision(requestID string, digest [sha256.Size]byte, command string, replayableAfterFailure bool) (response string, terminal bool, err error) {
	entry, ok := l.entries[requestID]
	if !ok || entry.State != commandStateCompleted {
		return "", false, nil
	}
	if entry.Digest != hex.EncodeToString(digest[:]) {
		return stableCommandFailureEnvelope(
			requestID,
			command,
			"request_id_conflict",
			"requestID was already used for a different command",
			mutationPhasePrecommit,
			false,
		), true, nil
	}
	succeeded, err := persistedCommandResponseSucceeded(entry.Response)
	if err != nil {
		return "", true, err
	}
	if succeeded || !replayableAfterFailure {
		return entry.Response, true, nil
	}
	return "", false, nil
}

func persistedCommandResponseSucceeded(response string) (bool, error) {
	var envelope responseEnvelope
	if err := decodeRequest(response, &envelope); err != nil {
		return false, errors.New("completed command ledger entry contains an invalid response")
	}
	return envelope.OK, nil
}

func commandCanReplayAfterFailure(command string) bool {
	switch command {
	case "ping", "start", "stop", "rescan", "sync", "evict", "materialize", "pin",
		"disposeRecovery", "disposeRecoveryReviewed", "exportRecovery", "discardRecoveryExport",
		"ignorePendingDevice", "unignorePendingDevice",
		"ignorePendingFolder", "unignorePendingFolder":
		return true
	default:
		return false
	}
}

func commandRequestCanReplayAfterFailure(request commandRequest) bool {
	if commandCanReplayAfterFailure(request.Command) {
		return true
	}
	return request.Command == "acceptFolder" && request.Arguments["observationProofID"] != ""
}

func (l *commandLedger) recordRetryPending(original commandLedgerEntry) (err error) {
	pending := original
	pending.State = commandStatePending
	pending.Response = ""
	l.entries[original.RequestID] = pending
	committed := false
	defer func() {
		if !committed {
			l.entries[original.RequestID] = original
		}
	}()
	if err := l.save(); err != nil {
		return err
	}
	committed = true
	return nil
}

func (l *commandLedger) recordPending(requestID string, digest [sha256.Size]byte) error {
	if len(l.entries) >= maxCommandLedgerEntries {
		return errors.New("command ledger is full")
	}
	entry := commandLedgerEntry{
		RequestID: requestID,
		Digest:    hex.EncodeToString(digest[:]),
		State:     commandStatePending,
	}
	l.entries[requestID] = entry
	accepted := false
	defer func() {
		if !accepted {
			delete(l.entries, requestID)
		}
	}()
	if err := l.save(); err != nil {
		return err
	}
	accepted = true
	return nil
}

func (l *commandLedger) recordCompleted(requestID, response string) error {
	pending, ok := l.entries[requestID]
	if !ok || pending.State != commandStatePending {
		return errors.New("command ledger entry is not pending")
	}
	completed := pending
	completed.State = commandStateCompleted
	completed.Response = response
	l.entries[requestID] = completed
	committed := false
	defer func() {
		if !committed {
			l.entries[requestID] = pending
		}
	}()
	if err := l.save(); err != nil {
		return err
	}
	committed = true
	return nil
}

func (l *commandLedger) acknowledgeCompleted(requestID string) (found, pending bool, err error) {
	entry, ok := l.entries[requestID]
	if !ok {
		return false, false, nil
	}
	if entry.State != commandStateCompleted {
		return true, true, nil
	}
	startupDigest, wasStartupPending := l.startupPending[requestID]
	delete(l.entries, requestID)
	delete(l.startupPending, requestID)
	committed := false
	defer func() {
		if !committed {
			l.entries[requestID] = entry
			if wasStartupPending {
				l.startupPending[requestID] = startupDigest
			}
		}
	}()
	if err := l.save(); err != nil {
		return true, false, err
	}
	committed = true
	return true, false, nil
}

// acknowledgeReconciledMutation is deliberately narrower than ordinary
// acknowledgement: it requires the original canonical request digest and is
// reachable only through the authoritative mutation-proof endpoint. It can
// therefore clean both the P1 pending case and an exactly recorded postcommit
// failure after Swift has proved that the requested state now holds.
func (l *commandLedger) acknowledgeReconciledMutation(requestID string, digest [sha256.Size]byte) (found bool, err error) {
	entry, ok := l.entries[requestID]
	if !ok {
		return false, nil
	}
	if entry.Digest != hex.EncodeToString(digest[:]) {
		return true, errCommandRequestDigestConflict
	}
	startupDigest, wasStartupPending := l.startupPending[requestID]
	delete(l.entries, requestID)
	delete(l.startupPending, requestID)
	committed := false
	defer func() {
		if !committed {
			l.entries[requestID] = entry
			if wasStartupPending {
				l.startupPending[requestID] = startupDigest
			}
		}
	}()
	if err := l.save(); err != nil {
		return true, err
	}
	committed = true
	return true, nil
}

// acknowledgeReconciledConfiguration is restricted to a pending entry loaded
// from durable storage when this Core was constructed. A configuration Save
// failure can leave the current in-memory wrapper looking like the requested
// state even though the disk state was never committed; requiring NewCore
// prevents that same-process state from being used as reconciliation proof.
func (l *commandLedger) acknowledgeReconciledConfiguration(requestID string, digest [sha256.Size]byte) (found bool, err error) {
	entry, ok := l.entries[requestID]
	if !ok {
		return false, nil
	}
	digestText := hex.EncodeToString(digest[:])
	if entry.Digest != digestText {
		return true, errCommandRequestDigestConflict
	}
	startupDigest, loadedPending := l.startupPending[requestID]
	if entry.State != commandStatePending || !loadedPending || startupDigest != digestText {
		return true, errConfigurationReconciliationNeedsRestart
	}
	delete(l.entries, requestID)
	delete(l.startupPending, requestID)
	committed := false
	defer func() {
		if !committed {
			l.entries[requestID] = entry
			l.startupPending[requestID] = startupDigest
		}
	}()
	if err := l.save(); err != nil {
		return true, err
	}
	committed = true
	return true, nil
}

func (l *commandLedger) save() error {
	entries := make([]commandLedgerEntry, 0, len(l.entries))
	for _, entry := range l.entries {
		entries = append(entries, entry)
	}
	slices.SortFunc(entries, func(left, right commandLedgerEntry) int {
		return strings.Compare(left.RequestID, right.RequestID)
	})
	document := commandLedgerDocument{
		SchemaVersion: commandLedgerSchemaVersion,
		Entries:       entries,
	}
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode command ledger: %w", err)
	}
	if len(data) > maxCommandLedgerSize {
		return errors.New("command ledger exceeds the supported size")
	}
	if err := l.writeFile(l.path, data); err != nil {
		return err
	}
	return nil
}

func writeCommandLedgerFile(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create command ledger directory: %w", err)
	}
	directoryInfo, err := os.Lstat(directory)
	if err != nil || !directoryInfo.IsDir() || directoryInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("command ledger directory is not a real directory")
	}
	temporary, err := os.CreateTemp(directory, ".command-ledger-*")
	if err != nil {
		return fmt.Errorf("create command ledger temporary file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("protect command ledger: %w", err)
	}
	if err := writeAll(temporary, data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write command ledger: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync command ledger: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close command ledger: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace command ledger: %w", err)
	}
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("open command ledger directory: %w", err)
	}
	defer directoryHandle.Close()
	if err := directoryHandle.Sync(); err != nil {
		return fmt.Errorf("sync command ledger directory: %w", err)
	}
	return nil
}

func writeAll(destination io.Writer, data []byte) error {
	for len(data) != 0 {
		written, err := destination.Write(data)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}
