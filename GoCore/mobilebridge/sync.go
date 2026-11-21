// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"strconv"
	"time"

	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	defaultSyncTimeout = 3 * time.Second
	maxSyncTimeout     = 15 * time.Second
	defaultSyncSettle  = 250 * time.Millisecond
	maxSyncSettle      = time.Second
)

type syncQuiescenceState uint8

const (
	syncQuiescenceIncomplete syncQuiescenceState = iota
	syncQuiescenceProofUnavailable
	syncQuiescenceCurrent
)

// syncLocked defines a bounded, direction-bound Syncthing run slice. It
// triggers real scans, leaves the normal connection/index/puller services
// running, and applies operation-specific local/remote completion checks after
// every configured, unpaused peer has connected and supplied a current index
// proof. It never claims that an offline or otherwise unverified peer is
// synchronized; payload directions are also enforced below the bridge by the
// model request gates installed before runtime start.
func (c *Core) syncLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if c.networkByteLimitReachedLocked() {
		return commandError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
	}
	operation := networkOperationSync
	if c.session != nil {
		operation = c.session.NetworkOperation
		if request.Command != operation {
			return commandError("operation_scope_mismatch", "the command does not match the active network operation")
		}
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "sync does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "folderID", "timeoutMS", "settleMS"); err != nil {
		return err
	}
	timeout, timeoutErr := parseBoundedDuration(request.Arguments["timeoutMS"], defaultSyncTimeout, maxSyncTimeout, "timeoutMS")
	if timeoutErr != nil {
		return timeoutErr
	}
	settle, settleErr := parseBoundedDuration(request.Arguments["settleMS"], defaultSyncSettle, maxSyncSettle, "settleMS")
	if settleErr != nil {
		return settleErr
	}
	var folderIDs []string
	if request.FolderID != "" || request.Arguments["folderID"] != "" {
		folderID, err := folderTarget(request)
		if err != nil {
			return err
		}
		folder, ok := c.runtime.configuration.Folder(folderID)
		if !ok {
			return commandError("folder_not_found", "folder is not configured")
		}
		if folder.Paused {
			return commandError("folder_paused", "paused folders cannot participate in a sync run slice")
		}
		folderIDs = []string{folderID}
	} else {
		for _, folder := range c.runtime.configuration.FolderList() {
			if !folder.Paused {
				folderIDs = append(folderIDs, folder.ID)
			}
		}
	}
	if len(folderIDs) == 0 {
		return commandError("no_active_folders", "sync requires at least one unpaused folder")
	}
	for _, folderID := range folderIDs {
		if err := c.scanFolderSubdirsLocked(folderID, nil); err != nil {
			if c.networkByteLimitReachedLocked() {
				return commandError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
			}
			if c.stopRequested.Load() {
				return commandError("sync_cancelled", "bounded sync run was cancelled")
			}
			return commandError("rescan_failed", err.Error())
		}
	}
	c.generation++
	if c.syncLoopStartedForTests != nil {
		close(c.syncLoopStartedForTests)
		c.syncLoopStartedForTests = nil
	}
	deadline := time.Now().Add(timeout)
	var quiescentSince time.Time
	for {
		if c.stopRequested.Load() {
			return commandError("sync_cancelled", "bounded sync run was cancelled by Stop or Close")
		}
		if c.networkByteLimitReachedLocked() {
			return commandError("network_byte_limit_reached", "the aggregate protocol byte limit was reached")
		}
		quiescence := c.syncFoldersQuiescentLocked(folderIDs, operation)
		if quiescence == syncQuiescenceCurrent {
			if quiescentSince.IsZero() {
				quiescentSince = time.Now()
			}
			if time.Since(quiescentSince) >= settle {
				return nil
			}
		} else {
			quiescentSince = time.Time{}
		}
		if time.Now().After(deadline) {
			if quiescence == syncQuiescenceProofUnavailable {
				return commandError("peer_index_proof_unavailable", "connected peer did not provide an authoritative complete remote-index proof; retry after indexing finishes or update the peer")
			}
			return commandError("sync_incomplete", "bounded sync run ended with folder progress incomplete or configured peer state offline-unverified")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (c *Core) syncFoldersQuiescentLocked(folderIDs []string, operation string) syncQuiescenceState {
	result := syncQuiescenceCurrent
	for _, folderID := range folderIDs {
		state, _, err := c.runtime.app.Internals.FolderState(folderID)
		if err != nil || state != "idle" {
			return syncQuiescenceIncomplete
		}
		if operation == networkOperationSync || operation == networkOperationDownload {
			local, err := c.runtime.app.Internals.Completion(c.localDeviceID, folderID)
			if err != nil || local.NeedBytes != 0 || local.NeedItems != 0 || local.NeedDeletes != 0 {
				return syncQuiescenceIncomplete
			}
		}
		folder, ok := c.runtime.configuration.Folder(folderID)
		if !ok {
			return syncQuiescenceIncomplete
		}
		for _, device := range folder.Devices {
			if device.DeviceID == c.localDeviceID {
				continue
			}
			configuredDevice, ok := c.runtime.configuration.Device(device.DeviceID)
			if !ok {
				return syncQuiescenceIncomplete
			}
			if configuredDevice.Paused {
				continue
			}
			if !c.syncPeerConnectedLocked(device.DeviceID) || c.runtime.syncPeerReadiness == nil {
				return syncQuiescenceIncomplete
			}
			switch c.runtime.syncPeerReadiness.state(device.DeviceID, folderID) {
			case model.RemoteIndexProofCurrent:
			case model.RemoteIndexProofPending:
				result = syncQuiescenceProofUnavailable
				continue
			default:
				return syncQuiescenceIncomplete
			}
			if operation == networkOperationSync || operation == networkOperationUpload {
				remote, err := c.runtime.app.Internals.Completion(device.DeviceID, folderID)
				if err != nil || remote.NeedBytes != 0 || remote.NeedItems != 0 || remote.NeedDeletes != 0 {
					return syncQuiescenceIncomplete
				}
			}
		}
	}
	return result
}

func (c *Core) syncPeerConnectedLocked(deviceID protocol.DeviceID) bool {
	if c.syncPeerConnectedForTests != nil {
		return c.syncPeerConnectedForTests(deviceID)
	}
	return c.runtime.app.Internals.IsConnectedTo(deviceID)
}

func parseBoundedDuration(value string, fallback, maximum time.Duration, field string) (time.Duration, *responseError) {
	if value == "" {
		return fallback, nil
	}
	milliseconds, err := strconv.Atoi(value)
	if err != nil || milliseconds < 1 || time.Duration(milliseconds)*time.Millisecond > maximum {
		return 0, commandError("invalid_request", field+" is outside the supported bound")
	}
	return time.Duration(milliseconds) * time.Millisecond, nil
}
