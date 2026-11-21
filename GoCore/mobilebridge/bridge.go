// SPDX-License-Identifier: MIT

// Package mobilebridge is the versioned, gomobile-safe boundary around the
// embedded Syncthing core. Its exported API intentionally uses only primitive
// values, byte slices, strings, errors, and the package-owned Core reference.
package mobilebridge

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gofrs/flock"
	"github.com/thejerf/suture/v4"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
)

const coreRevision = "syncthing-v2.1.3@946e2b83a1f6c6ae119427c09e0a5802940b82ff"

const (
	lifecycleCreated  = "created"
	lifecycleStarting = "starting"
	lifecycleRunning  = "running"
	lifecycleStopping = "stopping"
	lifecycleStopped  = "stopped"
	lifecycleClosed   = "closed"
)

var (
	singletonMu sync.Mutex
	singleton   *Core

	errNilCore       = errors.New("mobilebridge: nil core")
	errCoreClosed    = errors.New("mobilebridge: core is closed")
	errCoreInUse     = errors.New("mobilebridge: another core owns the process-global Syncthing state")
	errInternalPanic = errors.New("mobilebridge: internal panic recovered")
)

// Core owns one in-process Syncthing runtime. Syncthing locations are
// process-global, so only one Core may exist at a time. A stopped Core may be
// started again; Close is terminal and releases process ownership.
type Core struct {
	mu sync.Mutex

	home                            string
	configurationDirectory          string
	dataDirectory                   string
	stagingDirectory                string
	certificate                     tls.Certificate
	identityBlob                    []byte
	deviceID                        string
	localDeviceID                   protocol.DeviceID
	lifecycle                       string
	generation                      uint64
	closed                          bool
	runtime                         *runtimeState
	session                         *sessionDescriptor
	configurationRevision           string
	networkBudgetReport             networkBudgetReport
	commandLedger                   *commandLedger
	itemRegistry                    *itemIDRegistry
	pendingDevices                  *pendingDeviceStore
	pendingFolderObservationProofs  *pendingFolderObservationProofStore
	pendingFolderDiscoverySummaries *pendingFolderDiscoverySummaryStore
	connectionRateSamples           map[protocol.DeviceID]deviceRateSample
	stopRequested                   atomic.Bool
	cancelMu                        sync.Mutex
	activeOperationCancel           context.CancelFunc
	activeOperationDone             <-chan struct{}
	cancelNextOperation             bool
	activeReadCancel                context.CancelFunc
	activeReadCancelToken           uint64
	activeRuntimeCancel             func()
	activeRuntimeToken              uint64
	lifecycleStopRequested          bool
	runtimeStopRequested            atomic.Bool

	// Tests disable peer networking without changing the gomobile API.
	disableNetworkingForTests                    bool
	syncLoopStartedForTests                      chan struct{}
	syncPeerConnectedForTests                    func(protocol.DeviceID) bool
	pendingFolderOffersForTests                  func(protocol.DeviceID) ([]pendingFolderOffer, error)
	pendingFolderObservationEpochCurrentForTests func(protocol.DeviceID, string, uint64) bool
	connectionStatisticsForTests                 func() map[protocol.DeviceID]deviceConnectionStatistics
	beforeMutationCommitForTests                 func(command, path string) error
	afterMutationExchangeForTests                func(command, installedPath, preservedPath string) error
	beforeMutationRollbackForTests               func(command, installedPath, preservedPath string) error
	scanFolderSubdirsForTests                    func(folderID string, paths []string) error
	afterRecoveryApprovalForTests                func() error
	afterRecoveryRenameForTests                  func() error
	afterRecoveryDeleteForTests                  func() error
	beforeRecoveryRecordRemovalForTests          func() error
	afterSessionProcessLockForTests              func()
	afterSessionDatabaseOpenForTests             func()
	afterNetworkBudgetInstallForTests            func() error
	startNetworkAppForTests                      func(*syncthing.App) error
}

type networkBudgetReport struct {
	Limited    bool
	LimitBytes int64
	UsedBytes  int64
	Exhausted  bool
}

type runtimeState struct {
	mode                                 string
	canonicalConfiguration               *config.Configuration
	app                                  *syncthing.App
	appStarted                           bool
	closeDatabase                        func() error
	configuration                        config.Wrapper
	earlyCancel                          context.CancelFunc
	earlyErrors                          <-chan error
	processLock                          *flock.Flock
	eventSubscription                    events.Subscription
	bufferedEvents                       events.BufferedSubscription
	pendingDeviceSubscription            events.Subscription
	pendingDeviceWatcherDone             chan struct{}
	pendingFolderObservationSubscription events.Subscription
	pendingFolderObservation             *authoritativePendingFolderObservation
	capturedPendingFolderObservation     *pendingFolderObservationProof
	capturedPendingFolderDiscovery       *pendingFolderDiscoveryBatch
	syncPeerReadiness                    *syncPeerReadiness
	eventLogger                          events.Logger
	appStopOnce                          sync.Once
	appStopRequest                       chan struct{}
	appStopInitiated                     chan struct{}
	appStopDone                          chan struct{}
	appStopResultMu                      sync.Mutex
	appStopResult                        error
	appStopDrained                       bool
	coreRuntimeCancelToken               uint64
	networkBudgetToken                   protocol.NetworkByteBudgetToken
	networkBudgetBaselineIn              int64
	networkBudgetBaselineOut             int64
	networkBudgetFinal                   networkBudgetReport
	networkBudgetFinalized               bool
}

// NewCore creates a bridge using an absolute application-owned directory.
// Pass an empty identityBlob on first launch, retrieve IdentityBlob, and store
// it in the Keychain. Pass that same opaque blob on later launches.
func NewCore(home string, identityBlob []byte) (core *Core, err error) {
	defer recoverAsError(&err)
	installEmbeddedProcessLogger()

	if home == "" {
		return nil, newCoreCreationError(
			coreCreationFailureInvalidDirectory,
			errors.New("mobilebridge: home directory is required"),
		)
	}
	absoluteHome, err := filepath.Abs(home)
	if err != nil {
		return nil, newCoreCreationError(
			coreCreationFailureInvalidDirectory,
			fmt.Errorf("mobilebridge: resolve home directory: %w", err),
		)
	}
	absoluteHome = filepath.Clean(absoluteHome)
	if absoluteHome == string(filepath.Separator) {
		return nil, newCoreCreationError(
			coreCreationFailureInvalidDirectory,
			errors.New("mobilebridge: filesystem root cannot be used as the home directory"),
		)
	}

	singletonMu.Lock()
	defer singletonMu.Unlock()
	if singleton != nil {
		return nil, errCoreInUse
	}

	var certificate tls.Certificate
	var storedBlob []byte
	if len(identityBlob) == 0 {
		certificate, storedBlob, err = generateIdentity()
	} else {
		certificate, err = decodeIdentity(identityBlob)
		storedBlob = append([]byte(nil), identityBlob...)
	}
	if err != nil {
		clear(storedBlob)
		failureCode := coreCreationFailureGeneric
		if len(identityBlob) != 0 {
			failureCode = coreCreationFailureIdentity
		}
		return nil, newCoreCreationError(
			failureCode,
			fmt.Errorf("mobilebridge: load identity: %w", err),
		)
	}
	if len(certificate.Certificate) == 0 {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		failureCode := coreCreationFailureGeneric
		if len(identityBlob) != 0 {
			failureCode = coreCreationFailureIdentity
		}
		return nil, newCoreCreationError(
			failureCode,
			errors.New("mobilebridge: identity has no certificate"),
		)
	}
	itemRegistry, err := loadItemIDRegistry(absoluteHome)
	if err != nil {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		return nil, newCoreCreationError(
			coreCreationFailureStateUnavailable,
			fmt.Errorf("mobilebridge: load item identities: %w", err),
		)
	}
	commandLedger, err := loadCommandLedger(absoluteHome)
	if err != nil {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		return nil, newCoreCreationError(
			coreCreationFailureStateUnavailable,
			fmt.Errorf("mobilebridge: load command ledger: %w", err),
		)
	}
	pendingDevices, err := loadPendingDeviceStore(absoluteHome)
	if err != nil {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		return nil, newCoreCreationError(
			coreCreationFailureStateUnavailable,
			fmt.Errorf("mobilebridge: load pending devices: %w", err),
		)
	}
	pendingFolderObservationProofs, err := loadPendingFolderObservationProofStore(absoluteHome)
	if err != nil {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		return nil, newCoreCreationError(
			coreCreationFailureStateUnavailable,
			fmt.Errorf("mobilebridge: load pending folder observation proofs: %w", err),
		)
	}
	pendingFolderDiscoverySummaries, err := loadPendingFolderDiscoverySummaryStore(absoluteHome)
	if err != nil {
		clear(storedBlob)
		clearPrivateKey(certificate.PrivateKey)
		return nil, newCoreCreationError(
			coreCreationFailureStateUnavailable,
			fmt.Errorf("mobilebridge: load pending folder discovery summaries: %w", err),
		)
	}

	localDeviceID := protocol.NewDeviceID(certificate.Certificate[0])
	configurationDirectory := filepath.Join(absoluteHome, "Config")
	dataDirectory := filepath.Join(absoluteHome, "Data")
	stagingDirectory := filepath.Join(filepath.Dir(absoluteHome), "FileProvider", "Staging")
	core = &Core{
		home:                            absoluteHome,
		configurationDirectory:          configurationDirectory,
		dataDirectory:                   dataDirectory,
		stagingDirectory:                stagingDirectory,
		certificate:                     certificate,
		identityBlob:                    storedBlob,
		deviceID:                        localDeviceID.String(),
		localDeviceID:                   localDeviceID,
		lifecycle:                       lifecycleCreated,
		generation:                      1,
		commandLedger:                   commandLedger,
		itemRegistry:                    itemRegistry,
		pendingDevices:                  pendingDevices,
		pendingFolderObservationProofs:  pendingFolderObservationProofs,
		pendingFolderDiscoverySummaries: pendingFolderDiscoverySummaries,
	}
	singleton = core
	return core, nil
}

// CoreRevision returns the exact upstream release and commit represented by
// this bridge build.
func CoreRevision() string {
	return coreRevision
}

// IdentityBlob returns a copy of the opaque identity, including private key
// material. The caller must move it directly into Keychain storage and must
// never log or persist it as a regular file.
func (c *Core) IdentityBlob() (blob []byte) {
	defer func() {
		if recover() != nil {
			blob = nil
		}
	}()
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	return append([]byte(nil), c.identityBlob...)
}

// DeviceID returns the Syncthing device ID derived from the in-memory
// certificate. It is stable when the same identity blob is supplied.
func (c *Core) DeviceID() (deviceID string) {
	defer func() {
		if recover() != nil {
			deviceID = ""
		}
	}()
	if c == nil {
		return ""
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ""
	}
	return c.deviceID
}

// Start starts Syncthing without its management HTTP service, automatic
// upgrades, usage reporting, or crash reporting. Calling Start while already
// running is harmless.
func (c *Core) Start() (err error) {
	defer recoverAsError(&err)
	if c == nil {
		return errNilCore
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.startLocked()
}

// Stop synchronously stops Syncthing and releases its database and
// cross-process lock. The same Core can subsequently be started again.
func (c *Core) Stop() (err error) {
	defer recoverAsError(&err)
	if c == nil {
		return errNilCore
	}
	c.requestLifecycleStop()
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stopLocked()
}

// RequestCancel interrupts the current bridge operation and requests a real
// Syncthing runtime stop without waiting for Core's main mutex. The registered
// runtime callback only signals a dedicated stop worker; App.Stop and database
// drain therefore never run on the caller's thread. This is intentionally a
// void gomobile boundary and is safe to call while native code holds c.mu.
func (c *Core) RequestCancel() {
	defer func() { _ = recover() }()
	if c == nil {
		return
	}
	c.stopRequested.Store(true)
	c.cancelMu.Lock()
	operationCancel := c.activeOperationCancel
	readCancel := c.activeReadCancel
	runtimeCancel := c.activeRuntimeCancel
	if operationCancel == nil && runtimeCancel == nil {
		c.cancelNextOperation = true
	}
	if runtimeCancel != nil {
		c.runtimeStopRequested.Store(true)
	}
	c.cancelMu.Unlock()
	if operationCancel != nil {
		operationCancel()
	}
	if readCancel != nil {
		readCancel()
	}
	if runtimeCancel != nil {
		runtimeCancel()
	}
}

// Close stops the runtime, clears the bridge's in-memory identity copy, and
// releases process ownership. It is terminal and idempotent.
func (c *Core) Close() (err error) {
	defer recoverAsError(&err)
	if c == nil {
		return errNilCore
	}
	c.requestLifecycleStop()

	var stopErr error
	closedTerminally := false
	func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.closed {
			closedTerminally = true
			return
		}
		stopErr = c.stopLocked()
		if c.runtime != nil {
			// App.Stop did not prove that Syncthing services reached their drain
			// boundary. Keep this Core, its process lock, and singleton ownership
			// alive so a second owner can never open the same database.
			return
		}
		c.closed = true
		c.lifecycle = lifecycleClosed
		clear(c.identityBlob)
		c.identityBlob = nil
		clearPrivateKey(c.certificate.PrivateKey)
		c.certificate = tls.Certificate{}
		closedTerminally = true
	}()
	if !closedTerminally {
		return stopErr
	}

	singletonMu.Lock()
	if singleton == c {
		singleton = nil
	}
	singletonMu.Unlock()
	return stopErr
}

// SnapshotJSON returns a versioned JSON response containing only stable bridge
// fields. request must contain schemaVersion and requestID.
func (c *Core) SnapshotJSON(request string) (response string) {
	requestID := envelopeRequestID(request)
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(requestID, "snapshot", "internal_error", "the embedded core could not create the snapshot")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(requestID, "snapshot", "core_unavailable", "the embedded core is unavailable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(requestID, "snapshot", "core_closed", "the embedded core is closed")
	}

	var parsed baseRequest
	if decodeErr := decodeRequest(request, &parsed); decodeErr != nil {
		return stableFailureEnvelope(requestID, "snapshot", "invalid_request", decodeErr.Error())
	}
	if validationErr := validateRequest(parsed.SchemaVersion, parsed.RequestID); validationErr != nil {
		return stableFailureEnvelope(parsed.RequestID, "snapshot", validationErr.Code, validationErr.Message)
	}
	return stableSuccessEnvelope(parsed.RequestID, "snapshot", c.snapshotLocked())
}

// NetworkTransferTotalsJSON returns Syncthing protocol bytes received and sent
// since this process started. It is intentionally callable before Start so a
// consumer can establish an exact per-run baseline. The process-global counter
// is safe because NewCore enforces one Core per process.
func (c *Core) NetworkTransferTotalsJSON(request string) (response string) {
	requestID := envelopeRequestID(request)
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(requestID, "networkTransferTotals", "internal_error", "the embedded core could not read network transfer totals")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(requestID, "networkTransferTotals", "core_unavailable", "the embedded core is unavailable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(requestID, "networkTransferTotals", "core_closed", "the embedded core is closed")
	}

	var parsed baseRequest
	if decodeErr := decodeRequest(request, &parsed); decodeErr != nil {
		return stableFailureEnvelope(requestID, "networkTransferTotals", "invalid_request", decodeErr.Error())
	}
	if validationErr := validateRequest(parsed.SchemaVersion, parsed.RequestID); validationErr != nil {
		return stableFailureEnvelope(parsed.RequestID, "networkTransferTotals", validationErr.Code, validationErr.Message)
	}
	received, sent := protocol.TotalInOut()
	if received < 0 || sent < 0 {
		return stableFailureEnvelope(parsed.RequestID, "networkTransferTotals", "counter_unavailable", "network transfer totals are unavailable")
	}
	budget := c.networkBudgetReport
	if c.runtime != nil && c.runtime.networkBudgetToken != 0 {
		status, err := protocol.NetworkByteBudgetStatus(c.runtime.networkBudgetToken)
		if err != nil {
			return stableFailureEnvelope(parsed.RequestID, "networkTransferTotals", "internal_error", "the active network byte budget is unavailable")
		}
		budget = networkBudgetReportFromProtocol(status)
	}
	return stableSuccessEnvelope(
		parsed.RequestID,
		"networkTransferTotals",
		networkTransferTotalsPayload{
			ReceivedBytes:    received,
			SentBytes:        sent,
			BudgetLimited:    budget.Limited,
			BudgetLimitBytes: budget.LimitBytes,
			BudgetUsedBytes:  budget.UsedBytes,
			BudgetExhausted:  budget.Exhausted,
		},
	)
}

func networkBudgetReportFromProtocol(status protocol.NetworkByteBudgetSnapshot) networkBudgetReport {
	return networkBudgetReport{
		Limited:    status.Limited,
		LimitBytes: status.LimitBytes,
		UsedBytes:  status.UsedBytes,
		Exhausted:  status.Exhausted,
	}
}

// CommandJSON executes a versioned bridge command. Operational failures are
// returned as stable error envelopes. Completed successes and non-replay-safe
// commands are durably idempotent across Core reconstruction; a narrow set of
// replay-safe lifecycle and synchronization failures may execute again under
// the same digest. No NSError crosses the gomobile JSON boundary.
func (c *Core) CommandJSON(request string) (response string) {
	requestID := envelopeRequestID(request)
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(requestID, "command", "internal_error", "the embedded core could not execute the command")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(requestID, "command", "core_unavailable", "the embedded core is unavailable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(requestID, "command", "core_closed", "the embedded core is closed")
	}
	c.beginCancelableOperation()
	defer c.endCancelableOperation()

	response, err := c.commandJSONLocked(request)
	if err != nil {
		return stableFailureEnvelope(requestID, "command", "internal_error", "the embedded core could not encode the command response")
	}
	return response
}

// QueryJSON exposes paginated bridge-owned index and event projections. The
// request and response contain no Syncthing-owned types. The single String
// result avoids gomobile's unaligned multi-result cgo return on arm64.
func (c *Core) QueryJSON(request string) (response string) {
	requestID := envelopeRequestID(request)
	defer func() {
		if recover() != nil {
			response = stableFailureEnvelope(requestID, "query", "internal_error", "the embedded core could not execute the query")
		}
	}()
	if c == nil {
		return stableFailureEnvelope(requestID, "query", "core_unavailable", "the embedded core is unavailable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return stableFailureEnvelope(requestID, "query", "core_closed", "the embedded core is closed")
	}
	response, err := c.queryJSONLocked(request)
	if err != nil {
		return stableFailureEnvelope(requestID, "query", "internal_error", "the embedded core could not encode the query response")
	}
	return response
}

// ReadRangeJSON returns a JSON envelope for a bounded range request. Successful
// payload bytes are JSON-base64 encoded. Unlike the older []byte,error export,
// this method never sends an NSError through gomobile: operational failures,
// invalid lifecycle state, and recovered panics are all stable envelopes. This
// avoids a generated cgo ABI corruption observed after a native error return.
func (c *Core) ReadRangeJSON(request string) (response string) {
	requestID := readRangeRequestID(request)
	defer func() {
		if recover() != nil {
			response = readRangeFailureEnvelope(requestID, "internal_error")
		}
	}()
	if c == nil {
		return readRangeFailureEnvelope(requestID, "core_unavailable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return readRangeFailureEnvelope(requestID, "core_closed")
	}
	c.beginCancelableOperation()
	defer c.endCancelableOperation()

	data, err := c.readRangeJSONLocked(request)
	if err != nil {
		code := "read_range_failed"
		var rangeErr *readRangeError
		if errors.As(err, &rangeErr) {
			code = rangeErr.code
		}
		return readRangeFailureEnvelope(requestID, code)
	}
	return readRangeSuccessEnvelope(requestID, data)
}

func (c *Core) startLocked() (err error) {
	if c.lifecycle == lifecycleRunning {
		if c.session != nil {
			return errors.New("mobilebridge: an explicit session is already active")
		}
		return nil
	}
	return c.startRuntimeLocked(nil)
}

func (c *Core) startSessionLocked(descriptor sessionDescriptor) error {
	if descriptor.Mode != sessionModeConfiguration && descriptor.Mode != sessionModeNetwork && descriptor.Mode != sessionModePendingFolderObservation && descriptor.Mode != sessionModePendingFolderDiscovery {
		return errors.New("mobilebridge: unsupported session mode")
	}
	if c.lifecycle == lifecycleRunning || c.runtime != nil || c.session != nil {
		return errors.New("mobilebridge: another runtime is already active")
	}
	return c.startRuntimeLocked(&descriptor)
}

func (c *Core) startRuntimeLocked(descriptor *sessionDescriptor) (err error) {
	installEmbeddedProcessLogger()
	if c.closed {
		return errCoreClosed
	}
	mode := sessionModeLegacy
	if descriptor != nil {
		mode = descriptor.Mode
	}
	if descriptor == nil {
		c.clearLifecycleStop()
	} else if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}

	c.lifecycle = lifecycleStarting
	runtime := &runtimeState{mode: mode}
	committed := false
	defer func() {
		if !committed {
			cleanupErr := runtime.stop()
			if !runtime.appServicesDrained() || runtime.networkBudgetToken != 0 {
				// Preserve ownership fences when failed startup could not prove a
				// complete drain. Stop/Close may retry; a new runtime may not start.
				c.runtime = runtime
			}
			c.clearRuntimeCancel(runtime.coreRuntimeCancelToken)
			c.clearFailedRuntimeCancellation()
			if err == nil {
				err = cleanupErr
			} else if cleanupErr != nil {
				err = errors.Join(err, cleanupErr)
			}
			c.lifecycle = lifecycleStopped
		}
	}()

	if err := configureLocations(c.home, c.configurationDirectory, c.dataDirectory); err != nil {
		return fmt.Errorf("mobilebridge: configure Syncthing locations: %w", err)
	}
	for description, directory := range map[string]string{
		"home":          c.home,
		"configuration": c.configurationDirectory,
		"data":          c.dataDirectory,
		"staging":       c.stagingDirectory,
	} {
		if err := syncthing.EnsureDir(directory, 0o700); err != nil {
			return fmt.Errorf("mobilebridge: create %s directory: %w", description, err)
		}
	}

	runtime.processLock = flock.New(locations.Get(locations.LockFile))
	locked, err := runtime.processLock.TryLock()
	if err != nil {
		return fmt.Errorf("mobilebridge: acquire process lock: %w", err)
	}
	if !locked {
		return errors.New("mobilebridge: another process owns the Syncthing data directory")
	}
	if c.afterSessionProcessLockForTests != nil {
		c.afterSessionProcessLockForTests()
	}

	earlyContext, earlyCancel := context.WithCancel(context.Background())
	runtime.earlyCancel = earlyCancel
	runtime.coreRuntimeCancelToken = c.registerRuntimeCancel(earlyCancel)
	earlySupervisor := suture.New("mobilebridge-early", svcutil.SpecWithDebugLogger())
	runtime.earlyErrors = earlySupervisor.ServeBackground(earlyContext)
	eventLogger := events.NewLogger()
	runtime.eventLogger = eventLogger
	earlySupervisor.Add(eventLogger)
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}
	configurationPath := locations.Get(locations.ConfigFile)
	var canonical config.Wrapper
	var revision string
	if mode == sessionModeNetwork || mode == sessionModePendingFolderObservation || mode == sessionModePendingFolderDiscovery {
		contents, readErr := os.ReadFile(configurationPath)
		if errors.Is(readErr, os.ErrNotExist) {
			return &sessionStartError{code: "configuration_not_initialized", err: errors.New("a configuration session must initialize the canonical configuration before networking")}
		}
		if readErr != nil {
			return fmt.Errorf("mobilebridge: read canonical configuration: %w", readErr)
		}
		canonicalConfiguration, originalVersion, readErr := config.ReadXML(bytes.NewReader(contents), c.localDeviceID)
		if readErr != nil {
			return fmt.Errorf("mobilebridge: parse canonical configuration read-only: %w", readErr)
		}
		canonical = config.Wrap("", canonicalConfiguration, c.localDeviceID, eventLogger)
		revision = configurationContentsRevision(contents)
		if originalVersion != config.CurrentVersion {
			return &sessionStartError{code: "configuration_version_mismatch", err: errors.New("the canonical configuration requires an explicit configuration-session migration")}
		}
	} else {
		canonical, err = syncthing.LoadConfigAtStartup(
			configurationPath,
			c.certificate,
			eventLogger,
			false,
			true,
		)
		if err != nil {
			return fmt.Errorf("mobilebridge: load configuration: %w", err)
		}
		revision, err = configurationFileRevision(configurationPath)
		if err != nil {
			return fmt.Errorf("mobilebridge: read canonical configuration revision: %w", err)
		}
	}
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}
	switch mode {
	case sessionModeConfiguration:
		runtime.configuration = canonical
		earlySupervisor.Add(canonical)
	case sessionModeNetwork:
		if descriptor.ExpectedConfigurationRevision != revision {
			return &sessionStartError{
				code: "configuration_revision_mismatch",
				err:  errors.New("the canonical configuration changed after the network session was planned"),
			}
		}
		if expectedPlan := networkSessionPlanDigestForOperation(descriptor.TaskID, descriptor.FolderID, revision, descriptor.MaximumNetworkBytes, descriptor.NetworkOperation); descriptor.PlanDigest != expectedPlan {
			return &sessionStartError{
				code: "plan_digest_mismatch",
				err:  errors.New("planDigest does not bind the task, folder, and canonical configuration revision"),
			}
		}
		canonicalCopy := canonical.RawCopy()
		runtime.canonicalConfiguration = &canonicalCopy
		effective, scopeErr := deriveEffectiveNetworkConfiguration(canonicalCopy, *descriptor, c.localDeviceID)
		if scopeErr != nil {
			return &sessionStartError{code: scopeErr.Code, err: errors.New(scopeErr.Message)}
		}
		applyEmbeddedPolicy(
			&effective,
			c.disableNetworkingForTests || descriptor.NetworkOperation == networkOperationLocalMutation || descriptor.NetworkOperation == networkOperationLocalContent,
		)
		runtime.configuration = config.Wrap("", effective, c.localDeviceID, eventLogger)
		earlySupervisor.Add(runtime.configuration)
	case sessionModePendingFolderObservation:
		if descriptor.ExpectedConfigurationRevision != revision {
			return &sessionStartError{
				code: "configuration_revision_mismatch",
				err:  errors.New("the canonical configuration changed after the observation session was planned"),
			}
		}
		if expectedPlan := pendingFolderObservationSessionPlanDigest(descriptor.TaskID, descriptor.FolderID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes); descriptor.PlanDigest != expectedPlan {
			return &sessionStartError{
				code: "plan_digest_mismatch",
				err:  errors.New("planDigest does not bind the observation task, folder, offering device, and canonical configuration revision"),
			}
		}
		canonicalCopy := canonical.RawCopy()
		runtime.canonicalConfiguration = &canonicalCopy
		effective, scopeErr := deriveEffectivePendingFolderObservationConfiguration(canonicalCopy, *descriptor, c.localDeviceID)
		if scopeErr != nil {
			return &sessionStartError{code: scopeErr.Code, err: errors.New(scopeErr.Message)}
		}
		applyEmbeddedPolicy(&effective, c.disableNetworkingForTests)
		runtime.configuration = config.Wrap("", effective, c.localDeviceID, eventLogger)
		earlySupervisor.Add(runtime.configuration)
	case sessionModePendingFolderDiscovery:
		if descriptor.ExpectedConfigurationRevision != revision {
			return &sessionStartError{
				code: "configuration_revision_mismatch",
				err:  errors.New("the canonical configuration changed after the discovery session was planned"),
			}
		}
		if expectedPlan := pendingFolderDiscoverySessionPlanDigest(descriptor.TaskID, descriptor.OfferingDeviceID, revision, descriptor.MaximumNetworkBytes); descriptor.PlanDigest != expectedPlan {
			return &sessionStartError{
				code: "plan_digest_mismatch",
				err:  errors.New("planDigest does not bind the discovery task, offering device, and canonical configuration revision"),
			}
		}
		canonicalCopy := canonical.RawCopy()
		runtime.canonicalConfiguration = &canonicalCopy
		effective, scopeErr := deriveEffectivePendingFolderDiscoveryConfiguration(canonicalCopy, *descriptor, c.localDeviceID)
		if scopeErr != nil {
			return &sessionStartError{code: scopeErr.Code, err: errors.New(scopeErr.Message)}
		}
		applyEmbeddedPolicy(&effective, c.disableNetworkingForTests)
		runtime.configuration = config.Wrap("", effective, c.localDeviceID, eventLogger)
		earlySupervisor.Add(runtime.configuration)
	case sessionModeLegacy:
		runtime.configuration = canonical
		earlySupervisor.Add(canonical)
		waiter, modifyErr := canonical.Modify(func(current *config.Configuration) {
			applyEmbeddedPolicy(current, c.disableNetworkingForTests)
		})
		if modifyErr != nil {
			return fmt.Errorf("mobilebridge: apply embedded configuration policy: %w", modifyErr)
		}
		waiter.Wait()
		if err := canonical.Save(); err != nil {
			return fmt.Errorf("mobilebridge: save embedded configuration policy: %w", err)
		}
		revision, err = configurationFileRevision(configurationPath)
		if err != nil {
			return fmt.Errorf("mobilebridge: read canonical configuration revision: %w", err)
		}
	default:
		return errors.New("mobilebridge: unsupported runtime mode")
	}

	if mode == sessionModeConfiguration {
		if c.stopRequested.Load() {
			return &sessionStartError{code: "cancelled", err: context.Canceled}
		}
		c.runtime = runtime
		c.session = descriptor
		c.configurationRevision = revision
		c.networkBudgetReport = networkBudgetReport{}
		c.lifecycle = lifecycleRunning
		c.generation++
		committed = true
		return nil
	}

	runtime.eventSubscription = eventLogger.Subscribe(bridgeEventMask)
	runtime.bufferedEvents = events.NewBufferedSubscription(runtime.eventSubscription, maxBufferedEvents)
	runtime.pendingDeviceSubscription = eventLogger.Subscribe(events.PendingDevicesChanged)
	runtime.pendingDeviceWatcherDone = make(chan struct{})
	go c.watchPendingDevices(runtime.pendingDeviceSubscription, runtime.pendingDeviceWatcherDone)
	if mode == sessionModePendingFolderObservation || mode == sessionModePendingFolderDiscovery {
		runtime.pendingFolderObservationSubscription = eventLogger.Subscribe(events.ClusterConfigReceived)
	}
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}

	database, err := syncthing.OpenDatabase(locations.Get(locations.Database), 0)
	if err != nil {
		return fmt.Errorf("mobilebridge: open database: %w", err)
	}
	runtime.closeDatabase = database.Close
	if c.afterSessionDatabaseOpenForTests != nil {
		c.afterSessionDatabaseOpenForTests()
	}
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}

	options := syncthing.Options{NoUpgrade: true}
	if mode == sessionModeNetwork {
		upload, download := networkOperationPayloadDirections(descriptor.NetworkOperation)
		options.FolderTransferDirections = map[string]model.FolderTransferDirections{
			descriptor.FolderID: {Upload: upload, Download: download},
		}
	}
	app, err := syncthing.New(runtime.configuration, database, eventLogger, c.certificate, options)
	if err != nil {
		return fmt.Errorf("mobilebridge: create Syncthing app: %w", err)
	}
	if mode == sessionModeNetwork || mode == sessionModePendingFolderObservation || mode == sessionModePendingFolderDiscovery {
		limit, valid := parseMaximumNetworkBytes(descriptor.MaximumNetworkBytes)
		if !valid {
			return &sessionStartError{code: "invalid_session", err: errors.New("maximumNetworkBytes is not canonical")}
		}
		runtime.networkBudgetBaselineIn, runtime.networkBudgetBaselineOut = protocol.TotalInOut()
		runtime.networkBudgetToken, err = protocol.InstallNetworkByteBudget(limit)
		if err != nil {
			return fmt.Errorf("mobilebridge: install aggregate protocol byte budget: %w", err)
		}
		if c.afterNetworkBudgetInstallForTests != nil {
			if err := c.afterNetworkBudgetInstallForTests(); err != nil {
				return fmt.Errorf("mobilebridge: test failure after aggregate protocol byte budget install: %w", err)
			}
		}
	}
	runtime.app = app
	runtime.appStarted = true
	runtime.prepareAppStop()
	startApp := app.Start
	if (mode == sessionModeNetwork || mode == sessionModePendingFolderObservation || mode == sessionModePendingFolderDiscovery) && c.startNetworkAppForTests != nil {
		startApp = func() error { return c.startNetworkAppForTests(app) }
	}
	if err := startApp(); err != nil {
		return fmt.Errorf("mobilebridge: start Syncthing app: %w", err)
	}
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}
	runtime.syncPeerReadiness = newSyncPeerReadiness(app.Internals)

	runtime.coreRuntimeCancelToken = c.registerRuntimeCancel(runtime.requestAppStop)
	if c.stopRequested.Load() {
		return &sessionStartError{code: "cancelled", err: context.Canceled}
	}
	budgetReport := networkBudgetReport{}
	if mode == sessionModeNetwork || mode == sessionModePendingFolderObservation || mode == sessionModePendingFolderDiscovery {
		status, statusErr := protocol.NetworkByteBudgetStatus(runtime.networkBudgetToken)
		if statusErr != nil {
			return fmt.Errorf("mobilebridge: inspect aggregate protocol byte budget: %w", statusErr)
		}
		budgetReport = networkBudgetReportFromProtocol(status)
	}
	c.runtime = runtime
	c.session = descriptor
	c.configurationRevision = revision
	c.networkBudgetReport = budgetReport
	c.lifecycle = lifecycleRunning
	c.generation++
	committed = true
	return nil
}

func networkOperationPayloadDirections(operation string) (upload, download bool) {
	switch operation {
	case networkOperationSync:
		return true, true
	case networkOperationUpload:
		return true, false
	case networkOperationDownload:
		return false, true
	case networkOperationMaterialize:
		return false, true
	case networkOperationExchangeIndex:
		return false, false
	case networkOperationLocalMutation, networkOperationLocalContent:
		return false, false
	default:
		return false, false
	}
}

func (c *Core) stopLocked() error {
	c.requestLifecycleStop()
	if c.closed {
		return errCoreClosed
	}
	if c.runtime == nil {
		if c.lifecycle != lifecycleCreated {
			c.lifecycle = lifecycleStopped
		}
		return nil
	}

	c.lifecycle = lifecycleStopping
	runtime := c.runtime
	err := runtime.stop()
	if runtime.networkBudgetFinalized {
		// Preserve the final report even when strict delta reconciliation makes
		// closeSession fail. The caller can inspect it after the failed close.
		c.networkBudgetReport = runtime.networkBudgetFinal
	}
	if !runtime.appServicesDrained() || runtime.networkBudgetToken != 0 {
		// Retaining runtime also retains the process-lock handle. Dropping the
		// last reference here could let a finalizer release the lock while
		// upstream services are still alive after an abnormal App.Stop.
		return err
	}
	c.runtime = nil
	c.session = nil
	c.clearRuntimeCancel(runtime.coreRuntimeCancelToken)
	c.lifecycle = lifecycleStopped
	c.generation++
	return err
}

func configureLocations(home, configurationDirectory, dataDirectory string) error {
	for base, directory := range map[locations.BaseDirEnum]string{
		locations.UserHomeBaseDir: home,
		locations.ConfigBaseDir:   configurationDirectory,
		locations.DataBaseDir:     dataDirectory,
	} {
		if err := locations.SetBaseDir(base, directory); err != nil {
			return err
		}
	}
	return nil
}

func applyEmbeddedPolicy(current *config.Configuration, disableNetworking bool) {
	current.GUI.Enabled = false
	current.Options.StartBrowser = false
	current.Options.URAccepted = 0
	current.Options.URUniqueID = ""
	current.Options.URPostInsecurely = false
	current.Options.CREnabled = false
	current.Options.AutoUpgradeIntervalH = 0
	current.Options.UpgradeToPreReleases = false
	current.Options.SetLowPriority = false
	applyEmbeddedFolderPolicy(&current.Defaults.Folder)
	for index := range current.Folders {
		applyEmbeddedFolderPolicy(&current.Folders[index])
	}

	if disableNetworking {
		current.Options.RawListenAddresses = []string{}
		current.Options.GlobalAnnEnabled = false
		current.Options.LocalAnnEnabled = false
		current.Options.RelaysEnabled = false
		current.Options.NATEnabled = false
	}
}

func applyEmbeddedFolderPolicy(folder *config.FolderConfiguration) {
	// The embedded core runs bounded slices. Sync entry points and every
	// bridge-owned local mutation issue explicit scans, so a filesystem watcher
	// would outlive the policy-controlled work that caused the slice to start.
	folder.FSWatcherEnabled = false
}

func (runtime *runtimeState) prepareAppStop() {
	runtime.appStopRequest = make(chan struct{})
	runtime.appStopInitiated = make(chan struct{})
	runtime.appStopDone = make(chan struct{})
	go func() {
		<-runtime.appStopRequest
		close(runtime.appStopInitiated)
		result, drained := stopSyncthingApp(runtime.app)
		runtime.appStopResultMu.Lock()
		runtime.appStopResult = result
		runtime.appStopDrained = drained
		runtime.appStopResultMu.Unlock()
		close(runtime.appStopDone)
	}()
}

func (runtime *runtimeState) requestAppStop() {
	if runtime == nil || runtime.appStopRequest == nil {
		return
	}
	runtime.appStopOnce.Do(func() {
		close(runtime.appStopRequest)
	})
}

func (runtime *runtimeState) waitForAppStop() (error, bool) {
	if runtime == nil || runtime.appStopRequest == nil || runtime.appStopDone == nil {
		return errors.New("Syncthing runtime stop worker is unavailable"), false
	}
	runtime.requestAppStop()
	<-runtime.appStopDone
	runtime.appStopResultMu.Lock()
	defer runtime.appStopResultMu.Unlock()
	return runtime.appStopResult, runtime.appStopDrained
}

func (runtime *runtimeState) appServicesDrained() bool {
	if runtime == nil || !runtime.appStarted {
		return true
	}
	runtime.appStopResultMu.Lock()
	defer runtime.appStopResultMu.Unlock()
	return runtime.appStopDrained
}

func stopSyncthingApp(app *syncthing.App) (result error, drained bool) {
	defer func() {
		if recover() != nil {
			result = errors.New("Syncthing runtime stop panicked")
			drained = false
		}
	}()
	if app == nil {
		return errors.New("Syncthing runtime is unavailable"), false
	}
	status := app.Stop(svcutil.ExitSuccess)
	drained = true
	if runErr := app.Error(); runErr != nil {
		result = fmt.Errorf("Syncthing runtime failed: %w", runErr)
	}
	if status != svcutil.ExitSuccess {
		result = errors.Join(result, fmt.Errorf("Syncthing stopped with status %d", status.AsInt()))
	}
	return result, drained
}

func (runtime *runtimeState) stop() error {
	if runtime == nil {
		return nil
	}

	var result error
	if runtime.appStarted {
		if runtime.app == nil {
			return errors.New("Syncthing runtime is missing; resources remain fenced")
		}
		stopErr, drained := runtime.waitForAppStop()
		result = errors.Join(result, stopErr)
		if !drained {
			// Without proof that App.Stop reached its Wait barrier, closing the DB
			// or releasing the process lock could race live Syncthing services.
			return errors.Join(result, errors.New("Syncthing runtime did not drain; resources remain fenced"))
		}
	} else if runtime.closeDatabase != nil {
		result = errors.Join(result, guardedInternal("close Syncthing database", runtime.closeDatabase))
	}
	if runtime.eventSubscription != nil {
		result = errors.Join(result, guardedInternal("unsubscribe bridge events", func() error {
			runtime.eventSubscription.Unsubscribe()
			return nil
		}))
	}
	if runtime.pendingDeviceSubscription != nil {
		result = errors.Join(result, guardedInternal("unsubscribe pending device events", func() error {
			runtime.pendingDeviceSubscription.Unsubscribe()
			return nil
		}))
	}
	if runtime.pendingFolderObservationSubscription != nil {
		result = errors.Join(result, guardedInternal("unsubscribe pending folder observation events", func() error {
			runtime.pendingFolderObservationSubscription.Unsubscribe()
			return nil
		}))
	}
	if runtime.earlyCancel != nil {
		result = errors.Join(result, guardedInternal("stop early services", func() error {
			runtime.earlyCancel()
			if runtime.earlyErrors == nil {
				return nil
			}
			select {
			case earlyErr, ok := <-runtime.earlyErrors:
				if ok && earlyErr != nil && !errors.Is(earlyErr, context.Canceled) {
					return earlyErr
				}
				return nil
			case <-time.After(5 * time.Second):
				return errors.New("timed out stopping early services")
			}
		}))
	}
	if runtime.pendingDeviceWatcherDone != nil {
		select {
		case <-runtime.pendingDeviceWatcherDone:
		case <-time.After(time.Second):
			result = errors.Join(result, errors.New("timed out stopping pending device observer"))
		}
	}
	if runtime.networkBudgetToken != 0 {
		if budgetErr := runtime.clearNetworkByteBudget(); budgetErr != nil {
			if runtime.networkBudgetToken != 0 {
				// Keep the process lock and runtime fence when the owner token could
				// not clear the active global budget.
				return errors.Join(result, budgetErr)
			}
			result = errors.Join(result, budgetErr)
		}
	}
	if runtime.processLock != nil {
		result = errors.Join(result, guardedInternal("release process lock", runtime.processLock.Close))
	}
	return result
}

func (runtime *runtimeState) clearNetworkByteBudget() error {
	status, err := protocol.ClearNetworkByteBudget(runtime.networkBudgetToken)
	if err != nil {
		return fmt.Errorf("clear aggregate protocol byte budget: %w", err)
	}
	runtime.networkBudgetToken = 0
	runtime.networkBudgetFinal = networkBudgetReportFromProtocol(status)
	runtime.networkBudgetFinalized = true

	received, sent := protocol.TotalInOut()
	if received < runtime.networkBudgetBaselineIn || sent < runtime.networkBudgetBaselineOut {
		return errors.New("aggregate protocol byte counters regressed during the network session")
	}
	receivedDelta := received - runtime.networkBudgetBaselineIn
	sentDelta := sent - runtime.networkBudgetBaselineOut
	if sentDelta > 9223372036854775807-receivedDelta {
		return errors.New("aggregate protocol byte counter delta overflowed Int64")
	}
	if delta := receivedDelta + sentDelta; delta != status.UsedBytes {
		return fmt.Errorf("aggregate protocol byte budget reconciliation failed: used %d, protocol delta %d", status.UsedBytes, delta)
	}
	return nil
}

func guardedInternal(operation string, function func() error) (err error) {
	defer func() {
		if recover() != nil {
			err = fmt.Errorf("%s: %w", operation, errInternalPanic)
		}
	}()
	if err := function(); err != nil {
		return fmt.Errorf("%s: %w", operation, err)
	}
	return nil
}

func recoverAsError(err *error) {
	if recover() != nil {
		*err = errInternalPanic
	}
}
