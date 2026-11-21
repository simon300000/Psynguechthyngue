// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/syncthing/syncthing/lib/config"
)

// evictLocalContentLocked removes only this device's materialized bytes. It
// never creates a Syncthing tombstone. Exact-version remote availability is
// validated by the model before local source authority is withdrawn.
func (c *Core) evictLocalContentLocked(request commandRequest) *responseError {
	if err := requireArgumentKeys(request.Arguments, "contentVersion", "systemEvictionObserved", "retentionTransactionID"); err != nil {
		return err
	}
	if err := c.requireRunningLocked(); err != nil {
		return err
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
		return commandError("folder_paused", "paused folders cannot evict local content")
	}
	if folder.FilesystemType != config.FilesystemTypeBasic {
		return commandError("unsupported_filesystem", "local eviction requires a standard basic folder")
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
		return commandError("unsupported_item_type", "local eviction requires a valid regular file")
	}
	contentVersion, _ := fileVersionTokens(global)
	if versionErr := compareBaseVersion(
		request.Arguments["contentVersion"],
		contentVersion,
		"contentVersion",
	); versionErr != nil {
		return versionErr
	}
	systemEvictionObserved := false
	if value, ok := request.Arguments["systemEvictionObserved"]; ok {
		if value != "true" {
			return commandError("invalid_request", "systemEvictionObserved must be true when present")
		}
		systemEvictionObserved = true
	}

	rootInfo, err := os.Lstat(folder.Path)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return commandError("invalid_folder_root", "folder root must be an existing real directory")
	}
	root, err := filepath.EvalSymlinks(folder.Path)
	if err != nil || root == string(filepath.Separator) {
		return commandError("invalid_folder_root", "folder root could not be bound safely")
	}
	pathRef, openErr := openMutationPath(root, relativePath)
	if openErr != nil && !errors.Is(openErr, os.ErrNotExist) {
		return commandError("invalid_path", openErr.Error())
	}
	if pathRef != nil {
		defer pathRef.close()
		handle, handleErr := openMutationObjectAt(pathRef.parent(), pathRef.name)
		if handleErr != nil && !errors.Is(handleErr, os.ErrNotExist) {
			return commandError("invalid_path", handleErr.Error())
		}
		if handle != nil {
			info, statErr := handle.Stat()
			_ = handle.Close()
			if statErr != nil || !info.Mode().IsRegular() {
				return commandError("unsupported_item_type", "local eviction requires a regular file")
			}
			if systemEvictionObserved {
				return commandError("content_still_materialized", "system eviction observation requires absent local content")
			}
		}
	}

	// The DB transition happens first. A crash after this point can leave
	// harmless bytes behind, but the device cannot advertise or serve them.
	var stateErr error
	if systemEvictionObserved {
		stateErr = c.runtime.app.Internals.SetLocalContentUnavailableAfterSystemEviction(
			folder.ID,
			relativePath,
			global.Version.String(),
		)
	} else {
		stateErr = c.runtime.app.Internals.SetLocalContentUnavailable(
			folder.ID,
			relativePath,
			global.Version.String(),
		)
	}
	if stateErr != nil {
		return commandError("local_content_state_failed", stateErr.Error())
	}
	if pathRef != nil {
		if err := unlinkMutationAt(pathRef, false); err != nil && !errors.Is(err, os.ErrNotExist) {
			return commandError("evict_failed", err.Error())
		}
		if err := pathRef.parent().Sync(); err != nil {
			return commandError("evict_failed", err.Error())
		}
	}
	c.generation++
	return nil
}
