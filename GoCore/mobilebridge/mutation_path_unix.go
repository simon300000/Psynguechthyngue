// SPDX-License-Identifier: MIT

//go:build darwin || ios || linux

package mobilebridge

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

func openMutationDirectoryPath(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	return openMutationFileDescriptor(fd, err, path)
}

func openMutationDirectoryAt(parent *os.File, name string) (*os.File, error) {
	fd, err := unix.Openat(int(parent.Fd()), name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	return openMutationFileDescriptor(fd, err, name)
}

func openMutationObjectAt(parent *os.File, name string) (*os.File, error) {
	fd, err := unix.Openat(int(parent.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	return openMutationFileDescriptor(fd, err, name)
}

func openMutationFileDescriptor(fd int, err error, name string) (*os.File, error) {
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("could not wrap mutation file descriptor")
	}
	return file, nil
}

func createMutationTemporaryAt(parent *os.File) (string, *os.File, error) {
	for attempt := 0; attempt < 128; attempt++ {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return "", nil, err
		}
		name := ".syncthing.bridge-write-" + hex.EncodeToString(random[:]) + ".tmp"
		fd, openErr := unix.Openat(int(parent.Fd()), name, unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
		file, err := openMutationFileDescriptor(fd, openErr, name)
		if errors.Is(err, unix.EEXIST) {
			continue
		}
		return name, file, err
	}
	return "", nil, errors.New("could not allocate a unique mutation temporary file")
}

func createMutationNamedFileAt(parent *os.File, name string, mode uint32) (*os.File, error) {
	fd, err := unix.Openat(
		int(parent.Fd()),
		name,
		unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		mode,
	)
	return openMutationFileDescriptor(fd, err, name)
}

func mutationDirectoriesShareDevice(left, right *os.File) (bool, error) {
	var leftStatus unix.Stat_t
	if err := unix.Fstat(int(left.Fd()), &leftStatus); err != nil {
		return false, err
	}
	var rightStatus unix.Stat_t
	if err := unix.Fstat(int(right.Fd()), &rightStatus); err != nil {
		return false, err
	}
	return leftStatus.Dev == rightStatus.Dev, nil
}

func mutationDirectoryIdentity(handle *os.File) (string, error) {
	var status unix.Stat_t
	if err := unix.Fstat(int(handle.Fd()), &status); err != nil {
		return "", err
	}
	var value [16]byte
	binary.BigEndian.PutUint64(value[:8], uint64(status.Dev))
	binary.BigEndian.PutUint64(value[8:], uint64(status.Ino))
	digest := sha256.Sum256(value[:])
	return hex.EncodeToString(digest[:]), nil
}

func readMutationLinkAt(parent *os.File, name string) (string, error) {
	buffer := make([]byte, 256)
	for len(buffer) <= maxRelativePathBytes*4 {
		count, err := unix.Readlinkat(int(parent.Fd()), name, buffer)
		if err != nil {
			return "", err
		}
		if count < len(buffer) {
			return string(buffer[:count]), nil
		}
		buffer = make([]byte, len(buffer)*2)
	}
	return "", errors.New("symlink target is too long")
}

func mkdirMutationAt(path *mutationPathRef, mode uint32) error {
	return unix.Mkdirat(int(path.parent().Fd()), path.name, mode)
}

func mkdirMutationNameAt(parent *os.File, name string, mode uint32) error {
	return unix.Mkdirat(int(parent.Fd()), name, mode)
}

func unlinkMutationAt(path *mutationPathRef, directory bool) error {
	flags := 0
	if directory {
		flags = unix.AT_REMOVEDIR
	}
	return unix.Unlinkat(int(path.parent().Fd()), path.name, flags)
}
