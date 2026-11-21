// SPDX-License-Identifier: MIT

package psybridge

import (
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

func TestProcessSlotDrainNotPoison(t *testing.T) {
	if err := acquireProcess("engine", 0); err != nil {
		t.Fatal(err)
	}
	// Busy (not draining): a second owner gets already_running.
	if err := acquireProcess("fetch", 50*time.Millisecond); codeOf(err) != CodeAlreadyRunning {
		t.Fatalf("got %v", err)
	}
	// A runtime that missed its stop deadline: stop_timeout while draining…
	markDraining("engine")
	if err := acquireProcess("engine", 50*time.Millisecond); codeOf(err) != CodeStopTimeout {
		t.Fatalf("got %v", err)
	}
	// …and the waiter gets the slot as soon as the drain finishes.
	go func() {
		time.Sleep(100 * time.Millisecond)
		releaseProcess("engine")
	}()
	start := time.Now()
	if err := acquireProcess("engine", 5*time.Second); err != nil {
		t.Fatalf("acquire after drain: %v", err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("waited %v", d)
	}
	releaseProcess("engine")
	releaseProcess("engine") // idempotent
}

func TestTuneUpstreamCloseTimeout(t *testing.T) {
	old := protocol.CloseTimeout
	defer func() { protocol.CloseTimeout = old }()
	tuneUpstream()
	if protocol.CloseTimeout != connectionCloseTimeout || connectionCloseTimeout > 2*time.Second {
		t.Fatalf("CloseTimeout = %v", protocol.CloseTimeout)
	}
}
