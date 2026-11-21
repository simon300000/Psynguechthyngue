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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	pendingFolderObservationProofSchemaVersion = 2
	pendingFolderObservationProofLegacySchema  = 1
	maxPendingFolderObservationProofs          = 512
	maxPendingFolderObservationProofStoreSize  = 1 << 20
	pendingFolderObservationProofTTL           = 5 * time.Minute
	maxPendingFolderObservationNetworkBytes    = 8 << 20
)

var (
	errObservationProofNotFound       = errors.New("pending folder observation proof not found")
	errObservationProofExpired        = errors.New("pending folder observation proof expired")
	errObservationProofNotYetValid    = errors.New("pending folder observation proof is not yet valid")
	errObservationProofClockRollback  = errors.New("pending folder observation proof clock moved backwards")
	errObservationProofStoreFull      = errors.New("pending folder observation proof store is full")
	errObservationProofStoreUnhealthy = errors.New("pending folder observation proof store is unavailable")
)

// pendingFolderObservationProof is the complete durable authority handed from
// a network-only observation session to a later offline configuration session.
// ConnectionID is intentionally absent; ConnectionEpoch is a one-way digest.
type pendingFolderObservationProof struct {
	ProofID               string `json:"proofID"`
	FolderID              string `json:"folderID"`
	OfferingDeviceID      string `json:"offeringDeviceID"`
	OfferVersion          string `json:"offerVersion"`
	Label                 string `json:"label"`
	LastSeen              string `json:"lastSeen"`
	ReceiveEncrypted      bool   `json:"receiveEncrypted"`
	RemoteEncrypted       bool   `json:"remoteEncrypted"`
	ConfigurationRevision string `json:"configurationRevision"`
	ObservationSessionID  string `json:"observationSessionID"`
	ConnectionEpoch       string `json:"connectionEpoch"`
	ObservedAt            string `json:"observedAt"`
	ExpiresAt             string `json:"expiresAt"`
}

type pendingFolderObservationProofDocument struct {
	SchemaVersion  int                             `json:"schemaVersion"`
	ClockHighWater string                          `json:"clockHighWater,omitempty"`
	Proofs         []pendingFolderObservationProof `json:"proofs"`
}

type pendingFolderObservationProofStore struct {
	mu        sync.Mutex
	path      string
	proofs    map[string]pendingFolderObservationProof
	now       func() time.Time
	writeFile func(string, []byte) error

	wallHighWater time.Time
	clockFailed   bool
	storeFailed   bool
}

// authoritativePendingFolderObservation retains the raw connection identity
// only in process memory so capture can prove that the receive-owner epoch is
// still current. It is never serialized, logged, or returned across the ABI.
type authoritativePendingFolderObservation struct {
	generation      uint64
	connectionID    string
	connectionEpoch string
	observedAt      time.Time
	offers          map[string]pendingFolderOffer
	duplicateOffer  bool
	sourceTruncated bool
}

func loadPendingFolderObservationProofStore(home string) (*pendingFolderObservationProofStore, error) {
	return loadPendingFolderObservationProofStoreWithDependencies(home, time.Now, writePendingFolderObservationProofFile)
}

func loadPendingFolderObservationProofStoreWithDependencies(home string, now func() time.Time, writeFile func(string, []byte) error) (*pendingFolderObservationProofStore, error) {
	if now == nil || writeFile == nil {
		return nil, errObservationProofStoreUnhealthy
	}
	store := &pendingFolderObservationProofStore{
		path:      filepath.Join(home, "Bridge", "pending-folder-observation-proofs-v1.json"),
		proofs:    make(map[string]pendingFolderObservationProof),
		now:       now,
		writeFile: writeFile,
	}
	directory := filepath.Dir(store.path)
	if info, err := os.Lstat(directory); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("pending folder observation proof directory is not a real directory")
		}
		if info.Mode().Perm() != 0o700 {
			return nil, errors.New("pending folder observation proof directory permissions must be 0700")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect pending folder observation proof directory: %w", err)
	}

	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("inspect pending folder observation proof store: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("pending folder observation proof store is not a regular non-symlink file")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, errors.New("pending folder observation proof store permissions must be 0600")
	}
	if info.Size() > maxPendingFolderObservationProofStoreSize {
		return nil, errors.New("pending folder observation proof store exceeds the supported size")
	}

	handle, err := openCommandLedgerNoFollow(store.path)
	if err != nil {
		return nil, fmt.Errorf("open pending folder observation proof store: %w", err)
	}
	defer handle.Close()
	openedInfo, err := handle.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect open pending folder observation proof store: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || openedInfo.Mode().Perm() != 0o600 || !os.SameFile(info, openedInfo) {
		return nil, errors.New("pending folder observation proof store changed while it was being opened")
	}
	data, err := io.ReadAll(io.LimitReader(handle, maxPendingFolderObservationProofStoreSize+1))
	if err != nil {
		return nil, fmt.Errorf("read pending folder observation proof store: %w", err)
	}
	if len(data) > maxPendingFolderObservationProofStoreSize {
		return nil, errors.New("pending folder observation proof store exceeds the supported size")
	}

	if err := rejectDuplicatePendingFolderObservationJSONKeys(data); err != nil {
		return nil, err
	}
	var document pendingFolderObservationProofDocument
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode pending folder observation proof store: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errors.New("pending folder observation proof store must contain exactly one JSON object")
	}
	if document.SchemaVersion != pendingFolderObservationProofSchemaVersion && document.SchemaVersion != pendingFolderObservationProofLegacySchema {
		return nil, fmt.Errorf("unsupported pending folder observation proof schema %d", document.SchemaVersion)
	}
	if len(document.Proofs) > maxPendingFolderObservationProofs {
		return nil, errors.New("pending folder observation proof entry limit exceeded")
	}
	nowValue := store.now().UTC()
	if nowValue.IsZero() {
		return nil, errObservationProofStoreUnhealthy
	}
	if document.SchemaVersion == pendingFolderObservationProofLegacySchema {
		// Schema v1 had no durable rollback boundary. Its proofs cannot safely be
		// authorized after a process restart, so migration invalidates them and
		// must atomically establish a v2 high-water mark before the store is used.
		store.wallHighWater = nowValue
		if err := store.saveLocked(); err != nil {
			store.storeFailed = true
			return nil, fmt.Errorf("%w: migrate pending folder observation proof clock: %v", errObservationProofStoreUnhealthy, err)
		}
		return store, nil
	}
	highWater, err := parseCanonicalProofTime(document.ClockHighWater)
	if err != nil {
		return nil, errors.New("pending folder observation proof store contains an invalid clock high-water mark")
	}
	store.wallHighWater = highWater
	if nowValue.Before(highWater) {
		store.clockFailed = true
		return nil, errObservationProofClockRollback
	}
	for _, proof := range document.Proofs {
		expiresAt, validationErr := validatePendingFolderObservationProof(proof)
		if validationErr != nil {
			return nil, validationErr
		}
		observedAt, _ := parseCanonicalProofTime(proof.ObservedAt)
		if observedAt.After(highWater) {
			return nil, errors.New("pending folder observation proof postdates the durable clock high-water mark")
		}
		if nowValue.Before(observedAt) {
			return nil, errObservationProofNotYetValid
		}
		if _, duplicate := store.proofs[proof.ProofID]; duplicate {
			return nil, errors.New("pending folder observation proof store contains a duplicate proof ID")
		}
		if nowValue.Before(expiresAt) {
			store.proofs[proof.ProofID] = proof
		}
	}
	if nowValue.After(highWater) {
		priorHighWater := store.wallHighWater
		store.wallHighWater = nowValue
		if err := store.saveLocked(); err != nil {
			store.wallHighWater = priorHighWater
			store.storeFailed = true
			return nil, fmt.Errorf("%w: persist pending folder observation proof clock: %v", errObservationProofStoreUnhealthy, err)
		}
	}
	return store, nil
}

func rejectDuplicatePendingFolderObservationJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := scanPendingFolderObservationJSONValue(decoder); err != nil {
		return fmt.Errorf("decode pending folder observation proof store: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("pending folder observation proof store must contain exactly one JSON object")
	}
	return nil
}

func scanPendingFolderObservationJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, compound := token.(json.Delim)
	if !compound {
		return nil
	}
	switch delimiter {
	case '{':
		keys := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("object key is not a string")
			}
			if _, duplicate := keys[key]; duplicate {
				return errors.New("pending folder observation proof store contains a duplicate JSON key")
			}
			keys[key] = struct{}{}
			if err := scanPendingFolderObservationJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return errors.New("object is not terminated")
		}
	case '[':
		for decoder.More() {
			if err := scanPendingFolderObservationJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return errors.New("array is not terminated")
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	return nil
}

func validatePendingFolderObservationProof(proof pendingFolderObservationProof) (time.Time, error) {
	if !isCanonicalStableVersion(proof.ProofID) || !isCanonicalStableVersion(proof.OfferVersion) || !isCanonicalStableVersion(proof.ConnectionEpoch) {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid digest")
	}
	if validateFolderID(proof.FolderID) != nil || strings.TrimSpace(proof.FolderID) != proof.FolderID {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid folder ID")
	}
	deviceID, err := protocol.DeviceIDFromString(proof.OfferingDeviceID)
	if err != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != proof.OfferingDeviceID {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid offering device ID")
	}
	if sanitizedPendingLabel(proof.Label) != proof.Label || !isCanonicalSHA256(proof.ConfigurationRevision) {
		return time.Time{}, errors.New("pending folder observation proof contains invalid offer metadata")
	}
	if err := validateScopedIdentifier(proof.ObservationSessionID, maxSessionIDRunes, "observationSessionID"); err != nil {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid session ID")
	}
	lastSeen, err := parseCanonicalProofTime(proof.LastSeen)
	if err != nil {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid lastSeen timestamp")
	}
	observedAt, err := parseCanonicalProofTime(proof.ObservedAt)
	if err != nil {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid observedAt timestamp")
	}
	expiresAt, err := parseCanonicalProofTime(proof.ExpiresAt)
	if err != nil || !expiresAt.Equal(observedAt.Add(pendingFolderObservationProofTTL)) {
		return time.Time{}, errors.New("pending folder observation proof contains an invalid expiry")
	}
	offer := pendingFolderOffer{
		FolderID:         proof.FolderID,
		Label:            proof.Label,
		OfferingDeviceID: deviceID,
		LastSeen:         lastSeen,
		ReceiveEncrypted: proof.ReceiveEncrypted,
		RemoteEncrypted:  proof.RemoteEncrypted,
	}
	if pendingFolderOfferVersion(offer) != proof.OfferVersion || pendingFolderObservationProofID(proof) != proof.ProofID {
		return time.Time{}, errors.New("pending folder observation proof integrity check failed")
	}
	return expiresAt, nil
}

func parseCanonicalProofTime(value string) (time.Time, error) {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil || parsed.IsZero() || value != parsed.UTC().Format(time.RFC3339Nano) {
		return time.Time{}, errors.New("timestamp is not canonical UTC RFC3339Nano")
	}
	return parsed.UTC(), nil
}

func pendingFolderObservationProofID(proof pendingFolderObservationProof) string {
	// This unkeyed digest is a stable corruption/tamper detector, not a MAC or
	// an authentication boundary. OS ownership and the 0700 Bridge directory
	// protect the store; a same-UID writer with directory access can recompute it.
	return stableOfferVersion(
		"pending-folder-observation-proof-v1",
		proof.FolderID,
		proof.OfferingDeviceID,
		proof.OfferVersion,
		proof.Label,
		proof.LastSeen,
		strconv.FormatBool(proof.ReceiveEncrypted),
		strconv.FormatBool(proof.RemoteEncrypted),
		proof.ConfigurationRevision,
		proof.ObservationSessionID,
		proof.ConnectionEpoch,
		proof.ObservedAt,
		proof.ExpiresAt,
	)
}

func pendingFolderObservationConnectionEpoch(sessionID string, deviceID protocol.DeviceID, connectionID string, generation uint64) string {
	return stableOfferVersion(
		"pending-folder-connection-epoch-v1",
		sessionID,
		deviceID.String(),
		connectionID,
		strconv.FormatUint(generation, 10),
	)
}

func (s *pendingFolderObservationProofStore) trustedTime() (time.Time, error) {
	if s == nil {
		return time.Time{}, errObservationProofStoreUnhealthy
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.trustedTimeLocked()
}

func (s *pendingFolderObservationProofStore) trustedTimeLocked() (time.Time, error) {
	if s.clockFailed {
		return time.Time{}, errObservationProofClockRollback
	}
	if s.storeFailed {
		return time.Time{}, errObservationProofStoreUnhealthy
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now().UTC()
	}
	if now.IsZero() {
		s.storeFailed = true
		return time.Time{}, errObservationProofStoreUnhealthy
	}
	if !s.wallHighWater.IsZero() && now.Before(s.wallHighWater) {
		s.clockFailed = true
		return time.Time{}, errObservationProofClockRollback
	}
	if now.After(s.wallHighWater) {
		priorHighWater := s.wallHighWater
		s.wallHighWater = now
		if err := s.saveLocked(); err != nil {
			s.wallHighWater = priorHighWater
			s.storeFailed = true
			return time.Time{}, fmt.Errorf("%w: persist pending folder observation proof clock: %v", errObservationProofStoreUnhealthy, err)
		}
	}
	return now, nil
}

func (s *pendingFolderObservationProofStore) put(proof pendingFolderObservationProof) error {
	if s == nil {
		return errObservationProofStoreUnhealthy
	}
	expiresAt, err := validatePendingFolderObservationProof(proof)
	if err != nil {
		return err
	}
	observedAt, _ := parseCanonicalProofTime(proof.ObservedAt)
	s.mu.Lock()
	defer s.mu.Unlock()
	now, err := s.trustedTimeLocked()
	if err != nil {
		return err
	}
	if now.Before(observedAt) {
		return errObservationProofNotYetValid
	}
	if !now.Before(expiresAt) {
		return errObservationProofExpired
	}
	for proofID, candidate := range s.proofs {
		expiresAt, _ := parseCanonicalProofTime(candidate.ExpiresAt)
		if !now.Before(expiresAt) {
			delete(s.proofs, proofID)
		}
	}
	if existing, ok := s.proofs[proof.ProofID]; ok {
		if existing != proof {
			return errors.New("pending folder observation proof ID collision")
		}
		return nil
	}
	if len(s.proofs) >= maxPendingFolderObservationProofs {
		return errObservationProofStoreFull
	}
	s.proofs[proof.ProofID] = proof
	if err := s.saveLocked(); err != nil {
		delete(s.proofs, proof.ProofID)
		return err
	}
	return nil
}

func (s *pendingFolderObservationProofStore) get(proofID string) (pendingFolderObservationProof, error) {
	if s == nil {
		return pendingFolderObservationProof{}, errObservationProofStoreUnhealthy
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now, err := s.trustedTimeLocked()
	if err != nil {
		return pendingFolderObservationProof{}, err
	}
	proof, ok := s.proofs[proofID]
	if !ok {
		return pendingFolderObservationProof{}, errObservationProofNotFound
	}
	observedAt, err := parseCanonicalProofTime(proof.ObservedAt)
	if err != nil {
		return pendingFolderObservationProof{}, errObservationProofStoreUnhealthy
	}
	expiresAt, err := parseCanonicalProofTime(proof.ExpiresAt)
	if err != nil {
		return pendingFolderObservationProof{}, errObservationProofStoreUnhealthy
	}
	if now.Before(observedAt) {
		return pendingFolderObservationProof{}, errObservationProofNotYetValid
	}
	if !now.Before(expiresAt) {
		return pendingFolderObservationProof{}, errObservationProofExpired
	}
	return proof, nil
}

func (s *pendingFolderObservationProofStore) consume(proofID string) error {
	if s == nil {
		return errObservationProofStoreUnhealthy
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	proof, ok := s.proofs[proofID]
	if !ok {
		return nil
	}
	delete(s.proofs, proofID)
	if err := s.saveLocked(); err != nil {
		s.proofs[proofID] = proof
		return err
	}
	return nil
}

func (s *pendingFolderObservationProofStore) saveLocked() error {
	if s.wallHighWater.IsZero() {
		return errors.New("pending folder observation proof clock high-water mark is unavailable")
	}
	document := pendingFolderObservationProofDocument{
		SchemaVersion:  pendingFolderObservationProofSchemaVersion,
		ClockHighWater: s.wallHighWater.UTC().Format(time.RFC3339Nano),
		Proofs:         make([]pendingFolderObservationProof, 0, len(s.proofs)),
	}
	for _, proof := range s.proofs {
		document.Proofs = append(document.Proofs, proof)
	}
	slices.SortFunc(document.Proofs, func(left, right pendingFolderObservationProof) int {
		return strings.Compare(left.ProofID, right.ProofID)
	})
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode pending folder observation proof store: %w", err)
	}
	if len(data) > maxPendingFolderObservationProofStoreSize {
		return errors.New("pending folder observation proof store exceeds the supported size")
	}
	if err := s.writeFile(s.path, data); err != nil {
		return fmt.Errorf("write pending folder observation proof store: %w", err)
	}
	return nil
}

func (c *Core) capturePendingFolderObservationLocked(request commandRequest) *responseError {
	if err := c.requireRunningLocked(); err != nil {
		return err
	}
	if c.session == nil || c.session.Mode != sessionModePendingFolderObservation || c.runtime == nil {
		return commandError("wrong_session_mode", "pending folder observation capture requires an observation session")
	}
	if err := c.refreshPendingFolderObservationLocked(); err != nil {
		return err
	}
	observation := c.runtime.pendingFolderObservation
	now, clockErr := c.pendingFolderObservationProofs.trustedTime()
	if clockErr != nil {
		return commandError("observation_proof_store_unavailable", "the pending folder observation proof clock is unavailable")
	}
	if observation != nil && now.Before(observation.observedAt) {
		return commandError("pending_folder_observation_pending", "authoritative pending-folder evidence is not yet valid")
	}
	if observation == nil || !now.Before(observation.observedAt.Add(pendingFolderObservationProofTTL)) {
		if c.networkByteLimitReachedLocked() {
			return commandError("network_byte_limit_reached", "the aggregate protocol byte limit was reached before authoritative pending-folder evidence arrived")
		}
		return commandError("pending_folder_observation_pending", "authoritative pending-folder evidence has not arrived yet")
	}
	offer, found := observation.offers[c.session.FolderID]
	if !found {
		return commandError("pending_folder_not_found", "the authoritative ClusterConfig does not offer the scoped folder")
	}
	// refreshPendingFolderObservationLocked drains every queued observation.
	// Validate the exact receive-owner epoch after that drain and immediately
	// before signing the durable proof. Raw connection identity remains memory
	// only and is never included in the returned error or proof document.
	if !c.pendingFolderObservationEpochCurrentLocked(observation) {
		return commandError("pending_folder_observation_pending", "authoritative pending-folder evidence is no longer current")
	}
	proof := pendingFolderObservationProof{
		FolderID:              offer.FolderID,
		OfferingDeviceID:      offer.OfferingDeviceID.String(),
		OfferVersion:          pendingFolderOfferVersion(offer),
		Label:                 offer.Label,
		LastSeen:              offer.LastSeen.UTC().Format(time.RFC3339Nano),
		ReceiveEncrypted:      offer.ReceiveEncrypted,
		RemoteEncrypted:       offer.RemoteEncrypted,
		ConfigurationRevision: c.session.ExpectedConfigurationRevision,
		ObservationSessionID:  c.session.SessionID,
		ConnectionEpoch:       observation.connectionEpoch,
		ObservedAt:            observation.observedAt.UTC().Format(time.RFC3339Nano),
		ExpiresAt:             observation.observedAt.Add(pendingFolderObservationProofTTL).UTC().Format(time.RFC3339Nano),
	}
	proof.ProofID = pendingFolderObservationProofID(proof)
	if err := c.pendingFolderObservationProofs.put(proof); err != nil {
		if errors.Is(err, errObservationProofStoreFull) {
			return commandError("observation_proof_store_full", "pending folder observation proof store is full")
		}
		return commandError("observation_proof_store_unavailable", "the pending folder observation proof could not be persisted")
	}
	c.runtime.capturedPendingFolderObservation = &proof
	return nil
}

func (c *Core) refreshPendingFolderObservationLocked() *responseError {
	if c.runtime == nil || c.runtime.pendingFolderObservationSubscription == nil || c.session == nil {
		return commandError("pending_state_unavailable", "the authoritative pending-folder event source is unavailable")
	}
	for {
		select {
		case event, ok := <-c.runtime.pendingFolderObservationSubscription.C():
			if !ok {
				return commandError("pending_state_unavailable", "the authoritative pending-folder event source closed")
			}
			data, ok := event.Data.(model.ClusterConfigReceivedEventData)
			if !ok || data.Device.String() != c.session.OfferingDeviceID || data.ConnectionID == "" || data.ConnectionEpoch == 0 || event.Time.IsZero() {
				continue
			}
			if prior := c.runtime.pendingFolderObservation; prior != nil && data.ConnectionEpoch <= prior.generation {
				continue
			}
			offerCapacity := len(data.PendingFolders)
			if c.session.Mode == sessionModePendingFolderDiscovery && offerCapacity > maxPendingFolderDiscoverySummaries {
				offerCapacity = maxPendingFolderDiscoverySummaries
			} else if c.session.Mode == sessionModePendingFolderObservation {
				offerCapacity = 1
			}
			offers := make(map[string]pendingFolderOffer, offerCapacity)
			duplicateOffer := false
			sourceTruncated := false
			for _, pending := range data.PendingFolders {
				if validateFolderID(pending.FolderID) != nil || pending.LastSeen.IsZero() {
					sourceTruncated = true
					continue
				}
				if c.session.Mode == sessionModePendingFolderObservation && pending.FolderID != c.session.FolderID {
					continue
				}
				if _, duplicate := offers[pending.FolderID]; duplicate {
					duplicateOffer = true
					continue
				}
				offer := pendingFolderOffer{
					FolderID:         pending.FolderID,
					Label:            sanitizedPendingLabel(pending.Label),
					OfferingDeviceID: data.Device,
					LastSeen:         pending.LastSeen.UTC(),
					ReceiveEncrypted: pending.ReceiveEncrypted,
					RemoteEncrypted:  pending.RemoteEncrypted,
				}
				if c.session.Mode == sessionModePendingFolderDiscovery && len(offers) == maxPendingFolderDiscoverySummaries {
					sourceTruncated = true
					largestFolderID := ""
					for retainedFolderID := range offers {
						if retainedFolderID > largestFolderID {
							largestFolderID = retainedFolderID
						}
					}
					if pending.FolderID >= largestFolderID {
						continue
					}
					delete(offers, largestFolderID)
				}
				offers[pending.FolderID] = offer
			}
			c.runtime.pendingFolderObservation = &authoritativePendingFolderObservation{
				generation:      data.ConnectionEpoch,
				connectionID:    data.ConnectionID,
				connectionEpoch: pendingFolderObservationConnectionEpoch(c.session.SessionID, data.Device, data.ConnectionID, data.ConnectionEpoch),
				observedAt:      event.Time.UTC(),
				offers:          offers,
				duplicateOffer:  duplicateOffer,
				sourceTruncated: sourceTruncated,
			}
		default:
			return nil
		}
	}
}

func (c *Core) pendingFolderObservationEpochCurrentLocked(observation *authoritativePendingFolderObservation) bool {
	if c == nil || c.session == nil || c.runtime == nil || observation == nil || observation.connectionID == "" || observation.generation == 0 {
		return false
	}
	deviceID, err := protocol.DeviceIDFromString(c.session.OfferingDeviceID)
	if err != nil || deviceID == protocol.EmptyDeviceID {
		return false
	}
	if c.pendingFolderObservationEpochCurrentForTests != nil {
		return c.pendingFolderObservationEpochCurrentForTests(deviceID, observation.connectionID, observation.generation)
	}
	if c.runtime.app == nil {
		return false
	}
	return c.runtime.app.Internals.RemoteIndexEpochCurrent(deviceID, observation.connectionID, observation.generation)
}

func (c *Core) pendingFolderObservationProofForCommandLocked(request commandRequest, folderID string, deviceID protocol.DeviceID, offerVersion string) (pendingFolderObservationProof, *responseError) {
	proofID, ok := requiredCommandArgument(request.Arguments, "observationProofID")
	if !ok || !isCanonicalStableVersion(proofID) {
		return pendingFolderObservationProof{}, commandError("invalid_request", "observationProofID must be a canonical proof digest")
	}
	proof, err := c.pendingFolderObservationProofs.get(proofID)
	if err != nil {
		switch {
		case errors.Is(err, errObservationProofNotFound):
			return pendingFolderObservationProof{}, commandError("observation_proof_not_found", "the pending folder observation proof is unavailable")
		case errors.Is(err, errObservationProofExpired):
			return pendingFolderObservationProof{}, commandError("observation_proof_expired", "the pending folder observation proof expired")
		default:
			return pendingFolderObservationProof{}, commandError("observation_proof_store_unavailable", "the pending folder observation proof store is unavailable")
		}
	}
	if proof.FolderID != folderID || proof.OfferingDeviceID != deviceID.String() {
		return pendingFolderObservationProof{}, commandError("observation_proof_scope_mismatch", "the proof does not authorize this folder and offering device")
	}
	if proof.OfferVersion != offerVersion {
		return pendingFolderObservationProof{}, commandError("offer_version_conflict", "the proof does not authorize this offer version")
	}
	if proof.ConfigurationRevision != request.CommandConfigurationRevision || proof.ConfigurationRevision != c.configurationRevision {
		return pendingFolderObservationProof{}, commandError("observation_proof_configuration_mismatch", "the proof does not authorize the current canonical configuration revision")
	}
	return proof, nil
}

func (proof pendingFolderObservationProof) offer() (pendingFolderOffer, error) {
	deviceID, err := protocol.DeviceIDFromString(proof.OfferingDeviceID)
	if err != nil {
		return pendingFolderOffer{}, err
	}
	lastSeen, err := parseCanonicalProofTime(proof.LastSeen)
	if err != nil {
		return pendingFolderOffer{}, err
	}
	return pendingFolderOffer{
		FolderID:         proof.FolderID,
		Label:            proof.Label,
		OfferingDeviceID: deviceID,
		LastSeen:         lastSeen,
		ReceiveEncrypted: proof.ReceiveEncrypted,
		RemoteEncrypted:  proof.RemoteEncrypted,
	}, nil
}

func deriveEffectivePendingFolderObservationConfiguration(canonical config.Configuration, scope sessionDescriptor, localDeviceID protocol.DeviceID) (config.Configuration, *responseError) {
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
	if _, _, exists := effective.Folder(scope.FolderID); exists {
		return config.Configuration{}, commandError("folder_state_conflict", "the scoped folder is already configured")
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
