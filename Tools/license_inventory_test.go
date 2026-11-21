// SPDX-License-Identifier: MIT

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateLicenseEntryAcceptsExactControlledEvidence(t *testing.T) {
	digest := sha256.Sum256([]byte("MIT text"))
	digestText := hex.EncodeToString(digest[:])
	entry := licenseEntry{
		Module:       "example.com/module",
		Version:      "v1.2.3",
		License:      "MIT",
		LicenseFiles: map[string]string{"LICENSE": digestText},
	}
	requested := module{Path: entry.Module, Version: entry.Version}
	evidence := []licenseEvidence{{Name: "LICENSE", SHA256: digestText, Candidate: "MIT"}}
	if err := validateLicenseEntry(entry, requested, requested, evidence); err != nil {
		t.Fatalf("validateLicenseEntry rejected exact evidence: %v", err)
	}
}

func TestValidateLicenseEntryFailsClosed(t *testing.T) {
	digest := strings.Repeat("a", sha256.Size*2)
	base := licenseEntry{
		Module:       "example.com/module",
		Version:      "v1.2.3",
		License:      "MIT",
		LicenseFiles: map[string]string{"LICENSE": digest},
	}
	requested := module{Path: base.Module, Version: base.Version}
	evidence := []licenseEvidence{{Name: "LICENSE", SHA256: digest, Candidate: "MIT"}}
	tests := []struct {
		name      string
		mutate    func(*licenseEntry)
		evidence  []licenseEvidence
		effective module
	}{
		{
			name: "unknown license",
			mutate: func(entry *licenseEntry) {
				entry.License = "NOASSERTION"
			},
			evidence: evidence,
		},
		{
			name: "evidence digest drift",
			mutate: func(entry *licenseEntry) {
				entry.LicenseFiles["LICENSE"] = strings.Repeat("b", sha256.Size*2)
			},
			evidence: evidence,
		},
		{
			name:   "unmapped new notice",
			mutate: func(_ *licenseEntry) {},
			evidence: append(evidence, licenseEvidence{
				Name: "NOTICE", SHA256: digest, Candidate: "NOASSERTION",
			}),
		},
		{
			name: "unsafe evidence path",
			mutate: func(entry *licenseEntry) {
				entry.LicenseFiles = map[string]string{"../LICENSE": digest}
			},
			evidence: evidence,
		},
		{
			name: "MPL source delivery omitted",
			mutate: func(entry *licenseEntry) {
				entry.License = "MPL-2.0"
			},
			evidence: []licenseEvidence{{Name: "LICENSE", SHA256: digest, Candidate: "MPL-2.0"}},
		},
		{
			name: "replacement drift",
			mutate: func(entry *licenseEntry) {
				entry.ResolvedModule = "example.com/replacement"
				entry.ResolvedVersion = "v1.0.0"
			},
			evidence:  evidence,
			effective: module{Path: "example.com/other", Version: "v1.0.0"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			entry := base
			entry.LicenseFiles = map[string]string{"LICENSE": digest}
			test.mutate(&entry)
			effective := test.effective
			if effective.Path == "" {
				effective = requested
			}
			if err := validateLicenseEntry(entry, requested, effective, test.evidence); err == nil {
				t.Fatal("validateLicenseEntry accepted drift or unknown evidence")
			}
		})
	}
}

func TestValidateLocalReplacementEntryBindsAuditedSource(t *testing.T) {
	lock := syncthingSourceLock{
		ModulePath:        syncthingContractExpectedModule,
		ModuleVersion:     "v1.2.3",
		ModuleCommit:      strings.Repeat("a", 40),
		ModuleSum:         "h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
		LocalReplacePath:  syncthingContractExpectedLocal,
		PatchPath:         syncthingContractExpectedPatch,
		PatchSHA256:       strings.Repeat("b", 64),
		PatchedTreeSHA256: strings.Repeat("c", 64),
	}
	contract := validatedSyncthingSource{Lock: lock, TreeSHA256: lock.PatchedTreeSHA256}
	requested := module{Path: lock.ModulePath, Version: lock.ModuleVersion}
	entry := licenseEntry{
		Module:  lock.ModulePath,
		Version: lock.ModuleVersion,
		LocalReplacement: &localReplacementEvidence{
			Path:              lock.LocalReplacePath,
			UpstreamCommit:    lock.ModuleCommit,
			UpstreamSum:       lock.ModuleSum,
			PatchPath:         lock.PatchPath,
			PatchSHA256:       lock.PatchSHA256,
			PatchedTreeSHA256: lock.PatchedTreeSHA256,
		},
	}
	if err := validateLocalReplacementEntry(entry, requested, true, contract); err != nil {
		t.Fatalf("exact local replacement evidence failed: %v", err)
	}
	entry.LocalReplacement.PatchSHA256 = strings.Repeat("d", 64)
	if err := validateLocalReplacementEntry(entry, requested, true, contract); err == nil {
		t.Fatal("local replacement evidence accepted patch drift")
	}
	if err := validateLocalReplacementEntry(licenseEntry{Module: "example.com/other"}, module{Path: "example.com/other"}, true, contract); err == nil {
		t.Fatal("non-Syncthing module accepted a local replacement")
	}
}

func TestSourceURLUsesExactGoProxyEscaping(t *testing.T) {
	tests := []struct {
		path    string
		version string
		want    string
	}{
		{
			path:    "github.com/kballard/go-shellquote",
			version: "v0.0.0-20180428030007-95032a82bc51",
			want:    "https://proxy.golang.org/github.com/kballard/go-shellquote/@v/v0.0.0-20180428030007-95032a82bc51.zip",
		},
		{
			path:    "github.com/Azure/go-ntlmssp",
			version: "v0.1.1",
			want:    "https://proxy.golang.org/github.com/!azure/go-ntlmssp/@v/v0.1.1.zip",
		},
	}
	for _, test := range tests {
		if actual := sourceURL(test.path, test.version); actual != test.want {
			t.Fatalf("sourceURL(%q, %q) = %q, want %q", test.path, test.version, actual, test.want)
		}
	}
	commit := strings.Repeat("a", 40)
	if actual := syncthingCommitSourceURL(commit); actual != "https://github.com/syncthing/syncthing/tree/"+commit {
		t.Fatalf("Syncthing commit URL drift: %q", actual)
	}
}

func TestDocumentNamespaceBindsCompleteSPDXSemantics(t *testing.T) {
	newDocument := func(downloadLocation string) document {
		return document{
			SPDXVersion:       "SPDX-2.3",
			DataLicense:       "CC0-1.0",
			SPDXID:            "SPDXRef-DOCUMENT",
			Name:              "fixture",
			DocumentNamespace: "stale-value-must-not-affect-identity",
			CreationInfo: creationInfo{
				Created: createdAt, Creators: []string{"Tool: fixture"},
			},
			Packages: []spdxPackage{{
				Name: "example.com/module", SPDXID: "SPDXRef-Go-example.com-module",
				VersionInfo: "v1.2.3", DownloadLocation: downloadLocation,
				FilesAnalyzed: false, LicenseConcluded: "NOASSERTION",
				LicenseDeclared: "MIT", CopyrightText: "NOASSERTION",
			}},
			Relationships: []relationship{{
				SPDXElementID: "SPDXRef-DOCUMENT", RelationshipType: "DESCRIBES",
				RelatedSPDXElement: "SPDXRef-Go-example.com-module",
			}},
		}
	}
	first := newDocument("https://proxy.golang.org/example.com/module/@v/v1.2.3.zip")
	second := newDocument("https://proxy.golang.org/example.com/module/@v/v1.2.3.zip")
	changed := newDocument("https://proxy.golang.org/example.com/module/@v/v1.2.4.zip")
	for _, candidate := range []*document{&first, &second, &changed} {
		if err := bindDocumentNamespace(candidate, "https://example.com/spdx/base"); err != nil {
			t.Fatal(err)
		}
	}
	if first.DocumentNamespace != second.DocumentNamespace {
		t.Fatal("identical SPDX semantics produced different document namespaces")
	}
	if first.DocumentNamespace == changed.DocumentNamespace {
		t.Fatal("download location drift did not change the SPDX document namespace")
	}
	if err := bindDocumentNamespace(&first, "https://example.com/spdx/base"); err != nil {
		t.Fatal(err)
	}
	if first.DocumentNamespace != second.DocumentNamespace {
		t.Fatal("rebinding an identical SPDX document was not deterministic")
	}
}

func TestLinkedModulesIncludesIOSOnlyDependency(t *testing.T) {
	t.Setenv("GO111MODULE", "off")
	t.Setenv("GOOS", "plan9")
	t.Setenv("GOARCH", "386")
	t.Setenv("CGO_ENABLED", "0")
	t.Setenv("GOFLAGS", "-mod=vendor")
	t.Setenv("GOWORK", filepath.Join(t.TempDir(), "hostile.work"))
	root := t.TempDir()
	dependency := filepath.Join(root, "iosdep")
	bridge := filepath.Join(root, "mobilebridge")
	for _, directory := range []string{dependency, bridge} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeLicenseTestFile(t, filepath.Join(root, "go.mod"), "module example.com/app\n\ngo 1.25\n\nrequire example.com/iosdep v0.0.0\nreplace example.com/iosdep => ./iosdep\n")
	writeLicenseTestFile(t, filepath.Join(dependency, "go.mod"), "module example.com/iosdep\n\ngo 1.25\n")
	writeLicenseTestFile(t, filepath.Join(dependency, "dep.go"), "package iosdep\n")
	writeLicenseTestFile(t, filepath.Join(bridge, "bridge.go"), "package mobilebridge\n")
	writeLicenseTestFile(t, filepath.Join(bridge, "bridge_ios.go"), "package mobilebridge\nimport _ \"example.com/iosdep\"\n")

	linked, err := linkedModules(root)
	if err != nil {
		t.Fatalf("iOS production reachability failed: %v", err)
	}
	if !linked["example.com/iosdep"] {
		t.Fatal("iOS-only dependency was omitted from production reachability")
	}
}

func TestModuleInventoryDigestBindsDevOnlyPinsAndClassification(t *testing.T) {
	contract := validatedSyncthingSource{}
	base := []module{{Path: "example.com/dev", Version: "v1.0.0", Sum: "h1:one"}}
	baseline, err := moduleInventoryDigest(base, map[string]bool{}, contract)
	if err != nil {
		t.Fatal(err)
	}
	changedVersion, err := moduleInventoryDigest(
		[]module{{Path: "example.com/dev", Version: "v1.0.1", Sum: "h1:two"}},
		map[string]bool{},
		contract,
	)
	if err != nil {
		t.Fatal(err)
	}
	linked, err := moduleInventoryDigest(base, map[string]bool{"example.com/dev": true}, contract)
	if err != nil {
		t.Fatal(err)
	}
	if baseline == changedVersion || baseline == linked {
		t.Fatal("module inventory identity ignored a dev-only pin or linked classification")
	}
}

func TestRemoteReplacementChecksumUsesEffectiveModuleSum(t *testing.T) {
	requested := module{
		Path: "example.com/requested", Version: "v1.0.0", Sum: "",
		Replace: &module{Path: "example.com/effective", Version: "v1.1.0", Sum: "h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
	}
	effective, _, local, err := moduleSource(requested, validatedSyncthingSource{})
	if err != nil || local {
		t.Fatalf("resolve remote replacement: local=%v err=%v", local, err)
	}
	if goSumDigest(effective.Sum) == "" || goSumDigest(requested.Sum) != "" {
		t.Fatal("remote replacement checksum was not sourced from the effective module")
	}
}

func writeLicenseTestFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}
