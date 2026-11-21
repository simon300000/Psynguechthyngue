// SPDX-License-Identifier: MIT

//go:build !darwin && !ios && !linux

package mobilebridge

// Unsupported desktop targets retain the existing atomic writer. Production
// Apple targets and Linux verification use the dirfd-anchored implementation.
func writePendingFolderObservationProofFile(path string, data []byte) error {
	return writeCommandLedgerFile(path, data)
}
