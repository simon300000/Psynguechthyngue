#!/usr/bin/env python3
"""DEV/TEST ONLY: WP-C Files acceptance against the local official Syncthing.

Topology:
  official Syncthing (127.0.0.1:8384, the user's instance)
      <-> "phone" Syncthing (own home under ~/SyncthingTest/wpc/phone-home,
          GUI 127.0.0.1:8484, listen 127.0.0.1:22101) whose folder path is the
          simulator App Group  Folders/psy-test-wpc-files  (on-demand .stignore)
  Simulator: PsyFilesHarness (RESTDevEngine -> phone instance) + PsyFileProvider.

Rules (CLAUDE.local.md): on the official instance only psy-test-wpc-* objects
are created, nothing else is modified; the official API key is read from
config.xml into memory only and never printed or written anywhere.

Usage: e2e.py setup <appgroup-root> | status | official-file <path> | teardown
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HOME = os.path.expanduser("~")
W = os.path.join(HOME, "SyncthingTest", "wpc")
OFFICIAL = "http://127.0.0.1:8384"
PHONE = "http://127.0.0.1:8484"
PEER = "http://127.0.0.1:8585"
PEER_DIR = os.path.join(W, "peer-files")
FOLDER = "psy-test-wpc-files"
PHONE_NAME = "psy-test-wpc-phone"
OFFICIAL_DIR = os.path.join(W, "official-files")
BASELINE = os.path.join(W, ".baseline.json")
MARKER = "// === Psynguechthyngue managed — do not edit below ==="


def official_key():
    cfg = os.path.join(HOME, "Library/Application Support/Syncthing/config.xml")
    return ET.parse(cfg).getroot().find("gui").find("apikey").text


def phone_key():
    with open(os.path.join(W, "phone-home", ".harness-apikey")) as f:
        return f.read().strip()


def call(base, key, method, path, query=None, body=None):
    url = base + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"X-API-Key": key})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
    return json.loads(raw) if raw and raw[:1] in b"[{" else raw


def off(method, path, query=None, body=None):
    return call(OFFICIAL, official_key(), method, path, query, body)


def phone(method, path, query=None, body=None):
    return call(PHONE, phone_key(), method, path, query, body)


def peer_key():
    with open(os.path.join(W, "peer-home", ".harness-apikey")) as f:
        return f.read().strip()


def peer(method, path, query=None, body=None):
    return call(PEER, peer_key(), method, path, query, body)


def peer_setup():
    """Private third device (own home under ~/SyncthingTest/wpc) sharing the folder
    with the phone instance; used when the official instance cannot run."""
    phone_id = phone("GET", "/rest/system/status")["myID"]
    peer_id = peer("GET", "/rest/system/status")["myID"]
    for call_, port in ((peer, 22102), (phone, 22101)):
        call_("PATCH", "/rest/config/options", body={
            "listenAddresses": ["tcp://127.0.0.1:%d" % port], "globalAnnounceEnabled": False,
            "localAnnounceEnabled": False, "relaysEnabled": False, "natEnabled": False,
            "minHomeDiskFree": {"value": 1, "unit": "GB"}})
    peer("PUT", "/rest/config/devices/" + phone_id, body={"deviceID": phone_id, "name": PHONE_NAME, "addresses": ["tcp://127.0.0.1:22101"]})
    phone("PUT", "/rest/config/devices/" + peer_id, body={"deviceID": peer_id, "name": "psy-test-wpc-peer", "addresses": ["tcp://127.0.0.1:22102"]})
    os.makedirs(PEER_DIR, exist_ok=True)
    seed = {"hello.txt": "hello from the official instance\n", "remote-only.txt": "opened through delegatedToApp\n",
            "fetched-offline.txt": "opened through restrictedFetch\n", "docs/report.txt": "nested report\n"}
    for rel, text in seed.items():
        p = os.path.join(PEER_DIR, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    peer("PUT", "/rest/config/folders/" + FOLDER, body={
        "id": FOLDER, "label": FOLDER, "path": PEER_DIR, "type": "sendreceive",
        "devices": [{"deviceID": peer_id}, {"deviceID": phone_id}], "fsWatcherEnabled": True, "fsWatcherDelayS": 1,
        "minDiskFree": {"value": 1, "unit": "GB"}})
    f = phone("GET", "/rest/config/folders/" + FOLDER)
    if not any(d["deviceID"] == peer_id for d in f["devices"]):
        f["devices"].append({"deviceID": peer_id})
        phone("PUT", "/rest/config/folders/" + FOLDER, body=f)
    for _ in range(60):
        if phone("GET", "/rest/system/connections")["connections"].get(peer_id, {}).get("connected"):
            break
        time.sleep(1)
    print("peer connected:", phone("GET", "/rest/system/connections")["connections"].get(peer_id, {}).get("connected"))


def peer_status():
    s = peer("GET", "/rest/db/status", {"folder": FOLDER})
    print("peer:", s.get("state"), "local", s.get("localFiles"), "global", s.get("globalFiles"), "need", s.get("needFiles"))
    print("peer files:", sorted(os.path.relpath(os.path.join(d, n), PEER_DIR) for d, _, ns in os.walk(PEER_DIR) for n in ns
                                if not n.startswith(".st")))


def official_ids():
    """Folder/device IDs on the official instance, excluding every psy-test-*
    object (ours and other work packages' concurrent E2E runs)."""
    folders = sorted(f["id"] for f in off("GET", "/rest/config/folders") if not f["id"].startswith("psy-test-"))
    devices = sorted(d["deviceID"] for d in off("GET", "/rest/config/devices")
                     if not d.get("name", "").startswith("psy-test-"))
    return {"folders": folders, "devices": devices}


def guard_ok():
    """Official config must equal the baseline except for psy-test-* objects."""
    if not os.path.exists(BASELINE):
        return True
    with open(BASELINE) as f:
        base = json.load(f)
    return official_ids() == base


def setup(appgroup_root):
    os.makedirs(OFFICIAL_DIR, exist_ok=True)
    if not os.path.exists(BASELINE):
        with open(BASELINE, "w") as f:
            json.dump(official_ids(), f)
    official_id = off("GET", "/rest/system/status")["myID"]
    phone_id = phone("GET", "/rest/system/status")["myID"]

    # Phone instance: local-only networking, knows the official device.
    phone("PATCH", "/rest/config/options", body={
        "listenAddresses": ["tcp://127.0.0.1:22101"], "globalAnnounceEnabled": False,
        "localAnnounceEnabled": False, "relaysEnabled": False, "natEnabled": False})
    phone("PUT", "/rest/config/devices/" + official_id, body={
        "deviceID": official_id, "name": "psy-test-wpc-official", "addresses": ["tcp://127.0.0.1:22000", "dynamic"]})
    # Official instance: only psy-test-wpc-* additions.
    off("PUT", "/rest/config/devices/" + phone_id, body={
        "deviceID": phone_id, "name": PHONE_NAME, "addresses": ["tcp://127.0.0.1:22101"], "autoAcceptFolders": False})

    seed = {
        "hello.txt": "hello from the official instance\n",
        "remote-only.txt": "opened through delegatedToApp\n",
        "fetched-offline.txt": "opened through restrictedFetch\n",
        "docs/report.txt": "nested report\n",
    }
    for rel, text in seed.items():
        p = os.path.join(OFFICIAL_DIR, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    off("PUT", "/rest/config/folders/" + FOLDER, body={
        "id": FOLDER, "label": FOLDER, "path": OFFICIAL_DIR, "type": "sendreceive",
        "devices": [{"deviceID": official_id}, {"deviceID": phone_id}],
        "fsWatcherEnabled": True, "fsWatcherDelayS": 1, "rescanIntervalS": 60})

    folder_path = os.path.join(appgroup_root, "Folders", FOLDER)
    os.makedirs(folder_path, exist_ok=True)
    with open(os.path.join(folder_path, ".stignore"), "w") as f:
        f.write(MARKER + "\n*\n")
    phone("PUT", "/rest/config/folders/" + FOLDER, body={
        "id": FOLDER, "label": "Test Files", "path": folder_path, "type": "sendreceive",
        "devices": [{"deviceID": phone_id}, {"deviceID": official_id}],
        "fsWatcherEnabled": False, "rescanIntervalS": 3600})
    # DevRestrictedFetchBridge source (simulated peer for the offline path).
    dev = os.path.join(appgroup_root, "DevFetchSource", FOLDER)
    os.makedirs(dev, exist_ok=True)
    with open(os.path.join(dev, "fetched-offline.txt"), "w") as f:
        f.write(seed["fetched-offline.txt"])
    for _ in range(60):
        conns = phone("GET", "/rest/system/connections")["connections"]
        if conns.get(official_id, {}).get("connected"):
            break
        time.sleep(1)
    print("connected:", conns.get(official_id, {}).get("connected"), "guard:", guard_ok())


def status():
    s = phone("GET", "/rest/db/status", {"folder": FOLDER})
    o = off("GET", "/rest/db/status", {"folder": FOLDER})
    print("phone:", s.get("state"), "local", s.get("localFiles"), "global", s.get("globalFiles"), "need", s.get("needFiles"))
    print("official:", o.get("state"), "local", o.get("localFiles"), "global", o.get("globalFiles"))
    print("official files:", sorted(
        os.path.relpath(os.path.join(d, n), OFFICIAL_DIR) for d, _, ns in os.walk(OFFICIAL_DIR) for n in ns
        if not n.startswith(".st")))
    print("guard:", guard_ok())


def official_file(rel):
    info = off("GET", "/rest/db/file", {"folder": FOLDER, "file": rel})
    g = info.get("global") or {}
    print(json.dumps({"name": g.get("name"), "deleted": g.get("deleted"), "size": g.get("size"),
                      "modifiedBy": g.get("modifiedBy"), "version": g.get("version")}))


def set_present(appgroup_root, rel, present):
    """Phone side: un-ignore (+ wait for pull) or re-ignore + delete local copy."""
    lines = phone("GET", "/rest/db/ignores", {"folder": FOLDER})["ignore"]
    rule = "!/" + rel
    lines = [l for l in lines if l != rule]
    if present:
        lines.insert(lines.index("*"), rule)
    phone("POST", "/rest/db/ignores", {"folder": FOLDER}, {"ignore": lines})
    local = os.path.join(appgroup_root, "Folders", FOLDER, rel)
    if present:
        phone("POST", "/rest/db/scan", {"folder": FOLDER})
        for _ in range(30):
            if os.path.exists(local):
                break
            time.sleep(1)
        print("present:", os.path.exists(local))
    else:
        if os.path.exists(local):
            os.remove(local)
        phone("POST", "/rest/db/scan", {"folder": FOLDER})
        print("absent:", not os.path.exists(local))


def teardown():
    phone_id = phone("GET", "/rest/system/status")["myID"] if os.path.exists(os.path.join(W, "phone-home", ".harness-apikey")) else None
    for f in off("GET", "/rest/config/folders"):
        if f["id"].startswith("psy-test-wpc-"):
            off("DELETE", "/rest/config/folders/" + f["id"])
    for d in off("GET", "/rest/config/devices"):
        if d.get("name", "").startswith("psy-test-wpc-") or d["deviceID"] == phone_id:
            off("DELETE", "/rest/config/devices/" + d["deviceID"])
    ok = guard_ok()
    print("official restored:", ok)
    if ok and os.path.exists(BASELINE):
        os.remove(BASELINE)
    return 0 if ok else 1


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "setup":
        setup(sys.argv[2])
    elif cmd == "peer-setup":
        peer_setup()
    elif cmd == "peer-status":
        peer_status()
    elif cmd == "status":
        status()
    elif cmd == "official-file":
        official_file(sys.argv[2])
    elif cmd == "present":
        set_present(sys.argv[2], sys.argv[3], sys.argv[4] == "1")
    elif cmd == "teardown":
        sys.exit(teardown())
