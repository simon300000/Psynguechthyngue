#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""Build and verify deterministic license/source release materials."""

import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tarfile
import urllib.parse


BUNDLE_ROOT = "Psynguechthyngue-release-sources"
RELEASE_MATERIAL_PATHS = (
    "LICENSE",
    "NOTICE",
    "THIRD_PARTY_NOTICES.md",
    "Docs/DEPENDENCY_LICENSE_MAP.json",
    "Docs/SBOM.spdx.json",
    "Docs/LICENSE_AND_SOURCE.md",
    "GoCore/go.mod",
    "GoCore/go.sum",
    "GoCore/SyncthingSource.lock.json",
    "GoCore/Patches/syncthing-cluster-index-readiness.patch",
    "GoCore/Scripts/test-peer-interop.sh",
    "GoCore/Scripts/test-prepare-lock.sh",
    "GoCore/Scripts/prepare-syncthing-source.sh",
    "GoCore/Scripts/verify-syncthing-source.sh",
    "GoCore/Scripts/build-xcframework.sh",
    "GoCore/Scripts/build-xcframework-impl.sh",
    "GoCore/Scripts/swift-smoke.swift",
    "GoCore/Scripts/test-xcframework-provenance.sh",
    "GoCore/Scripts/xcframework-build-settings.sh",
    "GoCore/Scripts/xcframework-provenance.sh",
    "GoCore/Tools/preparelock/checkpoint_default.go",
    "GoCore/Tools/preparelock/checkpoint_preparelocktest.go",
    "GoCore/Tools/preparelock/main_other.go",
    "GoCore/Tools/preparelock/main_unix.go",
    "Scripts/bootstrap.sh",
    "Scripts/check-licenses.sh",
    "Scripts/check-project.sh",
    "Scripts/generate-sbom.sh",
    "Scripts/generate-third-party-notices.sh",
    "Scripts/hermetic-go-environment.sh",
    "Scripts/prepare-release-source.sh",
    "Scripts/test-bootstrap-no-reuse.sh",
    "Scripts/test-license-tools.sh",
    "Scripts/verify-release-licenses.sh",
    "Scripts/verify.sh",
    "Tools/license_inventory.go",
    "Tools/license_inventory_test.go",
    "Tools/license_release.py",
    "Tools/test_license_release.py",
    "Tools/syncthing_contract.go",
    "Tools/syncthing_contract_check.go",
    "Tools/syncthing_contract_test.go",
)
MAX_JSON_SIZE = 16 * 1024 * 1024
MAX_BUNDLE_FILES = 200_000
MAX_BUNDLE_BYTES = 1024 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
VERSION_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z._+-]{0,127}\Z")
MODULE_VALUE_RE = re.compile(r"[0-9A-Za-z._~+/:-]+\Z")
SYNCTHING_MODULE = "github.com/syncthing/syncthing"
LOCAL_REPLACEMENT_FIELDS = {
    "path",
    "upstreamCommit",
    "upstreamSum",
    "patchPath",
    "patchSHA256",
    "patchedTreeSHA256",
}
SYNCTHING_LOCK_FIELDS = {
    "schemaVersion",
    "modulePath",
    "moduleVersion",
    "moduleCommit",
    "moduleSum",
    "localReplaceOldVersion",
    "localReplacePath",
    "patchPath",
    "patchSHA256",
    "patchedTreeSHA256",
}


class ReleaseMaterialError(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def read_bytes(path, maximum=MAX_JSON_SIZE):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
        raise ReleaseMaterialError(f"unsafe or oversized input: {path}")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ReleaseMaterialError(f"oversized input: {path}")
        after = os.fstat(descriptor)
        stable = (
            before.st_dev == after.st_dev
            and before.st_ino == after.st_ino
            and before.st_size == after.st_size == total
            and before.st_mtime_ns == after.st_mtime_ns
            and before.st_ctime_ns == after.st_ctime_ns
        )
        if not stable:
            raise ReleaseMaterialError(f"input changed while reading: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_json(path):
    try:
        value = json.loads(read_bytes(path).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseMaterialError(f"invalid JSON input {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseMaterialError(f"JSON input is not an object: {path}")
    return value


def effective_pin(entry):
    return (
        entry.get("resolvedModule", entry["module"]),
        entry.get("resolvedVersion", entry["version"]),
    )


def source_url(module, version):
    return f"https://proxy.golang.org/{go_proxy_escape(module)}/@v/{go_proxy_escape(version)}.zip"


def go_proxy_escape(value):
    return "".join("!" + character.lower() if "A" <= character <= "Z" else character for character in value)


def entry_source_url(entry):
    local = entry.get("localReplacement")
    if local:
        return f"https://github.com/syncthing/syncthing/tree/{local['upstreamCommit']}"
    module, version = effective_pin(entry)
    return source_url(module, version)


def local_replacement_source_info(entry):
    local = entry["localReplacement"]
    return (
        f"Built from checksum-verified upstream {entry['module']}@{entry['version']} "
        f"(commit {local['upstreamCommit']}, Go sum {local['upstreamSum']}) with "
        f"{local['patchPath']} (SHA-256 {local['patchSHA256']}) applied; audited patched "
        f"source tree SHA-256 {local['patchedTreeSHA256']}."
    )


def validate_local_replacement(entry, package):
    local = entry.get("localReplacement")
    if local is None:
        if package.get("sourceInfo"):
            raise ReleaseMaterialError(f"unexpected local source provenance for {entry['module']}")
        return
    if entry["module"] != SYNCTHING_MODULE or set(local) != LOCAL_REPLACEMENT_FIELDS:
        raise ReleaseMaterialError(f"unsupported local replacement mapping for {entry['module']}")
    if local["path"] != "../.build/go/syncthing-readiness-v1":
        raise ReleaseMaterialError("Syncthing local replacement path drift")
    if local["patchPath"] != "Patches/syncthing-cluster-index-readiness.patch":
        raise ReleaseMaterialError("Syncthing local patch path drift")
    if not COMMIT_RE.fullmatch(local["upstreamCommit"]):
        raise ReleaseMaterialError("Syncthing local replacement commit is invalid")
    if not isinstance(local["upstreamSum"], str) or not local["upstreamSum"].startswith("h1:"):
        raise ReleaseMaterialError("Syncthing local replacement Go sum is invalid")
    for key in ("patchSHA256", "patchedTreeSHA256"):
        if not isinstance(local[key], str) or not SHA256_RE.fullmatch(local[key]):
            raise ReleaseMaterialError(f"Syncthing local replacement {key} is invalid")
    expected_checksums = [{"algorithm": "SHA256", "checksumValue": local["patchedTreeSHA256"]}]
    if package.get("checksums") != expected_checksums:
        raise ReleaseMaterialError("SBOM patched Syncthing tree checksum drift")
    if package.get("sourceInfo") != local_replacement_source_info(entry):
        raise ReleaseMaterialError("SBOM patched Syncthing source provenance drift")


def clean_go_environment():
    rejected = {"CGO_ENABLED", "GO111MODULE", "GOARCH", "GOENV", "GOFLAGS", "GOOS", "GOWORK"}
    environment = {key: value for key, value in os.environ.items() if key not in rejected}
    environment.update({"GO111MODULE": "on", "GOENV": "off", "GOFLAGS": "", "GOWORK": "off"})
    return environment


def validate_repository_syncthing_contract(project_root, map_path, mapped):
    local_entries = [entry for entry in mapped.values() if entry.get("localReplacement")]
    if len(local_entries) != 1 or local_entries[0]["module"] != SYNCTHING_MODULE:
        raise ReleaseMaterialError("repository must contain exactly one audited Syncthing local replacement")

    root = os.path.abspath(project_root)
    expected_map = os.path.join(root, "Docs", "DEPENDENCY_LICENSE_MAP.json")
    if os.path.abspath(map_path) != expected_map:
        raise ReleaseMaterialError("local replacement map is not rooted in the release project")
    core = os.path.join(root, "GoCore")
    lock = read_json(os.path.join(core, "SyncthingSource.lock.json"))
    if set(lock) != SYNCTHING_LOCK_FIELDS or lock.get("schemaVersion") != 1:
        raise ReleaseMaterialError("Syncthing source lock schema is incomplete or unknown")

    entry = local_entries[0]
    local = entry["localReplacement"]
    expected = {
        "modulePath": entry["module"],
        "moduleVersion": entry["version"],
        "moduleCommit": local["upstreamCommit"],
        "moduleSum": local["upstreamSum"],
        "localReplaceOldVersion": "",
        "localReplacePath": local["path"],
        "patchPath": local["patchPath"],
        "patchSHA256": local["patchSHA256"],
        "patchedTreeSHA256": local["patchedTreeSHA256"],
    }
    for key, value in expected.items():
        if lock.get(key) != value:
            raise ReleaseMaterialError(f"repository Syncthing lock drift for {key}")

    patch = os.path.join(core, *pathlib.PurePosixPath(local["patchPath"]).parts)
    if sha256_bytes(read_bytes(patch, maximum=128 * 1024 * 1024)) != local["patchSHA256"]:
        raise ReleaseMaterialError("repository Syncthing patch digest drift")

    edit = subprocess.run(
        ["go", "mod", "edit", "-json", os.path.join(core, "go.mod")],
        check=False,
        capture_output=True,
        text=True,
        env=clean_go_environment(),
    )
    if edit.returncode != 0:
        raise ReleaseMaterialError(f"repository go.mod parse failed: {edit.stderr.strip()[-2000:]}")
    try:
        go_mod = json.loads(edit.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseMaterialError("repository go.mod JSON is malformed") from error
    required = [item for item in go_mod.get("Require", []) if item.get("Path") == SYNCTHING_MODULE]
    if len(required) != 1 or required[0].get("Version") != entry["version"]:
        raise ReleaseMaterialError("repository Syncthing require pin drift")
    local_replacements = [
        item for item in go_mod.get("Replace", []) if not item.get("New", {}).get("Version")
    ]
    if len(local_replacements) != 1:
        raise ReleaseMaterialError("repository must contain exactly one local Go replacement")
    replacement = local_replacements[0]
    old = replacement.get("Old", {})
    new = replacement.get("New", {})
    if (
        old.get("Path") != SYNCTHING_MODULE
        or old.get("Version", "") != ""
        or new.get("Path") != local["path"]
    ):
        raise ReleaseMaterialError("repository local Go replacement drift")

    verifier = os.path.join(core, "Scripts", "verify-syncthing-source.sh")
    verified = subprocess.run(
        ["sh", verifier, "--verify"],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
        env=clean_go_environment(),
    )
    if verified.returncode != 0:
        raise ReleaseMaterialError(
            f"repository Syncthing source contract failed: {verified.stderr.strip()[-2000:]}"
        )


def load_inputs(map_path, sbom_path, project_root=None, require_repository_contract=True):
    license_map = read_json(map_path)
    sbom = read_json(sbom_path)
    if license_map.get("schemaVersion") != 1 or not license_map.get("reviewedAt"):
        raise ReleaseMaterialError("controlled license map metadata is incomplete")
    entries = license_map.get("entries")
    packages = sbom.get("packages")
    relationships = sbom.get("relationships")
    if not isinstance(entries, list) or not isinstance(packages, list) or not isinstance(relationships, list):
        raise ReleaseMaterialError("license map or SBOM collections are malformed")

    mapped = {}
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("module"):
            raise ReleaseMaterialError("license map contains a malformed entry")
        if entry["module"] in mapped:
            raise ReleaseMaterialError(f"duplicate mapped module: {entry['module']}")
        mapped[entry["module"]] = entry

    package_by_id = {package.get("SPDXID"): package for package in packages}
    linked = {}
    for relationship in relationships:
        if relationship.get("relationshipType") != "DEPENDS_ON":
            continue
        package = package_by_id.get(relationship.get("relatedSpdxElement"))
        if not package:
            raise ReleaseMaterialError("SBOM dependency relationship references a missing package")
        linked[package.get("name")] = package
    if set(mapped) != set(linked):
        missing = sorted(set(linked) - set(mapped))
        extra = sorted(set(mapped) - set(linked))
        raise ReleaseMaterialError(f"license map/SBOM scope drift; missing={missing} extra={extra}")

    for module, entry in mapped.items():
        package = linked[module]
        expected_version = entry["version"]
        resolved_module, resolved_version = effective_pin(entry)
        if resolved_module != module or resolved_version != expected_version:
            expected_version += f" => {resolved_module}@{resolved_version}"
        if package.get("versionInfo") != expected_version:
            raise ReleaseMaterialError(f"SBOM version drift for {module}")
        if package.get("licenseDeclared") != entry.get("license") or entry.get("license") == "NOASSERTION":
            raise ReleaseMaterialError(f"SBOM license drift or unknown license for {module}")
        if package.get("downloadLocation") != entry_source_url(entry):
            raise ReleaseMaterialError(f"SBOM source location drift for {module}")
        validate_local_replacement(entry, package)
        if "MPL-2.0" in entry["license"] and entry.get("sourceDelivery") != "covered-source-bundle":
            raise ReleaseMaterialError(f"MPL source delivery is not fail-closed for {module}")
        evidence = {}
        for role, key in (("license", "licenseFiles"), ("notice", "noticeFiles")):
            for name, digest in entry.get(key, {}).items():
                if pathlib.PurePosixPath(name).name != name or not SHA256_RE.fullmatch(digest):
                    raise ReleaseMaterialError(f"unsafe evidence mapping for {module}/{name}")
                if name in evidence:
                    raise ReleaseMaterialError(f"duplicate evidence mapping for {module}/{name}")
                evidence[name] = (role, digest)
        if not entry.get("licenseFiles"):
            raise ReleaseMaterialError(f"license evidence is absent for {module}")
    if require_repository_contract:
        if project_root is None:
            project_root = os.path.dirname(os.path.dirname(os.path.abspath(map_path)))
        validate_repository_syncthing_contract(project_root, map_path, mapped)
    return license_map, sbom, mapped, linked


def render_notices(map_path, sbom_path):
    license_map, _, mapped, linked = load_inputs(map_path, sbom_path)
    covered = [entry for entry in mapped.values() if entry.get("sourceDelivery") == "covered-source-bundle"]
    covered_text = ", ".join(f"`{entry['module']}@{entry['version']}`" for entry in covered)
    lines = [
        "# Third-party notices",
        "",
        f"Controlled inventory review date: {license_map['reviewedAt']}",
        "",
        (
            "This file lists every Go module reachable from the production `mobilebridge` package under "
            "the pinned `noassets` build. It is generated from `Docs/DEPENDENCY_LICENSE_MAP.json` and "
            "`Docs/SBOM.spdx.json`; `make licenses` rejects dependency, version, replacement, license-file, "
            "notice-file, or source-location drift."
        ),
        "",
        (
            "The map records engineering evidence from exact files in the pinned Go module cache. It is "
            "not a legal opinion. A release still requires a published, release-specific source offer and "
            "release-owner review; use `make release-licenses SOURCE_OFFER=...` after publishing the archive."
        ),
        "",
        "## Project identity and trademark",
        "",
        (
            "Psynguechthyngue is an independent, unofficial client. It is not affiliated with, endorsed by, "
            "or sponsored by the Syncthing project. “Syncthing” identifies the embedded software and protocol "
            "compatibility only; this project does not use the Syncthing logo."
        ),
        "",
        "## Recipient materials and corresponding source",
        "",
        (
            "`make source-bundle` creates a deterministic archive containing the exact license/NOTICE/PATENTS "
            "files for all modules below and the complete module-cache source trees for every MPL-2.0 module. "
            "The archive embeds a manifest with per-file and per-tree SHA-256 values."
        ),
        "",
        f"MPL-covered source bundled: {covered_text}.",
        "",
        "Versioned upstream locations remain provenance and source-acquisition references for every module; "
        "they do not replace the project-controlled release archive required before binary distribution.",
        "",
        "## Production-linked Go modules",
        "",
        "| Requested module | Effective source | License | Exact recipient files |",
        "| --- | --- | --- | --- |",
    ]
    for module in sorted(mapped):
        entry = mapped[module]
        package = linked[module]
        resolved_module, resolved_version = effective_pin(entry)
        requested = f"`{module}@{entry['version']}`"
        effective = f"[`{resolved_module}@{resolved_version}`]({package['downloadLocation']})"
        if entry.get("localReplacement"):
            local = entry["localReplacement"]
            effective += (
                f" + `{local['patchPath']}` (`{local['patchSHA256']}`); "
                f"patched tree `{local['patchedTreeSHA256']}`"
            )
        evidence = []
        for role, key in (("license", "licenseFiles"), ("notice", "noticeFiles")):
            for name, digest in sorted(entry.get(key, {}).items()):
                evidence.append(f"`{name}` ({role}, `{digest}`)")
        lines.append(f"| {requested} | {effective} | `{entry['license']}` | {'<br>'.join(evidence)} |")
    lines.extend(
        [
            "",
            "## Build-only and non-production modules",
            "",
            (
                "The SPDX document also records the exact Go module build list and classifies modules not "
                "reachable from `mobilebridge` as `DEV_DEPENDENCY_OF`. In particular, `gomobile`/`gobind` are "
                "build tools, not embedded app libraries. If the production reachability graph changes, the "
                "controlled map must be reviewed before the gate can pass."
            ),
            "",
            "This document records engineering release controls and is not legal advice.",
        ]
    )
    return "\n".join(lines) + "\n"


def decode_json_stream(data):
    decoder = json.JSONDecoder()
    offset = 0
    values = []
    while offset < len(data):
        while offset < len(data) and data[offset].isspace():
            offset += 1
        if offset == len(data):
            break
        value, offset = decoder.raw_decode(data, offset)
        values.append(value)
    return values


def module_directories(go_core, mapped):
    for architecture in ("arm64", "amd64"):
        environment = clean_go_environment()
        environment.update({"GOOS": "ios", "GOARCH": architecture, "CGO_ENABLED": "1"})
        reachable = subprocess.run(
            ["go", "list", "-mod=readonly", "-tags", "noassets", "-deps", "./mobilebridge"],
            cwd=go_core,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        if reachable.returncode != 0:
            detail = reachable.stderr.strip()[-2000:]
            raise ReleaseMaterialError(f"Go production reachability failed: {detail}")
    command = ["go", "list", "-mod=readonly", "-m", "-json", "all"]
    result = subprocess.run(
        command,
        cwd=go_core,
        check=False,
        capture_output=True,
        text=True,
        env=clean_go_environment(),
    )
    if result.returncode != 0:
        detail = result.stderr.strip()[-2000:]
        raise ReleaseMaterialError(f"go list module inventory failed: {detail}")
    directories = {}
    runtime_local_replacements = []
    for value in decode_json_stream(result.stdout):
        replacement = value.get("Replace")
        local = replacement if replacement and not replacement.get("Version") else None
        if local:
            runtime_local_replacements.append(
                (value.get("Path"), value.get("Version"), local.get("Path"), local.get("Dir"))
            )
            path = value.get("Path")
            version = value.get("Version")
            directory = local.get("Dir")
        else:
            effective = replacement or value
            path = effective.get("Path")
            version = effective.get("Version")
            directory = effective.get("Dir")
        if path and version and directory:
            directories[(path, version)] = {
                "directory": directory,
                "localReplacement": local,
            }
    expected_local = [
        (entry["module"], entry["version"], entry["localReplacement"]["path"])
        for entry in mapped.values()
        if entry.get("localReplacement")
    ]
    actual_local = [(module, version, path) for module, version, path, _ in runtime_local_replacements]
    if actual_local != expected_local:
        raise ReleaseMaterialError(
            f"runtime local replacement scope drift; expected={expected_local} actual={actual_local}"
        )
    return directories


def safe_module_root(prefix, module, version):
    if not MODULE_VALUE_RE.fullmatch(module) or not MODULE_VALUE_RE.fullmatch(version):
        raise ReleaseMaterialError(f"unsafe module path/version: {module}@{version}")
    parts = pathlib.PurePosixPath(module).parts
    if any(part in ("", ".", "..") for part in parts):
        raise ReleaseMaterialError(f"unsafe module path: {module}")
    return "/".join((BUNDLE_ROOT, prefix, *parts[:-1], parts[-1] + "@" + version))


def stable_source_files(directory):
    root_info = os.lstat(directory)
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
        raise ReleaseMaterialError("module cache directory is unsafe")
    files = []
    total = 0
    for current, directories, names in os.walk(directory, topdown=True, followlinks=False):
        directories.sort()
        names.sort()
        for child in directories:
            info = os.lstat(os.path.join(current, child))
            if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise ReleaseMaterialError("module source contains a symlink or special directory")
        for name in names:
            path = os.path.join(current, name)
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise ReleaseMaterialError("module source contains a symlink or special file")
            relative = pathlib.Path(path).relative_to(directory).as_posix()
            data = read_bytes(path, maximum=128 * 1024 * 1024)
            total += len(data)
            if len(files) >= MAX_BUNDLE_FILES or total > MAX_BUNDLE_BYTES:
                raise ReleaseMaterialError("covered source exceeds bundle safety limits")
            files.append((relative, data, sha256_bytes(data), bool(info.st_mode & 0o111)))
    files.sort(key=lambda item: item[0])
    return files


def tree_digest(files):
    digest = hashlib.sha256()
    for relative, data, file_digest, _ in files:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\0")
        digest.update(str(len(data)).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def audited_tree_digest(files):
    digest = hashlib.sha256()
    for relative, data, file_digest, _ in files:
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\t")
        digest.update(str(len(data)).encode("ascii"))
        digest.update(b"\t")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def package_sha256_checksum(package):
    checksums = package.get("checksums")
    if not isinstance(checksums, list):
        raise ReleaseMaterialError(f"SBOM package checksum is absent for {package.get('name')}")
    values = [
        item.get("checksumValue")
        for item in checksums
        if isinstance(item, dict) and item.get("algorithm") == "SHA256"
    ]
    if len(values) != 1 or not isinstance(values[0], str) or not SHA256_RE.fullmatch(values[0]):
        raise ReleaseMaterialError(f"SBOM package SHA-256 is malformed for {package.get('name')}")
    return values[0]


def go_h1_sha256(files, module, version):
    prefix = f"{module}@{version}/"
    named = []
    for relative, _, file_digest, _ in files:
        if not relative or relative.startswith("/") or "\n" in relative:
            raise ReleaseMaterialError("covered source contains an unsafe Go module path")
        named.append((prefix + relative, file_digest))
    digest = hashlib.sha256()
    for name, file_digest in sorted(named):
        digest.update(f"{file_digest}  {name}\n".encode("utf-8"))
    return digest.hexdigest()


def tar_info(name, size=0, executable=False, directory=False):
    info = tarfile.TarInfo(name + ("/" if directory and not name.endswith("/") else ""))
    info.size = size
    info.mode = 0o755 if directory or executable else 0o644
    if directory:
        info.type = tarfile.DIRTYPE
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    return info


def add_parent_directories(archive, names):
    directories = {BUNDLE_ROOT}
    for name in names:
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) not in (".", ""):
            directories.add(str(parent))
            parent = parent.parent
    for name in sorted(directories, key=lambda value: (value.count("/"), value)):
        archive.addfile(tar_info(name, directory=True))


def release_materials(project_root, map_path, sbom_path):
    root = os.path.abspath(project_root)
    root_info = os.lstat(root)
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
        raise ReleaseMaterialError("project root is unsafe")
    expected_map = os.path.join(root, "Docs", "DEPENDENCY_LICENSE_MAP.json")
    expected_sbom = os.path.join(root, "Docs", "SBOM.spdx.json")
    if os.path.abspath(map_path) != expected_map or os.path.abspath(sbom_path) != expected_sbom:
        raise ReleaseMaterialError("license map and SBOM must be the project release materials")

    materials = []
    for relative in RELEASE_MATERIAL_PATHS:
        path = os.path.join(root, *pathlib.PurePosixPath(relative).parts)
        data = read_bytes(path)
        archive_path = f"{BUNDLE_ROOT}/release-materials/{relative}"
        materials.append(
            (
                {
                    "archivePath": archive_path,
                    "path": relative,
                    "sha256": sha256_bytes(data),
                },
                data,
            )
        )
    return materials


def build_bundle(map_path, sbom_path, go_core, project_root, output):
    license_map, _, mapped, linked = load_inputs(map_path, sbom_path, project_root)
    directories = module_directories(go_core, mapped)
    archive_files = {}
    release_material_records = []
    for record, data in release_materials(project_root, map_path, sbom_path):
        archive_files[record["archivePath"]] = (data, False)
        release_material_records.append(record)
    manifest_modules = []
    for module in sorted(mapped):
        entry = mapped[module]
        resolved_module, resolved_version = effective_pin(entry)
        lookup_pin = (module, entry["version"]) if entry.get("localReplacement") else (resolved_module, resolved_version)
        source_record = directories.get(lookup_pin)
        if not source_record:
            raise ReleaseMaterialError(f"pinned module is absent from the local Go module cache: {resolved_module}@{resolved_version}")
        directory = source_record["directory"]
        local = entry.get("localReplacement")
        runtime_local = source_record.get("localReplacement")
        if local:
            expected_directory = os.path.abspath(os.path.join(go_core, local["path"]))
            if (
                not runtime_local
                or runtime_local.get("Path") != local["path"]
                or os.path.abspath(directory) != expected_directory
            ):
                raise ReleaseMaterialError(f"runtime local replacement drift for {module}")
        elif runtime_local:
            raise ReleaseMaterialError(f"unexpected runtime local replacement for {module}")
        material_root = safe_module_root("third-party-materials", resolved_module, resolved_version)
        material_entries = []
        for role, key in (("license", "licenseFiles"), ("notice", "noticeFiles")):
            for name, expected_digest in sorted(entry.get(key, {}).items()):
                data = read_bytes(os.path.join(directory, name), maximum=2 * 1024 * 1024)
                if sha256_bytes(data) != expected_digest:
                    raise ReleaseMaterialError(f"mapped evidence drift for {module}/{name}")
                archive_name = material_root + "/" + name
                archive_files[archive_name] = (data, False)
                material_entries.append(
                    {"archivePath": archive_name, "path": name, "role": role, "sha256": expected_digest}
                )
        record = {
            "license": entry["license"],
            "materials": material_entries,
            "module": module,
            "sourceURL": linked[module]["downloadLocation"],
            "version": entry["version"],
            "resolvedModule": resolved_module,
            "resolvedVersion": resolved_version,
        }
        if local:
            record["localReplacement"] = local
        if entry.get("sourceDelivery") == "covered-source-bundle":
            source_root = safe_module_root("covered-source", resolved_module, resolved_version)
            source_files = stable_source_files(directory)
            if local and audited_tree_digest(source_files) != local["patchedTreeSHA256"]:
                raise ReleaseMaterialError(f"audited patched source tree drift for {module}")
            if not local:
                expected_go_hash = package_sha256_checksum(linked[module])
                actual_go_hash = go_h1_sha256(source_files, resolved_module, resolved_version)
                if actual_go_hash != expected_go_hash:
                    raise ReleaseMaterialError(f"covered source Go checksum drift for {module}")
                record["coveredSourceGoH1SHA256"] = actual_go_hash
            for relative, data, _, executable in source_files:
                archive_files[source_root + "/" + relative] = (data, executable)
            record.update(
                {
                    "coveredSourceFileCount": len(source_files),
                    "coveredSourceRoot": source_root,
                    "coveredSourceTreeSHA256": tree_digest(source_files),
                }
            )
        manifest_modules.append(record)

    map_data = read_bytes(map_path)
    sbom_data = read_bytes(sbom_path)
    manifest = {
        "schemaVersion": 1,
        "bundleRoot": BUNDLE_ROOT,
        "licenseMapSHA256": sha256_bytes(map_data),
        "sbomSHA256": sha256_bytes(sbom_data),
        "scope": license_map["scope"],
        "releaseMaterials": release_material_records,
        "modules": manifest_modules,
    }
    manifest_name = BUNDLE_ROOT + "/SOURCE_MANIFEST.json"
    archive_files[manifest_name] = (canonical_json(manifest), False)
    output_parent = os.path.dirname(os.path.abspath(output))
    os.makedirs(output_parent, exist_ok=True)
    temporary = output + ".tmp"
    try:
        with open(temporary, "xb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    add_parent_directories(archive, archive_files)
                    for name in sorted(archive_files):
                        data, executable = archive_files[name]
                        archive.addfile(tar_info(name, len(data), executable=executable), io.BytesIO(data))
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(temporary, output)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return manifest


def safe_archive_name(name):
    path = pathlib.PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts and path.parts[0] == BUNDLE_ROOT


def read_bundle(archive_path):
    archive_size = os.lstat(archive_path).st_size
    if archive_size > MAX_BUNDLE_BYTES:
        raise ReleaseMaterialError("source bundle exceeds safety limit")
    files = {}
    total = 0
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for member in archive:
                if not safe_archive_name(member.name) or member.name in files:
                    raise ReleaseMaterialError("source bundle contains an unsafe or duplicate path")
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ReleaseMaterialError("source bundle contains links or special files")
                total += member.size
                if len(files) >= MAX_BUNDLE_FILES or total > MAX_BUNDLE_BYTES:
                    raise ReleaseMaterialError("source bundle exceeds extraction safety limits")
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseMaterialError("source bundle member could not be read")
                data = source.read(MAX_BUNDLE_BYTES + 1)
                if len(data) != member.size:
                    raise ReleaseMaterialError("source bundle member size mismatch")
                files[member.name] = data
    except (tarfile.TarError, OSError) as error:
        raise ReleaseMaterialError(f"invalid source bundle: {error}") from error
    manifest_name = BUNDLE_ROOT + "/SOURCE_MANIFEST.json"
    if manifest_name not in files:
        raise ReleaseMaterialError("source bundle manifest is missing")
    try:
        manifest = json.loads(files[manifest_name].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseMaterialError("source bundle manifest is invalid") from error
    return manifest, files


def verify_bundle(
    map_path,
    sbom_path,
    project_root,
    archive_path,
    require_repository_contract=True,
):
    license_map, _, mapped, linked = load_inputs(
        map_path,
        sbom_path,
        project_root,
        require_repository_contract=require_repository_contract,
    )
    manifest, files = read_bundle(archive_path)
    if set(manifest) != {
        "schemaVersion",
        "bundleRoot",
        "licenseMapSHA256",
        "sbomSHA256",
        "scope",
        "releaseMaterials",
        "modules",
    }:
        raise ReleaseMaterialError("source bundle manifest fields are incomplete or unknown")
    if manifest.get("schemaVersion") != 1 or manifest.get("bundleRoot") != BUNDLE_ROOT:
        raise ReleaseMaterialError("source bundle manifest schema is unsupported")
    if manifest.get("licenseMapSHA256") != sha256_bytes(read_bytes(map_path)):
        raise ReleaseMaterialError("source bundle license-map digest drift")
    if manifest.get("sbomSHA256") != sha256_bytes(read_bytes(sbom_path)):
        raise ReleaseMaterialError("source bundle SBOM digest drift")
    if manifest.get("scope") != license_map["scope"]:
        raise ReleaseMaterialError("source bundle scope drift")
    records = manifest.get("modules")
    if not isinstance(records, list):
        raise ReleaseMaterialError("source bundle module manifest is malformed")
    by_module = {record.get("module"): record for record in records if isinstance(record, dict)}
    if len(by_module) != len(records) or set(by_module) != set(mapped):
        raise ReleaseMaterialError("source bundle module scope drift")
    expected_files = {BUNDLE_ROOT + "/SOURCE_MANIFEST.json"}
    release_records = manifest.get("releaseMaterials")
    if not isinstance(release_records, list):
        raise ReleaseMaterialError("source bundle release materials are malformed")
    release_by_path = {
        record.get("path"): record for record in release_records if isinstance(record, dict)
    }
    expected_release_materials = release_materials(project_root, map_path, sbom_path)
    if len(release_by_path) != len(release_records) or set(release_by_path) != set(RELEASE_MATERIAL_PATHS):
        raise ReleaseMaterialError("source bundle release material scope drift")
    for expected_record, data in expected_release_materials:
        relative = expected_record["path"]
        record = release_by_path[relative]
        if record != expected_record:
            raise ReleaseMaterialError(f"source bundle release material metadata drift for {relative}")
        archive_name = expected_record["archivePath"]
        if archive_name not in files or sha256_bytes(files[archive_name]) != expected_record["sha256"]:
            raise ReleaseMaterialError(f"source bundle release material digest drift for {relative}")
        if files[archive_name] != data:
            raise ReleaseMaterialError(f"source bundle release material content drift for {relative}")
        expected_files.add(archive_name)
    for module, entry in mapped.items():
        record = by_module[module]
        resolved_module, resolved_version = effective_pin(entry)
        expected_scalars = {
            "license": entry["license"],
            "version": entry["version"],
            "resolvedModule": resolved_module,
            "resolvedVersion": resolved_version,
            "sourceURL": linked[module]["downloadLocation"],
        }
        for key, expected in expected_scalars.items():
            if record.get(key) != expected:
                raise ReleaseMaterialError(f"source bundle metadata drift for {module}/{key}")
        local = entry.get("localReplacement")
        if local:
            if record.get("localReplacement") != local:
                raise ReleaseMaterialError(f"source bundle local replacement provenance drift for {module}")
        elif "localReplacement" in record:
            raise ReleaseMaterialError(f"non-local module unexpectedly records a local replacement: {module}")
        materials = record.get("materials")
        if not isinstance(materials, list):
            raise ReleaseMaterialError(f"source bundle materials are missing for {module}")
        material_by_name = {material.get("path"): material for material in materials if isinstance(material, dict)}
        expected_materials = dict(entry.get("licenseFiles", {}))
        expected_materials.update(entry.get("noticeFiles", {}))
        if len(material_by_name) != len(materials) or set(material_by_name) != set(expected_materials):
            raise ReleaseMaterialError(f"source bundle material scope drift for {module}")
        for name, digest in expected_materials.items():
            material = material_by_name[name]
            archive_name = material.get("archivePath")
            material_root = safe_module_root("third-party-materials", resolved_module, resolved_version)
            if archive_name != material_root + "/" + name or archive_name not in files:
                raise ReleaseMaterialError(f"source bundle material path is unsafe for {module}/{name}")
            if material.get("sha256") != digest or sha256_bytes(files[archive_name]) != digest:
                raise ReleaseMaterialError(f"source bundle material digest drift for {module}/{name}")
            expected_role = "license" if name in entry.get("licenseFiles", {}) else "notice"
            if material.get("role") != expected_role:
                raise ReleaseMaterialError(f"source bundle material role drift for {module}/{name}")
            expected_files.add(archive_name)
        source_root = record.get("coveredSourceRoot")
        if entry.get("sourceDelivery") == "covered-source-bundle":
            expected_source_root = safe_module_root("covered-source", resolved_module, resolved_version)
            if source_root != expected_source_root:
                raise ReleaseMaterialError(f"covered source root is unsafe for {module}")
            source_items = []
            prefix = source_root + "/"
            for name, data in sorted(files.items()):
                if name.startswith(prefix):
                    relative = name[len(prefix) :]
                    source_items.append((relative, data, sha256_bytes(data), False))
                    expected_files.add(name)
            if record.get("coveredSourceFileCount") != len(source_items):
                raise ReleaseMaterialError(f"covered source file count drift for {module}")
            if record.get("coveredSourceTreeSHA256") != tree_digest(source_items):
                raise ReleaseMaterialError(f"covered source tree digest drift for {module}")
            if local and audited_tree_digest(source_items) != local["patchedTreeSHA256"]:
                raise ReleaseMaterialError(f"covered source does not match the audited patched tree for {module}")
            if local:
                if "coveredSourceGoH1SHA256" in record:
                    raise ReleaseMaterialError(f"locally patched source records an upstream Go checksum for {module}")
            else:
                expected_go_hash = package_sha256_checksum(linked[module])
                actual_go_hash = go_h1_sha256(source_items, resolved_module, resolved_version)
                if actual_go_hash != expected_go_hash or record.get("coveredSourceGoH1SHA256") != expected_go_hash:
                    raise ReleaseMaterialError(f"covered source does not match the SBOM Go checksum for {module}")
            for name, digest in expected_materials.items():
                source_name = prefix + name
                if source_name not in files or sha256_bytes(files[source_name]) != digest:
                    raise ReleaseMaterialError(f"covered source omits mapped evidence for {module}/{name}")
        elif source_root is not None:
            raise ReleaseMaterialError(f"non-MPL module unexpectedly has covered source: {module}")
    if set(files) != expected_files:
        raise ReleaseMaterialError("source bundle contains unmanifested files")
    return manifest


def validate_https_url(value, archive_filename=None):
    if not isinstance(value, str) or "REPLACE" in value.upper():
        raise ReleaseMaterialError("source offer contains a placeholder URL")
    parsed = urllib.parse.urlsplit(value)
    host = (parsed.hostname or "").lower()
    if (
        parsed.scheme != "https"
        or not host
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or host == "localhost"
        or host.endswith(".invalid")
    ):
        raise ReleaseMaterialError("source offer URL must be stable public HTTPS without credentials/query/fragment")
    if archive_filename and pathlib.PurePosixPath(urllib.parse.unquote(parsed.path)).name != archive_filename:
        raise ReleaseMaterialError("source URL does not end with the offered archive filename")
    return value


def load_offer(offer_path):
    offer = read_json(offer_path)
    expected_keys = {
        "schemaVersion",
        "releaseVersion",
        "releaseCommit",
        "publishedAt",
        "sourceArchiveFilename",
        "sourceArchiveSHA256",
        "sourceURL",
        "noticesURL",
        "licenseMapSHA256",
        "sbomSHA256",
    }
    if set(offer) != expected_keys or offer.get("schemaVersion") != 1:
        raise ReleaseMaterialError("source offer schema is incomplete or has unknown fields")
    if not VERSION_RE.fullmatch(str(offer.get("releaseVersion", ""))):
        raise ReleaseMaterialError("source offer release version is invalid")
    if not COMMIT_RE.fullmatch(str(offer.get("releaseCommit", ""))):
        raise ReleaseMaterialError("source offer release commit is invalid")
    filename = offer.get("sourceArchiveFilename")
    if not isinstance(filename, str) or pathlib.PurePosixPath(filename).name != filename or not filename.endswith(".tar.gz"):
        raise ReleaseMaterialError("source offer archive filename is unsafe")
    if offer["releaseVersion"] not in filename:
        raise ReleaseMaterialError("source offer archive filename is not release-specific")
    for key in ("sourceArchiveSHA256", "licenseMapSHA256", "sbomSHA256"):
        if not SHA256_RE.fullmatch(str(offer.get(key, ""))):
            raise ReleaseMaterialError(f"source offer {key} is invalid")
    validate_https_url(offer.get("sourceURL"), filename)
    validate_https_url(offer.get("noticesURL"))
    try:
        published = datetime.datetime.fromisoformat(offer["publishedAt"].replace("Z", "+00:00"))
    except (TypeError, ValueError) as error:
        raise ReleaseMaterialError("source offer publication time is invalid") from error
    if published.tzinfo is None:
        raise ReleaseMaterialError("source offer publication time must include a timezone")
    return offer


def verify_offer(map_path, sbom_path, project_root, archive_path, offer_path, expected_commit):
    offer = load_offer(offer_path)
    if offer["releaseCommit"] != expected_commit:
        raise ReleaseMaterialError("source offer release commit does not match the release checkout")
    archive_digest = sha256_bytes(read_bytes(archive_path, maximum=MAX_BUNDLE_BYTES))
    if archive_digest != offer["sourceArchiveSHA256"]:
        raise ReleaseMaterialError("downloaded archive digest does not match the source offer")
    if offer["licenseMapSHA256"] != sha256_bytes(read_bytes(map_path)):
        raise ReleaseMaterialError("source offer license-map digest drift")
    if offer["sbomSHA256"] != sha256_bytes(read_bytes(sbom_path)):
        raise ReleaseMaterialError("source offer SBOM digest drift")
    verify_bundle(map_path, sbom_path, project_root, archive_path)
    return offer


def parse_arguments():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("render-notices", "bundle", "verify-bundle", "offer-url", "verify-offer"):
        child = subparsers.add_parser(command)
        child.add_argument("--map", required=command not in ("offer-url",))
        child.add_argument("--sbom", required=command not in ("offer-url",))
        if command == "bundle":
            child.add_argument("--go-core", required=True)
            child.add_argument("--project-root", required=True)
            child.add_argument("--output", required=True)
        elif command == "verify-bundle":
            child.add_argument("--project-root", required=True)
            child.add_argument("--archive", required=True)
        elif command == "offer-url":
            child.add_argument("--offer", required=True)
            child.add_argument("--field", required=True, choices=("sourceURL", "noticesURL"))
        elif command == "verify-offer":
            child.add_argument("--project-root", required=True)
            child.add_argument("--archive", required=True)
            child.add_argument("--offer", required=True)
            child.add_argument("--expected-commit", required=True)
    return parser.parse_args()


def main():
    arguments = parse_arguments()
    try:
        if arguments.command == "render-notices":
            sys.stdout.write(render_notices(arguments.map, arguments.sbom))
        elif arguments.command == "bundle":
            manifest = build_bundle(
                arguments.map,
                arguments.sbom,
                arguments.go_core,
                arguments.project_root,
                arguments.output,
            )
            print(
                f"Created deterministic release source bundle with {len(manifest['modules'])} linked modules: "
                f"{arguments.output}"
            )
        elif arguments.command == "verify-bundle":
            manifest = verify_bundle(
                arguments.map,
                arguments.sbom,
                arguments.project_root,
                arguments.archive,
            )
            covered = sum(1 for module in manifest["modules"] if "coveredSourceRoot" in module)
            print(f"Verified release source bundle: {len(manifest['modules'])} modules, {covered} covered source trees.")
        elif arguments.command == "offer-url":
            print(load_offer(arguments.offer)[arguments.field])
        elif arguments.command == "verify-offer":
            offer = verify_offer(
                arguments.map,
                arguments.sbom,
                arguments.project_root,
                arguments.archive,
                arguments.offer,
                arguments.expected_commit,
            )
            print(f"Verified published source offer for release {offer['releaseVersion']}.")
    except (ReleaseMaterialError, OSError, subprocess.SubprocessError) as error:
        print(f"license release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
