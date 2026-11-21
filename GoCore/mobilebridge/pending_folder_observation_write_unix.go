// SPDX-License-Identifier: MIT

//go:build darwin || ios || linux

package mobilebridge

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// writePendingFolderObservationProofFile keeps every create, replace, cleanup,
// and directory sync operation anchored to one O_NOFOLLOW directory handle.
// This prevents a path swap from redirecting proof data outside the app-owned
// 0700 Bridge directory on supported Unix targets.
func writePendingFolderObservationProofFile(path string, data []byte) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create pending folder observation proof directory: %w", err)
	}
	before, err := os.Lstat(directory)
	if err != nil || !before.IsDir() || before.Mode()&os.ModeSymlink != 0 || before.Mode().Perm() != 0o700 {
		return errors.New("pending folder observation proof directory must be a real 0700 directory")
	}

	directoryDescriptor, err := unix.Open(directory, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("open pending folder observation proof directory: %w", err)
	}
	directoryHandle := os.NewFile(uintptr(directoryDescriptor), directory)
	if directoryHandle == nil {
		_ = unix.Close(directoryDescriptor)
		return errors.New("open pending folder observation proof directory")
	}
	defer directoryHandle.Close()
	opened, err := directoryHandle.Stat()
	if err != nil || !opened.IsDir() || opened.Mode().Perm() != 0o700 || !os.SameFile(before, opened) {
		return errors.New("pending folder observation proof directory changed while it was being opened")
	}

	temporaryName, temporaryDescriptor, err := createPendingFolderObservationTemporaryAt(directoryDescriptor)
	if err != nil {
		return err
	}
	temporaryHandle := os.NewFile(uintptr(temporaryDescriptor), temporaryName)
	if temporaryHandle == nil {
		_ = unix.Close(temporaryDescriptor)
		_ = unix.Unlinkat(directoryDescriptor, temporaryName, 0)
		return errors.New("open pending folder observation proof temporary file")
	}
	temporaryOpen := true
	defer func() {
		if temporaryOpen {
			_ = temporaryHandle.Close()
		}
		_ = unix.Unlinkat(directoryDescriptor, temporaryName, 0)
	}()
	if err := temporaryHandle.Chmod(0o600); err != nil {
		return fmt.Errorf("protect pending folder observation proof temporary file: %w", err)
	}
	if err := writeAll(temporaryHandle, data); err != nil {
		return fmt.Errorf("write pending folder observation proof temporary file: %w", err)
	}
	if err := temporaryHandle.Sync(); err != nil {
		return fmt.Errorf("sync pending folder observation proof temporary file: %w", err)
	}
	if err := temporaryHandle.Close(); err != nil {
		return fmt.Errorf("close pending folder observation proof temporary file: %w", err)
	}
	temporaryOpen = false

	base := filepath.Base(path)
	if base == "." || base == string(filepath.Separator) || filepath.Dir(base) != "." {
		return errors.New("pending folder observation proof path is not a direct directory child")
	}
	if err := unix.Renameat(directoryDescriptor, temporaryName, directoryDescriptor, base); err != nil {
		return fmt.Errorf("replace pending folder observation proof store: %w", err)
	}
	if err := unix.Fsync(directoryDescriptor); err != nil {
		return fmt.Errorf("sync pending folder observation proof directory: %w", err)
	}
	after, err := os.Lstat(directory)
	if err != nil || !after.IsDir() || after.Mode().Perm() != 0o700 || !os.SameFile(opened, after) {
		return errors.New("pending folder observation proof directory changed during replacement")
	}
	return nil
}

func createPendingFolderObservationTemporaryAt(directoryDescriptor int) (string, int, error) {
	var randomBytes [16]byte
	for attempt := 0; attempt < 16; attempt++ {
		if _, err := rand.Read(randomBytes[:]); err != nil {
			return "", -1, fmt.Errorf("generate pending folder observation proof temporary name: %w", err)
		}
		name := ".pending-folder-observation-" + hex.EncodeToString(randomBytes[:])
		descriptor, err := unix.Openat(directoryDescriptor, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
		if err == nil {
			return name, descriptor, nil
		}
		if !errors.Is(err, unix.EEXIST) {
			return "", -1, fmt.Errorf("create pending folder observation proof temporary file: %w", err)
		}
	}
	return "", -1, errors.New("create unique pending folder observation proof temporary file")
}
