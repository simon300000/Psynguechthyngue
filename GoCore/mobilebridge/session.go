// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	sessionModeLegacy                   = "legacy"
	sessionModeConfiguration            = "configuration"
	sessionModeNetwork                  = "network"
	sessionModePendingFolderObservation = "pendingFolderObservation"
	sessionModePendingFolderDiscovery   = "pendingFolderDiscovery"
	networkOperationSync                = "sync"
	networkOperationUpload              = "upload"
	networkOperationDownload            = "download"
	networkOperationExchangeIndex       = "exchangeIndex"
	networkOperationLocalMutation       = "localMutation"
	networkOperationLocalContent        = "localContent"
	networkOperationMaterialize         = "materialize"

	maxSessionIDRunes = 128
	maxTaskIDRunes    = 128
)

type sessionDescriptor struct {
	SessionID                     string `json:"sessionID"`
	Mode                          string `json:"mode"`
	FolderID                      string `json:"folderID,omitempty"`
	OfferingDeviceID              string `json:"offeringDeviceID,omitempty"`
	TaskID                        string `json:"taskID,omitempty"`
	PlanDigest                    string `json:"planDigest,omitempty"`
	ExpectedConfigurationRevision string `json:"expectedConfigurationRevision,omitempty"`
	MaximumNetworkBytes           string `json:"maximumNetworkBytes,omitempty"`
	NetworkOperation              string `json:"networkOperation,omitempty"`
}

func validateOpenSessionCommand(request commandRequest, mode string) (sessionDescriptor, *responseError) {
	if err := validateScopedIdentifier(request.SessionID, maxSessionIDRunes, "sessionID"); err != nil {
		return sessionDescriptor{}, commandError("invalid_session", err.Error())
	}
	descriptor := sessionDescriptor{
		SessionID:                     request.SessionID,
		Mode:                          mode,
		FolderID:                      request.FolderID,
		OfferingDeviceID:              request.OfferingDeviceID,
		TaskID:                        request.TaskID,
		PlanDigest:                    request.PlanDigest,
		ExpectedConfigurationRevision: request.ExpectedConfigurationRevision,
		MaximumNetworkBytes:           request.MaximumNetworkBytes,
		NetworkOperation:              request.NetworkOperation,
	}
	switch mode {
	case sessionModeConfiguration:
		if request.FolderID != "" || request.OfferingDeviceID != "" || request.ItemID != "" || request.TaskID != "" || request.PlanDigest != "" || request.ExpectedConfigurationRevision != "" || request.MaximumNetworkBytes != "" || request.NetworkOperation != "" || request.CommandConfigurationRevision != "" || len(request.Arguments) != 0 {
			return sessionDescriptor{}, commandError("invalid_session", "openConfiguration accepts only sessionID")
		}
	case sessionModeNetwork:
		if request.OfferingDeviceID != "" || request.ItemID != "" || request.CommandConfigurationRevision != "" || len(request.Arguments) != 0 {
			return sessionDescriptor{}, commandError("invalid_session", "openNetworkSession does not accept itemID or arguments")
		}
		if request.FolderID != strings.TrimSpace(request.FolderID) {
			return sessionDescriptor{}, commandError("invalid_folder_id", "folderID must use canonical trimmed form")
		}
		if err := validateFolderID(request.FolderID); err != nil {
			return sessionDescriptor{}, err
		}
		if err := validateScopedIdentifier(request.TaskID, maxTaskIDRunes, "taskID"); err != nil {
			return sessionDescriptor{}, commandError("invalid_session", err.Error())
		}
		if !isCanonicalSHA256(request.PlanDigest) {
			return sessionDescriptor{}, commandError("invalid_session", "planDigest must be a lowercase SHA-256 digest")
		}
		if !isCanonicalSHA256(request.ExpectedConfigurationRevision) {
			return sessionDescriptor{}, commandError("invalid_session", "expectedConfigurationRevision must be a lowercase SHA-256 digest")
		}
		if _, ok := parseMaximumNetworkBytes(request.MaximumNetworkBytes); !ok {
			return sessionDescriptor{}, commandError("invalid_session", "maximumNetworkBytes must be unlimited or a canonical nonnegative Int64 decimal")
		}
		if request.NetworkOperation == networkOperationLocalContent && request.MaximumNetworkBytes != "0" {
			return sessionDescriptor{}, commandError("invalid_session", "localContent requires a zero network byte limit")
		}
		if !isNetworkOperation(request.NetworkOperation) {
			return sessionDescriptor{}, commandError("invalid_session", "networkOperation must be sync, upload, download, exchangeIndex, localMutation, localContent, or materialize")
		}
	case sessionModePendingFolderObservation:
		if request.ItemID != "" || request.NetworkOperation != "" || request.CommandConfigurationRevision != "" || len(request.Arguments) != 0 {
			return sessionDescriptor{}, commandError("invalid_session", "openPendingFolderObservationSession does not accept itemID, commandConfigurationRevision, or arguments")
		}
		if request.FolderID != strings.TrimSpace(request.FolderID) {
			return sessionDescriptor{}, commandError("invalid_folder_id", "folderID must use canonical trimmed form")
		}
		if err := validateFolderID(request.FolderID); err != nil {
			return sessionDescriptor{}, err
		}
		deviceID, err := protocol.DeviceIDFromString(request.OfferingDeviceID)
		if err != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != request.OfferingDeviceID {
			return sessionDescriptor{}, commandError("invalid_device_id", "offeringDeviceID must be a canonical remote device ID")
		}
		if err := validateScopedIdentifier(request.TaskID, maxTaskIDRunes, "taskID"); err != nil {
			return sessionDescriptor{}, commandError("invalid_session", err.Error())
		}
		if !isCanonicalSHA256(request.PlanDigest) {
			return sessionDescriptor{}, commandError("invalid_session", "planDigest must be a lowercase SHA-256 digest")
		}
		if !isCanonicalSHA256(request.ExpectedConfigurationRevision) {
			return sessionDescriptor{}, commandError("invalid_session", "expectedConfigurationRevision must be a lowercase SHA-256 digest")
		}
		limit, ok := parseMaximumNetworkBytes(request.MaximumNetworkBytes)
		if !ok || limit < 0 || limit > maxPendingFolderObservationNetworkBytes {
			return sessionDescriptor{}, commandError("invalid_session", "maximumNetworkBytes must be a finite canonical decimal no greater than 8388608")
		}
	case sessionModePendingFolderDiscovery:
		if request.FolderID != "" || request.ItemID != "" || request.NetworkOperation != "" || request.CommandConfigurationRevision != "" || len(request.Arguments) != 0 {
			return sessionDescriptor{}, commandError("invalid_session", "openPendingFolderDiscoverySession does not accept folderID, itemID, commandConfigurationRevision, or arguments")
		}
		deviceID, err := protocol.DeviceIDFromString(request.OfferingDeviceID)
		if err != nil || deviceID == protocol.EmptyDeviceID || deviceID.String() != request.OfferingDeviceID {
			return sessionDescriptor{}, commandError("invalid_device_id", "offeringDeviceID must be a canonical remote device ID")
		}
		if err := validateScopedIdentifier(request.TaskID, maxTaskIDRunes, "taskID"); err != nil {
			return sessionDescriptor{}, commandError("invalid_session", err.Error())
		}
		if !isCanonicalSHA256(request.PlanDigest) {
			return sessionDescriptor{}, commandError("invalid_session", "planDigest must be a lowercase SHA-256 digest")
		}
		if !isCanonicalSHA256(request.ExpectedConfigurationRevision) {
			return sessionDescriptor{}, commandError("invalid_session", "expectedConfigurationRevision must be a lowercase SHA-256 digest")
		}
		limit, ok := parseMaximumNetworkBytes(request.MaximumNetworkBytes)
		if !ok || limit < 0 || limit > maxPendingFolderObservationNetworkBytes {
			return sessionDescriptor{}, commandError("invalid_session", "maximumNetworkBytes must be a finite canonical decimal no greater than 8388608")
		}
	}
	return descriptor, nil
}

func isNetworkOperation(value string) bool {
	switch value {
	case networkOperationSync, networkOperationUpload, networkOperationDownload, networkOperationExchangeIndex, networkOperationLocalMutation, networkOperationLocalContent, networkOperationMaterialize:
		return true
	default:
		return false
	}
}

func validateScopedIdentifier(value string, maximumRunes int, field string) error {
	if value == "" || value != strings.TrimSpace(value) || !utf8.ValidString(value) || utf8.RuneCountInString(value) > maximumRunes {
		return fmt.Errorf("%s must contain between 1 and %d valid characters", field, maximumRunes)
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return fmt.Errorf("%s must not contain control characters", field)
		}
	}
	return nil
}

func isCanonicalSHA256(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && hex.EncodeToString(decoded) == value
}

func parseMaximumNetworkBytes(value string) (int64, bool) {
	if value == "unlimited" {
		return -1, true
	}
	if value == "" || value[0] < '0' || value[0] > '9' || len(value) > 1 && value[0] == '0' {
		return 0, false
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	return parsed, err == nil && strconv.FormatInt(parsed, 10) == value
}

func networkSessionPlanDigest(taskID, folderID, configurationRevision, maximumNetworkBytes string) string {
	return networkSessionPlanDigestForOperation(taskID, folderID, configurationRevision, maximumNetworkBytes, networkOperationSync)
}

func networkSessionPlanDigestForOperation(taskID, folderID, configurationRevision, maximumNetworkBytes, operation string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-network-session-plan-v3"))
	digest.Write([]byte{0})
	digest.Write([]byte(taskID))
	digest.Write([]byte{0})
	digest.Write([]byte(folderID))
	digest.Write([]byte{0})
	digest.Write([]byte(configurationRevision))
	digest.Write([]byte{0})
	digest.Write([]byte(maximumNetworkBytes))
	digest.Write([]byte{0})
	digest.Write([]byte(operation))
	return hex.EncodeToString(digest.Sum(nil))
}

func pendingFolderObservationSessionPlanDigest(taskID, folderID, offeringDeviceID, configurationRevision, maximumNetworkBytes string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-pending-folder-observation-plan-v1"))
	for _, part := range []string{
		taskID,
		folderID,
		offeringDeviceID,
		configurationRevision,
		maximumNetworkBytes,
	} {
		digest.Write([]byte{0})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func pendingFolderDiscoverySessionPlanDigest(taskID, offeringDeviceID, configurationRevision, maximumNetworkBytes string) string {
	digest := sha256.New()
	digest.Write([]byte("psy-pending-folder-discovery-plan-v1"))
	for _, part := range []string{
		taskID,
		offeringDeviceID,
		configurationRevision,
		maximumNetworkBytes,
	} {
		digest.Write([]byte{0})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func sessionStartErrorCode(err error) string {
	var startErr *sessionStartError
	if errors.As(err, &startErr) {
		return startErr.code
	}
	return "session_start_failed"
}

type sessionStartError struct {
	code string
	err  error
}

func (e *sessionStartError) Error() string { return e.err.Error() }
func (e *sessionStartError) Unwrap() error { return e.err }

func (c *Core) openSessionCommandLocked(request commandRequest, mode string) *responseError {
	if c.stopRequested.Load() {
		return commandError("cancelled", "the session open was cancelled")
	}
	descriptor, validationErr := validateOpenSessionCommand(request, mode)
	if validationErr != nil {
		return validationErr
	}
	if c.session != nil || c.lifecycle == lifecycleRunning || c.runtime != nil {
		if c.session != nil && *c.session == descriptor && c.lifecycle == lifecycleRunning {
			return nil
		}
		return commandError("session_conflict", "another bridge session is already active")
	}
	if err := c.startSessionLocked(descriptor); err != nil {
		return commandError(sessionStartErrorCode(err), err.Error())
	}
	return nil
}

func (c *Core) closeSessionCommandLocked() *responseError {
	if c.session == nil || c.runtime == nil {
		return commandError("no_active_session", "no explicit bridge session is active")
	}
	var expectedConfiguration *config.Configuration
	configurationPath := ""
	if c.session.Mode == sessionModeConfiguration {
		if verifyErr := c.confirmCanonicalConfigurationLocked(); verifyErr != nil {
			return verifyErr
		}
		expected := c.runtime.configuration.RawCopy()
		expectedConfiguration = &expected
		configurationPath = c.runtime.configuration.ConfigPath()
	}
	stopErr := c.stopLocked()
	if c.runtime == nil {
		// A fully drained closeSession is a completed lifecycle boundary even
		// when final accounting reconciliation reports an error. A later explicit
		// session must not inherit its cancellation fence.
		c.clearLifecycleStop()
	}
	if stopErr != nil {
		return commandError("session_close_failed", stopErr.Error())
	}
	if expectedConfiguration != nil {
		revision, verifyErr := confirmCanonicalConfigurationDocument(
			configurationPath,
			c.localDeviceID,
			*expectedConfiguration,
		)
		if verifyErr != nil {
			return verifyErr
		}
		c.configurationRevision = revision
	}
	return nil
}

func deriveEffectiveNetworkConfiguration(canonical config.Configuration, scope sessionDescriptor, localDeviceID protocol.DeviceID) (config.Configuration, *responseError) {
	effective := canonical.Copy()
	target, _, exists := effective.Folder(scope.FolderID)
	if !exists {
		return config.Configuration{}, commandError("folder_not_found", "the scoped folder is not configured")
	}
	if target.Paused && scope.NetworkOperation != networkOperationLocalContent {
		return config.Configuration{}, commandError("folder_paused", "the scoped folder is paused in the canonical configuration")
	}
	switch scope.NetworkOperation {
	case networkOperationSync:
	case networkOperationUpload:
		if target.Type != config.FolderTypeSendReceive && target.Type != config.FolderTypeSendOnly {
			return config.Configuration{}, commandError("operation_not_allowed", "upload requires a Send & Receive or Send Only folder")
		}
		target.Type = config.FolderTypeSendOnly
	case networkOperationDownload:
		if target.Type != config.FolderTypeSendReceive && target.Type != config.FolderTypeReceiveOnly {
			return config.Configuration{}, commandError("operation_not_allowed", "download requires a Send & Receive or Receive Only folder")
		}
		target.Type = config.FolderTypeReceiveOnly
	case networkOperationExchangeIndex:
		target.Type = config.FolderTypeSendOnly
	case networkOperationLocalMutation:
		if target.Type != config.FolderTypeSendReceive && target.Type != config.FolderTypeSendOnly {
			return config.Configuration{}, commandError("operation_not_allowed", "local mutation requires a Send & Receive or Send Only folder")
		}
		target.Type = config.FolderTypeSendOnly
	case networkOperationLocalContent:
		if target.Type != config.FolderTypeSendReceive && target.Type != config.FolderTypeSendOnly && target.Type != config.FolderTypeReceiveOnly {
			return config.Configuration{}, commandError("operation_not_allowed", "localContent requires a plaintext folder")
		}
		target.Paused = false
		target.Type = config.FolderTypeSendOnly
	case networkOperationMaterialize:
		if target.Type != config.FolderTypeSendReceive && target.Type != config.FolderTypeReceiveOnly {
			return config.Configuration{}, commandError("operation_not_allowed", "materialize requires a Send & Receive or Receive Only folder")
		}
		// Keep index exchange and explicit verified block reads enabled while
		// preventing the ordinary puller from downloading unrelated files.
		target.Type = config.FolderTypeSendOnly
	default:
		return config.Configuration{}, commandError("invalid_session", "the network operation is invalid")
	}
	for index := range effective.Folders {
		if effective.Folders[index].ID == scope.FolderID {
			effective.Folders[index] = target
			break
		}
	}
	allowedDevices := make(map[protocol.DeviceID]struct{}, len(target.Devices)+1)
	allowedDevices[localDeviceID] = struct{}{}
	for _, device := range target.Devices {
		allowedDevices[device.DeviceID] = struct{}{}
	}
	for index := range effective.Folders {
		if effective.Folders[index].ID != scope.FolderID {
			effective.Folders[index].Paused = true
		}
	}
	for index := range effective.Devices {
		device := &effective.Devices[index]
		if device.DeviceID == localDeviceID {
			continue
		}
		if scope.NetworkOperation == networkOperationLocalMutation || scope.NetworkOperation == networkOperationLocalContent {
			device.Paused = true
			continue
		}
		if _, allowed := allowedDevices[device.DeviceID]; !allowed {
			device.Paused = true
		}
	}
	return effective, nil
}

func configurationFileRevision(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return configurationContentsRevision(contents), nil
}

func configurationContentsRevision(contents []byte) string {
	digest := sha256.Sum256(contents)
	return hex.EncodeToString(digest[:])
}

func (c *Core) confirmCanonicalConfigurationLocked() *responseError {
	if c.runtime == nil || c.runtime.configuration == nil || c.runtime.mode != sessionModeConfiguration {
		return commandError("wrong_session_mode", "canonical configuration confirmation requires a configuration session")
	}
	path := c.runtime.configuration.ConfigPath()
	revision, verifyErr := confirmCanonicalConfigurationDocument(
		path,
		c.localDeviceID,
		c.runtime.configuration.RawCopy(),
	)
	if verifyErr != nil {
		return verifyErr
	}
	c.configurationRevision = revision
	return nil
}

func confirmCanonicalConfigurationDocument(
	path string,
	localDeviceID protocol.DeviceID,
	expected config.Configuration,
) (string, *responseError) {
	loaded, _, err := config.Load(path, localDeviceID, events.NoopLogger)
	if err != nil {
		return "", commandError("configuration_verify_failed", err.Error())
	}
	if !reflect.DeepEqual(expected, loaded.RawCopy()) {
		return "", commandError("configuration_verify_failed", "the saved configuration did not reread as the committed state")
	}
	revision, err := configurationFileRevision(path)
	if err != nil {
		return "", commandError("configuration_verify_failed", err.Error())
	}
	return revision, nil
}

func (c *Core) preflightCommandSessionLocked(request commandRequest) *responseError {
	if c.session == nil {
		switch request.Command {
		case "openConfiguration":
			_, err := validateOpenSessionCommand(request, sessionModeConfiguration)
			return err
		case "openNetworkSession":
			_, err := validateOpenSessionCommand(request, sessionModeNetwork)
			return err
		case "openPendingFolderObservationSession":
			_, err := validateOpenSessionCommand(request, sessionModePendingFolderObservation)
			return err
		case "openPendingFolderDiscoverySession":
			_, err := validateOpenSessionCommand(request, sessionModePendingFolderDiscovery)
			return err
		case "closeSession":
			return commandError("no_active_session", "no explicit bridge session is active")
		}
		if request.SessionID != "" || request.TaskID != "" || request.PlanDigest != "" || request.ExpectedConfigurationRevision != "" || request.MaximumNetworkBytes != "" || request.NetworkOperation != "" || request.OfferingDeviceID != "" {
			return commandError("no_active_session", "the command is bound to a session but no explicit session is active")
		}
		return nil
	}
	if request.SessionID != c.session.SessionID {
		return commandError("session_scope_mismatch", "command sessionID does not match the active session")
	}
	if request.Command == "openConfiguration" || request.Command == "openNetworkSession" || request.Command == "openPendingFolderObservationSession" || request.Command == "openPendingFolderDiscoverySession" {
		mode := sessionModeConfiguration
		if request.Command == "openNetworkSession" {
			mode = sessionModeNetwork
		} else if request.Command == "openPendingFolderObservationSession" {
			mode = sessionModePendingFolderObservation
		} else if request.Command == "openPendingFolderDiscoverySession" {
			mode = sessionModePendingFolderDiscovery
		}
		descriptor, err := validateOpenSessionCommand(request, mode)
		if err != nil {
			return err
		}
		if descriptor == *c.session {
			return nil
		}
		return commandError("session_conflict", "another bridge session is already active")
	}
	if request.Command == "closeSession" {
		if request.FolderID != "" || request.OfferingDeviceID != "" || request.ItemID != "" || request.CommandConfigurationRevision != "" || len(request.Arguments) != 0 {
			return commandError("invalid_request", "closeSession does not accept resource targets, command revision, or arguments")
		}
		if c.session.Mode == sessionModeConfiguration && (request.TaskID != "" || request.PlanDigest != "" || request.ExpectedConfigurationRevision != "" || request.MaximumNetworkBytes != "" || request.NetworkOperation != "") {
			return commandError("session_scope_mismatch", "configuration closeSession must not carry network task scope")
		}
		if c.session.Mode == sessionModeNetwork || c.session.Mode == sessionModePendingFolderObservation || c.session.Mode == sessionModePendingFolderDiscovery {
			if _, valid := parseMaximumNetworkBytes(request.MaximumNetworkBytes); !valid {
				return commandError("invalid_session", "maximumNetworkBytes must be unlimited or a canonical nonnegative Int64 decimal")
			}
		}
		if (c.session.Mode == sessionModeNetwork || c.session.Mode == sessionModePendingFolderObservation || c.session.Mode == sessionModePendingFolderDiscovery) && (request.TaskID != c.session.TaskID || request.PlanDigest != c.session.PlanDigest || request.ExpectedConfigurationRevision != c.session.ExpectedConfigurationRevision || request.MaximumNetworkBytes != c.session.MaximumNetworkBytes || request.NetworkOperation != c.session.NetworkOperation) {
			return commandError("session_scope_mismatch", "closeSession taskID or planDigest does not match the active session")
		}
		return nil
	}
	switch c.session.Mode {
	case sessionModeConfiguration:
		if request.TaskID != "" || request.PlanDigest != "" || request.ExpectedConfigurationRevision != "" || request.MaximumNetworkBytes != "" || request.NetworkOperation != "" || request.OfferingDeviceID != "" {
			return commandError("session_scope_mismatch", "configuration commands must not carry network task scope")
		}
		if isConfigurationReconciliationRequest(request) {
			if !isCanonicalSHA256(request.CommandConfigurationRevision) {
				return commandError("invalid_request", "commandConfigurationRevision must be a lowercase SHA-256 digest")
			}
		} else if request.CommandConfigurationRevision != "" {
			return commandError("invalid_request", "commandConfigurationRevision is not accepted by this command")
		}
		proofBackedFolderDecision := (request.Command == "acceptFolder" || request.Command == "ignorePendingFolder") && request.Arguments["observationProofID"] != ""
		if (request.Command == "acceptFolder" || request.Command == "ignorePendingFolder") && !proofBackedFolderDecision {
			return commandError("network_observation_required", "the command requires a live pending-folder observation")
		}
		if request.Command != "ping" && !isOfflineConfigurationCommand(request.Command) && !proofBackedFolderDecision {
			return commandError("wrong_session_mode", "the command requires a network session")
		}
	case sessionModeNetwork:
		if request.OfferingDeviceID != "" {
			return commandError("session_scope_mismatch", "network commands must not carry an offering device scope")
		}
		if _, valid := parseMaximumNetworkBytes(request.MaximumNetworkBytes); !valid {
			return commandError("invalid_session", "maximumNetworkBytes must be unlimited or a canonical nonnegative Int64 decimal")
		}
		if request.TaskID != c.session.TaskID || request.PlanDigest != c.session.PlanDigest || request.ExpectedConfigurationRevision != c.session.ExpectedConfigurationRevision || request.MaximumNetworkBytes != c.session.MaximumNetworkBytes || request.NetworkOperation != c.session.NetworkOperation {
			return commandError("session_scope_mismatch", "command taskID or planDigest does not match the active session")
		}
		if request.CommandConfigurationRevision != "" {
			return commandError("session_scope_mismatch", "network commands must not carry a configuration-command revision")
		}
		if isNetworkOperation(request.Command) && request.Command != c.session.NetworkOperation {
			return commandError("operation_scope_mismatch", "the command does not match the active network operation")
		}
		if isMutationCommand(request.Command) && c.session.NetworkOperation != networkOperationLocalMutation {
			return commandError("operation_scope_mismatch", "file mutations require a localMutation session")
		}
		if c.session.NetworkOperation == networkOperationLocalContent && request.Command != "ping" && request.Command != "evict" {
			return commandError("operation_not_allowed", "localContent accepts only metadata queries, verified local range reads and content eviction")
		}
		if isConfigurationCommand(request.Command) || request.Command == "start" || request.Command == "stop" {
			return commandError("wrong_session_mode", "canonical configuration commands require a configuration session")
		}
		if request.FolderID != "" && request.FolderID != c.session.FolderID {
			return commandError("folder_out_of_scope", "command folderID is outside the active network session")
		}
		if commandRequiresScopedFolder(request.Command) {
			folderID, err := folderTarget(request)
			if err != nil {
				return err
			}
			if folderID != c.session.FolderID {
				return commandError("folder_out_of_scope", "command folderID is outside the active network session")
			}
		}
	case sessionModePendingFolderObservation:
		limit, valid := parseMaximumNetworkBytes(request.MaximumNetworkBytes)
		if !valid || limit < 0 || limit > maxPendingFolderObservationNetworkBytes {
			return commandError("invalid_session", "maximumNetworkBytes must be a finite canonical decimal no greater than 8388608")
		}
		if request.TaskID != c.session.TaskID || request.PlanDigest != c.session.PlanDigest || request.ExpectedConfigurationRevision != c.session.ExpectedConfigurationRevision || request.MaximumNetworkBytes != c.session.MaximumNetworkBytes {
			return commandError("session_scope_mismatch", "command task scope does not match the active observation session")
		}
		if request.CommandConfigurationRevision != "" {
			return commandError("session_scope_mismatch", "observation commands must not carry a configuration-command revision")
		}
		switch request.Command {
		case "ping":
			if request.FolderID != "" || request.OfferingDeviceID != "" {
				return commandError("invalid_request", "ping does not accept observation resource targets")
			}
		case "capturePendingFolderObservation":
			if request.FolderID != c.session.FolderID || request.OfferingDeviceID != c.session.OfferingDeviceID {
				return commandError("session_scope_mismatch", "capture target does not match the active observation session")
			}
			if request.ItemID != "" || len(request.Arguments) != 0 {
				return commandError("invalid_request", "capturePendingFolderObservation does not accept itemID or arguments")
			}
		default:
			return commandError("wrong_session_mode", "the command is not available in a pending-folder observation session")
		}
	case sessionModePendingFolderDiscovery:
		limit, valid := parseMaximumNetworkBytes(request.MaximumNetworkBytes)
		if !valid || limit < 0 || limit > maxPendingFolderObservationNetworkBytes {
			return commandError("invalid_session", "maximumNetworkBytes must be a finite canonical decimal no greater than 8388608")
		}
		if request.TaskID != c.session.TaskID || request.PlanDigest != c.session.PlanDigest || request.ExpectedConfigurationRevision != c.session.ExpectedConfigurationRevision || request.MaximumNetworkBytes != c.session.MaximumNetworkBytes {
			return commandError("session_scope_mismatch", "command task scope does not match the active discovery session")
		}
		if request.CommandConfigurationRevision != "" {
			return commandError("session_scope_mismatch", "discovery commands must not carry a configuration-command revision")
		}
		switch request.Command {
		case "ping":
			if request.FolderID != "" || request.OfferingDeviceID != "" {
				return commandError("invalid_request", "ping does not accept discovery resource targets")
			}
		case "capturePendingFolderDiscovery":
			if request.FolderID != "" || request.OfferingDeviceID != c.session.OfferingDeviceID {
				return commandError("session_scope_mismatch", "capture target does not match the active discovery session")
			}
			if request.ItemID != "" || len(request.Arguments) != 0 {
				return commandError("invalid_request", "capturePendingFolderDiscovery does not accept folderID, itemID, or arguments")
			}
		default:
			return commandError("wrong_session_mode", "the command is not available in a pending-folder discovery session")
		}
	default:
		return commandError("wrong_session_mode", "the active session mode is unsupported")
	}
	return nil
}

func isOfflineConfigurationCommand(command string) bool {
	switch command {
	case "addDevice", "editDevice", "removeDevice",
		"acceptDevice", "ignorePendingDevice",
		"addFolder", "editFolder", "removeFolder", "pause", "resume",
		"unignorePendingDevice", "unignorePendingFolder",
		"disposeRecovery", "disposeRecoveryReviewed", "exportRecovery", "discardRecoveryExport":
		return true
	default:
		return false
	}
}

func isConfigurationCommand(command string) bool {
	if isOfflineConfigurationCommand(command) || isConfigurationReconciliationCommand(command) {
		return true
	}
	switch command {
	case "acceptDevice", "ignorePendingDevice", "unignorePendingDevice",
		"acceptFolder", "ignorePendingFolder", "unignorePendingFolder":
		return true
	default:
		return false
	}
}

func commandRequiresScopedFolder(command string) bool {
	switch command {
	case "sync", "rescan", "create", "modify", "move", "delete", "evict", "materialize", "pin":
		return true
	default:
		return false
	}
}

func (c *Core) networkByteLimitReachedLocked() bool {
	if c.runtime == nil || c.runtime.networkBudgetToken == 0 {
		return false
	}
	status, err := protocol.NetworkByteBudgetStatus(c.runtime.networkBudgetToken)
	return err == nil && status.Exhausted
}

func (c *Core) preflightDataSessionLocked(
	sessionID, taskID, planDigest, configurationRevision, maximumNetworkBytes, networkOperation, folderID string,
	configurationOnly bool,
) *responseError {
	if c.session == nil {
		if sessionID != "" || taskID != "" || planDigest != "" || configurationRevision != "" || maximumNetworkBytes != "" || networkOperation != "" {
			return commandError("no_active_session", "the request is bound to a session but no explicit session is active")
		}
		return nil
	}
	if sessionID != c.session.SessionID {
		return commandError("session_scope_mismatch", "request sessionID does not match the active session")
	}
	if c.session.Mode == sessionModeConfiguration {
		if taskID != "" || planDigest != "" || configurationRevision != "" || maximumNetworkBytes != "" || networkOperation != "" {
			return commandError("session_scope_mismatch", "configuration requests must not carry network task scope")
		}
		if !configurationOnly {
			return commandError("wrong_session_mode", "the request requires a network session")
		}
		return nil
	}
	if c.session.Mode == sessionModePendingFolderObservation || c.session.Mode == sessionModePendingFolderDiscovery {
		return commandError("wrong_session_mode", "folder data and item queries are unavailable in a pending-folder observation or discovery session")
	}
	if configurationOnly {
		return commandError("wrong_session_mode", "the request requires a configuration session")
	}
	if _, valid := parseMaximumNetworkBytes(maximumNetworkBytes); !valid {
		return commandError("invalid_session", "maximumNetworkBytes must be unlimited or a canonical nonnegative Int64 decimal")
	}
	if taskID != c.session.TaskID || planDigest != c.session.PlanDigest || configurationRevision != c.session.ExpectedConfigurationRevision || maximumNetworkBytes != c.session.MaximumNetworkBytes || networkOperation != c.session.NetworkOperation {
		return commandError("session_scope_mismatch", "request task scope does not match the active session")
	}
	if folderID == "" || folderID != c.session.FolderID {
		return commandError("folder_out_of_scope", "request folderID is outside the active network session")
	}
	return nil
}
