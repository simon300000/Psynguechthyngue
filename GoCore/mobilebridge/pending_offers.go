// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/base64"
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
	"unicode"
	"unicode/utf8"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	pendingDeviceStoreSchemaVersion = 1
	maxPendingDeviceEntries         = 512
	maxPendingDeviceStoreSize       = 1 << 20
	maxPendingFolderSnapshots       = 512
	maxSuppressedPendingSnapshots   = 512
)

type pendingDeviceRecord struct {
	DeviceID string `json:"deviceID"`
	Label    string `json:"label"`
	LastSeen string `json:"lastSeen"`
}

type pendingDeviceStoreDocument struct {
	SchemaVersion int                   `json:"schemaVersion"`
	Devices       []pendingDeviceRecord `json:"devices"`
}

// pendingDeviceStore is a bridge-owned, minimal projection of
// PendingDevicesChanged. The pinned Syncthing Internals API exposes pending
// folders but does not expose PendingDevices, so retaining the event projection
// is the only supported way to survive process reconstruction without reaching
// through Syncthing's internal database schema.
type pendingDeviceStore struct {
	mu      sync.Mutex
	path    string
	devices map[protocol.DeviceID]pendingDeviceRecord
	healthy bool
}

func loadPendingDeviceStore(home string) (*pendingDeviceStore, error) {
	store := &pendingDeviceStore{
		path:    filepath.Join(home, "Bridge", "pending-devices-v1.json"),
		devices: make(map[protocol.DeviceID]pendingDeviceRecord),
		healthy: true,
	}
	directory := filepath.Dir(store.path)
	if info, err := os.Lstat(directory); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("pending device store directory is not a real directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect pending device store directory: %w", err)
	}

	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect pending device store: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("pending device store is not a regular non-symlink file")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, errors.New("pending device store permissions must be 0600")
	}
	if info.Size() > maxPendingDeviceStoreSize {
		return nil, errors.New("pending device store exceeds the supported size")
	}

	handle, err := openCommandLedgerNoFollow(store.path)
	if err != nil {
		return nil, fmt.Errorf("open pending device store: %w", err)
	}
	defer handle.Close()
	openedInfo, err := handle.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect open pending device store: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || openedInfo.Mode().Perm() != 0o600 || !os.SameFile(info, openedInfo) {
		return nil, errors.New("pending device store changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(handle, maxPendingDeviceStoreSize+1))
	if err != nil {
		return nil, fmt.Errorf("read pending device store: %w", err)
	}
	if len(data) > maxPendingDeviceStoreSize {
		return nil, errors.New("pending device store exceeds the supported size")
	}

	var document pendingDeviceStoreDocument
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode pending device store: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("pending device store must contain exactly one JSON object")
	}
	if document.SchemaVersion != pendingDeviceStoreSchemaVersion {
		return nil, fmt.Errorf("unsupported pending device store schema %d", document.SchemaVersion)
	}
	if len(document.Devices) > maxPendingDeviceEntries {
		return nil, errors.New("pending device store entry limit exceeded")
	}
	for _, record := range document.Devices {
		deviceID, err := validatePendingDeviceRecord(record)
		if err != nil {
			return nil, err
		}
		if _, duplicate := store.devices[deviceID]; duplicate {
			return nil, errors.New("pending device store contains a duplicate device ID")
		}
		store.devices[deviceID] = record
	}
	return store, nil
}

func validatePendingDeviceRecord(record pendingDeviceRecord) (protocol.DeviceID, error) {
	deviceID, err := protocol.DeviceIDFromString(strings.ToUpper(record.DeviceID))
	if err != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != record.DeviceID {
		return protocol.EmptyDeviceID, errors.New("pending device store contains an invalid device ID")
	}
	if sanitizedPendingLabel(record.Label) != record.Label {
		return protocol.EmptyDeviceID, errors.New("pending device store contains an invalid label")
	}
	lastSeen, err := time.Parse(time.RFC3339Nano, record.LastSeen)
	if err != nil || lastSeen.IsZero() || record.LastSeen != lastSeen.UTC().Format(time.RFC3339Nano) {
		return protocol.EmptyDeviceID, errors.New("pending device store contains an invalid lastSeen timestamp")
	}
	return deviceID, nil
}

func (s *pendingDeviceStore) applyEvent(event events.Event) {
	if s == nil || event.Type != events.PendingDevicesChanged {
		return
	}
	encoded, err := json.Marshal(event.Data)
	if err != nil || len(encoded) > maxJSONRequestSize {
		return
	}
	var change struct {
		Added []struct {
			DeviceID string `json:"deviceID"`
			Name     string `json:"name"`
		} `json:"added"`
		Removed []struct {
			DeviceID string `json:"deviceID"`
		} `json:"removed"`
	}
	if err := json.Unmarshal(encoded, &change); err != nil {
		return
	}
	seenAt := event.Time.UTC()
	if seenAt.IsZero() {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for _, added := range change.Added {
		deviceID, err := protocol.DeviceIDFromString(strings.ToUpper(strings.TrimSpace(added.DeviceID)))
		if err != nil || deviceID == protocol.EmptyDeviceID {
			continue
		}
		if _, exists := s.devices[deviceID]; !exists && len(s.devices) >= maxPendingDeviceEntries {
			continue
		}
		record := pendingDeviceRecord{
			DeviceID: deviceID.String(),
			Label:    sanitizedPendingLabel(added.Name),
			LastSeen: seenAt.Format(time.RFC3339Nano),
		}
		if prior, exists := s.devices[deviceID]; !exists || prior != record {
			s.devices[deviceID] = record
			changed = true
		}
	}
	for _, removed := range change.Removed {
		deviceID, err := protocol.DeviceIDFromString(strings.ToUpper(strings.TrimSpace(removed.DeviceID)))
		if err != nil || deviceID == protocol.EmptyDeviceID {
			continue
		}
		if _, exists := s.devices[deviceID]; exists {
			delete(s.devices, deviceID)
			changed = true
		}
	}
	if changed && s.saveLocked() != nil {
		s.healthy = false
	}
}

func (s *pendingDeviceStore) remove(deviceID protocol.DeviceID) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.devices[deviceID]; !exists {
		return
	}
	delete(s.devices, deviceID)
	if s.saveLocked() != nil {
		s.healthy = false
	}
}

func (s *pendingDeviceStore) pruneConfigured(configured map[protocol.DeviceID]struct{}) {
	if s == nil || len(configured) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for deviceID := range configured {
		if _, exists := s.devices[deviceID]; exists {
			delete(s.devices, deviceID)
			changed = true
		}
	}
	if changed && s.saveLocked() != nil {
		s.healthy = false
	}
}

func (s *pendingDeviceStore) record(deviceID protocol.DeviceID) (pendingDeviceRecord, bool) {
	if s == nil {
		return pendingDeviceRecord{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, ok := s.devices[deviceID]
	return record, ok
}

func (s *pendingDeviceStore) snapshots(localDeviceID protocol.DeviceID, configured map[protocol.DeviceID]struct{}) ([]pendingDeviceSnapshot, string) {
	if s == nil {
		return []pendingDeviceSnapshot{}, "unavailable"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]pendingDeviceSnapshot, 0, len(s.devices))
	for deviceID, record := range s.devices {
		if deviceID == localDeviceID {
			continue
		}
		if _, exists := configured[deviceID]; exists {
			continue
		}
		result = append(result, pendingDeviceSnapshot{
			DeviceID:                   record.DeviceID,
			Label:                      record.Label,
			LastSeen:                   record.LastSeen,
			OfferVersion:               pendingDeviceOfferVersion(record),
			UnverifiedIdentity:         true,
			RequiresExplicitAcceptance: true,
		})
	}
	slices.SortFunc(result, func(left, right pendingDeviceSnapshot) int {
		return strings.Compare(left.DeviceID, right.DeviceID)
	})
	if s.healthy {
		return result, "bridgeEventsPersisted"
	}
	return result, "bridgeEventsMemoryOnly"
}

func (s *pendingDeviceStore) saveLocked() error {
	document := pendingDeviceStoreDocument{
		SchemaVersion: pendingDeviceStoreSchemaVersion,
		Devices:       make([]pendingDeviceRecord, 0, len(s.devices)),
	}
	for _, record := range s.devices {
		document.Devices = append(document.Devices, record)
	}
	slices.SortFunc(document.Devices, func(left, right pendingDeviceRecord) int {
		return strings.Compare(left.DeviceID, right.DeviceID)
	})
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode pending device store: %w", err)
	}
	if len(data) > maxPendingDeviceStoreSize {
		return errors.New("pending device store exceeds the supported size")
	}
	if err := writeCommandLedgerFile(s.path, data); err != nil {
		return fmt.Errorf("write pending device store: %w", err)
	}
	s.healthy = true
	return nil
}

func sanitizedPendingLabel(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > maxConfigurationNameBytes || !utf8.ValidString(value) {
		return ""
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return ""
		}
	}
	return value
}

func pendingDeviceOfferVersion(record pendingDeviceRecord) string {
	return stableOfferVersion("pending-device-v1", record.DeviceID, record.Label, record.LastSeen)
}

type pendingFolderOffer struct {
	FolderID         string
	Label            string
	OfferingDeviceID protocol.DeviceID
	LastSeen         time.Time
	ReceiveEncrypted bool
	RemoteEncrypted  bool
}

func (offer pendingFolderOffer) snapshot() pendingFolderSnapshot {
	lastSeen := offer.LastSeen.UTC().Format(time.RFC3339Nano)
	return pendingFolderSnapshot{
		FolderID:                        offer.FolderID,
		Label:                           offer.Label,
		OfferingDeviceID:                offer.OfferingDeviceID.String(),
		LastSeen:                        lastSeen,
		OfferVersion:                    pendingFolderOfferVersion(offer),
		ReceiveEncrypted:                offer.ReceiveEncrypted,
		RemoteEncrypted:                 offer.RemoteEncrypted,
		RequiresManagedLocalPath:        true,
		RequiresExplicitDeviceSelection: true,
		EvidenceSource:                  "live",
		RequiresNetworkRevalidation:     false,
	}
}

func pendingFolderOfferVersion(offer pendingFolderOffer) string {
	return stableOfferVersion(
		"pending-folder-v1",
		offer.FolderID,
		offer.Label,
		offer.OfferingDeviceID.String(),
		offer.LastSeen.UTC().Format(time.RFC3339Nano),
		fmt.Sprintf("%t", offer.ReceiveEncrypted),
		fmt.Sprintf("%t", offer.RemoteEncrypted),
	)
}

func stableOfferVersion(parts ...string) string {
	hash := sha256.New()
	for _, part := range parts {
		_, _ = hash.Write([]byte(part))
		_, _ = hash.Write([]byte{0})
	}
	return base64.RawURLEncoding.EncodeToString(hash.Sum(nil))
}

func isCanonicalStableVersion(value string) bool {
	if len(value) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return false
	}
	return base64.RawURLEncoding.EncodeToString(decoded) == value
}

type suppressedPendingFolderKey struct {
	FolderID         string
	OfferingDeviceID protocol.DeviceID
}

func suppressedPendingSnapshots(
	raw config.Configuration,
	localDeviceID protocol.DeviceID,
) (
	[]suppressedPendingDeviceSnapshot,
	[]suppressedPendingFolderSnapshot,
	map[protocol.DeviceID]struct{},
	map[suppressedPendingFolderKey]struct{},
	bool,
	bool,
) {
	configuredDevices := make(map[protocol.DeviceID]struct{}, len(raw.Devices))
	for _, device := range raw.Devices {
		configuredDevices[device.DeviceID] = struct{}{}
	}

	latestDevices := make(map[protocol.DeviceID]config.ObservedDevice, len(raw.IgnoredDevices))
	for _, ignored := range raw.IgnoredDevices {
		if ignored.ID == protocol.EmptyDeviceID || ignored.ID == localDeviceID {
			continue
		}
		if _, configured := configuredDevices[ignored.ID]; configured {
			continue
		}
		if prior, exists := latestDevices[ignored.ID]; !exists || prior.Time.Before(ignored.Time) {
			latestDevices[ignored.ID] = ignored
		}
	}
	suppressedDeviceIDs := make(map[protocol.DeviceID]struct{}, len(latestDevices))
	deviceSnapshots := make([]suppressedPendingDeviceSnapshot, 0, len(latestDevices))
	for deviceID, ignored := range latestDevices {
		suppressedDeviceIDs[deviceID] = struct{}{}
		deviceSnapshots = append(deviceSnapshots, suppressedPendingDeviceSnapshot{
			DeviceID:           deviceID.String(),
			SuppressionVersion: suppressedPendingDeviceVersion(ignored),
		})
	}
	slices.SortFunc(deviceSnapshots, func(left, right suppressedPendingDeviceSnapshot) int {
		return strings.Compare(left.DeviceID, right.DeviceID)
	})
	devicesTruncated := len(deviceSnapshots) > maxSuppressedPendingSnapshots
	if devicesTruncated {
		deviceSnapshots = deviceSnapshots[:maxSuppressedPendingSnapshots]
	}

	latestFolders := make(map[suppressedPendingFolderKey]config.ObservedFolder)
	for _, device := range raw.Devices {
		if device.DeviceID == protocol.EmptyDeviceID || device.DeviceID == localDeviceID {
			continue
		}
		for _, ignored := range device.IgnoredFolders {
			if validateFolderID(ignored.ID) != nil {
				continue
			}
			if configuredFolder, _, exists := raw.Folder(ignored.ID); exists && configuredFolder.SharedWith(device.DeviceID) {
				continue
			}
			key := suppressedPendingFolderKey{
				FolderID:         ignored.ID,
				OfferingDeviceID: device.DeviceID,
			}
			if prior, exists := latestFolders[key]; !exists || prior.Time.Before(ignored.Time) {
				latestFolders[key] = ignored
			}
		}
	}
	suppressedFolderKeys := make(map[suppressedPendingFolderKey]struct{}, len(latestFolders))
	folderSnapshots := make([]suppressedPendingFolderSnapshot, 0, len(latestFolders))
	for key, ignored := range latestFolders {
		suppressedFolderKeys[key] = struct{}{}
		folderSnapshots = append(folderSnapshots, suppressedPendingFolderSnapshot{
			FolderID:           key.FolderID,
			OfferingDeviceID:   key.OfferingDeviceID.String(),
			SuppressionVersion: suppressedPendingFolderVersion(key.OfferingDeviceID, ignored),
		})
	}
	slices.SortFunc(folderSnapshots, func(left, right suppressedPendingFolderSnapshot) int {
		if comparison := strings.Compare(left.FolderID, right.FolderID); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.OfferingDeviceID, right.OfferingDeviceID)
	})
	foldersTruncated := len(folderSnapshots) > maxSuppressedPendingSnapshots
	if foldersTruncated {
		folderSnapshots = folderSnapshots[:maxSuppressedPendingSnapshots]
	}

	return deviceSnapshots, folderSnapshots, suppressedDeviceIDs, suppressedFolderKeys, devicesTruncated, foldersTruncated
}

func suppressedPendingDeviceVersion(ignored config.ObservedDevice) string {
	return stableOfferVersion(
		"suppressed-pending-device-v1",
		ignored.ID.String(),
		ignored.Time.UTC().Format(time.RFC3339Nano),
	)
}

func suppressedPendingFolderVersion(deviceID protocol.DeviceID, ignored config.ObservedFolder) string {
	return stableOfferVersion(
		"suppressed-pending-folder-v1",
		ignored.ID,
		deviceID.String(),
		ignored.Time.UTC().Format(time.RFC3339Nano),
	)
}

func latestIgnoredDevice(ignored []config.ObservedDevice, deviceID protocol.DeviceID) (config.ObservedDevice, bool) {
	var latest config.ObservedDevice
	found := false
	for _, candidate := range ignored {
		if candidate.ID != deviceID {
			continue
		}
		if !found || latest.Time.Before(candidate.Time) {
			latest = candidate
			found = true
		}
	}
	return latest, found
}

func latestIgnoredFolder(ignored []config.ObservedFolder, folderID string) (config.ObservedFolder, bool) {
	var latest config.ObservedFolder
	found := false
	for _, candidate := range ignored {
		if candidate.ID != folderID {
			continue
		}
		if !found || latest.Time.Before(candidate.Time) {
			latest = candidate
			found = true
		}
	}
	return latest, found
}

func (c *Core) pendingFolderOffersLocked(deviceID protocol.DeviceID) ([]pendingFolderOffer, error) {
	if c.pendingFolderOffersForTests != nil {
		return c.pendingFolderOffersForTests(deviceID)
	}
	if c.runtime == nil || c.runtime.app == nil || c.runtime.app.Internals == nil {
		return nil, errors.New("pending folder source is unavailable")
	}
	pending, err := c.runtime.app.Internals.PendingFolders(deviceID)
	if err != nil {
		return nil, err
	}
	offers := make([]pendingFolderOffer, 0, len(pending))
	for folderID, pendingFolder := range pending {
		if validateFolderID(folderID) != nil {
			continue
		}
		for offeringDeviceID, observed := range pendingFolder.OfferedBy {
			if offeringDeviceID == protocol.EmptyDeviceID || offeringDeviceID == c.localDeviceID || observed.Time.IsZero() {
				continue
			}
			offers = append(offers, pendingFolderOffer{
				FolderID:         folderID,
				Label:            sanitizedPendingLabel(observed.Label),
				OfferingDeviceID: offeringDeviceID,
				LastSeen:         observed.Time.UTC(),
				ReceiveEncrypted: observed.ReceiveEncrypted,
				RemoteEncrypted:  observed.RemoteEncrypted,
			})
		}
	}
	slices.SortFunc(offers, func(left, right pendingFolderOffer) int {
		if comparison := strings.Compare(left.FolderID, right.FolderID); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.OfferingDeviceID.String(), right.OfferingDeviceID.String())
	})
	return offers, nil
}

func (c *Core) watchPendingDevices(subscription events.Subscription, done chan<- struct{}) {
	defer close(done)
	for event := range subscription.C() {
		c.pendingDevices.applyEvent(event)
	}
}
