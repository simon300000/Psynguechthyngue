#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate the SBOM and third-party notices for the Go modules linked into GoBridge/psybridge.

Usage (run with python3 -I):
  licenses.py inventory            print the module inventory as TSV
  licenses.py sbom OUT             write SPDX 2.3 JSON
  licenses.py notices OUT          write THIRD_PARTY_NOTICES.md
  licenses.py check                every linked module has a detected license

Environment: GOCACHE defaults to <repo>/.build/gocache when unset; the module cache is Go's default (GOMODCACHE).
"""
import hashlib, json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "GoBridge"
PIN = json.loads((BRIDGE / "SyncthingPin.json").read_text())
LICENSE_FILES = re.compile(r"^(LICEN[CS]E|COPYING|UNLICENSE)([-._].*)?$", re.I)
EXTRA_FILES = re.compile(r"^(NOTICE|PATENTS)([-._].*)?$", re.I)


def go_list():
    env = dict(os.environ, GOOS="ios", GOARCH="arm64", CGO_ENABLED="1",
               GOFLAGS="-mod=readonly", GOWORK="off")
    env.setdefault("GOCACHE", str(ROOT / ".build" / "gocache"))
    fmt = "{{with .Module}}{{if not .Main}}{{.Path}}\t{{.Version}}\t{{.Dir}}\t{{with .Replace}}{{.Path}}@{{.Version}}{{end}}{{end}}{{end}}"
    out = subprocess.run(
        ["go", "list", "-tags", "noassets", "-deps", "-f", fmt, "./psybridge"],
        cwd=BRIDGE, env=env, check=True, capture_output=True, text=True).stdout
    mods = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        path, version, d, rep = line.split("\t")
        mods[path] = (version, d, rep)
    return mods


def detect(text):
    t = re.sub(r"\s+", " ", text).lower()
    if "mozilla public license" in t and "version 2.0" in t: return "MPL-2.0"
    if "apache license" in t and "version 2.0" in t: return "Apache-2.0"
    if "permission is hereby granted, free of charge" in t: return "MIT"
    if "redistribution and use in source and binary forms" in t:
        if "neither the name" in t or "may be used to endorse" in t: return "BSD-3-Clause"
        return "BSD-2-Clause"
    if "permission to use, copy, modify, and/or distribute this software" in t \
            or "permission to use, copy, modify, and distribute this software" in t:
        return "ISC"
    if "this is free and unencumbered software released into the public domain" in t: return "Unlicense"
    if "cc0 1.0 universal" in t: return "CC0-1.0"
    return None


def inventory():
    mods = go_list()
    inv = []
    for path in sorted(mods):
        version, d, rep = mods[path]
        files, extras, ids = [], [], set()
        if d:
            for f in sorted(os.listdir(d)):
                p = Path(d, f)
                if not p.is_file() or p.is_symlink():
                    continue
                if LICENSE_FILES.match(f):
                    text = p.read_text(encoding="utf-8", errors="replace")
                    files.append((f, text))
                    ident = detect(text)
                    if ident: ids.add(ident)
                elif EXTRA_FILES.match(f):
                    extras.append((f, p.read_text(encoding="utf-8", errors="replace")))
        license_id = " AND ".join(sorted(ids)) if ids else None
        inv.append(dict(path=path, version=version, replace=rep, license=license_id,
                        files=files + extras, has_license_file=bool(files)))
    # Syncthing (MPL-2.0) first, the rest sorted by path.
    inv.sort(key=lambda m: (m["path"] != PIN["modulePath"], m["path"]))
    return inv


def download_url(m):
    return f"https://proxy.golang.org/{m['path'].lower()}/@v/{m['version']}.zip"


def spdx_id(path):
    return "SPDXRef-Go-" + re.sub(r"[^A-Za-z0-9.-]", "-", path)


def sbom(inv):
    digest = hashlib.sha256("\n".join(f"{m['path']} {m['version']} {m['license']}" for m in inv).encode()).hexdigest()
    ts = re.search(r"\.(\d{14})-", PIN["moduleVersion"]).group(1)
    created = f"{ts[:4]}-{ts[4:6]}-{ts[6:8]}T{ts[8:10]}:{ts[10:12]}:{ts[12:14]}Z"
    app = "SPDXRef-Package-Psynguechthyngue"
    pkgs = [dict(name="Psynguechthyngue", SPDXID=app, downloadLocation="NOASSERTION",
                 filesAnalyzed=False, licenseConcluded="MIT", licenseDeclared="MIT",
                 copyrightText="Copyright (c) 2026 Simon", primaryPackagePurpose="APPLICATION")]
    rels = [dict(spdxElementId="SPDXRef-DOCUMENT", relationshipType="DESCRIBES", relatedSpdxElement=app)]
    seen = set()
    for m in inv:
        sid = spdx_id(m["path"])
        assert sid not in seen, sid
        seen.add(sid)
        pkgs.append(dict(name=m["path"], SPDXID=sid, versionInfo=m["version"],
                         downloadLocation=download_url(m), filesAnalyzed=False,
                         licenseConcluded="NOASSERTION", licenseDeclared=m["license"] or "NOASSERTION",
                         copyrightText="NOASSERTION"))
        rels.append(dict(spdxElementId=app, relationshipType="DEPENDS_ON", relatedSpdxElement=sid))
    return json.dumps(dict(
        spdxVersion="SPDX-2.3", dataLicense="CC0-1.0", SPDXID="SPDXRef-DOCUMENT",
        name="Psynguechthyngue Go dependency inventory",
        documentNamespace=f"https://github.com/simon300000/Psynguechthyngue/sbom/{PIN['commit']}/{digest}",
        creationInfo=dict(created=created, creators=["Tool: Psynguechthyngue Tools/licenses.py"]),
        packages=pkgs, relationships=rels), indent=2, ensure_ascii=False) + "\n"


def notices(inv):
    out = ["# Third-Party Notices", "",
           "Generated by `Tools/licenses.py` from the Go modules linked into `GoBridge/psybridge` "
           "(GOOS=ios, GOARCH=arm64, `-tags noassets`). Do not edit by hand.", "",
           f"Syncthing {PIN['tag']} (commit {PIN['commit']}) is used unmodified under the MPL-2.0; "
           f"its source is at https://github.com/syncthing/syncthing/tree/{PIN['commit']}.", "",
           "## Summary", "", "| Module | Version | License |", "| --- | --- | --- |"]
    for m in inv:
        out.append(f"| {m['path']} | {m['version']} | {m['license'] or 'NOASSERTION'} |")
    for m in inv:
        out += ["", "---", "", f"## {m['path']} {m['version']}", "",
                f"License: {m['license'] or 'NOASSERTION'}", ""]
        for name, text in m["files"]:
            out += [f"### {name}", "", "~~~~text", text.strip("\n").replace("\r\n", "\n"), "~~~~", ""]
    return "\n".join(out).rstrip("\n") + "\n"


def main(argv):
    if len(argv) < 2: sys.exit(__doc__)
    cmd = argv[1]
    inv = inventory()
    if cmd == "inventory":
        for m in inv: print(m["path"], m["version"], m["license"] or "NOASSERTION", sep="\t")
    elif cmd == "sbom": Path(argv[2]).write_text(sbom(inv), encoding="utf-8")
    elif cmd == "notices": Path(argv[2]).write_text(notices(inv), encoding="utf-8")
    elif cmd == "check":
        bad = [m["path"] for m in inv if not m["license"]]
        if bad: sys.exit("error: no detected license for: " + ", ".join(bad))
        print(f"ok: {len(inv)} linked modules, all with a detected license")
    else: sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
