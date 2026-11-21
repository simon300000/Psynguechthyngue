// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var (
	errMutationPathChanged      = errors.New("mutation path binding changed")
	errMutationDirFDUnsupported = errors.New("directory-relative mutation operations are unsupported on this platform")
)

type mutationDirectoryBinding struct {
	file           *os.File
	nameFromParent string
	info           os.FileInfo
}

type mutationDirectoryChain struct {
	rootPath    string
	directories []mutationDirectoryBinding
}

type mutationPathRef struct {
	chain        *mutationDirectoryChain
	name         string
	relativePath string
	absolutePath string
}

func openMutationPath(root, relativePath string) (*mutationPathRef, error) {
	return openMutationPathWithDirectoryCreation(root, relativePath, nil)
}

// openMutationPathWithDirectoryCreation optionally creates missing ancestor
// directories through the already-bound parent descriptor. The validator must
// prove each prefix is an exact current global-index directory before mkdirat.
func openMutationPathWithDirectoryCreation(
	root, relativePath string,
	validateDirectory func(string) error,
) (*mutationPathRef, error) {
	if root == "" || !filepath.IsAbs(root) {
		return nil, errors.New("mutation root must be absolute")
	}
	components := strings.Split(relativePath, "/")
	if len(components) == 0 {
		return nil, errors.New("mutation path is empty")
	}
	for _, component := range components {
		if component == "" || component == "." || component == ".." || strings.ContainsAny(component, `/\\`) {
			return nil, errors.New("mutation path contains an invalid component")
		}
	}

	rootFile, err := openMutationDirectoryPath(root)
	if err != nil {
		return nil, err
	}
	rootInfo, err := rootFile.Stat()
	if err != nil || !rootInfo.IsDir() {
		_ = rootFile.Close()
		if err == nil {
			err = errors.New("mutation root is not a directory")
		}
		return nil, err
	}
	pathInfo, err := os.Lstat(root)
	if err != nil || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(rootInfo, pathInfo) {
		_ = rootFile.Close()
		return nil, errMutationPathChanged
	}

	chain := &mutationDirectoryChain{
		rootPath: root,
		directories: []mutationDirectoryBinding{{
			file: rootFile,
			info: rootInfo,
		}},
	}
	failed := true
	defer func() {
		if failed {
			_ = chain.close()
		}
	}()

	parent := rootFile
	for index, component := range components[:len(components)-1] {
		child, openErr := openMutationDirectoryAt(parent, component)
		if errors.Is(openErr, os.ErrNotExist) && validateDirectory != nil {
			prefix := strings.Join(components[:index+1], "/")
			if err := validateDirectory(prefix); err != nil {
				return nil, err
			}
			if err := mkdirMutationNameAt(parent, component, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
				return nil, err
			}
			if err := parent.Sync(); err != nil {
				return nil, err
			}
			child, openErr = openMutationDirectoryAt(parent, component)
		}
		if openErr != nil {
			return nil, openErr
		}
		childInfo, statErr := child.Stat()
		if statErr != nil || !childInfo.IsDir() {
			_ = child.Close()
			if statErr == nil {
				statErr = errors.New("mutation path ancestor is not a directory")
			}
			return nil, statErr
		}
		chain.directories = append(chain.directories, mutationDirectoryBinding{
			file:           child,
			nameFromParent: component,
			info:           childInfo,
		})
		parent = child
	}

	failed = false
	return &mutationPathRef{
		chain:        chain,
		name:         components[len(components)-1],
		relativePath: relativePath,
		absolutePath: filepath.Join(root, filepath.FromSlash(relativePath)),
	}, nil
}

func (path *mutationPathRef) withName(name string) *mutationPathRef {
	return &mutationPathRef{
		chain:        path.chain,
		name:         name,
		relativePath: filepath.ToSlash(filepath.Join(filepath.Dir(path.relativePath), name)),
		absolutePath: filepath.Join(filepath.Dir(path.absolutePath), name),
	}
}

func (path *mutationPathRef) parent() *os.File {
	return path.chain.directories[len(path.chain.directories)-1].file
}

func (path *mutationPathRef) close() error {
	if path == nil || path.chain == nil {
		return nil
	}
	return path.chain.close()
}

func (chain *mutationDirectoryChain) close() error {
	var result error
	for index := len(chain.directories) - 1; index >= 0; index-- {
		result = errors.Join(result, chain.directories[index].file.Close())
	}
	chain.directories = nil
	return result
}

func (path *mutationPathRef) revalidate() error {
	if path == nil || path.chain == nil || len(path.chain.directories) == 0 {
		return errMutationPathChanged
	}
	rootCheck, err := openMutationDirectoryPath(path.chain.rootPath)
	if err != nil {
		return errMutationPathChanged
	}
	rootCheckInfo, statErr := rootCheck.Stat()
	_ = rootCheck.Close()
	if statErr != nil || !sameMutationDirectoryIdentity(rootCheckInfo, path.chain.directories[0].info) {
		return errMutationPathChanged
	}

	for index, binding := range path.chain.directories {
		currentInfo, err := binding.file.Stat()
		if err != nil || !sameMutationDirectoryIdentity(currentInfo, binding.info) {
			return errMutationPathChanged
		}
		if index == 0 {
			continue
		}
		parent := path.chain.directories[index-1].file
		currentBinding, err := openMutationDirectoryAt(parent, binding.nameFromParent)
		if err != nil {
			return errMutationPathChanged
		}
		currentBindingInfo, statErr := currentBinding.Stat()
		_ = currentBinding.Close()
		if statErr != nil || !sameMutationDirectoryIdentity(currentBindingInfo, binding.info) {
			return errMutationPathChanged
		}
	}
	return nil
}

func sameMutationDirectoryIdentity(left, right os.FileInfo) bool {
	return left != nil && right != nil && left.IsDir() && right.IsDir() && os.SameFile(left, right)
}

func revalidateMutationPaths(paths ...*mutationPathRef) error {
	seen := make(map[*mutationDirectoryChain]struct{}, len(paths))
	for _, path := range paths {
		if path == nil || path.chain == nil {
			return errMutationPathChanged
		}
		if _, ok := seen[path.chain]; ok {
			continue
		}
		if err := path.revalidate(); err != nil {
			return fmt.Errorf("%w: %v", errMutationPathChanged, err)
		}
		seen[path.chain] = struct{}{}
	}
	return nil
}
