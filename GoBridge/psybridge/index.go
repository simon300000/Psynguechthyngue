// SPDX-License-Identifier: MIT

package psybridge

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"iter"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

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

	mu     sync.Mutex
	db     dbQueries
	open   func()
	next   func() (indexMeta, bool)
	stop   func()
	errFn  func() error
	closed bool
	done   bool
}

// dbQueries is the subset of upstream's (internal) db.DB interface the bridge
// uses directly. Only lib/protocol types appear in the signatures, so we can
// assert it on the value returned by syncthing.OpenDatabase without importing
// an internal package.
type dbQueries interface {
	GetGlobalFile(folder string, file string) (protocol.FileInfo, bool, error)
	GetDeviceFile(folder string, device protocol.DeviceID, file string) (protocol.FileInfo, bool, error)
	GetGlobalAvailability(folder, file string) ([]protocol.DeviceID, error)
}

// indexMeta is the part of upstream db.FileMetadata we read.
type indexMeta struct {
	Name       string
	Sequence   int64
	ModNanos   int64
	Size       int64
	LocalFlags protocol.FlagLocal
	Type       protocol.FileInfoType
	Deleted    bool
}

// IndexEntryJSON mirrors Swift `GlobalIndexEntry`.
type IndexEntryJSON struct {
	Name         string `json:"name"`
	Type         string `json:"type"`
	Size         int64  `json:"size"`
	Modified     string `json:"modified"`
	Deleted      bool   `json:"deleted"`
	Invalid      bool   `json:"invalid"`
	Sequence     int64  `json:"sequence"`
	Version      string `json:"version"`
	BlocksHash   string `json:"blocksHash"`
	LocalPresent bool   `json:"localPresent"`
}

// OpenIndexStream requires a running Engine (App) — the extension never calls it.
func (e *Engine) OpenIndexStream(folderID string) (*IndexStream, error) {
	if folderID == "" {
		return nil, newError(CodeInvalidArgument, "folderID is required")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.rt == nil || e.rt.app == nil || e.rt.app.Internals == nil {
		return nil, newError(CodeNotRunning, "engine is not running")
	}
	if _, ok := e.wrapper.Folder(folderID); !ok {
		return nil, newError(CodeInvalidArgument, "unknown folder %q", folderID)
	}
	internals := e.rt.app.Internals
	s := &IndexStream{folderID: folderID, db: e.sdb}
	// Upstream runs the SQL query as soon as AllGlobalFiles is called and
	// only closes the rows once the iterator is ranged, so the query is
	// deferred to the first Next: an opened-but-unread stream holds nothing.
	s.open = func() {
		seq, errFn := internals.AllGlobalFiles(folderID)
		s.errFn = errFn
		s.next, s.stop = pullAnyThread(func(yield func(indexMeta) bool) {
			for md := range seq {
				if !yield(indexMeta{
					Name: md.Name, Sequence: md.Sequence, ModNanos: md.ModNanos, Size: md.Size,
					LocalFlags: md.LocalFlags, Type: md.Type, Deleted: md.Deleted,
				}) {
					return
				}
			}
		})
	}
	if e.streams == nil {
		e.streams = make(map[*IndexStream]struct{})
	}
	e.streams[s] = struct{}{}
	return s, nil
}

// Next returns the next page as JSON (see IndexEntryJSON).
func (s *IndexStream) Next(maxEntries int64) ([]byte, error) {
	if maxEntries <= 0 {
		return nil, newError(CodeInvalidArgument, "maxEntries must be positive")
	}
	maxEntries = min(maxEntries, 10_000)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, newError(CodeNotRunning, "index stream closed")
	}
	if s.next == nil {
		s.open()
	}
	page := make([]IndexEntryJSON, 0, min(maxEntries, 512))
	for int64(len(page)) < maxEntries && !s.done {
		md, ok := s.next()
		if !ok {
			s.done = true
			if err := s.errFn(); err != nil {
				return nil, newError(CodeDatabase, "iterate global index: %v", err)
			}
			break
		}
		entry, err := s.entry(md)
		if err != nil {
			return nil, err
		}
		page = append(page, entry)
	}
	out, err := json.Marshal(page)
	if err != nil {
		return nil, newError(CodeIO, "encode page: %v", err)
	}
	return out, nil
}

func (s *IndexStream) entry(md indexMeta) (IndexEntryJSON, error) {
	e := IndexEntryJSON{
		Name:     md.Name,
		Type:     entryType(md.Type),
		Size:     md.Size,
		Modified: time.Unix(0, md.ModNanos).UTC().Format(time.RFC3339Nano),
		Deleted:  md.Deleted,
		Invalid:  md.LocalFlags&(protocol.FlagLocalRemoteInvalid|protocol.FlagLocalIgnored|protocol.FlagLocalUnsupported) != 0,
		Sequence: md.Sequence,
	}
	global, ok, err := s.db.GetGlobalFile(s.folderID, md.Name)
	if err != nil {
		return e, newError(CodeDatabase, "global file: %v", err)
	}
	if !ok {
		return e, nil
	}
	e.Version = versionToken(global.Version)
	if global.Type == protocol.FileInfoTypeFile && !global.Deleted {
		e.BlocksHash = blocksHashToken(global)
	}
	local, ok, err := s.db.GetDeviceFile(s.folderID, protocol.LocalDeviceID, md.Name)
	if err != nil {
		return e, newError(CodeDatabase, "local file: %v", err)
	}
	e.LocalPresent = ok && !local.Deleted && !global.Deleted && !local.IsInvalid() && local.Version.Equal(global.Version)
	return e, nil
}

// Close releases the DB snapshot. Idempotent.
func (s *IndexStream) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closeLocked0()
}

// closeLocked is called by the engine (engine mutex held).
func (s *IndexStream) closeLocked() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closeLocked0()
}

func (s *IndexStream) closeLocked0() {
	if s.closed {
		return
	}
	s.closed = true
	if s.stop != nil {
		s.stop()
	}
}

// pullAnyThread is iter.Pull for callers on arbitrary OS threads. Every
// gomobile call arrives as a cgo callback whose goroutine is locked to the
// calling OS thread, and Swift's serial bridge queue does not pin a thread,
// so iter.Pull's coroutine (which must be resumed on the thread that created
// it) aborted the whole process ("coro: OS thread locking must match locking
// at coroutine creation"). A producer goroutine + channel has no such rule.
// stop ends the producer and waits for it, so the upstream DB rows are
// closed when stop returns.
func pullAnyThread[V any](seq iter.Seq[V]) (next func() (V, bool), stop func()) {
	items := make(chan V, 64)
	quit := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		defer close(items)
		for v := range seq {
			select {
			case items <- v:
			case <-quit:
				return
			}
		}
	}()
	var once sync.Once
	next = func() (V, bool) {
		v, ok := <-items
		return v, ok
	}
	stop = func() {
		once.Do(func() { close(quit) })
		<-finished
	}
	return next, stop
}

func entryType(t protocol.FileInfoType) string {
	switch t {
	case protocol.FileInfoTypeDirectory:
		return "directory"
	case protocol.FileInfoTypeFile:
		return "file"
	default:
		return "symlink"
	}
}

// versionToken = base64(sha256(version vector)), counters in upstream's
// canonical (sorted by ID) order, each as big-endian (id, value).
func versionToken(v protocol.Vector) string {
	h := sha256.New()
	var buf [16]byte
	for _, c := range v.Counters {
		binary.BigEndian.PutUint64(buf[:8], uint64(c.ID))
		binary.BigEndian.PutUint64(buf[8:], c.Value)
		h.Write(buf[:])
	}
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func blocksHashToken(f protocol.FileInfo) string {
	bh := f.BlocksHash
	if len(bh) == 0 {
		bh = protocol.BlocksHash(f.Blocks)
	}
	return base64.StdEncoding.EncodeToString(bh)
}
