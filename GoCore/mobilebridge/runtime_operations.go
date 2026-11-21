// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"context"
	"errors"
)

// scanFolderSubdirsLocked is the single cancellation-aware path from bridge
// commands into Syncthing's synchronous scan API. RequestCancel stops the real
// runtime, which closes folder runners; the post-call cancellation check also
// covers a scan that happened to finish concurrently with that stop request.
func (c *Core) scanFolderSubdirsLocked(folderID string, paths []string) error {
	if c.stopRequested.Load() {
		return context.Canceled
	}
	if c.scanFolderSubdirsForTests != nil {
		err := c.scanFolderSubdirsForTests(folderID, paths)
		if c.stopRequested.Load() {
			return context.Canceled
		}
		return err
	}
	if c.runtime == nil || c.runtime.app == nil || c.runtime.app.Internals == nil {
		return errors.New("Syncthing runtime is unavailable")
	}
	err := c.runtime.app.Internals.ScanFolderSubdirs(folderID, paths)
	if c.stopRequested.Load() {
		return context.Canceled
	}
	return err
}

type bridgeConfigurationWaiter interface {
	Wait()
}

// waitForConfigurationLocked keeps a stopped configuration subscriber from
// pinning CommandJSON behind c.mu. The upstream waiter has no context-aware
// method, so it is joined on a helper goroutine while the bridge operation's
// cancellation signal remains independently selectable.
func (c *Core) waitForConfigurationLocked(waiter bridgeConfigurationWaiter) error {
	if waiter == nil {
		return errors.New("configuration waiter is unavailable")
	}
	done := make(chan error, 1)
	go func() {
		var result error
		defer func() {
			if recover() != nil {
				result = errors.New("configuration waiter panicked")
			}
			done <- result
		}()
		waiter.Wait()
	}()
	cancelled := c.cancellationDone()
	select {
	case err := <-done:
		if err != nil {
			return err
		}
		if c.stopRequested.Load() {
			return context.Canceled
		}
		return nil
	case <-cancelled:
		return context.Canceled
	}
}
