// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	pendingFolderDiscoverySummarySchemaVersion = 1
	maxPendingFolderDiscoverySummaries         = 512
	maxPendingFolderDiscoverySummaryStoreSize  = 1 << 20
)

// pendingFolderDiscoverySummary is intentionally not an authorization proof.
// It is a redacted, durable UI projection; accept/ignore still requires the
// separate five-minute pendingFolderObservationProof.
type pendingFolderDiscoverySummary struct {
	FolderID         string `json:"folderID"`
	OfferingDeviceID string `json:"offeringDeviceID"`
	Label            string `json:"label"`
	LastSeen         string `json:"lastSeen"`
	OfferVersion     string `json:"offerVersion"`
	ReceiveEncrypted bool   `json:"receiveEncrypted"`
	RemoteEncrypted  bool   `json:"remoteEncrypted"`
	ConnectionEpoch  string `json:"connectionEpoch"`
	ObservedAt       string `json:"observedAt"`
}

type pendingFolderDiscoveryBatch struct {
	OfferingDeviceID string                          `json:"offeringDeviceID"`
	ConnectionEpoch  string                          `json:"connectionEpoch"`
	ObservedAt       string                          `json:"observedAt"`
	Offers           []pendingFolderDiscoverySummary `json:"offers"`
	Truncated        bool                            `json:"truncated"`
}

type pendingFolderDiscoverySummaryDocument struct {
	SchemaVersion              int                             `json:"schemaVersion"`
	Summaries                  []pendingFolderDiscoverySummary `json:"summaries"`
	TruncatedOfferingDeviceIDs []string                        `json:"truncatedOfferingDeviceIDs"`
}

type pendingFolderDiscoverySummaryKey struct {
	deviceID protocol.DeviceID
	folderID string
}

type pendingFolderDiscoverySummaryStore struct {
	mu               sync.Mutex
	path             string
	summaries        map[pendingFolderDiscoverySummaryKey]pendingFolderDiscoverySummary
	truncatedDevices map[protocol.DeviceID]bool
	healthy          bool
	writeFile        func(string, []byte) error
}

func loadPendingFolderDiscoverySummaryStore(home string) (*pendingFolderDiscoverySummaryStore, error) {
	return loadPendingFolderDiscoverySummaryStoreWithWriter(home, writePendingFolderObservationProofFile)
}

func loadPendingFolderDiscoverySummaryStoreWithWriter(home string, writeFile func(string, []byte) error) (*pendingFolderDiscoverySummaryStore, error) {
	if writeFile == nil {
		return nil, errors.New("pending folder discovery summary writer is unavailable")
	}
	store := &pendingFolderDiscoverySummaryStore{
		path:             filepath.Join(home, "Bridge", "pending-folder-discovery-summaries-v1.json"),
		summaries:        make(map[pendingFolderDiscoverySummaryKey]pendingFolderDiscoverySummary),
		truncatedDevices: make(map[protocol.DeviceID]bool),
		healthy:          true,
		writeFile:        writeFile,
	}
	directory := filepath.Dir(store.path)
	if info, err := os.Lstat(directory); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
			return nil, errors.New("pending folder discovery summary directory is not a real 0700 directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect pending folder discovery summary directory: %w", err)
	}

	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect pending folder discovery summary store: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("pending folder discovery summary store is not a regular non-symlink file")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, errors.New("pending folder discovery summary store permissions must be 0600")
	}
	if info.Size() > maxPendingFolderDiscoverySummaryStoreSize {
		return nil, errors.New("pending folder discovery summary store exceeds the supported size")
	}

	handle, err := openCommandLedgerNoFollow(store.path)
	if err != nil {
		return nil, fmt.Errorf("open pending folder discovery summary store: %w", err)
	}
	defer handle.Close()
	openedInfo, err := handle.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect open pending folder discovery summary store: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || openedInfo.Mode().Perm() != 0o600 || !os.SameFile(info, openedInfo) {
		return nil, errors.New("pending folder discovery summary store changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(handle, maxPendingFolderDiscoverySummaryStoreSize+1))
	if err != nil {
		return nil, fmt.Errorf("read pending folder discovery summary store: %w", err)
	}
	if len(data) > maxPendingFolderDiscoverySummaryStoreSize {
		return nil, errors.New("pending folder discovery summary store exceeds the supported size")
	}
	if err := rejectDuplicatePendingFolderDiscoveryJSONKeys(data); err != nil {
		return nil, err
	}

	var document pendingFolderDiscoverySummaryDocument
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode pending folder discovery summary store: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("pending folder discovery summary store must contain exactly one JSON object")
	}
	if document.SchemaVersion != pendingFolderDiscoverySummarySchemaVersion {
		return nil, fmt.Errorf("unsupported pending folder discovery summary schema %d", document.SchemaVersion)
	}
	if len(document.Summaries) > maxPendingFolderDiscoverySummaries || len(document.TruncatedOfferingDeviceIDs) > maxPendingFolderDiscoverySummaries {
		return nil, errors.New("pending folder discovery summary entry limit exceeded")
	}
	batchEpochs := make(map[protocol.DeviceID]string)
	batchObservedAt := make(map[protocol.DeviceID]string)
	for _, summary := range document.Summaries {
		key, validationErr := validatePendingFolderDiscoverySummary(summary)
		if validationErr != nil {
			return nil, validationErr
		}
		if _, duplicate := store.summaries[key]; duplicate {
			return nil, errors.New("pending folder discovery summary store contains a duplicate device and folder key")
		}
		if epoch, exists := batchEpochs[key.deviceID]; exists && epoch != summary.ConnectionEpoch {
			return nil, errors.New("pending folder discovery summary store mixes connection epochs for one device")
		}
		if observedAt, exists := batchObservedAt[key.deviceID]; exists && observedAt != summary.ObservedAt {
			return nil, errors.New("pending folder discovery summary store mixes observation times for one device")
		}
		batchEpochs[key.deviceID] = summary.ConnectionEpoch
		batchObservedAt[key.deviceID] = summary.ObservedAt
		store.summaries[key] = summary
	}
	for _, rawDeviceID := range document.TruncatedOfferingDeviceIDs {
		deviceID, parseErr := protocol.DeviceIDFromString(rawDeviceID)
		if parseErr != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != rawDeviceID {
			return nil, errors.New("pending folder discovery summary store contains an invalid truncated device ID")
		}
		if store.truncatedDevices[deviceID] {
			return nil, errors.New("pending folder discovery summary store contains a duplicate truncated device ID")
		}
		store.truncatedDevices[deviceID] = true
	}
	return store, nil
}

func rejectDuplicatePendingFolderDiscoveryJSONKeys(data []byte) error {
	if err := rejectDuplicatePendingFolderObservationJSONKeys(data); err != nil {
		return fmt.Errorf("pending folder discovery summary store: %w", err)
	}
	return nil
}

func validatePendingFolderDiscoverySummary(summary pendingFolderDiscoverySummary) (pendingFolderDiscoverySummaryKey, error) {
	if validateFolderID(summary.FolderID) != nil || summary.FolderID != strings.TrimSpace(summary.FolderID) {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary contains an invalid folder ID")
	}
	deviceID, err := protocol.DeviceIDFromString(summary.OfferingDeviceID)
	if err != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != summary.OfferingDeviceID {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary contains an invalid offering device ID")
	}
	if sanitizedPendingLabel(summary.Label) != summary.Label || !isCanonicalStableVersion(summary.OfferVersion) || !isCanonicalStableVersion(summary.ConnectionEpoch) {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary contains invalid offer metadata")
	}
	lastSeen, err := parseCanonicalProofTime(summary.LastSeen)
	if err != nil {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary contains an invalid lastSeen timestamp")
	}
	if _, err := parseCanonicalProofTime(summary.ObservedAt); err != nil {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary contains an invalid observedAt timestamp")
	}
	offer := pendingFolderOffer{
		FolderID:         summary.FolderID,
		Label:            summary.Label,
		OfferingDeviceID: deviceID,
		LastSeen:         lastSeen,
		ReceiveEncrypted: summary.ReceiveEncrypted,
		RemoteEncrypted:  summary.RemoteEncrypted,
	}
	if pendingFolderOfferVersion(offer) != summary.OfferVersion {
		return pendingFolderDiscoverySummaryKey{}, errors.New("pending folder discovery summary integrity check failed")
	}
	return pendingFolderDiscoverySummaryKey{deviceID: deviceID, folderID: summary.FolderID}, nil
}

func pendingFolderDiscoverySummaryFromOffer(offer pendingFolderOffer, connectionEpoch string, observedAt time.Time) pendingFolderDiscoverySummary {
	return pendingFolderDiscoverySummary{
		FolderID:         offer.FolderID,
		OfferingDeviceID: offer.OfferingDeviceID.String(),
		Label:            offer.Label,
		LastSeen:         offer.LastSeen.UTC().Format(time.RFC3339Nano),
		OfferVersion:     pendingFolderOfferVersion(offer),
		ReceiveEncrypted: offer.ReceiveEncrypted,
		RemoteEncrypted:  offer.RemoteEncrypted,
		ConnectionEpoch:  connectionEpoch,
		ObservedAt:       observedAt.UTC().Format(time.RFC3339Nano),
	}
}

func (summary pendingFolderDiscoverySummary) snapshot() pendingFolderSnapshot {
	return pendingFolderSnapshot{
		FolderID:                        summary.FolderID,
		Label:                           summary.Label,
		OfferingDeviceID:                summary.OfferingDeviceID,
		LastSeen:                        summary.LastSeen,
		OfferVersion:                    summary.OfferVersion,
		ReceiveEncrypted:                summary.ReceiveEncrypted,
		RemoteEncrypted:                 summary.RemoteEncrypted,
		RequiresManagedLocalPath:        true,
		RequiresExplicitDeviceSelection: true,
		EvidenceSource:                  "durableSummary",
		RequiresNetworkRevalidation:     true,
	}
}

func (s *pendingFolderDiscoverySummaryStore) replaceDevice(deviceID protocol.DeviceID, summaries []pendingFolderDiscoverySummary, sourceTruncated bool) ([]pendingFolderDiscoverySummary, bool, error) {
	if s == nil {
		return nil, false, errors.New("pending folder discovery summary store is unavailable")
	}
	if deviceID == protocol.EmptyDeviceID {
		return nil, false, errors.New("pending folder discovery summary device is invalid")
	}
	validated := make([]pendingFolderDiscoverySummary, 0, len(summaries))
	seenFolders := make(map[string]struct{}, len(summaries))
	batchEpoch := ""
	batchObservedAt := ""
	for _, summary := range summaries {
		key, err := validatePendingFolderDiscoverySummary(summary)
		if err != nil {
			return nil, false, err
		}
		if key.deviceID != deviceID {
			return nil, false, errors.New("pending folder discovery summary is outside the target device scope")
		}
		if _, duplicate := seenFolders[key.folderID]; duplicate {
			return nil, false, errors.New("pending folder discovery summary batch contains a duplicate folder ID")
		}
		if batchEpoch != "" && batchEpoch != summary.ConnectionEpoch {
			return nil, false, errors.New("pending folder discovery summary batch mixes connection epochs")
		}
		if batchObservedAt != "" && batchObservedAt != summary.ObservedAt {
			return nil, false, errors.New("pending folder discovery summary batch mixes observation times")
		}
		batchEpoch = summary.ConnectionEpoch
		batchObservedAt = summary.ObservedAt
		seenFolders[key.folderID] = struct{}{}
		validated = append(validated, summary)
	}
	slices.SortFunc(validated, func(left, right pendingFolderDiscoverySummary) int {
		return strings.Compare(left.FolderID, right.FolderID)
	})

	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.healthy {
		return nil, false, errors.New("pending folder discovery summary store is unavailable")
	}
	priorSummaries := s.summaries
	priorTruncated := s.truncatedDevices
	nextSummaries := make(map[pendingFolderDiscoverySummaryKey]pendingFolderDiscoverySummary, len(priorSummaries)+len(validated))
	for key, summary := range priorSummaries {
		if key.deviceID != deviceID {
			nextSummaries[key] = summary
		}
	}
	available := maxPendingFolderDiscoverySummaries - len(nextSummaries)
	if available < 0 {
		available = 0
	}
	truncated := sourceTruncated || len(validated) > available
	if len(validated) > available {
		validated = validated[:available]
	}
	for _, summary := range validated {
		nextSummaries[pendingFolderDiscoverySummaryKey{deviceID: deviceID, folderID: summary.FolderID}] = summary
	}
	nextTruncated := make(map[protocol.DeviceID]bool, len(priorTruncated)+1)
	for candidate, value := range priorTruncated {
		if candidate != deviceID && value {
			nextTruncated[candidate] = true
		}
	}
	if truncated {
		if len(nextTruncated) >= maxPendingFolderDiscoverySummaries {
			return nil, false, errors.New("pending folder discovery summary truncated-device limit exceeded")
		}
		nextTruncated[deviceID] = true
	}
	s.summaries = nextSummaries
	s.truncatedDevices = nextTruncated
	if err := s.saveLocked(); err != nil {
		s.summaries = priorSummaries
		s.truncatedDevices = priorTruncated
		s.healthy = false
		return nil, false, err
	}
	return append([]pendingFolderDiscoverySummary(nil), validated...), truncated, nil
}

func (s *pendingFolderDiscoverySummaryStore) snapshot() ([]pendingFolderDiscoverySummary, map[protocol.DeviceID]bool, bool) {
	if s == nil {
		return nil, nil, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]pendingFolderDiscoverySummary, 0, len(s.summaries))
	for _, summary := range s.summaries {
		result = append(result, summary)
	}
	slices.SortFunc(result, func(left, right pendingFolderDiscoverySummary) int {
		if comparison := strings.Compare(left.FolderID, right.FolderID); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.OfferingDeviceID, right.OfferingDeviceID)
	})
	truncated := make(map[protocol.DeviceID]bool, len(s.truncatedDevices))
	for deviceID, value := range s.truncatedDevices {
		truncated[deviceID] = value
	}
	return result, truncated, s.healthy
}

func (s *pendingFolderDiscoverySummaryStore) saveLocked() error {
	if len(s.summaries) > maxPendingFolderDiscoverySummaries || len(s.truncatedDevices) > maxPendingFolderDiscoverySummaries {
		return errors.New("pending folder discovery summary entry limit exceeded")
	}
	document := pendingFolderDiscoverySummaryDocument{
		SchemaVersion:              pendingFolderDiscoverySummarySchemaVersion,
		Summaries:                  make([]pendingFolderDiscoverySummary, 0, len(s.summaries)),
		TruncatedOfferingDeviceIDs: make([]string, 0, len(s.truncatedDevices)),
	}
	for _, summary := range s.summaries {
		document.Summaries = append(document.Summaries, summary)
	}
	slices.SortFunc(document.Summaries, func(left, right pendingFolderDiscoverySummary) int {
		if comparison := strings.Compare(left.OfferingDeviceID, right.OfferingDeviceID); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.FolderID, right.FolderID)
	})
	for deviceID, truncated := range s.truncatedDevices {
		if truncated {
			document.TruncatedOfferingDeviceIDs = append(document.TruncatedOfferingDeviceIDs, deviceID.String())
		}
	}
	slices.Sort(document.TruncatedOfferingDeviceIDs)
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode pending folder discovery summary store: %w", err)
	}
	if len(data) > maxPendingFolderDiscoverySummaryStoreSize {
		return errors.New("pending folder discovery summary store exceeds the supported size")
	}
	if err := s.writeFile(s.path, data); err != nil {
		return fmt.Errorf("write pending folder discovery summary store: %w", err)
	}
	return nil
}

// deriveEffectivePendingFolderDiscoveryConfiguration constructs an ephemeral
// network configuration that can connect to exactly one already-configured
// peer without configuring, scanning, or transferring any folder.
func deriveEffectivePendingFolderDiscoveryConfiguration(canonical config.Configuration, scope sessionDescriptor, localDeviceID protocol.DeviceID) (config.Configuration, *responseError) {
	effective := canonical.Copy()
	deviceID, err := protocol.DeviceIDFromString(scope.OfferingDeviceID)
	if err != nil || deviceID == protocol.EmptyDeviceID || deviceID == localDeviceID {
		return config.Configuration{}, commandError("invalid_device_id", "offeringDeviceID must identify a configured remote device")
	}
	target, _, exists := effective.Device(deviceID)
	if !exists {
		return config.Configuration{}, commandError("device_not_found", "offeringDeviceID is not configured")
	}
	if target.Paused {
		return config.Configuration{}, commandError("device_paused", "the offering device is paused in the canonical configuration")
	}

	effective.Folders = []config.FolderConfiguration{}
	devices := make([]config.DeviceConfiguration, 0, 2)
	for _, device := range effective.Devices {
		if device.DeviceID != localDeviceID && device.DeviceID != deviceID {
			continue
		}
		if device.DeviceID == deviceID {
			device.AutoAcceptFolders = false
			device.Introducer = false
			device.Paused = false
		}
		devices = append(devices, device)
	}
	effective.Devices = devices
	return effective, nil
}

func (c *Core) capturePendingFolderDiscoveryLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if c.session == nil || c.session.Mode != sessionModePendingFolderDiscovery || c.runtime == nil {
		return commandError("wrong_session_mode", "pending folder discovery capture requires a discovery session")
	}
	c.runtime.capturedPendingFolderDiscovery = nil
	if limit, valid := parseMaximumNetworkBytes(c.session.MaximumNetworkBytes); !valid || limit < 0 || limit > maxPendingFolderObservationNetworkBytes {
		return commandError("invalid_session", "maximumNetworkBytes must be a finite canonical decimal no greater than 8388608")
	} else if limit == 0 {
		return commandError("network_byte_limit_reached", "a zero network byte limit cannot produce authoritative pending-folder discovery evidence")
	}
	if c.stopRequested.Load() {
		return commandError("cancelled", "the pending folder discovery capture was cancelled")
	}
	if err := c.refreshPendingFolderObservationLocked(); err != nil {
		return err
	}
	observation := c.runtime.pendingFolderObservation
	now := time.Now().UTC()
	if observation != nil && now.Before(observation.observedAt) {
		return commandError("pending_folder_discovery_pending", "authoritative pending-folder discovery evidence is not yet valid")
	}
	if observation == nil || !now.Before(observation.observedAt.Add(pendingFolderObservationProofTTL)) {
		if c.networkByteLimitReachedLocked() {
			return commandError("network_byte_limit_reached", "the aggregate protocol byte limit was reached before authoritative pending-folder discovery evidence arrived")
		}
		return commandError("pending_folder_discovery_pending", "authoritative pending-folder discovery evidence has not arrived yet")
	}
	if observation.duplicateOffer {
		return commandError("pending_folder_discovery_pending", "authoritative pending-folder discovery evidence contains an ambiguous duplicate folder")
	}

	canonical, preflightErr := c.preflightPendingFolderDiscoveryCanonicalLocked()
	if preflightErr != nil {
		return preflightErr
	}
	deviceID, parseErr := protocol.DeviceIDFromString(c.session.OfferingDeviceID)
	if parseErr != nil || deviceID == protocol.EmptyDeviceID {
		return commandError("invalid_device_id", "offeringDeviceID is invalid")
	}
	_, _, _, suppressedFolderKeys, _, _ := suppressedPendingSnapshots(canonical, c.localDeviceID)
	summaries := make([]pendingFolderDiscoverySummary, 0, len(observation.offers))
	for _, offer := range observation.offers {
		key := suppressedPendingFolderKey{FolderID: offer.FolderID, OfferingDeviceID: deviceID}
		if _, suppressed := suppressedFolderKeys[key]; suppressed {
			continue
		}
		if _, _, configured := canonical.Folder(offer.FolderID); configured {
			continue
		}
		summaries = append(summaries, pendingFolderDiscoverySummaryFromOffer(offer, observation.connectionEpoch, observation.observedAt))
	}
	slices.SortFunc(summaries, func(left, right pendingFolderDiscoverySummary) int {
		return strings.Compare(left.FolderID, right.FolderID)
	})
	if c.stopRequested.Load() {
		return commandError("cancelled", "the pending folder discovery capture was cancelled")
	}
	// The event queue is fully drained above. Recheck the exact receive-owner
	// epoch only after the canonical disk preflight and immediately before the
	// sole durable write. Raw connection identity stays process-memory-only.
	if !c.pendingFolderObservationEpochCurrentLocked(observation) {
		return commandError("pending_folder_discovery_pending", "authoritative pending-folder discovery evidence is no longer current")
	}
	stored, truncated, storeErr := c.pendingFolderDiscoverySummaries.replaceDevice(deviceID, summaries, observation.sourceTruncated)
	if storeErr != nil {
		return commandError("pending_folder_discovery_store_unavailable", "the pending folder discovery summary could not be persisted")
	}
	c.runtime.capturedPendingFolderDiscovery = &pendingFolderDiscoveryBatch{
		OfferingDeviceID: deviceID.String(),
		ConnectionEpoch:  observation.connectionEpoch,
		ObservedAt:       observation.observedAt.UTC().Format(time.RFC3339Nano),
		Offers:           stored,
		Truncated:        truncated,
	}
	return nil
}

func (c *Core) preflightPendingFolderDiscoveryCanonicalLocked() (config.Configuration, *responseError) {
	if c == nil || c.session == nil || c.session.Mode != sessionModePendingFolderDiscovery {
		return config.Configuration{}, commandError("wrong_session_mode", "pending folder discovery canonical preflight requires a discovery session")
	}
	contents, err := os.ReadFile(filepath.Join(c.configurationDirectory, "config.xml"))
	if err != nil {
		return config.Configuration{}, commandError("configuration_verify_failed", "the canonical configuration could not be reread")
	}
	revision := configurationContentsRevision(contents)
	if revision != c.configurationRevision || revision != c.session.ExpectedConfigurationRevision {
		return config.Configuration{}, commandError("configuration_revision_mismatch", "the canonical configuration changed after the discovery session was planned")
	}
	canonical, originalVersion, err := config.ReadXML(bytes.NewReader(contents), c.localDeviceID)
	if err != nil || originalVersion != config.CurrentVersion {
		return config.Configuration{}, commandError("configuration_verify_failed", "the canonical configuration could not be verified")
	}
	deviceID, err := protocol.DeviceIDFromString(c.session.OfferingDeviceID)
	if err != nil || deviceID == protocol.EmptyDeviceID || deviceID == c.localDeviceID {
		return config.Configuration{}, commandError("invalid_device_id", "offeringDeviceID is invalid")
	}
	device, _, exists := canonical.Device(deviceID)
	if !exists {
		return config.Configuration{}, commandError("device_not_found", "offeringDeviceID is no longer configured")
	}
	if device.Paused {
		return config.Configuration{}, commandError("device_paused", "the offering device is paused in the canonical configuration")
	}
	return canonical, nil
}
