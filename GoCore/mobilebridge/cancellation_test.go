// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestRequestCancelInterruptsRegisteredReadContextWithoutMainMutex(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	core.beginCancelableOperation()
	ctx, cancel := context.WithCancel(context.Background())
	token := core.registerReadCancel(cancel)
	defer core.clearReadCancel(token)
	// A real remote ReadRangeJSON holds this mutex while DownloadBlock waits.
	// Holding it here proves RequestCancel uses only the independent cancel
	// registry and cannot queue behind the blocked gomobile call.
	core.mu.Lock()
	returned := make(chan struct{})
	go func() {
		core.RequestCancel()
		close(returned)
	}()
	select {
	case <-returned:
	case <-time.After(250 * time.Millisecond):
		core.mu.Unlock()
		t.Fatal("RequestCancel waited for the Core mutex")
	}
	select {
	case <-ctx.Done():
	case <-time.After(250 * time.Millisecond):
		core.mu.Unlock()
		t.Fatal("RequestCancel did not cancel the registered remote read context")
	}
	core.mu.Unlock()

	core.clearReadCancel(token)
	core.beginCancelableOperation()
	if core.stopRequested.Load() {
		t.Fatal("a completed operation's cancellation polluted the next read")
	}
	nextContext, nextCancel := context.WithCancel(context.Background())
	nextToken := core.registerReadCancel(nextCancel)
	defer func() {
		core.clearReadCancel(nextToken)
		nextCancel()
	}()
	select {
	case <-nextContext.Done():
		t.Fatal("new remote read context inherited a stale cancellation")
	default:
	}
}

func TestRequestCancelInterruptsBoundedSyncSlice(t *testing.T) {
	fixture := newPhase3Fixture(t)
	started := make(chan struct{})
	fixture.core.syncLoopStartedForTests = started
	response := make(chan string, 1)
	go func() {
		response <- fixture.core.CommandJSON(commandForTest(
			"cancel-sync-slice",
			"sync",
			fixture.folderID,
			"",
			map[string]string{"timeoutMS": "15000", "settleMS": "1000"},
		))
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("sync slice did not enter its cancellable loop")
	}

	before := time.Now()
	fixture.core.RequestCancel()
	if elapsed := time.Since(before); elapsed > 250*time.Millisecond {
		t.Fatalf("RequestCancel blocked for %s", elapsed)
	}
	select {
	case raw := <-response:
		envelope := decodeTestEnvelope(t, raw)
		assertEnvelopeErrorCode(t, envelope, "sync_cancelled")
	case <-time.After(time.Second):
		t.Fatal("bounded sync slice did not observe RequestCancel promptly")
	}
}

func TestCancelledReadEnvelopeIsStableAndSanitized(t *testing.T) {
	envelope := decodeTestEnvelope(t, readRangeFailureEnvelope("cancelled-read", "cancelled"))
	assertEnvelopeErrorCode(t, envelope, "cancelled")
	if envelope.RequestID != "cancelled-read" || envelope.Kind != "readRange" {
		t.Fatalf("cancelled read envelope lost identity: %+v", envelope)
	}
	if envelope.Error.Message != "the read range request was cancelled" {
		t.Fatalf("cancelled read exposed an unstable native error: %q", envelope.Error.Message)
	}
}

func TestRequestCancelStopsRealRuntimeWhileRescanHoldsMainMutex(t *testing.T) {
	fixture := newPhase3Fixture(t)
	entered := make(chan struct{})
	var enterOnce sync.Once
	fixture.core.scanFolderSubdirsForTests = func(_ string, _ []string) error {
		enterOnce.Do(func() { close(entered) })
		<-fixture.core.runtime.appStopInitiated
		return context.Canceled
	}

	response := make(chan string, 1)
	go func() {
		response <- fixture.core.CommandJSON(commandForTest(
			"cancel-blocked-real-rescan",
			"rescan",
			fixture.folderID,
			"",
			nil,
		))
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("rescan did not enter the blocking scan seam")
	}

	started := time.Now()
	fixture.core.RequestCancel()
	if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
		t.Fatalf("RequestCancel blocked behind CommandJSON for %s", elapsed)
	}
	select {
	case <-fixture.core.runtime.appStopInitiated:
		if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
			t.Fatalf("runtime stop was not initiated promptly: %s", elapsed)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("RequestCancel did not initiate a real Syncthing runtime stop")
	}
	select {
	case raw := <-response:
		envelope := decodeTestEnvelope(t, raw)
		assertEnvelopeErrorCode(t, envelope, "cancelled")
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled rescan did not return")
	}

	// Normal lifecycle cleanup must join the already requested stop instead of
	// invoking App.Stop again or releasing the database before it drains.
	if err := fixture.core.Stop(); err != nil {
		t.Fatal(err)
	}
	if fixture.core.lifecycle != lifecycleStopped || fixture.core.runtime != nil {
		t.Fatalf("cancelled runtime was not cleaned up safely: lifecycle=%s runtime=%p", fixture.core.lifecycle, fixture.core.runtime)
	}
}

func TestFailedRuntimeDrainRetainsProcessFenceAndSingletonOwnership(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &runtimeState{
		appStarted:     true,
		appStopRequest: make(chan struct{}),
		appStopDone:    make(chan struct{}),
		appStopResult:  errors.New("injected undrained runtime"),
		appStopDrained: false,
	}
	close(runtime.appStopDone)
	core.runtime = runtime
	core.lifecycle = lifecycleRunning
	identityLength := len(core.identityBlob)

	if err := core.Close(); err == nil {
		t.Fatal("Close succeeded without proof that Syncthing services drained")
	}
	if core.runtime != runtime || core.lifecycle != lifecycleStopping || core.closed {
		t.Fatalf(
			"undrained runtime fence was discarded: runtime=%p lifecycle=%s closed=%v",
			core.runtime,
			core.lifecycle,
			core.closed,
		)
	}
	if len(core.identityBlob) != identityLength {
		t.Fatal("failed Close cleared identity while the fenced runtime remained live")
	}
	singletonMu.Lock()
	stillOwner := singleton == core
	singletonMu.Unlock()
	if !stillOwner {
		t.Fatal("failed Close released singleton ownership before runtime drain")
	}

	// Test-only recovery: model a later proof that no App services remain, then
	// ensure the same Core can finish terminal cleanup and release ownership.
	runtime.appStarted = false
	if err := core.Close(); err != nil {
		t.Fatalf("close after proven drain: %v", err)
	}
	singletonMu.Lock()
	released := singleton == nil
	singletonMu.Unlock()
	if !released || !core.closed || core.runtime != nil {
		t.Fatal("terminal cleanup did not release ownership after proven drain")
	}
}

func TestConfigurationWaiterReturnsOnIndependentCancellation(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.beginCancelableOperation()
	defer core.endCancelableOperation()
	waiter := &blockingConfigurationWaiter{
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}
	defer close(waiter.release)

	result := make(chan error, 1)
	go func() {
		result <- core.waitForConfigurationLocked(waiter)
	}()
	select {
	case <-waiter.entered:
	case <-time.After(time.Second):
		t.Fatal("configuration waiter did not start")
	}
	core.RequestCancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("configuration waiter returned %v, want context cancellation", err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("configuration waiter remained pinned after cancellation")
	}
}

func TestCancelledMutationRetainsCommitPhaseForReconciliation(t *testing.T) {
	ambiguous := true
	postcommit := &responseError{
		Code:              "rescan_failed",
		Message:           "private native error",
		MutationPhase:     mutationPhasePostcommit,
		MutationAmbiguous: &ambiguous,
	}
	failure := cancelledCommandFailure("modify", postcommit)
	if failure.Code != "cancelled" || failure.MutationPhase != mutationPhasePostcommit || failure.MutationAmbiguous == nil || !*failure.MutationAmbiguous {
		t.Fatalf("postcommit cancellation lost reconciliation metadata: %+v", failure)
	}
	precommit := cancelledCommandFailure("modify", nil)
	if precommit.MutationPhase != mutationPhasePrecommit || precommit.MutationAmbiguous == nil || *precommit.MutationAmbiguous {
		t.Fatalf("precommit cancellation became replay-ambiguous: %+v", precommit)
	}
}

type blockingConfigurationWaiter struct {
	entered chan struct{}
	release chan struct{}
}

func (w *blockingConfigurationWaiter) Wait() {
	close(w.entered)
	<-w.release
}
