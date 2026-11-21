// SPDX-License-Identifier: MIT

package integration

import (
	"crypto/sha256"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoBridge/psybridge"
)

func randomBytes(n int, seed int64) []byte {
	b := make([]byte, n)
	r := rand.NewChaCha8([32]byte{byte(seed), byte(seed >> 8), byte(seed >> 16), 0x70, 0x73, 0x79})
	_, _ = r.Read(b)
	return b
}

const (
	bigSize   = 100 << 20          // 100 MiB
	crossSize = 2*(128<<10) + 1000 // spans three 128 KiB blocks
)

// TestFetchFile: §10.2 — A is a full engine, B's restricted core fetches
// from it. B first runs as a full engine with ignore-all, so its DB holds the
// global index but no content (the on-demand situation).
func TestFetchFile(t *testing.T) {
	if testing.Short() {
		t.Skip("writes and transfers 100 MiB")
	}
	root := t.TempDir()
	a := newNode(t, root, "A")
	b := newNode(t, root, "B")
	writeConfig(t, a, b)
	writeConfig(t, b, a)
	if err := os.WriteFile(filepath.Join(b.dir, ".stignore"), []byte("*\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	content := map[string][]byte{
		"small.bin":   randomBytes(1024, 1),
		"cross.bin":   randomBytes(crossSize, 2),
		"stale.bin":   randomBytes(1024, 3),
		"dir/big.bin": randomBytes(bigSize, 4),
		"empty.txt":   {},
	}
	for name, data := range content {
		p := filepath.Join(a.dir, filepath.FromSlash(name))
		_ = os.MkdirAll(filepath.Dir(p), 0o700)
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	a.startEngine(t)
	b.startEngine(t)
	eventually(t, 120*time.Second, "B to receive A's index", func() bool {
		for name, data := range content {
			var f struct {
				Global struct {
					Size int64 `json:"size"`
				} `json:"global"`
			}
			if restGet(t, b.endpoint, "/rest/db/file?folder=f&file="+name, &f) != 200 || f.Global.Size != int64(len(data)) {
				return false
			}
		}
		return true
	})
	if _, err := os.Stat(filepath.Join(b.dir, "small.bin")); err == nil {
		t.Fatal("B downloaded content despite ignore-all")
	}
	b.stopEngine(t)
	bConfig, _ := os.ReadFile(filepath.Join(b.home, "config.xml"))

	staging := filepath.Join(root, "B", "Staging")
	_ = os.MkdirAll(staging, 0o700)
	dest := func(name string) string { return filepath.Join(staging, filepath.Base(name)+".part") }

	for _, name := range []string{"small.bin", "cross.bin", "empty.txt", "dir/big.bin"} {
		t.Run("fetch "+name, func(t *testing.T) {
			o := b.fetch(t, helperArgs{Path: name, Dest: dest(name)})
			if o.Error != "" {
				t.Fatalf("FetchFile: %s", o.Error)
			}
			got, err := os.ReadFile(dest(name))
			if err != nil {
				t.Fatal(err)
			}
			if sha256.Sum256(got) != sha256.Sum256(content[name]) {
				t.Fatalf("content differs (%d vs %d bytes)", len(got), len(content[name]))
			}
			if o.Result.Size != int64(len(content[name])) || o.Result.ServedBy != a.id.DeviceID || len(o.Result.Version) != 44 {
				t.Fatalf("result %+v", o.Result)
			}
			if _, err := time.Parse(time.RFC3339Nano, o.Result.ModifiedUTC); err != nil {
				t.Fatal(err)
			}
			t.Logf("%s: %d bytes in %d ms, B peak RSS %.1f MiB (GOMEMLIMIT %d MiB)",
				name, len(got), o.ElapsedMS, float64(o.MaxRSS)/(1<<20), psybridge.DefaultRestrictedMemoryLimitMiB)
			if name == "dir/big.bin" {
				recordRSS(t, o)
			}
		})
	}

	t.Run("expected version", func(t *testing.T) {
		first := b.fetch(t, helperArgs{Path: "small.bin", Dest: dest("v1")})
		if first.Error != "" {
			t.Fatal(first.Error)
		}
		o := b.fetch(t, helperArgs{Path: "small.bin", Dest: dest("v2"), Expected: first.Result.Version})
		if o.Error != "" {
			t.Fatalf("matching ExpectedVersion rejected: %s", o.Error)
		}
		o = b.fetch(t, helperArgs{Path: "small.bin", Dest: dest("v3"), Expected: "bogus"})
		if code(o.Error) != psybridge.CodeVersionMismatch {
			t.Fatalf("got %q", o.Error)
		}
	})

	t.Run("missing file", func(t *testing.T) {
		for _, p := range []string{"nope.bin", "dir"} {
			if o := b.fetch(t, helperArgs{Path: p, Dest: dest("missing")}); code(o.Error) != psybridge.CodeFileNotFound {
				t.Fatalf("%s: got %q", p, o.Error)
			}
		}
		if o := b.fetch(t, helperArgs{Folder: "other", Path: "x", Dest: dest("missing")}); code(o.Error) != psybridge.CodeFileNotFound {
			t.Fatalf("unknown folder: got %q", o.Error)
		}
	})

	t.Run("cancel", func(t *testing.T) {
		o := b.fetch(t, helperArgs{Path: "dir/big.bin", Dest: dest("cancel"), CancelAfter: 1 << 20})
		if code(o.Error) != psybridge.CodeCancelled {
			t.Fatalf("got %q", o.Error)
		}
		if _, err := os.Stat(dest("cancel")); !os.IsNotExist(err) {
			t.Fatal("partial file left behind")
		}
	})

	t.Run("hash mismatch", func(t *testing.T) {
		// A's disk changes behind its index (watcher off, no rescan): A
		// refuses to serve the stale block hash B asks for.
		if err := os.WriteFile(filepath.Join(a.dir, "stale.bin"), randomBytes(1024, 99), 0o600); err != nil {
			t.Fatal(err)
		}
		o := b.fetch(t, helperArgs{Path: "stale.bin", Dest: dest("stale")})
		if code(o.Error) != psybridge.CodeHashMismatch {
			t.Fatalf("got %q", o.Error)
		}
	})

	t.Run("peer offline", func(t *testing.T) {
		a.stopEngine(t)
		o := b.fetch(t, helperArgs{Path: "small.bin", Dest: dest("offline"), Deadline: 3_000})
		if code(o.Error) != psybridge.CodeNoPeer {
			t.Fatalf("got %q", o.Error)
		}
		if o.ElapsedMS > 10_000 {
			t.Fatalf("offline fetch took %d ms", o.ElapsedMS)
		}
	})

	// The restricted core works on an in-memory config: config.xml unchanged.
	if after, _ := os.ReadFile(filepath.Join(b.home, "config.xml")); string(after) != string(bConfig) || len(after) == 0 {
		t.Fatal("restricted fetch modified B's config.xml")
	}
}

func recordRSS(t *testing.T, o fetchOutcome) {
	t.Helper()
	if raceEnabled {
		t.Logf("race detector on: RSS not representative, not recorded")
		return
	}
	mib := float64(o.MaxRSS) / (1 << 20)
	if path := os.Getenv("PSY_RSS_REPORT"); path != "" {
		line := time.Now().UTC().Format(time.RFC3339) + " FetchFile 100 MiB: peak RSS " +
			formatMiB(mib) + " MiB, " + formatInt(o.ElapsedMS) + " ms, GOMEMLIMIT 40 MiB\n"
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			_, _ = f.WriteString(line)
			f.Close()
		}
	}
	// Gross regression guard only; the real budget is measured on device (WP-C).
	if mib > 160 {
		t.Fatalf("restricted fetch peak RSS %.1f MiB is far above budget", mib)
	}
}
