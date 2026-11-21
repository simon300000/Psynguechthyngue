// SPDX-License-Identifier: MIT

package mobilebridge

import "context"

// requestLifecycleStop publishes cancellation before Stop or Close waits for
// the main Core mutex. Holding cancelMu only protects the tiny cancellation
// registry; it is never held while waiting for c.mu.
func (c *Core) requestLifecycleStop() {
	c.stopRequested.Store(true)
	c.cancelMu.Lock()
	c.lifecycleStopRequested = true
	operationCancel := c.activeOperationCancel
	readCancel := c.activeReadCancel
	runtimeCancel := c.activeRuntimeCancel
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

func (c *Core) clearLifecycleStop() {
	c.cancelMu.Lock()
	c.lifecycleStopRequested = false
	c.runtimeStopRequested.Store(false)
	c.stopRequested.Store(false)
	c.cancelMu.Unlock()
}

func (c *Core) clearFailedRuntimeCancellation() {
	c.cancelMu.Lock()
	defer c.cancelMu.Unlock()
	if c.lifecycleStopRequested {
		return
	}
	c.runtimeStopRequested.Store(false)
	c.stopRequested.Store(false)
}

// beginCancelableOperation clears a cancellation left behind by an earlier
// completed operation, but never clears a pending lifecycle Stop or Close.
func (c *Core) beginCancelableOperation() {
	c.cancelMu.Lock()
	operationCancel := c.activeOperationCancel
	readCancel := c.activeReadCancel
	ctx, cancel := context.WithCancel(context.Background())
	c.activeOperationCancel = cancel
	c.activeOperationDone = ctx.Done()
	c.activeReadCancel = nil
	pendingCancellation := c.cancelNextOperation
	c.cancelNextOperation = false
	if !pendingCancellation && !c.lifecycleStopRequested && !c.runtimeStopRequested.Load() {
		c.stopRequested.Store(false)
	}
	cancelImmediately := pendingCancellation || c.stopRequested.Load()
	c.cancelMu.Unlock()
	if operationCancel != nil {
		operationCancel()
	}
	if readCancel != nil {
		readCancel()
	}
	if cancelImmediately {
		cancel()
	}
}

func (c *Core) endCancelableOperation() {
	c.cancelMu.Lock()
	cancel := c.activeOperationCancel
	c.activeOperationCancel = nil
	c.activeOperationDone = nil
	c.cancelMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (c *Core) cancellationDone() <-chan struct{} {
	c.cancelMu.Lock()
	done := c.activeOperationDone
	c.cancelMu.Unlock()
	return done
}

func (c *Core) registerRuntimeCancel(cancel func()) uint64 {
	c.cancelMu.Lock()
	c.activeRuntimeToken++
	token := c.activeRuntimeToken
	c.activeRuntimeCancel = cancel
	cancelImmediately := c.stopRequested.Load()
	if cancelImmediately {
		c.runtimeStopRequested.Store(true)
	}
	c.cancelMu.Unlock()
	if cancelImmediately {
		cancel()
	}
	return token
}

func (c *Core) clearRuntimeCancel(token uint64) {
	c.cancelMu.Lock()
	if c.activeRuntimeToken == token {
		c.activeRuntimeCancel = nil
	}
	c.cancelMu.Unlock()
}

func (c *Core) registerReadCancel(cancel context.CancelFunc) uint64 {
	c.cancelMu.Lock()
	c.activeReadCancelToken++
	token := c.activeReadCancelToken
	c.activeReadCancel = cancel
	cancelImmediately := c.stopRequested.Load()
	c.cancelMu.Unlock()
	if cancelImmediately {
		cancel()
	}
	return token
}

func (c *Core) clearReadCancel(token uint64) {
	c.cancelMu.Lock()
	if c.activeReadCancelToken == token {
		c.activeReadCancel = nil
	}
	c.cancelMu.Unlock()
}
