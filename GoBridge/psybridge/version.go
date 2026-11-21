// SPDX-License-Identifier: MIT

package psybridge

// BridgeAPIVersion is bumped on any breaking change to the exported API in
// this package. Swift checks it at launch (PsySync `BridgeContract.apiVersion`).
const BridgeAPIVersion = 2

// APIVersion returns BridgeAPIVersion (gomobile cannot export constants of
// every type reliably, so expose a function too).
func APIVersion() int64 { return BridgeAPIVersion }

// SyncthingVersion returns the embedded upstream release, e.g. "v2.1.6".
// WP-A wires this to upstream build.Version via -ldflags.
func SyncthingVersion() string { return "unlinked" }
