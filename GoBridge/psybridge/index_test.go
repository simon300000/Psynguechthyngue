// SPDX-License-Identifier: MIT

package psybridge

import (
	"runtime"
	"sync/atomic"
	"testing"
)

// Regression (simulator acceptance): gomobile callbacks are locked to the
// calling OS thread and Swift's serial queue may use a different thread for
// each Next, which made iter.Pull abort the process. pullAnyThread must work
// when created and resumed from different locked threads, and stop must end
// the producer (closing upstream DB rows) even mid-stream.
func TestPullAnyThreadAcrossLockedThreads(t *testing.T) {
	var producerDone atomic.Bool
	seq := func(yield func(int) bool) {
		defer producerDone.Store(true)
		for i := 0; i < 1000; i++ {
			if !yield(i) {
				return
			}
		}
	}
	onLockedThread := func(f func()) {
		done := make(chan struct{})
		go func() {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			defer close(done)
			f()
		}()
		<-done
	}

	var next func() (int, bool)
	var stop func()
	onLockedThread(func() { next, stop = pullAnyThread[int](seq) })
	got := 0
	for i := 0; i < 5; i++ {
		onLockedThread(func() {
			for j := 0; j < 10; j++ {
				v, ok := next()
				if !ok || v != got {
					t.Errorf("next = %d,%v want %d,true", v, ok, got)
				}
				got++
			}
		})
	}
	onLockedThread(stop)
	if !producerDone.Load() {
		t.Fatal("stop returned before the producer finished")
	}
	stop() // idempotent

	// Exhaustion.
	n, s := pullAnyThread[int](func(yield func(int) bool) { yield(1) })
	defer s()
	if v, ok := n(); !ok || v != 1 {
		t.Fatalf("first = %d,%v", v, ok)
	}
	if _, ok := n(); ok {
		t.Fatal("expected exhaustion")
	}
}
