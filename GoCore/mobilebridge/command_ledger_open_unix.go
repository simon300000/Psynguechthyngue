// SPDX-License-Identifier: MIT

//go:build darwin || ios || linux

package mobilebridge

import (
	"os"

	"golang.org/x/sys/unix"
)

func openCommandLedgerNoFollow(path string) (*os.File, error) {
	descriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(descriptor), path), nil
}
