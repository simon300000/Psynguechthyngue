#!/bin/sh
# SPDX-License-Identifier: MIT
# GoBridge verification: vet, unit + integration tests, race detector.
# Usage: GoBridge/Scripts/test.sh [--quick]   (--quick skips -race)
set -eu
cd "$(dirname "$0")/.."
TAGS=noassets
export GOFLAGS="${GOFLAGS:-} -tags=$TAGS"

echo "== go vet"
go vet ./...
echo "== go test"
PSY_RSS_REPORT="${PSY_RSS_REPORT:-}" go test -count=1 ./...
if [ "${1:-}" != "--quick" ]; then
	echo "== go test -race"
	go test -race -count=1 -timeout 20m ./...
fi
echo "GoBridge tests OK"
