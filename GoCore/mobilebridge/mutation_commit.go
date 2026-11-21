// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"hash"
	"io"
	"os"
	"sort"
)

var (
	errMutationObjectChanged         = errors.New("mutation object changed")
	errMutationObjectTypeUnsupported = errors.New("mutation object type is unsupported")
)

type mutationObjectState struct {
	info   os.FileInfo
	mode   os.FileMode
	digest [sha256.Size]byte
	bytes  int64
}

func writeMutationDigestField(destination hash.Hash, value []byte) error {
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(value)))
	if _, err := destination.Write(length[:]); err != nil {
		return err
	}
	_, err := destination.Write(value)
	return err
}

func sameMutationFileMetadata(left, right os.FileInfo) bool {
	return left != nil && right != nil && os.SameFile(left, right) && left.Mode() == right.Mode() && left.Size() == right.Size() && left.ModTime().Equal(right.ModTime())
}

func sameMutationObjectState(left, right mutationObjectState) bool {
	return sameMutationFileMetadata(left.info, right.info) && left.mode == right.mode && left.digest == right.digest && left.bytes == right.bytes
}

func captureMutationObjectAt(path *mutationPathRef) (mutationObjectState, error) {
	first, err := observeMutationObjectAt(path)
	if err != nil {
		return mutationObjectState{}, err
	}
	second, err := observeMutationObjectAt(path)
	if err != nil {
		return mutationObjectState{}, err
	}
	if !sameMutationObjectState(first, second) {
		return mutationObjectState{}, errMutationObjectChanged
	}
	return second, nil
}

func observeMutationObjectAt(path *mutationPathRef) (mutationObjectState, error) {
	if err := path.revalidate(); err != nil {
		return mutationObjectState{}, err
	}
	handle, err := openMutationObjectAt(path.parent(), path.name)
	if err != nil {
		return mutationObjectState{}, err
	}
	defer handle.Close()
	info, err := handle.Stat()
	if err != nil {
		return mutationObjectState{}, err
	}

	var digest [sha256.Size]byte
	var byteCount int64
	switch {
	case info.Mode().IsRegular():
		digest, err = digestMutationRegularHandle(handle, info)
		byteCount = info.Size()
	case info.IsDir():
		digest, byteCount, err = digestMutationDirectoryHandle(handle, info)
	default:
		err = errMutationObjectTypeUnsupported
	}
	if err != nil {
		return mutationObjectState{}, err
	}
	finalInfo, err := handle.Stat()
	if err != nil || !sameMutationFileMetadata(info, finalInfo) {
		return mutationObjectState{}, errMutationObjectChanged
	}
	current, err := openMutationObjectAt(path.parent(), path.name)
	if err != nil {
		return mutationObjectState{}, errMutationObjectChanged
	}
	currentInfo, statErr := current.Stat()
	_ = current.Close()
	if statErr != nil || !sameMutationFileMetadata(finalInfo, currentInfo) || path.revalidate() != nil {
		return mutationObjectState{}, errMutationObjectChanged
	}
	return mutationObjectState{info: finalInfo, mode: finalInfo.Mode(), digest: digest, bytes: byteCount}, nil
}

func digestMutationRegularHandle(handle *os.File, expected os.FileInfo) ([sha256.Size]byte, error) {
	if _, err := handle.Seek(0, io.SeekStart); err != nil {
		return [sha256.Size]byte{}, err
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, handle); err != nil {
		return [sha256.Size]byte{}, err
	}
	after, err := handle.Stat()
	if err != nil || !sameMutationFileMetadata(expected, after) {
		return [sha256.Size]byte{}, errMutationObjectChanged
	}
	var result [sha256.Size]byte
	copy(result[:], digest.Sum(nil))
	return result, nil
}

func digestMutationDirectoryHandle(directory *os.File, expected os.FileInfo) ([sha256.Size]byte, int64, error) {
	digest := sha256.New()
	if err := writeMutationDigestField(digest, []byte("directory-dirfd-v1")); err != nil {
		return [sha256.Size]byte{}, 0, err
	}
	byteCount, err := digestMutationDirectoryEntries(digest, directory, "")
	if err != nil {
		return [sha256.Size]byte{}, 0, err
	}
	after, err := directory.Stat()
	if err != nil || !sameMutationFileMetadata(expected, after) {
		return [sha256.Size]byte{}, 0, errMutationObjectChanged
	}
	var result [sha256.Size]byte
	copy(result[:], digest.Sum(nil))
	return result, byteCount, nil
}

func digestMutationDirectoryEntries(digest hash.Hash, directory *os.File, relativeParent string) (int64, error) {
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return 0, err
	}
	var byteCount int64
	sort.Slice(entries, func(left, right int) bool { return entries[left].Name() < entries[right].Name() })
	for _, entry := range entries {
		name := entry.Name()
		relative := name
		if relativeParent != "" {
			relative = relativeParent + "/" + name
		}
		if err := writeMutationDigestField(digest, []byte(relative)); err != nil {
			return 0, err
		}

		child, openErr := openMutationObjectAt(directory, name)
		if openErr != nil {
			target, linkErr := readMutationLinkAt(directory, name)
			if linkErr != nil {
				return 0, openErr
			}
			secondTarget, linkErr := readMutationLinkAt(directory, name)
			if linkErr != nil || secondTarget != target {
				return 0, errMutationObjectChanged
			}
			if err := writeMutationDigestField(digest, []byte{'l'}); err != nil {
				return 0, err
			}
			if err := writeMutationDigestField(digest, []byte(target)); err != nil {
				return 0, err
			}
			byteCount += int64(len(target))
			continue
		}
		childInfo, statErr := child.Stat()
		if statErr != nil {
			_ = child.Close()
			return 0, statErr
		}
		var kind byte
		switch {
		case childInfo.IsDir():
			kind = 'd'
		case childInfo.Mode().IsRegular():
			kind = 'f'
		default:
			_ = child.Close()
			return 0, errMutationObjectTypeUnsupported
		}
		if err := writeMutationDigestField(digest, []byte{kind}); err != nil {
			_ = child.Close()
			return 0, err
		}
		var numeric [8]byte
		binary.BigEndian.PutUint64(numeric[:], uint64(childInfo.Mode()))
		if err := writeMutationDigestField(digest, numeric[:]); err != nil {
			_ = child.Close()
			return 0, err
		}
		switch kind {
		case 'f':
			fileDigest, err := digestMutationRegularHandle(child, childInfo)
			if err != nil {
				_ = child.Close()
				return 0, err
			}
			binary.BigEndian.PutUint64(numeric[:], uint64(childInfo.Size()))
			if err := writeMutationDigestField(digest, numeric[:]); err != nil {
				_ = child.Close()
				return 0, err
			}
			if err := writeMutationDigestField(digest, fileDigest[:]); err != nil {
				_ = child.Close()
				return 0, err
			}
			byteCount += childInfo.Size()
		case 'd':
			childBytes, err := digestMutationDirectoryEntries(digest, child, relative)
			if err != nil {
				_ = child.Close()
				return 0, err
			}
			byteCount += childBytes
		}
		finalInfo, statErr := child.Stat()
		_ = child.Close()
		if statErr != nil || !sameMutationFileMetadata(childInfo, finalInfo) {
			return 0, errMutationObjectChanged
		}
		current, err := openMutationObjectAt(directory, name)
		if err != nil {
			return 0, errMutationObjectChanged
		}
		currentInfo, statErr := current.Stat()
		_ = current.Close()
		if statErr != nil || !sameMutationFileMetadata(finalInfo, currentInfo) {
			return 0, errMutationObjectChanged
		}
	}
	return byteCount, nil
}

func mutationObjectMatchesAt(path *mutationPathRef, expected mutationObjectState) bool {
	current, err := captureMutationObjectAt(path)
	return err == nil && sameMutationObjectState(current, expected)
}

func mutationPathMissingAt(path *mutationPathRef) bool {
	if path.revalidate() != nil {
		return false
	}
	handle, err := openMutationObjectAt(path.parent(), path.name)
	if err == nil {
		_ = handle.Close()
		return false
	}
	if _, linkErr := readMutationLinkAt(path.parent(), path.name); linkErr == nil {
		return false
	}
	return errors.Is(err, os.ErrNotExist)
}

func mutationVersionConflict(message string) *responseError {
	return mutationFailure("version_conflict", message, mutationPhasePrecommit, false)
}

func mutationCommitAmbiguous(message string) *responseError {
	return mutationFailure("mutation_inconsistent", message, mutationPhaseIndeterminate, true)
}

func prepareMutationIncoming(staged string, destination *mutationPathRef) (temporaryPath *mutationPathRef, incoming mutationObjectState, err error) {
	source, err := os.Open(staged)
	if err != nil {
		return nil, mutationObjectState{}, err
	}
	defer source.Close()
	openedInfo, err := source.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() {
		return nil, mutationObjectState{}, errors.New("opened staged content is not a regular file")
	}
	lstatInfo, err := os.Lstat(staged)
	if err != nil || lstatInfo.Mode()&os.ModeSymlink != 0 || !sameMutationFileMetadata(openedInfo, lstatInfo) {
		return nil, mutationObjectState{}, errors.New("staged content changed during validation")
	}

	temporaryName, temporary, err := createMutationTemporaryAt(destination.parent())
	if err != nil {
		return nil, mutationObjectState{}, err
	}
	temporaryPath = destination.withName(temporaryName)
	keep := false
	closed := false
	defer func() {
		if !closed {
			if closeErr := temporary.Close(); err == nil && closeErr != nil {
				err = closeErr
			}
		}
		if err != nil && !keep {
			_ = unlinkMutationAt(temporaryPath, false)
		}
	}()
	if _, err = io.Copy(temporary, source); err != nil {
		return nil, mutationObjectState{}, err
	}
	if err = temporary.Sync(); err != nil {
		return nil, mutationObjectState{}, err
	}
	afterSource, statErr := source.Stat()
	afterPath, lstatErr := os.Lstat(staged)
	if statErr != nil || lstatErr != nil || !sameMutationFileMetadata(openedInfo, afterSource) || !sameMutationFileMetadata(afterSource, afterPath) {
		return nil, mutationObjectState{}, errors.New("staged content changed during copy")
	}
	if err = temporary.Close(); err != nil {
		return nil, mutationObjectState{}, err
	}
	closed = true
	incoming, err = captureMutationObjectAt(temporaryPath)
	if err != nil {
		return nil, mutationObjectState{}, err
	}
	keep = true
	return temporaryPath, incoming, nil
}

func replaceMutationFileCAS(
	staged string,
	destination *mutationPathRef,
	baseline mutationObjectState,
	recovery *mutationRecoveryPlan,
	beforeCommit func(command, path string) error,
	afterExchange func(command, installedPath, preservedPath string) error,
	beforeRollback func(command, installedPath, preservedPath string) error,
	beforeFinalRetention func(command, preservedPath string) error,
	afterRecoveryMove func(recoveryPath string) error,
) *responseError {
	temporary, incoming, err := prepareMutationIncoming(staged, destination)
	if err != nil {
		return commandError("modify_failed", err.Error())
	}
	keepTemporary := false
	defer func() {
		if !keepTemporary {
			_ = unlinkMutationAt(temporary, false)
		}
	}()

	// This is intentionally the last instruction before the atomic exchange.
	// Tests use it to replace the destination after the baseline capture and
	// prove that the exchange validates the object it actually displaced.
	if beforeCommit != nil {
		if err := beforeCommit("modify", destination.absolutePath); err != nil {
			return commandError("internal_error", err.Error())
		}
	}
	if err := revalidateMutationPaths(temporary, destination); err != nil {
		return mutationVersionConflict("the destination ancestor binding changed before replacement")
	}
	if err := exchangePathsAt(temporary, destination); err != nil {
		return commandError("modify_failed", err.Error())
	}
	keepTemporary = true
	if afterExchange != nil {
		if err := afterExchange("modify", destination.absolutePath, temporary.absolutePath); err != nil {
			return mutationCommitAmbiguous("the replacement exchange could not be verified; both versions were retained")
		}
	}
	if err := syncMutationDirectories(temporary, destination); err != nil {
		return mutationCommitAmbiguous("the replacement was exchanged but its directory could not be synchronized; both versions were retained")
	}

	installedOK := mutationObjectMatchesAt(destination, incoming)
	preserved, preservedErr := captureMutationObjectAt(temporary)
	preservedIsBaseline := preservedErr == nil && sameMutationObjectState(preserved, baseline)
	if !installedOK || !preservedIsBaseline {
		if !installedOK || preservedErr != nil {
			if recovery != nil {
				_ = recovery.retain(temporary, baseline, mutationRecoveryStatusConflict, false, nil, nil)
			}
			return mutationCommitAmbiguous("the replacement changed during commit; recoverable versions were retained")
		}
		if beforeRollback != nil {
			if err := beforeRollback("modify", destination.absolutePath, temporary.absolutePath); err != nil {
				return mutationCommitAmbiguous("the replacement conflict could not be rolled back safely; both versions were retained")
			}
		}
		if revalidateMutationPaths(temporary, destination) != nil || !mutationObjectMatchesAt(destination, incoming) || !mutationObjectMatchesAt(temporary, preserved) {
			return mutationCommitAmbiguous("the replacement changed before rollback; both versions were retained")
		}
		if err := exchangePathsAt(temporary, destination); err != nil {
			return mutationCommitAmbiguous("the replacement conflict could not be rolled back atomically; both versions were retained")
		}
		if err := syncMutationDirectories(temporary, destination); err != nil || !mutationObjectMatchesAt(destination, preserved) || !mutationObjectMatchesAt(temporary, incoming) {
			return mutationCommitAmbiguous("the replacement rollback could not be verified; both versions were retained")
		}
		if err := unlinkMutationAt(temporary, false); err != nil {
			return mutationCommitAmbiguous("the rejected incoming version could not be cleaned up safely")
		}
		keepTemporary = false
		if err := destination.parent().Sync(); err != nil {
			return mutationCommitAmbiguous("the replacement rollback cleanup could not be synchronized")
		}
		return mutationVersionConflict("the destination changed after its base version was verified")
	}

	if revalidateMutationPaths(temporary, destination) != nil || !mutationObjectMatchesAt(destination, incoming) || !mutationObjectMatchesAt(temporary, baseline) {
		if recovery != nil {
			_ = recovery.retain(temporary, baseline, mutationRecoveryStatusConflict, false, nil, nil)
		}
		return mutationCommitAmbiguous("the replacement changed before cleanup; both versions were retained")
	}
	if recovery == nil {
		return mutationCommitAmbiguous("the prior destination has no durable recovery reservation")
	}
	if err := recovery.retain(
		temporary,
		baseline,
		mutationRecoveryStatusRetained,
		true,
		beforeFinalRetention,
		afterRecoveryMove,
	); err != nil {
		return mutationCommitAmbiguous("the prior destination could not be durably retained")
	}
	return nil
}

func moveMutationObjectCAS(
	command string,
	source *mutationPathRef,
	destination *mutationPathRef,
	baseline mutationObjectState,
	failureCode string,
	beforeCommit func(command, path string) error,
	afterExchange func(command, installedPath, preservedPath string) error,
	beforeRollback func(command, installedPath, preservedPath string) error,
) *responseError {
	// Keep the test barrier adjacent to the no-replace rename so a concurrent
	// replacement cannot be hidden by unrelated validation or staging work.
	if beforeCommit != nil {
		if err := beforeCommit(command, source.absolutePath); err != nil {
			return commandError("internal_error", err.Error())
		}
	}
	if err := revalidateMutationPaths(source, destination); err != nil {
		return mutationVersionConflict("the item ancestor binding changed before commit")
	}
	if err := renameNoReplaceAt(source, destination); err != nil {
		return commandError(failureCode, err.Error())
	}
	if afterExchange != nil {
		if err := afterExchange(command, source.absolutePath, destination.absolutePath); err != nil {
			return mutationCommitAmbiguous("the quarantined mutation could not be verified; recoverable data was retained")
		}
	}
	if err := syncMutationDirectories(source, destination); err != nil {
		return mutationCommitAmbiguous("the quarantined mutation could not be synchronized")
	}
	if mutationObjectMatchesAt(destination, baseline) {
		return nil
	}
	preserved, err := captureMutationObjectAt(destination)
	if err != nil {
		return mutationCommitAmbiguous("the quarantined mutation could not be verified; recoverable data was retained")
	}
	if beforeRollback != nil {
		if err := beforeRollback(command, source.absolutePath, destination.absolutePath); err != nil {
			return mutationCommitAmbiguous("the mutation conflict could not be rolled back safely; recoverable data was retained")
		}
	}
	if revalidateMutationPaths(source, destination) != nil || !mutationPathMissingAt(source) || !mutationObjectMatchesAt(destination, preserved) {
		return mutationCommitAmbiguous("the mutation paths changed before rollback; recoverable data was retained")
	}
	if err := renameNoReplaceAt(destination, source); err != nil {
		return mutationCommitAmbiguous("the mutation conflict could not be rolled back atomically; recoverable data was retained")
	}
	if err := syncMutationDirectories(source, destination); err != nil || !mutationObjectMatchesAt(source, preserved) {
		return mutationCommitAmbiguous("the mutation rollback could not be verified; recoverable data was retained")
	}
	return mutationVersionConflict("the item changed after its base version was verified")
}

func restoreQuarantinedMutationObject(
	command string,
	quarantine *mutationPathRef,
	destination *mutationPathRef,
	beforeRollback func(command, installedPath, preservedPath string) error,
) error {
	preserved, err := captureMutationObjectAt(quarantine)
	if err != nil {
		return err
	}
	if beforeRollback != nil {
		if err := beforeRollback(command, destination.absolutePath, quarantine.absolutePath); err != nil {
			return err
		}
	}
	if revalidateMutationPaths(quarantine, destination) != nil || !mutationPathMissingAt(destination) || !mutationObjectMatchesAt(quarantine, preserved) {
		return errMutationObjectChanged
	}
	if err := renameNoReplaceAt(quarantine, destination); err != nil {
		return err
	}
	if err := syncMutationDirectories(quarantine, destination); err != nil {
		return err
	}
	if !mutationObjectMatchesAt(destination, preserved) {
		return errMutationObjectChanged
	}
	return nil
}

func syncMutationDirectories(first, second *mutationPathRef) error {
	if err := first.parent().Sync(); err != nil {
		return err
	}
	if !os.SameFile(first.chain.directories[len(first.chain.directories)-1].info, second.chain.directories[len(second.chain.directories)-1].info) {
		if err := second.parent().Sync(); err != nil {
			return err
		}
	}
	return nil
}
