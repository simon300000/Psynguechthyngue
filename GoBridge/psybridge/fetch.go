// SPDX-License-Identifier: MIT

package psybridge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

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

// FetchProgress is called from bridge goroutines: Progress from the fetch
// loop, IsCancelled from a watcher that polls every 100 ms. The two may run
// concurrently, so implementations must be thread-safe.
type FetchProgress interface {
	// Progress reports bytes completed / total.
	Progress(completed int64, total int64)
	// IsCancelled is polled between blocks; returning true aborts with CodeCancelled.
	IsCancelled() bool
}

// FetchFile performs the restricted fetch. Blocking; Swift calls it from a
// dedicated thread (never the cooperative pool).
func FetchFile(req *FetchRequest, progress FetchProgress) (result *FetchResult, err error) {
	if req == nil || req.FolderID == "" || req.Path == "" || req.DestinationPath == "" {
		return nil, newError(CodeInvalidArgument, "FolderID, Path and DestinationPath are required")
	}
	if req.HomeDir == "" {
		return nil, newError(CodeInvalidArgument, "HomeDir is required")
	}
	start := time.Now()
	deadline := start.Add(millis(req.DeadlineMillis, DefaultFetchDeadlineMillis*time.Millisecond))
	maxBytes := req.MaxFileBytes
	if maxBytes <= 0 {
		maxBytes = DefaultFetchMaxFileBytes
	}
	cert, myID, err := parseIdentity(req.CertPEM, req.KeyPEM)
	if err != nil {
		return nil, err
	}
	if err := acquireProcess("fetch"); err != nil {
		return nil, err
	}
	rt := &upstreamRuntime{}
	defer func() {
		poisoned := !rt.stop(10 * time.Second)
		releaseProcess("fetch", poisoned)
		if poisoned && err == nil {
			err = newError(CodeStopTimeout, "restricted core did not stop")
			result = nil
		}
	}()

	applyRuntimeProfile(req.MemoryLimitMiB, 0, 2, DefaultRestrictedMemoryLimitMiB, DefaultRestrictedGCPercent, 2)
	if err := configureLocations(req.HomeDir); err != nil {
		return nil, err
	}
	installLogSink(nil, "")

	// In-memory config derivative; never written back (Wrap with no path).
	raw, err := os.ReadFile(locations.Get(locations.ConfigFile))
	if err != nil {
		return nil, newError(CodeConfig, "read config: %v", err)
	}
	base, _, err := config.ReadXML(bytes.NewReader(raw), myID)
	if err != nil {
		return nil, newError(CodeConfig, "parse config: %v", err)
	}
	folderCfg, ok := restrictConfig(&base, myID, req.FolderID)
	if !ok {
		return nil, newError(CodeFileNotFound, "folder %q is not configured", req.FolderID)
	}

	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	cancelled := watchCancellation(ctx, cancel, progress)

	evLogger, early, earlyCancel, earlyDone := newEarlySupervisor()
	rt.earlyCancel, rt.earlyDone = earlyCancel, earlyDone
	cfg := config.Wrap("", base, myID, evLogger)
	early.Add(cfg)

	sdb, err := syncthing.OpenDatabase(locations.Get(locations.Database), dbDeleteRetention)
	if err != nil {
		return nil, newError(CodeDatabase, "%v", err)
	}
	rt.db = sdb
	queries, ok := sdb.(dbQueries)
	if !ok {
		return nil, newError(CodeDatabase, "upstream DB lacks expected query methods")
	}

	// Check the index before touching the network.
	global, found, err := queries.GetGlobalFile(req.FolderID, req.Path)
	if err != nil {
		return nil, newError(CodeDatabase, "global file: %v", err)
	}
	if !found || global.Deleted || global.IsInvalid() || global.Type != protocol.FileInfoTypeFile {
		return nil, newError(CodeFileNotFound, "%s is not a file in the global index", req.Path)
	}
	version := versionToken(global.Version)
	if req.ExpectedVersion != "" && req.ExpectedVersion != version {
		return nil, newError(CodeVersionMismatch, "index has a different version")
	}
	if global.Size > maxBytes {
		return nil, newError(CodeTooLarge, "%d bytes exceeds the %d byte budget", global.Size, maxBytes)
	}
	holders, _ := queries.GetGlobalAvailability(req.FolderID, req.Path)
	candidates := candidateDevices(folderCfg, myID, holders)
	if len(candidates) == 0 {
		return nil, newError(CodeNoPeer, "no other device shares folder %q", req.FolderID)
	}

	app, err := syncthing.New(cfg, sdb, evLogger, cert, syncthing.Options{NoUpgrade: true, DBMaintenanceInterval: 0})
	if err != nil {
		return nil, newError(CodeDatabase, "create app: %v", err)
	}
	rt.app = app
	if err := app.Start(); err != nil {
		return nil, wrapUpstream(CodeDatabase, "start", err)
	}

	graceEnd := time.Now().Add(DefaultFetchConnectGraceMillis * time.Millisecond)
	if graceEnd.After(deadline) {
		graceEnd = deadline
	}
	f := &fetcher{
		ctx: ctx, cancelled: cancelled, internals: app.Internals, folder: req.FolderID,
		file: global, candidates: candidates, graceEnd: graceEnd, progress: progress,
		served: map[protocol.DeviceID]bool{},
	}
	if err := f.run(req.DestinationPath); err != nil {
		os.Remove(req.DestinationPath)
		return nil, err
	}

	servedBy := make([]string, 0, len(f.served))
	for _, id := range candidates {
		if f.served[id] {
			servedBy = append(servedBy, id.String())
		}
	}
	return &FetchResult{
		Size:        global.Size,
		ModifiedUTC: global.ModTime().UTC().Format(time.RFC3339Nano),
		Version:     version,
		BlocksHash:  blocksHashToken(global),
		ServedBy:    strings.Join(servedBy, ","),
	}, nil
}

// restrictConfig turns the persisted config into the restricted-core variant
// (DESIGN.md §6.4) and returns the target folder's configuration.
func restrictConfig(c *config.Configuration, myID protocol.DeviceID, folderID string) (config.FolderConfiguration, bool) {
	var target config.FolderConfiguration
	found := false
	sharing := map[protocol.DeviceID]bool{}
	for i := range c.Folders {
		c.Folders[i].Paused = true
		c.Folders[i].FSWatcherEnabled = false
		if c.Folders[i].ID == folderID {
			target = c.Folders[i]
			found = true
			for _, d := range target.Devices {
				sharing[d.DeviceID] = true
			}
		}
	}
	for i := range c.Devices {
		d := &c.Devices[i]
		if d.DeviceID == myID {
			continue
		}
		// Only talk to devices that share the folder, one connection each.
		if !sharing[d.DeviceID] {
			d.Paused = true
		}
		d.RawNumConnections = 1
	}
	c.GUI.Enabled = false
	c.Options.NATEnabled = false
	c.Options.URAccepted = -1
	c.Options.URUniqueID = ""
	c.Options.CREnabled = false
	c.Options.AutoUpgradeIntervalH = 0
	c.Options.StartBrowser = false
	return target, found
}

// candidateDevices: devices sharing the folder (not us, not paused), the ones
// the index says hold the global version first.
func candidateDevices(f config.FolderConfiguration, myID protocol.DeviceID, holders []protocol.DeviceID) []protocol.DeviceID {
	shared := map[protocol.DeviceID]bool{}
	for _, d := range f.Devices {
		if d.DeviceID != myID {
			shared[d.DeviceID] = true
		}
	}
	var out []protocol.DeviceID
	seen := map[protocol.DeviceID]bool{}
	for _, id := range holders {
		if shared[id] && !seen[id] {
			out = append(out, id)
			seen[id] = true
		}
	}
	for _, d := range f.Devices {
		if shared[d.DeviceID] && !seen[d.DeviceID] {
			out = append(out, d.DeviceID)
			seen[d.DeviceID] = true
		}
	}
	return out
}

// watchCancellation polls progress.IsCancelled and cancels ctx; the returned
// func reports whether cancellation (not the deadline) ended ctx.
func watchCancellation(ctx context.Context, cancel context.CancelFunc, progress FetchProgress) func() bool {
	var mu sync.Mutex
	was := false
	if progress != nil {
		go func() {
			t := time.NewTicker(100 * time.Millisecond)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					if progress.IsCancelled() {
						mu.Lock()
						was = true
						mu.Unlock()
						cancel()
						return
					}
				}
			}
		}()
	}
	return func() bool {
		mu.Lock()
		defer mu.Unlock()
		return was
	}
}

type blockDownloader interface {
	DownloadBlock(ctx context.Context, deviceID protocol.DeviceID, folderID string, path string, blockNumber int, blockInfo protocol.BlockInfo, allowFromTemporary bool) ([]byte, error)
	IsConnectedTo(deviceID protocol.DeviceID) bool
}

type fetcher struct {
	ctx        context.Context
	cancelled  func() bool
	internals  blockDownloader
	folder     string
	file       protocol.FileInfo
	candidates []protocol.DeviceID
	graceEnd   time.Time
	progress   FetchProgress
	served     map[protocol.DeviceID]bool

	everConnected bool
}

func (f *fetcher) ctxErr() error {
	if f.cancelled() {
		return newError(CodeCancelled, "fetch cancelled")
	}
	if errors.Is(f.ctx.Err(), context.DeadlineExceeded) {
		return newError(CodeDeadline, "deadline reached")
	}
	if f.ctx.Err() != nil {
		return newError(CodeCancelled, "fetch cancelled")
	}
	return nil
}

func (f *fetcher) connected() []protocol.DeviceID {
	var out []protocol.DeviceID
	for _, id := range f.candidates {
		if f.internals.IsConnectedTo(id) {
			out = append(out, id)
		}
	}
	return out
}

// waitConnected waits for at least one candidate connection.
func (f *fetcher) waitConnected() ([]protocol.DeviceID, error) {
	for {
		if devs := f.connected(); len(devs) > 0 {
			f.everConnected = true
			return devs, nil
		}
		if err := f.ctxErr(); err != nil {
			if !f.everConnected && ErrorCode(err.Error()) == CodeDeadline {
				return nil, newError(CodeNoPeer, "no device sharing the folder connected before the deadline")
			}
			return nil, err
		}
		if time.Now().After(f.graceEnd) {
			return nil, newError(CodeNoPeer, "no device sharing the folder connected within the grace period")
		}
		select {
		case <-f.ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (f *fetcher) run(dest string) error {
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return newError(CodeIO, "open destination: %v", err)
	}
	defer out.Close()
	total := f.file.Size
	if total > 0 {
		if err := out.Truncate(total); err != nil {
			return newError(CodeIO, "size destination: %v", err)
		}
	}
	report := func(done int64) {
		if f.progress != nil {
			f.progress.Progress(done, total)
		}
	}
	report(0)

	var completed int64
	for i, block := range f.file.Blocks {
		if err := f.ctxErr(); err != nil {
			return err
		}
		data, err := f.fetchBlock(i, block)
		if err != nil {
			return err
		}
		if _, err := out.WriteAt(data, block.Offset); err != nil {
			return newError(CodeIO, "write block: %v", err)
		}
		completed += int64(len(data))
		report(completed)
	}
	if err := out.Sync(); err != nil {
		return newError(CodeIO, "fsync: %v", err)
	}
	if err := out.Close(); err != nil {
		return newError(CodeIO, "close: %v", err)
	}
	mtime := f.file.ModTime()
	_ = os.Chtimes(dest, mtime, mtime)
	return nil
}

// fetchBlock tries every connected candidate (twice each) before giving up.
func (f *fetcher) fetchBlock(index int, block protocol.BlockInfo) ([]byte, error) {
	var lastErr error
	hashMismatch := false
	for attempt := 0; attempt < 2; attempt++ {
		devs, err := f.waitConnected()
		if err != nil {
			if lastErr != nil && hashMismatch {
				return nil, newError(CodeHashMismatch, "block %d: %v", index, lastErr)
			}
			return nil, err
		}
		for _, dev := range devs {
			if err := f.ctxErr(); err != nil {
				return nil, err
			}
			data, err := f.internals.DownloadBlock(f.ctx, dev, f.folder, f.file.Name, index, block, false)
			if err != nil {
				lastErr = err
				if errors.Is(err, protocol.ErrNoSuchFile) || errors.Is(err, protocol.ErrInvalid) {
					// The peer no longer has this content: our index is stale.
					hashMismatch = true
				}
				continue
			}
			sum := sha256.Sum256(data)
			if len(data) != block.Size || !bytes.Equal(sum[:], block.Hash) {
				lastErr = errors.New("block hash differs from the index")
				hashMismatch = true
				continue
			}
			f.served[dev] = true
			return data, nil
		}
		if err := f.ctxErr(); err != nil {
			return nil, err
		}
		select {
		case <-f.ctx.Done():
		case <-time.After(250 * time.Millisecond):
		}
	}
	if hashMismatch {
		return nil, newError(CodeHashMismatch, "block %d: %v", index, lastErr)
	}
	return nil, newError(CodeNoPeer, "block %d unavailable: %v", index, lastErr)
}
