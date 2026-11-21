// SPDX-License-Identifier: MIT

package psybridge

import (
	"crypto/rand"
	"encoding/base32"
	"errors"
	"net"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

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

	mu       sync.Mutex
	rt       *upstreamRuntime
	sdb      dbQueries
	wrapper  config.Wrapper
	myID     protocol.DeviceID
	endpoint *APIEndpoint
	stopping bool
	streams  map[*IndexStream]struct{}
}

// NewEngine validates the configuration but does not touch the network or DB.
func NewEngine(cfg *EngineConfig, log LogSink, observer ExitObserver) (*Engine, error) {
	if cfg == nil || cfg.HomeDir == "" {
		return nil, newError(CodeInvalidArgument, "HomeDir is required")
	}
	if len(cfg.CertPEM) == 0 || len(cfg.KeyPEM) == 0 {
		return nil, newError(CodeIdentity, "certificate and key are required")
	}
	if _, err := loopbackAddress(cfg.APIAddress); err != nil {
		return nil, err
	}
	return &Engine{cfg: *cfg, log: log, obs: observer}, nil
}

const (
	defaultAPIAddress   = "127.0.0.1:0"
	defaultStartTimeout = 30 * time.Second
	iosRescanIntervalS  = 3600
)

// loopbackAddress validates an APIAddress and returns it with defaults applied.
func loopbackAddress(addr string) (string, error) {
	if addr == "" {
		addr = defaultAPIAddress
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "", newError(CodeInvalidArgument, "APIAddress %q: %v", addr, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return "", newError(CodeInvalidArgument, "APIAddress must be a loopback IP literal, got %q", host)
	}
	return net.JoinHostPort(ip.String(), port), nil
}

// resolvePort replaces port 0 with a currently free loopback port. Upstream's
// API service does not report the port it bound, so we choose it.
func resolvePort(addr string) (string, error) {
	host, port, _ := net.SplitHostPort(addr)
	if port != "0" {
		return addr, nil
	}
	l, err := net.Listen("tcp", net.JoinHostPort(host, "0"))
	if err != nil {
		return "", newError(CodeListen, "probe loopback port: %v", err)
	}
	defer l.Close()
	return l.Addr().String(), nil
}

func randomAPIKey() string {
	b := make([]byte, 20)
	_, _ = rand.Read(b)
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

// applyEngineConfig enforces the embedded policy on every start.
func applyEngineConfig(c *config.Configuration, myID protocol.DeviceID, apiAddr, apiKey, deviceName string, firstStart bool) {
	c.GUI.Enabled = true
	c.GUI.RawAddress = apiAddr
	c.GUI.RawUseTLS = false
	c.GUI.APIKey = apiKey
	c.GUI.InsecureAdminAccess = false
	c.GUI.InsecureSkipHostCheck = false
	c.GUI.InsecureAllowFrameLoading = false

	c.Options.URAccepted = -1
	c.Options.URSeen = 0
	c.Options.URUniqueID = ""
	c.Options.AutoUpgradeIntervalH = 0
	c.Options.UpgradeToPreReleases = false
	c.Options.CREnabled = false
	c.Options.StartBrowser = false
	c.Options.SetLowPriority = false

	applyFolderPolicy(&c.Defaults.Folder)
	for i := range c.Folders {
		applyFolderPolicy(&c.Folders[i])
	}

	if firstStart && deviceName != "" {
		for i := range c.Devices {
			if c.Devices[i].DeviceID == myID {
				c.Devices[i].Name = deviceName
			}
		}
		c.Defaults.Device.Name = ""
	}
}

func applyFolderPolicy(f *config.FolderConfiguration) {
	if runtime.GOOS == "ios" {
		// No FSEvents on iOS; the Files journal + targeted scans replace it.
		f.FSWatcherEnabled = false
		f.RescanIntervalS = iosRescanIntervalS
	}
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
func (e *Engine) Start(timeoutMillis int64) (endpoint *APIEndpoint, err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.rt != nil {
		return nil, newError(CodeAlreadyRunning, "engine already started")
	}
	if err := acquireProcess("engine"); err != nil {
		return nil, err
	}
	rt := &upstreamRuntime{}
	defer func() {
		if err != nil {
			poisoned := !rt.stop(10 * time.Second)
			releaseProcess("engine", poisoned)
		}
	}()

	timeout := millis(timeoutMillis, defaultStartTimeout)
	deadline := time.Now().Add(timeout)

	cert, myID, err := parseIdentity(e.cfg.CertPEM, e.cfg.KeyPEM)
	if err != nil {
		return nil, err
	}
	addr, err := loopbackAddress(e.cfg.APIAddress)
	if err != nil {
		return nil, err
	}
	if addr, err = resolvePort(addr); err != nil {
		return nil, err
	}
	// Environment overrides would bypass the loopback/API key policy.
	os.Unsetenv("STGUIADDRESS")
	os.Unsetenv("STGUIAPIKEY")

	applyRuntimeProfile(e.cfg.MemoryLimitMiB, e.cfg.GCPercent, e.cfg.MaxProcs,
		DefaultForegroundMemoryLimitMiB, DefaultGCPercent, defaultMaxProcs())
	if err := configureLocations(e.cfg.HomeDir); err != nil {
		return nil, err
	}
	apiKey := randomAPIKey()
	logs := installLogSink(e.log, e.cfg.LogLevel)
	logs.addSecret(apiKey)

	evLogger, early, cancel, done := newEarlySupervisor()
	rt.earlyCancel, rt.earlyDone = cancel, done

	cfgPath := locations.Get(locations.ConfigFile)
	_, statErr := os.Stat(cfgPath)
	firstStart := errors.Is(statErr, os.ErrNotExist)
	cfg, err := syncthing.LoadConfigAtStartup(cfgPath, cert, evLogger, false, true)
	if err != nil {
		return nil, newError(CodeConfig, "%v", err)
	}
	early.Add(cfg)
	waiter, err := cfg.Modify(func(c *config.Configuration) {
		applyEngineConfig(c, myID, addr, apiKey, e.cfg.DeviceName, firstStart)
	})
	if err != nil {
		return nil, newError(CodeConfig, "apply embedded policy: %v", err)
	}
	waiter.Wait()
	if err := cfg.Save(); err != nil {
		return nil, newError(CodeConfig, "save config: %v", err)
	}

	sdb, err := syncthing.OpenDatabase(locations.Get(locations.Database), dbDeleteRetention)
	if err != nil {
		return nil, newError(CodeDatabase, "%v", err)
	}
	rt.db = sdb
	queries, ok := sdb.(dbQueries)
	if !ok {
		return nil, newError(CodeDatabase, "upstream DB lacks expected query methods")
	}
	app, err := syncthing.New(cfg, sdb, evLogger, cert, syncthing.Options{
		NoUpgrade:             true,
		DBMaintenanceInterval: dbMaintenanceInterval,
	})
	if err != nil {
		return nil, newError(CodeDatabase, "create app: %v", err)
	}
	rt.app = app
	if err := app.Start(); err != nil {
		return nil, wrapUpstream(CodeDatabase, "start", err)
	}
	baseURL := "http://" + addr
	if err := waitHealthy(baseURL, deadline, app); err != nil {
		return nil, err
	}

	e.rt = rt
	e.sdb = queries
	e.wrapper = cfg
	e.myID = myID
	e.stopping = false
	e.endpoint = &APIEndpoint{BaseURL: baseURL, APIKey: apiKey, DeviceID: myID.String()}
	go e.watchExit(rt, logs)
	out := *e.endpoint
	return &out, nil
}

func waitHealthy(baseURL string, deadline time.Time, app *syncthing.App) error {
	client := &http.Client{Timeout: time.Second}
	for {
		resp, err := client.Get(baseURL + "/rest/noauth/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		if appErr := app.Error(); appErr != nil {
			return newError(CodeListen, "engine exited during start: %v", appErr)
		}
		if time.Now().After(deadline) {
			detail := "timeout"
			if err != nil {
				detail = err.Error()
			}
			return newError(CodeListen, "REST API not healthy on %s: %s", baseURL, detail)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// watchExit reports an unexpected exit (anything but our own Stop) to Swift.
func (e *Engine) watchExit(rt *upstreamRuntime, logs *sinkShared) {
	rt.app.Wait()
	e.mu.Lock()
	unexpected := e.rt == rt && !e.stopping
	if unexpected {
		e.closeStreamsLocked()
		rt.earlyCancel()
		e.rt = nil
		e.endpoint = nil
		e.sdb = nil
		releaseProcess("engine", false)
	}
	e.mu.Unlock()
	if unexpected && e.obs != nil {
		code, detail := CodeNotRunning, "engine stopped"
		if err := rt.app.Error(); err != nil {
			detail = logs.redact(err.Error())
			if strings.Contains(strings.ToLower(detail), "database") || strings.Contains(detail, "sqlite") {
				code = CodeDatabase
			}
		}
		e.obs.EngineExited(code, detail)
	}
}

// Stop requests a graceful shutdown (upstream App.Stop) and waits up to
// timeoutMillis for the DB to close and the engine lock to be released.
// On CodeStopTimeout the caller must treat the process as poisoned for engine
// purposes (do not Start again in this process).
func (e *Engine) Stop(timeoutMillis int64) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.rt == nil {
		return newError(CodeNotRunning, "engine is not running")
	}
	e.stopping = true
	e.closeStreamsLocked()
	ok := e.rt.stop(millis(timeoutMillis, 10*time.Second))
	e.rt = nil
	e.endpoint = nil
	e.sdb = nil
	releaseProcess("engine", !ok)
	if !ok {
		return newError(CodeStopTimeout, "engine did not stop within %d ms", timeoutMillis)
	}
	return nil
}

// IsRunning reports whether Start succeeded and Stop has not completed.
func (e *Engine) IsRunning() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.rt != nil
}

// OnMemoryWarning is called from UIApplication.didReceiveMemoryWarning:
// runs debug.FreeOSMemory and temporarily lowers the memory limit.
func (e *Engine) OnMemoryWarning() { memoryWarning() }

func (e *Engine) closeStreamsLocked() {
	for s := range e.streams {
		s.closeLocked()
	}
	e.streams = nil
}
