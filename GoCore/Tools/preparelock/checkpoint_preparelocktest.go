// SPDX-License-Identifier: MIT
//go:build (darwin || linux) && preparelocktest

package main

import (
	"errors"
	"fmt"
	"os"
	"time"
)

func runTestCheckpoint() error {
	acquired := os.Getenv("PSY_PREPARELOCK_TEST_ACQUIRED_FILE")
	release := os.Getenv("PSY_PREPARELOCK_TEST_RELEASE_FILE")
	if acquired != "" {
		if err := os.WriteFile(acquired, nil, 0o600); err != nil {
			return fmt.Errorf("write test lock checkpoint: %w", err)
		}
	}
	for release != "" {
		if _, err := os.Stat(release); err == nil {
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("read test lock release: %w", err)
		}
		time.Sleep(lockRetryInterval)
	}
	return nil
}
