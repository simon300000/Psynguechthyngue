#!/usr/bin/env bash
# E2E: LiveSyncEngine ↔ the official Syncthing running on this Mac.
#
# - The official instance's API key is read from its config.xml into a shell
#   variable and passed to curl via stdin (`-H @-`) and to the test process via
#   its environment. It is never printed, never in argv, never written to disk.
# - Only `psy-test-wpb-*` folders/devices are created on the official instance;
#   all test paths live under ~/SyncthingTest/wpb/. Leftovers from earlier runs
#   are removed first; cleanup runs from a trap.
# - Guard: the official configuration and pending lists (excluding every
#   `psy-test-*` entry, which other work packages may be using concurrently)
#   must be identical before and after, otherwise the run fails.
#
# Env overrides: PSY_E2E_OFFICIAL_CONFIG, PSY_E2E_OFFICIAL_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

CFG="${PSY_E2E_OFFICIAL_CONFIG:-$HOME/Library/Application Support/Syncthing/config.xml}"
URL="${PSY_E2E_OFFICIAL_URL:-http://127.0.0.1:8384}"
TEST_BASE="$HOME/SyncthingTest/wpb"
PREFIX="psy-test-wpb-"
RUN_ID="$(uuidgen | cut -c1-8 | tr '[:upper:]' '[:lower:]')"

for tool in jq curl xmllint swift; do
  command -v "$tool" >/dev/null || { echo "e2e-local: missing $tool" >&2; exit 2; }
done
[[ -r "$CFG" ]] || { echo "e2e-local: cannot read $CFG" >&2; exit 2; }
KEY="$(xmllint --xpath 'string(/configuration/gui/apikey)' "$CFG" 2>/dev/null || true)"
[[ -n "$KEY" ]] || { echo "e2e-local: no GUI API key in config" >&2; exit 2; }

api() { # METHOD PATH [curl args...]
  # The official instance can be slow under load (other sessions' tests): be patient, retry reads.
  local method="$1" path="$2"; shift 2
  local retry=()
  [[ "$method" == GET ]] && retry=(--retry 3 --retry-delay 2 --retry-all-errors)
  printf 'X-API-Key: %s\n' "$KEY" | curl -sS -f --max-time 120 ${retry[@]+"${retry[@]}"} -X "$method" -H @- "$@" "$URL$path"
}

uri() { jq -rn --arg v "$1" '$v|@uri'; }

snapshot() {
  # Everything except psy-test-* entries and secrets.
  api GET /rest/config | jq -S '
    del(.gui.apikey, .gui.password)
    | .folders |= map(select(.id | startswith("psy-test-") | not))
    | .devices |= map(select(.name | startswith("psy-test-") | not))'
  api GET /rest/cluster/pending/devices | jq -S 'with_entries(select((.value.name // "") | startswith("psy-test-") | not))'
  api GET /rest/cluster/pending/folders | jq -S 'with_entries(select(.key | startswith("psy-test-") | not))'
}

cleanup_official() {
  local id dev
  pkill -f "SyncthingTest/wpb/${PREFIX}" 2>/dev/null || true
  for id in $(api GET /rest/config/folders | jq -r --arg p "$PREFIX" '.[] | select(.id | startswith($p)) | .id'); do
    api DELETE "/rest/config/folders/$(uri "$id")" -o /dev/null || true
  done
  for dev in $(api GET /rest/config/devices | jq -r --arg p "$PREFIX" '.[] | select(.name | startswith($p)) | .deviceID'); do
    api DELETE "/rest/config/devices/$dev" -o /dev/null || true
  done
  for dev in $(api GET /rest/cluster/pending/devices | jq -r --arg p "$PREFIX" 'to_entries[] | select((.value.name // "") | startswith($p)) | .key'); do
    api DELETE "/rest/cluster/pending/devices?device=$dev" -o /dev/null || true
  done
  api GET /rest/cluster/pending/folders \
    | jq -r --arg p "$PREFIX" 'to_entries[] | select(.key | startswith($p)) | .key as $f | .value.offeredBy | keys[] | "\($f) \(.)"' \
    | while read -r id dev; do
        api DELETE "/rest/cluster/pending/folders?folder=$(uri "$id")&device=$dev" -o /dev/null || true
      done
  rm -rf "$TEST_BASE"/${PREFIX}*
}

leftovers() {
  {
    api GET /rest/config | jq -r --arg p "$PREFIX" '(.folders[] | select(.id | startswith($p)) | .id), (.devices[] | select(.name | startswith($p)) | .name)'
    api GET /rest/cluster/pending/devices | jq -r --arg p "$PREFIX" 'to_entries[] | select((.value.name // "") | startswith($p)) | .key'
    api GET /rest/cluster/pending/folders | jq -r --arg p "$PREFIX" 'keys[] | select(startswith($p))'
    ls -d "$TEST_BASE"/${PREFIX}* 2>/dev/null || true
  } | sed '/^$/d'
}

VERSION="$(api GET /rest/system/version | jq -r .version)"
echo "e2e-local: official Syncthing $VERSION at $URL, run $RUN_ID"
[[ "$VERSION" == v2.1.* ]] || echo "e2e-local: warning: expected v2.1.x (pinned peer v2.1.6)" >&2

mkdir -p "$TEST_BASE"
cleanup_official   # residue from earlier runs
BEFORE="$(snapshot)"
trap 'cleanup_official' EXIT

echo "e2e-local: building tests"
swift build --build-tests >/dev/null

set +e
OUT="$(PSY_E2E_LOCAL=1 PSY_E2E_OFFICIAL_APIKEY="$KEY" PSY_E2E_OFFICIAL_URL="$URL/" PSY_E2E_RUN_ID="$RUN_ID" \
  swift test --skip-build --filter 'LocalSyncthingE2ETests' 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUT" | grep -E '\[e2e\]|recorded an issue|Expectation failed|passed|failed|error' | grep -v 'started\.$' || true

cleanup_official
trap - EXIT
AFTER="$(snapshot)"
LEFT="$(leftovers)"

RESULT=0
if [[ $STATUS -ne 0 ]] || ! grep -q 'fullScenario() passed' <<<"$OUT"; then
  echo "e2e-local: FAIL — test scenario did not pass" >&2
  RESULT=1
fi
if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "e2e-local: FAIL — official configuration changed outside psy-test-*:" >&2
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -40 >&2 || true
  RESULT=1
else
  echo "e2e-local: official configuration unchanged (excluding psy-test-*)"
fi
if [[ -n "$LEFT" ]]; then
  echo "e2e-local: FAIL — leftovers after cleanup:" >&2
  printf '%s\n' "$LEFT" >&2
  RESULT=1
fi
[[ $RESULT -eq 0 ]] && echo "e2e-local: PASS"
exit $RESULT
