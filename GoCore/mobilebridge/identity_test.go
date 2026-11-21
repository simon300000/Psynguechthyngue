// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"testing"
)

func TestIdentityBlobRoundTripKeepsDeviceID(t *testing.T) {
	first, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	blob := first.IdentityBlob()
	firstID := first.DeviceID()
	if len(blob) == 0 {
		t.Fatal("generated identity blob is empty")
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := NewCore(t.TempDir(), blob)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = second.Close() })
	secondID := second.DeviceID()
	if firstID != secondID {
		t.Fatalf("device ID changed across identity round trip: %q != %q", firstID, secondID)
	}
	roundTrippedBlob := second.IdentityBlob()
	if !bytes.Equal(blob, roundTrippedBlob) {
		t.Fatal("identity blob changed during round trip")
	}
}

func TestIdentityBlobRejectsCorruption(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	blob := core.IdentityBlob()
	if err := core.Close(); err != nil {
		t.Fatal(err)
	}

	blob[len(blob)/2] ^= 0xff
	if _, err := NewCore(t.TempDir(), blob); err == nil {
		t.Fatal("corrupted identity blob was accepted")
	}
}
