#!/bin/sh
# SPDX-License-Identifier: MIT

# These values are production build inputs. Keep them centralized so the
# builder and provenance verifier cannot silently drift apart.
PSY_XCFRAMEWORK_PROVENANCE_SCHEMA=3
# Current gomobile treats device and Simulator as separate Apple platforms.
# Both are required for the two-slice XCFramework consumed by Xcode.
PSY_XCFRAMEWORK_TARGET=ios,iossimulator
PSY_XCFRAMEWORK_DEFAULT_DEPLOYMENT_TARGET=17.0
PSY_XCFRAMEWORK_BUILD_TAGS=noassets
PSY_SYNCTHING_BUILD_VERSION=v2.1.3
PSY_XCFRAMEWORK_LDFLAGS="-s -w -X github.com/syncthing/syncthing/lib/build.Version=${PSY_SYNCTHING_BUILD_VERSION}"

readonly \
	PSY_XCFRAMEWORK_PROVENANCE_SCHEMA \
	PSY_XCFRAMEWORK_TARGET \
	PSY_XCFRAMEWORK_DEFAULT_DEPLOYMENT_TARGET \
	PSY_XCFRAMEWORK_BUILD_TAGS \
	PSY_SYNCTHING_BUILD_VERSION \
	PSY_XCFRAMEWORK_LDFLAGS
