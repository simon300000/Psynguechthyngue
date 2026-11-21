// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

// Upstream Syncthing keeps process-global state (locations, the default slog
// logger, protocol counters), so at most one upstream App may run per
// process: either the long-lived Engine or one restricted FetchFile.
//
// A Stop that misses its deadline does not poison the process: the old
// runtime keeps shutting down in the background ("draining") and keeps the
// process slot until it is done; the next Start/FetchFile waits for it.
var (
	processMu       sync.Mutex
	processOwner    string        // "" | "engine" | "fetch" | "record"
	processDraining bool          // owner is a runtime still stopping after a missed deadline
	processIdle     chan struct{} // closed when processOwner becomes ""
)

// acquireProcess takes the process slot, waiting up to wait for a previous
// owner to release it.
func acquireProcess(owner string, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	for {
		processMu.Lock()
		if processOwner == "" {
			processOwner = owner
			processDraining = false
			processIdle = make(chan struct{})
			processMu.Unlock()
			return nil
		}
		idle, current, draining := processIdle, processOwner, processDraining
		processMu.Unlock()
		remaining := time.Until(deadline)
		if remaining <= 0 {
			if draining {
				return newError(CodeStopTimeout, "the previous %s is still stopping; retry later", current)
			}
			return newError(CodeAlreadyRunning, "%s already owns the Syncthing runtime in this process", current)
		}
		select {
		case <-idle:
		case <-time.After(remaining):
		}
	}
}

func releaseProcess(owner string) {
	processMu.Lock()
	defer processMu.Unlock()
	if processOwner == owner {
		processOwner = ""
		processDraining = false
		close(processIdle)
	}
}

// markDraining records that owner's runtime missed its stop deadline and is
// still shutting down.
func markDraining(owner string) {
	processMu.Lock()
	defer processMu.Unlock()
	if processOwner == owner {
		processDraining = true
	}
}

// connectionCloseTimeout bounds how long upstream waits to deliver a BEP
// Close message before dropping a connection (protocol.CloseTimeout, 10 s
// upstream). A peer that vanished mid-transfer (writer blocked or gone) made
// every Stop wait the full 10 s before the DB was even closed; 2 s keeps the
// polite close for live peers and lets Stop meet a 5-10 s background budget.
const connectionCloseTimeout = 2 * time.Second

// tuneUpstream applies process-wide upstream knobs. Called while holding the
// process slot and before any connection exists, so no goroutine reads them
// concurrently.
func tuneUpstream() {
	protocol.CloseTimeout = connectionCloseTimeout
}

// Upstream defaults (cmd/syncthing): --db-delete-retention-interval=10920h,
// --db-maintenance-interval=8h.
const (
	dbDeleteRetention     = 10920 * time.Hour
	dbMaintenanceInterval = 8 * time.Hour
)

func parseIdentity(certPEM, keyPEM []byte) (tls.Certificate, protocol.DeviceID, error) {
	if len(certPEM) == 0 || len(keyPEM) == 0 {
		return tls.Certificate{}, protocol.EmptyDeviceID, newError(CodeIdentity, "certificate and key are required")
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, protocol.EmptyDeviceID, newError(CodeIdentity, "unreadable certificate or key: %v", err)
	}
	return cert, protocol.NewDeviceID(cert.Certificate[0]), nil
}

// configureLocations points every upstream location at homeDir:
// homeDir/config.xml, homeDir/index-v2/, homeDir/syncthing.lock, ...
func configureLocations(homeDir string) error {
	if !filepath.IsAbs(homeDir) {
		return newError(CodeInvalidArgument, "HomeDir must be absolute")
	}
	if err := os.MkdirAll(homeDir, 0o700); err != nil {
		return newError(CodeIO, "create HomeDir: %v", err)
	}
	for _, base := range []locations.BaseDirEnum{locations.ConfigBaseDir, locations.DataBaseDir, locations.UserHomeBaseDir} {
		if err := locations.SetBaseDir(base, homeDir); err != nil {
			return newError(CodeIO, "set location: %v", err)
		}
	}
	return nil
}

// upstreamRuntime is one running upstream App plus the "early" supervisor
// that runs the event logger and the config wrapper (same structure as
// upstream cmd/syncthing).
type upstreamRuntime struct {
	app         *syncthing.App
	db          io.Closer
	extraCancel context.CancelFunc // bridge-side goroutines (peer cache)
	earlyCancel context.CancelFunc
	earlyDone   <-chan error

	stopOnce sync.Once
	stopped  chan struct{}
}

func newEarlySupervisor() (events.Logger, *suture.Supervisor, context.CancelFunc, <-chan error) {
	sup := suture.New("psybridge-early", svcutil.SpecWithDebugLogger())
	ctx, cancel := context.WithCancel(context.Background())
	done := sup.ServeBackground(ctx)
	evLogger := events.NewLogger()
	sup.Add(evLogger)
	return evLogger, sup, cancel, done
}

// stopAsync starts shutting down (once) and returns a channel closed when
// the App, its DB and the early services are all gone.
func (r *upstreamRuntime) stopAsync() <-chan struct{} {
	r.stopOnce.Do(func() {
		r.stopped = make(chan struct{})
		go func() {
			defer close(r.stopped)
			if r.extraCancel != nil {
				r.extraCancel()
			}
			if r.app != nil {
				r.app.Stop(svcutil.ExitSuccess) // waits for services and DB close
			}
			if r.db != nil {
				// The App closes the DB itself once started; this covers error
				// paths before that point (Close is idempotent upstream).
				_ = r.db.Close()
			}
			if r.earlyCancel != nil {
				r.earlyCancel()
				<-r.earlyDone
			}
		}()
	})
	return r.stopped
}

// stopAndRelease stops the runtime within timeout. On time it releases the
// process slot and returns true. Otherwise it marks the slot as draining,
// releases it in the background once shutdown completes, and returns false.
func (r *upstreamRuntime) stopAndRelease(owner string, timeout time.Duration) bool {
	done := r.stopAsync()
	select {
	case <-done:
		releaseProcess(owner)
		return true
	case <-time.After(timeout):
		markDraining(owner)
		go func() {
			<-done
			releaseProcess(owner)
		}()
		return false
	}
}

func defaultMaxProcs() int {
	return min(4, runtime.NumCPU())
}

func millis(v int64, def time.Duration) time.Duration {
	if v <= 0 {
		return def
	}
	return time.Duration(v) * time.Millisecond
}

func wrapUpstream(code string, what string, err error) error {
	var be *BridgeError
	if errors.As(err, &be) {
		return be
	}
	return newError(code, "%s: %s", what, fmt.Sprint(err))
}
