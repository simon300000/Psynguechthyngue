#!/usr/bin/env python3
"""DEV/TEST ONLY (acceptance): upstream scan time vs number of generated
on-demand rules (`!/path` lines before `*`). Runs on the private
phone-side Syncthing (127.0.0.1:8484), never on the official instance.
Usage: stignore-scale.py <dir-with-files>"""
import json, os, statistics, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import e2e

FOLDER = "psy-test-wpc-stignore"
path = os.path.abspath(sys.argv[1])
files = sorted(os.path.relpath(os.path.join(d, n), path) for d, _, ns in os.walk(path) for n in ns if not n.startswith(".st"))
e2e.phone("PUT", "/rest/config/folders/" + FOLDER, body={"id": FOLDER, "label": FOLDER, "path": path, "type": "sendreceive",
          "fsWatcherEnabled": False, "rescanIntervalS": 86400, "minDiskFree": {"value": 1, "unit": "GB"}})
time.sleep(3)

def wait_idle():
    for _ in range(600):
        if e2e.phone("GET", "/rest/db/status", {"folder": FOLDER}).get("state") == "idle":
            return
        time.sleep(0.2)

def scan_time():
    wait_idle()
    t = time.monotonic()
    for attempt in range(10):
        try:
            e2e.phone("POST", "/rest/db/scan", {"folder": FOLDER})
            break
        except Exception:
            time.sleep(0.5)
    wait_idle()
    return time.monotonic() - t

results = []
for label, rules in [
    ("no .stignore (everything)", None),
    ("'*' only", []),
    ("1,000 file rules", files[:1000]),
    ("5,000 file rules", files[:5000]),
    ("10,000 file rules", files[:10000]),
    ("100 directory rules", sorted({f.split("/")[0] for f in files})),
]:
    lines = [] if rules is None else [e2e.MARKER] + ["!/" + r for r in rules] + ["*"]
    e2e.phone("POST", "/rest/db/ignores", {"folder": FOLDER}, {"ignore": lines})
    time.sleep(2)
    scan_time()  # settle (first scan after a rule change re-evaluates the index)
    samples = [scan_time() for _ in range(3)]
    st = e2e.phone("GET", "/rest/db/status", {"folder": FOLDER})
    results.append((label, statistics.median(samples), st.get("localFiles")))
    print("%-28s median %.3fs  localFiles=%s" % results[-1], flush=True)

e2e.phone("DELETE", "/rest/config/folders/" + FOLDER)
