// SPDX-License-Identifier: MIT

// Package integration holds the bridge-level integration tests from
// Docs/REWRITE/DESIGN.md §10.2. They run on the macOS host against the real
// upstream Syncthing compiled into psybridge (no mocks):
//
//   - engine_test.go: Engine start/stop in a temp home, REST bound to
//     127.0.0.1 only, random API key per start, index stream, resources
//     released after Stop.
//   - fetch_test.go: two psybridge processes on loopback (A = full engine,
//     B = restricted FetchFile core at GOMEMLIMIT 40 MiB) fetching 1 KiB,
//     cross-block and 100 MiB files, plus cancel / hash mismatch / version
//     mismatch / missing file / peer offline. Peak RSS of B is logged.
//
// Run: GoBridge/Scripts/test.sh (adds -tags noassets).
package integration
