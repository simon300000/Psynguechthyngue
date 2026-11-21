// SPDX-License-Identifier: MIT

//go:build !darwin && !ios && !linux

package mobilebridge

import "os"

func openMutationDirectoryPath(string) (*os.File, error) {
	return nil, errMutationDirFDUnsupported
}

func openMutationDirectoryAt(*os.File, string) (*os.File, error) {
	return nil, errMutationDirFDUnsupported
}

func openMutationObjectAt(*os.File, string) (*os.File, error) {
	return nil, errMutationDirFDUnsupported
}

func createMutationTemporaryAt(*os.File) (string, *os.File, error) {
	return "", nil, errMutationDirFDUnsupported
}

func createMutationNamedFileAt(*os.File, string, uint32) (*os.File, error) {
	return nil, errMutationDirFDUnsupported
}

func mutationDirectoriesShareDevice(*os.File, *os.File) (bool, error) {
	return false, errMutationDirFDUnsupported
}

func mutationDirectoryIdentity(*os.File) (string, error) {
	return "", errMutationDirFDUnsupported
}

func readMutationLinkAt(*os.File, string) (string, error) {
	return "", errMutationDirFDUnsupported
}

func mkdirMutationAt(*mutationPathRef, uint32) error {
	return errMutationDirFDUnsupported
}

func mkdirMutationNameAt(*os.File, string, uint32) error {
	return errMutationDirFDUnsupported
}

func unlinkMutationAt(*mutationPathRef, bool) error {
	return errMutationDirFDUnsupported
}
