// SPDX-License-Identifier: MIT

package integration

import (
	"crypto/sha256"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
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

// TestFetchFile: A is a full engine, B's restricted core fetches
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

	// Non-default permissions so the fetch must copy them (scanner compares perms).
	if err := os.Chmod(filepath.Join(a.dir, "cross.bin"), 0o644); err != nil {
		t.Fatal(err)
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
	// Global version of cross.bin as announced by A, before any commit.
	var before struct {
		Global map[string]any `json:"global"`
	}
	restGet(t, b.endpoint, "/rest/db/file?folder=f&file=cross.bin", &before)
	t.Logf("announced by A: %v", before.Global)
	var announcedVersion []string
	for _, v := range before.Global["version"].([]any) {
		announcedVersion = append(announcedVersion, v.(string))
	}
	announced := strings.Join(announcedVersion, ",")
	if !strings.HasPrefix(announced, a.devID.Short().String()+":") {
		t.Fatalf("cross.bin global version %q is not A's", announced)
	}
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

	t.Run("restricted core is dial-only", func(t *testing.T) {
		// Progress fires after the core connected, i.e. while it runs.
		o := b.fetch(t, helperArgs{Path: "dir/big.bin", Dest: dest("sockets"), SocketCheck: true})
		if o.Error != "" {
			t.Fatal(o.Error)
		}
		if !o.SocketChecked {
			t.Skip("lsof unavailable")
		}
		for _, l := range o.Sockets {
			// QUIC/UDP dialing may hold an unconnected client socket; nothing
			// may listen on TCP or bind the discovery/sync ports.
			if strings.Contains(l, "(LISTEN)") || strings.Contains(l, ":21027") ||
				strings.Contains(l, fmt.Sprintf(":%d ", b.port)) || strings.HasSuffix(l, fmt.Sprintf(":%d", b.port)) {
				t.Errorf("restricted core holds a listening socket: %s", l)
			}
		}
		t.Logf("sockets while fetching: %q", o.Sockets)
	})

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

	// The restricted core works on an in-memory config: config.xml unchanged.
	if after, _ := os.ReadFile(filepath.Join(b.home, "config.xml")); string(after) != string(bConfig) || len(after) == 0 {
		t.Fatal("restricted fetch modified B's config.xml")
	}

	t.Run("commit then rescan keeps global version", func(t *testing.T) {
		// commit path: staging → folder, un-ignore, App engine scans.
		// A is offline here, so B can only adopt what it has on disk.
		o := b.fetch(t, helperArgs{Path: "cross.bin", Dest: dest("commit")})
		if o.Error != "" {
			t.Fatal(o.Error)
		}
		a.stopEngine(t)
		st, _ := os.Stat(dest("commit"))
		t.Logf("staged mode %v mtime %v", st.Mode(), st.ModTime().UTC().Format(time.RFC3339Nano))
		// Recording before the file is in place must be refused.
		if msg := b.record(t, "cross.bin", o.Result.Version); code(msg) != psybridge.CodeIO {
			t.Fatalf("record before commit: %q", msg)
		}
		if err := os.Rename(dest("commit"), filepath.Join(b.dir, "cross.bin")); err != nil {
			t.Fatal(err)
		}
		if msg := b.record(t, "cross.bin", "bogus"); code(msg) != psybridge.CodeVersionMismatch {
			t.Fatalf("record with wrong version: %q", msg)
		}
		if msg := b.record(t, "cross.bin", o.Result.Version); msg != "" {
			t.Fatalf("RecordFetchedFile: %s", msg)
		}
		if msg := b.record(t, "cross.bin", o.Result.Version); msg != "" {
			t.Fatalf("RecordFetchedFile not idempotent: %s", msg)
		}
		if err := os.WriteFile(filepath.Join(b.dir, ".stignore"), []byte("!/cross.bin\n*\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		b.startEngine(t)
		defer b.stopEngine(t)
		restPost(t, b.endpoint, "/rest/db/scan?folder=f")
		var info struct {
			Global struct {
				Version  []string `json:"version"`
				Modified string   `json:"modified"`
				Perms    string   `json:"permissions"`
			} `json:"global"`
			Local struct {
				Version  []string `json:"version"`
				Modified string   `json:"modified"`
				Perms    string   `json:"permissions"`
				Invalid  bool     `json:"invalid"`
			} `json:"local"`
		}
		eventually(t, 30*time.Second, "B to index cross.bin", func() bool {
			restGet(t, b.endpoint, "/rest/db/file?folder=f&file=cross.bin", &info)
			return len(info.Local.Version) > 0 && !info.Local.Invalid
		})
		t.Logf("global %+v", info.Global)
		t.Logf("local  %+v", info.Local)
		if info.Local.Modified != info.Global.Modified || info.Local.Perms != info.Global.Perms {
			t.Errorf("metadata differs: local %s/%s global %s/%s", info.Local.Modified, info.Local.Perms, info.Global.Modified, info.Global.Perms)
		}
		if got := strings.Join(info.Local.Version, ","); got != announced {
			t.Errorf("rescan created a new version: local %s, announced by A %s", got, announced)
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
	// Gross regression guard only; the real budget is measured on device.
	if mib > 160 {
		t.Fatalf("restricted fetch peak RSS %.1f MiB is far above budget", mib)
	}
}
