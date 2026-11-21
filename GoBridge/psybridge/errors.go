// SPDX-License-Identifier: MIT

package psybridge

import (
	"errors"
	"fmt"
	"strings"
)

// Stable error codes. Swift maps these to `EngineError` (Sources/PsySync).
// Adding a code is a contract change: update both sides in the same commit.
const (
	CodeNotImplemented  = "not_implemented"
	CodeInvalidArgument = "invalid_argument"
	CodeAlreadyRunning  = "already_running"
	CodeNotRunning      = "not_running"
	CodeIdentity        = "identity"         // certificate/key missing or unreadable
	CodeDatabase        = "database"         // Syncthing DB cannot be opened/migrated
	CodeConfig          = "config"           // config.xml invalid
	CodeListen          = "listen"           // could not bind the loopback API
	CodeStopTimeout     = "stop_timeout"     // Stop exceeded its deadline; process must not reuse the engine
	CodeFileNotFound    = "file_not_found"   // fetch: path not in global index
	CodeVersionMismatch = "version_mismatch" // fetch: index version differs from the requested one
	CodeNoPeer          = "no_peer"          // fetch: no connected device has the needed blocks
	CodeHashMismatch    = "hash_mismatch"    // fetch: peer returned data whose hash differs (stale index)
	CodeTooLarge        = "too_large"        // fetch: file exceeds the restricted-core size budget
	CodeDeadline        = "deadline"         // fetch: deadline reached before completion
	CodeCancelled       = "cancelled"
	CodeIO              = "io"
)

// BridgeError is the only error type returned across the gomobile boundary.
type BridgeError struct {
	Code   string
	Detail string
}

func (e *BridgeError) Error() string {
	if e.Detail == "" {
		return "psy:" + e.Code
	}
	return "psy:" + e.Code + ": " + e.Detail
}

func newError(code, format string, args ...any) error {
	return &BridgeError{Code: code, Detail: fmt.Sprintf(format, args...)}
}

func notImplemented(what string) error {
	return newError(CodeNotImplemented, "%s", what)
}

// ErrorCode extracts the stable code from an error string produced by this
// package. Exported so tests on both sides can share one parser shape.
func ErrorCode(message string) string {
	if !strings.HasPrefix(message, "psy:") {
		return ""
	}
	rest := strings.TrimPrefix(message, "psy:")
	if i := strings.Index(rest, ":"); i >= 0 {
		return rest[:i]
	}
	return rest
}

func codeOf(err error) string {
	var be *BridgeError
	if errors.As(err, &be) {
		return be.Code
	}
	return ""
}
