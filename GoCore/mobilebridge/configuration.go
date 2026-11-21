// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	maxConfigurationNameBytes = 256
	maxConfigurationListItems = 64
)

type deviceConnectionStatistics struct {
	At            time.Time
	StartedAt     time.Time
	InBytesTotal  int64
	OutBytesTotal int64
	Connections   int
}

type deviceRateSample struct {
	Statistics             deviceConnectionStatistics
	UploadBytesPerSecond   int64
	DownloadBytesPerSecond int64
}

type deviceTransferRate struct {
	UploadBytesPerSecond   int64
	DownloadBytesPerSecond int64
}

func (c *Core) snapshotLocked() snapshotPayload {
	payload := snapshotPayload{
		CoreRevision:             coreRevision,
		Generation:               c.generation,
		GeneratedAt:              time.Now().UTC().Format(time.RFC3339Nano),
		DeviceID:                 c.deviceID,
		Lifecycle:                c.lifecycle,
		Running:                  c.lifecycle == lifecycleRunning,
		Devices:                  make([]deviceSnapshot, 0),
		Folders:                  make([]folderSnapshot, 0),
		PendingDevices:           make([]pendingDeviceSnapshot, 0),
		PendingFolders:           make([]pendingFolderSnapshot, 0),
		SuppressedPendingDevices: make([]suppressedPendingDeviceSnapshot, 0),
		SuppressedPendingFolders: make([]suppressedPendingFolderSnapshot, 0),
		Identity: identityPolicy{
			FormatVersion:    int(identityFormatVersion),
			PrivateKeyOnDisk: false,
		},
		NetworkPolicy: networkPolicy{
			ManagementHTTPEnabled: false,
			UsageReportingEnabled: false,
			CrashReportingEnabled: false,
			AutoUpgradeEnabled:    false,
		},
		ConfigurationRevision: c.configurationRevision,
	}
	if c.session != nil {
		session := *c.session
		payload.Session = &session
	}
	payload.PendingDevices, payload.PendingDeviceObservationScope = c.pendingDevices.snapshots(
		c.localDeviceID,
		map[protocol.DeviceID]struct{}{},
	)
	if c.runtime == nil || c.runtime.configuration == nil || c.lifecycle != lifecycleRunning {
		return payload
	}

	runtimeConfiguration := c.runtime.configuration.RawCopy()
	raw := runtimeConfiguration
	if (c.runtime.mode == sessionModeNetwork || c.runtime.mode == sessionModePendingFolderDiscovery) && c.runtime.canonicalConfiguration != nil {
		raw = c.runtime.canonicalConfiguration.Copy()
	}
	hasNetworkRuntime := c.runtime.app != nil && c.runtime.app.Internals != nil && c.runtime.mode != sessionModeConfiguration
	scopedFolderID := ""
	scopedOfferingDeviceID := protocol.EmptyDeviceID
	statusDevices := make(map[protocol.DeviceID]struct{})
	if c.session != nil && (c.session.Mode == sessionModeNetwork || c.session.Mode == sessionModePendingFolderObservation || c.session.Mode == sessionModePendingFolderDiscovery) {
		scopedFolderID = c.session.FolderID
		statusDevices[c.localDeviceID] = struct{}{}
		if c.session.Mode == sessionModePendingFolderObservation || c.session.Mode == sessionModePendingFolderDiscovery {
			if deviceID, err := protocol.DeviceIDFromString(c.session.OfferingDeviceID); err == nil {
				statusDevices[deviceID] = struct{}{}
				scopedOfferingDeviceID = deviceID
			}
		} else if folder, _, exists := runtimeConfiguration.Folder(scopedFolderID); exists {
			for _, device := range folder.Devices {
				statusDevices[device.DeviceID] = struct{}{}
			}
		}
	}
	configuredDevices := make(map[protocol.DeviceID]struct{}, len(raw.Devices))
	for _, device := range raw.Devices {
		configuredDevices[device.DeviceID] = struct{}{}
	}
	var suppressedDeviceIDs map[protocol.DeviceID]struct{}
	var suppressedFolderKeys map[suppressedPendingFolderKey]struct{}
	payload.SuppressedPendingDevices,
		payload.SuppressedPendingFolders,
		suppressedDeviceIDs,
		suppressedFolderKeys,
		payload.SuppressedPendingDevicesTruncated,
		payload.SuppressedPendingFoldersTruncated = suppressedPendingSnapshots(raw, c.localDeviceID)
	payload.SuppressedPendingStateAvailable = true
	excludedPendingDevices := make(map[protocol.DeviceID]struct{}, len(configuredDevices)+len(suppressedDeviceIDs))
	for deviceID := range configuredDevices {
		excludedPendingDevices[deviceID] = struct{}{}
	}
	for deviceID := range suppressedDeviceIDs {
		excludedPendingDevices[deviceID] = struct{}{}
	}
	if hasNetworkRuntime {
		c.pendingDevices.pruneConfigured(excludedPendingDevices)
		payload.PendingDevices, payload.PendingDeviceObservationScope = c.pendingDevices.snapshots(c.localDeviceID, excludedPendingDevices)
	} else {
		payload.PendingDevices = []pendingDeviceSnapshot{}
		payload.PendingDeviceObservationScope = "unavailable_in_configuration_session"
	}
	pendingFolderSnapshots := make(map[suppressedPendingFolderKey]pendingFolderSnapshot)
	if hasNetworkRuntime {
		if offers, err := c.pendingFolderOffersLocked(protocol.EmptyDeviceID); err == nil {
			payload.PendingFoldersAvailable = true
			for _, offer := range offers {
				if scopedFolderID != "" && offer.FolderID != scopedFolderID {
					continue
				}
				if scopedOfferingDeviceID != protocol.EmptyDeviceID && offer.OfferingDeviceID != scopedOfferingDeviceID {
					continue
				}
				if _, configured := configuredDevices[offer.OfferingDeviceID]; !configured {
					continue
				}
				key := suppressedPendingFolderKey{FolderID: offer.FolderID, OfferingDeviceID: offer.OfferingDeviceID}
				if _, suppressed := suppressedFolderKeys[key]; suppressed {
					continue
				}
				if configuredFolder, _, exists := raw.Folder(offer.FolderID); exists && configuredFolder.SharedWith(offer.OfferingDeviceID) {
					continue
				}
				pendingFolderSnapshots[key] = offer.snapshot()
			}
		}
	}
	if summaries, truncatedDevices, healthy := c.pendingFolderDiscoverySummaries.snapshot(); healthy {
		visibleSummaryState := false
		for _, summary := range summaries {
			deviceID, err := protocol.DeviceIDFromString(summary.OfferingDeviceID)
			if err != nil || deviceID == protocol.EmptyDeviceID {
				continue
			}
			if scopedFolderID != "" && summary.FolderID != scopedFolderID {
				continue
			}
			if scopedOfferingDeviceID != protocol.EmptyDeviceID && deviceID != scopedOfferingDeviceID {
				continue
			}
			if _, configured := configuredDevices[deviceID]; !configured {
				continue
			}
			key := suppressedPendingFolderKey{FolderID: summary.FolderID, OfferingDeviceID: deviceID}
			if _, suppressed := suppressedFolderKeys[key]; suppressed {
				continue
			}
			if _, _, configured := raw.Folder(summary.FolderID); configured {
				continue
			}
			visibleSummaryState = true
			if _, live := pendingFolderSnapshots[key]; !live {
				pendingFolderSnapshots[key] = summary.snapshot()
			}
		}
		for deviceID, truncated := range truncatedDevices {
			if !truncated {
				continue
			}
			if _, configured := configuredDevices[deviceID]; !configured {
				continue
			}
			if scopedOfferingDeviceID != protocol.EmptyDeviceID && deviceID != scopedOfferingDeviceID {
				continue
			}
			visibleSummaryState = true
			payload.PendingFoldersTruncated = true
		}
		if visibleSummaryState {
			payload.PendingFoldersAvailable = true
		}
	}
	payload.PendingFolders = make([]pendingFolderSnapshot, 0, min(len(pendingFolderSnapshots), maxPendingFolderSnapshots))
	for _, snapshot := range pendingFolderSnapshots {
		payload.PendingFolders = append(payload.PendingFolders, snapshot)
	}
	slices.SortFunc(payload.PendingFolders, func(left, right pendingFolderSnapshot) int {
		if comparison := strings.Compare(left.FolderID, right.FolderID); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.OfferingDeviceID, right.OfferingDeviceID)
	})
	if len(payload.PendingFolders) > maxPendingFolderSnapshots {
		payload.PendingFolders = payload.PendingFolders[:maxPendingFolderSnapshots]
		payload.PendingFoldersTruncated = true
	}
	// Keep runtime-only fields unavailable in a configuration session while
	// still projecting the complete authoritative canonical configuration.
	lastSeenByDevice := make(map[protocol.DeviceID]time.Time)
	transferRatesByDevice := make(map[protocol.DeviceID]deviceTransferRate)
	if hasNetworkRuntime {
		upstreamStatistics, _ := c.runtime.app.Internals.DeviceStatistics()
		for deviceID, entry := range upstreamStatistics {
			lastSeenByDevice[deviceID] = entry.LastSeen
		}
		transferRatesByDevice = c.deviceTransferRatesLocked()
	} else {
		clear(c.connectionRateSamples)
	}
	for _, device := range raw.Devices {
		local := device.DeviceID == c.localDeviceID
		_, scopedDevice := statusDevices[device.DeviceID]
		statusAvailable := hasNetworkRuntime && (scopedFolderID == "" || scopedDevice)
		entry := deviceSnapshot{
			DeviceID:  device.DeviceID.String(),
			Name:      device.Name,
			Addresses: append([]string(nil), device.Addresses...),
			Paused:    device.Paused,
			Connected: statusAvailable && (local || c.runtime.app.Internals.IsConnectedTo(device.DeviceID)),
			Local:     local,
		}
		if lastSeen, ok := lastSeenByDevice[device.DeviceID]; statusAvailable && ok && lastSeen.After(time.Unix(1, 0)) {
			entry.LastSeen = lastSeen.UTC().Format(time.RFC3339Nano)
		}
		if rates, ok := transferRatesByDevice[device.DeviceID]; statusAvailable && ok {
			entry.UploadBytesPerSecond = rates.UploadBytesPerSecond
			entry.DownloadBytesPerSecond = rates.DownloadBytesPerSecond
		}
		payload.Devices = append(payload.Devices, entry)
	}
	slices.SortFunc(payload.Devices, func(a, b deviceSnapshot) int {
		return strings.Compare(a.DeviceID, b.DeviceID)
	})
	deviceSnapshotIndex := make(map[protocol.DeviceID]int, len(payload.Devices))
	for index, device := range payload.Devices {
		deviceID, err := protocol.DeviceIDFromString(device.DeviceID)
		if err == nil {
			deviceSnapshotIndex[deviceID] = index
		}
	}

	for _, folder := range raw.Folders {
		entry := folderSnapshot{
			FolderID:        folder.ID,
			Label:           folder.Label,
			Path:            folder.Path,
			Type:            bridgeFolderType(folder.Type),
			Paused:          folder.Paused,
			DeviceIDs:       make([]string, 0, len(folder.Devices)),
			RescanIntervalS: folder.RescanIntervalS,
		}
		for _, folderDevice := range folder.Devices {
			entry.DeviceIDs = append(entry.DeviceIDs, folderDevice.DeviceID.String())
		}
		slices.Sort(entry.DeviceIDs)

		statusAvailable := hasNetworkRuntime && (scopedFolderID == "" || folder.ID == scopedFolderID)
		if folder.Paused && statusAvailable {
			entry.State = "paused"
		} else if statusAvailable {
			var statusErrors []string
			state, changedAt, stateErr := c.runtime.app.Internals.FolderState(folder.ID)
			if stateErr != nil {
				statusErrors = append(statusErrors, "state: "+stateErr.Error())
			} else {
				entry.State = state
				if !changedAt.IsZero() {
					entry.StateChangedAt = changedAt.UTC().Format(time.RFC3339Nano)
				}
			}

			localCompletion, completionErr := c.runtime.app.Internals.Completion(c.localDeviceID, folder.ID)
			if completionErr != nil {
				statusErrors = append(statusErrors, "local completion: "+completionErr.Error())
			} else {
				entry.CompletionPercent = localCompletion.CompletionPct
				entry.PendingDownloadBytes = maxInt64(localCompletion.NeedBytes, 0)
			}

			// This is the sum of bytes each configured peer still needs from the
			// folder. The same file can therefore count once per peer.
			for _, folderDevice := range folder.Devices {
				if folderDevice.DeviceID == c.localDeviceID {
					continue
				}
				remoteCompletion, remoteErr := c.runtime.app.Internals.Completion(folderDevice.DeviceID, folder.ID)
				if remoteErr != nil {
					statusErrors = append(statusErrors, "remote completion: "+remoteErr.Error())
					continue
				}
				pendingBytes := maxInt64(remoteCompletion.NeedBytes, 0)
				entry.PendingUploadBytes = saturatingAdd(entry.PendingUploadBytes, pendingBytes)
				if index, ok := deviceSnapshotIndex[folderDevice.DeviceID]; ok {
					payload.Devices[index].PendingBytes = saturatingAdd(
						payload.Devices[index].PendingBytes,
						pendingBytes,
					)
				}
			}
			entry.Error = strings.Join(statusErrors, "; ")
		}
		payload.Folders = append(payload.Folders, entry)
	}
	slices.SortFunc(payload.Folders, func(a, b folderSnapshot) int {
		return strings.Compare(a.FolderID, b.FolderID)
	})
	return payload
}

func (c *Core) addDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "addDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "deviceID", "name", "addresses", "paused"); err != nil {
		return err
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be added")
	}
	if _, ok := c.runtime.configuration.Device(deviceID); ok {
		return commandError("device_already_exists", "device is already configured")
	}

	device := c.runtime.configuration.DefaultDevice()
	device.DeviceID = deviceID
	if value, ok := request.Arguments["name"]; ok {
		name, nameErr := validateName(value, "device name")
		if nameErr != nil {
			return nameErr
		}
		device.Name = name
	}
	if value, ok := request.Arguments["addresses"]; ok {
		addresses, addressErr := parseAddresses(value)
		if addressErr != nil {
			return addressErr
		}
		device.Addresses = addresses
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		device.Paused = paused
	}
	if operationErr := c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	}); operationErr != nil {
		return operationErr
	}
	c.pendingDevices.remove(deviceID)
	return nil
}

func (c *Core) acceptDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "acceptDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "deviceID", "offerVersion", "name", "paused"); err != nil {
		return err
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be accepted")
	}
	if _, configured := c.runtime.configuration.Device(deviceID); configured {
		return commandError("device_state_conflict", "the device is already configured")
	}
	if c.runtime.configuration.IgnoredDevice(deviceID) {
		return commandError("pending_device_not_found", "the pending device offer is no longer available")
	}
	offerVersion, ok := request.Arguments["offerVersion"]
	if !ok || strings.TrimSpace(offerVersion) == "" {
		return commandError("invalid_request", "acceptDevice requires offerVersion")
	}
	offer, found := c.pendingDevices.record(deviceID)
	if !found {
		return commandError("pending_device_not_found", "the pending device offer is no longer available")
	}
	if offerVersion != pendingDeviceOfferVersion(offer) {
		return commandError("offer_version_conflict", "the pending device offer changed; review it again")
	}

	device := c.runtime.configuration.DefaultDevice()
	device.DeviceID = deviceID
	device.Name = offer.Label
	if value, ok := request.Arguments["name"]; ok {
		name, nameErr := validateName(value, "device name")
		if nameErr != nil {
			return nameErr
		}
		device.Name = name
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		device.Paused = paused
	}
	if operationErr := c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	}); operationErr != nil {
		return operationErr
	}
	// Syncthing also removes the observed entry during configuration cleanup.
	// Remove the bridge projection synchronously so the next snapshot cannot
	// continue presenting a device that was just accepted.
	c.pendingDevices.remove(deviceID)
	return nil
}

// Pending-suppression handlers are kept separate from acceptance because they
// persist only a minimal ignored key and never promote untrusted offer data.
func (c *Core) ignorePendingDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "ignorePendingDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "offerVersion"); err != nil {
		return err
	}
	if strings.TrimSpace(request.ItemID) == "" {
		return commandError("invalid_device_id", "ignorePendingDevice requires a device ID in itemID")
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be ignored")
	}
	if _, configured := c.runtime.configuration.Device(deviceID); configured {
		return commandError("device_state_conflict", "a configured device cannot be ignored as pending")
	}
	offerVersion, ok := requiredCommandArgument(request.Arguments, "offerVersion")
	if !ok || !isCanonicalStableVersion(offerVersion) {
		return commandError("invalid_request", "ignorePendingDevice requires offerVersion")
	}

	// The desired postcondition is intentionally idempotent. Replaying after a
	// config or ledger write failure must still force Save, but must not require
	// the already-consumed pending projection to exist.
	if c.runtime.configuration.IgnoredDevice(deviceID) {
		return c.modifyConfigurationLocked(func(*config.Configuration) {})
	}
	offer, found := c.pendingDevices.record(deviceID)
	if !found {
		return commandError("pending_device_not_found", "the pending device offer is no longer available")
	}
	if offerVersion != pendingDeviceOfferVersion(offer) {
		return commandError("offer_version_conflict", "the pending device offer changed; review it again")
	}

	ignoredAt := time.Now().UTC()
	operationErr := c.modifyConfigurationLocked(func(current *config.Configuration) {
		filtered := make([]config.ObservedDevice, 0, len(current.IgnoredDevices)+1)
		for _, ignored := range current.IgnoredDevices {
			if ignored.ID != deviceID {
				filtered = append(filtered, ignored)
			}
		}
		filtered = append(filtered, config.ObservedDevice{
			ID:   deviceID,
			Time: ignoredAt,
		})
		current.IgnoredDevices = filtered
	})
	if operationErr != nil {
		return operationErr
	}
	c.pendingDevices.remove(deviceID)
	return nil
}

func (c *Core) unignorePendingDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "unignorePendingDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "suppressionVersion"); err != nil {
		return err
	}
	if strings.TrimSpace(request.ItemID) == "" {
		return commandError("invalid_device_id", "unignorePendingDevice requires a device ID in itemID")
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot have a pending suppression")
	}
	suppressionVersion, ok := requiredCommandArgument(request.Arguments, "suppressionVersion")
	if !ok || !isCanonicalStableVersion(suppressionVersion) {
		return commandError("invalid_request", "unignorePendingDevice requires suppressionVersion")
	}
	ignored, found := latestIgnoredDevice(c.runtime.configuration.IgnoredDevices(), deviceID)
	if !found {
		return c.modifyConfigurationLocked(func(*config.Configuration) {})
	}
	if suppressionVersion != suppressedPendingDeviceVersion(ignored) {
		return commandError("suppression_version_conflict", "the pending-device suppression changed; review it again")
	}
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		filtered := make([]config.ObservedDevice, 0, len(current.IgnoredDevices))
		for _, candidate := range current.IgnoredDevices {
			if candidate.ID != deviceID {
				filtered = append(filtered, candidate)
			}
		}
		current.IgnoredDevices = filtered
	})
}

func (c *Core) editDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "editDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "deviceID", "name", "addresses", "paused"); err != nil {
		return err
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be edited")
	}
	device, ok := c.runtime.configuration.Device(deviceID)
	if !ok {
		return commandError("device_not_found", "device is not configured")
	}
	if !hasAnyArgument(request.Arguments, "name", "addresses", "paused") {
		return commandError("invalid_request", "editDevice requires at least one mutable argument")
	}
	original := device.Copy()
	if value, ok := request.Arguments["name"]; ok {
		name, nameErr := validateName(value, "device name")
		if nameErr != nil {
			return nameErr
		}
		device.Name = name
	}
	if value, ok := request.Arguments["addresses"]; ok {
		addresses, addressErr := parseAddresses(value)
		if addressErr != nil {
			return addressErr
		}
		device.Addresses = addresses
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		device.Paused = paused
	}
	if reflect.DeepEqual(original, device) {
		return c.confirmUnchangedConfigurationLocked()
	}
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	})
}

func (c *Core) removeDeviceLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.FolderID != "" {
		return commandError("invalid_request", "removeDevice does not accept folderID")
	}
	if err := requireArgumentKeys(request.Arguments, "deviceID"); err != nil {
		return err
	}
	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be removed")
	}
	if _, ok := c.runtime.configuration.Device(deviceID); !ok {
		return commandError("device_not_found", "device is not configured")
	}
	c.pendingDevices.remove(deviceID)
	waiter, modifyErr := c.runtime.configuration.RemoveDevice(deviceID)
	return c.finishConfigurationChangeLocked(waiter, modifyErr)
}

func (c *Core) addFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "addFolder does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "folderID", "label", "path", "type", "paused", "deviceIDs", "rescanIntervalS"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	if _, ok := c.runtime.configuration.Folder(folderID); ok {
		return commandError("folder_already_exists", "folder is already configured")
	}
	pathValue, ok := request.Arguments["path"]
	if !ok {
		return commandError("invalid_path", "addFolder requires a path argument")
	}
	cleanPath, pathErr := c.validateFolderPathLocked(pathValue, "")
	if pathErr != nil {
		return pathErr
	}

	folder := c.runtime.configuration.DefaultFolder()
	folder.ID = folderID
	folder.Path = cleanPath
	if value, ok := request.Arguments["label"]; ok {
		label, labelErr := validateName(value, "folder label")
		if labelErr != nil {
			return labelErr
		}
		folder.Label = label
	}
	if value, ok := request.Arguments["type"]; ok {
		folderType, typeErr := parseFolderType(value)
		if typeErr != nil {
			return typeErr
		}
		folder.Type = folderType
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		folder.Paused = paused
	}
	if value, ok := request.Arguments["rescanIntervalS"]; ok {
		interval, intervalErr := parseRescanInterval(value)
		if intervalErr != nil {
			return intervalErr
		}
		folder.RescanIntervalS = interval
	}
	if value, ok := request.Arguments["deviceIDs"]; ok {
		devices, devicesErr := c.folderDevicesLocked(value, nil)
		if devicesErr != nil {
			return devicesErr
		}
		folder.Devices = devices
	}
	applyEmbeddedFolderPolicy(&folder)
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetFolder(folder)
	})
}

func (c *Core) acceptFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "acceptFolder does not accept itemID")
	}
	if err := requireArgumentKeys(
		request.Arguments,
		"folderID",
		"offeringDeviceID",
		"offerVersion",
		"label",
		"path",
		"type",
		"paused",
		"deviceIDs",
		"rescanIntervalS",
		"observationProofID",
	); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	if _, configured := c.runtime.configuration.Folder(folderID); configured {
		return commandError("folder_state_conflict", "the folder is already configured")
	}
	for _, required := range []string{"offeringDeviceID", "offerVersion", "path", "type", "deviceIDs"} {
		if strings.TrimSpace(request.Arguments[required]) == "" {
			return commandError("invalid_request", "acceptFolder requires offeringDeviceID, offerVersion, path, type, and deviceIDs")
		}
	}
	proofID := strings.TrimSpace(request.Arguments["observationProofID"])
	if proofID != "" && (c.runtime == nil || c.runtime.mode != sessionModeConfiguration) {
		return commandError("wrong_session_mode", "observation proofs may only be consumed in a configuration session")
	}
	offeringDeviceID, parseErr := protocol.DeviceIDFromString(strings.ToUpper(strings.TrimSpace(request.Arguments["offeringDeviceID"])))
	if parseErr != nil || offeringDeviceID == protocol.EmptyDeviceID || offeringDeviceID == c.localDeviceID {
		return commandError("invalid_device_id", "offeringDeviceID must identify a configured remote device")
	}
	offeringDevice, configured := c.runtime.configuration.Device(offeringDeviceID)
	if !configured {
		return commandError("device_not_found", "offeringDeviceID is not configured")
	}
	if offeringDevice.IgnoredFolder(folderID) {
		return commandError("pending_folder_not_found", "the pending folder offer is no longer available")
	}
	var offer pendingFolderOffer
	var observationProof pendingFolderObservationProof
	if proofID != "" {
		proof, proofErr := c.pendingFolderObservationProofForCommandLocked(request, folderID, offeringDeviceID, request.Arguments["offerVersion"])
		if proofErr != nil {
			return proofErr
		}
		observationProof = proof
		var offerErr error
		offer, offerErr = proof.offer()
		if offerErr != nil {
			return commandError("observation_proof_store_unavailable", "the pending folder observation proof is malformed")
		}
	} else {
		offers, sourceErr := c.pendingFolderOffersLocked(offeringDeviceID)
		if sourceErr != nil {
			return commandError("pending_state_unavailable", "pending folder state is temporarily unavailable")
		}
		found := false
		for _, candidate := range offers {
			if candidate.FolderID == folderID && candidate.OfferingDeviceID == offeringDeviceID {
				offer = candidate
				found = true
				break
			}
		}
		if !found {
			return commandError("pending_folder_not_found", "the pending folder offer is no longer available")
		}
	}
	if request.Arguments["offerVersion"] != pendingFolderOfferVersion(offer) {
		return commandError("offer_version_conflict", "the pending folder offer changed; review it again")
	}
	folderType, typeErr := parseFolderType(request.Arguments["type"])
	if typeErr != nil {
		return typeErr
	}
	if offer.ReceiveEncrypted && offer.RemoteEncrypted {
		return commandError("invalid_encrypted_offer", "the pending folder offer contains both encrypted-direction tokens")
	}
	offerEncrypted := offer.ReceiveEncrypted || offer.RemoteEncrypted
	if offerEncrypted != (folderType == config.FolderTypeReceiveEncrypted) {
		return commandError("encrypted_folder_type_mismatch", "encrypted offers require receiveEncrypted and unencrypted offers forbid it")
	}

	cleanPath, pathErr := c.validateFolderPathLocked(request.Arguments["path"], "")
	if pathErr != nil {
		return pathErr
	}
	devices, devicesErr := c.folderDevicesLocked(request.Arguments["deviceIDs"], nil)
	if devicesErr != nil {
		return devicesErr
	}
	offeringDeviceSelected := false
	for _, device := range devices {
		if device.DeviceID == offeringDeviceID {
			offeringDeviceSelected = true
			break
		}
	}
	if !offeringDeviceSelected {
		return commandError("offering_device_not_selected", "deviceIDs must explicitly include the offering device")
	}
	if offerEncrypted && len(devices) != 2 {
		return commandError("invalid_device_selection", "receiveEncrypted acceptance may include only the local and verified offering device")
	}

	folder := c.runtime.configuration.DefaultFolder()
	folder.ID = folderID
	folder.Label = offer.Label
	folder.Path = cleanPath
	folder.Type = folderType
	folder.Devices = devices
	if value, ok := request.Arguments["label"]; ok {
		label, labelErr := validateName(value, "folder label")
		if labelErr != nil {
			return labelErr
		}
		folder.Label = label
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		folder.Paused = paused
	}
	if value, ok := request.Arguments["rescanIntervalS"]; ok {
		interval, intervalErr := parseRescanInterval(value)
		if intervalErr != nil {
			return intervalErr
		}
		if folderType == config.FolderTypeReceiveEncrypted && interval != 0 && interval < 24*60*60 {
			return commandError("invalid_request", "receiveEncrypted rescanIntervalS must be zero or at least 86400")
		}
		folder.RescanIntervalS = interval
	}
	if folderType == config.FolderTypeReceiveEncrypted {
		folder.IgnorePerms = true
	}
	applyEmbeddedFolderPolicy(&folder)
	if proofID != "" {
		if revisionErr := c.preflightCommandConfigurationRevisionLocked(request); revisionErr != nil {
			return revisionErr
		}
		commitProof, proofErr := c.pendingFolderObservationProofForCommandLocked(request, folderID, offeringDeviceID, request.Arguments["offerVersion"])
		if proofErr != nil {
			return proofErr
		}
		if commitProof != observationProof {
			return commandError("observation_proof_store_unavailable", "the pending folder observation proof changed before commit")
		}
	}
	modifyErr := c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetFolder(folder)
	})
	if modifyErr != nil || proofID == "" {
		return modifyErr
	}
	if err := c.pendingFolderObservationProofs.consume(proofID); err != nil {
		return commandError("observation_proof_cleanup_failed", "the configuration committed but the observation proof could not be consumed")
	}
	return nil
}

func (c *Core) ignorePendingFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "ignorePendingFolder does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "offeringDeviceID", "offerVersion", "observationProofID"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	offeringDeviceValue, ok := requiredCommandArgument(request.Arguments, "offeringDeviceID")
	if !ok {
		return commandError("invalid_request", "ignorePendingFolder requires offeringDeviceID")
	}
	offeringDeviceID, parseErr := protocol.DeviceIDFromString(strings.ToUpper(offeringDeviceValue))
	if parseErr != nil || offeringDeviceID == protocol.EmptyDeviceID || offeringDeviceID == c.localDeviceID {
		return commandError("invalid_device_id", "offeringDeviceID must identify a configured remote device")
	}
	offerVersion, ok := requiredCommandArgument(request.Arguments, "offerVersion")
	if !ok || !isCanonicalStableVersion(offerVersion) {
		return commandError("invalid_request", "ignorePendingFolder requires offerVersion")
	}
	proofID := strings.TrimSpace(request.Arguments["observationProofID"])
	if proofID != "" && (c.runtime == nil || c.runtime.mode != sessionModeConfiguration) {
		return commandError("wrong_session_mode", "observation proofs may only be consumed in a configuration session")
	}
	device, configured := c.runtime.configuration.Device(offeringDeviceID)
	if !configured {
		return commandError("device_not_found", "offeringDeviceID is not configured")
	}
	if configuredFolder, exists := c.runtime.configuration.Folder(folderID); exists && configuredFolder.SharedWith(offeringDeviceID) {
		return commandError("folder_state_conflict", "the folder is already shared with the offering device")
	}
	if device.IgnoredFolder(folderID) && proofID == "" {
		return c.modifyConfigurationLocked(func(*config.Configuration) {})
	}
	var offer pendingFolderOffer
	var observationProof pendingFolderObservationProof
	if proofID != "" {
		if device.IgnoredFolder(folderID) {
			return commandError("folder_state_conflict", "the pending folder offer is already ignored")
		}
		proof, proofErr := c.pendingFolderObservationProofForCommandLocked(request, folderID, offeringDeviceID, offerVersion)
		if proofErr != nil {
			return proofErr
		}
		observationProof = proof
		var offerErr error
		offer, offerErr = proof.offer()
		if offerErr != nil {
			return commandError("observation_proof_store_unavailable", "the pending folder observation proof is malformed")
		}
	} else {
		offers, sourceErr := c.pendingFolderOffersLocked(offeringDeviceID)
		if sourceErr != nil {
			return commandError("pending_state_unavailable", "pending folder state is temporarily unavailable")
		}
		found := false
		for _, candidate := range offers {
			if candidate.FolderID == folderID && candidate.OfferingDeviceID == offeringDeviceID {
				offer = candidate
				found = true
				break
			}
		}
		if !found {
			return commandError("pending_folder_not_found", "the pending folder offer is no longer available")
		}
	}
	if offerVersion != pendingFolderOfferVersion(offer) {
		return commandError("offer_version_conflict", "the pending folder offer changed; review it again")
	}
	if proofID != "" {
		if revisionErr := c.preflightCommandConfigurationRevisionLocked(request); revisionErr != nil {
			return revisionErr
		}
		commitProof, proofErr := c.pendingFolderObservationProofForCommandLocked(request, folderID, offeringDeviceID, offerVersion)
		if proofErr != nil {
			return proofErr
		}
		if commitProof != observationProof {
			return commandError("observation_proof_store_unavailable", "the pending folder observation proof changed before commit")
		}
	}

	ignoredAt := time.Now().UTC()
	device.IgnoredFolders = appendFilteredIgnoredFolder(
		device.IgnoredFolders,
		config.ObservedFolder{ID: folderID, Time: ignoredAt},
	)
	modifyErr := c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	})
	if modifyErr != nil || proofID == "" {
		return modifyErr
	}
	if err := c.pendingFolderObservationProofs.consume(proofID); err != nil {
		return commandError("observation_proof_cleanup_failed", "the configuration committed but the observation proof could not be consumed")
	}
	return nil
}

func (c *Core) unignorePendingFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "unignorePendingFolder does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "offeringDeviceID", "suppressionVersion"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	offeringDeviceValue, ok := requiredCommandArgument(request.Arguments, "offeringDeviceID")
	if !ok {
		return commandError("invalid_request", "unignorePendingFolder requires offeringDeviceID")
	}
	offeringDeviceID, parseErr := protocol.DeviceIDFromString(strings.ToUpper(offeringDeviceValue))
	if parseErr != nil || offeringDeviceID == protocol.EmptyDeviceID || offeringDeviceID == c.localDeviceID {
		return commandError("invalid_device_id", "offeringDeviceID must identify a remote device")
	}
	suppressionVersion, ok := requiredCommandArgument(request.Arguments, "suppressionVersion")
	if !ok || !isCanonicalStableVersion(suppressionVersion) {
		return commandError("invalid_request", "unignorePendingFolder requires suppressionVersion")
	}
	device, configured := c.runtime.configuration.Device(offeringDeviceID)
	if !configured {
		return c.modifyConfigurationLocked(func(*config.Configuration) {})
	}
	ignored, found := latestIgnoredFolder(device.IgnoredFolders, folderID)
	if !found {
		return c.modifyConfigurationLocked(func(*config.Configuration) {})
	}
	if suppressionVersion != suppressedPendingFolderVersion(offeringDeviceID, ignored) {
		return commandError("suppression_version_conflict", "the pending-folder suppression changed; review it again")
	}
	filtered := make([]config.ObservedFolder, 0, len(device.IgnoredFolders))
	for _, candidate := range device.IgnoredFolders {
		if candidate.ID != folderID {
			filtered = append(filtered, candidate)
		}
	}
	device.IgnoredFolders = filtered
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	})
}

func appendFilteredIgnoredFolder(
	existing []config.ObservedFolder,
	ignored config.ObservedFolder,
) []config.ObservedFolder {
	filtered := make([]config.ObservedFolder, 0, len(existing)+1)
	for _, candidate := range existing {
		if candidate.ID != ignored.ID {
			filtered = append(filtered, candidate)
		}
	}
	return append(filtered, ignored)
}

func (c *Core) editFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "editFolder does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "folderID", "label", "path", "type", "paused", "deviceIDs", "rescanIntervalS"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	folder, ok := c.runtime.configuration.Folder(folderID)
	if !ok {
		return commandError("folder_not_found", "folder is not configured")
	}
	if !hasAnyArgument(request.Arguments, "label", "path", "type", "paused", "deviceIDs", "rescanIntervalS") {
		return commandError("invalid_request", "editFolder requires at least one mutable argument")
	}
	original := folder.Copy()
	if value, ok := request.Arguments["label"]; ok {
		label, labelErr := validateName(value, "folder label")
		if labelErr != nil {
			return labelErr
		}
		folder.Label = label
	}
	if value, ok := request.Arguments["path"]; ok {
		cleanPath, pathErr := c.validateFolderPathLocked(value, folderID)
		if pathErr != nil {
			return pathErr
		}
		folder.Path = cleanPath
	}
	if value, ok := request.Arguments["type"]; ok {
		folderType, typeErr := parseFolderType(value)
		if typeErr != nil {
			return typeErr
		}
		folder.Type = folderType
	}
	if value, ok := request.Arguments["paused"]; ok {
		paused, boolErr := parseBoolean(value, "paused")
		if boolErr != nil {
			return boolErr
		}
		folder.Paused = paused
	}
	if value, ok := request.Arguments["rescanIntervalS"]; ok {
		interval, intervalErr := parseRescanInterval(value)
		if intervalErr != nil {
			return intervalErr
		}
		folder.RescanIntervalS = interval
	}
	if value, ok := request.Arguments["deviceIDs"]; ok {
		devices, devicesErr := c.folderDevicesLocked(value, folder.Devices)
		if devicesErr != nil {
			return devicesErr
		}
		folder.Devices = devices
	}
	applyEmbeddedFolderPolicy(&folder)
	if reflect.DeepEqual(original, folder) {
		return c.confirmUnchangedConfigurationLocked()
	}
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetFolder(folder)
	})
}

func (c *Core) removeFolderLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "removeFolder does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "folderID", "deleteData"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	if value, ok := request.Arguments["deleteData"]; ok {
		deleteData, boolErr := parseBoolean(value, "deleteData")
		if boolErr != nil {
			return boolErr
		}
		if deleteData {
			return commandError("unsupported_destructive_option", "removing synchronized files is not supported")
		}
	}
	if _, ok := c.runtime.configuration.Folder(folderID); !ok {
		return commandError("folder_not_found", "folder is not configured")
	}
	waiter, modifyErr := c.runtime.configuration.RemoveFolder(folderID)
	return c.finishConfigurationChangeLocked(waiter, modifyErr)
}

func (c *Core) setPausedLocked(request commandRequest, paused bool) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if err := requireArgumentKeys(request.Arguments, "folderID", "deviceID"); err != nil {
		return err
	}
	_, hasFolderArgument := request.Arguments["folderID"]
	if request.FolderID != "" || hasFolderArgument {
		if request.ItemID != "" {
			return commandError("invalid_request", "folder pause or resume does not accept itemID")
		}
		if _, hasDeviceArgument := request.Arguments["deviceID"]; hasDeviceArgument {
			return commandError("invalid_request", "pause or resume must target exactly one folder or device")
		}
		folderID, err := folderTarget(request)
		if err != nil {
			return err
		}
		folder, ok := c.runtime.configuration.Folder(folderID)
		if !ok {
			return commandError("folder_not_found", "folder is not configured")
		}
		if folder.Paused == paused {
			return c.confirmUnchangedConfigurationLocked()
		}
		folder.Paused = paused
		return c.modifyConfigurationLocked(func(current *config.Configuration) {
			current.SetFolder(folder)
		})
	}

	deviceID, err := deviceTarget(request)
	if err != nil {
		return err
	}
	if deviceID == c.localDeviceID {
		return commandError("local_device_immutable", "the local device cannot be paused or resumed")
	}
	device, ok := c.runtime.configuration.Device(deviceID)
	if !ok {
		return commandError("device_not_found", "device is not configured")
	}
	if device.Paused == paused {
		return c.confirmUnchangedConfigurationLocked()
	}
	device.Paused = paused
	return c.modifyConfigurationLocked(func(current *config.Configuration) {
		current.SetDevice(device)
	})
}

func (c *Core) rescanLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if request.ItemID != "" {
		return commandError("invalid_request", "rescan does not accept itemID")
	}
	if err := requireArgumentKeys(request.Arguments, "folderID"); err != nil {
		return err
	}
	folderID, err := folderTarget(request)
	if err != nil {
		return err
	}
	folder, ok := c.runtime.configuration.Folder(folderID)
	if !ok {
		return commandError("folder_not_found", "folder is not configured")
	}
	if folder.Paused {
		return commandError("folder_paused", "paused folders cannot be rescanned")
	}
	if c.runtime.app == nil || c.runtime.app.Internals == nil {
		return commandError("core_not_running", "Syncthing core is not running")
	}
	if scanErr := c.scanFolderSubdirsLocked(folderID, nil); scanErr != nil {
		if c.stopRequested.Load() {
			return commandError("cancelled", "the folder rescan was cancelled")
		}
		return commandError("rescan_failed", scanErr.Error())
	}
	c.generation++
	return nil
}

func (c *Core) requireRunningLocked() *responseError {
	if c.lifecycle != lifecycleRunning || c.runtime == nil || c.runtime.configuration == nil || c.runtimeStopRequested.Load() {
		return commandError("core_not_running", "Syncthing core must be running")
	}
	return nil
}

func (c *Core) modifyConfigurationLocked(modify func(*config.Configuration)) *responseError {
	waiter, err := c.runtime.configuration.Modify(func(current *config.Configuration) {
		modify(current)
		applyEmbeddedFolderPolicy(&current.Defaults.Folder)
		for index := range current.Folders {
			applyEmbeddedFolderPolicy(&current.Folders[index])
		}
	})
	return c.finishConfigurationChangeLocked(waiter, err)
}

func (c *Core) finishConfigurationChangeLocked(waiter config.Waiter, modifyErr error) *responseError {
	if modifyErr != nil {
		return commandError("configuration_rejected", modifyErr.Error())
	}
	if waitErr := c.waitForConfigurationLocked(waiter); waitErr != nil {
		return commandError("cancelled", "the configuration update was cancelled")
	}
	c.generation++
	if err := c.runtime.configuration.Save(); err != nil {
		return commandError("configuration_save_failed", err.Error())
	}
	if c.runtime.mode == sessionModeConfiguration {
		if verifyErr := c.confirmCanonicalConfigurationLocked(); verifyErr != nil {
			return verifyErr
		}
	}
	return nil
}

func (c *Core) confirmUnchangedConfigurationLocked() *responseError {
	if c.runtime == nil || c.runtime.mode != sessionModeConfiguration {
		return nil
	}
	if err := c.runtime.configuration.Save(); err != nil {
		return commandError("configuration_save_failed", err.Error())
	}
	return c.confirmCanonicalConfigurationLocked()
}

func deviceTarget(request commandRequest) (protocol.DeviceID, *responseError) {
	itemID := strings.TrimSpace(request.ItemID)
	argumentID, hasArgumentID := request.Arguments["deviceID"]
	argumentID = strings.TrimSpace(argumentID)
	if itemID == "" && hasArgumentID {
		itemID = argumentID
	} else if itemID != "" && hasArgumentID && !strings.EqualFold(itemID, argumentID) {
		return protocol.EmptyDeviceID, commandError("invalid_request", "itemID and arguments.deviceID identify different devices")
	}
	if itemID == "" {
		return protocol.EmptyDeviceID, commandError("invalid_device_id", "a device ID is required in itemID or arguments.deviceID")
	}
	deviceID, err := protocol.DeviceIDFromString(strings.ToUpper(itemID))
	if err != nil || deviceID == protocol.EmptyDeviceID {
		return protocol.EmptyDeviceID, commandError("invalid_device_id", "device ID is not a valid Syncthing device ID")
	}
	return deviceID, nil
}

func folderTarget(request commandRequest) (string, *responseError) {
	folderID := strings.TrimSpace(request.FolderID)
	argumentID, hasArgumentID := request.Arguments["folderID"]
	argumentID = strings.TrimSpace(argumentID)
	if folderID == "" && hasArgumentID {
		folderID = argumentID
	} else if folderID != "" && hasArgumentID && folderID != argumentID {
		return "", commandError("invalid_request", "folderID and arguments.folderID identify different folders")
	}
	if err := validateFolderID(folderID); err != nil {
		return "", err
	}
	return folderID, nil
}

func validateFolderID(folderID string) *responseError {
	if folderID == "" || utf8.RuneCountInString(folderID) > 64 {
		return commandError("invalid_folder_id", "folder ID must contain between 1 and 64 characters")
	}
	for _, character := range folderID {
		if unicode.IsControl(character) {
			return commandError("invalid_folder_id", "folder ID must not contain control characters")
		}
	}
	return nil
}

func validateName(value, field string) (string, *responseError) {
	value = strings.TrimSpace(value)
	if len(value) > maxConfigurationNameBytes {
		return "", commandError("invalid_request", field+" exceeds 256 bytes")
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return "", commandError("invalid_request", field+" must not contain control characters")
		}
	}
	return value, nil
}

func parseAddresses(value string) ([]string, *responseError) {
	addresses, err := parseStringList(value, "addresses")
	if err != nil {
		return nil, err
	}
	if len(addresses) == 0 {
		return []string{"dynamic"}, nil
	}
	for index, address := range addresses {
		if strings.EqualFold(address, "dynamic") {
			addresses[index] = "dynamic"
			continue
		}
		if len(address) > 2048 {
			return nil, commandError("invalid_address", "device address exceeds 2048 bytes")
		}
		parsed, parseErr := url.Parse(address)
		if parseErr != nil || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
			return nil, commandError("invalid_address", "device address must be dynamic or a supported network URL")
		}
		switch parsed.Scheme {
		case "tcp", "tcp4", "tcp6", "quic", "quic4", "quic6", "relay":
		default:
			return nil, commandError("invalid_address", "device address uses an unsupported URL scheme")
		}
		if _, _, splitErr := net.SplitHostPort(parsed.Host); splitErr != nil {
			return nil, commandError("invalid_address", "device address must include a valid host and port")
		}
	}
	return addresses, nil
}

func parseStringList(value, field string) ([]string, *responseError) {
	value = strings.TrimSpace(value)
	if value == "" {
		return []string{}, nil
	}
	var values []string
	if strings.HasPrefix(value, "[") {
		if err := json.Unmarshal([]byte(value), &values); err != nil {
			return nil, commandError("invalid_request", field+" must be a comma-separated list or JSON string array")
		}
	} else {
		values = strings.Split(value, ",")
	}
	if len(values) > maxConfigurationListItems {
		return nil, commandError("invalid_request", field+" contains too many entries")
	}
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, item := range values {
		item = strings.TrimSpace(item)
		if item == "" {
			return nil, commandError("invalid_request", field+" must not contain empty entries")
		}
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		result = append(result, item)
	}
	return result, nil
}

func parseBoolean(value, field string) (bool, *responseError) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, commandError("invalid_request", field+" must be true or false")
	}
}

func parseRescanInterval(value string) (int, *responseError) {
	interval, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || interval < 0 || interval > config.MaxRescanIntervalS {
		return 0, commandError("invalid_request", fmt.Sprintf("rescanIntervalS must be between 0 and %d", config.MaxRescanIntervalS))
	}
	return interval, nil
}

func parseFolderType(value string) (config.FolderType, *responseError) {
	switch strings.TrimSpace(value) {
	case "sendReceive", "sendreceive":
		return config.FolderTypeSendReceive, nil
	case "sendOnly", "sendonly":
		return config.FolderTypeSendOnly, nil
	case "receiveOnly", "receiveonly":
		return config.FolderTypeReceiveOnly, nil
	case "receiveEncrypted", "receiveencrypted":
		return config.FolderTypeReceiveEncrypted, nil
	default:
		return config.FolderTypeSendReceive, commandError("invalid_folder_type", "folder type must be sendReceive, sendOnly, receiveOnly, or receiveEncrypted")
	}
}

func bridgeFolderType(folderType config.FolderType) string {
	switch folderType {
	case config.FolderTypeSendReceive:
		return "sendReceive"
	case config.FolderTypeSendOnly:
		return "sendOnly"
	case config.FolderTypeReceiveOnly:
		return "receiveOnly"
	case config.FolderTypeReceiveEncrypted:
		return "receiveEncrypted"
	default:
		return "unknown"
	}
}

func (c *Core) folderDevicesLocked(value string, existing []config.FolderDeviceConfiguration) ([]config.FolderDeviceConfiguration, *responseError) {
	deviceValues, err := parseStringList(value, "deviceIDs")
	if err != nil {
		return nil, err
	}
	existingByID := make(map[protocol.DeviceID]config.FolderDeviceConfiguration, len(existing))
	for _, device := range existing {
		existingByID[device.DeviceID] = device
	}
	result := make([]config.FolderDeviceConfiguration, 0, len(deviceValues)+1)
	seen := make(map[protocol.DeviceID]struct{}, len(deviceValues)+1)
	for _, value := range deviceValues {
		deviceID, parseErr := protocol.DeviceIDFromString(strings.ToUpper(strings.TrimSpace(value)))
		if parseErr != nil || deviceID == protocol.EmptyDeviceID {
			return nil, commandError("invalid_device_id", "deviceIDs contains an invalid Syncthing device ID")
		}
		if _, ok := c.runtime.configuration.Device(deviceID); !ok {
			return nil, commandError("device_not_found", "deviceIDs contains a device that is not configured")
		}
		if _, ok := seen[deviceID]; ok {
			continue
		}
		seen[deviceID] = struct{}{}
		if preserved, ok := existingByID[deviceID]; ok {
			result = append(result, preserved)
		} else {
			result = append(result, config.FolderDeviceConfiguration{DeviceID: deviceID})
		}
	}
	if _, ok := seen[c.localDeviceID]; !ok {
		if preserved, ok := existingByID[c.localDeviceID]; ok {
			result = append(result, preserved)
		} else {
			result = append(result, config.FolderDeviceConfiguration{DeviceID: c.localDeviceID})
		}
	}
	return result, nil
}

func (c *Core) validateFolderPathLocked(value, editingFolderID string) (string, *responseError) {
	value = strings.TrimSpace(value)
	if value == "" || !filepath.IsAbs(value) {
		return "", commandError("invalid_path", "folder path must be an absolute directory path")
	}
	cleanPath := filepath.Clean(value)
	if cleanPath == string(filepath.Separator) {
		return "", commandError("invalid_path", "filesystem root cannot be configured as a folder")
	}
	lstatInfo, err := os.Lstat(cleanPath)
	if err != nil {
		return "", commandError("invalid_path", "folder path must exist and be accessible")
	}
	if lstatInfo.Mode()&os.ModeSymlink != 0 {
		return "", commandError("invalid_path", "folder path must not be a symlink")
	}
	if !lstatInfo.IsDir() {
		return "", commandError("invalid_path", "folder path must identify a directory")
	}
	resolvedPath, err := filepath.EvalSymlinks(cleanPath)
	if err != nil {
		return "", commandError("invalid_path", "folder path could not be resolved safely")
	}
	for _, reserved := range []string{c.home, c.configurationDirectory, c.dataDirectory, c.stagingDirectory} {
		resolvedReserved, resolveErr := filepath.EvalSymlinks(reserved)
		if resolveErr != nil {
			resolvedReserved = reserved
		}
		if pathsOverlap(resolvedPath, resolvedReserved) {
			return "", commandError("invalid_path", "folder path must not contain or overlap bridge-owned state or staging directories")
		}
	}
	for _, configured := range c.runtime.configuration.FolderList() {
		if configured.ID == editingFolderID {
			continue
		}
		configuredPath, resolveErr := filepath.EvalSymlinks(filepath.Clean(configured.Path))
		if resolveErr != nil {
			configuredPath = filepath.Clean(configured.Path)
		}
		if pathsOverlap(resolvedPath, configuredPath) {
			return "", commandError("folder_path_conflict", "folder path overlaps another configured folder")
		}
	}
	return cleanPath, nil
}

func pathsOverlap(first, second string) bool {
	first = filepath.Clean(first)
	second = filepath.Clean(second)
	return pathContains(first, second) || pathContains(second, first)
}

func pathContains(parent, child string) bool {
	relative, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return relative == "." || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func hasAnyArgument(arguments map[string]string, keys ...string) bool {
	for _, key := range keys {
		if _, ok := arguments[key]; ok {
			return true
		}
	}
	return false
}

func saturatingAdd(left, right int64) int64 {
	if right > 0 && left > math.MaxInt64-right {
		return math.MaxInt64
	}
	return left + right
}

func (c *Core) deviceTransferRatesLocked() map[protocol.DeviceID]deviceTransferRate {
	statistics := make(map[protocol.DeviceID]deviceConnectionStatistics)
	if c.connectionStatisticsForTests != nil {
		statistics = c.connectionStatisticsForTests()
	} else if c.runtime != nil && c.runtime.app != nil && c.runtime.app.Internals != nil {
		for deviceID, entry := range c.runtime.app.Internals.ConnectionStatistics() {
			statistics[deviceID] = deviceConnectionStatistics{
				At:            entry.At,
				StartedAt:     entry.StartedAt,
				InBytesTotal:  entry.InBytesTotal,
				OutBytesTotal: entry.OutBytesTotal,
				Connections:   entry.Connections,
			}
		}
	}
	if c.connectionRateSamples == nil {
		c.connectionRateSamples = make(map[protocol.DeviceID]deviceRateSample)
	}
	result := make(map[protocol.DeviceID]deviceTransferRate, len(statistics))
	for deviceID, current := range statistics {
		previous, exists := c.connectionRateSamples[deviceID]
		sample := deviceRateSample{Statistics: current}
		switch {
		case !exists,
			current.At.IsZero(),
			current.StartedAt.IsZero(),
			current.Connections <= 0,
			current.StartedAt != previous.Statistics.StartedAt,
			current.Connections != previous.Statistics.Connections,
			current.InBytesTotal < previous.Statistics.InBytesTotal,
			current.OutBytesTotal < previous.Statistics.OutBytesTotal:
			// A first sample, replacement connection, changed connection set or
			// counter rollback establishes a new epoch and never invents a rate.
		case !current.At.After(previous.Statistics.At):
			// Syncthing timestamps counters to whole seconds. Repeated snapshots
			// within the same completed sample retain the last calculated rate
			// without advancing the counter baseline.
			sample = previous
		default:
			interval := current.At.Sub(previous.Statistics.At)
			sample.UploadBytesPerSecond = bytesPerSecond(
				current.OutBytesTotal-previous.Statistics.OutBytesTotal,
				interval,
			)
			sample.DownloadBytesPerSecond = bytesPerSecond(
				current.InBytesTotal-previous.Statistics.InBytesTotal,
				interval,
			)
		}
		c.connectionRateSamples[deviceID] = sample
		result[deviceID] = deviceTransferRate{
			UploadBytesPerSecond:   sample.UploadBytesPerSecond,
			DownloadBytesPerSecond: sample.DownloadBytesPerSecond,
		}
	}
	for deviceID := range c.connectionRateSamples {
		if _, connected := statistics[deviceID]; !connected {
			delete(c.connectionRateSamples, deviceID)
		}
	}
	return result
}

func bytesPerSecond(bytes int64, interval time.Duration) int64 {
	if bytes <= 0 || interval <= 0 {
		return 0
	}
	rate := float64(bytes) / interval.Seconds()
	if rate >= float64(math.MaxInt64) {
		return math.MaxInt64
	}
	return int64(rate)
}

func maxInt64(left, right int64) int64 {
	if left > right {
		return left
	}
	return right
}
