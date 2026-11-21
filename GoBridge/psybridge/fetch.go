// SPDX-License-Identifier: MIT

package psybridge

// Restricted single-file fetch ("受限小内核", DESIGN.md §6.4).
//
// Used ONLY by the File Provider extension when the App is not running and
// the user opens a placeholder. It starts a minimal upstream `syncthing.App`
// against the shared HomeDir with an *in-memory* config derivative:
//
//   - every folder Paused = true (no scanner, no puller, no index exchange);
//     outgoing block Requests still work because the remote side only checks
//     its own folder config;
//   - GUI/REST disabled, UPnP/NAT-PMP off, usage reporting/crash reporting/
//     auto-upgrade off, DB maintenance interval = 0;
//   - global + local discovery and relays stay on (needed to reach peers);
//   - nothing is written to config.xml.
//
// Then: GlobalFileInfo(folder, path) from the DB → check version → for each
// block, pick a connected device that shares the folder → DownloadBlock →
// verify SHA-256 → write at offset into DestinationPath → fsync → stop.
// Stops as soon as the file is complete, on deadline, or on cancellation.
//
// Caller (Swift) MUST hold the App Group engine lock for the whole call.

// FetchRequest describes the single file to fetch.
type FetchRequest struct {
	HomeDir string
	CertPEM []byte
	KeyPEM  []byte

	FolderID string
	// Path is folder-relative, '/' separated, NFC.
	Path string
	// ExpectedVersion is the `version` field the File Provider item advertised
	// (IndexEntryJSON.version). Empty = accept current index version.
	ExpectedVersion string
	// DestinationPath: a file in <AppGroup>/Staging/ (same volume as the
	// folders, outside every Syncthing folder so no ignore rule is needed).
	// The bridge writes and fsyncs it; Swift clones/renames it into place.
	DestinationPath string

	// Budgets. Zero = defaults below.
	DeadlineMillis int64 // total wall clock including connect
	MemoryLimitMiB int64
	MaxFileBytes   int64
}

// Default budgets for the restricted fetch.
const (
	DefaultFetchDeadlineMillis = 90_000
	DefaultFetchMaxFileBytes   = 2 << 30 // 2 GiB; above this we tell the user to open the App
	// ConnectGraceMillis: how long to wait for the first peer connection
	// before failing with CodeNoPeer.
	DefaultFetchConnectGraceMillis = 20_000
)

// FetchResult describes the fetched content.
type FetchResult struct {
	Size        int64
	ModifiedUTC string // RFC3339Nano
	Version     string // same encoding as IndexEntryJSON.version
	BlocksHash  string
	// DeviceIDs that served blocks, comma separated (diagnostics only).
	ServedBy string
}

// FetchProgress is polled/called from the fetch goroutine.
type FetchProgress interface {
	// Progress reports bytes completed / total.
	Progress(completed int64, total int64)
	// IsCancelled is polled between blocks; returning true aborts with CodeCancelled.
	IsCancelled() bool
}

// FetchFile performs the restricted fetch. Blocking; Swift calls it from a
// dedicated thread (never the cooperative pool).
func FetchFile(req *FetchRequest, progress FetchProgress) (*FetchResult, error) {
	if req == nil || req.FolderID == "" || req.Path == "" || req.DestinationPath == "" {
		return nil, newError(CodeInvalidArgument, "FolderID, Path and DestinationPath are required")
	}
	return nil, notImplemented("FetchFile")
}
