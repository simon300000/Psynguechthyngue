// SPDX-License-Identifier: MIT

package psybridge

import "github.com/syncthing/syncthing/lib/build"

// BridgeAPIVersion is bumped on any breaking change to the exported API in
// this package. Swift checks it at launch (PsySync `BridgeContract.apiVersion`).
const BridgeAPIVersion = 2

// PinnedSyncthingVersion is the upstream release this bridge is built and
// tested against (GoBridge/SyncthingPin.json; a test keeps them in sync).
const PinnedSyncthingVersion = "v2.1.6"

// APIVersion returns BridgeAPIVersion (gomobile cannot export constants of
// every type reliably, so expose a function too).
func APIVersion() int64 { return BridgeAPIVersion }

// SyncthingVersion returns the embedded upstream release, e.g. "v2.1.6".
// GoBridge/Scripts/build-xcframework.sh stamps upstream build.Version via
// -ldflags -X; unstamped builds (plain `go test`) report
// "<pinned>+unstamped".
func SyncthingVersion() string {
	if build.Version == "" || build.Version == "unknown-dev" {
		return PinnedSyncthingVersion + "+unstamped"
	}
	return build.Version
}
