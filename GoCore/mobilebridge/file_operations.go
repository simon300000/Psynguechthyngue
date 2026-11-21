// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	maxRelativePathBytes  = 4096
	maxPathComponentBytes = 255
)

func validateRelativePath(value string, allowEmpty bool) (string, *responseError) {
	if value == "" && allowEmpty {
		return "", nil
	}
	if value == "" || len(value) > maxRelativePathBytes || !utf8.ValidString(value) {
		return "", commandError("invalid_path", "relative path must contain between 1 and 4096 valid UTF-8 bytes")
	}
	if strings.HasPrefix(value, "/") || filepath.IsAbs(value) || strings.Contains(value, "\\") {
		return "", commandError("invalid_path", "relative path must not be absolute or contain backslashes")
	}
	components := strings.Split(value, "/")
	for _, component := range components {
		if component == "" || component == "." || component == ".." || len(component) > maxPathComponentBytes {
			return "", commandError("invalid_path", "relative path contains an empty, dot, parent, or overlong component")
		}
		if component == config.DefaultMarkerName || component == ".stversions" || component == ".stignore" || strings.HasPrefix(component, ".syncthing.") {
			return "", commandError("protected_path", "Syncthing internal paths cannot be mutated through the bridge")
		}
		for _, character := range component {
			if unicode.IsControl(character) || character == ':' {
				return "", commandError("invalid_path", "relative path contains a control character or colon")
			}
		}
	}
	if cleaned := path.Clean(value); cleaned != value || cleaned == "." {
		return "", commandError("invalid_path", "relative path is not in normalized slash form")
	}
	return value, nil
}

func validateFilename(value string) (string, *responseError) {
	if strings.Contains(value, "/") || strings.Contains(value, "\\") {
		return "", commandError("invalid_path", "filename must contain exactly one path component")
	}
	return validateRelativePath(value, false)
}

func (c *Core) createItemLocked(request commandRequest) *responseError {
	folder, root, err := c.writableFolderLocked(request.FolderID)
	if err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "create does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "parentIdentifier", "filename", "isDirectory", "fileProviderOperation", "stagedContentToken"); err != nil {
		return err
	}
	if request.Arguments["fileProviderOperation"] != "createAndPropagate" {
		return commandError("invalid_request", "fileProviderOperation must be createAndPropagate")
	}
	filename, filenameErr := validateFilename(request.Arguments["filename"])
	if filenameErr != nil {
		return filenameErr
	}
	parent, parentErr := c.resolveParentIdentifierLocked(folder, request.Arguments["parentIdentifier"])
	if parentErr != nil {
		return parentErr
	}
	relativePath, pathErr := validateRelativePath(path.Join(parent, filename), false)
	if pathErr != nil {
		return pathErr
	}
	isDirectory, boolErr := parseBoolean(request.Arguments["isDirectory"], "isDirectory")
	if boolErr != nil {
		return boolErr
	}
	destination, destinationErr := safeDestination(root, relativePath)
	if destinationErr != nil {
		return destinationErr
	}
	if collisionErr := rejectCanonicalSiblingCollision(filepath.Dir(destination), filepath.Base(destination), ""); collisionErr != nil {
		return collisionErr
	}
	if _, statErr := os.Lstat(destination); statErr == nil {
		return commandError("destination_exists", "an item already exists at the destination path")
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return commandError("invalid_path", statErr.Error())
	}
	destinationRef, refErr := openMutationPath(root, relativePath)
	if refErr != nil {
		return commandError("invalid_path", refErr.Error())
	}
	defer destinationRef.close()
	if isDirectory {
		if request.Arguments["stagedContentToken"] != "" {
			return commandError("invalid_request", "directory create does not accept stagedContentToken")
		}
		if validationErr := destinationRef.revalidate(); validationErr != nil {
			return commandError("invalid_path", validationErr.Error())
		}
		if mkdirErr := mkdirMutationAt(destinationRef, 0o700); mkdirErr != nil {
			return commandError("create_failed", mkdirErr.Error())
		}
		if syncErr := destinationRef.parent().Sync(); syncErr != nil {
			_ = unlinkMutationAt(destinationRef, true)
			return commandError("create_failed", syncErr.Error())
		}
	} else {
		staged, stagedErr := c.resolveStagedContent(request.Arguments["stagedContentToken"])
		if stagedErr != nil {
			return stagedErr
		}
		if installErr := installNewStagedFile(staged, destinationRef); installErr != nil {
			return commandError("create_failed", installErr.Error())
		}
	}
	registryBefore := c.itemRegistry.snapshot()
	itemID, suppressed, registryErr := c.itemRegistry.itemID(folder.ID, relativePath, false)
	if registryErr != nil || suppressed {
		_ = removeCreatedItem(destinationRef, isDirectory)
		c.itemRegistry.restore(registryBefore)
		if registryErr == nil {
			registryErr = errors.New("new item was suppressed by stale identity state")
		}
		return commandError("item_identity_conflict", registryErr.Error())
	}
	_ = itemID
	if saveErr := c.itemRegistry.save(); saveErr != nil {
		_ = removeCreatedItem(destinationRef, isDirectory)
		c.itemRegistry.restore(registryBefore)
		return commandError("identity_registry_save_failed", saveErr.Error())
	}
	if scanErr := c.rescanAndVerifyPresentLocked(folder.ID, []string{relativePath}, relativePath, isDirectory); scanErr != nil {
		_ = removeCreatedItem(destinationRef, isDirectory)
		_ = c.itemRegistry.restoreAndSave(registryBefore)
		_ = c.scanFolderSubdirsLocked(folder.ID, []string{relativePath})
		return scanErr
	}
	c.generation++
	return nil
}

func (c *Core) modifyItemLocked(request commandRequest) *responseError {
	return c.modifyOrMoveItemLocked(request, false)
}

func (c *Core) moveItemLocked(request commandRequest) *responseError {
	return c.modifyOrMoveItemLocked(request, true)
}

func (c *Core) modifyOrMoveItemLocked(request commandRequest, requireMove bool) *responseError {
	folder, root, err := c.writableFolderLocked(request.FolderID)
	if err != nil {
		return err
	}
	if request.ItemID == "" {
		return commandError("invalid_item_id", "modify and move require itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "parentIdentifier", "filename", "fileProviderOperation", "stagedContentToken", "baseContentVersion", "baseMetadataVersion"); err != nil {
		return err
	}
	if request.Arguments["fileProviderOperation"] != "modifyAndPropagate" {
		return commandError("invalid_request", "fileProviderOperation must be modifyAndPropagate")
	}
	sourcePath, ok := c.itemRegistry.pathForItem(folder.ID, request.ItemID)
	if !ok {
		return commandError("item_not_found", "itemID is not registered for this folder")
	}
	sourcePath, pathErr := validateRelativePath(sourcePath, false)
	if pathErr != nil {
		return pathErr
	}
	current, baseErr := c.verifyBaseVersionsLocked(folder.ID, sourcePath, request.Arguments)
	if baseErr != nil {
		return baseErr
	}
	if current.IsSymlink() {
		return commandError("symlink_rejected", "symlink items cannot be modified or moved through the bridge")
	}
	source, sourceInfo, sourceErr := safeExisting(root, sourcePath)
	if sourceErr != nil {
		return sourceErr
	}
	if sourceInfo.IsDir() != current.IsDirectory() || !sourceInfo.IsDir() && !sourceInfo.Mode().IsRegular() {
		return commandError("item_type_changed", "local item type does not match the indexed regular file or directory")
	}
	sourceRef, refErr := openMutationPath(root, sourcePath)
	if refErr != nil {
		return mutationVersionConflict("the local item ancestor binding changed after validation")
	}
	defer sourceRef.close()
	baseline, baselineErr := captureMutationObjectAt(sourceRef)
	if baselineErr != nil || !sameMutationFileMetadata(sourceInfo, baseline.info) {
		return mutationVersionConflict("the local item changed after its indexed base version was selected")
	}
	filename, filenameErr := validateFilename(request.Arguments["filename"])
	if filenameErr != nil {
		return filenameErr
	}
	parent, parentErr := c.resolveParentIdentifierLocked(folder, request.Arguments["parentIdentifier"])
	if parentErr != nil {
		return parentErr
	}
	destinationPath, destinationPathErr := validateRelativePath(path.Join(parent, filename), false)
	if destinationPathErr != nil {
		return destinationPathErr
	}
	moving := sourcePath != destinationPath
	if requireMove && !moving {
		return commandError("invalid_request", "move must change the item path")
	}
	stagedToken := request.Arguments["stagedContentToken"]
	if !moving && stagedToken == "" {
		return commandError("invalid_request", "modify requires changed content or a changed filename")
	}
	if sourceInfo.IsDir() && stagedToken != "" {
		return commandError("invalid_request", "directory content cannot be replaced")
	}
	// Resolve and validate retained upload bytes before any rename or identity
	// update. An invalid/missing staging token is therefore a definite
	// precommit rejection and may be terminally acknowledged by Swift.
	staged := ""
	if stagedToken != "" {
		var stagedErr *responseError
		staged, stagedErr = c.resolveStagedContent(stagedToken)
		if stagedErr != nil {
			return stagedErr
		}
	}

	registryBefore := c.itemRegistry.snapshot()
	destination := source
	destinationRef := sourceRef
	var recovery *mutationRecoveryPlan
	if moving {
		if itemRegistryKey(folder.ID, sourcePath) == itemRegistryKey(folder.ID, destinationPath) {
			return commandError("path_identity_conflict", "source and destination collide by case or Unicode normalization")
		}
		var destinationErr *responseError
		destination, destinationErr = safeDestination(root, destinationPath)
		if destinationErr != nil {
			return destinationErr
		}
		ignoredName := ""
		if filepath.Dir(source) == filepath.Dir(destination) {
			ignoredName = filepath.Base(source)
		}
		if collisionErr := rejectCanonicalSiblingCollision(filepath.Dir(destination), filepath.Base(destination), ignoredName); collisionErr != nil {
			return collisionErr
		}
		if _, statErr := os.Lstat(destination); statErr == nil {
			return commandError("destination_exists", "an item already exists at the destination path")
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return commandError("invalid_path", statErr.Error())
		}
		destinationRef, refErr = openMutationPath(root, destinationPath)
		if refErr != nil {
			return mutationVersionConflict("the destination ancestor binding changed after validation")
		}
		defer destinationRef.close()
		if stagedToken != "" {
			recovery, baselineErr = prepareMutationRecovery(
				c.home,
				root,
				request,
				destinationPath,
				destinationRef,
				baseline,
			)
			if baselineErr != nil {
				return mutationFailure("internal_error", "the prior version could not be reserved for durable recovery", mutationPhasePrecommit, false)
			}
			defer recovery.close()
		}
		if moveFailure := moveMutationObjectCAS(
			"move",
			sourceRef,
			destinationRef,
			baseline,
			"move_failed",
			c.beforeMutationCommitForTests,
			c.afterMutationExchangeForTests,
			c.beforeMutationRollbackForTests,
		); moveFailure != nil {
			return moveFailure
		}
		if registryErr := c.itemRegistry.move(folder.ID, sourcePath, destinationPath, request.ItemID); registryErr != nil {
			_ = restoreQuarantinedMutationObject("move", destinationRef, sourceRef, c.beforeMutationRollbackForTests)
			c.itemRegistry.restore(registryBefore)
			return commandError("item_identity_conflict", registryErr.Error())
		}
		if saveErr := c.itemRegistry.save(); saveErr != nil {
			rollbackErr := restoreQuarantinedMutationObject("move", destinationRef, sourceRef, c.beforeMutationRollbackForTests)
			c.itemRegistry.restore(registryBefore)
			_ = c.itemRegistry.save()
			if rollbackErr != nil {
				return commandError("mutation_inconsistent", fmt.Sprintf("registry save failed and move rollback failed: %v; %v", saveErr, rollbackErr))
			}
			return commandError("identity_registry_save_failed", saveErr.Error())
		}
	}
	if stagedToken != "" && recovery == nil {
		recovery, baselineErr = prepareMutationRecovery(
			c.home,
			root,
			request,
			destinationPath,
			destinationRef,
			baseline,
		)
		if baselineErr != nil {
			return mutationFailure("internal_error", "the prior version could not be reserved for durable recovery", mutationPhasePrecommit, false)
		}
		defer recovery.close()
	}
	if stagedToken != "" {
		if installFailure := replaceMutationFileCAS(
			staged,
			destinationRef,
			baseline,
			recovery,
			c.beforeMutationCommitForTests,
			c.afterMutationExchangeForTests,
			c.beforeMutationRollbackForTests,
			nil,
			nil,
		); installFailure != nil {
			if moving {
				if rollbackErr := c.rollbackMoveRegistryAndFileCAS(destinationRef, sourceRef, baseline, registryBefore); rollbackErr != nil {
					return mutationCommitAmbiguous("the content replacement failed and the preceding move could not be rolled back safely; recoverable data was retained")
				}
			}
			return installFailure
		}
	}
	paths := []string{sourcePath}
	if moving {
		paths = append(paths, destinationPath)
	}
	if scanErr := c.rescanAndVerifyPresentLocked(folder.ID, paths, destinationPath, sourceInfo.IsDir()); scanErr != nil {
		return scanErr
	}
	if moving {
		old, found, globalErr := c.runtime.app.Internals.GlobalFileInfo(folder.ID, sourcePath)
		if globalErr != nil || !found || !old.IsDeleted() {
			return mutationFailure("propagation_not_indexed", "move source did not become a Syncthing tombstone", mutationPhasePostcommit, true)
		}
	}
	c.generation++
	return nil
}

func (c *Core) deleteItemLocked(request commandRequest) *responseError {
	folder, root, err := c.writableFolderLocked(request.FolderID)
	if err != nil {
		return err
	}
	if request.ItemID == "" {
		return commandError("invalid_item_id", "delete requires itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "fileProviderOperation", "baseContentVersion", "baseMetadataVersion", "propagatesToPeers", "recursive"); err != nil {
		return err
	}
	if operation := request.Arguments["fileProviderOperation"]; operation != "" && operation != "deleteAndPropagate" {
		return commandError("invalid_request", "fileProviderOperation must be deleteAndPropagate when present")
	}
	propagates, boolErr := parseBoolean(request.Arguments["propagatesToPeers"], "propagatesToPeers")
	if boolErr != nil || !propagates {
		return commandError("delete_must_propagate", "propagatesToPeers must be true")
	}
	recursive, recursiveErr := parseBoolean(request.Arguments["recursive"], "recursive")
	if recursiveErr != nil {
		return recursiveErr
	}
	sourcePath, ok := c.itemRegistry.pathForItem(folder.ID, request.ItemID)
	if !ok {
		return commandError("item_not_found", "itemID is not registered for this folder")
	}
	sourcePath, pathErr := validateRelativePath(sourcePath, false)
	if pathErr != nil {
		return pathErr
	}
	current, baseErr := c.verifyBaseVersionsLocked(folder.ID, sourcePath, request.Arguments)
	if baseErr != nil {
		return baseErr
	}
	if current.IsSymlink() {
		return commandError("symlink_rejected", "symlink items cannot be deleted through the bridge")
	}
	source, sourceInfo, sourceErr := safeExisting(root, sourcePath)
	if sourceErr != nil {
		return sourceErr
	}
	if sourceInfo.IsDir() != current.IsDirectory() || !sourceInfo.IsDir() && !sourceInfo.Mode().IsRegular() {
		return commandError("item_type_changed", "local item type does not match the indexed regular file or directory")
	}
	sourceRef, refErr := openMutationPath(root, sourcePath)
	if refErr != nil {
		return mutationVersionConflict("the local item ancestor binding changed after validation")
	}
	defer sourceRef.close()
	baseline, baselineErr := captureMutationObjectAt(sourceRef)
	if baselineErr != nil || !sameMutationFileMetadata(sourceInfo, baseline.info) {
		return mutationVersionConflict("the local item changed after its indexed base version was selected")
	}
	if sourceInfo.IsDir() && !recursive {
		entries, readErr := os.ReadDir(source)
		if readErr != nil {
			return commandError("delete_failed", readErr.Error())
		}
		if len(entries) != 0 {
			return commandError("directory_not_empty", "recursive must be true to delete a non-empty directory")
		}
	}
	recovery, recoveryErr := prepareMutationRecovery(
		c.home,
		root,
		request,
		sourcePath,
		sourceRef,
		baseline,
	)
	if recoveryErr != nil {
		return mutationFailure("internal_error", "the deleted version could not be reserved for durable recovery", mutationPhasePrecommit, false)
	}
	defer recovery.close()
	temporaryRef := sourceRef.withName(syncthingDeleteTemporaryName(filepath.Base(source)))
	if moveFailure := moveMutationObjectCAS(
		"delete",
		sourceRef,
		temporaryRef,
		baseline,
		"delete_failed",
		c.beforeMutationCommitForTests,
		c.afterMutationExchangeForTests,
		c.beforeMutationRollbackForTests,
	); moveFailure != nil {
		return moveFailure
	}
	registryBefore := c.itemRegistry.snapshot()
	if registryErr := c.itemRegistry.delete(folder.ID, sourcePath, request.ItemID); registryErr != nil {
		_ = restoreQuarantinedMutationObject("delete", temporaryRef, sourceRef, c.beforeMutationRollbackForTests)
		return commandError("item_identity_conflict", registryErr.Error())
	}
	if saveErr := c.itemRegistry.save(); saveErr != nil {
		rollbackErr := restoreQuarantinedMutationObject("delete", temporaryRef, sourceRef, c.beforeMutationRollbackForTests)
		c.itemRegistry.restore(registryBefore)
		_ = c.itemRegistry.save()
		if rollbackErr != nil {
			return commandError("mutation_inconsistent", fmt.Sprintf("registry save failed and delete rollback failed: %v; %v", saveErr, rollbackErr))
		}
		return commandError("identity_registry_save_failed", saveErr.Error())
	}
	if !mutationObjectMatchesAt(temporaryRef, baseline) {
		if retainErr := recovery.retain(
			temporaryRef,
			baseline,
			mutationRecoveryStatusConflict,
			false,
			nil,
			nil,
		); retainErr != nil && !errors.Is(retainErr, errMutationRecoveryRequiresManualCleanup) {
			return mutationCommitAmbiguous("the changed quarantine could not be indexed in durable recovery")
		}
		return mutationCommitAmbiguous("the quarantined item changed and requires explicit recovery review")
	}
	if retainErr := recovery.retain(
		temporaryRef,
		baseline,
		mutationRecoveryStatusRetained,
		true,
		nil,
		nil,
	); retainErr != nil {
		return mutationCommitAmbiguous("the deleted version could not be durably retained")
	}
	if scanErr := c.scanFolderSubdirsLocked(folder.ID, []string{sourcePath}); scanErr != nil {
		return mutationFailure("rescan_failed", scanErr.Error(), mutationPhasePostcommit, true)
	}
	deleted, found, globalErr := c.runtime.app.Internals.GlobalFileInfo(folder.ID, sourcePath)
	if globalErr != nil || !found || !deleted.IsDeleted() {
		return mutationFailure("propagation_not_indexed", "delete did not become a Syncthing tombstone", mutationPhasePostcommit, true)
	}
	c.generation++
	return nil
}

func (c *Core) writableFolderLocked(folderID string) (config.FolderConfiguration, string, *responseError) {
	if err := c.requireRunningLocked(); err != nil {
		return config.FolderConfiguration{}, "", err
	}
	if err := validateFolderID(folderID); err != nil {
		return config.FolderConfiguration{}, "", err
	}
	folder, ok := c.runtime.configuration.Folder(folderID)
	if !ok {
		return config.FolderConfiguration{}, "", commandError("folder_not_found", "folder is not configured")
	}
	if folder.Paused {
		return config.FolderConfiguration{}, "", commandError("folder_paused", "paused folders cannot be mutated")
	}
	if !folderSupportsFileMutations(folder) {
		return config.FolderConfiguration{}, "", commandError("folder_not_writable", "file mutations require a standard basic sendReceive or sendOnly folder")
	}
	rootInfo, err := os.Lstat(folder.Path)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return config.FolderConfiguration{}, "", commandError("invalid_folder_root", "folder root must be an existing real directory, not a symlink")
	}
	root, err := filepath.EvalSymlinks(folder.Path)
	if err != nil || root == string(filepath.Separator) {
		return config.FolderConfiguration{}, "", commandError("invalid_folder_root", "folder root cannot be resolved safely")
	}
	return folder, root, nil
}

func folderSupportsFileMutations(folder config.FolderConfiguration) bool {
	return (folder.Type == config.FolderTypeSendReceive || folder.Type == config.FolderTypeSendOnly) &&
		folder.FilesystemType == config.FilesystemTypeBasic
}

func (c *Core) resolveParentIdentifierLocked(folder config.FolderConfiguration, identifier string) (string, *responseError) {
	if identifier == bridgeFolderIdentifier(folder.ID) {
		return "", nil
	}
	if !strings.HasPrefix(identifier, "item-") || len(identifier) <= len("item-") {
		return "", commandError("invalid_parent", "parentIdentifier is not the configured folder root or a bridge item")
	}
	itemID := strings.TrimPrefix(identifier, "item-")
	parent, ok := c.itemRegistry.pathForItem(folder.ID, itemID)
	if !ok {
		return "", commandError("invalid_parent", "parent item is not registered in this folder")
	}
	file, found, err := c.runtime.app.Internals.GlobalFileInfo(folder.ID, parent)
	if err != nil || !found || file.IsDeleted() || !file.IsDirectory() {
		return "", commandError("invalid_parent", "parent item is not a live indexed directory")
	}
	return parent, nil
}

func bridgeFolderIdentifier(folderID string) string {
	digest := sha256.Sum256([]byte(folderID))
	return "folder-" + hex.EncodeToString(digest[:16])
}

func (c *Core) verifyBaseVersionsLocked(folderID, relativePath string, arguments map[string]string) (protocol.FileInfo, *responseError) {
	if scanErr := c.scanFolderSubdirsLocked(folderID, []string{relativePath}); scanErr != nil {
		return protocol.FileInfo{}, mutationFailure("rescan_failed", scanErr.Error(), mutationPhasePrecommit, false)
	}
	file, found, err := c.runtime.app.Internals.GlobalFileInfo(folderID, relativePath)
	if err != nil {
		return protocol.FileInfo{}, mutationFailure("index_read_failed", err.Error(), mutationPhasePrecommit, false)
	}
	if !found || file.IsDeleted() {
		return protocol.FileInfo{}, commandError("item_not_found", "item is not present in the global index")
	}
	content, metadata := fileVersionTokens(file)
	if err := compareBaseVersion(arguments["baseContentVersion"], content, "baseContentVersion"); err != nil {
		return protocol.FileInfo{}, err
	}
	if err := compareBaseVersion(arguments["baseMetadataVersion"], metadata, "baseMetadataVersion"); err != nil {
		return protocol.FileInfo{}, err
	}
	return file, nil
}

func compareBaseVersion(encoded string, current []byte, field string) *responseError {
	decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(decoded) != sha256.Size {
		return commandError("invalid_base_version", field+" must be base64 for exactly 32 bytes")
	}
	if subtle.ConstantTimeCompare(decoded, current) != 1 {
		return commandError("version_conflict", field+" no longer matches the indexed item")
	}
	return nil
}

func safeExisting(root, relativePath string) (string, os.FileInfo, *responseError) {
	components := strings.Split(relativePath, "/")
	current := root
	for index, component := range components {
		current = filepath.Join(current, component)
		if !pathContains(root, current) {
			return "", nil, commandError("path_escape", "item path escaped the folder root")
		}
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return "", nil, commandError("item_not_found", "item path does not exist locally")
		}
		if err != nil {
			return "", nil, commandError("invalid_path", err.Error())
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", nil, commandError("symlink_rejected", "item path or an ancestor is a symlink")
		}
		if index != len(components)-1 && !info.IsDir() {
			return "", nil, commandError("invalid_path", "item path ancestor is not a directory")
		}
		if index == len(components)-1 {
			return current, info, nil
		}
	}
	return "", nil, commandError("invalid_path", "folder root cannot be used as an item path")
}

func safeDestination(root, relativePath string) (string, *responseError) {
	parent := parentPath(relativePath)
	if parent != "" {
		_, info, err := safeExisting(root, parent)
		if err != nil {
			return "", err
		}
		if !info.IsDir() {
			return "", commandError("invalid_parent", "destination parent is not a directory")
		}
	}
	destination := filepath.Join(root, filepath.FromSlash(relativePath))
	if !pathContains(root, destination) || destination == root {
		return "", commandError("path_escape", "destination escaped the folder root")
	}
	return destination, nil
}

func rejectCanonicalSiblingCollision(directory, desiredName, ignoredExactName string) *responseError {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return commandError("invalid_parent", err.Error())
	}
	fold := cases.Fold()
	desiredKey := fold.String(norm.NFC.String(desiredName))
	for _, entry := range entries {
		if entry.Name() == ignoredExactName {
			continue
		}
		if fold.String(norm.NFC.String(entry.Name())) == desiredKey {
			return commandError("path_identity_conflict", "destination collides by case or Unicode normalization")
		}
	}
	return nil
}

func (c *Core) resolveStagedContent(token string) (string, *responseError) {
	parts := strings.Split(token, "/")
	if len(parts) != 2 || !validCanonicalUUID(parts[0]) || parts[1] != "contents" {
		return "", commandError("staged_content_invalid", "stagedContentToken must be <UUID>/contents")
	}
	rootInfo, err := os.Lstat(c.stagingDirectory)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", commandError("staged_content_invalid", "staging root must be an existing real directory")
	}
	root, err := filepath.EvalSymlinks(c.stagingDirectory)
	if err != nil {
		return "", commandError("staged_content_invalid", "staging root cannot be resolved safely")
	}
	directory := filepath.Join(root, parts[0])
	directoryInfo, err := os.Lstat(directory)
	if err != nil || !directoryInfo.IsDir() || directoryInfo.Mode()&os.ModeSymlink != 0 {
		return "", commandError("staged_content_invalid", "staged token directory is missing, not a directory, or a symlink")
	}
	staged := filepath.Join(directory, "contents")
	if !pathContains(root, staged) {
		return "", commandError("staged_content_invalid", "staged content escaped the staging root")
	}
	info, err := os.Lstat(staged)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", commandError("staged_content_invalid", "staged content must be a regular non-symlink file")
	}
	resolved, err := filepath.EvalSymlinks(staged)
	if err != nil || !pathContains(root, resolved) {
		return "", commandError("staged_content_invalid", "staged content real path escaped the staging root")
	}
	return resolved, nil
}

func validCanonicalUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			if !(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f') && !(character >= 'A' && character <= 'F') {
				return false
			}
		}
	}
	return true
}

func installNewStagedFile(staged string, destination *mutationPathRef) error {
	source, err := os.Open(staged)
	if err != nil {
		return err
	}
	defer source.Close()
	openedInfo, err := source.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() {
		return errors.New("opened staged content is not a regular file")
	}
	lstatInfo, err := os.Lstat(staged)
	if err != nil || lstatInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(openedInfo, lstatInfo) {
		return errors.New("staged content changed during validation")
	}
	temporaryName, temporary, err := createMutationTemporaryAt(destination.parent())
	if err != nil {
		return err
	}
	temporaryPath := destination.withName(temporaryName)
	defer unlinkMutationAt(temporaryPath, false)
	if _, err := io.Copy(temporary, source); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := revalidateMutationPaths(temporaryPath, destination); err != nil {
		return err
	}
	if err := renameNoReplaceAt(temporaryPath, destination); err != nil {
		return err
	}
	return destination.parent().Sync()
}

func syncDirectory(directory string) error {
	handle, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer handle.Close()
	return handle.Sync()
}

func (c *Core) rescanAndVerifyPresentLocked(folderID string, paths []string, expectedPath string, directory bool) *responseError {
	if err := c.scanFolderSubdirsLocked(folderID, paths); err != nil {
		return mutationFailure("rescan_failed", err.Error(), mutationPhasePostcommit, true)
	}
	file, found, err := c.runtime.app.Internals.GlobalFileInfo(folderID, expectedPath)
	if err != nil || !found || file.IsDeleted() || file.IsDirectory() != directory {
		return mutationFailure("propagation_not_indexed", "mutated item was not indexed with the expected type", mutationPhasePostcommit, true)
	}
	return nil
}

func removeCreatedItem(path *mutationPathRef, directory bool) error {
	if err := path.revalidate(); err != nil {
		return err
	}
	if err := unlinkMutationAt(path, directory); err != nil {
		return err
	}
	return path.parent().Sync()
}

func syncthingDeleteTemporaryName(base string) string {
	var random [8]byte
	_, _ = rand.Read(random[:])
	return ".syncthing." + base + "." + hex.EncodeToString(random[:]) + ".tmp"
}

func (c *Core) rollbackMoveRegistryAndFileCAS(destination, source *mutationPathRef, baseline mutationObjectState, registryBefore itemRegistryState) error {
	if !mutationObjectMatchesAt(destination, baseline) {
		return errMutationObjectChanged
	}
	fileErr := restoreQuarantinedMutationObject("move", destination, source, c.beforeMutationRollbackForTests)
	registryErr := c.itemRegistry.restoreAndSave(registryBefore)
	return errors.Join(fileErr, registryErr)
}
