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
	"strings"
	"time"
)

const (
	mutationRecoverySchemaVersion = 1
	maxMutationRecoveryRecords    = 512
	maxMutationRecoveryRecordSize = 4 << 10

	mutationRecoveryPreparedName = "prepared.json"
	mutationRecoveryRetainedName = "retained.json"
	mutationRecoveryConflictName = "conflict.json"
	mutationRecoveryPayloadName  = "payload"

	mutationRecoveryStatusPrepared = "prepared"
	mutationRecoveryStatusRetained = "retainedRequiresUserConfirmation"
	mutationRecoveryStatusConflict = "conflictRequiresManualCleanup"
)

var errMutationRecoveryRequiresManualCleanup = errors.New("mutation recovery requires manual cleanup")

type mutationRecoveryRecord struct {
	SchemaVersion           int    `json:"schemaVersion"`
	RequestIDHash           string `json:"requestIDHash"`
	CommandKind             string `json:"commandKind"`
	FolderID                string `json:"folderID"`
	RelativePath            string `json:"relativePath"`
	ContentDigest           string `json:"contentDigest"`
	ByteCount               int64  `json:"byteCount"`
	PayloadKind             string `json:"payloadKind"`
	RelativeRecoveryLocator string `json:"relativeRecoveryLocator"`
	RecoveryRootDigest      string `json:"recoveryRootDigest,omitempty"`
	RecoveryRootIdentity    string `json:"recoveryRootIdentity,omitempty"`
	CreatedAt               string `json:"createdAt"`
	Status                  string `json:"status"`
}

type mutationRecoveryPlan struct {
	manifestDirectory *os.File
	payload           *mutationPathRef
	prepared          mutationRecoveryRecord
}

func prepareMutationRecovery(
	home string,
	folderRoot string,
	request commandRequest,
	relativePath string,
	sourceParent *mutationPathRef,
	expected mutationObjectState,
) (*mutationRecoveryPlan, error) {
	if _, validationErr := validateRelativePath(relativePath, false); validationErr != nil {
		return nil, errors.New("mutation recovery path is invalid")
	}
	if request.RequestID == "" || request.FolderID == "" || request.Command == "" {
		return nil, errors.New("mutation recovery identity is incomplete")
	}
	if sourceParent == nil || sourceParent.parent() == nil {
		return nil, errors.New("mutation recovery source binding is unavailable")
	}

	hash := sha256.Sum256([]byte(request.RequestID))
	requestHash := hex.EncodeToString(hash[:])
	recoveryRoot := filepath.Join(home, "Bridge", "MutationRecovery")
	manifestDirectory, err := prepareMutationRecoveryManifestDirectory(home, requestHash)
	if err != nil {
		return nil, err
	}
	keepManifestDirectory := false
	defer func() {
		if !keepManifestDirectory {
			_ = manifestDirectory.Close()
		}
	}()

	sameDevice, err := mutationDirectoriesShareDevice(sourceParent.parent(), manifestDirectory)
	if err != nil {
		return nil, fmt.Errorf("compare mutation recovery filesystems: %w", err)
	}
	payloadRoot := recoveryRoot
	payloadRelativePath := requestHash + "/" + mutationRecoveryPayloadName
	relativeLocator := "home:Bridge/MutationRecovery/" + requestHash + "/" + mutationRecoveryPayloadName
	recoveryRootIdentity := ""
	if !sameDevice {
		if err := prepareMutationRecoveryFallbackDirectory(folderRoot, requestHash); err != nil {
			return nil, err
		}
		payloadRoot = folderRoot
		payloadRelativePath = ".stversions/.psy-bridge-recovery/" + requestHash + "/" + mutationRecoveryPayloadName
		relativeLocator = "folder:" + payloadRelativePath
		fallbackPayload, openErr := openMutationPath(payloadRoot, payloadRelativePath)
		if openErr != nil {
			return nil, fmt.Errorf("open folder recovery payload binding: %w", openErr)
		}
		fallbackSameDevice, deviceErr := mutationDirectoriesShareDevice(sourceParent.parent(), fallbackPayload.parent())
		if deviceErr == nil {
			recoveryRootIdentity, deviceErr = mutationDirectoryIdentity(fallbackPayload.parent())
		}
		_ = fallbackPayload.close()
		if deviceErr != nil || !fallbackSameDevice {
			if deviceErr == nil {
				deviceErr = errors.New("folder recovery location is not on the mutation filesystem")
			}
			return nil, deviceErr
		}
	}

	payload, err := openMutationPath(payloadRoot, payloadRelativePath)
	if err != nil {
		return nil, fmt.Errorf("open mutation recovery payload binding: %w", err)
	}
	keepPayload := false
	defer func() {
		if !keepPayload {
			_ = payload.close()
		}
	}()

	payloadKind := "file"
	byteCount := expected.bytes
	if expected.info.IsDir() {
		payloadKind = "directory"
	}
	proposed := mutationRecoveryRecord{
		SchemaVersion:           mutationRecoverySchemaVersion,
		RequestIDHash:           requestHash,
		CommandKind:             request.Command,
		FolderID:                request.FolderID,
		RelativePath:            relativePath,
		ContentDigest:           hex.EncodeToString(expected.digest[:]),
		ByteCount:               byteCount,
		PayloadKind:             payloadKind,
		RelativeRecoveryLocator: relativeLocator,
		CreatedAt:               time.Now().UTC().Format(time.RFC3339Nano),
		Status:                  mutationRecoveryStatusPrepared,
	}
	if !sameDevice {
		rootDigest := sha256.Sum256([]byte(filepath.Clean(folderRoot)))
		proposed.RecoveryRootDigest = hex.EncodeToString(rootDigest[:])
		proposed.RecoveryRootIdentity = recoveryRootIdentity
	}
	prepared, err := prepareMutationRecoveryRecord(manifestDirectory, proposed)
	if err != nil {
		return nil, err
	}

	keepManifestDirectory = true
	keepPayload = true
	return &mutationRecoveryPlan{
		manifestDirectory: manifestDirectory,
		payload:           payload,
		prepared:          prepared,
	}, nil
}

func (plan *mutationRecoveryPlan) close() error {
	if plan == nil {
		return nil
	}
	var result error
	if plan.payload != nil {
		result = errors.Join(result, plan.payload.close())
		plan.payload = nil
	}
	if plan.manifestDirectory != nil {
		result = errors.Join(result, plan.manifestDirectory.Close())
		plan.manifestDirectory = nil
	}
	return result
}

func (plan *mutationRecoveryPlan) retain(
	source *mutationPathRef,
	expected mutationObjectState,
	status string,
	requireExpectedFingerprint bool,
	beforeMove func(command, preservedPath string) error,
	afterMove func(recoveryPath string) error,
) error {
	if plan == nil || plan.manifestDirectory == nil || plan.payload == nil {
		return errors.New("mutation recovery plan is unavailable")
	}
	if status != mutationRecoveryStatusRetained && status != mutationRecoveryStatusConflict {
		return errors.New("mutation recovery status is invalid")
	}
	if conflict, err := readMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryConflictName); err != nil {
		return err
	} else if conflict != nil {
		if !sameMutationRecoveryOperationInvariant(*conflict, plan.prepared) || conflict.Status != mutationRecoveryStatusConflict {
			return errors.New("mutation recovery conflict record does not match the accepted operation")
		}
		return errMutationRecoveryRequiresManualCleanup
	}
	if retained, err := readMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryRetainedName); err != nil {
		return err
	} else if retained != nil {
		if !sameMutationRecoveryOperationInvariant(*retained, plan.prepared) || retained.Status != mutationRecoveryStatusRetained {
			return errors.New("mutation recovery retained record does not match the accepted operation")
		}
		if !mutationPathMissingAt(source) {
			return errMutationObjectChanged
		}
		current, captureErr := captureMutationObjectAt(plan.payload)
		if captureErr != nil || mutationRecoveryRecordDigest(*retained) != mutationRecoveryStateDigest(current) {
			conflictRecord := plan.prepared
			if captureErr == nil {
				conflictRecord = mutationRecoveryRecordForState(conflictRecord, current)
			}
			conflictRecord.Status = mutationRecoveryStatusConflict
			_ = writeMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryConflictName, conflictRecord)
			return errMutationRecoveryRequiresManualCleanup
		}
		return nil
	}

	payloadExists := mutationRecoveryPayloadHasExpectedType(plan.payload, expected)
	sourceMissing := mutationPathMissingAt(source)
	if payloadExists && !sourceMissing {
		return errMutationObjectChanged
	}
	if !payloadExists {
		if sourceMissing {
			return errors.New("accepted mutation has neither a quarantine nor a recovery payload")
		}
		if requireExpectedFingerprint && !mutationObjectMatchesAt(source, expected) {
			return errMutationObjectChanged
		}
		if err := revalidateMutationPaths(source, plan.payload); err != nil {
			return err
		}
		handle, err := openMutationObjectAt(source.parent(), source.name)
		if err != nil {
			return err
		}
		defer handle.Close()
		openedInfo, err := handle.Stat()
		if err != nil || !sameMutationObjectIdentity(openedInfo, expected.info) {
			return errMutationObjectChanged
		}
		if beforeMove != nil {
			if err := beforeMove(plan.prepared.CommandKind, source.absolutePath); err != nil {
				return err
			}
		}
		finalInfo, err := handle.Stat()
		if err != nil || !sameMutationObjectIdentity(openedInfo, finalInfo) {
			return errMutationObjectChanged
		}
		current, err := openMutationObjectAt(source.parent(), source.name)
		if err != nil {
			return errMutationObjectChanged
		}
		currentInfo, currentErr := current.Stat()
		_ = current.Close()
		if currentErr != nil || !sameMutationObjectIdentity(finalInfo, currentInfo) {
			return errMutationObjectChanged
		}
		if err := revalidateMutationPaths(source, plan.payload); err != nil || !mutationPathMissingAt(plan.payload) {
			return errMutationObjectChanged
		}
		if err := renameNoReplaceAt(source, plan.payload); err != nil {
			return err
		}
		if err := syncMutationDirectories(source, plan.payload); err != nil {
			return err
		}
		payloadHandle, err := openMutationObjectAt(plan.payload.parent(), plan.payload.name)
		if err != nil {
			return err
		}
		payloadInfo, statErr := payloadHandle.Stat()
		if statErr != nil || !sameMutationObjectIdentity(finalInfo, payloadInfo) {
			_ = payloadHandle.Close()
			return errMutationObjectChanged
		}
		permissions := os.FileMode(0o600)
		if payloadInfo.IsDir() {
			permissions = 0o700
		}
		if err := payloadHandle.Chmod(permissions); err != nil {
			_ = payloadHandle.Close()
			return err
		}
		if err := payloadHandle.Sync(); err != nil {
			_ = payloadHandle.Close()
			return err
		}
		if err := payloadHandle.Close(); err != nil {
			return err
		}
		if err := plan.payload.parent().Sync(); err != nil {
			return err
		}
		if afterMove != nil {
			if err := afterMove(plan.payload.absolutePath); err != nil {
				return err
			}
		}
	} else if !sourceMissing {
		return errMutationObjectChanged
	}

	current, captureErr := captureMutationObjectAt(plan.payload)
	if captureErr != nil {
		finalRecord := plan.prepared
		finalRecord.Status = mutationRecoveryStatusConflict
		_ = writeMutationRecoveryRecord(plan.manifestDirectory, mutationRecoveryConflictName, finalRecord)
		return errMutationRecoveryRequiresManualCleanup
	}
	finalRecord := mutationRecoveryRecordForState(plan.prepared, current)
	finalRecord.Status = status
	recordName := mutationRecoveryRetainedName
	if status == mutationRecoveryStatusConflict {
		recordName = mutationRecoveryConflictName
	}
	if err := writeMutationRecoveryRecord(plan.manifestDirectory, recordName, finalRecord); err != nil {
		return err
	}
	return plan.manifestDirectory.Sync()
}

func sameMutationObjectIdentity(left, right os.FileInfo) bool {
	if left == nil || right == nil || !os.SameFile(left, right) {
		return false
	}
	return left.IsDir() == right.IsDir() && left.Mode().IsRegular() == right.Mode().IsRegular()
}

func mutationRecoveryPayloadHasExpectedType(path *mutationPathRef, expected mutationObjectState) bool {
	if path == nil || path.revalidate() != nil {
		return false
	}
	handle, err := openMutationObjectAt(path.parent(), path.name)
	if err != nil {
		return false
	}
	defer handle.Close()
	info, err := handle.Stat()
	if err != nil {
		return false
	}
	return info.IsDir() == expected.info.IsDir() && info.Mode().IsRegular() == expected.info.Mode().IsRegular()
}

func prepareMutationRecoveryManifestDirectory(home, requestHash string) (*os.File, error) {
	homeDirectory, err := openVerifiedMutationRecoveryRoot(home)
	if err != nil {
		return nil, err
	}
	defer homeDirectory.Close()
	bridge, err := ensureMutationRecoveryDirectory(homeDirectory, "Bridge", true)
	if err != nil {
		return nil, err
	}
	defer bridge.Close()
	recovery, err := ensureMutationRecoveryDirectory(bridge, "MutationRecovery", true)
	if err != nil {
		return nil, err
	}
	defer recovery.Close()

	entries, err := recovery.ReadDir(-1)
	if err != nil {
		return nil, err
	}
	found := false
	unresolvedCount := 0
	for _, entry := range entries {
		name := entry.Name()
		if !validMutationRecoveryID(name) {
			return nil, errors.New("mutation recovery directory contains an invalid record name")
		}
		child, err := openMutationDirectoryAt(recovery, name)
		if err != nil {
			return nil, errors.New("mutation recovery record is not a no-follow directory")
		}
		childEntries, readErr := child.ReadDir(-1)
		_ = child.Close()
		if readErr != nil {
			return nil, errors.New("mutation recovery record directory could not be read safely")
		}
		if len(childEntries) == 0 {
			if err := unlinkMutationNameAt(recovery, name, true); err != nil {
				return nil, errors.New("completed mutation recovery record could not be reclaimed")
			}
			if err := recovery.Sync(); err != nil {
				return nil, err
			}
			continue
		}
		unresolvedCount++
		if name == requestHash {
			found = true
		}
	}
	if !found && unresolvedCount >= maxMutationRecoveryRecords {
		return nil, errors.New("mutation recovery record capacity is exhausted")
	}
	return ensureMutationRecoveryDirectory(recovery, requestHash, true)
}

func prepareMutationRecoveryFallbackDirectory(folderRoot, requestHash string) error {
	root, err := openVerifiedMutationRecoveryRoot(folderRoot)
	if err != nil {
		return err
	}
	defer root.Close()
	versions, err := ensureMutationRecoveryDirectory(root, ".stversions", false)
	if err != nil {
		return err
	}
	defer versions.Close()
	recovery, err := ensureMutationRecoveryDirectory(versions, ".psy-bridge-recovery", true)
	if err != nil {
		return err
	}
	defer recovery.Close()
	operation, err := ensureMutationRecoveryDirectory(recovery, requestHash, true)
	if err != nil {
		return err
	}
	return operation.Close()
}

func openVerifiedMutationRecoveryRoot(path string) (*os.File, error) {
	if path == "" || !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return nil, errors.New("mutation recovery root is invalid")
	}
	handle, err := openMutationDirectoryPath(path)
	if err != nil {
		return nil, err
	}
	info, err := handle.Stat()
	if err != nil || !info.IsDir() {
		_ = handle.Close()
		return nil, errors.New("mutation recovery root is not a directory")
	}
	pathInfo, err := os.Lstat(path)
	if err != nil || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(info, pathInfo) {
		_ = handle.Close()
		return nil, errors.New("mutation recovery root binding changed")
	}
	return handle, nil
}

func ensureMutationRecoveryDirectory(parent *os.File, name string, securePermissions bool) (*os.File, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\\`) {
		return nil, errors.New("mutation recovery directory name is invalid")
	}
	child, err := openMutationDirectoryAt(parent, name)
	if errors.Is(err, os.ErrNotExist) {
		path := &mutationPathRef{
			chain: &mutationDirectoryChain{directories: []mutationDirectoryBinding{{file: parent}}},
			name:  name,
		}
		if err := mkdirMutationAt(path, 0o700); err != nil {
			return nil, err
		}
		if err := parent.Sync(); err != nil {
			return nil, err
		}
		child, err = openMutationDirectoryAt(parent, name)
	}
	if err != nil {
		return nil, err
	}
	info, err := child.Stat()
	if err != nil || !info.IsDir() {
		_ = child.Close()
		return nil, errors.New("mutation recovery component is not a directory")
	}
	if securePermissions {
		if err := child.Chmod(0o700); err != nil {
			_ = child.Close()
			return nil, err
		}
	}
	return child, nil
}

func prepareMutationRecoveryRecord(directory *os.File, proposed mutationRecoveryRecord) (mutationRecoveryRecord, error) {
	existing, err := readMutationRecoveryRecord(directory, mutationRecoveryPreparedName)
	if err != nil {
		return mutationRecoveryRecord{}, err
	}
	if existing != nil {
		proposed.CreatedAt = existing.CreatedAt
		if existing.Status != mutationRecoveryStatusPrepared || !sameMutationRecoveryInvariant(*existing, proposed) {
			return mutationRecoveryRecord{}, errors.New("mutation recovery request hash collides with another accepted operation")
		}
		return *existing, nil
	}
	if err := writeMutationRecoveryRecord(directory, mutationRecoveryPreparedName, proposed); err != nil {
		return mutationRecoveryRecord{}, err
	}
	return proposed, nil
}

func sameMutationRecoveryInvariant(left, right mutationRecoveryRecord) bool {
	return sameMutationRecoveryOperationInvariant(left, right) &&
		left.ContentDigest == right.ContentDigest &&
		left.ByteCount == right.ByteCount
}

func sameMutationRecoveryOperationInvariant(left, right mutationRecoveryRecord) bool {
	return left.SchemaVersion == right.SchemaVersion &&
		left.RequestIDHash == right.RequestIDHash &&
		left.CommandKind == right.CommandKind &&
		left.FolderID == right.FolderID &&
		left.RelativePath == right.RelativePath &&
		left.PayloadKind == right.PayloadKind &&
		left.RelativeRecoveryLocator == right.RelativeRecoveryLocator &&
		left.RecoveryRootDigest == right.RecoveryRootDigest &&
		left.RecoveryRootIdentity == right.RecoveryRootIdentity &&
		left.CreatedAt == right.CreatedAt
}

func mutationRecoveryRecordForState(record mutationRecoveryRecord, state mutationObjectState) mutationRecoveryRecord {
	record.ContentDigest = hex.EncodeToString(state.digest[:])
	record.ByteCount = state.bytes
	return record
}

func mutationRecoveryStateDigest(state mutationObjectState) string {
	return fmt.Sprintf("%s:%d", hex.EncodeToString(state.digest[:]), state.bytes)
}

func mutationRecoveryRecordDigest(record mutationRecoveryRecord) string {
	return fmt.Sprintf("%s:%d", record.ContentDigest, record.ByteCount)
}

func writeMutationRecoveryRecord(directory *os.File, name string, record mutationRecoveryRecord) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > maxMutationRecoveryRecordSize {
		return errors.New("mutation recovery record exceeds the supported size")
	}
	handle, err := createMutationNamedFileAt(directory, name, 0o600)
	if errors.Is(err, os.ErrExist) {
		existing, readErr := readMutationRecoveryRecord(directory, name)
		if readErr != nil {
			return readErr
		}
		if existing == nil || *existing != record {
			return errors.New("mutation recovery record changed unexpectedly")
		}
		return nil
	}
	if err != nil {
		return err
	}
	defer handle.Close()
	if err := handle.Chmod(0o600); err != nil {
		return err
	}
	if _, err := handle.Write(data); err != nil {
		return err
	}
	if err := handle.Sync(); err != nil {
		return err
	}
	return directory.Sync()
}

func readMutationRecoveryRecord(directory *os.File, name string) (*mutationRecoveryRecord, error) {
	handle, err := openMutationObjectAt(directory, name)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer handle.Close()
	info, err := handle.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxMutationRecoveryRecordSize {
		return nil, errors.New("mutation recovery record is not a bounded regular file")
	}
	if err := handle.Chmod(0o600); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(handle, maxMutationRecoveryRecordSize+1))
	if err != nil || len(data) == 0 || len(data) > maxMutationRecoveryRecordSize {
		return nil, errors.New("mutation recovery record could not be read safely")
	}
	var record mutationRecoveryRecord
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("mutation recovery record must contain exactly one JSON object")
	}
	if record.SchemaVersion != mutationRecoverySchemaVersion ||
		len(record.RequestIDHash) != sha256.Size*2 ||
		record.CommandKind == "" || record.FolderID == "" || record.RelativePath == "" ||
		record.ContentDigest == "" || record.RelativeRecoveryLocator == "" || record.CreatedAt == "" {
		return nil, errors.New("mutation recovery record is invalid")
	}
	if _, err := hex.DecodeString(record.RequestIDHash); err != nil {
		return nil, errors.New("mutation recovery request hash is invalid")
	}
	if err := validateMutationRecoveryRecordFields(record); err != nil {
		return nil, err
	}
	return &record, nil
}
