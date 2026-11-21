// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/syncthing/syncthing/lib/config"
)

// materializeLocalContentLocked installs one exact global-index regular file
// into the managed Syncthing root. The ordinary puller is disabled by the
// materialize session's effective Send Only folder, so no unrelated payload is
// downloaded. Source authority is published only after a second full hash in
// SetLocalContentAvailable verifies the committed file.
func (c *Core) materializeLocalContentLocked(request commandRequest, onDemand bool) *responseError {
	if err := requireArgumentKeys(request.Arguments, "contentVersion"); err != nil {
		return err
	}
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if c.session == nil || c.session.Mode != sessionModeNetwork || c.session.NetworkOperation != networkOperationMaterialize {
		return commandError("wrong_session_mode", "local materialization requires a materialize network session")
	}
	if err := validateFolderID(request.FolderID); err != nil {
		return err
	}
	if request.ItemID == "" {
		return commandError("invalid_item_id", "itemID is required")
	}
	folder, ok := c.runtime.configuration.Folder(request.FolderID)
	if !ok {
		return commandError("folder_not_found", "folder is not configured")
	}
	if folder.Paused {
		return commandError("folder_paused", "paused folders cannot materialize content")
	}
	if folder.FilesystemType != config.FilesystemTypeBasic {
		return commandError("unsupported_filesystem", "local materialization requires a standard basic folder")
	}
	relativePath, ok := c.itemRegistry.pathForItem(folder.ID, request.ItemID)
	if !ok {
		return commandError("item_not_found", "itemID is not registered for this folder")
	}
	if _, pathErr := validateRelativePath(relativePath, false); pathErr != nil {
		return pathErr
	}
	global, found, err := c.runtime.app.Internals.GlobalFileInfo(folder.ID, relativePath)
	if err != nil {
		return commandError("index_read_failed", err.Error())
	}
	if !found || global.IsDeleted() {
		return commandError("item_not_found", "item is not present in the global index")
	}
	if global.IsDirectory() || global.IsSymlink() || global.IsInvalid() {
		return commandError("unsupported_item_type", "local materialization requires a valid regular file")
	}
	contentVersion, _ := fileVersionTokens(global)
	if versionErr := compareBaseVersion(
		request.Arguments["contentVersion"], contentVersion, "contentVersion",
	); versionErr != nil {
		return versionErr
	}

	rootInfo, err := os.Lstat(folder.Path)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return commandError("invalid_folder_root", "folder root must be an existing real directory")
	}
	root, err := filepath.EvalSymlinks(folder.Path)
	if err != nil || root == string(filepath.Separator) {
		return commandError("invalid_folder_root", "folder root could not be bound safely")
	}
	pathRef, err := openMutationPathWithDirectoryCreation(
		root,
		relativePath,
		func(prefix string) error {
			indexed, found, err := c.runtime.app.Internals.GlobalFileInfo(folder.ID, prefix)
			if err != nil {
				return err
			}
			if !found || indexed.IsDeleted() || indexed.IsInvalid() || !indexed.IsDirectory() || indexed.IsSymlink() {
				return errors.New("materialization ancestor is not an exact global directory")
			}
			return nil
		},
	)
	if err != nil {
		return commandError("invalid_path", err.Error())
	}
	defer pathRef.close()

	existing, existingErr := openMutationObjectAt(pathRef.parent(), pathRef.name)
	if existingErr == nil {
		info, statErr := existing.Stat()
		_ = existing.Close()
		if statErr != nil || !info.Mode().IsRegular() {
			return commandError("unsupported_item_type", "materialization destination is not a regular file")
		}
		if err := c.runtime.app.Internals.SetLocalContentAvailable(
			folder.ID, relativePath, global.Version.String(), onDemand,
		); err != nil {
			return commandError("version_conflict", "existing local content does not match the requested global version")
		}
		c.generation++
		return nil
	}
	if !errors.Is(existingErr, os.ErrNotExist) {
		return commandError("invalid_path", existingErr.Error())
	}

	temporaryName, temporary, err := createMutationTemporaryAt(pathRef.parent())
	if err != nil {
		return commandError("materialization_write_failed", err.Error())
	}
	temporaryPath := pathRef.withName(temporaryName)
	keepTemporary := true
	defer func() {
		if keepTemporary {
			_ = unlinkMutationAt(temporaryPath, false)
		}
	}()
	closed := false
	defer func() {
		if !closed {
			_ = temporary.Close()
		}
	}()

	var covered int64
	for blockNumber, block := range global.Blocks {
		if c.stopRequested.Load() {
			return commandError("cancelled", "local materialization was cancelled")
		}
		if block.Offset != covered || block.Size < 0 || block.Offset+int64(block.Size) < block.Offset {
			return commandError("remote_read_unavailable", "global blocks do not form a canonical complete file")
		}
		ctx, cancel := context.WithTimeout(context.Background(), remoteReadTimeout)
		token := c.registerReadCancel(cancel)
		data, readErr := c.downloadVerifiedRemoteBlockLocked(
			ctx, folder.ID, global, blockNumber, block,
		)
		c.clearReadCancel(token)
		cancel()
		if readErr != nil {
			var rangeFailure *readRangeError
			if errors.As(readErr, &rangeFailure) {
				return commandError(rangeFailure.code, rangeFailure.message)
			}
			return commandError("remote_read_unavailable", readErr.Error())
		}
		if err := writeMaterializedBlock(temporary, data); err != nil {
			return commandError("materialization_write_failed", err.Error())
		}
		covered += int64(len(data))
	}
	if covered != global.Size {
		return commandError("remote_read_unavailable", "global blocks do not cover the complete file")
	}
	mode := os.FileMode(global.Permissions & 0o777)
	if mode == 0 {
		mode = 0o600
	}
	mode |= 0o600
	if err := temporary.Chmod(mode); err != nil {
		return commandError("materialization_write_failed", err.Error())
	}
	if err := temporary.Sync(); err != nil {
		return commandError("materialization_write_failed", err.Error())
	}
	if err := temporary.Close(); err != nil {
		return commandError("materialization_write_failed", err.Error())
	}
	closed = true
	if err := revalidateMutationPaths(temporaryPath, pathRef); err != nil {
		return commandError("version_conflict", "materialization ancestor binding changed before commit")
	}
	if err := renameNoReplaceAt(temporaryPath, pathRef); err != nil {
		return commandError("version_conflict", "local content appeared before materialization committed")
	}
	keepTemporary = false
	if err := pathRef.parent().Sync(); err != nil {
		return commandError("materialization_write_failed", err.Error())
	}
	if err := c.runtime.app.Internals.SetLocalContentAvailable(
		folder.ID, relativePath, global.Version.String(), onDemand,
	); err != nil {
		// Exact bytes remain harmlessly present but are not advertised as a
		// source. A retry re-verifies them and publishes the local state.
		return commandError("local_content_state_failed", err.Error())
	}
	c.generation++
	return nil
}

func writeMaterializedBlock(destination io.Writer, data []byte) error {
	for len(data) > 0 {
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
