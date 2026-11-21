// SPDX-License-Identifier: MIT

//go:build linux

package mobilebridge

import "golang.org/x/sys/unix"

func renameNoReplaceAt(source, destination *mutationPathRef) error {
	return unix.Renameat2(
		int(source.parent().Fd()),
		source.name,
		int(destination.parent().Fd()),
		destination.name,
		unix.RENAME_NOREPLACE,
	)
}

func exchangePathsAt(source, destination *mutationPathRef) error {
	return unix.Renameat2(
		int(source.parent().Fd()),
		source.name,
		int(destination.parent().Fd()),
		destination.name,
		unix.RENAME_EXCHANGE,
	)
}
