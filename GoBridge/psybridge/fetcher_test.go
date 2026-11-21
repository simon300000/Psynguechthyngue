// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/protocol"
)

type fakePeer struct {
	connected bool
	delay     time.Duration
	data      []byte
	err       error
}

func (p *fakePeer) IsConnectedTo(protocol.DeviceID) bool { return p.connected }
func (p *fakePeer) DownloadBlock(ctx context.Context, _ protocol.DeviceID, _ string, _ string, _ int, b protocol.BlockInfo, _ bool) ([]byte, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(p.delay):
	}
	if p.err != nil {
		return nil, p.err
	}
	return p.data[b.Offset : b.Offset+int64(b.Size)], nil
}

func testFetcher(t *testing.T, peer *fakePeer, deadline time.Duration, data []byte) (*fetcher, string) {
	sum := sha256.Sum256(data)
	file := protocol.FileInfo{Name: "x", Size: int64(len(data)), Blocks: []protocol.BlockInfo{{Hash: sum[:], Offset: 0, Size: len(data)}}}
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	t.Cleanup(cancel)
	dev, _ := protocol.DeviceIDFromString("7777777-777777N-7777777-777777N-7777777-777777N-7777777-77777Q4")
	return &fetcher{
		ctx: ctx, cancelled: func() bool { return false }, internals: peer, folder: "f", file: file,
		candidates: []protocol.DeviceID{dev}, graceEnd: time.Now().Add(time.Hour), served: map[protocol.DeviceID]bool{},
	}, filepath.Join(t.TempDir(), "dest")
}

func TestFetcherOutcomes(t *testing.T) {
	data := []byte("hello restricted core")
	cases := []struct {
		name string
		peer *fakePeer
		want string
	}{
		{"ok", &fakePeer{connected: true, data: data}, ""},
		{"never connected", &fakePeer{connected: false}, CodeNoPeer},
		{"slow peer hits deadline", &fakePeer{connected: true, delay: time.Hour, data: data}, CodeDeadline},
		{"peer lacks content", &fakePeer{connected: true, err: protocol.ErrNoSuchFile}, CodeHashMismatch},
		{"wrong bytes", &fakePeer{connected: true, data: []byte("HELLO restricted core")}, CodeHashMismatch},
		{"transport error", &fakePeer{connected: true, err: errors.New("reset")}, CodeNoPeer},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f, dest := testFetcher(t, c.peer, 300*time.Millisecond, data)
			err := f.run(dest)
			if got := codeOf(err); got != c.want {
				t.Fatalf("code = %q (%v), want %q", got, err, c.want)
			}
			if c.want == "" {
				got, _ := os.ReadFile(dest)
				if string(got) != string(data) {
					t.Fatalf("content %q", got)
				}
			}
		})
	}
}

func TestFetcherCancelled(t *testing.T) {
	data := []byte("abc")
	f, dest := testFetcher(t, &fakePeer{connected: true, delay: time.Hour, data: data}, time.Hour, data)
	ctx, cancel := context.WithCancel(f.ctx)
	f.ctx = ctx
	f.cancelled = watchCancellation(ctx, cancel, cancelAfter{})
	if err := f.run(dest); codeOf(err) != CodeCancelled {
		t.Fatalf("got %v", err)
	}
}

type cancelAfter struct{}

func (cancelAfter) Progress(int64, int64) {}
func (cancelAfter) IsCancelled() bool     { return true }
