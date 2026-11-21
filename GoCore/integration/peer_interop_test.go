// SPDX-License-Identifier: MIT

//go:build peerinterop

package integration

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoCore/mobilebridge"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	expectedCoreRevision      = "syncthing-v2.1.3@946e2b83a1f6c6ae119427c09e0a5802940b82ff"
	interopFolderID           = "peer-interop"
	discoveryFolderID         = "peer-discovery-extra"
	interopTimeout            = 45 * time.Second
	interopRescanIntervalS    = 3600
	standardPeerWatcherDelay  = 10 * time.Second
	standardPeerWatcherSettle = standardPeerWatcherDelay + 2*time.Second
)

type bridgeEnvelope struct {
	SchemaVersion int             `json:"schemaVersion"`
	RequestID     string          `json:"requestID"`
	Kind          string          `json:"kind"`
	OK            bool            `json:"ok"`
	Payload       json.RawMessage `json:"payload"`
	Error         *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type bridgeSnapshot struct {
	CoreRevision          string `json:"coreRevision"`
	DeviceID              string `json:"deviceID"`
	Running               bool   `json:"running"`
	ConfigurationRevision string `json:"configurationRevision"`
	Devices               []struct {
		DeviceID  string `json:"deviceID"`
		Connected bool   `json:"connected"`
		Local     bool   `json:"local"`
	} `json:"devices"`
	Folders []struct {
		FolderID  string   `json:"folderID"`
		Type      string   `json:"type"`
		DeviceIDs []string `json:"deviceIDs"`
		State     string   `json:"state"`
	} `json:"folders"`
	PendingDevices []struct {
		DeviceID                   string `json:"deviceID"`
		OfferVersion               string `json:"offerVersion"`
		UnverifiedIdentity         bool   `json:"unverifiedIdentity"`
		RequiresExplicitAcceptance bool   `json:"requiresExplicitAcceptance"`
	} `json:"pendingDevices"`
	PendingFolders []struct {
		FolderID                    string `json:"folderID"`
		OfferingDeviceID            string `json:"offeringDeviceID"`
		OfferVersion                string `json:"offerVersion"`
		EvidenceSource              string `json:"evidenceSource"`
		RequiresNetworkRevalidation bool   `json:"requiresNetworkRevalidation"`
	} `json:"pendingFolders"`
	SuppressedPendingFolders []struct {
		FolderID           string `json:"folderID"`
		OfferingDeviceID   string `json:"offeringDeviceID"`
		SuppressionVersion string `json:"suppressionVersion"`
	} `json:"suppressedPendingFolders"`
	SuppressedPendingStateAvailable bool `json:"suppressedPendingStateAvailable"`
	NetworkPolicy                   struct {
		ManagementHTTPEnabled bool `json:"managementHTTPEnabled"`
		UsageReportingEnabled bool `json:"usageReportingEnabled"`
		CrashReportingEnabled bool `json:"crashReportingEnabled"`
		AutoUpgradeEnabled    bool `json:"autoUpgradeEnabled"`
	} `json:"networkPolicy"`
}

type pendingFolderDiscoveryPayload struct {
	PendingFolderDiscovery *struct {
		OfferingDeviceID string `json:"offeringDeviceID"`
		ConnectionEpoch  string `json:"connectionEpoch"`
		Offers           []struct {
			FolderID         string `json:"folderID"`
			OfferingDeviceID string `json:"offeringDeviceID"`
			OfferVersion     string `json:"offerVersion"`
			ConnectionEpoch  string `json:"connectionEpoch"`
		} `json:"offers"`
		Truncated bool `json:"truncated"`
	} `json:"pendingFolderDiscovery"`
}

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

type pendingFolderObservationPayload struct {
	PendingFolderObservation *pendingFolderObservationProof `json:"pendingFolderObservation"`
}

type networkTransferTotalsPayload struct {
	ReceivedBytes    int64 `json:"receivedBytes"`
	SentBytes        int64 `json:"sentBytes"`
	BudgetLimited    bool  `json:"budgetLimited"`
	BudgetLimitBytes int64 `json:"budgetLimitBytes"`
	BudgetUsedBytes  int64 `json:"budgetUsedBytes"`
	BudgetExhausted  bool  `json:"budgetExhausted"`
}

type directionalNetworkSession struct {
	phase                 string
	operation             string
	sessionID             string
	taskID                string
	planDigest            string
	configurationRevision string
	maximumNetworkBytes   string
}

type itemQueryPayload struct {
	Items []struct {
		RelativePath             string   `json:"relativePath"`
		LocalPresent             bool     `json:"localPresent"`
		Tombstone                bool     `json:"tombstone"`
		ConnectedRemoteDeviceIDs []string `json:"connectedRemoteDeviceIDs"`
	} `json:"items"`
}

type eventQueryPayload struct {
	Events []struct {
		Type string `json:"type"`
	} `json:"events"`
}

type sparseFileMarker struct {
	offset int64
	data   []byte
}

// TestPeerInterop is intentionally opt-in. GoCore/Scripts/test-peer-interop.sh
// builds each exact, checksum-pinned upstream cmd/syncthing peer and supplies
// its absolute path plus independently expected source/version attestations.
func TestPeerInterop(t *testing.T) {
	peerBinary := os.Getenv("PEER_INTEROP_SYNCTHING")
	if !filepath.IsAbs(peerBinary) {
		t.Fatal("PEER_INTEROP_SYNCTHING must be an absolute path supplied by the peer-interop runner")
	}
	expectedPeerCommit := os.Getenv("PEER_INTEROP_UPSTREAM_COMMIT")
	commitBytes, err := hex.DecodeString(expectedPeerCommit)
	if err != nil || len(commitBytes) != 20 {
		t.Fatal("PEER_INTEROP_UPSTREAM_COMMIT must attest one exact Git commit")
	}
	expectedPeerRelease := os.Getenv("PEER_INTEROP_RELEASE")
	if expectedPeerRelease == "" || len(expectedPeerRelease) > 128 ||
		strings.ContainsAny(expectedPeerRelease, "\t\r\n ") {
		t.Fatal("PEER_INTEROP_RELEASE must be a bounded single token")
	}
	assertPeerBinaryVersion(t, peerBinary, expectedPeerRelease, expectedPeerCommit)
	if revision := mobilebridge.CoreRevision(); revision != expectedCoreRevision {
		t.Fatalf("unexpected bridge core revision %q", revision)
	}

	testRoot := t.TempDir()
	bridgeHome := filepath.Join(testRoot, "bridge-home")
	bridgeFolder := filepath.Join(testRoot, "bridge-folder")
	peerHome := filepath.Join(testRoot, "peer-home")
	peerFolder := filepath.Join(testRoot, "peer-folder")
	peerDiscoveryFolder := filepath.Join(testRoot, "peer-discovery-folder")
	for _, directory := range []string{bridgeHome, bridgeFolder, peerHome, peerFolder, peerDiscoveryFolder} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}

	addresses := reserveLoopbackAddresses(t, 4)
	bridgeBEP, peerBEP, bridgeGUI, peerGUI := addresses[0], addresses[1], addresses[2], addresses[3]

	core, err := mobilebridge.NewCore(bridgeHome, nil)
	if err != nil {
		t.Fatal(err)
	}
	coreClosed := false
	t.Cleanup(func() {
		if !coreClosed {
			_ = core.Close()
		}
	})
	bridgeIdentity := core.IdentityBlob()
	t.Cleanup(func() { clear(bridgeIdentity) })
	bridgeID := mustDeviceID(t, core.DeviceID())

	generatePeerIdentity(t, peerBinary, peerHome, testRoot)
	peerCertificate, err := tls.LoadX509KeyPair(
		filepath.Join(peerHome, "cert.pem"),
		filepath.Join(peerHome, "key.pem"),
	)
	if err != nil {
		t.Fatalf("load temporary peer identity: %v", err)
	}
	if len(peerCertificate.Certificate) == 0 {
		t.Fatal("temporary peer certificate is empty")
	}
	peerID := protocol.NewDeviceID(peerCertificate.Certificate[0])
	peerCertificate.PrivateKey = nil

	writeBridgeBootstrapConfig(t, bridgeHome, bridgeID, bridgeBEP, bridgeGUI)
	writePeerConfig(t, peerHome, peerFolder, peerDiscoveryFolder, peerID, bridgeID, peerBEP, bridgeBEP, peerGUI)
	releaseReservedAddresses(t)

	if err := core.Start(); err != nil {
		t.Fatalf("start bridge core: %v", err)
	}
	wrongPeerID := protocol.NewDeviceID([]byte("peer interop wrong expected certificate identity"))
	commandOK(t, core, "add-peer-wrong-identity", "addDevice", "", wrongPeerID.String(), map[string]string{
		"name":      "peer-interop",
		"addresses": "tcp://" + peerBEP,
		"paused":    "false",
	})

	peer := startPeer(t, peerBinary, peerHome, testRoot)
	t.Cleanup(func() { peer.stop(t, testRoot) })
	waitForTCP(t, peerBEP, interopTimeout)
	offerVersion := waitForRejectedCertificateIdentity(t, core, wrongPeerID.String(), peerID.String(), interopTimeout)
	commandOK(t, core, "remove-peer-wrong-identity", "removeDevice", "", wrongPeerID.String(), nil)
	commandOK(t, core, "accept-pending-peer", "acceptDevice", "", peerID.String(), map[string]string{
		"offerVersion": offerVersion,
		"name":         "peer-interop",
		"paused":       "false",
	})
	commandOK(t, core, "configure-accepted-peer-address", "editDevice", "", peerID.String(), map[string]string{
		"addresses": "tcp://" + peerBEP,
	})
	waitForConnected(t, core, peerID.String(), interopTimeout)
	preDiscovery := snapshot(t, core, "zero-shared-folder-connected")
	if len(preDiscovery.Folders) != 0 || preDiscovery.ConfigurationRevision == "" {
		t.Fatalf("zero-folder peer connection fixture is invalid: folders=%d revision=%q", len(preDiscovery.Folders), preDiscovery.ConfigurationRevision)
	}
	t.Log("mismatched TLS certificate identity was rejected; the verified pending device was explicitly accepted before reconnecting")
	t.Log("configured peer established BEP with zero shared folders")

	if err := core.Stop(); err != nil {
		t.Fatalf("stop zero-folder bridge before discovery: %v", err)
	}
	if err := core.Close(); err != nil {
		t.Fatalf("close zero-folder bridge before explicit discovery: %v", err)
	}
	coreClosed = true
	discoveryCore, err := mobilebridge.NewCore(bridgeHome, bridgeIdentity)
	if err != nil {
		t.Fatalf("reconstruct bridge for explicit discovery: %v", err)
	}
	core = discoveryCore
	coreClosed = false
	canonicalAfterLegacyClose, err := os.ReadFile(filepath.Join(bridgeHome, "Config", "config.xml"))
	if err != nil {
		t.Fatalf("read canonical configuration before discovery: %v", err)
	}
	discoveryRevisionBytes := sha256.Sum256(canonicalAfterLegacyClose)
	discoveryRevision := hex.EncodeToString(discoveryRevisionBytes[:])
	discoveryTaskID := "peer-interop-pending-folder-discovery"
	discoveryMaximumBytes := "8388608"
	discoveryPlanDigest := pendingFolderDiscoveryPlanDigest(discoveryTaskID, peerID.String(), discoveryRevision, discoveryMaximumBytes)
	discoverySessionID := "peer-interop-discovery"
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "open-real-discovery",
		"command":                       "openPendingFolderDiscoverySession",
		"sessionID":                     discoverySessionID,
		"offeringDeviceID":              peerID.String(),
		"taskID":                        discoveryTaskID,
		"planDigest":                    discoveryPlanDigest,
		"expectedConfigurationRevision": discoveryRevision,
		"maximumNetworkBytes":           discoveryMaximumBytes,
	})
	waitForConnected(t, core, peerID.String(), interopTimeout)
	discovered := captureRealPendingFolderDiscovery(t, core, discoverySessionID, discoveryTaskID, discoveryPlanDigest, discoveryRevision, discoveryMaximumBytes, peerID.String())
	if discovered.PendingFolderDiscovery == nil || discovered.PendingFolderDiscovery.Truncated || len(discovered.PendingFolderDiscovery.Offers) != 2 || discovered.PendingFolderDiscovery.OfferingDeviceID != peerID.String() || !isCanonicalStableVersion(discovered.PendingFolderDiscovery.ConnectionEpoch) {
		t.Fatalf("real zero-folder discovery returned an invalid batch: %+v", discovered.PendingFolderDiscovery)
	}
	discoveredIDs := make(map[string]bool)
	for _, offer := range discovered.PendingFolderDiscovery.Offers {
		if offer.OfferingDeviceID != peerID.String() || offer.ConnectionEpoch != discovered.PendingFolderDiscovery.ConnectionEpoch || !isCanonicalStableVersion(offer.OfferVersion) {
			t.Fatalf("real discovery crossed device or epoch scope: %+v", offer)
		}
		discoveredIDs[offer.FolderID] = true
	}
	if !discoveredIDs[interopFolderID] || !discoveredIDs[discoveryFolderID] {
		t.Fatalf("real discovery omitted peer offers: %+v", discoveredIDs)
	}
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "close-real-discovery",
		"command":                       "closeSession",
		"sessionID":                     discoverySessionID,
		"taskID":                        discoveryTaskID,
		"planDigest":                    discoveryPlanDigest,
		"expectedConfigurationRevision": discoveryRevision,
		"maximumNetworkBytes":           discoveryMaximumBytes,
	})
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "open-real-discovery-summary",
		"command":       "openConfiguration",
		"sessionID":     "real-discovery-summary",
	})
	summarySnapshot := snapshot(t, core, "real-discovery-summary-snapshot")
	if len(summarySnapshot.PendingFolders) != 2 {
		t.Fatalf("real discovery summaries were not projected offline: %+v", summarySnapshot.PendingFolders)
	}
	for _, offer := range summarySnapshot.PendingFolders {
		if offer.EvidenceSource != "durableSummary" || !offer.RequiresNetworkRevalidation {
			t.Fatalf("real discovery summary was upgraded to acceptance authority: %+v", offer)
		}
	}
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "close-real-discovery-summary",
		"command":       "closeSession",
		"sessionID":     "real-discovery-summary",
	})
	privacyValues := []string{
		bridgeHome,
		bridgeFolder,
		peerHome,
		peerFolder,
		peerDiscoveryFolder,
		bridgeBEP,
		peerBEP,
		bridgeGUI,
		peerGUI,
	}

	acceptedProof := observeRealPendingFolder(
		t,
		core,
		"accept",
		interopFolderID,
		peerID.String(),
		discoveryRevision,
		discoveryMaximumBytes,
		privacyValues...,
	)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "open-proof-accept-configuration",
		"command":       "openConfiguration",
		"sessionID":     "proof-accept-configuration",
	})
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                1,
		"requestID":                    "proof-backed-accept-real-offer",
		"command":                      "acceptFolder",
		"sessionID":                    "proof-accept-configuration",
		"commandConfigurationRevision": acceptedProof.ConfigurationRevision,
		"folderID":                     acceptedProof.FolderID,
		"arguments": map[string]string{
			"offeringDeviceID":   acceptedProof.OfferingDeviceID,
			"offerVersion":       acceptedProof.OfferVersion,
			"observationProofID": acceptedProof.ProofID,
			"label":              "peer-interop",
			"path":               bridgeFolder,
			"type":               "sendReceive",
			"paused":             "false",
			"deviceIDs":          peerID.String(),
			"rescanIntervalS":    strconv.Itoa(interopRescanIntervalS),
		},
	})
	acceptedSnapshot := snapshot(t, core, "proof-backed-accept-snapshot")
	if acceptedSnapshot.ConfigurationRevision == acceptedProof.ConfigurationRevision ||
		!snapshotHasFolder(acceptedSnapshot, interopFolderID, bridgeID.String(), peerID.String()) {
		t.Fatalf("proof-backed accept did not advance the bound configuration: before=%q after=%q folders=%+v", acceptedProof.ConfigurationRevision, acceptedSnapshot.ConfigurationRevision, acceptedSnapshot.Folders)
	}
	assertObservationProofConsumed(t, bridgeHome, acceptedProof.ProofID)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "close-proof-accept-configuration",
		"command":       "closeSession",
		"sessionID":     "proof-accept-configuration",
	})
	t.Log("real standard-peer offer passed bounded observation, durable proof capture, revision-bound acceptance, and proof consumption")

	ignoredProof := observeRealPendingFolder(
		t,
		core,
		"ignore",
		discoveryFolderID,
		peerID.String(),
		acceptedSnapshot.ConfigurationRevision,
		discoveryMaximumBytes,
		privacyValues...,
	)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "open-proof-ignore-configuration",
		"command":       "openConfiguration",
		"sessionID":     "proof-ignore-configuration",
	})
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                1,
		"requestID":                    "proof-backed-ignore-real-offer",
		"command":                      "ignorePendingFolder",
		"sessionID":                    "proof-ignore-configuration",
		"commandConfigurationRevision": ignoredProof.ConfigurationRevision,
		"folderID":                     ignoredProof.FolderID,
		"arguments": map[string]string{
			"offeringDeviceID":   ignoredProof.OfferingDeviceID,
			"offerVersion":       ignoredProof.OfferVersion,
			"observationProofID": ignoredProof.ProofID,
		},
	})
	ignoredSnapshot := snapshot(t, core, "proof-backed-ignore-snapshot")
	if ignoredSnapshot.ConfigurationRevision == ignoredProof.ConfigurationRevision {
		t.Fatal("proof-backed ignore did not advance the bound configuration revision")
	}
	ignoredSuppressionVersion := suppressionVersionForFolder(t, ignoredSnapshot, discoveryFolderID, peerID.String())
	if snapshotHasPendingFolder(ignoredSnapshot, discoveryFolderID, peerID.String()) {
		t.Fatal("proof-backed ignore left the offered folder visible")
	}
	assertObservationProofConsumed(t, bridgeHome, ignoredProof.ProofID)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "close-proof-ignore-configuration",
		"command":       "closeSession",
		"sessionID":     "proof-ignore-configuration",
	})

	if err := core.Close(); err != nil {
		t.Fatalf("close bridge before durable suppression reconstruction: %v", err)
	}
	coreClosed = true
	reconstructedAfterIgnore, err := mobilebridge.NewCore(bridgeHome, bridgeIdentity)
	if err != nil {
		t.Fatalf("reconstruct bridge after proof-backed ignore: %v", err)
	}
	core = reconstructedAfterIgnore
	coreClosed = false
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "open-durable-suppression-configuration",
		"command":       "openConfiguration",
		"sessionID":     "durable-suppression-configuration",
	})
	durableSuppression := snapshot(t, core, "durable-suppression-after-reconstruction")
	if got := suppressionVersionForFolder(t, durableSuppression, discoveryFolderID, peerID.String()); got != ignoredSuppressionVersion {
		t.Fatalf("pending-folder suppression changed across reconstruction: before=%q after=%q", ignoredSuppressionVersion, got)
	}
	if snapshotHasPendingFolder(durableSuppression, discoveryFolderID, peerID.String()) {
		t.Fatal("durably suppressed folder reappeared after reconstruction")
	}
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "unignore-durable-real-offer",
		"command":       "unignorePendingFolder",
		"sessionID":     "durable-suppression-configuration",
		"folderID":      discoveryFolderID,
		"arguments": map[string]string{
			"offeringDeviceID":   peerID.String(),
			"suppressionVersion": ignoredSuppressionVersion,
		},
	})
	unignoredSnapshot := snapshot(t, core, "unignored-durable-offer")
	if unignoredSnapshot.ConfigurationRevision == durableSuppression.ConfigurationRevision {
		t.Fatal("unignore did not advance the canonical configuration revision")
	}
	if hasSuppressionForFolder(unignoredSnapshot, discoveryFolderID, peerID.String()) {
		t.Fatal("unignore left the durable pending-folder suppression in place")
	}
	commandRequestOK(t, core, map[string]any{
		"schemaVersion": 1,
		"requestID":     "close-durable-suppression-configuration",
		"command":       "closeSession",
		"sessionID":     "durable-suppression-configuration",
	})

	reobservedProof := observeRealPendingFolder(
		t,
		core,
		"reobserve",
		discoveryFolderID,
		peerID.String(),
		unignoredSnapshot.ConfigurationRevision,
		discoveryMaximumBytes,
		privacyValues...,
	)
	if reobservedProof.FolderID != ignoredProof.FolderID || reobservedProof.OfferingDeviceID != ignoredProof.OfferingDeviceID {
		t.Fatalf("unignored offer was not re-observed in its original device scope: %+v", reobservedProof)
	}
	t.Log("second real offer passed bounded observation, proof-backed ignore, durable suppression reconstruction, fenced unignore, and authoritative re-observation")

	uploadLocal := []byte("direction-bound upload payload\n")
	uploadRemote := []byte("must not download during upload-only\n")
	writeFile(t, filepath.Join(bridgeFolder, "upload-only-local.txt"), uploadLocal)
	writeFile(t, filepath.Join(peerFolder, "upload-only-remote.txt"), uploadRemote)
	time.Sleep(standardPeerWatcherSettle)
	uploadSession := openDirectionalNetworkSession(
		t, core, "upload-only", "upload", reobservedProof.ConfigurationRevision,
	)
	requireSettledDirectionalSlice(t, core, uploadSession)
	if !fileHasDigest(filepath.Join(peerFolder, "upload-only-local.txt"), uploadLocal) {
		t.Fatal("upload-only session did not transfer the local payload to the standard peer")
	}
	assertRemainsMissing(t, filepath.Join(bridgeFolder, "upload-only-remote.txt"), time.Second)
	assertFiniteDirectionalTotals(t, core, uploadSession)
	closeDirectionalNetworkSession(t, core, uploadSession)
	t.Log("real upload-only session transferred local payload and rejected remote payload download")

	downloadRemote := []byte("direction-bound download payload\n")
	downloadLocal := []byte("must not upload during download-only\n")
	writeFile(t, filepath.Join(peerFolder, "download-only-remote.txt"), downloadRemote)
	writeFile(t, filepath.Join(bridgeFolder, "download-only-local.txt"), downloadLocal)
	time.Sleep(standardPeerWatcherSettle)
	downloadSession := openDirectionalNetworkSession(
		t, core, "download-only", "download", reobservedProof.ConfigurationRevision,
	)
	requireSettledDirectionalSlice(t, core, downloadSession)
	if !fileHasDigest(filepath.Join(bridgeFolder, "download-only-remote.txt"), downloadRemote) {
		t.Fatal("download-only session did not materialize the standard peer payload")
	}
	assertRemainsMissing(t, filepath.Join(peerFolder, "download-only-local.txt"), time.Second)
	assertFiniteDirectionalTotals(t, core, downloadSession)
	closeDirectionalNetworkSession(t, core, downloadSession)
	t.Log("real download-only session transferred remote payload and rejected local payload upload")

	indexLocal := []byte("index-only local payload must remain local\n")
	indexRemote := []byte("index-only remote payload must remain remote\n")
	writeFile(t, filepath.Join(bridgeFolder, "index-only-local.txt"), indexLocal)
	writeFile(t, filepath.Join(peerFolder, "index-only-remote.txt"), indexRemote)
	time.Sleep(standardPeerWatcherSettle)
	indexSession := openDirectionalNetworkSession(
		t, core, "index-only", "exchangeIndex", reobservedProof.ConfigurationRevision,
	)
	requireSettledDirectionalSlice(t, core, indexSession)
	assertRemainsMissing(t, filepath.Join(peerFolder, "index-only-local.txt"), time.Second)
	assertRemainsMissing(t, filepath.Join(bridgeFolder, "index-only-remote.txt"), time.Second)
	assertFiniteDirectionalTotals(t, core, indexSession)
	closeDirectionalNetworkSession(t, core, indexSession)
	t.Log("real index-only session exchanged bounded protocol metadata without payload transfer")

	if err := core.Start(); err != nil {
		t.Fatalf("start legacy bridge after proof-backed decisions: %v", err)
	}
	waitForConnected(t, core, peerID.String(), interopTimeout)
	assertNoHTTPListener(t, bridgeGUI)
	assertNoHTTPListener(t, peerGUI)
	assertPrivateConfiguration(
		t,
		filepath.Join(bridgeHome, "Config", "config.xml"),
		bridgeID,
		bridgeBEP,
		bridgeGUI,
		false,
	)
	assertPrivateConfiguration(
		t,
		filepath.Join(peerHome, "config.xml"),
		peerID,
		peerBEP,
		peerGUI,
		strings.Contains(expectedPeerRelease, "-rc."),
	)
	t.Log("BEP connection established over direct localhost TCP; both management HTTP listeners are absent")

	desktopInitial := []byte("desktop-to-bridge\x00v1\n")
	writeFile(t, filepath.Join(peerFolder, "desktop.txt"), desktopInitial)
	converge(t, core, "desktop-create", func() bool {
		return fileHasDigest(filepath.Join(bridgeFolder, "desktop.txt"), desktopInitial)
	})

	bridgeInitial := []byte("bridge-to-desktop\x00v1\n")
	writeFile(t, filepath.Join(bridgeFolder, "bridge.txt"), bridgeInitial)
	converge(t, core, "bridge-create", func() bool {
		return fileHasDigest(filepath.Join(peerFolder, "bridge.txt"), bridgeInitial)
	})
	assertIndexedReplica(t, core, "desktop.txt", peerID.String())
	assertInteropEvents(t, core)
	requireSettledSyncSlice(t, core, "verified-peer-sync-settle")
	t.Logf("bidirectional byte transfer verified: desktop=%s bridge=%s", digestPrefix(desktopInitial), digestPrefix(bridgeInitial))
	if logicalBytesText := os.Getenv("PEER_INTEROP_MULTI_GIB_BYTES"); logicalBytesText != "" {
		logicalBytes, parseErr := strconv.ParseInt(logicalBytesText, 10, 64)
		if parseErr != nil || logicalBytes <= 2<<30 {
			t.Fatal("PEER_INTEROP_MULTI_GIB_BYTES must be a decimal byte count larger than 2 GiB")
		}
		exerciseMultiGiBSparseTransfer(t, core, bridgeFolder, peerFolder, logicalBytes)
	}
	if logicalBytesText := os.Getenv("PEER_INTEROP_NONSPARSE_MULTI_GIB_BYTES"); logicalBytesText != "" {
		logicalBytes, parseErr := strconv.ParseInt(logicalBytesText, 10, 64)
		if parseErr != nil || logicalBytes <= 2<<30 {
			t.Fatal("PEER_INTEROP_NONSPARSE_MULTI_GIB_BYTES must be a decimal byte count larger than 2 GiB")
		}
		exerciseMultiGiBNonSparseTransfer(t, core, bridgeFolder, peerFolder, logicalBytes)
	}
	if fileCountText := os.Getenv("PEER_INTEROP_SMALL_FILE_COUNT"); fileCountText != "" {
		fileCount, parseErr := strconv.ParseInt(fileCountText, 10, 32)
		if parseErr != nil || fileCount < 10_000 || fileCount > 1_000_000 {
			t.Fatal("PEER_INTEROP_SMALL_FILE_COUNT must be between 10000 and 1000000")
		}
		exerciseLargeSmallFileSet(t, core, bridgeFolder, peerFolder, int(fileCount))
	}

	desktopModified := []byte("desktop-to-bridge\x00modified-content-with-new-size\n")
	writeFile(t, filepath.Join(peerFolder, "desktop.txt"), desktopModified)
	converge(t, core, "desktop-modify", func() bool {
		return fileHasDigest(filepath.Join(bridgeFolder, "desktop.txt"), desktopModified)
	})

	if err := os.Rename(
		filepath.Join(peerFolder, "desktop.txt"),
		filepath.Join(peerFolder, "renamed.txt"),
	); err != nil {
		t.Fatal(err)
	}
	converge(t, core, "desktop-rename", func() bool {
		return fileMissing(filepath.Join(bridgeFolder, "desktop.txt")) &&
			fileHasDigest(filepath.Join(bridgeFolder, "renamed.txt"), desktopModified)
	})

	if err := os.Remove(filepath.Join(bridgeFolder, "bridge.txt")); err != nil {
		t.Fatal(err)
	}
	converge(t, core, "bridge-delete", func() bool {
		return fileMissing(filepath.Join(peerFolder, "bridge.txt"))
	})
	t.Log("modify, rename, and delete propagation verified")

	peer.stop(t, testRoot)
	if err := core.Stop(); err != nil {
		t.Fatalf("stop bridge core: %v", err)
	}
	if err := core.Close(); err != nil {
		t.Fatalf("close bridge core: %v", err)
	}
	coreClosed = true

	restarted, err := mobilebridge.NewCore(bridgeHome, bridgeIdentity)
	if err != nil {
		t.Fatalf("reconstruct bridge core: %v", err)
	}
	core = restarted
	coreClosed = false
	if core.DeviceID() != bridgeID.String() {
		t.Fatal("bridge DeviceID changed after identity restoration")
	}
	if err := core.Start(); err != nil {
		t.Fatalf("restart bridge core: %v", err)
	}
	peer = startPeer(t, peerBinary, peerHome, testRoot)
	waitForTCP(t, peerBEP, interopTimeout)
	waitForConnected(t, core, peerID.String(), interopTimeout)
	if currentPeerID := peerDeviceID(t, peerHome); currentPeerID != peerID {
		t.Fatal("standard peer DeviceID changed after restart")
	}
	assertRestartedState(t, core, bridgeID.String(), peerID.String(), bridgeFolder, peerFolder, desktopModified)
	assertNoHTTPListener(t, bridgeGUI)
	assertNoHTTPListener(t, peerGUI)
	requireSettledSyncSlice(t, core, "already-indexed-peer-reconnects-without-change")
	t.Log("already-indexed peer settled immediately after reconnect without requiring a new index mutation")

	postRestart := []byte("post-restart-index-and-transfer\n")
	writeFile(t, filepath.Join(peerFolder, "post-restart.txt"), postRestart)
	converge(t, core, "post-restart", func() bool {
		return fileHasDigest(filepath.Join(bridgeFolder, "post-restart.txt"), postRestart)
	})
	t.Logf("both peers restarted with stable DeviceIDs and recovered data; post-restart SHA256=%s", digestPrefix(postRestart))

	peer.stop(t, testRoot)
	waitForDisconnected(t, core, peerID.String(), 10*time.Second)
	bridgeConflict := []byte("offline bridge edit\n")
	peerConflict := []byte("offline standard peer edit\n")
	writeFile(t, filepath.Join(bridgeFolder, "renamed.txt"), bridgeConflict)
	commandOK(t, core, "offline-bridge-rescan", "rescan", interopFolderID, "", nil)
	writeFile(t, filepath.Join(peerFolder, "renamed.txt"), peerConflict)

	peer = startPeer(t, peerBinary, peerHome, testRoot)
	waitForTCP(t, peerBEP, interopTimeout)
	waitForConnected(t, core, peerID.String(), interopTimeout)
	converge(t, core, "concurrent-conflict", func() bool {
		return conflictVersionsConverged(
			bridgeFolder,
			peerFolder,
			"renamed.txt",
			bridgeConflict,
			peerConflict,
		)
	})
	t.Logf(
		"offline concurrent edits retained both versions: bridge=%s peer=%s",
		digestPrefix(bridgeConflict),
		digestPrefix(peerConflict),
	)
}

var reservedListeners struct {
	sync.Mutex
	listeners []net.Listener
}

func reserveLoopbackAddresses(t *testing.T, count int) []string {
	t.Helper()
	reservedListeners.Lock()
	defer reservedListeners.Unlock()
	if len(reservedListeners.listeners) != 0 {
		t.Fatal("loopback address reservation leaked from another interop run")
	}
	addresses := make([]string, 0, count)
	for range count {
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		reservedListeners.listeners = append(reservedListeners.listeners, listener)
		addresses = append(addresses, listener.Addr().String())
	}
	return addresses
}

func releaseReservedAddresses(t *testing.T) {
	t.Helper()
	reservedListeners.Lock()
	defer reservedListeners.Unlock()
	for _, listener := range reservedListeners.listeners {
		if err := listener.Close(); err != nil {
			t.Fatal(err)
		}
	}
	reservedListeners.listeners = nil
}

func assertPeerBinaryVersion(t *testing.T, peerBinary, expectedRelease, expectedCommit string) {
	t.Helper()
	output, err := exec.Command(peerBinary, "version").CombinedOutput()
	if err != nil {
		t.Fatalf("read peer version: %v", err)
	}
	version := string(output)
	if !strings.Contains(version, "syncthing "+expectedRelease) || !strings.Contains(version, expectedCommit) {
		t.Fatalf("standard peer does not identify the pinned source: %q", strings.TrimSpace(version))
	}
}

func generatePeerIdentity(t *testing.T, peerBinary, peerHome, secretRoot string) {
	t.Helper()
	command := exec.Command(peerBinary, "generate", "--home", peerHome, "--no-port-probing")
	command.Env = peerEnvironment()
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("generate standard peer identity: %v: %s", err, redact(string(output), secretRoot, peerHome))
	}
}

func writeBridgeBootstrapConfig(t *testing.T, home string, localID protocol.DeviceID, bepAddress, guiAddress string) {
	t.Helper()
	configuration := config.New(localID)
	applyPrivateNetworkConfiguration(&configuration, bepAddress, guiAddress)
	writeConfiguration(t, filepath.Join(home, "Config", "config.xml"), &configuration)
}

func writePeerConfig(
	t *testing.T,
	home, folder, discoveryFolder string,
	localID, bridgeID protocol.DeviceID,
	bepAddress, bridgeAddress, guiAddress string,
) {
	t.Helper()
	configuration := config.New(localID)
	applyPrivateNetworkConfiguration(&configuration, bepAddress, guiAddress)
	device := configuration.Defaults.Device.Copy()
	device.DeviceID = bridgeID
	device.Name = "mobilebridge-interop"
	device.Addresses = []string{"tcp://" + bridgeAddress}
	device.RawNumConnections = 1
	configuration.SetDevice(device)

	syncedFolder := configuration.Defaults.Folder.Copy()
	syncedFolder.ID = interopFolderID
	syncedFolder.Label = "peer-interop"
	syncedFolder.Path = folder
	syncedFolder.Type = config.FolderTypeSendReceive
	// Keep the standard peer's watcher responsible for peer-originated changes,
	// using the pinned Syncthing release's production defaults. A one-second
	// periodic full-tree scan plus a 100 ms watcher delay makes the 100k-file
	// transfer gate measure repeated destination rescans contending with database
	// writes instead of the embedded core's scan and transfer path.
	syncedFolder.RescanIntervalS = interopRescanIntervalS
	syncedFolder.FSWatcherEnabled = true
	syncedFolder.FSWatcherDelayS = standardPeerWatcherDelay.Seconds()
	syncedFolder.Devices = []config.FolderDeviceConfiguration{
		{DeviceID: localID},
		{DeviceID: bridgeID},
	}
	configuration.SetFolder(syncedFolder)
	discoveryOnlyFolder := syncedFolder.Copy()
	discoveryOnlyFolder.ID = discoveryFolderID
	discoveryOnlyFolder.Label = "peer-discovery-extra"
	discoveryOnlyFolder.Path = discoveryFolder
	configuration.SetFolder(discoveryOnlyFolder)
	writeConfiguration(t, filepath.Join(home, "config.xml"), &configuration)
}

func applyPrivateNetworkConfiguration(configuration *config.Configuration, bepAddress, guiAddress string) {
	configuration.GUI.Enabled = false
	configuration.GUI.RawAddress = guiAddress
	configuration.Options.RawListenAddresses = []string{"tcp://" + bepAddress}
	configuration.Options.RawGlobalAnnServers = []string{}
	configuration.Options.RawStunServers = []string{}
	configuration.Options.GlobalAnnEnabled = false
	configuration.Options.LocalAnnEnabled = false
	configuration.Options.AnnounceLANAddresses = false
	configuration.Options.RelaysEnabled = false
	configuration.Options.NATEnabled = false
	configuration.Options.StartBrowser = false
	configuration.Options.URAccepted = -1
	configuration.Options.URUniqueID = ""
	configuration.Options.URURL = "http://" + guiAddress
	configuration.Options.URPostInsecurely = false
	configuration.Options.CREnabled = false
	configuration.Options.AutoUpgradeIntervalH = 0
	configuration.Options.UpgradeToPreReleases = false
}

func writeConfiguration(t *testing.T, path string, configuration *config.Configuration) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	handle, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	writeErr := configuration.WriteXML(handle)
	closeErr := handle.Close()
	if writeErr != nil || closeErr != nil {
		t.Fatal(errors.Join(writeErr, closeErr))
	}
}

type lockedBuffer struct {
	sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	return b.buffer.Write(data)
}

func (b *lockedBuffer) String() string {
	b.Lock()
	defer b.Unlock()
	return b.buffer.String()
}

type peerProcess struct {
	command *exec.Cmd
	done    chan error
	logs    *lockedBuffer
	stopped atomic.Bool
}

func startPeer(t *testing.T, binary, home, secretRoot string) *peerProcess {
	t.Helper()
	logs := new(lockedBuffer)
	command := exec.Command(
		binary,
		"serve",
		"--home", home,
		"--no-browser",
		"--no-port-probing",
		"--no-restart",
		"--no-upgrade",
		"--log-file=-",
		"--log-level=INFO",
	)
	command.Env = peerEnvironment()
	// Run the real cmd/syncthing serve implementation directly instead of its
	// crash-restarting monitor wrapper. This keeps the peer an independent
	// upstream process while making stop/restart ownership deterministic.
	command.Env = append(command.Env, "STMONITORED=yes")
	command.Stdout = logs
	command.Stderr = logs
	if err := command.Start(); err != nil {
		t.Fatalf("start standard peer: %v", err)
	}
	peer := &peerProcess{command: command, done: make(chan error, 1), logs: logs}
	go func() { peer.done <- command.Wait() }()
	select {
	case err := <-peer.done:
		peer.stopped.Store(true)
		t.Fatalf("standard peer exited during startup: %v: %s", err, redact(logs.String(), secretRoot, home))
	case <-time.After(250 * time.Millisecond):
	}
	return peer
}

func (p *peerProcess) stop(t *testing.T, secretRoot string) {
	t.Helper()
	if p == nil || !p.stopped.CompareAndSwap(false, true) {
		return
	}
	if p.command.Process == nil {
		return
	}
	if err := p.command.Process.Signal(os.Interrupt); err != nil && !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("signal standard peer: %v", err)
	}
	select {
	case err := <-p.done:
		if err != nil {
			t.Fatalf("standard peer stopped with an error: %v: %s", err, redact(p.logs.String(), secretRoot))
		}
	case <-time.After(10 * time.Second):
		_ = p.command.Process.Kill()
		<-p.done
		t.Fatal("standard peer did not stop within ten seconds")
	}
}

func peerEnvironment() []string {
	environment := make([]string, 0, len(os.Environ())+4)
	for _, variable := range os.Environ() {
		name, _, _ := strings.Cut(variable, "=")
		if strings.HasPrefix(name, "ST") {
			continue
		}
		environment = append(environment, variable)
	}
	return append(environment,
		"STNOBROWSER=1",
		"STNORESTART=1",
		"STNOUPGRADE=1",
		"STGUIADDRESS=",
	)
}

func commandOK(
	t *testing.T,
	core *mobilebridge.Core,
	requestID, command, folderID, itemID string,
	arguments map[string]string,
) {
	t.Helper()
	request := map[string]any{
		"schemaVersion": 1,
		"requestID":     requestID,
		"command":       command,
	}
	if folderID != "" {
		request["folderID"] = folderID
	}
	if itemID != "" {
		request["itemID"] = itemID
	}
	if len(arguments) != 0 {
		request["arguments"] = arguments
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeEnvelope(t, core.CommandJSON(string(raw)))
	if !envelope.OK {
		if envelope.Error == nil {
			t.Fatalf("bridge command %s failed without a stable error", command)
		}
		t.Fatalf("bridge command %s failed: %s", command, envelope.Error.Code)
	}
}

func commandRequestOK(t *testing.T, core *mobilebridge.Core, request map[string]any) bridgeEnvelope {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeEnvelope(t, core.CommandJSON(string(raw)))
	if !envelope.OK {
		if envelope.Error == nil {
			t.Fatal("bridge command failed without a stable error")
		}
		t.Fatalf("bridge command failed: %s", envelope.Error.Code)
	}
	return envelope
}

func pendingFolderDiscoveryPlanDigest(taskID, offeringDeviceID, configurationRevision, maximumNetworkBytes string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-pending-folder-discovery-plan-v1"))
	for _, part := range []string{taskID, offeringDeviceID, configurationRevision, maximumNetworkBytes} {
		digest.Write([]byte{0})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func pendingFolderObservationPlanDigest(taskID, folderID, offeringDeviceID, configurationRevision, maximumNetworkBytes string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-pending-folder-observation-plan-v1"))
	for _, part := range []string{taskID, folderID, offeringDeviceID, configurationRevision, maximumNetworkBytes} {
		digest.Write([]byte{0})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func directionalNetworkPlanDigest(taskID, folderID, configurationRevision, maximumNetworkBytes, operation string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-network-session-plan-v3"))
	for _, part := range []string{taskID, folderID, configurationRevision, maximumNetworkBytes, operation} {
		digest.Write([]byte{0})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func openDirectionalNetworkSession(
	t *testing.T,
	core *mobilebridge.Core,
	phase, operation, configurationRevision string,
) directionalNetworkSession {
	t.Helper()
	const maximumNetworkBytes = "8388608"
	session := directionalNetworkSession{
		phase:                 phase,
		operation:             operation,
		sessionID:             "peer-interop-" + phase + "-session",
		taskID:                "peer-interop-" + phase + "-task",
		configurationRevision: configurationRevision,
		maximumNetworkBytes:   maximumNetworkBytes,
	}
	session.planDigest = directionalNetworkPlanDigest(
		session.taskID,
		interopFolderID,
		configurationRevision,
		maximumNetworkBytes,
		operation,
	)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "open-" + phase,
		"command":                       "openNetworkSession",
		"sessionID":                     session.sessionID,
		"folderID":                      interopFolderID,
		"taskID":                        session.taskID,
		"planDigest":                    session.planDigest,
		"expectedConfigurationRevision": configurationRevision,
		"maximumNetworkBytes":           maximumNetworkBytes,
		"networkOperation":              operation,
	})
	return session
}

func requireSettledDirectionalSlice(t *testing.T, core *mobilebridge.Core, session directionalNetworkSession) {
	t.Helper()
	deadline := time.Now().Add(interopTimeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		request := map[string]any{
			"schemaVersion":                 1,
			"requestID":                     fmt.Sprintf("%s-slice-%d", session.phase, attempt),
			"command":                       session.operation,
			"sessionID":                     session.sessionID,
			"folderID":                      interopFolderID,
			"taskID":                        session.taskID,
			"planDigest":                    session.planDigest,
			"expectedConfigurationRevision": session.configurationRevision,
			"maximumNetworkBytes":           session.maximumNetworkBytes,
			"networkOperation":              session.operation,
			"arguments": map[string]string{
				"timeoutMS": "3000",
				"settleMS":  "250",
			},
		}
		raw, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		envelope := decodeEnvelope(t, core.CommandJSON(string(raw)))
		if envelope.OK {
			return
		}
		if envelope.Error == nil || (envelope.Error.Code != "sync_incomplete" && envelope.Error.Code != "peer_index_proof_unavailable") {
			if envelope.Error == nil {
				t.Fatalf("%s session failed without a stable error", session.phase)
			}
			t.Fatalf("%s session failed: %s", session.phase, envelope.Error.Code)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("%s session did not settle", session.phase)
}

func assertFiniteDirectionalTotals(t *testing.T, core *mobilebridge.Core, session directionalNetworkSession) {
	t.Helper()
	envelope := decodeEnvelope(t, core.NetworkTransferTotalsJSON(fmt.Sprintf(
		`{"schemaVersion":1,"requestID":%q}`,
		"totals-"+session.phase,
	)))
	if !envelope.OK {
		t.Fatalf("%s session totals were unavailable", session.phase)
	}
	var totals networkTransferTotalsPayload
	if err := json.Unmarshal(envelope.Payload, &totals); err != nil {
		t.Fatal(err)
	}
	const expectedLimit = int64(8 << 20)
	if !totals.BudgetLimited || totals.BudgetLimitBytes != expectedLimit || totals.BudgetUsedBytes <= 0 ||
		totals.BudgetUsedBytes > totals.BudgetLimitBytes || totals.BudgetExhausted {
		t.Fatalf("%s session did not report finite non-exhausted totals: %+v", session.phase, totals)
	}
}

func closeDirectionalNetworkSession(t *testing.T, core *mobilebridge.Core, session directionalNetworkSession) {
	t.Helper()
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "close-" + session.phase,
		"command":                       "closeSession",
		"sessionID":                     session.sessionID,
		"taskID":                        session.taskID,
		"planDigest":                    session.planDigest,
		"expectedConfigurationRevision": session.configurationRevision,
		"maximumNetworkBytes":           session.maximumNetworkBytes,
		"networkOperation":              session.operation,
	})
}

func assertRemainsMissing(t *testing.T, path string, duration time.Duration) {
	t.Helper()
	deadline := time.Now().Add(duration)
	for time.Now().Before(deadline) {
		if !fileMissing(path) {
			t.Fatalf("direction-bound session transferred forbidden payload %q", filepath.Base(path))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func observeRealPendingFolder(
	t *testing.T,
	core *mobilebridge.Core,
	phase, folderID, offeringDeviceID, configurationRevision, maximumNetworkBytes string,
	privacyValues ...string,
) pendingFolderObservationProof {
	t.Helper()
	sessionID := "peer-interop-" + phase + "-observation"
	taskID := "peer-interop-" + phase + "-task"
	planDigest := pendingFolderObservationPlanDigest(taskID, folderID, offeringDeviceID, configurationRevision, maximumNetworkBytes)
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "open-" + phase + "-observation",
		"command":                       "openPendingFolderObservationSession",
		"sessionID":                     sessionID,
		"folderID":                      folderID,
		"offeringDeviceID":              offeringDeviceID,
		"taskID":                        taskID,
		"planDigest":                    planDigest,
		"expectedConfigurationRevision": configurationRevision,
		"maximumNetworkBytes":           maximumNetworkBytes,
	})
	waitForConnected(t, core, offeringDeviceID, interopTimeout)
	proof := captureRealPendingFolderObservation(
		t,
		core,
		sessionID,
		folderID,
		taskID,
		planDigest,
		configurationRevision,
		maximumNetworkBytes,
		offeringDeviceID,
		privacyValues...,
	)
	assertFiniteObservationTotals(t, core, "totals-"+phase+"-observation")
	commandRequestOK(t, core, map[string]any{
		"schemaVersion":                 1,
		"requestID":                     "close-" + phase + "-observation",
		"command":                       "closeSession",
		"sessionID":                     sessionID,
		"taskID":                        taskID,
		"planDigest":                    planDigest,
		"expectedConfigurationRevision": configurationRevision,
		"maximumNetworkBytes":           maximumNetworkBytes,
	})
	return proof
}

func captureRealPendingFolderObservation(
	t *testing.T,
	core *mobilebridge.Core,
	sessionID, folderID, taskID, planDigest, configurationRevision, maximumNetworkBytes, offeringDeviceID string,
	privacyValues ...string,
) pendingFolderObservationProof {
	t.Helper()
	deadline := time.Now().Add(interopTimeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		request := map[string]any{
			"schemaVersion":                 1,
			"requestID":                     fmt.Sprintf("capture-real-observation-%s-%d", folderID, attempt),
			"command":                       "capturePendingFolderObservation",
			"sessionID":                     sessionID,
			"folderID":                      folderID,
			"offeringDeviceID":              offeringDeviceID,
			"taskID":                        taskID,
			"planDigest":                    planDigest,
			"expectedConfigurationRevision": configurationRevision,
			"maximumNetworkBytes":           maximumNetworkBytes,
		}
		rawRequest, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		rawResponse := core.CommandJSON(string(rawRequest))
		assertPendingFolderObservationResponsePrivate(t, rawResponse, privacyValues...)
		envelope := decodeEnvelope(t, rawResponse)
		if envelope.OK {
			var payload pendingFolderObservationPayload
			if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
				t.Fatal(err)
			}
			if payload.PendingFolderObservation == nil {
				t.Fatal("successful observation capture omitted its durable proof")
			}
			proof := *payload.PendingFolderObservation
			if proof.FolderID != folderID || proof.OfferingDeviceID != offeringDeviceID ||
				proof.ConfigurationRevision != configurationRevision || proof.ObservationSessionID != sessionID {
				t.Fatalf("observation proof crossed its folder, device, revision, or session scope: %+v", proof)
			}
			for field, value := range map[string]string{
				"proofID":         proof.ProofID,
				"offerVersion":    proof.OfferVersion,
				"connectionEpoch": proof.ConnectionEpoch,
			} {
				if !isCanonicalStableVersion(value) {
					t.Fatalf("observation proof %s is not a canonical stable version", field)
				}
			}
			if !isCanonicalSHA256(proof.ConfigurationRevision) {
				t.Fatal("observation proof configurationRevision is not a canonical SHA-256 digest")
			}
			if proof.LastSeen == "" || proof.ObservedAt == "" || proof.ExpiresAt == "" || proof.ReceiveEncrypted || proof.RemoteEncrypted {
				t.Fatalf("observation proof metadata is incomplete or unexpectedly encrypted: %+v", proof)
			}
			assertPendingFolderObservationProofSchema(t, envelope.Payload)
			return proof
		}
		if envelope.Error == nil || envelope.Error.Code != "pending_folder_observation_pending" {
			if envelope.Error == nil {
				t.Fatal("real pending-folder observation failed without a stable error")
			}
			t.Fatalf("real pending-folder observation failed: %s", envelope.Error.Code)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("real pending-folder observation did not receive authoritative offer evidence")
	return pendingFolderObservationProof{}
}

func assertPendingFolderObservationResponsePrivate(t *testing.T, raw string, privacyValues ...string) {
	t.Helper()
	for _, forbidden := range append(append([]string(nil), privacyValues...), "tcp://", "127.0.0.1", "[::1]", `"connectionID"`) {
		if forbidden != "" && strings.Contains(raw, forbidden) {
			t.Fatalf("pending-folder observation response leaked private path, address, or raw connection identity")
		}
	}
}

func assertPendingFolderObservationProofSchema(t *testing.T, payload json.RawMessage) {
	t.Helper()
	var outer map[string]json.RawMessage
	if err := json.Unmarshal(payload, &outer); err != nil {
		t.Fatal(err)
	}
	rawProof, ok := outer["pendingFolderObservation"]
	if !ok {
		t.Fatal("observation payload omitted pendingFolderObservation")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(rawProof, &fields); err != nil {
		t.Fatal(err)
	}
	expected := []string{
		"proofID",
		"folderID",
		"offeringDeviceID",
		"offerVersion",
		"label",
		"lastSeen",
		"receiveEncrypted",
		"remoteEncrypted",
		"configurationRevision",
		"observationSessionID",
		"connectionEpoch",
		"observedAt",
		"expiresAt",
	}
	if len(fields) != len(expected) {
		actual := mapKeys(fields)
		slices.Sort(actual)
		t.Fatalf("observation proof exposed an unexpected field set: %v", actual)
	}
	for _, field := range expected {
		if _, ok := fields[field]; !ok {
			t.Fatalf("observation proof omitted required field %q", field)
		}
	}
}

func mapKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	return keys
}

func assertFiniteObservationTotals(t *testing.T, core *mobilebridge.Core, requestID string) {
	t.Helper()
	envelope := decodeEnvelope(t, core.NetworkTransferTotalsJSON(fmt.Sprintf(`{"schemaVersion":1,"requestID":%q}`, requestID)))
	if !envelope.OK {
		t.Fatal("pending-folder observation network totals were unavailable")
	}
	var totals networkTransferTotalsPayload
	if err := json.Unmarshal(envelope.Payload, &totals); err != nil {
		t.Fatal(err)
	}
	const expectedLimit = int64(8 << 20)
	if !totals.BudgetLimited || totals.BudgetLimitBytes != expectedLimit || totals.BudgetUsedBytes <= 0 ||
		totals.BudgetUsedBytes > totals.BudgetLimitBytes || totals.BudgetExhausted ||
		totals.ReceivedBytes <= 0 || totals.SentBytes <= 0 {
		t.Fatalf("pending-folder observation did not report finite non-exhausted totals: %+v", totals)
	}
	t.Logf(
		"bounded observation totals verified: limit=%d used=%d receivedProcessTotal=%d sentProcessTotal=%d",
		totals.BudgetLimitBytes,
		totals.BudgetUsedBytes,
		totals.ReceivedBytes,
		totals.SentBytes,
	)
}

func assertObservationProofConsumed(t *testing.T, home, proofID string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(home, "Bridge", "pending-folder-observation-proofs-v1.json"))
	if err != nil {
		t.Fatalf("read pending-folder observation proof store: %v", err)
	}
	var document struct {
		Proofs []struct {
			ProofID string `json:"proofID"`
		} `json:"proofs"`
	}
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatalf("decode pending-folder observation proof store: %v", err)
	}
	for _, proof := range document.Proofs {
		if proof.ProofID == proofID {
			t.Fatal("proof-backed pending-folder decision did not consume its durable proof")
		}
	}
}

func isCanonicalSHA256(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func isCanonicalStableVersion(value string) bool {
	if len(value) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && base64.RawURLEncoding.EncodeToString(decoded) == value
}

func snapshotHasFolder(snapshot bridgeSnapshot, folderID, localDeviceID, remoteDeviceID string) bool {
	for _, folder := range snapshot.Folders {
		if folder.FolderID == folderID && folder.Type == "sendReceive" &&
			slices.Contains(folder.DeviceIDs, localDeviceID) && slices.Contains(folder.DeviceIDs, remoteDeviceID) {
			return true
		}
	}
	return false
}

func snapshotHasPendingFolder(snapshot bridgeSnapshot, folderID, offeringDeviceID string) bool {
	for _, offer := range snapshot.PendingFolders {
		if offer.FolderID == folderID && offer.OfferingDeviceID == offeringDeviceID {
			return true
		}
	}
	return false
}

func hasSuppressionForFolder(snapshot bridgeSnapshot, folderID, offeringDeviceID string) bool {
	for _, suppression := range snapshot.SuppressedPendingFolders {
		if suppression.FolderID == folderID && suppression.OfferingDeviceID == offeringDeviceID {
			return true
		}
	}
	return false
}

func suppressionVersionForFolder(t *testing.T, snapshot bridgeSnapshot, folderID, offeringDeviceID string) string {
	t.Helper()
	if !snapshot.SuppressedPendingStateAvailable {
		t.Fatal("durable pending-folder suppression state is unavailable")
	}
	for _, suppression := range snapshot.SuppressedPendingFolders {
		if suppression.FolderID == folderID && suppression.OfferingDeviceID == offeringDeviceID {
			if !isCanonicalStableVersion(suppression.SuppressionVersion) {
				t.Fatal("pending-folder suppression version is not canonical")
			}
			return suppression.SuppressionVersion
		}
	}
	t.Fatal("expected durable pending-folder suppression is absent")
	return ""
}

func captureRealPendingFolderDiscovery(
	t *testing.T,
	core *mobilebridge.Core,
	sessionID, taskID, planDigest, configurationRevision, maximumNetworkBytes, offeringDeviceID string,
) pendingFolderDiscoveryPayload {
	t.Helper()
	deadline := time.Now().Add(interopTimeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		request := map[string]any{
			"schemaVersion":                 1,
			"requestID":                     fmt.Sprintf("capture-real-discovery-%d", attempt),
			"command":                       "capturePendingFolderDiscovery",
			"sessionID":                     sessionID,
			"offeringDeviceID":              offeringDeviceID,
			"taskID":                        taskID,
			"planDigest":                    planDigest,
			"expectedConfigurationRevision": configurationRevision,
			"maximumNetworkBytes":           maximumNetworkBytes,
		}
		raw, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		envelope := decodeEnvelope(t, core.CommandJSON(string(raw)))
		if envelope.OK {
			var payload pendingFolderDiscoveryPayload
			if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
				t.Fatal(err)
			}
			return payload
		}
		if envelope.Error == nil || envelope.Error.Code != "pending_folder_discovery_pending" {
			if envelope.Error == nil {
				t.Fatal("real pending-folder discovery failed without a stable error")
			}
			t.Fatalf("real pending-folder discovery failed: %s", envelope.Error.Code)
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("real pending-folder discovery did not receive authoritative offers")
	return pendingFolderDiscoveryPayload{}
}

func syncSlice(t *testing.T, core *mobilebridge.Core, requestID string) {
	t.Helper()
	syncSliceWithTimeout(t, core, requestID, "3000", false)
}

func requireSettledSyncSlice(t *testing.T, core *mobilebridge.Core, requestID string) {
	t.Helper()
	syncSliceWithTimeout(t, core, requestID, "3000", true)
}

func syncLongSlice(t *testing.T, core *mobilebridge.Core, requestID string, requireSettled bool) {
	t.Helper()
	syncSliceWithTimeout(t, core, requestID, "15000", requireSettled)
}

func syncSliceWithTimeout(
	t *testing.T,
	core *mobilebridge.Core,
	requestID string,
	timeoutMilliseconds string,
	requireSettled bool,
) {
	t.Helper()
	request, err := json.Marshal(map[string]any{
		"schemaVersion": 1,
		"requestID":     requestID,
		"command":       "sync",
		"folderID":      interopFolderID,
		"arguments": map[string]string{
			"timeoutMS": timeoutMilliseconds,
			"settleMS":  "250",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeEnvelope(t, core.CommandJSON(string(request)))
	if envelope.OK {
		return
	}
	if requireSettled {
		if envelope.Error == nil {
			t.Fatal("verified sync slice failed without a stable error")
		}
		t.Fatalf("verified sync slice did not settle: %s", envelope.Error.Code)
	}
	if envelope.Error == nil || (envelope.Error.Code != "sync_incomplete" && envelope.Error.Code != "sync_cancelled") {
		if envelope.Error == nil {
			t.Fatal("sync slice failed without a stable error")
		}
		t.Fatalf("sync slice failed: %s", envelope.Error.Code)
	}
}

func decodeEnvelope(t *testing.T, raw string) bridgeEnvelope {
	t.Helper()
	var envelope bridgeEnvelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("decode bridge envelope: %v", err)
	}
	if envelope.SchemaVersion != 1 {
		t.Fatalf("unexpected bridge schema version %d", envelope.SchemaVersion)
	}
	return envelope
}

func snapshot(t *testing.T, core *mobilebridge.Core, requestID string) bridgeSnapshot {
	t.Helper()
	request := fmt.Sprintf(`{"schemaVersion":1,"requestID":%q}`, requestID)
	envelope := decodeEnvelope(t, core.SnapshotJSON(request))
	if !envelope.OK {
		t.Fatal("bridge snapshot failed")
	}
	var payload bridgeSnapshot
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func waitForConnected(t *testing.T, core *mobilebridge.Core, peerID string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		current := snapshot(t, core, fmt.Sprintf("wait-connected-%d", attempt))
		for _, device := range current.Devices {
			if device.DeviceID == peerID && device.Connected && !device.Local {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("standard peer did not establish a BEP connection")
}

func waitForRejectedCertificateIdentity(
	t *testing.T,
	core *mobilebridge.Core,
	configuredDeviceID, presentedDeviceID string,
	timeout time.Duration,
) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		current := snapshot(t, core, fmt.Sprintf("wait-rejected-identity-%d", attempt))
		for _, device := range current.Devices {
			if !device.Local && device.Connected &&
				(device.DeviceID == configuredDeviceID || device.DeviceID == presentedDeviceID) {
				t.Fatalf("mismatched TLS certificate identity was accepted as connected: %+v", device)
			}
		}
		for _, pending := range current.PendingDevices {
			if pending.DeviceID != presentedDeviceID {
				continue
			}
			if !pending.UnverifiedIdentity || !pending.RequiresExplicitAcceptance {
				t.Fatalf("mismatched TLS identity was upgraded to trusted state: %+v", pending)
			}
			if pending.OfferVersion == "" {
				t.Fatalf("mismatched TLS identity did not include a review version: %+v", pending)
			}
			return pending.OfferVersion
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("mismatched TLS certificate identity was not rejected into the pending-device review boundary")
	return ""
}

func waitForDisconnected(t *testing.T, core *mobilebridge.Core, peerID string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		current := snapshot(t, core, fmt.Sprintf("wait-disconnected-%d", attempt))
		disconnected := true
		for _, device := range current.Devices {
			if device.DeviceID == peerID && device.Connected && !device.Local {
				disconnected = false
				break
			}
		}
		if disconnected {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("bridge did not observe the standard peer disconnect")
}

func converge(t *testing.T, core *mobilebridge.Core, phase string, condition func() bool) {
	t.Helper()
	convergeWithin(t, core, phase, interopTimeout, condition)
}

func convergeWithin(
	t *testing.T,
	core *mobilebridge.Core,
	phase string,
	timeout time.Duration,
	condition func() bool,
) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for attempt := 0; time.Now().Before(deadline); attempt++ {
		if condition() {
			return
		}
		syncSlice(t, core, fmt.Sprintf("sync-%s-%d", phase, attempt))
		if condition() {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("interop phase %s did not converge", phase)
}

func exerciseMultiGiBSparseTransfer(
	t *testing.T,
	core *mobilebridge.Core,
	bridgeRoot string,
	peerRoot string,
	logicalBytes int64,
) {
	t.Helper()
	const markerBytes = 4096
	markers := []sparseFileMarker{
		{offset: 0, data: bytes.Repeat([]byte{0x31}, markerBytes)},
		{offset: logicalBytes / 2, data: bytes.Repeat([]byte{0x72}, markerBytes)},
		{offset: logicalBytes - markerBytes, data: bytes.Repeat([]byte{0xB4}, markerBytes)},
	}
	sourcePath := filepath.Join(bridgeRoot, "multi-gib-sparse.bin")
	destinationPath := filepath.Join(peerRoot, "multi-gib-sparse.bin")
	handle, err := os.OpenFile(sourcePath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("create multi-GiB sparse source: %v", err)
	}
	if err := handle.Truncate(logicalBytes); err != nil {
		_ = handle.Close()
		t.Fatalf("size multi-GiB sparse source: %v", err)
	}
	for _, marker := range markers {
		if _, err := handle.WriteAt(marker.data, marker.offset); err != nil {
			_ = handle.Close()
			t.Fatalf("write multi-GiB sparse marker: %v", err)
		}
	}
	if err := handle.Close(); err != nil {
		t.Fatalf("close multi-GiB sparse source: %v", err)
	}

	started := time.Now()
	convergeWithin(t, core, "multi-gib-sparse-create", 5*time.Minute, func() bool {
		return sparseReplicaMatches(destinationPath, logicalBytes, markers)
	})
	requireSettledSyncSlice(t, core, "multi-gib-sparse-settle")
	t.Logf(
		"multi-GiB sparse content transfer verified: logicalBytes=%d elapsed=%s",
		logicalBytes,
		time.Since(started).Round(time.Millisecond),
	)
	if err := os.Remove(sourcePath); err != nil {
		t.Fatalf("remove multi-GiB sparse source: %v", err)
	}
	convergeWithin(t, core, "multi-gib-sparse-delete", 2*time.Minute, func() bool {
		return fileMissing(destinationPath)
	})
	t.Log("multi-GiB sparse delete propagation verified")
}

func sparseReplicaMatches(path string, logicalBytes int64, markers []sparseFileMarker) bool {
	info, err := os.Stat(path)
	if err != nil || info.Size() != logicalBytes {
		return false
	}
	handle, err := os.Open(path)
	if err != nil {
		return false
	}
	defer handle.Close()
	for _, marker := range markers {
		actual := make([]byte, len(marker.data))
		if _, err := handle.ReadAt(actual, marker.offset); err != nil || !bytes.Equal(actual, marker.data) {
			return false
		}
	}
	zeroProbe := make([]byte, 4096)
	if _, err := handle.ReadAt(zeroProbe, logicalBytes/4); err != nil {
		return false
	}
	return bytes.Equal(zeroProbe, make([]byte, len(zeroProbe)))
}

func exerciseMultiGiBNonSparseTransfer(
	t *testing.T,
	core *mobilebridge.Core,
	bridgeRoot string,
	peerRoot string,
	logicalBytes int64,
) {
	t.Helper()
	key := sha256.Sum256([]byte("psy-peer-interop-non-sparse-content-key-v1"))
	initialCounter := sha256.Sum256([]byte("psy-peer-interop-non-sparse-counter-v1"))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		t.Fatalf("initialize deterministic multi-GiB content generator: %v", err)
	}
	stream := cipher.NewCTR(block, initialCounter[:aes.BlockSize])
	sourcePath := filepath.Join(bridgeRoot, "multi-gib-nonsparse.bin")
	destinationPath := filepath.Join(peerRoot, "multi-gib-nonsparse.bin")
	handle, err := os.OpenFile(sourcePath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("create non-sparse multi-GiB source: %v", err)
	}

	generationStarted := time.Now()
	hasher := sha256.New()
	buffer := make([]byte, 4<<20)
	for remaining := logicalBytes; remaining > 0; {
		chunkBytes := int64(len(buffer))
		if remaining < chunkBytes {
			chunkBytes = remaining
		}
		chunk := buffer[:int(chunkBytes)]
		clear(chunk)
		stream.XORKeyStream(chunk, chunk)
		for unwritten := chunk; len(unwritten) > 0; {
			written, writeErr := handle.Write(unwritten)
			if writeErr != nil {
				_ = handle.Close()
				t.Fatalf("write non-sparse multi-GiB source: %v", writeErr)
			}
			if written == 0 {
				_ = handle.Close()
				t.Fatal("write non-sparse multi-GiB source made no progress")
			}
			unwritten = unwritten[written:]
		}
		if _, err := hasher.Write(chunk); err != nil {
			_ = handle.Close()
			t.Fatalf("hash non-sparse multi-GiB source: %v", err)
		}
		remaining -= chunkBytes
	}
	if err := handle.Sync(); err != nil {
		_ = handle.Close()
		t.Fatalf("sync non-sparse multi-GiB source: %v", err)
	}
	if err := handle.Close(); err != nil {
		t.Fatalf("close non-sparse multi-GiB source: %v", err)
	}
	expectedDigest := hasher.Sum(nil)
	t.Logf(
		"non-sparse multi-GiB source generated: logicalBytes=%d elapsed=%s digest=%s",
		logicalBytes,
		time.Since(generationStarted).Round(time.Millisecond),
		hex.EncodeToString(expectedDigest[:8]),
	)

	transferStarted := time.Now()
	convergeWithin(t, core, "multi-gib-nonsparse-create", 8*time.Minute, func() bool {
		info, statErr := os.Stat(destinationPath)
		return statErr == nil && info.Mode().IsRegular() && info.Size() == logicalBytes
	})
	requireSettledSyncSlice(t, core, "multi-gib-nonsparse-settle")
	destination, err := os.Open(destinationPath)
	if err != nil {
		t.Fatalf("open non-sparse multi-GiB replica: %v", err)
	}
	replicaHasher := sha256.New()
	copiedBytes, copyErr := io.Copy(replicaHasher, destination)
	closeErr := destination.Close()
	if copyErr != nil {
		t.Fatalf("hash non-sparse multi-GiB replica: %v", copyErr)
	}
	if closeErr != nil {
		t.Fatalf("close non-sparse multi-GiB replica: %v", closeErr)
	}
	actualDigest := replicaHasher.Sum(nil)
	if copiedBytes != logicalBytes || !bytes.Equal(actualDigest, expectedDigest) {
		t.Fatalf(
			"non-sparse multi-GiB replica mismatch: bytes=%d expectedBytes=%d digest=%s expectedDigest=%s",
			copiedBytes,
			logicalBytes,
			hex.EncodeToString(actualDigest),
			hex.EncodeToString(expectedDigest),
		)
	}
	t.Logf(
		"non-sparse multi-GiB content transfer and full SHA-256 verified: logicalBytes=%d elapsed=%s digest=%s",
		logicalBytes,
		time.Since(transferStarted).Round(time.Millisecond),
		hex.EncodeToString(expectedDigest[:8]),
	)
	if err := os.Remove(sourcePath); err != nil {
		t.Fatalf("remove non-sparse multi-GiB source: %v", err)
	}
	convergeWithin(t, core, "multi-gib-nonsparse-delete", 2*time.Minute, func() bool {
		return fileMissing(destinationPath)
	})
	t.Log("non-sparse multi-GiB delete propagation verified")
}

type smallFileTreeEvidence struct {
	directoryCount int
	fileCount      int
	byteCount      int64
	digest         []byte
}

func exerciseLargeSmallFileSet(
	t *testing.T,
	core *mobilebridge.Core,
	bridgeRoot string,
	peerRoot string,
	fileCount int,
) {
	t.Helper()
	const filesPerDirectory = 1_000
	sourceRoot := filepath.Join(bridgeRoot, "large-small-file-set")
	destinationRoot := filepath.Join(peerRoot, "large-small-file-set")
	if err := os.Mkdir(sourceRoot, 0o700); err != nil {
		t.Fatalf("create large small-file source root: %v", err)
	}
	generationStarted := time.Now()
	for index := 0; index < fileCount; index++ {
		if index%filesPerDirectory == 0 {
			directory := filepath.Join(sourceRoot, fmt.Sprintf("bucket-%04d", index/filesPerDirectory))
			if err := os.Mkdir(directory, 0o700); err != nil {
				t.Fatalf("create large small-file source bucket: %v", err)
			}
		}
		seedDigest := sha256.Sum256([]byte(fmt.Sprintf("psy-small-file-%08d", index)))
		content := []byte(fmt.Sprintf("psy-small-file-%08d:%x\n", index, seedDigest))
		path := filepath.Join(
			sourceRoot,
			fmt.Sprintf("bucket-%04d", index/filesPerDirectory),
			fmt.Sprintf("file-%08d.dat", index),
		)
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatalf("write large small-file source item %d: %v", index, err)
		}
	}
	expected, err := collectSmallFileTreeEvidence(sourceRoot, true)
	if err != nil {
		t.Fatalf("collect large small-file source evidence: %v", err)
	}
	if expected.fileCount != fileCount {
		t.Fatalf("large small-file source count mismatch: got %d expected %d", expected.fileCount, fileCount)
	}
	t.Logf(
		"large small-file source generated: directories=%d files=%d bytes=%d elapsed=%s digest=%s",
		expected.directoryCount,
		expected.fileCount,
		expected.byteCount,
		time.Since(generationStarted).Round(time.Millisecond),
		hex.EncodeToString(expected.digest[:8]),
	)

	transferStarted := time.Now()
	syncLongSlice(t, core, "large-small-file-create-start", false)
	waitForSmallFileTreeEvidence(t, destinationRoot, expected, 20*time.Minute)
	syncLongSlice(t, core, "large-small-file-settle", true)
	actual, err := collectSmallFileTreeEvidence(destinationRoot, true)
	if err != nil {
		t.Fatalf("collect large small-file replica evidence: %v", err)
	}
	if actual.directoryCount != expected.directoryCount ||
		actual.fileCount != expected.fileCount ||
		actual.byteCount != expected.byteCount ||
		!bytes.Equal(actual.digest, expected.digest) {
		t.Fatalf(
			"large small-file replica mismatch: directories=%d/%d files=%d/%d bytes=%d/%d digest=%s/%s",
			actual.directoryCount,
			expected.directoryCount,
			actual.fileCount,
			expected.fileCount,
			actual.byteCount,
			expected.byteCount,
			hex.EncodeToString(actual.digest),
			hex.EncodeToString(expected.digest),
		)
	}
	t.Logf(
		"large small-file tree transfer and full path+content SHA-256 verified: directories=%d files=%d bytes=%d elapsed=%s digest=%s",
		actual.directoryCount,
		actual.fileCount,
		actual.byteCount,
		time.Since(transferStarted).Round(time.Millisecond),
		hex.EncodeToString(actual.digest[:8]),
	)
	if err := os.RemoveAll(sourceRoot); err != nil {
		t.Fatalf("remove large small-file source tree: %v", err)
	}
	syncLongSlice(t, core, "large-small-file-delete-start", false)
	waitForMissingPath(t, destinationRoot, 10*time.Minute)
	t.Log("large small-file tree delete propagation verified")
}

func waitForSmallFileTreeEvidence(
	t *testing.T,
	root string,
	expected smallFileTreeEvidence,
	timeout time.Duration,
) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	nextProgressLog := time.Now().Add(30 * time.Second)
	last := smallFileTreeEvidence{}
	for time.Now().Before(deadline) {
		actual, err := collectSmallFileTreeEvidence(root, false)
		if err == nil {
			last = actual
			if actual.directoryCount == expected.directoryCount &&
				actual.fileCount == expected.fileCount &&
				actual.byteCount == expected.byteCount {
				return
			}
		}
		if time.Now().After(nextProgressLog) {
			t.Logf(
				"large small-file transfer progress: directories=%d/%d files=%d/%d bytes=%d/%d",
				last.directoryCount,
				expected.directoryCount,
				last.fileCount,
				expected.fileCount,
				last.byteCount,
				expected.byteCount,
			)
			nextProgressLog = time.Now().Add(30 * time.Second)
		}
		time.Sleep(30 * time.Second)
	}
	t.Fatalf(
		"large small-file tree did not converge: directories=%d/%d files=%d/%d bytes=%d/%d",
		last.directoryCount,
		expected.directoryCount,
		last.fileCount,
		expected.fileCount,
		last.byteCount,
		expected.byteCount,
	)
}

func waitForMissingPath(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if fileMissing(path) {
			return
		}
		time.Sleep(time.Second)
	}
	t.Fatal("large small-file tree delete did not converge")
}

func collectSmallFileTreeEvidence(root string, includeContent bool) (smallFileTreeEvidence, error) {
	evidence := smallFileTreeEvidence{}
	hasher := sha256.New()
	err := filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			if !info.IsDir() {
				return fmt.Errorf("small-file tree root is not a directory")
			}
			return nil
		}
		relativePath, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relativePath = filepath.ToSlash(relativePath)
		if info.IsDir() {
			evidence.directoryCount++
			return nil
		}
		if !info.Mode().IsRegular() || filepath.Ext(path) != ".dat" {
			return fmt.Errorf("unexpected small-file tree entry %q", relativePath)
		}
		evidence.fileCount++
		evidence.byteCount += info.Size()
		if !includeContent {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if int64(len(content)) != info.Size() {
			return fmt.Errorf("small-file tree item changed while reading %q", relativePath)
		}
		_, _ = fmt.Fprintf(hasher, "%08x:%s:%016x:", len(relativePath), relativePath, len(content))
		_, _ = hasher.Write(content)
		return nil
	})
	if err != nil {
		return smallFileTreeEvidence{}, err
	}
	if includeContent {
		evidence.digest = hasher.Sum(nil)
	}
	return evidence, nil
}

func assertIndexedReplica(t *testing.T, core *mobilebridge.Core, relativePath, peerID string) {
	t.Helper()
	request, err := json.Marshal(map[string]any{
		"schemaVersion": 1,
		"requestID":     "query-index-replica",
		"query":         "items",
		"folderID":      interopFolderID,
		"scope":         "global",
		"limit":         100,
	})
	if err != nil {
		t.Fatal(err)
	}
	envelope := decodeEnvelope(t, core.QueryJSON(string(request)))
	if !envelope.OK {
		t.Fatal("global index query failed")
	}
	var payload itemQueryPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	for _, item := range payload.Items {
		if item.RelativePath == relativePath && item.LocalPresent && !item.Tombstone &&
			slices.Contains(item.ConnectedRemoteDeviceIDs, peerID) {
			return
		}
	}
	t.Fatal("bridge global index did not expose the connected remote replica")
}

func assertInteropEvents(t *testing.T, core *mobilebridge.Core) {
	t.Helper()
	request := `{"schemaVersion":1,"requestID":"query-interop-events","query":"events","cursor":"0","limit":100}`
	envelope := decodeEnvelope(t, core.QueryJSON(request))
	if !envelope.OK {
		t.Fatal("interop event query failed")
	}
	var payload eventQueryPayload
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	seenConnected := false
	seenRemoteIndex := false
	for _, event := range payload.Events {
		seenConnected = seenConnected || event.Type == "DeviceConnected"
		seenRemoteIndex = seenRemoteIndex || event.Type == "RemoteIndexUpdated"
	}
	if !seenConnected || !seenRemoteIndex {
		t.Fatalf("bridge event projection lacks BEP evidence: connected=%t remoteIndex=%t", seenConnected, seenRemoteIndex)
	}
}

func assertRestartedState(
	t *testing.T,
	core *mobilebridge.Core,
	bridgeID, peerID string,
	bridgeFolder, peerFolder string,
	desktopContent []byte,
) {
	t.Helper()
	current := snapshot(t, core, "snapshot-after-restart")
	if !current.Running || current.DeviceID != bridgeID || current.CoreRevision != expectedCoreRevision {
		t.Fatal("bridge runtime identity was not restored")
	}
	folderFound := false
	for _, folder := range current.Folders {
		if folder.FolderID == interopFolderID && folder.Type == "sendReceive" &&
			slices.Contains(folder.DeviceIDs, bridgeID) && slices.Contains(folder.DeviceIDs, peerID) {
			folderFound = true
			break
		}
	}
	if !folderFound {
		t.Fatal("bridge folder configuration was not restored")
	}
	for _, path := range []string{
		filepath.Join(bridgeFolder, "renamed.txt"),
		filepath.Join(peerFolder, "renamed.txt"),
	} {
		if !fileHasDigest(path, desktopContent) {
			t.Fatal("synchronized data was not recovered after restart")
		}
	}
	for _, path := range []string{
		filepath.Join(bridgeFolder, "bridge.txt"),
		filepath.Join(peerFolder, "bridge.txt"),
	} {
		if !fileMissing(path) {
			t.Fatal("synchronized deletion was not recovered after restart")
		}
	}
}

func conflictVersionsConverged(
	bridgeRoot, peerRoot, originalName string,
	first, second []byte,
) bool {
	bridgeVersions, bridgeOriginal, bridgeOK := conflictVersions(bridgeRoot, originalName)
	peerVersions, peerOriginal, peerOK := conflictVersions(peerRoot, originalName)
	if !bridgeOK || !peerOK || bridgeOriginal != peerOriginal {
		return false
	}
	firstDigest := sha256.Sum256(first)
	secondDigest := sha256.Sum256(second)
	return bridgeVersions[firstDigest] && bridgeVersions[secondDigest] &&
		peerVersions[firstDigest] && peerVersions[secondDigest] &&
		len(bridgeVersions) >= 2 && len(peerVersions) >= 2
}

func conflictVersions(root, originalName string) (map[[sha256.Size]byte]bool, [sha256.Size]byte, bool) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, [sha256.Size]byte{}, false
	}
	stem := strings.TrimSuffix(originalName, filepath.Ext(originalName))
	extension := filepath.Ext(originalName)
	versions := make(map[[sha256.Size]byte]bool)
	var originalDigest [sha256.Size]byte
	originalFound := false
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		isOriginal := name == originalName
		isConflict := strings.HasPrefix(name, stem+".sync-conflict-") && strings.HasSuffix(name, extension)
		if !isOriginal && !isConflict {
			continue
		}
		data, readErr := os.ReadFile(filepath.Join(root, name))
		if readErr != nil {
			return nil, [sha256.Size]byte{}, false
		}
		digest := sha256.Sum256(data)
		versions[digest] = true
		if isOriginal {
			originalDigest = digest
			originalFound = true
		}
	}
	return versions, originalDigest, originalFound
}

func assertPrivateConfiguration(
	t *testing.T,
	path string,
	localID protocol.DeviceID,
	bepAddress string,
	telemetrySinkAddress string,
	expectCandidateUsageMetadata bool,
) {
	t.Helper()
	handle, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	configuration, _, readErr := config.ReadXML(handle, localID)
	closeErr := handle.Close()
	if readErr != nil || closeErr != nil {
		t.Fatal(errors.Join(readErr, closeErr))
	}
	options := configuration.Options
	usageMetadataValid := options.URAccepted <= 0 && options.URUniqueID == ""
	if expectCandidateUsageMetadata {
		// Upstream release-candidate builds intentionally force anonymous usage
		// metadata. The fixture preserves that behavior while fencing the only
		// report URL to the same verified-unbound loopback address as its GUI.
		usageMetadataValid = options.URAccepted > 0 && options.URUniqueID != ""
	}
	telemetrySinkValid := options.URURL == "http://"+telemetrySinkAddress
	if configuration.GUI.Enabled || options.StartBrowser ||
		options.GlobalAnnEnabled || options.LocalAnnEnabled || options.AnnounceLANAddresses ||
		options.RelaysEnabled || options.NATEnabled || !usageMetadataValid ||
		!telemetrySinkValid || options.URPostInsecurely || options.CREnabled ||
		options.AutoUpgradeIntervalH != 0 ||
		options.UpgradeToPreReleases {
		t.Fatalf(
			"peer privacy configuration was not preserved: gui=%t browser=%t global=%t local=%t lanAddresses=%t relays=%t nat=%t usageAcceptedPositive=%t usageIDPresent=%t usageSinkLocal=%t usageInsecure=%t crashReporting=%t autoUpgradeInterval=%d prereleaseUpgradeMetadata=%t expectedCandidateUsageMetadata=%t",
			configuration.GUI.Enabled,
			options.StartBrowser,
			options.GlobalAnnEnabled,
			options.LocalAnnEnabled,
			options.AnnounceLANAddresses,
			options.RelaysEnabled,
			options.NATEnabled,
			options.URAccepted > 0,
			options.URUniqueID != "",
			telemetrySinkValid,
			options.URPostInsecurely,
			options.CREnabled,
			options.AutoUpgradeIntervalH,
			options.UpgradeToPreReleases,
			expectCandidateUsageMetadata,
		)
	}
	expected := []string{"tcp://" + bepAddress}
	if !slices.Equal(options.RawListenAddresses, expected) {
		t.Fatal("peer does not use the single expected localhost TCP listener")
	}
}

func assertNoHTTPListener(t *testing.T, address string) {
	t.Helper()
	connection, err := net.DialTimeout("tcp4", address, 250*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		t.Fatal("a disabled management HTTP address accepted a TCP connection")
	}
}

func waitForTCP(t *testing.T, address string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("tcp4", address, 250*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("standard peer did not open its direct TCP listener")
}

func peerDeviceID(t *testing.T, home string) protocol.DeviceID {
	t.Helper()
	certificate, err := tls.LoadX509KeyPair(
		filepath.Join(home, "cert.pem"),
		filepath.Join(home, "key.pem"),
	)
	if err != nil || len(certificate.Certificate) == 0 {
		t.Fatal("standard peer identity is unavailable after restart")
	}
	deviceID := protocol.NewDeviceID(certificate.Certificate[0])
	certificate.PrivateKey = nil
	return deviceID
}

func mustDeviceID(t *testing.T, raw string) protocol.DeviceID {
	t.Helper()
	deviceID, err := protocol.DeviceIDFromString(raw)
	if err != nil {
		t.Fatal(err)
	}
	return deviceID
}

func writeFile(t *testing.T, path string, content []byte) {
	t.Helper()
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}

func fileHasDigest(path string, expected []byte) bool {
	actual, err := os.ReadFile(path)
	return err == nil && sha256.Sum256(actual) == sha256.Sum256(expected)
}

func fileMissing(path string) bool {
	_, err := os.Lstat(path)
	return errors.Is(err, os.ErrNotExist)
}

func digestPrefix(content []byte) string {
	digest := sha256.Sum256(content)
	return hex.EncodeToString(digest[:8])
}

func redact(value string, secrets ...string) string {
	for _, secret := range secrets {
		if secret != "" {
			value = strings.ReplaceAll(value, secret, "<temporary-path>")
		}
	}
	return value
}

var _ io.Writer = (*lockedBuffer)(nil)
