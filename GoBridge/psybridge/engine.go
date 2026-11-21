// SPDX-License-Identifier: MIT

package psybridge

// EngineConfig describes one long-lived engine instance owned by the App.
//
// Paths are absolute. HomeDir holds config.xml and the Syncthing database and
// lives in the App Group container so the File Provider extension's
// restricted fetch can read the same index when the App is not running.
type EngineConfig struct {
	// HomeDir: <AppGroup>/Engine. Contains config.xml, index-v2/ (Syncthing DB).
	HomeDir string
	// CertPEM / KeyPEM: device identity, stored by Swift in the Keychain
	// (shared access group) and passed in on every start. Never written to disk
	// by the bridge.
	CertPEM []byte
	KeyPEM  []byte
	// DeviceName is applied to config on first start only.
	DeviceName string

	// Runtime tuning (see runtime.go). Zero means "use default".
	MemoryLimitMiB int64
	GCPercent      int64
	MaxProcs       int64

	// APIAddress: "127.0.0.1:0" (random port, default) — never a non-loopback
	// address. A fixed port is only for tests.
	APIAddress string

	// LogLevel: "info" | "debug". Logs go to LogSink if set, else are dropped.
	LogLevel string
}

// APIEndpoint is returned by Start. Swift's REST client uses it for the
// engine's lifetime. APIKey is random per Start and never persisted.
type APIEndpoint struct {
	// BaseURL e.g. "http://127.0.0.1:53817"
	BaseURL string
	APIKey  string
	// DeviceID is the full Syncthing device ID of this device.
	DeviceID string
}

// LogSink receives engine log lines (already redacted of the API key).
type LogSink interface {
	Log(level string, message string)
}

// ExitObserver is told when the engine stops for any reason other than an
// explicit Stop call (crash of a service, fatal DB error, ...).
type ExitObserver interface {
	EngineExited(code string, detail string)
}

// Engine wraps one upstream `syncthing.App`. At most one Engine per process may
// be running. Cross-process exclusivity (App engine vs extension restricted
// fetch) is the caller's job: Swift must hold the App Group engine lock
// (PsySync `EngineLock`) before Start and until Stop returns.
type Engine struct {
	cfg EngineConfig
	log LogSink
	obs ExitObserver
}

// NewEngine validates the configuration but does not touch the network or DB.
func NewEngine(cfg *EngineConfig, log LogSink, observer ExitObserver) (*Engine, error) {
	if cfg == nil || cfg.HomeDir == "" {
		return nil, newError(CodeInvalidArgument, "HomeDir is required")
	}
	if len(cfg.CertPEM) == 0 || len(cfg.KeyPEM) == 0 {
		return nil, newError(CodeIdentity, "certificate and key are required")
	}
	return &Engine{cfg: *cfg, log: log, obs: observer}, nil
}

// Start opens the DB, loads (or creates) config.xml,
// forces the GUI/API onto loopback with a fresh API key, and starts the
// upstream App. Blocks until the REST API answers /rest/noauth/health or the
// timeout elapses.
//
// Effects on config applied on every start (in memory and persisted):
//   - gui.address = APIAddress, gui.apikey = random, gui.tls = false
//   - options: urAccepted = -1, autoUpgradeIntervalH = 0, crashReportingEnabled = false
//   - every folder: fsWatcherEnabled = false on iOS (no FSEvents), rescanIntervalS = 3600
func (e *Engine) Start(timeoutMillis int64) (*APIEndpoint, error) {
	return nil, notImplemented("Engine.Start")
}

// Stop requests a graceful shutdown (upstream App.Stop) and waits up to
// timeoutMillis for the DB to close and the engine lock to be released.
// On CodeStopTimeout the caller must treat the process as poisoned for engine
// purposes (do not Start again in this process).
func (e *Engine) Stop(timeoutMillis int64) error {
	return notImplemented("Engine.Stop")
}

// IsRunning reports whether Start succeeded and Stop has not completed.
func (e *Engine) IsRunning() bool { return false }

// OnMemoryWarning is called from UIApplication.didReceiveMemoryWarning:
// runs debug.FreeOSMemory and temporarily lowers the memory limit.
func (e *Engine) OnMemoryWarning() {}
