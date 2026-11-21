# GoBridge (bridge v2)

Thin gomobile boundary between the iOS app and an **unpatched** upstream
Syncthing (Docs/REWRITE/DESIGN.md §3, §6.4). Upstream is pinned in
`SyncthingPin.json` and `go.mod` (v2.1.6, zero patches).

| Path | What |
|---|---|
| `psybridge/` | Exported API: `Engine` (Start/Stop/IsRunning/OnMemoryWarning/OpenIndexStream), identity, runtime memory profiles, `FetchFile` (restricted core) |
| `integration/` | §10.2 tests: in-process engine lifecycle; two-process A (engine) ↔ B (restricted `FetchFile`) on loopback |
| `Scripts/test.sh` | `go vet`, `go test`, `go test -race` (all with `-tags noassets`) |
| `Scripts/build-xcframework.sh` | `Artifacts/PsyBridge.xcframework` (iOS + iOS Simulator) + provenance JSON |
| `../Platform/PsyBridgeAdapter.swift` | Swift `SyncthingBridge` / `RestrictedFetchBridge` over the framework, plus `PsyBridgeThread` |

Every Go command needs `-tags noassets` (upstream `lib/api` otherwise wants
generated GUI assets). The scripts set it.

## Behaviour notes

- REST/GUI is forced onto `127.0.0.1:<random port>` with a random API key on
  every `Start`; non-loopback `APIAddress` values are rejected. `STGUIADDRESS`
  and `STGUIAPIKEY` are unset before start.
- On iOS (`GOOS=ios`, which includes Designed for iPad on Mac) every folder
  gets `fsWatcherEnabled=false`, `rescanIntervalS=3600` on each start.
- `Stop` closes every file under the home directory (asserted with `lsof`).
  `CodeStopTimeout` poisons the process: no further Start/FetchFile.
- One upstream App per process (Engine **or** FetchFile): a second one gets
  `already_running`.
- `FetchFile` reads config.xml into memory (never writes it), pauses every
  folder, pauses devices that do not share the target folder, uses one
  connection per device, keeps discovery/relays as configured.
- `FetchFile` gives the staged file the global nanosecond mtime and
  permissions. `RecordFetchedFile` (call it after the file has been moved into
  the folder, with the lock still held) writes the global FileInfo as the
  local index entry, the same way the puller does. Without that entry, the
  App's next scan mints a new version in about 60% of runs, because the
  scanner compares against the *local* entry. See
  `Docs/REWRITE/notes/contract-change-WP-A-record-fetched-file.md`.
- Upstream exposes no SQLite `cache_size` knob (DESIGN §3.5 asked): it runs
  with SQLite's default page cache (2 MiB per connection) in C memory,
  outside GOMEMLIMIT.

## Measurements (macOS host, Apple Silicon, not a device)

`FetchFile` of a 100 MiB file from a local A engine, B at GOMEMLIMIT 40 MiB /
GOGC 50: **peak RSS 29.2 MiB**, ~2 s. 1 KiB / 257 KiB fetches peak at
~27–28 MiB. Device numbers (jetsam limit of the extension) are WP-C's job.
