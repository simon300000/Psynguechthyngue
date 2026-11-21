// SPDX-License-Identifier: MIT

package psybridge

// IndexStream walks the *global* index of one folder (upstream
// Internals.AllGlobalFiles) so Swift can build the File Provider metadata
// projection. REST /rest/db/browse lacks version vectors and block hashes and
// is tree-shaped, so this is one of the few direct functions.
//
// Next returns a JSON array of IndexEntryJSON, at most maxEntries long.
// An empty array ("[]") means the stream is exhausted. The stream holds a DB
// read snapshot; callers must Close it promptly (Swift: `defer`).
//
// IndexEntryJSON (contract, mirrored by Swift `GlobalIndexEntry`):
//
//	{
//	  "name":     "dir/file.txt",   // folder-relative, NFC, '/' separated
//	  "type":     "file" | "directory" | "symlink",
//	  "size":     1234,
//	  "modified": "2026-11-21T10:00:00.123Z",
//	  "deleted":  false,
//	  "invalid":  false,            // ignored/unsupported on the announcing device
//	  "sequence": 42,               // global sequence for change detection
//	  "version":  "base64(sha256(version vector))",  // content+metadata version
//	  "blocksHash": "base64",       // content-only version (empty for dirs)
//	  "localPresent": true          // this device has this exact version on disk
//	}
type IndexStream struct {
	folderID string
}

// OpenIndexStream requires a running Engine (App) — the extension never calls it.
func (e *Engine) OpenIndexStream(folderID string) (*IndexStream, error) {
	return nil, notImplemented("Engine.OpenIndexStream")
}

// Next returns the next page as JSON (see IndexEntryJSON).
func (s *IndexStream) Next(maxEntries int64) ([]byte, error) {
	return nil, notImplemented("IndexStream.Next")
}

// Close releases the DB snapshot. Idempotent.
func (s *IndexStream) Close() {}
