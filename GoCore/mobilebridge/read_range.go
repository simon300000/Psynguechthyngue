// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	maxReadRangeBytes  = 1 << 20
	maxRemoteBlockSize = 32 << 20
	remoteReadTimeout  = 30 * time.Second
)

type readRangeRequest struct {
	SchemaVersion                 int    `json:"schemaVersion"`
	RequestID                     string `json:"requestID"`
	SessionID                     string `json:"sessionID,omitempty"`
	TaskID                        string `json:"taskID,omitempty"`
	PlanDigest                    string `json:"planDigest,omitempty"`
	ExpectedConfigurationRevision string `json:"expectedConfigurationRevision,omitempty"`
	MaximumNetworkBytes           string `json:"maximumNetworkBytes,omitempty"`
	NetworkOperation              string `json:"networkOperation,omitempty"`
	FolderID                      string `json:"folderID"`
	ItemID                        string `json:"itemID"`
	Path                          string `json:"path,omitempty"`
	ContentVersion                string `json:"contentVersion"`
	Offset                        int64  `json:"offset"`
	Length                        int    `json:"length"`
}

type readRangePayload struct {
	Data []byte `json:"data"`
}

type readRangeError struct {
	code    string
	message string
}

func (e *readRangeError) Error() string {
	return fmt.Sprintf("mobilebridge[%s]: %s", e.code, e.message)
}

func rangeError(code, message string) error {
	return &readRangeError{code: code, message: message}
}

func readRangeRequestID(raw string) string {
	return envelopeRequestID(raw)
}

func readRangeSuccessEnvelope(requestID string, data []byte) string {
	return stableSuccessEnvelope(requestID, "readRange", readRangePayload{Data: data})
}

func readRangeFailureEnvelope(requestID, code string) string {
	return stableFailureEnvelope(
		requestID,
		"readRange",
		code,
		readRangePublicMessage(code),
	)
}

func readRangePublicMessage(code string) string {
	switch code {
	case "version_conflict":
		return "the indexed content changed before the requested bytes could be read"
	case "remote_read_unavailable":
		return "the requested content is not currently available from a verified replica"
	case "item_not_found", "folder_not_found":
		return "the requested indexed content is no longer available"
	case "core_not_running", "core_closed", "core_unavailable":
		return "the embedded core is not available for this read"
	case "cancelled":
		return "the read range request was cancelled"
	case "network_byte_limit_reached":
		return "the aggregate protocol byte limit was reached"
	case "internal_error":
		return "the embedded core could not complete the read"
	default:
		return "the read range request could not be completed"
	}
}

func (c *Core) readRangeJSONLocked(raw string) ([]byte, error) {
	var request readRangeRequest
	if err := decodeRequest(raw, &request); err != nil {
		return nil, rangeError("invalid_request", err.Error())
	}
	if validationErr := validateRequest(request.SchemaVersion, request.RequestID); validationErr != nil {
		return nil, rangeError(validationErr.Code, validationErr.Message)
	}
	if sessionErr := c.preflightDataSessionLocked(
		request.SessionID,
		request.TaskID,
		request.PlanDigest,
		request.ExpectedConfigurationRevision,
		request.MaximumNetworkBytes,
		request.NetworkOperation,
		request.FolderID,
		false,
	); sessionErr != nil {
		return nil, rangeError(sessionErr.Code, sessionErr.Message)
	}
	if runningErr := c.requireRunningLocked(); runningErr != nil {
		return nil, rangeError(runningErr.Code, runningErr.Message)
	}
	if folderErr := validateFolderID(request.FolderID); folderErr != nil {
		return nil, rangeError(folderErr.Code, folderErr.Message)
	}
	if request.ItemID == "" {
		return nil, rangeError("invalid_item_id", "itemID is required")
	}
	if request.Offset < 0 || request.Length < 0 || request.Length > maxReadRangeBytes {
		return nil, rangeError("invalid_range", "offset must be non-negative and length must be between 0 and 1048576")
	}
	if c.stopRequested.Load() {
		return nil, rangeError("cancelled", "read range was cancelled")
	}
	folder, ok := c.runtime.configuration.Folder(request.FolderID)
	if !ok {
		return nil, rangeError("folder_not_found", "folder is not configured")
	}
	if folder.FilesystemType != config.FilesystemTypeBasic {
		return nil, rangeError("unsupported_filesystem", "read range requires a standard basic folder")
	}
	relativePath, ok := c.itemRegistry.pathForItem(folder.ID, request.ItemID)
	if !ok {
		return nil, rangeError("item_not_found", "itemID is not registered for this folder")
	}
	if request.Path != "" && request.Path != relativePath {
		return nil, rangeError("item_path_mismatch", "path does not match itemID")
	}
	if _, pathErr := validateRelativePath(relativePath, false); pathErr != nil {
		return nil, rangeError(pathErr.Code, pathErr.Message)
	}
	rootInfo, err := os.Lstat(folder.Path)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return nil, rangeError("invalid_folder_root", "folder root must be an existing real directory")
	}
	root, err := filepath.EvalSymlinks(folder.Path)
	if err != nil {
		return nil, rangeError("invalid_folder_root", "folder root cannot be resolved safely")
	}
	localPath, localInfo, localErr := safeExisting(root, relativePath)
	if localErr == nil {
		// A present local file is rescanned before version comparison. A missing
		// file is intentionally not scanned here: treating a remote-only item as
		// a local deletion could propagate the exact opposite of a read request.
		if err := c.scanFolderSubdirsLocked(folder.ID, []string{relativePath}); err != nil {
			if c.stopRequested.Load() {
				return nil, rangeError("cancelled", "read range was cancelled")
			}
			return nil, rangeError("rescan_failed", err.Error())
		}
	} else if localErr.Code != "item_not_found" {
		return nil, rangeError(localErr.Code, localErr.Message)
	}
	file, found, err := c.runtime.app.Internals.GlobalFileInfo(folder.ID, relativePath)
	if err != nil {
		return nil, rangeError("index_read_failed", err.Error())
	}
	if !found || file.IsDeleted() {
		return nil, rangeError("item_not_found", "item is not present in the global index")
	}
	if file.IsDirectory() || file.IsSymlink() || file.IsInvalid() {
		return nil, rangeError("unsupported_item_type", "read range requires a valid regular file")
	}
	contentVersion, _ := fileVersionTokens(file)
	if versionErr := compareBaseVersion(request.ContentVersion, contentVersion, "contentVersion"); versionErr != nil {
		return nil, rangeError(versionErr.Code, versionErr.Message)
	}
	end := request.Offset + int64(request.Length)
	if end < request.Offset || end > file.Size {
		return nil, rangeError("invalid_range", "requested range exceeds the indexed file size")
	}
	if request.Length == 0 {
		if c.session != nil && c.session.NetworkOperation == networkOperationLocalContent && localErr != nil {
			return nil, rangeError("local_content_unavailable", "the exact content is not present in managed storage")
		}
		return []byte{}, nil
	}
	if localErr == nil {
		if !localInfo.Mode().IsRegular() {
			return nil, rangeError("unsupported_item_type", "local item is not a regular file")
		}
		return readVerifiedLocalRange(localPath, localInfo, file, request.Offset, request.Length)
	}
	if c.session != nil && c.session.NetworkOperation == networkOperationLocalContent {
		return nil, rangeError("local_content_unavailable", "the exact content is not present in managed storage")
	}
	return c.readRemoteRangeLocked(folder.ID, file, request.Offset, request.Length)
}

func readVerifiedLocalRange(path string, expected os.FileInfo, indexed protocol.FileInfo, offset int64, length int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, rangeError("local_read_failed", err.Error())
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(opened, expected) {
		return nil, rangeError("local_read_failed", "local file changed during safe open")
	}
	if indexed.Size > 0 && len(indexed.Blocks) == 0 {
		return nil, rangeError("local_read_failed", "indexed file has no verifiable blocks")
	}
	end := offset + int64(length)
	result := make([]byte, length)
	written := 0
	for _, block := range indexed.Blocks {
		blockEnd := block.Offset + int64(block.Size)
		if blockEnd <= offset || block.Offset >= end {
			continue
		}
		if block.Size < 0 || block.Size > maxRemoteBlockSize || blockEnd < block.Offset {
			return nil, rangeError("local_read_failed", "indexed file contains an invalid or overlarge block")
		}
		blockData := make([]byte, block.Size)
		if _, err := file.ReadAt(blockData, block.Offset); err != nil && !errors.Is(err, io.EOF) {
			return nil, rangeError("local_read_failed", err.Error())
		}
		digest := sha256.Sum256(blockData)
		if !bytes.Equal(digest[:], block.Hash) {
			return nil, rangeError("version_conflict", "local file changed after its indexed version was selected")
		}
		copyStart := max64(offset, block.Offset)
		copyEnd := min64(end, blockEnd)
		sourceStart := copyStart - block.Offset
		destinationStart := copyStart - offset
		written += copy(result[destinationStart:destinationStart+(copyEnd-copyStart)], blockData[sourceStart:sourceStart+(copyEnd-copyStart)])
	}
	if written != length {
		return nil, rangeError("local_read_failed", "indexed blocks did not cover the complete requested range")
	}
	return result, nil
}

func (c *Core) readRemoteRangeLocked(folderID string, file protocol.FileInfo, offset int64, length int) ([]byte, error) {
	if file.Size > 0 && len(file.Blocks) == 0 {
		return nil, rangeError("remote_read_unavailable", "global file metadata has no downloadable blocks")
	}
	ctx, cancel := context.WithTimeout(context.Background(), remoteReadTimeout)
	token := c.registerReadCancel(cancel)
	defer func() {
		c.clearReadCancel(token)
		cancel()
	}()
	end := offset + int64(length)
	result := make([]byte, length)
	written := 0
	for blockNumber, block := range file.Blocks {
		if errors.Is(ctx.Err(), context.Canceled) || c.stopRequested.Load() {
			return nil, rangeError("cancelled", "read range was cancelled")
		}
		blockEnd := block.Offset + int64(block.Size)
		if blockEnd <= offset || block.Offset >= end {
			continue
		}
		if block.Size < 0 || block.Size > maxRemoteBlockSize || blockEnd < block.Offset {
			return nil, rangeError("remote_read_unavailable", "global index contains an invalid or overlarge block")
		}
		blockData, err := c.downloadVerifiedRemoteBlockLocked(ctx, folderID, file, blockNumber, block)
		if err != nil {
			return nil, err
		}
		copyStart := max64(offset, block.Offset)
		copyEnd := min64(end, blockEnd)
		sourceStart := copyStart - block.Offset
		destinationStart := copyStart - offset
		copied := copy(result[destinationStart:destinationStart+(copyEnd-copyStart)], blockData[sourceStart:sourceStart+(copyEnd-copyStart)])
		written += copied
	}
	if errors.Is(ctx.Err(), context.Canceled) || c.stopRequested.Load() {
		return nil, rangeError("cancelled", "read range was cancelled")
	}
	if written != length {
		return nil, rangeError("remote_read_unavailable", "global blocks did not cover the complete requested range")
	}
	return result, nil
}

func (c *Core) downloadVerifiedRemoteBlockLocked(
	ctx context.Context,
	folderID string,
	file protocol.FileInfo,
	blockNumber int,
	block protocol.BlockInfo,
) ([]byte, error) {
	if block.Size < 0 || block.Size > maxRemoteBlockSize {
		return nil, rangeError("remote_read_unavailable", "global index contains an invalid or overlarge block")
	}
	if block.IsEmpty() {
		return make([]byte, block.Size), nil
	}
	if c.networkByteLimitReachedLocked() {
		return nil, rangeError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
	}
	availability, err := c.runtime.app.Internals.BlockAvailability(folderID, file, block)
	if err != nil {
		return nil, rangeError("remote_read_unavailable", err.Error())
	}
	var lastErr error
	for _, candidate := range availability {
		if candidate.FromTemporary || candidate.ID == c.localDeviceID {
			continue
		}
		if c.networkByteLimitReachedLocked() {
			return nil, rangeError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
		}
		downloaded, err := c.runtime.app.Internals.DownloadBlock(
			ctx, candidate.ID, folderID, file.Name, blockNumber, block, false,
		)
		if err != nil {
			if errors.Is(ctx.Err(), context.Canceled) || c.stopRequested.Load() {
				return nil, rangeError("cancelled", "read range was cancelled")
			}
			if c.networkByteLimitReachedLocked() {
				return nil, rangeError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
			}
			lastErr = err
			continue
		}
		if len(downloaded) != block.Size {
			lastErr = errors.New("peer returned a block with the wrong length")
			continue
		}
		digest := sha256.Sum256(downloaded)
		if !bytes.Equal(digest[:], block.Hash) {
			lastErr = errors.New("peer returned a block that failed SHA-256 verification")
			continue
		}
		return downloaded, nil
	}
	if errors.Is(ctx.Err(), context.Canceled) || c.stopRequested.Load() {
		return nil, rangeError("cancelled", "read range was cancelled")
	}
	if lastErr == nil {
		lastErr = errors.New("no connected verified replica is available")
	}
	return nil, rangeError("remote_read_unavailable", lastErr.Error())
}

func min64(left, right int64) int64 {
	if left < right {
		return left
	}
	return right
}

func max64(left, right int64) int64 {
	if left > right {
		return left
	}
	return right
}
