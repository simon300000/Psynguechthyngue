// SPDX-License-Identifier: MIT

package psybridge

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// RecordRequest identifies a file that FetchFile produced and Swift has
// moved to its final place inside the folder.
type RecordRequest struct {
	HomeDir string
	CertPEM []byte
	KeyPEM  []byte

	FolderID string
	Path     string
	// ExpectedVersion: FetchResult.Version. Required.
	ExpectedVersion string
}

// RecordFetchedFile writes the global FileInfo into the *local* index, exactly
// like the upstream puller does after it downloaded a file. Without it the
// App's next scan finds a file with no local index entry and always gives it
// a brand-new version (scanner: Vector{}.Update(myID)), which peers then
// receive as a conflicting/metadata-only change.
//
// Call it in the extension after FetchFile, after the staged file was renamed
// to <folder>/<Path>, and while still holding the engine lock. It opens only
// the DB (no network, no App) and checks first that the file on disk matches
// the global entry (regular file, size, nanosecond mtime) and that the global
// version still equals ExpectedVersion; otherwise it records nothing and
// returns CodeVersionMismatch (or CodeFileNotFound / CodeIO).
//
// Order matters for safety: record only after the file is in place. If the
// local entry existed while the file was missing and not ignored, the next
// scan would announce a deletion.
func RecordFetchedFile(req *RecordRequest) error {
	if req == nil || req.HomeDir == "" || req.FolderID == "" || req.Path == "" || req.ExpectedVersion == "" {
		return newError(CodeInvalidArgument, "HomeDir, FolderID, Path and ExpectedVersion are required")
	}
	_, myID, err := parseIdentity(req.CertPEM, req.KeyPEM)
	if err != nil {
		return err
	}
	if err := acquireProcess("record"); err != nil {
		return err
	}
	defer releaseProcess("record", false)
	if err := configureLocations(req.HomeDir); err != nil {
		return err
	}
	installLogSink(fetchLogSink())

	raw, err := os.ReadFile(locations.Get(locations.ConfigFile))
	if err != nil {
		return newError(CodeConfig, "read config: %v", err)
	}
	cfg, _, err := config.ReadXML(bytes.NewReader(raw), myID)
	if err != nil {
		return newError(CodeConfig, "parse config: %v", err)
	}
	folder, _, ok := cfg.Folder(req.FolderID)
	if !ok {
		return newError(CodeFileNotFound, "folder %q is not configured", req.FolderID)
	}

	sdb, err := syncthing.OpenDatabase(locations.Get(locations.Database), dbDeleteRetention)
	if err != nil {
		return newError(CodeDatabase, "%v", err)
	}
	defer sdb.Close()
	queries, ok := sdb.(dbQueries)
	if !ok {
		return newError(CodeDatabase, "upstream DB lacks expected query methods")
	}

	global, found, err := queries.GetGlobalFile(req.FolderID, req.Path)
	if err != nil {
		return newError(CodeDatabase, "global file: %v", err)
	}
	if !found || global.Deleted || global.IsInvalid() || global.Type != protocol.FileInfoTypeFile {
		return newError(CodeFileNotFound, "%s is not a file in the global index", req.Path)
	}
	if versionToken(global.Version) != req.ExpectedVersion {
		return newError(CodeVersionMismatch, "global version changed since the fetch")
	}

	onDisk := filepath.Join(folder.Filesystem().URI(), filepath.FromSlash(req.Path))
	st, err := os.Lstat(onDisk)
	if err != nil {
		return newError(CodeIO, "stat committed file: %v", err)
	}
	if !st.Mode().IsRegular() || st.Size() != global.Size || !st.ModTime().Equal(global.ModTime()) {
		return newError(CodeVersionMismatch, "file on disk does not match the fetched version")
	}

	local, found, err := queries.GetDeviceFile(req.FolderID, protocol.LocalDeviceID, req.Path)
	if err != nil {
		return newError(CodeDatabase, "local file: %v", err)
	}
	if found && !local.IsInvalid() && !local.Deleted && local.Version.Equal(global.Version) {
		return nil // already recorded
	}

	entry := global
	entry.LocalFlags = 0
	entry.Sequence = 0 // assigned by the DB for the local device
	if err := updateLocal(sdb, req.FolderID, entry); err != nil {
		return newError(CodeDatabase, "record local file: %v", err)
	}
	return nil
}

// updateLocal calls upstream db.DB.Update(folder, LocalDeviceID, files).
// Update's variadic option type lives in an internal package, so it cannot
// appear in an interface we declare; reflection calls it without naming it.
func updateLocal(sdb any, folder string, f protocol.FileInfo) error {
	m := reflect.ValueOf(sdb).MethodByName("Update")
	if !m.IsValid() {
		return newError(CodeDatabase, "upstream DB has no Update method")
	}
	out := m.Call([]reflect.Value{
		reflect.ValueOf(folder),
		reflect.ValueOf(protocol.LocalDeviceID),
		reflect.ValueOf([]protocol.FileInfo{f}),
	})
	if err, _ := out[0].Interface().(error); err != nil {
		return err
	}
	return nil
}
