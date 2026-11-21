// SPDX-License-Identifier: MIT

//go:build darwin || ios || linux

package mobilebridge

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestPendingFolderObservationProofWriterIsDirfdAnchoredAndNoFollow(t *testing.T) {
	t.Run("target symlink", func(t *testing.T) {
		home := t.TempDir()
		directory := filepath.Join(home, "Bridge")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		outside := filepath.Join(t.TempDir(), "outside-proof")
		outsideData := []byte("outside must remain unchanged")
		if err := os.WriteFile(outside, outsideData, 0o600); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "pending-folder-observation-proofs-v1.json")
		if err := os.Symlink(outside, path); err != nil {
			t.Fatal(err)
		}
		proofData := []byte(`{"schemaVersion":1,"proofs":[]}`)
		if err := writePendingFolderObservationProofFile(path, proofData); err != nil {
			t.Fatal(err)
		}
		if got, err := os.ReadFile(outside); err != nil || !bytes.Equal(got, outsideData) {
			t.Fatalf("writer followed target symlink: data=%q err=%v", got, err)
		}
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			t.Fatalf("writer did not atomically replace the symlink with a protected file: info=%+v err=%v", info, err)
		}
		if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, proofData) {
			t.Fatalf("writer persisted the wrong proof data: data=%q err=%v", got, err)
		}
	})

	t.Run("directory symlink", func(t *testing.T) {
		home := t.TempDir()
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(home, "Bridge")); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(home, "Bridge", "pending-folder-observation-proofs-v1.json")
		if err := writePendingFolderObservationProofFile(path, []byte(`{"schemaVersion":1,"proofs":[]}`)); err == nil {
			t.Fatal("writer accepted a symlinked proof directory")
		}
		if _, err := os.Lstat(filepath.Join(outside, filepath.Base(path))); !os.IsNotExist(err) {
			t.Fatalf("writer created proof data through a directory symlink: %v", err)
		}
	})
}
