// SPDX-License-Identifier: MIT

package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	syncthingContractLockName       = "SyncthingSource.lock.json"
	syncthingContractPreparePath    = "Scripts/prepare-syncthing-source.sh"
	syncthingContractExpectedModule = "github.com/syncthing/syncthing"
	syncthingContractExpectedPatch  = "Patches/syncthing-cluster-index-readiness.patch"
	syncthingContractExpectedLocal  = "../.build/go/syncthing-readiness-v1"
	syncthingContractGlobOldPath    = "github.com/gobwas/glob"
	syncthingContractGlobOldVersion = "v0.2.3"
	syncthingContractGlobNewPath    = "github.com/calmh/glob"
	syncthingContractGlobNewVersion = "v0.0.0-20220615080505-1d823af5017b"
	syncthingContractGWOldPath      = "github.com/jackpal/gateway"
	syncthingContractGWOldVersion   = "v1.1.1"
	syncthingContractGWNewPath      = "github.com/marbens-arch/gateway"
	syncthingContractGWNewVersion   = "v1.1.2-0.20260308173556-c567cc04e7d4"
	syncthingContractMaxFileBytes   = 128 * 1024 * 1024
	syncthingContractMaxTreeBytes   = 1024 * 1024 * 1024
	syncthingContractMaxTreeFiles   = 200_000
)

type syncthingSourceLock struct {
	SchemaVersion          int    `json:"schemaVersion"`
	ModulePath             string `json:"modulePath"`
	ModuleVersion          string `json:"moduleVersion"`
	ModuleCommit           string `json:"moduleCommit"`
	ModuleSum              string `json:"moduleSum"`
	LocalReplaceOldVersion string `json:"localReplaceOldVersion"`
	LocalReplacePath       string `json:"localReplacePath"`
	PatchPath              string `json:"patchPath"`
	PatchSHA256            string `json:"patchSHA256"`
	PatchedTreeSHA256      string `json:"patchedTreeSHA256"`
}

type validatedSyncthingSource struct {
	Lock          syncthingSourceLock
	CoreDir       string
	PatchFile     string
	GeneratedDir  string
	PatchSHA256   string
	TreeSHA256    string
	TreeAvailable bool
}

type goModEditJSON struct {
	Require []struct {
		Path    string
		Version string
	}
	Replace []struct {
		Old struct {
			Path    string
			Version string
		}
		New struct {
			Path    string
			Version string
		}
	}
}

type syncthingTreeNodeSnapshot struct {
	Relative string
	Info     fs.FileInfo
}

func loadSyncthingSourceContract(coreDir string, requireTree bool) (validatedSyncthingSource, error) {
	absoluteCore, err := filepath.Abs(coreDir)
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("resolve GoCore: %w", err)
	}
	if err := requireRealDirectory(absoluteCore); err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("unsafe GoCore: %w", err)
	}

	lockPath := filepath.Join(absoluteCore, syncthingContractLockName)
	lockData, _, err := readStableRegularFile(lockPath, 1<<20)
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("read Syncthing source lock: %w", err)
	}
	var lock syncthingSourceLock
	decoder := json.NewDecoder(bytes.NewReader(lockData))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&lock); err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("decode Syncthing source lock: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return validatedSyncthingSource{}, errors.New("Syncthing source lock contains trailing JSON")
	}
	if err := validateSyncthingLock(lock); err != nil {
		return validatedSyncthingSource{}, err
	}

	patchFile := filepath.Join(absoluteCore, filepath.FromSlash(lock.PatchPath))
	patchData, _, err := readStableRegularFile(patchFile, syncthingContractMaxFileBytes)
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("read audited Syncthing patch: %w", err)
	}
	patchDigest := sha256.Sum256(patchData)
	patchSHA := hex.EncodeToString(patchDigest[:])
	if patchSHA != lock.PatchSHA256 {
		return validatedSyncthingSource{}, fmt.Errorf("Syncthing patch SHA-256 drift: lock=%s actual=%s", lock.PatchSHA256, patchSHA)
	}

	preparePath := filepath.Join(absoluteCore, filepath.FromSlash(syncthingContractPreparePath))
	prepareData, _, err := readStableRegularFile(preparePath, 2<<20)
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("read Syncthing source preparer: %w", err)
	}
	if err := validatePreparePins(prepareData, lock); err != nil {
		return validatedSyncthingSource{}, err
	}
	if err := validateGoModContract(absoluteCore, lock); err != nil {
		return validatedSyncthingSource{}, err
	}

	generatedDir := filepath.Clean(filepath.Join(absoluteCore, filepath.FromSlash(lock.LocalReplacePath)))
	repositoryDir := filepath.Dir(absoluteCore)
	if err := requireRealDirectory(repositoryDir); err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("unsafe repository root: %w", err)
	}
	expectedGenerated := filepath.Join(repositoryDir, ".build", "go", "syncthing-readiness-v1")
	if generatedDir != expectedGenerated {
		return validatedSyncthingSource{}, errors.New("Syncthing local replacement escapes its audited generated path")
	}
	if err := rejectSymlinkedPathWithin(repositoryDir, generatedDir, true); err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("unsafe Syncthing generated path: %w", err)
	}

	result := validatedSyncthingSource{
		Lock:         lock,
		CoreDir:      absoluteCore,
		PatchFile:    patchFile,
		GeneratedDir: generatedDir,
		PatchSHA256:  patchSHA,
	}
	info, err := os.Lstat(generatedDir)
	if errors.Is(err, os.ErrNotExist) {
		if requireTree {
			return validatedSyncthingSource{}, errors.New("audited Syncthing generated tree is missing; run its preparer")
		}
		return result, nil
	}
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("inspect Syncthing generated tree: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return validatedSyncthingSource{}, errors.New("Syncthing generated tree must be a real directory")
	}
	treeSHA, err := syncthingTreeHash(generatedDir)
	if err != nil {
		return validatedSyncthingSource{}, fmt.Errorf("hash Syncthing generated tree: %w", err)
	}
	if treeSHA != lock.PatchedTreeSHA256 {
		return validatedSyncthingSource{}, fmt.Errorf("Syncthing generated tree SHA-256 drift: lock=%s actual=%s", lock.PatchedTreeSHA256, treeSHA)
	}
	result.TreeSHA256 = treeSHA
	result.TreeAvailable = true
	return result, nil
}

func validateSyncthingLock(lock syncthingSourceLock) error {
	if lock.SchemaVersion != 1 {
		return fmt.Errorf("unsupported Syncthing source lock schema %d", lock.SchemaVersion)
	}
	if lock.ModulePath != syncthingContractExpectedModule || lock.ModuleVersion == "" {
		return errors.New("Syncthing source lock has an unexpected module pin")
	}
	if len(lock.ModuleCommit) != 40 || !isLowerHex(lock.ModuleCommit) {
		return errors.New("Syncthing source lock has an invalid commit")
	}
	if !strings.HasPrefix(lock.ModuleSum, "h1:") {
		return errors.New("Syncthing source lock has an invalid Go module sum")
	}
	decodedSum, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(lock.ModuleSum, "h1:"))
	if err != nil || len(decodedSum) != sha256.Size {
		return errors.New("Syncthing source lock has an invalid Go module sum")
	}
	if lock.LocalReplaceOldVersion != "" || lock.LocalReplacePath != syncthingContractExpectedLocal {
		return errors.New("Syncthing source lock has an unexpected local replacement")
	}
	if lock.PatchPath != syncthingContractExpectedPatch {
		return errors.New("Syncthing source lock has an unexpected patch path")
	}
	for label, value := range map[string]string{
		"patch SHA-256":        lock.PatchSHA256,
		"patched tree SHA-256": lock.PatchedTreeSHA256,
	} {
		if len(value) != sha256.Size*2 || !isLowerHex(value) {
			return fmt.Errorf("Syncthing source lock has an invalid %s", label)
		}
	}
	return nil
}

func validatePreparePins(data []byte, lock syncthingSourceLock) error {
	expected := map[string]string{
		"module_path":         lock.ModulePath,
		"module_version":      lock.ModuleVersion,
		"module_commit":       lock.ModuleCommit,
		"module_sum":          lock.ModuleSum,
		"patch_sha256":        lock.PatchSHA256,
		"patched_tree_sha256": lock.PatchedTreeSHA256,
	}
	actual := make(map[string]string, len(expected))
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		for key := range expected {
			prefix := key + "="
			if !strings.HasPrefix(line, prefix) {
				continue
			}
			if _, exists := actual[key]; exists {
				return fmt.Errorf("Syncthing source preparer repeats %s", key)
			}
			value := strings.TrimSpace(strings.TrimPrefix(line, prefix))
			if len(value) >= 2 && ((value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"')) {
				value = value[1 : len(value)-1]
			}
			actual[key] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan Syncthing source preparer: %w", err)
	}
	for key, expectedValue := range expected {
		if actual[key] != expectedValue {
			return fmt.Errorf("Syncthing source preparer %s drift: lock=%s preparer=%s", key, expectedValue, actual[key])
		}
	}
	text := string(data)
	if !strings.Contains(text, `patch_file="$core_dir/`+lock.PatchPath+`"`) {
		return errors.New("Syncthing source preparer patch path drift")
	}
	if !strings.Contains(text, `generated_dir="$generated_parent/`+filepath.Base(lock.LocalReplacePath)+`"`) {
		return errors.New("Syncthing source preparer generated path drift")
	}
	return nil
}

func validateGoModContract(coreDir string, lock syncthingSourceLock) error {
	goModPath := filepath.Join(coreDir, "go.mod")
	if _, _, err := readStableRegularFile(goModPath, 4<<20); err != nil {
		return fmt.Errorf("read GoCore/go.mod: %w", err)
	}
	command := exec.Command("go", "mod", "edit", "-json", goModPath)
	command.Env = cleanGoEnvironment(os.Environ())
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return fmt.Errorf("parse GoCore/go.mod: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	var edit goModEditJSON
	decoder := json.NewDecoder(bytes.NewReader(output))
	if err := decoder.Decode(&edit); err != nil {
		return fmt.Errorf("decode go mod edit output: %w", err)
	}
	requireMatches := 0
	for _, required := range edit.Require {
		if required.Path == lock.ModulePath {
			requireMatches++
			if required.Version != lock.ModuleVersion {
				return fmt.Errorf("Syncthing required version drift: lock=%s go.mod=%s", lock.ModuleVersion, required.Version)
			}
		}
	}
	if requireMatches != 1 {
		return fmt.Errorf("GoCore/go.mod must require Syncthing exactly once, found %d", requireMatches)
	}

	expectedReplacements := map[string]struct{}{
		goReplacementKey(
			syncthingContractGlobOldPath, syncthingContractGlobOldVersion,
			syncthingContractGlobNewPath, syncthingContractGlobNewVersion,
		): {},
		goReplacementKey(
			syncthingContractGWOldPath, syncthingContractGWOldVersion,
			syncthingContractGWNewPath, syncthingContractGWNewVersion,
		): {},
		goReplacementKey(lock.ModulePath, lock.LocalReplaceOldVersion, lock.LocalReplacePath, ""): {},
	}
	if len(edit.Replace) != len(expectedReplacements) {
		return fmt.Errorf("GoCore/go.mod must contain exactly %d audited replacements, found %d", len(expectedReplacements), len(edit.Replace))
	}
	seenReplacements := make(map[string]struct{}, len(edit.Replace))
	for _, replacement := range edit.Replace {
		key := goReplacementKey(
			replacement.Old.Path, replacement.Old.Version,
			replacement.New.Path, replacement.New.Version,
		)
		if _, expected := expectedReplacements[key]; !expected {
			return fmt.Errorf(
				"unaudited Go replacement: %s@%s => %s@%s",
				replacement.Old.Path, replacement.Old.Version,
				replacement.New.Path, replacement.New.Version,
			)
		}
		if _, duplicate := seenReplacements[key]; duplicate {
			return fmt.Errorf(
				"duplicate audited Go replacement: %s@%s",
				replacement.Old.Path, replacement.Old.Version,
			)
		}
		seenReplacements[key] = struct{}{}
	}
	if len(seenReplacements) != len(expectedReplacements) {
		return errors.New("GoCore/go.mod is missing an audited Go replacement")
	}

	return nil
}

func goReplacementKey(oldPath, oldVersion, newPath, newVersion string) string {
	return strings.Join([]string{oldPath, oldVersion, newPath, newVersion}, "\x00")
}

// verifyPristineSyncthingModule proves that both the downloaded module zip and
// the extracted directory have exactly the h1 content pinned in the source
// lock. This is deliberately independent of GoCore/go.sum: Syncthing is
// locally replaced in the main module, so the explicit module@version download
// is the checksum-verifying trust boundary for the standard peer.
func verifyPristineSyncthingModule(contract validatedSyncthingSource, directory, zipPath string) error {
	prefix := contract.Lock.ModulePath + "@" + contract.Lock.ModuleVersion
	directoryHash, err := syncthingModuleDirectoryHash(directory, prefix)
	if err != nil {
		return fmt.Errorf("hash extracted upstream Syncthing module: %w", err)
	}
	if directoryHash != contract.Lock.ModuleSum {
		return fmt.Errorf("upstream Syncthing directory checksum drift: lock=%s actual=%s", contract.Lock.ModuleSum, directoryHash)
	}
	zipHash, err := syncthingModuleZipHash(zipPath, prefix)
	if err != nil {
		return fmt.Errorf("hash upstream Syncthing module zip: %w", err)
	}
	if zipHash != contract.Lock.ModuleSum {
		return fmt.Errorf("upstream Syncthing zip checksum drift: lock=%s actual=%s", contract.Lock.ModuleSum, zipHash)
	}
	return nil
}

func syncthingModuleDirectoryHash(root, prefix string) (string, error) {
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	if err := requireRealDirectory(absoluteRoot); err != nil {
		return "", err
	}
	type input struct {
		name string
		path string
	}
	inputs := make([]input, 0, 1024)
	nodes := make([]syncthingTreeNodeSnapshot, 0, 1024)
	var total int64
	err = filepath.WalkDir(absoluteRoot, func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(absoluteRoot, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("module tree contains a symlink: %s", relative)
		}
		if path == absoluteRoot || info.IsDir() {
			nodes = append(nodes, syncthingTreeNodeSnapshot{Relative: relative, Info: info})
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("module tree contains a special file: %s", relative)
		}
		if strings.Contains(relative, "\n") {
			return errors.New("module tree path contains a newline")
		}
		if len(inputs) >= syncthingContractMaxTreeFiles || total+info.Size() > syncthingContractMaxTreeBytes {
			return errors.New("module tree exceeds safety limits")
		}
		inputs = append(inputs, input{name: prefix + "/" + relative, path: path})
		nodes = append(nodes, syncthingTreeNodeSnapshot{Relative: relative, Info: info})
		total += info.Size()
		return nil
	})
	if err != nil {
		return "", err
	}
	hash, err := syncthingModuleHash1(inputs, func(item input) string { return item.name }, func(item input) (io.ReadCloser, error) {
		data, _, err := readStableRegularFile(item.path, syncthingContractMaxFileBytes)
		if err != nil {
			return nil, err
		}
		return io.NopCloser(bytes.NewReader(data)), nil
	})
	if err != nil {
		return "", err
	}
	after, err := snapshotSyncthingTreeNodes(absoluteRoot)
	if err != nil {
		return "", err
	}
	if !sameSyncthingTreeNodes(nodes, after) {
		return "", errors.New("module tree entries changed while hashing")
	}
	return hash, nil
}

func syncthingModuleZipHash(path, prefix string) (string, error) {
	data, _, err := readStableRegularFile(path, syncthingContractMaxTreeBytes)
	if err != nil {
		return "", err
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return "", err
	}
	type input struct {
		name string
		file *zip.File
	}
	inputs := make([]input, 0, len(reader.File))
	seen := make(map[string]struct{}, len(reader.File))
	var total uint64
	for _, file := range reader.File {
		if file.Name == "" || !strings.HasPrefix(file.Name, prefix+"/") || strings.Contains(file.Name, "\n") || strings.Contains(file.Name, "\\") {
			return "", fmt.Errorf("module zip contains an unsafe path: %q", file.Name)
		}
		clean := filepath.ToSlash(filepath.Clean(file.Name))
		if clean != file.Name || strings.HasSuffix(file.Name, "/") {
			return "", fmt.Errorf("module zip contains a non-canonical path: %q", file.Name)
		}
		if _, exists := seen[file.Name]; exists {
			return "", fmt.Errorf("module zip repeats a path: %s", file.Name)
		}
		seen[file.Name] = struct{}{}
		if !file.Mode().IsRegular() || file.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("module zip contains a non-regular entry: %s", file.Name)
		}
		total += file.UncompressedSize64
		if len(inputs) >= syncthingContractMaxTreeFiles || total > syncthingContractMaxTreeBytes {
			return "", errors.New("module zip exceeds safety limits")
		}
		inputs = append(inputs, input{name: file.Name, file: file})
	}
	return syncthingModuleHash1(inputs, func(item input) string { return item.name }, func(item input) (io.ReadCloser, error) {
		return item.file.Open()
	})
}

func syncthingModuleHash1[T any](inputs []T, nameOf func(T) string, open func(T) (io.ReadCloser, error)) (string, error) {
	type named struct {
		name  string
		input T
	}
	items := make([]named, 0, len(inputs))
	for _, input := range inputs {
		items = append(items, named{name: nameOf(input), input: input})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].name < items[j].name })
	manifest := sha256.New()
	for _, item := range items {
		reader, err := open(item.input)
		if err != nil {
			return "", err
		}
		fileHash := sha256.New()
		_, copyErr := io.Copy(fileHash, reader)
		closeErr := reader.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		fmt.Fprintf(manifest, "%x  %s\n", fileHash.Sum(nil), item.name)
	}
	return "h1:" + base64.StdEncoding.EncodeToString(manifest.Sum(nil)), nil
}

func cleanGoEnvironment(environment []string) []string {
	result := make([]string, 0, len(environment)+3)
	for _, item := range environment {
		key := item
		if index := strings.IndexByte(item, '='); index >= 0 {
			key = item[:index]
		}
		switch key {
		case "CGO_ENABLED", "GO111MODULE", "GOARCH", "GOENV", "GOFLAGS", "GOOS", "GOWORK":
			continue
		default:
			result = append(result, item)
		}
	}
	return append(result, "GO111MODULE=on", "GOENV=off", "GOFLAGS=", "GOWORK=off")
}

func syncthingTreeHash(root string) (string, error) {
	rootInfo, err := os.Lstat(root)
	if err != nil {
		return "", err
	}
	if !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("tree root is not a real directory")
	}
	type entry struct {
		relative string
		digest   string
		bytes    int64
	}
	entries := make([]entry, 0, 1024)
	nodes := []syncthingTreeNodeSnapshot{{Relative: ".", Info: rootInfo}}
	var total int64
	err = filepath.WalkDir(root, func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if strings.ContainsAny(relative, "\n\t") {
			return fmt.Errorf("tree path contains a newline or tab: %q", relative)
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("tree contains a symlink: %s", relative)
		}
		if info.IsDir() {
			nodes = append(nodes, syncthingTreeNodeSnapshot{Relative: relative, Info: info})
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("tree contains a special file: %s", relative)
		}
		data, stableInfo, err := readStableRegularFile(path, syncthingContractMaxFileBytes)
		if err != nil {
			return err
		}
		total += int64(len(data))
		if len(entries) >= syncthingContractMaxTreeFiles || total > syncthingContractMaxTreeBytes {
			return errors.New("tree exceeds safety limits")
		}
		digest := sha256.Sum256(data)
		entries = append(entries, entry{relative: relative, digest: hex.EncodeToString(digest[:]), bytes: stableInfo.Size()})
		nodes = append(nodes, syncthingTreeNodeSnapshot{Relative: relative, Info: stableInfo})
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].relative < entries[j].relative })
	manifest := sha256.New()
	for _, item := range entries {
		fmt.Fprintf(manifest, "%s\t%d\t%s\n", item.digest, item.bytes, item.relative)
	}
	afterNodes, err := snapshotSyncthingTreeNodes(root)
	if err != nil {
		return "", err
	}
	if !sameSyncthingTreeNodes(nodes, afterNodes) {
		return "", errors.New("tree entries changed while hashing")
	}
	return hex.EncodeToString(manifest.Sum(nil)), nil
}

func snapshotSyncthingTreeNodes(root string) ([]syncthingTreeNodeSnapshot, error) {
	nodes := make([]syncthingTreeNodeSnapshot, 0, 1024)
	err := filepath.WalkDir(root, func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if strings.ContainsAny(relative, "\n\t") {
			return fmt.Errorf("tree path contains a newline or tab: %q", relative)
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("tree contains a symlink: %s", relative)
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return fmt.Errorf("tree contains a special file: %s", relative)
		}
		nodes = append(nodes, syncthingTreeNodeSnapshot{Relative: relative, Info: info})
		return nil
	})
	return nodes, err
}

func sameSyncthingTreeNodes(before, after []syncthingTreeNodeSnapshot) bool {
	if len(before) != len(after) {
		return false
	}
	for index := range before {
		left, right := before[index], after[index]
		if left.Relative != right.Relative || !os.SameFile(left.Info, right.Info) ||
			left.Info.Mode() != right.Info.Mode() || left.Info.Size() != right.Info.Size() ||
			!left.Info.ModTime().Equal(right.Info.ModTime()) {
			return false
		}
	}
	return true
}

func readStableRegularFile(path string, maximum int64) ([]byte, fs.FileInfo, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !before.Mode().IsRegular() || before.Mode()&os.ModeSymlink != 0 || before.Size() > maximum {
		return nil, nil, errors.New("input is not a safe regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, nil, err
	}
	if !os.SameFile(before, opened) || !opened.Mode().IsRegular() {
		return nil, nil, errors.New("input changed before reading")
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, nil, err
	}
	if int64(len(data)) > maximum {
		return nil, nil, errors.New("input exceeds safety limit")
	}
	after, err := file.Stat()
	if err != nil {
		return nil, nil, err
	}
	if !os.SameFile(opened, after) || opened.Size() != after.Size() || opened.Size() != int64(len(data)) ||
		opened.Mode() != after.Mode() || !opened.ModTime().Equal(after.ModTime()) {
		return nil, nil, errors.New("input changed while reading")
	}
	return data, after, nil
}

func requireRealDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("path is not a real directory")
	}
	return nil
}

func rejectSymlinkedPathWithin(base, path string, allowMissing bool) error {
	absoluteBase, err := filepath.Abs(base)
	if err != nil {
		return err
	}
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(absoluteBase, absolutePath)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("path escapes its trusted base")
	}
	current := absoluteBase
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) && allowMissing {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("path component is a symlink: %s", component)
		}
	}
	return nil
}

func isLowerHex(value string) bool {
	if value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
