// SPDX-License-Identifier: MIT

package mobilebridge

import "errors"

const (
	coreCreationFailureGeneric          = "core_creation_failed"
	coreCreationFailureIdentity         = "identity_rejected"
	coreCreationFailureInUse            = "core_in_use"
	coreCreationFailureInvalidDirectory = "invalid_core_directories"
	coreCreationFailureStateUnavailable = "core_state_unavailable"
)

type coreCreationError struct {
	code  string
	cause error
}

func (e *coreCreationError) Error() string {
	return e.cause.Error()
}

func (e *coreCreationError) Unwrap() error {
	return e.cause
}

func newCoreCreationError(code string, cause error) error {
	return &coreCreationError{code: code, cause: cause}
}

func coreCreationFailureCode(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, errCoreInUse) {
		return coreCreationFailureInUse
	}
	var creationError *coreCreationError
	if errors.As(err, &creationError) {
		switch creationError.code {
		case coreCreationFailureIdentity,
			coreCreationFailureInvalidDirectory,
			coreCreationFailureStateUnavailable:
			return creationError.code
		}
	}
	return coreCreationFailureGeneric
}

// CoreCreation is the gomobile-safe result of constructing a Core. Exactly
// one of CreatedCore and FailureCode is populated. It avoids NSError and raw
// Go error text at the platform boundary.
type CoreCreation struct {
	core        *Core
	failureCode string
}

// NewCoreCreation constructs a Core and returns only a package-owned Core
// reference or an allowlisted stable failure code.
func NewCoreCreation(home string, identityBlob []byte) *CoreCreation {
	core, err := NewCore(home, identityBlob)
	if err != nil {
		return &CoreCreation{failureCode: coreCreationFailureCode(err)}
	}
	if core == nil {
		return &CoreCreation{failureCode: coreCreationFailureGeneric}
	}
	return &CoreCreation{core: core}
}

// CreatedCore returns the constructed Core, or nil when creation failed.
func (r *CoreCreation) CreatedCore() *Core {
	if r == nil {
		return nil
	}
	return r.core
}

// FailureCode returns an allowlisted stable code, or an empty string on
// success. It never returns a path, identity blob, or native error text.
func (r *CoreCreation) FailureCode() string {
	if r == nil {
		return coreCreationFailureGeneric
	}
	return r.failureCode
}
