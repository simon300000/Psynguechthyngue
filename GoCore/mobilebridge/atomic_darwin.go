// SPDX-License-Identifier: MIT

//go:build darwin || ios

package mobilebridge

import "golang.org/x/sys/unix"

func renameNoReplaceAt(source, destination *mutationPathRef) error {
	return unix.RenameatxNp(
		int(source.parent().Fd()),
		source.name,
		int(destination.parent().Fd()),
		destination.name,
		unix.RENAME_EXCL,
	)
}

func exchangePathsAt(source, destination *mutationPathRef) error {
	return unix.RenameatxNp(
		int(source.parent().Fd()),
		source.name,
		int(destination.parent().Fd()),
		destination.name,
		unix.RENAME_SWAP,
	)
}
