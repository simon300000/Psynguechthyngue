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
var (
	processMu     sync.Mutex
	processOwner  string // "" | "engine" | "fetch"
	processPoison bool   // set after a stop timeout; nothing may start again
)

func acquireProcess(owner string) error {
	processMu.Lock()
	defer processMu.Unlock()
	if processPoison {
		return newError(CodeStopTimeout, "a previous engine did not stop; restart the process")
	}
	if processOwner != "" {
		return newError(CodeAlreadyRunning, "%s already owns the Syncthing runtime in this process", processOwner)
	}
	processOwner = owner
	return nil
}

func releaseProcess(owner string, poisoned bool) {
	processMu.Lock()
	defer processMu.Unlock()
	if processOwner == owner {
		processOwner = ""
	}
	if poisoned {
		processPoison = true
	}
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
}

func newEarlySupervisor() (events.Logger, *suture.Supervisor, context.CancelFunc, <-chan error) {
	sup := suture.New("psybridge-early", svcutil.SpecWithDebugLogger())
	ctx, cancel := context.WithCancel(context.Background())
	done := sup.ServeBackground(ctx)
	evLogger := events.NewLogger()
	sup.Add(evLogger)
	return evLogger, sup, cancel, done
}

// stop stops the App and then the early services. Returns false when the
// deadline passed before everything (including the DB) closed.
func (r *upstreamRuntime) stop(timeout time.Duration) bool {
	done := make(chan struct{})
	go func() {
		defer close(done)
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
	select {
	case <-done:
		return true
	case <-time.After(timeout):
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
