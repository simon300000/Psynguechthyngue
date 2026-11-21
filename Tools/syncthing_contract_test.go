// SPDX-License-Identifier: MIT

package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestSyncthingSourceContractAcceptsExactFixture(t *testing.T) {
	fixture := newSyncthingContractFixture(t)
	contract, err := loadSyncthingSourceContract(fixture, true)
	if err != nil {
		t.Fatalf("exact source contract failed: %v", err)
	}
	if !contract.TreeAvailable || contract.TreeSHA256 != contract.Lock.PatchedTreeSHA256 {
		t.Fatalf("source contract omitted its generated tree: %+v", contract)
	}
}

func TestSyncthingSourceContractFailsClosed(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(t *testing.T, core string)
	}{
		{
			name: "missing local replacement",
			mutate: func(t *testing.T, core string) {
				replaceFileText(t, filepath.Join(core, "go.mod"), "replace github.com/syncthing/syncthing => ../.build/go/syncthing-readiness-v1\n", "")
			},
		},
		{
			name: "missing audited remote replacement",
			mutate: func(t *testing.T, core string) {
				replaceFileText(t, filepath.Join(core, "go.mod"), "replace "+syncthingContractGlobOldPath+" "+syncthingContractGlobOldVersion+" => "+syncthingContractGlobNewPath+" "+syncthingContractGlobNewVersion+"\n", "")
			},
		},
		{
			name: "drifted audited remote replacement",
			mutate: func(t *testing.T, core string) {
				replaceFileText(t, filepath.Join(core, "go.mod"), syncthingContractGlobNewVersion, "v0.0.0-20000101000000-000000000000")
			},
		},
		{
			name: "version specific Syncthing remote replacement",
			mutate: func(t *testing.T, core string) {
				appendFileText(t, filepath.Join(core, "go.mod"), "replace "+syncthingContractExpectedModule+" v1.2.3 => "+syncthingContractExpectedModule+" v1.2.2\n")
			},
		},
		{
			name: "additional remote replacement",
			mutate: func(t *testing.T, core string) {
				appendFileText(t, filepath.Join(core, "go.mod"), "replace example.com/extra v1.0.0 => example.com/fork v1.0.1\n")
			},
		},
		{
			name: "additional local replacement",
			mutate: func(t *testing.T, core string) {
				appendFileText(t, filepath.Join(core, "go.mod"), "replace example.com/extra => ../extra\n")
			},
		},
		{
			name: "wrong local replacement",
			mutate: func(t *testing.T, core string) {
				replaceFileText(t, filepath.Join(core, "go.mod"), "../.build/go/syncthing-readiness-v1", "../.build/go/other")
			},
		},
		{
			name: "patch tamper",
			mutate: func(t *testing.T, core string) {
				appendFileText(t, filepath.Join(core, syncthingContractExpectedPatch), "tamper\n")
			},
		},
		{
			name: "generated file tamper",
			mutate: func(t *testing.T, core string) {
				appendFileText(t, filepath.Join(core, syncthingContractExpectedLocal, "source.go"), "tamper\n")
			},
		},
		{
			name: "generated symlink tamper",
			mutate: func(t *testing.T, core string) {
				if err := os.Symlink("source.go", filepath.Join(core, syncthingContractExpectedLocal, "alias.go")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "generated special node tamper",
			mutate: func(t *testing.T, core string) {
				if err := syscall.Mkfifo(filepath.Join(core, syncthingContractExpectedLocal, "unexpected.fifo"), 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "build parent symlink",
			mutate: func(t *testing.T, core string) {
				repository := filepath.Dir(core)
				build := filepath.Join(repository, ".build")
				realBuild := filepath.Join(repository, "real-build")
				if err := os.Rename(build, realBuild); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(realBuild, build); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "go parent symlink",
			mutate: func(t *testing.T, core string) {
				repository := filepath.Dir(core)
				goParent := filepath.Join(repository, ".build", "go")
				realGo := filepath.Join(repository, "real-go")
				if err := os.Rename(goParent, realGo); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(realGo, goParent); err != nil {
					t.Fatal(err)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newSyncthingContractFixture(t)
			test.mutate(t, fixture)
			if _, err := loadSyncthingSourceContract(fixture, true); err == nil {
				t.Fatal("source contract accepted drift")
			}
		})
	}
}

func TestSyncthingSourceContractPreflightAllowsMissingGeneratedTree(t *testing.T) {
	fixture := newSyncthingContractFixture(t)
	if err := os.RemoveAll(filepath.Join(fixture, syncthingContractExpectedLocal)); err != nil {
		t.Fatal(err)
	}
	contract, err := loadSyncthingSourceContract(fixture, false)
	if err != nil {
		t.Fatalf("preflight rejected a clean missing generated tree: %v", err)
	}
	if contract.TreeAvailable {
		t.Fatal("preflight reported a missing tree as available")
	}
	if _, err := loadSyncthingSourceContract(fixture, true); err == nil {
		t.Fatal("full verification accepted a missing generated tree")
	}
}

func TestPristineSyncthingModuleRequiresMatchingDirectoryAndZip(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "module")
	if err := os.MkdirAll(filepath.Join(directory, "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFileText(t, filepath.Join(directory, "go.mod"), "module "+syncthingContractExpectedModule+"\n")
	writeFileText(t, filepath.Join(directory, "lib", "source.go"), "package lib\n")
	version := "v1.2.3"
	prefix := syncthingContractExpectedModule + "@" + version
	expected, err := syncthingModuleDirectoryHash(directory, prefix)
	if err != nil {
		t.Fatal(err)
	}
	zipPath := filepath.Join(t.TempDir(), "module.zip")
	writeSyncthingModuleZip(t, zipPath, prefix, directory)
	contract := validatedSyncthingSource{Lock: syncthingSourceLock{
		ModulePath: syncthingContractExpectedModule, ModuleVersion: version, ModuleSum: expected,
	}}
	if err := verifyPristineSyncthingModule(contract, directory, zipPath); err != nil {
		t.Fatalf("exact upstream module failed: %v", err)
	}
	appendFileText(t, filepath.Join(directory, "lib", "source.go"), "// tamper\n")
	if err := verifyPristineSyncthingModule(contract, directory, zipPath); err == nil {
		t.Fatal("upstream verification accepted a tampered extracted tree")
	}
}

func TestPristineSyncthingModuleRejectsTamperedZip(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "module")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFileText(t, filepath.Join(directory, "go.mod"), "module "+syncthingContractExpectedModule+"\n")
	version := "v1.2.3"
	prefix := syncthingContractExpectedModule + "@" + version
	expected, err := syncthingModuleDirectoryHash(directory, prefix)
	if err != nil {
		t.Fatal(err)
	}
	zipPath := filepath.Join(t.TempDir(), "module.zip")
	writeSyncthingModuleZip(t, zipPath, prefix, directory)
	appendFileText(t, filepath.Join(directory, "go.mod"), "// zip tamper\n")
	writeSyncthingModuleZip(t, zipPath, prefix, directory)
	writeFileText(t, filepath.Join(directory, "go.mod"), "module "+syncthingContractExpectedModule+"\n")
	contract := validatedSyncthingSource{Lock: syncthingSourceLock{
		ModulePath: syncthingContractExpectedModule, ModuleVersion: version, ModuleSum: expected,
	}}
	if err := verifyPristineSyncthingModule(contract, directory, zipPath); err == nil {
		t.Fatal("upstream verification accepted a tampered module zip")
	}
}

func newSyncthingContractFixture(t *testing.T) string {
	t.Helper()
	repository := t.TempDir()
	core := filepath.Join(repository, "GoCore")
	generated := filepath.Join(repository, ".build", "go", "syncthing-readiness-v1")
	for _, directory := range []string{core, filepath.Join(core, "Scripts"), filepath.Join(core, "Patches"), generated} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	version := "v1.2.3"
	moduleSum := "h1:" + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	goMod := "module example.com/core\n\ngo 1.25\n\nrequire " + syncthingContractExpectedModule + " " + version + "\n\n" +
		"replace " + syncthingContractGlobOldPath + " " + syncthingContractGlobOldVersion + " => " + syncthingContractGlobNewPath + " " + syncthingContractGlobNewVersion + "\n\n" +
		"replace " + syncthingContractGWOldPath + " " + syncthingContractGWOldVersion + " => " + syncthingContractGWNewPath + " " + syncthingContractGWNewVersion + "\n\n" +
		"replace " + syncthingContractExpectedModule + " => " + syncthingContractExpectedLocal + "\n"
	writeFileText(t, filepath.Join(core, "go.mod"), goMod)
	writeFileText(t, filepath.Join(core, "go.sum"), syncthingContractExpectedModule+" "+version+" "+moduleSum+"\n")
	patch := []byte("audited patch\n")
	writeFileText(t, filepath.Join(core, syncthingContractExpectedPatch), string(patch))
	writeFileText(t, filepath.Join(generated, "source.go"), "package source\n")
	treeSHA, err := syncthingTreeHash(generated)
	if err != nil {
		t.Fatal(err)
	}
	patchDigest := sha256.Sum256(patch)
	lock := syncthingSourceLock{
		SchemaVersion:          1,
		ModulePath:             syncthingContractExpectedModule,
		ModuleVersion:          version,
		ModuleCommit:           strings.Repeat("a", 40),
		ModuleSum:              moduleSum,
		LocalReplaceOldVersion: "",
		LocalReplacePath:       syncthingContractExpectedLocal,
		PatchPath:              syncthingContractExpectedPatch,
		PatchSHA256:            hex.EncodeToString(patchDigest[:]),
		PatchedTreeSHA256:      treeSHA,
	}
	lockData, err := json.MarshalIndent(lock, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	writeFileText(t, filepath.Join(core, syncthingContractLockName), string(lockData)+"\n")
	prepare := "#!/bin/sh\n" +
		"patch_file=\"$core_dir/" + lock.PatchPath + "\"\n" +
		"module_path=" + lock.ModulePath + "\n" +
		"module_version=" + lock.ModuleVersion + "\n" +
		"module_commit=" + lock.ModuleCommit + "\n" +
		"module_sum='" + lock.ModuleSum + "'\n" +
		"patch_sha256=" + lock.PatchSHA256 + "\n" +
		"patched_tree_sha256=" + lock.PatchedTreeSHA256 + "\n" +
		"generated_dir=\"$generated_parent/" + filepath.Base(lock.LocalReplacePath) + "\"\n"
	writeFileText(t, filepath.Join(core, syncthingContractPreparePath), prepare)
	return core
}

func writeSyncthingModuleZip(t *testing.T, path, prefix, directory string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	archive := zip.NewWriter(file)
	err = filepath.WalkDir(directory, func(inputPath string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(directory, inputPath)
		if err != nil {
			return err
		}
		writer, err := archive.Create(prefix + "/" + filepath.ToSlash(relative))
		if err != nil {
			return err
		}
		data, err := os.ReadFile(inputPath)
		if err != nil {
			return err
		}
		_, err = writer.Write(data)
		return err
	})
	if err == nil {
		err = archive.Close()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
}

func writeFileText(t *testing.T, path, value string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}

func appendFileText(t *testing.T, path, value string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(value); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func replaceFileText(t *testing.T, path, old, replacement string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	updated := strings.Replace(string(data), old, replacement, 1)
	if updated == string(data) {
		t.Fatalf("fixture does not contain %q", old)
	}
	writeFileText(t, path, updated)
}
