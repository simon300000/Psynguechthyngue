// SPDX-License-Identifier: MIT

//go:build !darwin && !ios && !linux

package mobilebridge

import "errors"

var errAtomicExchangeUnsupported = errors.New("atomic path exchange is unsupported on this platform")

func renameNoReplaceAt(_, _ *mutationPathRef) error {
	return errAtomicExchangeUnsupported
}

func exchangePathsAt(_, _ *mutationPathRef) error {
	return errAtomicExchangeUnsupported
}
