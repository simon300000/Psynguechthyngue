// SPDX-License-Identifier: MIT

//go:build !darwin && !ios && !linux

package mobilebridge

import (
	"errors"
	"os"
)

func openCommandLedgerNoFollow(path string) (*os.File, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("command ledger is not a regular non-symlink file")
	}
	handle, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	openedInfo, err := handle.Stat()
	if err != nil || !os.SameFile(info, openedInfo) {
		_ = handle.Close()
		return nil, errors.New("command ledger changed while it was being opened")
	}
	return handle, nil
}
