// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"testing"
)

// Regression: IndexStream.Close never removed the stream from e.streams, so
// the map grew for the life of a long-running (Mac) engine.
func TestIndexStreamCloseUnregisters(t *testing.T) {
	e := &Engine{}
	a := &IndexStream{folderID: "f", engine: e}
	b := &IndexStream{folderID: "f", engine: e}
	e.streams = map[*IndexStream]struct{}{a: {}, b: {}}
	a.Close()
	a.Close() // idempotent
	if _, ok := e.streams[a]; ok || len(e.streams) != 1 {
		t.Fatalf("closed stream still tracked: %d streams", len(e.streams))
	}
	if !a.closed {
		t.Fatal("stream not closed")
	}
	// Engine stop closes the rest and clears the map; a later Close is a no-op.
	e.mu.Lock()
	e.closeStreamsLocked()
	e.mu.Unlock()
	b.Close()
	if len(e.streams) != 0 || !b.closed {
		t.Fatal("stop did not close remaining streams")
	}
}

type exitRecorder struct{ code, detail string }

func (r *exitRecorder) EngineExited(code, detail string) { r.code, r.detail = code, detail }

// Regression: an unexpected engine exit (watchExit) cancelled only the early
// supervisor, never rt.extraCancel, so the peer-cache goroutine leaked.
func TestUnexpectedExitCancelsBridgeGoroutines(t *testing.T) {
	if err := acquireProcess("engine", 0); err != nil {
		t.Fatal(err)
	}
	extraCtx, extraCancel := context.WithCancel(context.Background())
	earlyCalled := false
	rt := &upstreamRuntime{extraCancel: extraCancel, earlyCancel: func() { earlyCalled = true }}
	obs := &exitRecorder{}
	e := &Engine{rt: rt, obs: obs}
	e.handleExit(rt, nil, nil)
	if extraCtx.Err() == nil {
		t.Fatal("extraCancel not called on unexpected exit")
	}
	if !earlyCalled || e.rt != nil || obs.code != CodeNotRunning {
		t.Fatalf("exit not handled: early=%v rt=%v code=%q", earlyCalled, e.rt, obs.code)
	}
	// The process slot was released.
	if err := acquireProcess("engine", 0); err != nil {
		t.Fatalf("slot not released: %v", err)
	}
	releaseProcess("engine")
}
