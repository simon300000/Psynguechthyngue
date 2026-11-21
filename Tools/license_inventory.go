// SPDX-License-Identifier: MIT

// license_inventory emits a deterministic SPDX 2.3 dependency snapshot from the
// exact Go module build list and the packages reachable by the mobile bridge.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

const createdAt = "2026-08-09T00:00:00Z"

type module struct {
	Path    string  `json:"Path"`
	Version string  `json:"Version"`
	Sum     string  `json:"Sum"`
	Dir     string  `json:"Dir"`
	Replace *module `json:"Replace"`
	Error   *struct {
		Err string `json:"Err"`
	} `json:"Error"`
}

type goPackage struct {
	Module *module `json:"Module"`
}

type licenseMap struct {
	SchemaVersion int            `json:"schemaVersion"`
	ReviewedAt    string         `json:"reviewedAt"`
	Scope         string         `json:"scope"`
	Entries       []licenseEntry `json:"entries"`
}

type licenseEntry struct {
	Module           string                    `json:"module"`
	Version          string                    `json:"version"`
	ResolvedModule   string                    `json:"resolvedModule,omitempty"`
	ResolvedVersion  string                    `json:"resolvedVersion,omitempty"`
	License          string                    `json:"license"`
	LicenseFiles     map[string]string         `json:"licenseFiles"`
	NoticeFiles      map[string]string         `json:"noticeFiles,omitempty"`
	SourceDelivery   string                    `json:"sourceDelivery,omitempty"`
	LocalReplacement *localReplacementEvidence `json:"localReplacement,omitempty"`
}

type localReplacementEvidence struct {
	Path              string `json:"path"`
	UpstreamCommit    string `json:"upstreamCommit"`
	UpstreamSum       string `json:"upstreamSum"`
	PatchPath         string `json:"patchPath"`
	PatchSHA256       string `json:"patchSHA256"`
	PatchedTreeSHA256 string `json:"patchedTreeSHA256"`
}

type licenseEvidence struct {
	Name      string
	SHA256    string
	Candidate string
}

type document struct {
	SPDXVersion       string         `json:"spdxVersion"`
	DataLicense       string         `json:"dataLicense"`
	SPDXID            string         `json:"SPDXID"`
	Name              string         `json:"name"`
	DocumentNamespace string         `json:"documentNamespace"`
	CreationInfo      creationInfo   `json:"creationInfo"`
	Packages          []spdxPackage  `json:"packages"`
	Relationships     []relationship `json:"relationships"`
}

type creationInfo struct {
	Created  string   `json:"created"`
	Creators []string `json:"creators"`
}

type spdxPackage struct {
	Name                  string        `json:"name"`
	SPDXID                string        `json:"SPDXID"`
	VersionInfo           string        `json:"versionInfo,omitempty"`
	DownloadLocation      string        `json:"downloadLocation"`
	FilesAnalyzed         bool          `json:"filesAnalyzed"`
	LicenseConcluded      string        `json:"licenseConcluded"`
	LicenseDeclared       string        `json:"licenseDeclared"`
	CopyrightText         string        `json:"copyrightText"`
	Comment               string        `json:"comment,omitempty"`
	Checksums             []checksum    `json:"checksums,omitempty"`
	ExternalRefs          []externalRef `json:"externalRefs,omitempty"`
	PrimaryPackagePurpose string        `json:"primaryPackagePurpose,omitempty"`
	SourceInfo            string        `json:"sourceInfo,omitempty"`
}

type checksum struct {
	Algorithm     string `json:"algorithm"`
	ChecksumValue string `json:"checksumValue"`
}

type externalRef struct {
	ReferenceCategory string `json:"referenceCategory"`
	ReferenceType     string `json:"referenceType"`
	ReferenceLocator  string `json:"referenceLocator"`
}

type relationship struct {
	SPDXElementID      string `json:"spdxElementId"`
	RelationshipType   string `json:"relationshipType"`
	RelatedSPDXElement string `json:"relatedSpdxElement"`
}

func main() {
	if len(os.Args) != 3 {
		fatal(errors.New("usage: license_inventory <GoCore directory> <controlled license map>"))
	}
	coreDir, err := filepath.Abs(os.Args[1])
	if err != nil {
		fatal(err)
	}
	controlledMap, controlledMapDigest, err := loadLicenseMap(os.Args[2])
	if err != nil {
		fatal(err)
	}
	sourceContract, err := loadSyncthingSourceContract(coreDir, true)
	if err != nil {
		fatal(err)
	}
	linked, err := linkedModules(coreDir)
	if err != nil {
		fatal(err)
	}
	modules, err := listModules(coreDir)
	if err != nil {
		fatal(err)
	}
	inventoryDigest, err := moduleInventoryDigest(modules, linked, sourceContract)
	if err != nil {
		fatal(err)
	}

	rootID := "SPDXRef-Package-Psynguechthyngue"
	namespacePrefix := "https://github.com/simon300000/Psynguechthyngue/sbom/" + sourceContract.Lock.ModuleCommit + "/" + controlledMapDigest + "/" + inventoryDigest
	doc := document{
		SPDXVersion:       "SPDX-2.3",
		DataLicense:       "CC0-1.0",
		SPDXID:            "SPDXRef-DOCUMENT",
		Name:              "Psynguechthyngue Go dependency inventory",
		DocumentNamespace: "",
		CreationInfo: creationInfo{
			Created:  createdAt,
			Creators: []string{"Tool: Psynguechthyngue license_inventory"},
		},
		Packages: []spdxPackage{{
			Name:                  "Psynguechthyngue",
			SPDXID:                rootID,
			DownloadLocation:      "NOASSERTION",
			FilesAnalyzed:         false,
			LicenseConcluded:      "MIT",
			LicenseDeclared:       "MIT",
			CopyrightText:         "Copyright (c) 2026 Simon",
			PrimaryPackagePurpose: "APPLICATION",
		}},
		Relationships: []relationship{{
			SPDXElementID:      "SPDXRef-DOCUMENT",
			RelationshipType:   "DESCRIBES",
			RelatedSPDXElement: rootID,
		}},
	}

	sort.Slice(modules, func(i, j int) bool {
		return modules[i].Path < modules[j].Path
	})
	matchedControlledEntries := make(map[string]bool)
	for _, item := range modules {
		if item.Path == "" || item.Version == "" || item.Error != nil {
			continue
		}
		effective, sourceDirectory, localPatched, err := moduleSource(item, sourceContract)
		if err != nil {
			fatal(err)
		}
		id := spdxID(item.Path)
		licenseEvidence, evidence := scanLicenses(sourceDirectory)
		declared := "NOASSERTION"
		if linked[item.Path] {
			entry, ok := controlledMap[item.Path]
			if !ok {
				fatal(fmt.Errorf("linked module %s@%s is absent from the controlled license map", item.Path, item.Version))
			}
			if err := validateLicenseEntry(entry, item, effective, licenseEvidence); err != nil {
				fatal(err)
			}
			if err := validateLocalReplacementEntry(entry, item, localPatched, sourceContract); err != nil {
				fatal(err)
			}
			matchedControlledEntries[item.Path] = true
			declared = entry.License
			evidence = "Controlled license map verified against the pinned module cache. " + evidence
		}
		version := item.Version
		if item.Replace != nil && !localPatched {
			version += " => " + item.Replace.Path + "@" + item.Replace.Version
		}
		downloadLocation := sourceURL(effective.Path, effective.Version)
		if localPatched {
			downloadLocation = syncthingCommitSourceURL(sourceContract.Lock.ModuleCommit)
		}
		pkg := spdxPackage{
			Name:             item.Path,
			SPDXID:           id,
			VersionInfo:      version,
			DownloadLocation: downloadLocation,
			FilesAnalyzed:    false,
			LicenseConcluded: "NOASSERTION",
			LicenseDeclared:  declared,
			CopyrightText:    "NOASSERTION",
			Comment:          evidence,
			ExternalRefs: []externalRef{{
				ReferenceCategory: "PACKAGE-MANAGER",
				ReferenceType:     "purl",
				ReferenceLocator:  goPURL(effective.Path, effective.Version),
			}},
		}
		if localPatched {
			pkg.Checksums = []checksum{{Algorithm: "SHA256", ChecksumValue: sourceContract.TreeSHA256}}
			pkg.SourceInfo = localReplacementSourceInfo(item, sourceContract)
		} else if digest := goSumDigest(effective.Sum); digest != "" {
			pkg.Checksums = []checksum{{Algorithm: "SHA256", ChecksumValue: digest}}
		}
		if linked[item.Path] {
			pkg.PrimaryPackagePurpose = "LIBRARY"
			doc.Relationships = append(doc.Relationships, relationship{
				SPDXElementID: rootID, RelationshipType: "DEPENDS_ON", RelatedSPDXElement: id,
			})
		} else {
			pkg.PrimaryPackagePurpose = "SOURCE"
			doc.Relationships = append(doc.Relationships, relationship{
				SPDXElementID: id, RelationshipType: "DEV_DEPENDENCY_OF", RelatedSPDXElement: rootID,
			})
		}
		doc.Packages = append(doc.Packages, pkg)
	}
	for path := range controlledMap {
		if !matchedControlledEntries[path] {
			fatal(fmt.Errorf("controlled license entry %s is not reachable from the production mobilebridge package", path))
		}
	}

	sort.Slice(doc.Relationships[1:], func(i, j int) bool {
		a, b := doc.Relationships[i+1], doc.Relationships[j+1]
		if a.RelationshipType != b.RelationshipType {
			return a.RelationshipType < b.RelationshipType
		}
		return a.RelatedSPDXElement < b.RelatedSPDXElement
	})
	if err := bindDocumentNamespace(&doc, namespacePrefix); err != nil {
		fatal(err)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(doc); err != nil {
		fatal(err)
	}
}

func bindDocumentNamespace(doc *document, prefix string) error {
	if doc == nil || prefix == "" {
		return errors.New("SPDX document namespace prefix is missing")
	}
	doc.DocumentNamespace = ""
	var canonical bytes.Buffer
	encoder := json.NewEncoder(&canonical)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(doc); err != nil {
		return fmt.Errorf("encode SPDX namespace semantics: %w", err)
	}
	digest := sha256.Sum256(bytes.TrimSuffix(canonical.Bytes(), []byte{'\n'}))
	doc.DocumentNamespace = prefix + "/" + hex.EncodeToString(digest[:])
	return nil
}

func moduleSource(item module, contract validatedSyncthingSource) (module, string, bool, error) {
	if item.Replace == nil {
		return item, item.Dir, false, nil
	}
	if item.Replace.Version != "" {
		return *item.Replace, item.Replace.Dir, false, nil
	}
	if item.Path != contract.Lock.ModulePath || item.Version != contract.Lock.ModuleVersion ||
		item.Replace.Path != contract.Lock.LocalReplacePath || item.Replace.Dir == "" {
		return module{}, "", false, fmt.Errorf("unaudited runtime local replacement for %s@%s", item.Path, item.Version)
	}
	actualDirectory, err := filepath.Abs(item.Replace.Dir)
	if err != nil {
		return module{}, "", false, fmt.Errorf("resolve runtime local replacement: %w", err)
	}
	if filepath.Clean(actualDirectory) != contract.GeneratedDir {
		return module{}, "", false, fmt.Errorf("runtime local replacement directory drift for %s", item.Path)
	}
	return item, contract.GeneratedDir, true, nil
}

func validateLocalReplacementEntry(entry licenseEntry, requested module, localPatched bool, contract validatedSyncthingSource) error {
	if requested.Path == contract.Lock.ModulePath {
		if !localPatched || entry.LocalReplacement == nil {
			return fmt.Errorf("controlled local replacement evidence is missing for %s", requested.Path)
		}
		expected := localReplacementEvidence{
			Path:              contract.Lock.LocalReplacePath,
			UpstreamCommit:    contract.Lock.ModuleCommit,
			UpstreamSum:       contract.Lock.ModuleSum,
			PatchPath:         contract.Lock.PatchPath,
			PatchSHA256:       contract.Lock.PatchSHA256,
			PatchedTreeSHA256: contract.Lock.PatchedTreeSHA256,
		}
		if *entry.LocalReplacement != expected {
			return fmt.Errorf("controlled local replacement provenance drift for %s", requested.Path)
		}
		return nil
	}
	if localPatched || entry.LocalReplacement != nil {
		return fmt.Errorf("unexpected controlled local replacement evidence for %s", requested.Path)
	}
	return nil
}

func localReplacementSourceInfo(item module, contract validatedSyncthingSource) string {
	return fmt.Sprintf(
		"Built from checksum-verified upstream %s@%s (commit %s, Go sum %s) with %s (SHA-256 %s) applied; audited patched source tree SHA-256 %s.",
		item.Path,
		item.Version,
		contract.Lock.ModuleCommit,
		contract.Lock.ModuleSum,
		contract.Lock.PatchPath,
		contract.Lock.PatchSHA256,
		contract.Lock.PatchedTreeSHA256,
	)
}

func loadLicenseMap(path string) (map[string]licenseEntry, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("read controlled license map: %w", err)
	}
	var value licenseMap
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return nil, "", fmt.Errorf("decode controlled license map: %w", err)
	}
	if value.SchemaVersion != 1 || strings.TrimSpace(value.ReviewedAt) == "" || strings.TrimSpace(value.Scope) == "" {
		return nil, "", errors.New("controlled license map metadata is incomplete")
	}
	result := make(map[string]licenseEntry, len(value.Entries))
	for _, entry := range value.Entries {
		if entry.Module == "" || entry.Version == "" {
			return nil, "", errors.New("controlled license map contains an entry without module/version")
		}
		if _, exists := result[entry.Module]; exists {
			return nil, "", fmt.Errorf("controlled license map contains duplicate module %s", entry.Module)
		}
		result[entry.Module] = entry
	}
	if len(result) == 0 {
		return nil, "", errors.New("controlled license map has no entries")
	}
	digest := sha256.Sum256(data)
	return result, hex.EncodeToString(digest[:]), nil
}

func validateLicenseEntry(entry licenseEntry, requested, effective module, evidence []licenseEvidence) error {
	if entry.Module != requested.Path || entry.Version != requested.Version {
		return fmt.Errorf("controlled license pin drift for %s: map=%s runtime=%s", requested.Path, entry.Version, requested.Version)
	}
	resolvedPath, resolvedVersion := entry.ResolvedModule, entry.ResolvedVersion
	if resolvedPath == "" {
		resolvedPath = entry.Module
	}
	if resolvedVersion == "" {
		resolvedVersion = entry.Version
	}
	if (entry.ResolvedModule == "") != (entry.ResolvedVersion == "") {
		return fmt.Errorf("controlled license replacement for %s must set both resolvedModule and resolvedVersion", entry.Module)
	}
	if resolvedPath != effective.Path || resolvedVersion != effective.Version {
		return fmt.Errorf("controlled license replacement drift for %s: map=%s@%s runtime=%s@%s", entry.Module, resolvedPath, resolvedVersion, effective.Path, effective.Version)
	}

	licenseIDs := strings.Split(entry.License, " OR ")
	if len(licenseIDs) == 0 || entry.License == "NOASSERTION" {
		return fmt.Errorf("controlled license for %s is unknown", entry.Module)
	}
	allowed := map[string]bool{
		"Apache-2.0":   true,
		"BSD-2-Clause": true,
		"BSD-3-Clause": true,
		"CC0-1.0":      true,
		"ISC":          true,
		"MIT":          true,
		"MPL-2.0":      true,
		"Unlicense":    true,
	}
	for _, id := range licenseIDs {
		if !allowed[id] {
			return fmt.Errorf("controlled license for %s contains unsupported SPDX identifier %q", entry.Module, id)
		}
	}
	if strings.Contains(entry.License, "MPL-2.0") {
		if entry.SourceDelivery != "covered-source-bundle" {
			return fmt.Errorf("MPL-covered module %s is not assigned to the covered-source bundle", entry.Module)
		}
	} else if entry.SourceDelivery != "" {
		return fmt.Errorf("non-MPL module %s has unsupported sourceDelivery %q", entry.Module, entry.SourceDelivery)
	}

	expected := make(map[string]string, len(entry.LicenseFiles)+len(entry.NoticeFiles))
	for name, digest := range entry.LicenseFiles {
		if err := addExpectedEvidence(expected, name, digest, entry.Module); err != nil {
			return err
		}
	}
	for name, digest := range entry.NoticeFiles {
		if err := addExpectedEvidence(expected, name, digest, entry.Module); err != nil {
			return err
		}
	}
	if len(entry.LicenseFiles) == 0 {
		return fmt.Errorf("controlled license for %s has no license-file evidence", entry.Module)
	}

	actual := make(map[string]licenseEvidence, len(evidence))
	for _, item := range evidence {
		actual[item.Name] = item
	}
	if len(actual) != len(expected) {
		return fmt.Errorf("root license/notice file set drift for %s: map=%d runtime=%d", entry.Module, len(expected), len(actual))
	}
	detected := make(map[string]bool)
	for name, digest := range expected {
		item, ok := actual[name]
		if !ok || item.SHA256 != digest {
			return fmt.Errorf("license/notice evidence drift for %s/%s", entry.Module, name)
		}
		if _, isLicense := entry.LicenseFiles[name]; isLicense {
			if item.Candidate == "NOASSERTION" {
				return fmt.Errorf("license text for %s/%s is not recognized", entry.Module, name)
			}
			detected[item.Candidate] = true
		}
	}
	if len(detected) != len(licenseIDs) {
		return fmt.Errorf("controlled SPDX expression does not match license texts for %s", entry.Module)
	}
	for _, id := range licenseIDs {
		if !detected[id] {
			return fmt.Errorf("controlled SPDX expression for %s is not backed by %s text", entry.Module, id)
		}
	}
	return nil
}

func addExpectedEvidence(expected map[string]string, name, digest, modulePath string) error {
	if name == "" || filepath.Base(name) != name || !isLicenseFilename(name) {
		return fmt.Errorf("unsafe license evidence filename %q for %s", name, modulePath)
	}
	if len(digest) != sha256.Size*2 {
		return fmt.Errorf("invalid license evidence digest for %s/%s", modulePath, name)
	}
	if _, err := hex.DecodeString(digest); err != nil || strings.ToLower(digest) != digest {
		return fmt.Errorf("invalid license evidence digest for %s/%s", modulePath, name)
	}
	if _, exists := expected[name]; exists {
		return fmt.Errorf("duplicate license evidence filename %s for %s", name, modulePath)
	}
	expected[name] = digest
	return nil
}

func listModules(dir string) ([]module, error) {
	command := exec.Command("go", "list", "-mod=readonly", "-m", "-json", "all")
	command.Dir = dir
	command.Env = cleanGoEnvironment(os.Environ())
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return nil, commandError(command, stderr.Bytes(), err)
	}
	decoder := json.NewDecoder(bytes.NewReader(output))
	var result []module
	for {
		var value module
		if err := decoder.Decode(&value); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, err
		}
		if err := hydrateModuleSource(dir, &value); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, nil
}

func hydrateModuleSource(dir string, item *module) error {
	if item.Path == "" || item.Version == "" {
		return nil
	}
	effective := item
	if item.Replace != nil {
		if item.Replace.Version == "" {
			return nil
		}
		effective = item.Replace
	}
	if effective.Dir != "" && effective.Sum != "" {
		return nil
	}
	command := exec.Command("go", "mod", "download", "-json", effective.Path+"@"+effective.Version)
	command.Dir = dir
	command.Env = cleanGoEnvironment(os.Environ())
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return commandError(command, stderr.Bytes(), err)
	}
	var downloaded module
	decoder := json.NewDecoder(bytes.NewReader(output))
	if err := decoder.Decode(&downloaded); err != nil {
		return fmt.Errorf("decode explicit module download for %s@%s: %w", effective.Path, effective.Version, err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return fmt.Errorf("explicit module download for %s@%s has trailing JSON", effective.Path, effective.Version)
	}
	if downloaded.Error != nil || downloaded.Path != effective.Path || downloaded.Version != effective.Version ||
		downloaded.Dir == "" || !strings.HasPrefix(downloaded.Sum, "h1:") {
		return fmt.Errorf("explicit module download evidence drift for %s@%s", effective.Path, effective.Version)
	}
	effective.Dir = downloaded.Dir
	effective.Sum = downloaded.Sum
	return nil
}

func moduleInventoryDigest(modules []module, linked map[string]bool, contract validatedSyncthingSource) (string, error) {
	type record struct {
		requested string
		version   string
		effective string
		sum       string
		linked    bool
	}
	records := make([]record, 0, len(modules))
	for _, item := range modules {
		if item.Path == "" || item.Version == "" || item.Error != nil {
			continue
		}
		effective, _, local, err := moduleSource(item, contract)
		if err != nil {
			return "", err
		}
		sum := effective.Sum
		effectivePin := effective.Path + "@" + effective.Version
		if local {
			sum = contract.Lock.PatchedTreeSHA256
			effectivePin = contract.Lock.ModulePath + "@" + contract.Lock.ModuleVersion + "+local"
		}
		records = append(records, record{
			requested: item.Path,
			version:   item.Version,
			effective: effectivePin,
			sum:       sum,
			linked:    linked[item.Path],
		})
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].requested != records[j].requested {
			return records[i].requested < records[j].requested
		}
		return records[i].version < records[j].version
	})
	digest := sha256.New()
	for _, item := range records {
		fmt.Fprintf(digest, "%s\t%s\t%s\t%s\t%t\n", item.requested, item.version, item.effective, item.sum, item.linked)
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func linkedModules(dir string) (map[string]bool, error) {
	result := make(map[string]bool)
	for _, architecture := range []string{"arm64", "amd64"} {
		command := exec.Command("go", "list", "-mod=readonly", "-tags", "noassets", "-deps", "-json", "./mobilebridge")
		command.Dir = dir
		command.Env = append(cleanGoEnvironment(os.Environ()), "GOOS=ios", "GOARCH="+architecture, "CGO_ENABLED=1")
		var stderr bytes.Buffer
		command.Stderr = &stderr
		output, err := command.Output()
		if err != nil {
			return nil, commandError(command, stderr.Bytes(), err)
		}
		decoder := json.NewDecoder(bytes.NewReader(output))
		for {
			var value goPackage
			if err := decoder.Decode(&value); errors.Is(err, io.EOF) {
				break
			} else if err != nil {
				return nil, err
			}
			if value.Module != nil && value.Module.Path != "" {
				result[value.Module.Path] = true
			}
		}
	}
	return result, nil
}

func scanLicenses(dir string) ([]licenseEvidence, string) {
	if dir == "" {
		return nil, "No module directory was available for automated license evidence."
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, "License evidence could not be read."
	}
	var detected []licenseEvidence
	var evidence []string
	for _, entry := range entries {
		if entry.IsDir() || !isLicenseFilename(entry.Name()) {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil || len(data) > 2<<20 {
			continue
		}
		digest := sha256.Sum256(data)
		candidate := detectLicense(string(data))
		digestText := hex.EncodeToString(digest[:])
		evidence = append(evidence, fmt.Sprintf("%s sha256=%s candidate=%s", entry.Name(), digestText, candidate))
		detected = append(detected, licenseEvidence{Name: entry.Name(), SHA256: digestText, Candidate: candidate})
	}
	sort.Slice(detected, func(i, j int) bool { return detected[i].Name < detected[j].Name })
	sort.Strings(evidence)
	if len(evidence) == 0 {
		return detected, "No root license/notice file was found by the automated scanner; human review required."
	}
	return detected, "Automated candidates only; human review required. Evidence: " + strings.Join(evidence, "; ")
}

func detectLicense(text string) string {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "mozilla public license") && strings.Contains(lower, "version 2.0"):
		return "MPL-2.0"
	case strings.Contains(lower, "apache license") && strings.Contains(lower, "version 2.0"):
		return "Apache-2.0"
	case strings.Contains(lower, "permission is hereby granted, free of charge"):
		return "MIT"
	case strings.Contains(lower, "permission to use, copy, modify, and/or distribute this software"):
		return "ISC"
	case strings.Contains(lower, "redistribution and use in source and binary forms") && strings.Contains(lower, "neither the name"):
		return "BSD-3-Clause"
	case strings.Contains(lower, "redistribution and use in source and binary forms"):
		return "BSD-2-Clause"
	case strings.Contains(lower, "free and unencumbered software released into the public domain"):
		return "Unlicense"
	case strings.Contains(lower, "creative commons zero v1.0 universal"):
		return "CC0-1.0"
	default:
		return "NOASSERTION"
	}
}

func isLicenseFilename(name string) bool {
	upper := strings.ToUpper(name)
	for _, prefix := range []string{"LICENSE", "LICENCE", "COPYING", "NOTICE", "PATENTS"} {
		if strings.HasPrefix(upper, prefix) {
			return true
		}
	}
	return false
}

func spdxID(path string) string {
	var builder strings.Builder
	builder.WriteString("SPDXRef-Go-")
	for _, value := range path {
		if unicode.IsLetter(value) || unicode.IsDigit(value) || value == '.' || value == '-' {
			builder.WriteRune(value)
		} else {
			builder.WriteByte('-')
		}
	}
	return builder.String()
}

func sourceURL(path, version string) string {
	return "https://proxy.golang.org/" + goProxyEscape(path) + "/@v/" + goProxyEscape(version) + ".zip"
}

func syncthingCommitSourceURL(commit string) string {
	return "https://github.com/syncthing/syncthing/tree/" + commit
}

func goProxyEscape(value string) string {
	var escaped strings.Builder
	escaped.Grow(len(value))
	for _, character := range value {
		if character >= 'A' && character <= 'Z' {
			escaped.WriteByte('!')
			escaped.WriteRune(character + ('a' - 'A'))
			continue
		}
		escaped.WriteRune(character)
	}
	return escaped.String()
}

func goPURL(path, version string) string {
	return "pkg:golang/" + path + "@" + version
}

func goSumDigest(sum string) string {
	if !strings.HasPrefix(sum, "h1:") {
		return ""
	}
	value, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(sum, "h1:"))
	if err != nil || len(value) != sha256.Size {
		return ""
	}
	return hex.EncodeToString(value)
}

func commandError(command *exec.Cmd, output []byte, err error) error {
	message := strings.TrimSpace(string(output))
	if len(message) > 2_000 {
		message = message[len(message)-2_000:]
	}
	return fmt.Errorf("%s failed: %w: %s", strings.Join(command.Args, " "), err, message)
}

func fatal(err error) {
	writer := bufio.NewWriter(os.Stderr)
	fmt.Fprintln(writer, "license inventory:", err)
	writer.Flush()
	os.Exit(1)
}
