// SPDX-License-Identifier: MIT
//go:build darwin || linux

// preparelock runs one command from a directory-bound working directory while
// holding an inherited kernel lock.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	inheritedLockEnvironment   = "PSY_SYNCTHING_PREPARE_LOCK_FD=3"
	inheritedParentEnvironment = "PSY_SYNCTHING_PREPARE_PARENT_FD=4"
	verifierEnvironmentPrefix  = "PSY_SYNCTHING_PREPARE_LOCK_VERIFIER="
	defaultLockTimeout         = 60 * time.Second
	lockRetryInterval          = 20 * time.Millisecond
	lockTimeoutExitCode        = 75
)

type lockTimeoutError struct {
	timeout time.Duration
}

func (e *lockTimeoutError) Error() string {
	return fmt.Sprintf("timed out after %s waiting for preparation lock", e.timeout)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		var timeoutErr *lockTimeoutError
		if errors.As(err, &timeoutErr) {
			fmt.Fprintf(os.Stderr, "preparelock: %v\n", err)
			os.Exit(lockTimeoutExitCode)
		}
		fmt.Fprintf(os.Stderr, "preparelock: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) > 0 && args[0] == "--verify-inherited" {
		if len(args) != 2 {
			return errors.New("usage: preparelock --verify-inherited LOCKFILE")
		}
		return verifyInheritedLock(args[1], 3, 4)
	}

	timeout := defaultLockTimeout
	if len(args) > 0 && strings.HasPrefix(args[0], "--timeout=") {
		var err error
		timeout, err = time.ParseDuration(strings.TrimPrefix(args[0], "--timeout="))
		if err != nil || timeout <= 0 {
			return errors.New("lock timeout must be a positive duration")
		}
		args = args[1:]
	}
	if len(args) < 3 {
		return errors.New("usage: preparelock [--timeout=DURATION] PARENT LOCKFILE COMMAND [ARG...]")
	}

	parent, err := openBoundParent(args[0])
	if err != nil {
		return err
	}
	defer parent.Close()
	if err := syscall.Fchdir(int(parent.Fd())); err != nil {
		return fmt.Errorf("bind working directory to preparation parent: %w", err)
	}
	deadline := time.Now().Add(timeout)
	if err := lockUntil(parent, deadline, timeout, "preparation parent"); err != nil {
		return err
	}

	lockFile, err := openLockFile(args[1])
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := lockUntil(lockFile, deadline, timeout, "preparation file"); err != nil {
		return err
	}
	if err := verifyLockIdentity(args[1], lockFile); err != nil {
		return err
	}
	if err := runTestCheckpoint(); err != nil {
		return err
	}

	cmd := exec.Command(args[2], args[3:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = []*os.File{lockFile, parent}
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve preparation lock verifier: %w", err)
	}
	cmd.Env = append(filteredEnvironment(os.Environ()), inheritedLockEnvironment, inheritedParentEnvironment, verifierEnvironmentPrefix+executable)
	return cmd.Run()
}

// openBoundParent starts from the helper's inherited working directory, which
// is the trusted repository directory. It traverses one component at a time by
// fchdir plus O_NOFOLLOW directory opens. The process cwd therefore remains
// bound to the opened inode even if any pathname is concurrently renamed.
func openBoundParent(path string) (*os.File, error) {
	clean := filepath.Clean(path)
	if clean == "." || filepath.IsAbs(clean) || clean != path {
		return nil, errors.New("preparation parent must be a clean relative path")
	}
	components := strings.Split(clean, string(os.PathSeparator))
	for _, component := range components {
		if component == "" || component == "." || component == ".." {
			return nil, errors.New("preparation parent contains an unsafe component")
		}
	}

	fd, err := syscall.Open(".", syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open trusted repository directory: %w", err)
	}
	current := os.NewFile(uintptr(fd), ".")
	if current == nil {
		syscall.Close(fd)
		return nil, errors.New("wrap trusted repository directory descriptor")
	}

	for _, component := range components {
		if err := syscall.Fchdir(int(current.Fd())); err != nil {
			current.Close()
			return nil, fmt.Errorf("bind preparation ancestor %s: %w", component, err)
		}
		nextFD, err := syscall.Open(component, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
		if errors.Is(err, syscall.ENOENT) {
			if mkdirErr := syscall.Mkdir(component, 0o755); mkdirErr != nil && !errors.Is(mkdirErr, syscall.EEXIST) {
				current.Close()
				return nil, fmt.Errorf("create preparation ancestor %s: %w", component, mkdirErr)
			}
			nextFD, err = syscall.Open(component, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
		}
		if err != nil {
			current.Close()
			return nil, fmt.Errorf("open preparation ancestor %s without following links: %w", component, err)
		}
		next := os.NewFile(uintptr(nextFD), component)
		if next == nil {
			syscall.Close(nextFD)
			current.Close()
			return nil, fmt.Errorf("wrap preparation ancestor %s descriptor", component)
		}
		if err := verifyDirectoryDescriptor(next); err != nil {
			next.Close()
			current.Close()
			return nil, fmt.Errorf("unsafe preparation ancestor %s: %w", component, err)
		}
		current.Close()
		current = next
	}
	return current, nil
}

func verifyDirectoryDescriptor(directory *os.File) error {
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(directory.Fd()), &stat); err != nil {
		return err
	}
	if stat.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		return errors.New("descriptor is not a directory")
	}
	if int(stat.Uid) != os.Geteuid() {
		return errors.New("directory is not owned by the effective user")
	}
	if stat.Mode&0o022 != 0 {
		return errors.New("directory is writable by group or others")
	}
	return nil
}

func openLockFile(name string) (*os.File, error) {
	if err := validateLockLeaf(name); err != nil {
		return nil, err
	}
	fd, err := syscall.Open(name, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock file without following links: %w", err)
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		syscall.Close(fd)
		return nil, errors.New("wrap lock file descriptor")
	}
	if err := verifyLockIdentity(name, file); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func validateLockLeaf(name string) error {
	if name == "" || name == "." || name == ".." || filepath.IsAbs(name) || filepath.Base(name) != name {
		return errors.New("lock file must be one safe relative path component")
	}
	return nil
}

func lockUntil(file *os.File, deadline time.Time, timeout time.Duration, description string) error {
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if !wouldBlock(err) {
			return fmt.Errorf("lock %s: %w", description, err)
		}
		if !time.Now().Before(deadline) {
			return &lockTimeoutError{timeout: timeout}
		}
		remaining := time.Until(deadline)
		pause := lockRetryInterval
		if remaining < pause {
			pause = remaining
		}
		if pause > 0 {
			time.Sleep(pause)
		}
	}
}

func verifyInheritedLock(name string, lockFD, parentFD int) error {
	if err := validateLockLeaf(name); err != nil {
		return err
	}
	parent := os.NewFile(uintptr(parentFD), ".")
	if parent == nil {
		return errors.New("inherited preparation parent descriptor is unavailable")
	}
	if err := verifyDirectoryDescriptor(parent); err != nil {
		return fmt.Errorf("unsafe inherited preparation parent descriptor: %w", err)
	}
	parentProbe, err := os.Open(".")
	if err != nil {
		return fmt.Errorf("open preparation parent identity probe: %w", err)
	}
	defer parentProbe.Close()
	if err := verifyFileIdentityPair(parent, parentProbe, "inherited preparation parent descriptor and cwd identity differ"); err != nil {
		return err
	}
	if err := verifyInheritedOwner(parentProbe, parentFD, "preparation parent"); err != nil {
		return err
	}

	inherited := os.NewFile(uintptr(lockFD), name)
	if inherited == nil {
		return errors.New("inherited lock descriptor is unavailable")
	}
	if err := verifyLockDescriptor(inherited); err != nil {
		return fmt.Errorf("unsafe inherited lock descriptor: %w", err)
	}

	probeFD, err := syscall.Open(name, syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return fmt.Errorf("open inherited lock identity probe: %w", err)
	}
	probe := os.NewFile(uintptr(probeFD), name)
	if probe == nil {
		syscall.Close(probeFD)
		return errors.New("wrap inherited lock identity probe")
	}
	defer probe.Close()
	if err := verifyFileIdentityPair(inherited, probe, "inherited lock descriptor and lock path identity differ"); err != nil {
		return err
	}
	if err := verifyInheritedOwner(probe, lockFD, "preparation file"); err != nil {
		return err
	}
	return verifyLockIdentity(name, inherited)
}

func verifyInheritedOwner(probe *os.File, inheritedFD int, description string) error {
	// Probe first. If this succeeds, the inherited descriptor was not already
	// part of the locked open-file description, so unlock the probe and reject.
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		_ = syscall.Flock(int(probe.Fd()), syscall.LOCK_UN)
		return fmt.Errorf("inherited descriptor did not already hold the %s lock", description)
	} else if !wouldBlock(err) {
		return fmt.Errorf("probe inherited %s lock: %w", description, err)
	}
	if err := syscall.Flock(inheritedFD, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("inherited descriptor is not the %s lock owner: %w", description, err)
	}
	return nil
}

func verifyLockIdentity(name string, file *os.File) error {
	if err := verifyLockDescriptor(file); err != nil {
		return err
	}
	pathInfo, err := os.Lstat(name)
	if err != nil {
		return fmt.Errorf("lstat lock path: %w", err)
	}
	if !pathInfo.Mode().IsRegular() {
		return errors.New("lock path is not a regular file")
	}
	pathStat, ok := pathInfo.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("lock path has unexpected stat data")
	}
	var descriptor syscall.Stat_t
	if err := syscall.Fstat(int(file.Fd()), &descriptor); err != nil {
		return fmt.Errorf("stat lock descriptor: %w", err)
	}
	if !sameFile(&descriptor, pathStat) {
		return errors.New("lock descriptor and path identity differ")
	}
	return nil
}

func verifyFileIdentityPair(first, second *os.File, mismatch string) error {
	var firstStat, secondStat syscall.Stat_t
	if err := syscall.Fstat(int(first.Fd()), &firstStat); err != nil {
		return fmt.Errorf("stat inherited lock descriptor: %w", err)
	}
	if err := syscall.Fstat(int(second.Fd()), &secondStat); err != nil {
		return fmt.Errorf("stat lock identity probe: %w", err)
	}
	if !sameFile(&firstStat, &secondStat) {
		return errors.New(mismatch)
	}
	return nil
}

func verifyLockDescriptor(file *os.File) error {
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(file.Fd()), &stat); err != nil {
		return fmt.Errorf("stat lock descriptor: %w", err)
	}
	if stat.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return errors.New("lock descriptor is not a regular file")
	}
	if int(stat.Uid) != os.Geteuid() {
		return errors.New("lock file is not owned by the effective user")
	}
	if stat.Mode&0o7777 != 0o600 {
		return errors.New("lock file permissions are not 0600")
	}
	if uint64(stat.Nlink) != 1 {
		return errors.New("lock file must have exactly one link")
	}
	return nil
}

func sameFile(first, second *syscall.Stat_t) bool {
	return uint64(first.Dev) == uint64(second.Dev) && uint64(first.Ino) == uint64(second.Ino)
}

func wouldBlock(err error) bool {
	return errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN)
}

func filteredEnvironment(environment []string) []string {
	filtered := environment[:0]
	for _, entry := range environment {
		if strings.HasPrefix(entry, "PSY_SYNCTHING_PREPARE_LOCK_FD=") || strings.HasPrefix(entry, "PSY_SYNCTHING_PREPARE_PARENT_FD=") || strings.HasPrefix(entry, verifierEnvironmentPrefix) || strings.HasPrefix(entry, "PSY_PREPARELOCK_TEST_") {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}
