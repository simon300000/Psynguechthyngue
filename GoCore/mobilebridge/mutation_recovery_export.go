// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

const (
	mutationRecoveryExportsName  = "MutationRecoveryExports"
	mutationRecoveryExportPrefix = ".psy-core-recovery-export-"
)

func (c *Core) exportRecoveryLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" || request.ItemID != "" {
		return commandError("invalid_request", "exportRecovery does not accept folderID or itemID")
	}
	if err := requireArgumentKeys(
		request.Arguments,
		"recoveryID", "folderID", "commandKind", "relativePath", "payloadKind",
		"digest", "byteCount", "status", "exportID", "outputName",
	); err != nil {
		return err
	}
	recoveryID, ok := requiredCommandArgument(request.Arguments, "recoveryID")
	if !ok || !validMutationRecoveryID(recoveryID) {
		return commandError("invalid_recovery_id", "recoveryID must be a canonical opaque recovery identifier")
	}
	exportID, ok := requiredCommandArgument(request.Arguments, "exportID")
	if !ok || !validMutationRecoveryExportID(exportID) || exportID != request.RequestID {
		return commandError("invalid_recovery_export", "exportID must match the canonical request identifier")
	}
	outputName, ok := requiredCommandArgument(request.Arguments, "outputName")
	if !ok || !validMutationRecoveryExportName(outputName) {
		return commandError("invalid_recovery_export", "outputName must be one safe path component")
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
	payloadKind, payloadKindOK := requiredCommandArgument(request.Arguments, "payloadKind")
	status, statusOK := requiredCommandArgument(request.Arguments, "status")
	folderID, folderOK := requiredCommandArgument(request.Arguments, "folderID")
	commandKind, commandOK := requiredCommandArgument(request.Arguments, "commandKind")
	relativePath, relativeOK := requiredCommandArgument(request.Arguments, "relativePath")
	if !payloadKindOK || payloadKind != "file" && payloadKind != "directory" ||
		!statusOK || !validMutationRecoveryStatus(status) ||
		!folderOK || validateFolderID(folderID) != nil ||
		!commandOK || !isMutationCommand(commandKind) ||
		!relativeOK {
		return commandError("invalid_recovery_summary", "the recovery summary is invalid")
	}
	if _, err := validateRelativePath(relativePath, false); err != nil {
		return commandError("invalid_recovery_summary", "the recovery relative path is invalid")
	}

	record, payload, responseErr := c.exactRecoveryPayload(recoveryID)
	if responseErr != nil {
		return responseErr
	}
	defer payload.close()
	if record.ContentDigest != digest || record.ByteCount != byteCount ||
		record.PayloadKind != payloadKind || record.Status != status ||
		record.FolderID != folderID || record.CommandKind != commandKind ||
		record.RelativePath != relativePath {
		return commandError("recovery_summary_mismatch", "the recovery summary changed after review")
	}
	if !recoveryPayloadMatchesRecord(payload, record) {
		return commandError("recovery_changed", "the recovery payload changed after review")
	}
	if err := c.createMutationRecoveryExport(record, payload, exportID, outputName); err != nil {
		return commandError("recovery_export_failed", "the recovery snapshot could not be created safely")
	}
	return nil
}

func (c *Core) discardRecoveryExportLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" || request.ItemID != "" {
		return commandError("invalid_request", "discardRecoveryExport does not accept folderID or itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "exportID"); err != nil {
		return err
	}
	exportID, ok := requiredCommandArgument(request.Arguments, "exportID")
	if !ok || !validMutationRecoveryExportID(exportID) {
		return commandError("invalid_recovery_export", "exportID must be canonical")
	}
	if err := removeMutationRecoveryExport(c.home, exportID); err != nil {
		return commandError("recovery_export_cleanup_failed", "the recovery snapshot could not be removed safely")
	}
	return nil
}

func (c *Core) exactRecoveryPayload(recoveryID string) (mutationRecoveryRecord, *mutationPathRef, *responseError) {
	recoveryRoot, err := openMutationRecoveryStore(c.home)
	if errors.Is(err, os.ErrNotExist) {
		return mutationRecoveryRecord{}, nil, commandError("recovery_not_found", "the recovery record no longer exists")
	}
	if err != nil {
		return mutationRecoveryRecord{}, nil, commandError("recovery_store_corrupt", "recovery records could not be opened safely")
	}
	defer recoveryRoot.Close()
	manifest, err := openMutationDirectoryAt(recoveryRoot, recoveryID)
	if errors.Is(err, os.ErrNotExist) {
		return mutationRecoveryRecord{}, nil, commandError("recovery_not_found", "the recovery record no longer exists")
	}
	if err != nil {
		return mutationRecoveryRecord{}, nil, commandError("recovery_store_corrupt", "the recovery record could not be opened safely")
	}
	set, err := readMutationRecoveryRecordSet(manifest, recoveryID)
	_ = manifest.Close()
	if err != nil {
		return mutationRecoveryRecord{}, nil, commandError("recovery_store_corrupt", "the recovery record could not be read safely")
	}
	record, err := set.visible()
	if err != nil {
		return mutationRecoveryRecord{}, nil, commandError("recovery_not_found", "the recovery record is unavailable")
	}
	payload, disposing, _, _, responseErr := c.openRecoveryPayloads(record)
	if responseErr != nil {
		return mutationRecoveryRecord{}, nil, responseErr
	}
	if payload != nil && disposing != nil {
		_ = payload.close()
		_ = disposing.close()
		return mutationRecoveryRecord{}, nil, commandError("recovery_changed", "multiple recovery payloads are present")
	}
	if payload == nil {
		payload = disposing
	}
	if payload == nil {
		return mutationRecoveryRecord{}, nil, commandError("recovery_not_found", "the recovery payload is unavailable")
	}
	return record, payload, nil
}

func (c *Core) createMutationRecoveryExport(
	record mutationRecoveryRecord,
	payload *mutationPathRef,
	exportID, outputName string,
) error {
	root, err := openVerifiedMutationRecoveryRoot(c.home)
	if err != nil {
		return err
	}
	defer root.Close()
	bridge, err := ensureMutationRecoveryDirectory(root, "Bridge", true)
	if err != nil {
		return err
	}
	defer bridge.Close()
	exports, err := ensureMutationRecoveryDirectory(bridge, mutationRecoveryExportsName, true)
	if err != nil {
		return err
	}
	defer exports.Close()
	containerName := mutationRecoveryExportPrefix + exportID
	container, openErr := openMutationDirectoryAt(exports, containerName)
	if openErr == nil {
		_ = container.Close()
		if verifyErr := verifyExistingMutationRecoveryExport(
			c.home,
			record,
			exportID,
			outputName,
		); verifyErr == nil {
			return nil
		}
		if err := removeMutationRecoveryExport(c.home, exportID); err != nil {
			return err
		}
		openErr = os.ErrNotExist
	}
	if !errors.Is(openErr, os.ErrNotExist) {
		return openErr
	}
	container, err = ensureMutationRecoveryDirectory(exports, containerName, true)
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		_ = container.Close()
		if !committed {
			_ = removeMutationRecoveryExport(c.home, exportID)
		}
	}()
	if err := copyMutationRecoveryExportObject(payload.parent(), payload.name, container, outputName); err != nil {
		return err
	}
	if err := container.Sync(); err != nil {
		return err
	}
	if !recoveryPayloadMatchesRecord(payload, record) {
		return errMutationObjectChanged
	}
	if err := verifyExistingMutationRecoveryExport(c.home, record, exportID, outputName); err != nil {
		return err
	}
	committed = true
	return nil
}

func copyMutationRecoveryExportObject(sourceParent *os.File, sourceName string, destinationParent *os.File, destinationName string) error {
	source, err := openMutationObjectAt(sourceParent, sourceName)
	if err != nil {
		return err
	}
	defer source.Close()
	before, err := source.Stat()
	if err != nil {
		return err
	}
	switch {
	case before.Mode().IsRegular():
		destination, err := createMutationNamedFileAt(destinationParent, destinationName, 0o600)
		if err != nil {
			return err
		}
		if _, err = source.Seek(0, io.SeekStart); err == nil {
			_, err = io.Copy(destination, source)
		}
		if err == nil {
			err = destination.Chmod(before.Mode().Perm())
		}
		if err == nil {
			err = destination.Sync()
		}
		closeErr := destination.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	case before.IsDir():
		if err := mkdirMutationNameAt(destinationParent, destinationName, 0o700); err != nil {
			return err
		}
		destination, err := openMutationDirectoryAt(destinationParent, destinationName)
		if err != nil {
			return err
		}
		entries, readErr := source.ReadDir(-1)
		if readErr != nil {
			_ = destination.Close()
			return readErr
		}
		sort.Slice(entries, func(left, right int) bool { return entries[left].Name() < entries[right].Name() })
		for _, entry := range entries {
			if err := copyMutationRecoveryExportObject(source, entry.Name(), destination, entry.Name()); err != nil {
				_ = destination.Close()
				return err
			}
		}
		if err := destination.Chmod(before.Mode().Perm()); err != nil {
			_ = destination.Close()
			return err
		}
		if err := destination.Sync(); err != nil {
			_ = destination.Close()
			return err
		}
		if err := destination.Close(); err != nil {
			return err
		}
	default:
		// File Provider mutation payloads are regular files or directories.
		// Reject links and special files rather than exporting an object that
		// could resolve outside the private snapshot.
		return errMutationObjectTypeUnsupported
	}
	after, err := source.Stat()
	if err != nil || !sameMutationFileMetadata(before, after) {
		return errMutationObjectChanged
	}
	current, err := openMutationObjectAt(sourceParent, sourceName)
	if err != nil {
		return errMutationObjectChanged
	}
	currentInfo, statErr := current.Stat()
	_ = current.Close()
	if statErr != nil || !sameMutationFileMetadata(after, currentInfo) {
		return errMutationObjectChanged
	}
	return nil
}

func verifyExistingMutationRecoveryExport(home string, record mutationRecoveryRecord, exportID, outputName string) error {
	relative := "Bridge/" + mutationRecoveryExportsName + "/" + mutationRecoveryExportPrefix + exportID + "/" + outputName
	exported, err := openMutationPath(home, relative)
	if err != nil {
		return err
	}
	defer exported.close()
	state, err := captureMutationObjectAt(exported)
	if err != nil {
		return err
	}
	kind := "file"
	if state.info.IsDir() {
		kind = "directory"
	}
	if kind != record.PayloadKind || state.bytes != record.ByteCount ||
		fmt.Sprintf("%x", state.digest[:]) != record.ContentDigest {
		return errMutationObjectChanged
	}
	container := exported.parent()
	if _, err := container.Seek(0, 0); err != nil {
		return err
	}
	entries, err := container.ReadDir(-1)
	if err != nil || len(entries) != 1 || entries[0].Name() != outputName {
		return errors.New("mutation recovery export container is not exact")
	}
	return nil
}

func removeMutationRecoveryExport(home, exportID string) error {
	if !validMutationRecoveryExportID(exportID) {
		return errors.New("mutation recovery export identifier is invalid")
	}
	relative := "Bridge/" + mutationRecoveryExportsName + "/" + mutationRecoveryExportPrefix + exportID
	exported, err := openMutationPath(home, relative)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer exported.close()
	if mutationPathMissingAt(exported) {
		return nil
	}
	if err := removeMutationRecoveryObject(exported); err != nil {
		return err
	}
	return exported.parent().Sync()
}

func validMutationRecoveryExportID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, value := range []byte(value) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if value != '-' {
				return false
			}
			continue
		}
		digit := value >= '0' && value <= '9'
		lowerHex := value >= 'a' && value <= 'f'
		if !digit && !lowerHex {
			return false
		}
	}
	return true
}

func validMutationRecoveryExportName(value string) bool {
	return value != "" && value != "." && value != ".." && len(value) <= 180 &&
		!strings.ContainsAny(value, `/\\`) && !strings.ContainsRune(value, '\x00') &&
		strings.IndexFunc(value, func(r rune) bool { return r < 0x20 || r == 0x7f }) == -1
}

func validMutationRecoveryStatus(value string) bool {
	switch value {
	case mutationRecoveryStatusPrepared, mutationRecoveryStatusRetained,
		mutationRecoveryStatusConflict, mutationRecoveryStatusDisposalApproved:
		return true
	default:
		return false
	}
}
