// SPDX-License-Identifier: MIT

package psybridge

import (
	"iter"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

// fakeIndexDB stores one device's rows with increasing local sequences.
type fakeIndexDB struct {
	rows      []protocol.FileInfo // Sequence = local DB sequence
	remoteSeq int64
	queries   int
}

func (f *fakeIndexDB) GetDeviceSequence(string, protocol.DeviceID) (int64, error) { return f.remoteSeq, nil }

func (f *fakeIndexDB) AllLocalFilesBySequence(_ string, _ protocol.DeviceID, start int64, limit int) (iter.Seq[protocol.FileInfo], func() error) {
	f.queries++
	return func(yield func(protocol.FileInfo) bool) {
		n := 0
		for _, r := range f.rows {
			if r.Sequence < start {
				continue
			}
			if limit > 0 && n >= limit {
				return
			}
			n++
			if !yield(r) {
				return
			}
		}
	}, func() error { return nil }
}

// apply stores a batch the way upstream does: new local sequences (with a
// gap, as other devices' rows interleave).
func (f *fakeIndexDB) apply(n, blocksEach int) {
	next := int64(1)
	if len(f.rows) > 0 {
		next = f.rows[len(f.rows)-1].Sequence + 7
	}
	for i := 0; i < n; i++ {
		f.rows = append(f.rows, protocol.FileInfo{Sequence: next + int64(i), Blocks: make([]protocol.BlockInfo, blocksEach)})
	}
	f.remoteSeq += int64(n)
}

var testPeer = protocol.DeviceID{1, 2, 3}

type testClock struct{ t time.Time }

func (c *testClock) now() time.Time { return c.t }

func newTestTracker(db indexDB) (*indexTracker, *testClock) {
	clock := &testClock{t: time.Date(2026, 11, 23, 0, 0, 0, 0, time.UTC)}
	tr := newIndexTracker(db, "", []string{"f"})
	tr.now = clock.now
	return tr, clock
}

func TestTailBlocksFindsTheLastBatch(t *testing.T) {
	db := &fakeIndexDB{}
	for i := 0; i < 50; i++ {
		db.apply(1000, 0) // 50k deletes
	}
	db.apply(300, 20) // 300 photos, 20 blocks each
	blocks, start, err := tailBlocks(db, "f", testPeer, 300, 1)
	if err != nil || blocks != 6000 {
		t.Fatalf("blocks=%d err=%v, want 6000", blocks, err)
	}
	if first, before := db.rows[len(db.rows)-300].Sequence, db.rows[len(db.rows)-301].Sequence; start > first || start <= before {
		t.Fatalf("start=%d, want in (%d, %d]", start, before, first)
	}
	// The hint makes the next search cheap and still exact.
	db.queries = 0
	db.apply(10, 3)
	blocks, _, _ = tailBlocks(db, "f", testPeer, 10, start)
	if blocks != 30 {
		t.Fatalf("blocks=%d, want 30", blocks)
	}
}

func TestPhaseFollowsUpstreamBatchRule(t *testing.T) {
	db := &fakeIndexDB{}
	tr, clock := newTestTracker(db)
	tr.clusterConfig(testPeer)

	// Never received anything: awaiting (the first batch is due).
	if p, _ := tr.phase("f", testPeer, 0); p != IndexPhaseAwaiting {
		t.Fatalf("before first batch: %s", p)
	}
	// Full batches by count (tombstones): receiving, however slow.
	for i := 0; i < 3; i++ {
		db.apply(1000, 0)
		tr.batch("f", testPeer, 1000, db.remoteSeq)
		clock.t = clock.t.Add(10 * time.Second)
		if p, n := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseReceiving || n != int64(1000*(i+1)) {
			t.Fatalf("after full batch %d: %s %d", i, p, n)
		}
	}
	// Full by blocks (fewer than 1000 entries): still receiving.
	db.apply(250, 20)
	tr.batch("f", testPeer, 250, db.remoteSeq)
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseReceiving {
		t.Fatalf("after block-full batch: %s", p)
	}
	// The short batch drains the backlog: complete at once.
	db.apply(17, 1)
	tr.batch("f", testPeer, 17, db.remoteSeq)
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseComplete {
		t.Fatalf("after short batch: %s", p)
	}
}

func TestPhaseQuietCases(t *testing.T) {
	db := &fakeIndexDB{}
	tr, clock := newTestTracker(db)
	tr.clusterConfig(testPeer)

	// Index known from before and nothing pending: complete right away
	// (delta index with nothing new sends no batch at all).
	if p, _ := tr.phase("f", testPeer, 42); p != IndexPhaseComplete {
		t.Fatalf("known index: %s", p)
	}
	// A cut-off transfer resumes as awaiting until the peer speaks again.
	db.apply(1000, 0)
	tr.batch("f", testPeer, 1000, db.remoteSeq)
	tr.disconnected(testPeer)
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseDisconnected {
		t.Fatalf("disconnected: %s", p)
	}
	clock.t = clock.t.Add(time.Minute)
	tr.clusterConfig(testPeer)
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseAwaiting {
		t.Fatalf("resumed after cut-off: %s", p)
	}
	// Another folder's batches keep the timer from running out (one
	// connection delivers index messages in order).
	for i := 0; i < 4; i++ {
		clock.t = clock.t.Add(10 * time.Second)
		tr.batch("other", testPeer, 1000, 1)
	}
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseAwaiting {
		t.Fatalf("behind another folder: %s", p)
	}
	// Silence: the backlog was an exact multiple of the batch size.
	clock.t = clock.t.Add(indexQuietGrace)
	if p, _ := tr.phase("f", testPeer, db.remoteSeq); p != IndexPhaseComplete {
		t.Fatalf("after silence: %s", p)
	}
	if tr.incomplete[indexKey("f", testPeer)] {
		t.Fatal("cut-off flag kept after resolution")
	}
}

func TestIncompleteSurvivesRestart(t *testing.T) {
	home := t.TempDir()
	db := &fakeIndexDB{}
	tr := newIndexTracker(db, home, []string{"f"})
	tr.clusterConfig(testPeer)
	db.apply(1000, 0)
	tr.batch("f", testPeer, 1000, db.remoteSeq)

	again := newIndexTracker(db, home, []string{"f"})
	again.clusterConfig(testPeer)
	if p, _ := again.phase("f", testPeer, db.remoteSeq); p != IndexPhaseAwaiting {
		t.Fatalf("after restart: %s", p)
	}
	// Removing the folder forgets it.
	again.folders(nil)
	if len(readIndexProgress(home)) != 0 {
		t.Fatal("removed folder still listed")
	}
}

func TestFolderStartRestartsTheWait(t *testing.T) {
	db := &fakeIndexDB{}
	tr, clock := newTestTracker(db)
	tr.folders(nil)
	tr.clusterConfig(testPeer)
	clock.t = clock.t.Add(time.Hour)
	// Folder added (or resumed) long after the connection came up.
	tr.folders([]string{"f"})
	if p, _ := tr.phase("f", testPeer, 0); p != IndexPhaseAwaiting {
		t.Fatalf("new folder: %s", p)
	}
}
