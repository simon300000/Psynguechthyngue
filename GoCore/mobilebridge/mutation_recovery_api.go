// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	mutationRecoveryCursorSchemaVersion = 1
	mutationRecoveryDisposalName        = "disposal-approved.json"
	mutationRecoveryDisposingName       = "disposing"

	mutationRecoveryStatusDisposalApproved = "disposalApprovedPendingCleanup"
)

var errMutationRecoveryNoDurableRecord = errors.New("mutation recovery directory has no durable record")

type mutationRecoverySummary struct {
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

type mutationRecoveryQueryPayload struct {
	Query      string                    `json:"query"`
	Recoveries []mutationRecoverySummary `json:"recoveries"`
	NextCursor string                    `json:"nextCursor,omitempty"`
	HasMore    bool                      `json:"hasMore"`
}

type mutationRecoveryCursor struct {
	SchemaVersion int    `json:"v"`
	AfterID       string `json:"afterID"`
}

type mutationRecoveryRecordSet struct {
	prepared *mutationRecoveryRecord
	retained *mutationRecoveryRecord
	conflict *mutationRecoveryRecord
	disposal *mutationRecoveryRecord
}

func (c *Core) queryRecoveriesLocked(request queryRequest) (mutationRecoveryQueryPayload, *responseError) {
	empty := mutationRecoveryQueryPayload{Query: "recoveries", Recoveries: []mutationRecoverySummary{}}
	for _, field := range []string{"folderID", "scope", "parent", "search", "includeDeleted", "timeoutMS"} {
		if request.hasField(field) {
			return empty, commandError("invalid_query", "recoveries query accepts only cursor and limit")
		}
	}
	limit := request.Limit
	if limit == 0 {
		limit = defaultQueryLimit
	}
	if limit < 1 || limit > maxQueryLimit {
		return empty, commandError("invalid_query", "limit must be between 1 and 200")
	}
	afterID := ""
	if request.Cursor != "" {
		cursor, err := decodeMutationRecoveryCursor(request.Cursor)
		if err != nil {
			return empty, commandError("invalid_cursor", "recovery cursor is invalid")
		}
		afterID = cursor.AfterID
	}
	records, err := listMutationRecoveryRecords(c.home)
	if err != nil {
		return empty, commandError("recovery_store_corrupt", "recovery records could not be read safely")
	}
	start := sort.Search(len(records), func(index int) bool {
		return records[index].RequestIDHash > afterID
	})
	end := start + limit
	hasMore := end < len(records)
	if end > len(records) {
		end = len(records)
	}
	page := records[start:end]
	result := mutationRecoveryQueryPayload{
		Query:      "recoveries",
		Recoveries: make([]mutationRecoverySummary, 0, len(page)),
		HasMore:    hasMore,
	}
	for _, record := range page {
		result.Recoveries = append(result.Recoveries, recoverySummary(record))
	}
	if hasMore && len(page) != 0 {
		cursor, err := encodeMutationRecoveryCursor(mutationRecoveryCursor{
			SchemaVersion: mutationRecoveryCursorSchemaVersion,
			AfterID:       page[len(page)-1].RequestIDHash,
		})
		if err != nil {
			return empty, commandError("query_failed", "recovery cursor could not be encoded")
		}
		result.NextCursor = cursor
	}
	return result, nil
}

func recoverySummary(record mutationRecoveryRecord) mutationRecoverySummary {
	return mutationRecoverySummary{
		RecoveryID:   record.RequestIDHash,
		FolderID:     record.FolderID,
		CommandKind:  record.CommandKind,
		RelativePath: record.RelativePath,
		PayloadKind:  record.PayloadKind,
		Digest:       record.ContentDigest,
		Bytes:        record.ByteCount,
		CreatedAt:    record.CreatedAt,
		Status:       record.Status,
	}
}

func encodeMutationRecoveryCursor(cursor mutationRecoveryCursor) (string, error) {
	data, err := json.Marshal(cursor)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeMutationRecoveryCursor(encoded string) (mutationRecoveryCursor, error) {
	data, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil || len(data) > 256 {
		return mutationRecoveryCursor{}, errors.New("invalid recovery cursor")
	}
	var cursor mutationRecoveryCursor
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cursor); err != nil {
		return mutationRecoveryCursor{}, err
	}
	if cursor.SchemaVersion != mutationRecoveryCursorSchemaVersion || !validMutationRecoveryID(cursor.AfterID) {
		return mutationRecoveryCursor{}, errors.New("invalid recovery cursor")
	}
	return cursor, nil
}

func listMutationRecoveryRecords(home string) ([]mutationRecoveryRecord, error) {
	recovery, err := openMutationRecoveryStore(home)
	if errors.Is(err, os.ErrNotExist) {
		return []mutationRecoveryRecord{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer recovery.Close()
	entries, err := recovery.ReadDir(-1)
	if err != nil {
		return nil, err
	}
	records := make([]mutationRecoveryRecord, 0, len(entries))
	for _, entry := range entries {
		if !validMutationRecoveryID(entry.Name()) {
			return nil, errors.New("mutation recovery directory contains an invalid record name")
		}
		directory, err := openMutationDirectoryAt(recovery, entry.Name())
		if err != nil {
			return nil, errors.New("mutation recovery record is not a no-follow directory")
		}
		empty, emptyErr := mutationRecoveryDirectoryEmpty(directory)
		if emptyErr != nil {
			_ = directory.Close()
			return nil, emptyErr
		}
		if empty {
			_ = directory.Close()
			continue
		}
		set, readErr := readMutationRecoveryRecordSet(directory, entry.Name())
		if errors.Is(readErr, errMutationRecoveryNoDurableRecord) {
			empty, emptyErr := mutationRecoveryDirectoryEmpty(directory)
			_ = directory.Close()
			if emptyErr != nil {
				return nil, emptyErr
			}
			if empty {
				continue
			}
		} else {
			_ = directory.Close()
		}
		if readErr != nil {
			return nil, readErr
		}
		record, err := set.visible()
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}
	sort.Slice(records, func(left, right int) bool {
		return records[left].RequestIDHash < records[right].RequestIDHash
	})
	return records, nil
}

func openMutationRecoveryStore(home string) (*os.File, error) {
	root, err := openVerifiedMutationRecoveryRoot(home)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	bridge, err := openMutationDirectoryAt(root, "Bridge")
	if err != nil {
		return nil, err
	}
	defer bridge.Close()
	return openMutationDirectoryAt(bridge, "MutationRecovery")
}

func readMutationRecoveryRecordSet(directory *os.File, recoveryID string) (mutationRecoveryRecordSet, error) {
	if !validMutationRecoveryID(recoveryID) {
		return mutationRecoveryRecordSet{}, errors.New("mutation recovery identifier is invalid")
	}
	if _, err := directory.Seek(0, 0); err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	allowed := map[string]struct{}{
		mutationRecoveryPreparedName:  {},
		mutationRecoveryRetainedName:  {},
		mutationRecoveryConflictName:  {},
		mutationRecoveryDisposalName:  {},
		mutationRecoveryPayloadName:   {},
		mutationRecoveryDisposingName: {},
	}
	for _, entry := range entries {
		if _, ok := allowed[entry.Name()]; !ok {
			return mutationRecoveryRecordSet{}, errors.New("mutation recovery record directory contains an unexpected entry")
		}
	}
	read := func(name, status string) (*mutationRecoveryRecord, error) {
		record, err := readMutationRecoveryRecord(directory, name)
		if err != nil || record == nil {
			return record, err
		}
		if record.RequestIDHash != recoveryID || record.Status != status {
			return nil, errors.New("mutation recovery record identity or status is invalid")
		}
		return record, nil
	}
	set := mutationRecoveryRecordSet{}
	if set.prepared, err = read(mutationRecoveryPreparedName, mutationRecoveryStatusPrepared); err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	if set.retained, err = read(mutationRecoveryRetainedName, mutationRecoveryStatusRetained); err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	if set.conflict, err = read(mutationRecoveryConflictName, mutationRecoveryStatusConflict); err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	if set.disposal, err = read(mutationRecoveryDisposalName, mutationRecoveryStatusDisposalApproved); err != nil {
		return mutationRecoveryRecordSet{}, err
	}
	for _, candidate := range []*mutationRecoveryRecord{set.retained, set.conflict, set.disposal} {
		if candidate != nil && set.prepared != nil && !sameMutationRecoveryOperationInvariant(*candidate, *set.prepared) {
			return mutationRecoveryRecordSet{}, errors.New("mutation recovery record invariant changed")
		}
	}
	return set, nil
}

func (set mutationRecoveryRecordSet) visible() (mutationRecoveryRecord, error) {
	switch {
	case set.conflict != nil:
		return *set.conflict, nil
	case set.disposal != nil:
		return *set.disposal, nil
	case set.retained != nil:
		return *set.retained, nil
	case set.prepared != nil:
		return *set.prepared, nil
	default:
		return mutationRecoveryRecord{}, errMutationRecoveryNoDurableRecord
	}
}

func validMutationRecoveryID(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && hex.EncodeToString(decoded) == value
}

func (c *Core) disposeRecoveryLocked(request commandRequest, reviewed bool) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" || request.ItemID != "" {
		return commandError("invalid_request", "disposeRecovery does not accept folderID or itemID")
	}
	allowed := []string{"recoveryID", "digest", "byteCount", "status", "confirmed"}
	if reviewed {
		allowed = append(allowed, "payloadKind")
	}
	if err := requireArgumentKeys(request.Arguments, allowed...); err != nil {
		return err
	}
	recoveryID, ok := requiredCommandArgument(request.Arguments, "recoveryID")
	if !ok || !validMutationRecoveryID(recoveryID) {
		return commandError("invalid_recovery_id", "recoveryID must be a canonical opaque recovery identifier")
	}
	digest, ok := requiredCommandArgument(request.Arguments, "digest")
	if !ok || !validMutationRecoveryID(digest) {
		return commandError("invalid_recovery_summary", "digest must be a canonical SHA-256 value")
	}
	byteCountValue, ok := requiredCommandArgument(request.Arguments, "byteCount")
	byteCount, parseErr := strconv.ParseInt(byteCountValue, 10, 64)
	if !ok || parseErr != nil || byteCount < 0 || strconv.FormatInt(byteCount, 10) != byteCountValue {
		return commandError("invalid_recovery_summary", "byteCount must be a canonical nonnegative integer")
	}
	status, ok := requiredCommandArgument(request.Arguments, "status")
	if reviewed {
		if !ok || status != mutationRecoveryStatusPrepared && status != mutationRecoveryStatusConflict {
			return commandError("recovery_review_required", "reviewed disposal requires a prepared or conflicted recovery summary")
		}
		payloadKind, payloadKindOK := requiredCommandArgument(request.Arguments, "payloadKind")
		if !payloadKindOK || payloadKind != "file" && payloadKind != "directory" {
			return commandError("invalid_recovery_summary", "payloadKind must be file or directory")
		}
	} else if !ok || status != mutationRecoveryStatusRetained && status != mutationRecoveryStatusDisposalApproved {
		return commandError("recovery_not_disposable", "only retained recovery data or approved cleanup can be disposed")
	}
	confirmedValue, ok := requiredCommandArgument(request.Arguments, "confirmed")
	confirmed, confirmationErr := strconv.ParseBool(confirmedValue)
	if !ok || confirmationErr != nil || confirmedValue != strconv.FormatBool(confirmed) {
		return commandError("invalid_request", "confirmed must be true or false")
	}
	if !confirmed {
		return commandError("recovery_confirmation_required", "recovery disposal requires explicit confirmation")
	}
	payloadKind := request.Arguments["payloadKind"]
	if err := c.disposeRecoveryExact(recoveryID, payloadKind, digest, byteCount, status, reviewed); err != nil {
		return err
	}
	c.generation++
	return nil
}

func (c *Core) disposeRecoveryExact(
	recoveryID, payloadKind, digest string,
	byteCount int64,
	suppliedStatus string,
	reviewed bool,
) *responseError {
	recoveryRoot, err := openMutationRecoveryStore(c.home)
	if errors.Is(err, os.ErrNotExist) {
		return commandError("recovery_not_found", "the recovery record no longer exists")
	}
	if err != nil {
		return commandError("recovery_store_corrupt", "recovery records could not be opened safely")
	}
	defer recoveryRoot.Close()
	manifest, err := openMutationDirectoryAt(recoveryRoot, recoveryID)
	if errors.Is(err, os.ErrNotExist) {
		return commandError("recovery_not_found", "the recovery record no longer exists")
	}
	if err != nil {
		return commandError("recovery_store_corrupt", "recovery records could not be opened safely")
	}
	defer manifest.Close()
	empty, emptyErr := mutationRecoveryDirectoryEmpty(manifest)
	if emptyErr != nil {
		return commandError("recovery_store_corrupt", "recovery records could not be read safely")
	}
	if empty {
		if err := unlinkMutationNameAt(recoveryRoot, recoveryID, true); err != nil {
			return commandError("recovery_disposal_failed", "completed recovery cleanup could not be finalized")
		}
		if err := recoveryRoot.Sync(); err != nil {
			return commandError("recovery_disposal_failed", "completed recovery cleanup could not be finalized")
		}
		return nil
	}
	set, err := readMutationRecoveryRecordSet(manifest, recoveryID)
	if errors.Is(err, errMutationRecoveryNoDurableRecord) {
		empty, emptyErr := mutationRecoveryDirectoryEmpty(manifest)
		if emptyErr != nil || !empty {
			return commandError("recovery_store_corrupt", "recovery records could not be read safely")
		}
		if err := unlinkMutationNameAt(recoveryRoot, recoveryID, true); err != nil {
			return commandError("recovery_disposal_failed", "completed recovery cleanup could not be finalized")
		}
		if err := recoveryRoot.Sync(); err != nil {
			return commandError("recovery_disposal_failed", "completed recovery cleanup could not be finalized")
		}
		return nil
	}
	if err != nil {
		return commandError("recovery_store_corrupt", "recovery records could not be read safely")
	}
	active, sourceRecordName, selectionErr := selectRecoveryForDisposal(set, suppliedStatus, reviewed)
	if selectionErr != nil {
		return selectionErr
	}
	if active.ContentDigest != digest || active.ByteCount != byteCount ||
		reviewed && active.PayloadKind != payloadKind {
		return commandError("recovery_summary_mismatch", "the recovery summary changed; list it again before disposal")
	}

	payload, disposing, locatorKind, folderRoot, locatorErr := c.openRecoveryPayloads(active)
	if locatorErr != nil {
		return locatorErr
	}
	if payload != nil {
		defer payload.close()
	}
	if disposing != nil {
		defer disposing.close()
	}
	if payload != nil && disposing != nil {
		return commandError("recovery_store_corrupt", "recovery cleanup contains two payloads")
	}

	needsApproval := set.disposal == nil || reviewed && sourceRecordName == mutationRecoveryConflictName
	if needsApproval {
		payloadRequired := active.Status != mutationRecoveryStatusPrepared
		if payloadRequired && payload == nil || payload != nil && !recoveryPayloadMatchesRecord(payload, active) {
			_ = retainMutationRecoveryConflict(manifest, active, payload)
			return commandError("recovery_changed", "recovery payload changed after it was listed")
		}
		approved := active
		approved.Status = mutationRecoveryStatusDisposalApproved
		if set.disposal != nil {
			if err := unlinkMutationRecordIfPresent(manifest, mutationRecoveryDisposalName); err != nil {
				return commandError("recovery_disposal_failed", "reviewed recovery approval could not replace prior cleanup approval")
			}
			if err := manifest.Sync(); err != nil {
				return commandError("recovery_disposal_failed", "reviewed recovery approval could not replace prior cleanup approval")
			}
		}
		if err := writeMutationRecoveryRecord(manifest, mutationRecoveryDisposalName, approved); err != nil {
			return commandError("recovery_disposal_failed", "recovery disposal approval could not be persisted")
		}
		if err := manifest.Sync(); err != nil {
			return commandError("recovery_disposal_failed", "recovery disposal approval could not be persisted")
		}
		if reviewed {
			if err := unlinkMutationRecordIfPresent(manifest, sourceRecordName); err != nil {
				return commandError("recovery_disposal_failed", "reviewed recovery approval could not be persisted")
			}
			if err := manifest.Sync(); err != nil {
				return commandError("recovery_disposal_failed", "reviewed recovery approval could not be persisted")
			}
		}
		if c.afterRecoveryApprovalForTests != nil {
			if err := c.afterRecoveryApprovalForTests(); err != nil {
				return commandError("recovery_disposal_interrupted", "recovery disposal can be retried")
			}
		}
		set.disposal = &approved
	}
	approved := *set.disposal

	if disposing == nil && payload != nil {
		disposing = payload.withName(mutationRecoveryDisposingName)
		if err := revalidateMutationPaths(payload, disposing); err != nil || !recoveryPayloadMatchesRecord(payload, approved) {
			return commandError("recovery_changed", "recovery payload changed before cleanup")
		}
		if err := renameNoReplaceAt(payload, disposing); err != nil {
			return commandError("recovery_disposal_failed", "recovery payload could not enter cleanup")
		}
		if err := disposing.parent().Sync(); err != nil {
			return commandError("recovery_disposal_failed", "recovery cleanup transition could not be persisted")
		}
		if c.afterRecoveryRenameForTests != nil {
			if err := c.afterRecoveryRenameForTests(); err != nil {
				return commandError("recovery_disposal_interrupted", "recovery disposal can be retried")
			}
		}
	}
	if disposing != nil {
		if !recoveryPayloadMatchesRecord(disposing, approved) {
			_ = retainMutationRecoveryConflict(manifest, approved, disposing)
			return commandError("recovery_changed", "recovery payload changed during cleanup")
		}
		if err := removeMutationRecoveryObject(disposing); err != nil {
			return commandError("recovery_disposal_failed", "recovery payload could not be removed safely")
		}
		if err := disposing.parent().Sync(); err != nil {
			return commandError("recovery_disposal_failed", "recovery payload removal could not be persisted")
		}
		if c.afterRecoveryDeleteForTests != nil {
			if err := c.afterRecoveryDeleteForTests(); err != nil {
				return commandError("recovery_disposal_interrupted", "recovery disposal can be retried")
			}
		}
	}
	if locatorKind == "folder" {
		if err := removeEmptyFallbackRecoveryDirectory(folderRoot, recoveryID); err != nil {
			return commandError("recovery_disposal_failed", "recovery fallback cleanup could not be completed safely")
		}
	}
	if err := finishMutationRecoveryManifestDisposal(
		recoveryRoot,
		manifest,
		recoveryID,
		c.beforeRecoveryRecordRemovalForTests,
	); err != nil {
		if c.beforeRecoveryRecordRemovalForTests != nil {
			return commandError("recovery_disposal_interrupted", "recovery disposal can be retried")
		}
		return commandError("recovery_disposal_failed", "recovery record cleanup could not be completed safely")
	}
	return nil
}

func selectRecoveryForDisposal(
	set mutationRecoveryRecordSet,
	suppliedStatus string,
	reviewed bool,
) (mutationRecoveryRecord, string, *responseError) {
	if set.conflict != nil {
		if reviewed && suppliedStatus == mutationRecoveryStatusConflict {
			return *set.conflict, mutationRecoveryConflictName, nil
		}
		if reviewed {
			return mutationRecoveryRecord{}, "", commandError("recovery_review_required", "the recovery status changed and requires a new reviewed confirmation")
		}
		return mutationRecoveryRecord{}, "", commandError("recovery_not_disposable", "conflicted recovery data requires reviewed disposal")
	}
	if set.disposal != nil {
		allowedPrior := suppliedStatus == mutationRecoveryStatusRetained || suppliedStatus == mutationRecoveryStatusDisposalApproved
		if reviewed {
			allowedPrior = suppliedStatus == mutationRecoveryStatusPrepared || suppliedStatus == mutationRecoveryStatusConflict
		}
		if !allowedPrior {
			return mutationRecoveryRecord{}, "", commandError("recovery_summary_mismatch", "the recovery summary changed; list it again before disposal")
		}
		return *set.disposal, "", nil
	}
	if reviewed {
		switch suppliedStatus {
		case mutationRecoveryStatusPrepared:
			if set.prepared != nil && set.retained == nil {
				return *set.prepared, mutationRecoveryPreparedName, nil
			}
		}
		return mutationRecoveryRecord{}, "", commandError("recovery_summary_mismatch", "the reviewed recovery summary is no longer current")
	}
	if set.retained == nil {
		return mutationRecoveryRecord{}, "", commandError("recovery_not_disposable", "prepared or conflicted recovery data requires reviewed disposal")
	}
	if suppliedStatus != mutationRecoveryStatusRetained {
		return mutationRecoveryRecord{}, "", commandError("recovery_summary_mismatch", "the recovery summary changed; list it again before disposal")
	}
	return *set.retained, mutationRecoveryRetainedName, nil
}

func retainMutationRecoveryConflict(
	manifest *os.File,
	base mutationRecoveryRecord,
	payload *mutationPathRef,
) error {
	conflict := base
	if payload != nil {
		if state, err := captureMutationObjectAt(payload); err == nil {
			conflict = mutationRecoveryRecordForState(conflict, state)
		}
	}
	conflict.Status = mutationRecoveryStatusConflict
	if err := writeMutationRecoveryRecord(manifest, mutationRecoveryConflictName, conflict); err != nil {
		return err
	}
	return manifest.Sync()
}

func (c *Core) openRecoveryPayloads(record mutationRecoveryRecord) (
	payload, disposing *mutationPathRef,
	locatorKind, folderRoot string,
	responseErr *responseError,
) {
	recoveryID := record.RequestIDHash
	var root, payloadRelative, disposingRelative string
	switch {
	case record.RelativeRecoveryLocator == "home:Bridge/MutationRecovery/"+recoveryID+"/"+mutationRecoveryPayloadName:
		locatorKind = "home"
		root = c.home
		payloadRelative = "Bridge/MutationRecovery/" + recoveryID + "/" + mutationRecoveryPayloadName
		disposingRelative = "Bridge/MutationRecovery/" + recoveryID + "/" + mutationRecoveryDisposingName
	case record.RelativeRecoveryLocator == "folder:.stversions/.psy-bridge-recovery/"+recoveryID+"/"+mutationRecoveryPayloadName:
		locatorKind = "folder"
		folder, ok := c.runtime.configuration.Folder(record.FolderID)
		if !ok {
			return nil, nil, "", "", commandError("recovery_location_unavailable", "the recovery folder is no longer configured")
		}
		rootDigest := sha256.Sum256([]byte(filepath.Clean(folder.Path)))
		if record.RecoveryRootDigest == "" || record.RecoveryRootDigest != hex.EncodeToString(rootDigest[:]) {
			return nil, nil, "", "", commandError("recovery_location_unavailable", "the recovery folder location changed")
		}
		root = folder.Path
		folderRoot = folder.Path
		payloadRelative = ".stversions/.psy-bridge-recovery/" + recoveryID + "/" + mutationRecoveryPayloadName
		disposingRelative = ".stversions/.psy-bridge-recovery/" + recoveryID + "/" + mutationRecoveryDisposingName
	default:
		return nil, nil, "", "", commandError("recovery_store_corrupt", "recovery locator is invalid")
	}
	payload, err := openMutationPath(root, payloadRelative)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, "", "", commandError("recovery_store_corrupt", "recovery payload binding is unsafe")
	}
	if err == nil && locatorKind == "folder" {
		identity, identityErr := mutationDirectoryIdentity(payload.parent())
		if identityErr != nil || identity != record.RecoveryRootIdentity {
			_ = payload.close()
			return nil, nil, "", "", commandError("recovery_location_unavailable", "the recovery folder binding changed")
		}
	}
	if err == nil && mutationPathMissingAt(payload) {
		_ = payload.close()
		payload = nil
	}
	disposing, err = openMutationPath(root, disposingRelative)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		if payload != nil {
			_ = payload.close()
		}
		return nil, nil, "", "", commandError("recovery_store_corrupt", "recovery cleanup binding is unsafe")
	}
	if err == nil && mutationPathMissingAt(disposing) {
		_ = disposing.close()
		disposing = nil
	}
	return payload, disposing, locatorKind, folderRoot, nil
}

func recoveryPayloadMatchesRecord(payload *mutationPathRef, record mutationRecoveryRecord) bool {
	state, err := captureMutationObjectAt(payload)
	if err != nil {
		return false
	}
	kind := "file"
	if state.info.IsDir() {
		kind = "directory"
	}
	return kind == record.PayloadKind && state.bytes == record.ByteCount &&
		hex.EncodeToString(state.digest[:]) == record.ContentDigest
}

func removeMutationRecoveryObject(path *mutationPathRef) error {
	if err := path.revalidate(); err != nil {
		return errMutationPathChanged
	}
	handle, err := openMutationObjectAt(path.parent(), path.name)
	if err != nil {
		return err
	}
	info, err := handle.Stat()
	if err != nil {
		_ = handle.Close()
		return err
	}
	switch {
	case info.Mode().IsRegular():
		_ = handle.Close()
		current, err := openMutationObjectAt(path.parent(), path.name)
		if err != nil {
			return errMutationObjectChanged
		}
		currentInfo, statErr := current.Stat()
		_ = current.Close()
		if statErr != nil || !sameMutationFileMetadata(info, currentInfo) || path.revalidate() != nil {
			return errMutationObjectChanged
		}
		return unlinkMutationAt(path, false)
	case info.IsDir():
		if err := removeMutationRecoveryDirectoryContents(handle); err != nil {
			_ = handle.Close()
			return err
		}
		if err := handle.Sync(); err != nil {
			_ = handle.Close()
			return err
		}
		finalInfo, err := handle.Stat()
		_ = handle.Close()
		if err != nil || !sameMutationObjectIdentity(info, finalInfo) || path.revalidate() != nil {
			return errMutationObjectChanged
		}
		return unlinkMutationAt(path, true)
	default:
		_ = handle.Close()
		return errMutationObjectTypeUnsupported
	}
}

func removeMutationRecoveryDirectoryContents(directory *os.File) error {
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return err
	}
	sort.Slice(entries, func(left, right int) bool { return entries[left].Name() < entries[right].Name() })
	for _, entry := range entries {
		name := entry.Name()
		child, openErr := openMutationObjectAt(directory, name)
		if openErr != nil {
			first, linkErr := readMutationLinkAt(directory, name)
			if linkErr != nil {
				return openErr
			}
			second, linkErr := readMutationLinkAt(directory, name)
			if linkErr != nil || first != second {
				return errMutationObjectChanged
			}
			if err := unlinkMutationNameAt(directory, name, false); err != nil {
				return err
			}
			continue
		}
		info, err := child.Stat()
		if err != nil {
			_ = child.Close()
			return err
		}
		switch {
		case info.Mode().IsRegular():
			_ = child.Close()
			current, err := openMutationObjectAt(directory, name)
			if err != nil {
				return errMutationObjectChanged
			}
			currentInfo, statErr := current.Stat()
			_ = current.Close()
			if statErr != nil || !sameMutationFileMetadata(info, currentInfo) {
				return errMutationObjectChanged
			}
			if err := unlinkMutationNameAt(directory, name, false); err != nil {
				return err
			}
		case info.IsDir():
			if err := removeMutationRecoveryDirectoryContents(child); err != nil {
				_ = child.Close()
				return err
			}
			if err := child.Sync(); err != nil {
				_ = child.Close()
				return err
			}
			finalInfo, err := child.Stat()
			_ = child.Close()
			if err != nil || !sameMutationObjectIdentity(info, finalInfo) {
				return errMutationObjectChanged
			}
			if err := unlinkMutationNameAt(directory, name, true); err != nil {
				return err
			}
		default:
			_ = child.Close()
			return errMutationObjectTypeUnsupported
		}
	}
	return directory.Sync()
}

func unlinkMutationNameAt(parent *os.File, name string, directory bool) error {
	path := &mutationPathRef{
		chain: &mutationDirectoryChain{directories: []mutationDirectoryBinding{{file: parent}}},
		name:  name,
	}
	return unlinkMutationAt(path, directory)
}

func removeEmptyFallbackRecoveryDirectory(folderRoot, recoveryID string) error {
	path, err := openMutationPath(folderRoot, ".stversions/.psy-bridge-recovery/"+recoveryID)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer path.close()
	directory, err := openMutationDirectoryAt(path.parent(), path.name)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	entries, readErr := directory.ReadDir(-1)
	_ = directory.Close()
	if readErr != nil || len(entries) != 0 {
		return errors.New("fallback recovery directory is not empty")
	}
	if err := path.revalidate(); err != nil {
		return err
	}
	if err := unlinkMutationAt(path, true); err != nil {
		return err
	}
	return path.parent().Sync()
}

func finishMutationRecoveryManifestDisposal(
	root, manifest *os.File,
	recoveryID string,
	beforeDirectoryRemoval func() error,
) error {
	for _, name := range []string{mutationRecoveryPreparedName, mutationRecoveryRetainedName} {
		if err := unlinkMutationRecordIfPresent(manifest, name); err != nil {
			return err
		}
	}
	if err := manifest.Sync(); err != nil {
		return err
	}
	if err := unlinkMutationRecordIfPresent(manifest, mutationRecoveryDisposalName); err != nil {
		return err
	}
	if err := manifest.Sync(); err != nil {
		return err
	}
	if _, err := manifest.Seek(0, 0); err != nil {
		return err
	}
	entries, err := manifest.ReadDir(-1)
	if err != nil || len(entries) != 0 {
		return errors.New("recovery manifest directory is not empty")
	}
	if beforeDirectoryRemoval != nil {
		if err := beforeDirectoryRemoval(); err != nil {
			return err
		}
	}
	if err := unlinkMutationNameAt(root, recoveryID, true); err != nil {
		return err
	}
	return root.Sync()
}

func mutationRecoveryDirectoryEmpty(directory *os.File) (bool, error) {
	if _, err := directory.Seek(0, 0); err != nil {
		return false, err
	}
	entries, err := directory.ReadDir(1)
	if err == nil {
		return len(entries) == 0, nil
	}
	if errors.Is(err, io.EOF) {
		return true, nil
	}
	return false, err
}

func unlinkMutationRecordIfPresent(directory *os.File, name string) error {
	handle, err := openMutationObjectAt(directory, name)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	info, statErr := handle.Stat()
	_ = handle.Close()
	if statErr != nil || !info.Mode().IsRegular() {
		return errors.New("recovery record is not a regular file")
	}
	return unlinkMutationNameAt(directory, name, false)
}

func validateMutationRecoveryRecordFields(record mutationRecoveryRecord) error {
	if !validMutationRecoveryID(record.RequestIDHash) || !validMutationRecoveryID(record.ContentDigest) ||
		record.ByteCount < 0 || record.PayloadKind != "file" && record.PayloadKind != "directory" {
		return fmt.Errorf("mutation recovery record summary is invalid")
	}
	if err := validateFolderID(record.FolderID); err != nil {
		return errors.New("mutation recovery folder identity is invalid")
	}
	if _, err := validateRelativePath(record.RelativePath, false); err != nil {
		return errors.New("mutation recovery relative path is invalid")
	}
	homeLocator := "home:Bridge/MutationRecovery/" + record.RequestIDHash + "/" + mutationRecoveryPayloadName
	folderLocator := "folder:.stversions/.psy-bridge-recovery/" + record.RequestIDHash + "/" + mutationRecoveryPayloadName
	if record.RelativeRecoveryLocator != homeLocator && record.RelativeRecoveryLocator != folderLocator {
		return errors.New("mutation recovery locator is invalid")
	}
	if record.RelativeRecoveryLocator == homeLocator && (record.RecoveryRootDigest != "" || record.RecoveryRootIdentity != "") {
		return errors.New("home mutation recovery record has an unexpected root binding")
	}
	if record.RelativeRecoveryLocator == folderLocator &&
		(!validMutationRecoveryID(record.RecoveryRootDigest) || !validMutationRecoveryID(record.RecoveryRootIdentity)) {
		return errors.New("folder mutation recovery root binding is invalid")
	}
	createdAt, err := time.Parse(time.RFC3339Nano, record.CreatedAt)
	if err != nil || createdAt.UTC().Format(time.RFC3339Nano) != record.CreatedAt {
		return errors.New("mutation recovery creation time is invalid")
	}
	switch record.Status {
	case mutationRecoveryStatusPrepared, mutationRecoveryStatusRetained,
		mutationRecoveryStatusConflict, mutationRecoveryStatusDisposalApproved:
	default:
		return errors.New("mutation recovery status is invalid")
	}
	return nil
}
