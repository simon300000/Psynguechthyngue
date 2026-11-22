// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"encoding/json"
	"iter"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// Index reception ("is the peer's file list complete?").
//
// Upstream does not keep the max sequence a peer announces in its
// ClusterConfig (it is used once to pick the delta start and dropped), and
// patching upstream is not allowed (DESIGN.md §3.4). What the protocol does
// guarantee is how the sender batches: upstream's index sender sends its
// backlog in batches that are "full" — at least model.MaxBatchSizeFiles
// entries or model.MaxBatchSizeBlocks blocks — until the backlog is drained,
// and the batch that drains it is not full. So:
//
//   - a full batch:      more is coming ("receiving");
//   - a short batch:     the peer's index is complete up to now;
//   - nothing since the connection (or folder) started: nothing new to send,
//     or the first batch is still on its way. That cannot be told apart from
//     the wire, so it is "awaiting" only when we know data is due (we never
//     received this peer's index for the folder, or the last connection ended
//     mid-transfer), for indexQuietGrace after the device last sent anything.
//
// One connection delivers index messages for all folders in order, so a
// folder's first batch can queue behind another folder's transfer; every
// quiet timer therefore runs from the device's last batch of any folder.
const (
	indexBatchMaxFiles  = model.MaxBatchSizeFiles
	indexBatchMaxBlocks = model.MaxBatchSizeBlocks
	indexQuietGrace     = 15 * time.Second
	indexProgressFile   = "index-progress.json"
)

// Phases reported per (folder, peer).
const (
	IndexPhaseReceiving    = "receiving"
	IndexPhaseAwaiting     = "awaiting"
	IndexPhaseComplete     = "complete"
	IndexPhaseDisconnected = "disconnected"
	// Disconnected while its index is known to be incomplete (a transfer
	// was cut off, or it never sent one): what we have is partial.
	IndexPhaseInterrupted = "interrupted"
)

// indexDB is what the tracker reads from upstream's DB.
type indexDB interface {
	GetDeviceSequence(folder string, device protocol.DeviceID) (int64, error)
	AllLocalFilesBySequence(folder string, device protocol.DeviceID, startSeq int64, limit int) (iter.Seq[protocol.FileInfo], func() error)
}

// countsDB adds the counters FolderIndexState reports (read straight from the
// DB, so they also work for a paused folder, whose REST summary is all zero).
type countsDB interface {
	indexDB
	CountGlobal(folder string) (syncthing.Counts, error)
	CountLocal(folder string, device protocol.DeviceID) (syncthing.Counts, error)
}

type trackedFolder struct {
	lastBatchAt   time.Time
	lastBatchFull bool
	received      int64 // entries received on this connection
	tailHint      int64 // lower bound for the next tail search (local DB sequence)
}

type trackedDevice struct {
	connectedAt time.Time // last ClusterConfig from the device
	lastBatchAt time.Time // last index batch of any folder
	folders     map[string]*trackedFolder
}

type indexTracker struct {
	mu          sync.Mutex
	db          indexDB
	now         func() time.Time
	homeDir     string
	devices     map[protocol.DeviceID]*trackedDevice
	folderStart map[string]time.Time
	running     map[string]bool
	incomplete  map[string]bool // "folder|device": a transfer was cut off
}

func newIndexTracker(db indexDB, homeDir string, running []string) *indexTracker {
	t := &indexTracker{
		db: db, now: time.Now, homeDir: homeDir,
		devices:     make(map[protocol.DeviceID]*trackedDevice),
		folderStart: make(map[string]time.Time),
		running:     make(map[string]bool),
		incomplete:  readIndexProgress(homeDir),
	}
	for _, f := range running {
		t.running[f] = true
	}
	return t
}

func indexKey(folder string, dev protocol.DeviceID) string { return folder + "|" + dev.String() }

// run consumes upstream events until ctx ends. Subscribe before the App
// starts so the first ClusterConfig is not missed.
func (t *indexTracker) subscribe(ctx context.Context, evLogger events.Logger) {
	sub := evLogger.Subscribe(events.ClusterConfigReceived | events.RemoteIndexUpdated |
		events.DeviceDisconnected | events.ConfigSaved)
	go func() {
		defer sub.Unsubscribe()
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-sub.C():
				if !ok {
					return
				}
				t.handle(ev)
			}
		}
	}()
}

func (t *indexTracker) handle(ev events.Event) {
	switch ev.Type {
	case events.ClusterConfigReceived:
		if d, ok := ev.Data.(model.ClusterConfigReceivedEventData); ok {
			t.clusterConfig(d.Device)
		}
	case events.DeviceDisconnected:
		if d, ok := ev.Data.(map[string]string); ok {
			if id, err := protocol.DeviceIDFromString(d["id"]); err == nil {
				t.disconnected(id)
			}
		}
	case events.RemoteIndexUpdated:
		d, ok := ev.Data.(map[string]any)
		if !ok {
			return
		}
		folder, _ := d["folder"].(string)
		devStr, _ := d["device"].(string)
		dev, err := protocol.DeviceIDFromString(devStr)
		if folder == "" || err != nil {
			return
		}
		t.batch(folder, dev, toInt64(d["items"]), toInt64(d["sequence"]))
	case events.ConfigSaved:
		if cfg, ok := ev.Data.(config.Configuration); ok {
			var running []string
			for _, f := range cfg.Folders {
				if !f.Paused {
					running = append(running, f.ID)
				}
			}
			t.folders(running)
		}
	}
}

func toInt64(v any) int64 {
	switch n := v.(type) {
	case int:
		return int64(n)
	case int64:
		return n
	case float64:
		return int64(n)
	}
	return 0
}

func (t *indexTracker) clusterConfig(dev protocol.DeviceID) {
	t.mu.Lock()
	defer t.mu.Unlock()
	d := t.devices[dev]
	if d == nil {
		d = &trackedDevice{folders: make(map[string]*trackedFolder)}
		t.devices[dev] = d
	}
	d.connectedAt = t.now()
}

func (t *indexTracker) disconnected(dev protocol.DeviceID) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.devices, dev)
}

// folders records which folders run; a folder that starts (added, resumed)
// starts its quiet timer: our ClusterConfig makes the peer send its index.
func (t *indexTracker) folders(running []string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	next := make(map[string]bool, len(running))
	for _, f := range running {
		next[f] = true
		if !t.running[f] {
			t.folderStart[f] = now
		}
	}
	changed := false
	for f := range t.running {
		if !next[f] {
			delete(t.folderStart, f)
			for k := range t.incomplete {
				if strings.HasPrefix(k, f+"|") {
					delete(t.incomplete, k)
					changed = true
				}
			}
		}
	}
	t.running = next
	if changed {
		t.persistLocked()
	}
}

func (t *indexTracker) batch(folder string, dev protocol.DeviceID, items, sequence int64) {
	t.mu.Lock()
	d := t.devices[dev]
	if d == nil {
		// Batch before (or without) the ClusterConfig event: the device is
		// evidently connected.
		d = &trackedDevice{folders: make(map[string]*trackedFolder), connectedAt: t.now()}
		t.devices[dev] = d
	}
	f := d.folders[folder]
	if f == nil {
		f = &trackedFolder{}
		d.folders[folder] = f
	}
	hint := f.tailHint
	t.mu.Unlock()

	full, nextHint := t.isFull(folder, dev, items, sequence, hint)

	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	d.lastBatchAt = now
	f.lastBatchAt = now
	f.lastBatchFull = full
	f.received += items
	if nextHint > f.tailHint {
		f.tailHint = nextHint
	}
	key := indexKey(folder, dev)
	if t.incomplete[key] != full {
		if full {
			t.incomplete[key] = true
		} else {
			delete(t.incomplete, key)
		}
		t.persistLocked()
	}
}

// isFull applies upstream's batch rule to the batch just applied.
func (t *indexTracker) isFull(folder string, dev protocol.DeviceID, items, sequence, hint int64) (bool, int64) {
	if items >= indexBatchMaxFiles {
		return true, hint
	}
	if t.db == nil {
		return false, hint
	}
	// A later batch is already in the DB: the peer is evidently still
	// sending (its own event decides).
	if cur, err := t.db.GetDeviceSequence(folder, dev); err == nil && cur > sequence {
		return true, hint
	}
	blocks, start, err := tailBlocks(t.db, folder, dev, int(items), hint)
	if err != nil {
		return false, hint
	}
	return blocks >= indexBatchMaxBlocks, start
}

// tailBlocks sums the blocks of the device's `n` most recently stored files
// (the batch just applied: rows get increasing local DB sequences). Upstream
// has no descending iterator, so the start of the tail is found by search:
// countFrom(s) = rows with local sequence >= s (capped at n+1) is
// non-increasing in s.
func tailBlocks(db indexDB, folder string, dev protocol.DeviceID, n int, lo int64) (blocks int, start int64, err error) {
	if n <= 0 {
		return 0, lo, nil
	}
	countFrom := func(s int64) (int, error) {
		seq, errFn := db.AllLocalFilesBySequence(folder, dev, s, n+1)
		c := 0
		for range seq {
			c++
		}
		return c, errFn()
	}
	if lo < 1 {
		lo = 1
	}
	if c, err := countFrom(lo); err != nil {
		return 0, lo, err
	} else if c <= n {
		start = lo
	} else {
		hi := lo * 2
		for {
			c, err := countFrom(hi)
			if err != nil {
				return 0, lo, err
			}
			if c <= n {
				break
			}
			lo, hi = hi, hi*2
		}
		// countFrom(lo) > n, countFrom(hi) <= n: find the smallest such hi.
		for hi-lo > 1 {
			mid := lo + (hi-lo)/2
			c, err := countFrom(mid)
			if err != nil {
				return 0, lo, err
			}
			if c <= n {
				hi = mid
			} else {
				lo = mid
			}
		}
		start = hi
	}
	seq, errFn := db.AllLocalFilesBySequence(folder, dev, start, n)
	for fi := range seq {
		blocks += len(fi.Blocks)
	}
	return blocks, start, errFn()
}

// IndexPeerState is one peer's index reception for a folder.
type IndexPeerState struct {
	Device string `json:"device"`
	Phase  string `json:"phase"`
	// Entries received from the peer on this connection (all kinds, deletes
	// included).
	Received int64 `json:"received"`
	// Entries of the peer's index stored here (files, directories, symlinks,
	// deletes), across connections.
	Entries int64 `json:"entries"`
	Deleted int64 `json:"deleted"`
	// Peer's highest sequence we have (change fingerprint).
	Sequence int64 `json:"sequence"`
}

func (t *indexTracker) peerStates(folder string, peers []protocol.DeviceID, counts countsDB) []IndexPeerState {
	out := make([]IndexPeerState, 0, len(peers))
	for _, dev := range peers {
		s := IndexPeerState{Device: dev.String()}
		if counts != nil {
			s.Sequence, _ = counts.GetDeviceSequence(folder, dev)
			if c, err := counts.CountLocal(folder, dev); err == nil {
				s.Entries = int64(c.Files + c.Directories + c.Symlinks + c.Deleted)
				s.Deleted = int64(c.Deleted)
			}
		}
		s.Phase, s.Received = t.phase(folder, dev, s.Sequence)
		out = append(out, s)
	}
	return out
}

// phase of (folder, dev); sequence is our highest sequence from dev (0: we
// never received its index for this folder).
func (t *indexTracker) phase(folder string, dev protocol.DeviceID, sequence int64) (string, int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	d := t.devices[dev]
	key := indexKey(folder, dev)
	if d == nil {
		if t.incomplete[key] || sequence == 0 {
			return IndexPhaseInterrupted, 0
		}
		return IndexPhaseDisconnected, 0
	}
	now := t.now()
	started := d.connectedAt
	if s := t.folderStart[folder]; s.After(started) {
		started = s
	}
	quietSince := started
	if d.lastBatchAt.After(quietSince) {
		quietSince = d.lastBatchAt
	}
	f := d.folders[folder]
	var received int64
	if f != nil {
		received = f.received
	}
	if f != nil && !f.lastBatchAt.Before(started) {
		if !f.lastBatchFull {
			return IndexPhaseComplete, received
		}
		if now.Sub(d.lastBatchAt) < indexQuietGrace {
			return IndexPhaseReceiving, received
		}
		// A full last batch and then silence: the backlog was an exact
		// multiple of the batch size.
		t.resolveLocked(key)
		return IndexPhaseComplete, received
	}
	if t.incomplete[key] || sequence == 0 {
		if now.Sub(quietSince) < indexQuietGrace {
			return IndexPhaseAwaiting, received
		}
		t.resolveLocked(key)
	}
	return IndexPhaseComplete, received
}

func (t *indexTracker) resolveLocked(key string) {
	if t.incomplete[key] {
		delete(t.incomplete, key)
		t.persistLocked()
	}
}

func readIndexProgress(homeDir string) map[string]bool {
	out := make(map[string]bool)
	if homeDir == "" {
		return out
	}
	data, err := os.ReadFile(filepath.Join(homeDir, indexProgressFile))
	if err != nil {
		return out
	}
	var file struct {
		Incomplete []string `json:"incomplete"`
	}
	if json.Unmarshal(data, &file) == nil {
		for _, k := range file.Incomplete {
			out[k] = true
		}
	}
	return out
}

func (t *indexTracker) persistLocked() {
	if t.homeDir == "" {
		return
	}
	keys := make([]string, 0, len(t.incomplete))
	for k := range t.incomplete {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	data, err := json.Marshal(struct {
		Incomplete []string `json:"incomplete"`
	}{keys})
	if err != nil {
		return
	}
	path := filepath.Join(t.homeDir, indexProgressFile)
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, path)
	}
}

// FolderIndexStateJSON mirrors Swift `FolderIndexState`.
type FolderIndexStateJSON struct {
	GlobalFiles       int64            `json:"globalFiles"`
	GlobalDirectories int64            `json:"globalDirectories"`
	GlobalSymlinks    int64            `json:"globalSymlinks"`
	GlobalDeleted     int64            `json:"globalDeleted"`
	GlobalBytes       int64            `json:"globalBytes"`
	LocalFiles        int64            `json:"localFiles"`
	LocalDirectories  int64            `json:"localDirectories"`
	LocalSymlinks     int64            `json:"localSymlinks"`
	LocalDeleted      int64            `json:"localDeleted"`
	LocalBytes        int64            `json:"localBytes"`
	LocalSequence     int64            `json:"localSequence"`
	Peers             []IndexPeerState `json:"peers"`
}

// FolderIndexState reports, for one folder, the DB counters (valid for a
// paused folder too) and per shared peer whether its index is still arriving.
func (e *Engine) FolderIndexState(folderID string) ([]byte, error) {
	e.mu.Lock()
	tracker, sdb, wrapper, myID := e.index, e.sdb, e.wrapper, e.myID
	running := e.rt != nil
	e.mu.Unlock()
	if !running || sdb == nil || wrapper == nil {
		return nil, newError(CodeNotRunning, "engine is not running")
	}
	fcfg, ok := wrapper.Folder(folderID)
	if !ok {
		return nil, newError(CodeInvalidArgument, "unknown folder %q", folderID)
	}
	counts, _ := sdb.(countsDB)
	out := FolderIndexStateJSON{Peers: []IndexPeerState{}}
	if counts != nil {
		if g, err := counts.CountGlobal(folderID); err == nil {
			out.GlobalFiles, out.GlobalDirectories, out.GlobalSymlinks = int64(g.Files), int64(g.Directories), int64(g.Symlinks)
			out.GlobalDeleted, out.GlobalBytes = int64(g.Deleted), g.Bytes
		}
		if l, err := counts.CountLocal(folderID, protocol.LocalDeviceID); err == nil {
			out.LocalFiles, out.LocalDirectories, out.LocalSymlinks = int64(l.Files), int64(l.Directories), int64(l.Symlinks)
			out.LocalDeleted, out.LocalBytes = int64(l.Deleted), l.Bytes
		}
		out.LocalSequence, _ = counts.GetDeviceSequence(folderID, protocol.LocalDeviceID)
	}
	var peers []protocol.DeviceID
	for _, d := range fcfg.Devices {
		if d.DeviceID != myID {
			peers = append(peers, d.DeviceID)
		}
	}
	if tracker != nil {
		out.Peers = tracker.peerStates(folderID, peers, counts)
	}
	data, err := json.Marshal(out)
	if err != nil {
		return nil, newError(CodeIO, "encode index state: %v", err)
	}
	return data, nil
}
