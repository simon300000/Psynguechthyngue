// SPDX-License-Identifier: MIT

// Package psybridge is bridge v2: the thin, gomobile-safe boundary between
// the iOS app and an *unpatched* upstream Syncthing.
//
// Design rules (Docs/REWRITE/DESIGN.md §3):
//
//   - Control plane = Syncthing's own REST + events API, bound to 127.0.0.1
//     on a random port with a random per-launch API key. Swift talks to it
//     with URLSession. This package only starts/stops the engine and hands
//     the endpoint to Swift.
//   - Direct functions exist only where REST cannot serve the need:
//     lifecycle, identity, runtime memory tuning, streaming the global index
//     for the File Provider metadata projection, and the restricted
//     single-file fetch used by the File Provider extension.
//   - Exported API uses only gomobile-supported types: string, bool, int64,
//     []byte, pointers to exported structs with such fields, and interfaces.
//     Collections cross the boundary as JSON []byte.
//   - Errors returned to Swift have the form "psy:<code>: <detail>" where
//     <code> is one of the Code* constants in errors.go.
//
// Every function in this file set is currently a stub that returns
// CodeNotImplemented; WP-A replaces the bodies without changing signatures.
package psybridge
