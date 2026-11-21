// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewCoreCreationReturnsStableFailureCodes(t *testing.T) {
	invalidDirectory := NewCoreCreation("", nil)
	if invalidDirectory.CreatedCore() != nil || invalidDirectory.FailureCode() != coreCreationFailureInvalidDirectory {
		t.Fatalf("invalid directory creation = core %v code %q", invalidDirectory.CreatedCore(), invalidDirectory.FailureCode())
	}

	invalidIdentity := NewCoreCreation(t.TempDir(), []byte("not-an-identity"))
	if invalidIdentity.CreatedCore() != nil || invalidIdentity.FailureCode() != coreCreationFailureIdentity {
		t.Fatalf("invalid identity creation = core %v code %q", invalidIdentity.CreatedCore(), invalidIdentity.FailureCode())
	}

	created := NewCoreCreation(t.TempDir(), nil)
	if created.CreatedCore() == nil || created.FailureCode() != "" {
		t.Fatalf("successful creation = core %v code %q", created.CreatedCore(), created.FailureCode())
	}
	second := NewCoreCreation(t.TempDir(), nil)
	if second.CreatedCore() != nil || second.FailureCode() != coreCreationFailureInUse {
		t.Fatalf("concurrent creation = core %v code %q", second.CreatedCore(), second.FailureCode())
	}
	if err := created.CreatedCore().Close(); err != nil {
		t.Fatalf("close created core: %v", err)
	}

	corruptHome := t.TempDir()
	registryDirectory := filepath.Join(corruptHome, "Bridge")
	if err := os.MkdirAll(registryDirectory, 0o700); err != nil {
		t.Fatalf("create registry directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(registryDirectory, "item-identifiers-v1.json"), []byte("{"), 0o600); err != nil {
		t.Fatalf("write corrupt registry: %v", err)
	}
	corruptState := NewCoreCreation(corruptHome, nil)
	if corruptState.CreatedCore() != nil || corruptState.FailureCode() != coreCreationFailureStateUnavailable {
		t.Fatalf("corrupt state creation = core %v code %q", corruptState.CreatedCore(), corruptState.FailureCode())
	}
}
