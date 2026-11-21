# SPDX-License-Identifier: MIT

import gzip
import io
import json
import os
import pathlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import license_release


EXPECTED_RELEASE_MATERIAL_PATHS = (
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


def write_archive(path, contents):
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for name, data in sorted(contents.items()):
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))


class LicenseReleaseTests(unittest.TestCase):
    def test_exact_source_urls_escape_pseudo_remote_and_local_pins(self):
        self.assertEqual(
            license_release.source_url(
                "github.com/kballard/go-shellquote",
                "v0.0.0-20180428030007-95032a82bc51",
            ),
            "https://proxy.golang.org/github.com/kballard/go-shellquote/@v/"
            "v0.0.0-20180428030007-95032a82bc51.zip",
        )
        self.assertEqual(
            license_release.source_url("github.com/Azure/go-ntlmssp", "v0.1.1"),
            "https://proxy.golang.org/github.com/!azure/go-ntlmssp/@v/v0.1.1.zip",
        )
        self.assertEqual(
            license_release.source_url(
                "github.com/marbens-arch/gateway",
                "v1.1.2-0.20260308173556-c567cc04e7d4",
            ),
            "https://proxy.golang.org/github.com/marbens-arch/gateway/@v/"
            "v1.1.2-0.20260308173556-c567cc04e7d4.zip",
        )
        local_entry = {
            "module": license_release.SYNCTHING_MODULE,
            "version": "v1.2.3",
            "localReplacement": {"upstreamCommit": "a" * 40},
        }
        self.assertEqual(
            license_release.entry_source_url(local_entry),
            "https://github.com/syncthing/syncthing/tree/" + "a" * 40,
        )

    def test_release_material_scope_is_independently_pinned(self):
        self.assertEqual(license_release.RELEASE_MATERIAL_PATHS, EXPECTED_RELEASE_MATERIAL_PATHS)

    def test_repository_contract_rejects_omitted_local_map(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.validate_repository_syncthing_contract(
                    temporary,
                    pathlib.Path(temporary) / "Docs/DEPENDENCY_LICENSE_MAP.json",
                    {},
                )

    def test_release_materials_bind_all_required_project_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Docs").mkdir()
            for relative in license_release.RELEASE_MATERIAL_PATHS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"contents for {relative}\n", encoding="utf-8")
            map_path = root / "Docs/DEPENDENCY_LICENSE_MAP.json"
            sbom_path = root / "Docs/SBOM.spdx.json"

            materials = license_release.release_materials(root, map_path, sbom_path)

            self.assertEqual(
                [record["path"] for record, _ in materials],
                list(license_release.RELEASE_MATERIAL_PATHS),
            )
            for record, data in materials:
                self.assertEqual(record["sha256"], license_release.sha256_bytes(data))
                self.assertEqual(
                    record["archivePath"],
                    f"{license_release.BUNDLE_ROOT}/release-materials/{record['path']}",
                )

    def test_release_materials_reject_non_project_map(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Docs").mkdir()
            sbom_path = root / "Docs/SBOM.spdx.json"
            sbom_path.write_text("{}\n", encoding="utf-8")
            other_map = root / "map.json"
            other_map.write_text("{}\n", encoding="utf-8")
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.release_materials(root, other_map, sbom_path)

    def test_bundle_verifier_rejects_release_material_tamper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Docs").mkdir()
            map_path = root / "Docs/DEPENDENCY_LICENSE_MAP.json"
            sbom_path = root / "Docs/SBOM.spdx.json"
            map_path.write_bytes(
                license_release.canonical_json(
                    {"schemaVersion": 1, "reviewedAt": "2026-08-09", "scope": "test", "entries": []}
                )
            )
            sbom_path.write_bytes(
                license_release.canonical_json(
                    {
                        "packages": [
                            {
                                "name": "Psynguechthyngue",
                                "SPDXID": "SPDXRef-Package-Psynguechthyngue",
                            }
                        ],
                        "relationships": [
                            {
                                "spdxElementId": "SPDXRef-DOCUMENT",
                                "relationshipType": "DESCRIBES",
                                "relatedSpdxElement": "SPDXRef-Package-Psynguechthyngue",
                            }
                        ],
                    }
                )
            )
            for relative in license_release.RELEASE_MATERIAL_PATHS:
                path = root / relative
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(f"contents for {relative}\n", encoding="utf-8")

            materials = license_release.release_materials(root, map_path, sbom_path)
            manifest = {
                "schemaVersion": 1,
                "bundleRoot": license_release.BUNDLE_ROOT,
                "licenseMapSHA256": license_release.sha256_bytes(map_path.read_bytes()),
                "sbomSHA256": license_release.sha256_bytes(sbom_path.read_bytes()),
                "scope": "test",
                "releaseMaterials": [record for record, _ in materials],
                "modules": [],
            }
            files = {record["archivePath"]: data for record, data in materials}
            files[f"{license_release.BUNDLE_ROOT}/SOURCE_MANIFEST.json"] = (
                license_release.canonical_json(manifest)
            )

            valid_archive = root / "valid.tar.gz"
            write_archive(valid_archive, files)
            license_release.verify_bundle(
                map_path, sbom_path, root, valid_archive, require_repository_contract=False
            )

            tampered_files = dict(files)
            notice_name = f"{license_release.BUNDLE_ROOT}/release-materials/NOTICE"
            tampered_files[notice_name] = b"tampered\n"
            tampered_archive = root / "tampered.tar.gz"
            write_archive(tampered_archive, tampered_files)
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.verify_bundle(
                    map_path, sbom_path, root, tampered_archive, require_repository_contract=False
                )

    def test_bundle_rejects_nonlocal_covered_source_with_fresh_tampered_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Docs").mkdir()
            module = "example.com/mpl"
            version = "v1.2.3"
            license_data = b"Mozilla Public License Version 2.0\n"
            source_data = b"package mpl\n"
            license_digest = license_release.sha256_bytes(license_data)
            source_items = [
                ("LICENSE", license_data, license_digest, False),
                ("source.go", source_data, license_release.sha256_bytes(source_data), False),
            ]
            go_hash = license_release.go_h1_sha256(source_items, module, version)
            entry = {
                "module": module,
                "version": version,
                "license": "MPL-2.0",
                "licenseFiles": {"LICENSE": license_digest},
                "sourceDelivery": "covered-source-bundle",
            }
            package_id = "SPDXRef-Package-example"
            map_path = root / "Docs/DEPENDENCY_LICENSE_MAP.json"
            sbom_path = root / "Docs/SBOM.spdx.json"
            map_path.write_bytes(
                license_release.canonical_json(
                    {"schemaVersion": 1, "reviewedAt": "2026-08-09", "scope": "test", "entries": [entry]}
                )
            )
            sbom_path.write_bytes(
                license_release.canonical_json(
                    {
                        "packages": [
                            {"name": "Psynguechthyngue", "SPDXID": "SPDXRef-Package-Psynguechthyngue"},
                            {
                                "name": module,
                                "SPDXID": package_id,
                                "versionInfo": version,
                                "licenseDeclared": "MPL-2.0",
                                "downloadLocation": license_release.source_url(module, version),
                                "checksums": [{"algorithm": "SHA256", "checksumValue": go_hash}],
                            },
                        ],
                        "relationships": [
                            {
                                "spdxElementId": "SPDXRef-Package-Psynguechthyngue",
                                "relationshipType": "DEPENDS_ON",
                                "relatedSpdxElement": package_id,
                            }
                        ],
                    }
                )
            )
            for relative in license_release.RELEASE_MATERIAL_PATHS:
                path = root / relative
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(f"contents for {relative}\n", encoding="utf-8")

            release_materials = license_release.release_materials(root, map_path, sbom_path)
            source_root = license_release.safe_module_root("covered-source", module, version)
            material_root = license_release.safe_module_root("third-party-materials", module, version)
            record = {
                "license": "MPL-2.0",
                "materials": [
                    {
                        "archivePath": material_root + "/LICENSE",
                        "path": "LICENSE",
                        "role": "license",
                        "sha256": license_digest,
                    }
                ],
                "module": module,
                "sourceURL": license_release.source_url(module, version),
                "version": version,
                "resolvedModule": module,
                "resolvedVersion": version,
                "coveredSourceFileCount": len(source_items),
                "coveredSourceRoot": source_root,
                "coveredSourceTreeSHA256": license_release.tree_digest(source_items),
                "coveredSourceGoH1SHA256": go_hash,
            }
            manifest = {
                "schemaVersion": 1,
                "bundleRoot": license_release.BUNDLE_ROOT,
                "licenseMapSHA256": license_release.sha256_bytes(map_path.read_bytes()),
                "sbomSHA256": license_release.sha256_bytes(sbom_path.read_bytes()),
                "scope": "test",
                "releaseMaterials": [item for item, _ in release_materials],
                "modules": [record],
            }
            files = {item["archivePath"]: data for item, data in release_materials}
            files[material_root + "/LICENSE"] = license_data
            files[source_root + "/LICENSE"] = license_data
            files[source_root + "/source.go"] = source_data
            files[license_release.BUNDLE_ROOT + "/SOURCE_MANIFEST.json"] = license_release.canonical_json(manifest)
            valid = root / "valid-covered.tar.gz"
            write_archive(valid, files)
            license_release.verify_bundle(
                map_path, sbom_path, root, valid, require_repository_contract=False
            )

            tampered_data = b"package mpl\n// tampered\n"
            tampered_items = [
                source_items[0],
                ("source.go", tampered_data, license_release.sha256_bytes(tampered_data), False),
            ]
            tampered_manifest = json.loads(json.dumps(manifest))
            tampered_record = tampered_manifest["modules"][0]
            tampered_record["coveredSourceTreeSHA256"] = license_release.tree_digest(tampered_items)
            tampered_record["coveredSourceGoH1SHA256"] = license_release.go_h1_sha256(
                tampered_items, module, version
            )
            tampered_files = dict(files)
            tampered_files[source_root + "/source.go"] = tampered_data
            tampered_files[license_release.BUNDLE_ROOT + "/SOURCE_MANIFEST.json"] = (
                license_release.canonical_json(tampered_manifest)
            )
            tampered = root / "tampered-covered.tar.gz"
            write_archive(tampered, tampered_files)
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.verify_bundle(
                    map_path, sbom_path, root, tampered, require_repository_contract=False
                )

    def test_safe_module_root_rejects_traversal(self):
        with self.assertRaises(license_release.ReleaseMaterialError):
            license_release.safe_module_root("covered-source", "example.com/../escape", "v1.0.0")

    def test_https_offer_url_rejects_placeholder_and_query(self):
        for value in (
            "https://REPLACE.example/source.tar.gz",
            "https://example.invalid/source.tar.gz",
            "https://example.com/source.tar.gz?mutable=1",
            "http://example.com/source.tar.gz",
        ):
            with self.subTest(value=value):
                with self.assertRaises(license_release.ReleaseMaterialError):
                    license_release.validate_https_url(value, "source.tar.gz")

    def test_offer_requires_release_specific_archive_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            offer = {
                "schemaVersion": 1,
                "releaseVersion": "v1.0.0",
                "releaseCommit": "a" * 40,
                "publishedAt": "2026-08-09T00:00:00Z",
                "sourceArchiveFilename": "sources.tar.gz",
                "sourceArchiveSHA256": "b" * 64,
                "sourceURL": "https://downloads.example.com/sources.tar.gz",
                "noticesURL": "https://downloads.example.com/notices",
                "licenseMapSHA256": "c" * 64,
                "sbomSHA256": "d" * 64,
            }
            path = os.path.join(temporary, "offer.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(offer, handle)
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.load_offer(path)

    def test_tree_digest_binds_path_content_and_size(self):
        baseline = [("a.txt", b"hello", license_release.sha256_bytes(b"hello"), False)]
        renamed = [("b.txt", b"hello", license_release.sha256_bytes(b"hello"), False)]
        changed = [("a.txt", b"hello!", license_release.sha256_bytes(b"hello!"), False)]
        self.assertNotEqual(license_release.tree_digest(baseline), license_release.tree_digest(renamed))
        self.assertNotEqual(license_release.tree_digest(baseline), license_release.tree_digest(changed))

    def test_bundle_reader_rejects_symbolic_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.join(temporary, "unsafe.tar.gz")
            with open(path, "wb") as raw:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as archive:
                        member = tarfile.TarInfo(license_release.BUNDLE_ROOT + "/escape")
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/etc/passwd"
                        archive.addfile(member)
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.read_bundle(path)

    def test_bundle_reader_rejects_duplicate_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = os.path.join(temporary, "duplicate.tar.gz")
            with open(path, "wb") as raw:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as archive:
                        name = license_release.BUNDLE_ROOT + "/SOURCE_MANIFEST.json"
                        for _ in range(2):
                            data = b"{}"
                            member = tarfile.TarInfo(name)
                            member.size = len(data)
                            archive.addfile(member, io.BytesIO(data))
            with self.assertRaises(license_release.ReleaseMaterialError):
                license_release.read_bundle(path)


if __name__ == "__main__":
    unittest.main()
