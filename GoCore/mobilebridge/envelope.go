// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	envelopeSchemaVersion = 1
	maxJSONRequestSize    = 64 << 10
	maxRequestIDSize      = 128
	maxJSONNestingDepth   = 64
)

type baseRequest struct {
	SchemaVersion int    `json:"schemaVersion"`
	RequestID     string `json:"requestID"`
}

type commandRequest struct {
	SchemaVersion                 int               `json:"schemaVersion"`
	RequestID                     string            `json:"requestID"`
	Command                       string            `json:"command"`
	SessionID                     string            `json:"sessionID,omitempty"`
	TaskID                        string            `json:"taskID,omitempty"`
	PlanDigest                    string            `json:"planDigest,omitempty"`
	ExpectedConfigurationRevision string            `json:"expectedConfigurationRevision,omitempty"`
	MaximumNetworkBytes           string            `json:"maximumNetworkBytes,omitempty"`
	NetworkOperation              string            `json:"networkOperation,omitempty"`
	CommandConfigurationRevision  string            `json:"commandConfigurationRevision,omitempty"`
	FolderID                      string            `json:"folderID,omitempty"`
	OfferingDeviceID              string            `json:"offeringDeviceID,omitempty"`
	ItemID                        string            `json:"itemID,omitempty"`
	Arguments                     map[string]string `json:"arguments,omitempty"`
}

type responseEnvelope struct {
	SchemaVersion int            `json:"schemaVersion"`
	RequestID     string         `json:"requestID,omitempty"`
	Kind          string         `json:"kind"`
	OK            bool           `json:"ok"`
	Payload       any            `json:"payload,omitempty"`
	Error         *responseError `json:"error,omitempty"`
}

type responseError struct {
	Code              string `json:"code"`
	Message           string `json:"message"`
	MutationPhase     string `json:"mutationPhase,omitempty"`
	MutationAmbiguous *bool  `json:"mutationAmbiguous,omitempty"`
}

type snapshotPayload struct {
	CoreRevision                      string                            `json:"coreRevision"`
	Generation                        uint64                            `json:"generation"`
	GeneratedAt                       string                            `json:"generatedAt"`
	DeviceID                          string                            `json:"deviceID"`
	Lifecycle                         string                            `json:"lifecycle"`
	Running                           bool                              `json:"running"`
	Devices                           []deviceSnapshot                  `json:"devices"`
	Folders                           []folderSnapshot                  `json:"folders"`
	PendingDevices                    []pendingDeviceSnapshot           `json:"pendingDevices"`
	PendingFolders                    []pendingFolderSnapshot           `json:"pendingFolders"`
	PendingDeviceObservationScope     string                            `json:"pendingDeviceObservationScope"`
	PendingFoldersAvailable           bool                              `json:"pendingFoldersAvailable"`
	PendingFoldersTruncated           bool                              `json:"pendingFoldersTruncated"`
	SuppressedPendingDevices          []suppressedPendingDeviceSnapshot `json:"suppressedPendingDevices"`
	SuppressedPendingFolders          []suppressedPendingFolderSnapshot `json:"suppressedPendingFolders"`
	SuppressedPendingStateAvailable   bool                              `json:"suppressedPendingStateAvailable"`
	SuppressedPendingDevicesTruncated bool                              `json:"suppressedPendingDevicesTruncated"`
	SuppressedPendingFoldersTruncated bool                              `json:"suppressedPendingFoldersTruncated"`
	Identity                          identityPolicy                    `json:"identity"`
	NetworkPolicy                     networkPolicy                     `json:"networkPolicy"`
	Session                           *sessionDescriptor                `json:"session,omitempty"`
	ConfigurationRevision             string                            `json:"configurationRevision,omitempty"`
}

// pendingDeviceSnapshot is intentionally narrower than Syncthing's observed
// device record. In particular, it never exposes the untrusted network address
// or arbitrary event data supplied by an unknown peer.
type pendingDeviceSnapshot struct {
	DeviceID                   string `json:"deviceID"`
	Label                      string `json:"label"`
	LastSeen                   string `json:"lastSeen"`
	OfferVersion               string `json:"offerVersion"`
	UnverifiedIdentity         bool   `json:"unverifiedIdentity"`
	RequiresExplicitAcceptance bool   `json:"requiresExplicitAcceptance"`
}

// pendingFolderSnapshot is one offer from one configured peer. A folder
// offered by multiple peers therefore appears once per offeringDeviceID.
type pendingFolderSnapshot struct {
	FolderID                        string `json:"folderID"`
	Label                           string `json:"label"`
	OfferingDeviceID                string `json:"offeringDeviceID"`
	LastSeen                        string `json:"lastSeen"`
	OfferVersion                    string `json:"offerVersion"`
	ReceiveEncrypted                bool   `json:"receiveEncrypted"`
	RemoteEncrypted                 bool   `json:"remoteEncrypted"`
	RequiresManagedLocalPath        bool   `json:"requiresManagedLocalPath"`
	RequiresExplicitDeviceSelection bool   `json:"requiresExplicitDeviceSelection"`
	EvidenceSource                  string `json:"evidenceSource"`
	RequiresNetworkRevalidation     bool   `json:"requiresNetworkRevalidation"`
}

// suppressedPendingDeviceSnapshot is the minimum reversible projection of a
// persistent Syncthing ignored-device entry. Untrusted names and addresses are
// deliberately excluded.
type suppressedPendingDeviceSnapshot struct {
	DeviceID           string `json:"deviceID"`
	SuppressionVersion string `json:"suppressionVersion"`
}

// suppressedPendingFolderSnapshot identifies exactly one folder offer source.
// A suppression for one peer must never hide the same folder ID from another.
type suppressedPendingFolderSnapshot struct {
	FolderID           string `json:"folderID"`
	OfferingDeviceID   string `json:"offeringDeviceID"`
	SuppressionVersion string `json:"suppressionVersion"`
}

type deviceSnapshot struct {
	DeviceID               string   `json:"deviceID"`
	Name                   string   `json:"name"`
	Addresses              []string `json:"addresses"`
	Paused                 bool     `json:"paused"`
	Connected              bool     `json:"connected"`
	Local                  bool     `json:"local"`
	LastSeen               string   `json:"lastSeen,omitempty"`
	UploadBytesPerSecond   int64    `json:"uploadBytesPerSecond"`
	DownloadBytesPerSecond int64    `json:"downloadBytesPerSecond"`
	PendingBytes           int64    `json:"pendingBytes"`
}

type folderSnapshot struct {
	FolderID             string   `json:"folderID"`
	Label                string   `json:"label"`
	Path                 string   `json:"path"`
	Type                 string   `json:"type"`
	Paused               bool     `json:"paused"`
	DeviceIDs            []string `json:"deviceIDs"`
	RescanIntervalS      int      `json:"rescanIntervalS"`
	State                string   `json:"state,omitempty"`
	StateChangedAt       string   `json:"stateChangedAt,omitempty"`
	CompletionPercent    float64  `json:"completionPercent"`
	PendingUploadBytes   int64    `json:"pendingUploadBytes"`
	PendingDownloadBytes int64    `json:"pendingDownloadBytes"`
	Error                string   `json:"error,omitempty"`
}

type identityPolicy struct {
	FormatVersion    int  `json:"formatVersion"`
	PrivateKeyOnDisk bool `json:"privateKeyOnDisk"`
}

type networkPolicy struct {
	ManagementHTTPEnabled bool `json:"managementHTTPEnabled"`
	UsageReportingEnabled bool `json:"usageReportingEnabled"`
	CrashReportingEnabled bool `json:"crashReportingEnabled"`
	AutoUpgradeEnabled    bool `json:"autoUpgradeEnabled"`
}

// networkTransferTotalsPayload exposes only the process-wide byte counters
// maintained atomically by Syncthing's protocol package. The bridge enforces a
// single in-process Core, so callers can take a baseline before Start and derive
// one run's exact protocol traffic without exposing peer identities or
// connection details.
type networkTransferTotalsPayload struct {
	ReceivedBytes    int64 `json:"receivedBytes"`
	SentBytes        int64 `json:"sentBytes"`
	BudgetLimited    bool  `json:"budgetLimited"`
	BudgetLimitBytes int64 `json:"budgetLimitBytes"`
	BudgetUsedBytes  int64 `json:"budgetUsedBytes"`
	BudgetExhausted  bool  `json:"budgetExhausted"`
}

type commandPayload struct {
	Command                       string                         `json:"command"`
	Lifecycle                     string                         `json:"lifecycle"`
	Generation                    uint64                         `json:"generation"`
	SessionID                     string                         `json:"sessionID,omitempty"`
	SessionMode                   string                         `json:"sessionMode,omitempty"`
	FolderID                      string                         `json:"folderID,omitempty"`
	OfferingDeviceID              string                         `json:"offeringDeviceID,omitempty"`
	TaskID                        string                         `json:"taskID,omitempty"`
	PlanDigest                    string                         `json:"planDigest,omitempty"`
	ExpectedConfigurationRevision string                         `json:"expectedConfigurationRevision,omitempty"`
	MaximumNetworkBytes           string                         `json:"maximumNetworkBytes,omitempty"`
	NetworkOperation              string                         `json:"networkOperation,omitempty"`
	ConfigurationRevision         string                         `json:"configurationRevision,omitempty"`
	Disposition                   string                         `json:"disposition,omitempty"`
	RecoveryID                    string                         `json:"recoveryID,omitempty"`
	ReceiptHash                   string                         `json:"receiptHash,omitempty"`
	PendingFolderObservation      *pendingFolderObservationProof `json:"pendingFolderObservation,omitempty"`
	PendingFolderDiscovery        *pendingFolderDiscoveryBatch   `json:"pendingFolderDiscovery,omitempty"`
}

func envelopeRequestID(raw string) string {
	if len(raw) == 0 || len(raw) > maxJSONRequestSize {
		return ""
	}
	if err := validateJSONObjectSyntax(raw); err != nil {
		return ""
	}
	var request baseRequest
	if err := json.Unmarshal([]byte(raw), &request); err != nil || len(request.RequestID) > maxRequestIDSize {
		return ""
	}
	return request.RequestID
}

func stableSuccessEnvelope(requestID, kind string, payload any) string {
	response, err := successEnvelope(requestID, kind, payload)
	if err != nil {
		return stableFailureEnvelope(requestID, kind, "internal_error", "the embedded core could not encode the response")
	}
	return response
}

func stableFailureEnvelope(requestID, kind, code, message string) string {
	response, err := failureEnvelope(requestID, kind, code, message)
	if err != nil {
		return fallbackEnvelope
	}
	return response
}

const fallbackEnvelope = `{"schemaVersion":1,"kind":"bridge","ok":false,"error":{"code":"internal_error","message":"the embedded core could not encode the response"}}`

func decodeRequest(raw string, destination any) error {
	if len(raw) == 0 {
		return errors.New("request must be a JSON object")
	}
	if len(raw) > maxJSONRequestSize {
		return errors.New("request exceeds the supported size")
	}
	if err := validateJSONObjectSyntax(raw); err != nil {
		return err
	}

	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return fmt.Errorf("decode request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("request must contain exactly one JSON object")
	}
	return nil
}

func validateJSONObjectSyntax(raw string) error {
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()

	opening, err := decoder.Token()
	if err != nil {
		return fmt.Errorf("decode request: %w", err)
	}
	openingDelimiter, ok := opening.(json.Delim)
	if !ok || openingDelimiter != '{' {
		return errors.New("request must be a JSON object")
	}
	if err := validateJSONObjectContents(decoder, 1); err != nil {
		return fmt.Errorf("decode request: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err != nil {
			return fmt.Errorf("decode request: %w", err)
		}
		return errors.New("request must contain exactly one JSON object")
	}
	return nil
}

func validateJSONObjectContents(decoder *json.Decoder, depth int) error {
	seen := make(map[string]struct{})
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return err
		}
		key, ok := keyToken.(string)
		if !ok {
			return errors.New("JSON object field name must be a string")
		}
		if _, duplicate := seen[key]; duplicate {
			return fmt.Errorf("duplicate JSON object field %q", key)
		}
		seen[key] = struct{}{}
		if err := validateJSONValue(decoder, depth); err != nil {
			return err
		}
	}
	closing, err := decoder.Token()
	if err != nil {
		return err
	}
	if delimiter, ok := closing.(json.Delim); !ok || delimiter != '}' {
		return errors.New("JSON object is not properly terminated")
	}
	return nil
}

func validateJSONValue(decoder *json.Decoder, depth int) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, composite := token.(json.Delim)
	if !composite {
		return nil
	}
	if depth >= maxJSONNestingDepth {
		return fmt.Errorf("JSON nesting exceeds %d levels", maxJSONNestingDepth)
	}
	switch delimiter {
	case '{':
		return validateJSONObjectContents(decoder, depth+1)
	case '[':
		for decoder.More() {
			if err := validateJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closingDelimiter, ok := closing.(json.Delim); !ok || closingDelimiter != ']' {
			return errors.New("JSON array is not properly terminated")
		}
		return nil
	default:
		return errors.New("unexpected JSON delimiter")
	}
}

func validateRequest(schemaVersion int, requestID string) *responseError {
	if schemaVersion != envelopeSchemaVersion {
		return &responseError{
			Code:    "unsupported_schema",
			Message: fmt.Sprintf("schemaVersion must be %d", envelopeSchemaVersion),
		}
	}
	if requestID == "" || len(requestID) > maxRequestIDSize {
		return &responseError{
			Code:    "invalid_request_id",
			Message: "requestID must contain between 1 and 128 bytes",
		}
	}
	return nil
}

func successEnvelope(requestID, kind string, payload any) (string, error) {
	return marshalEnvelope(responseEnvelope{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     requestID,
		Kind:          kind,
		OK:            true,
		Payload:       payload,
	})
}

func failureEnvelope(requestID, kind, code, message string) (string, error) {
	return failureEnvelopeWithError(requestID, kind, &responseError{
		Code:    code,
		Message: message,
	})
}

func failureEnvelopeWithError(requestID, kind string, responseErr *responseError) (string, error) {
	return marshalEnvelope(responseEnvelope{
		SchemaVersion: envelopeSchemaVersion,
		RequestID:     requestID,
		Kind:          kind,
		OK:            false,
		Error:         responseErr,
	})
}

func marshalEnvelope(envelope responseEnvelope) (string, error) {
	data, err := json.Marshal(envelope)
	if err != nil {
		return "", fmt.Errorf("encode response envelope: %w", err)
	}
	return string(data), nil
}
