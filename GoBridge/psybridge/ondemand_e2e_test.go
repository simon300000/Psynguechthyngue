// SPDX-License-Identifier: MIT

package psybridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// TestOnDemandIndexStreamE2E (opt-in, PSY_E2E_ONDEMAND=1): a real psybridge
// Engine ("phone") pairs with a temporary standalone Syncthing peer and
// accepts a folder on demand (managed .stignore: everything ignored). The
// global index stream must list every peer entry as valid (not invalid), or
// the Files projection drops them. PSY_E2E_MODE=everything checks a
// download-everything folder instead.
//
// Peer: /Applications/Syncthing.app binary, home ~/SyncthingTest/fix-ondemand/go-e2e,
// listen 127.0.0.1:22511, GUI 127.0.0.1:8442. Never the official instance.
func TestOnDemandIndexStreamE2E(t *testing.T) {
	if os.Getenv("PSY_E2E_ONDEMAND") != "1" {
		t.Skip("set PSY_E2E_ONDEMAND=1")
	}
	bin := envOr("PSY_E2E_SYNCTHING", "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing")
	homeDir, _ := os.UserHomeDir()
	base := filepath.Join(homeDir, "SyncthingTest", "fix-ondemand", "go-e2e")
	_ = os.RemoveAll(base)
	t.Cleanup(func() {
		if os.Getenv("PSY_E2E_KEEP") == "" {
			_ = os.RemoveAll(base)
		}
	})
	peerHome := filepath.Join(base, "peer-home")
	peerData := filepath.Join(base, "peer-data")
	phoneHome := filepath.Join(base, "phone-home")
	phoneData := filepath.Join(base, "phone-data")
	const folderID = "psy-test-ondemand"

	tree := makePeerTree(t, peerData)

	// Peer.
	if out, err := exec.Command(bin, "generate", "--home", peerHome, "--no-port-probing").CombinedOutput(); err != nil {
		t.Fatalf("generate: %v %s", err, out)
	}
	peerKey := randomAPIKey()
	peerID := strings.TrimSpace(mustRun(t, bin, "device-id", "--home", peerHome))
	cmd := exec.Command(bin, "serve", "--home", peerHome, "--no-browser", "--no-restart",
		"--gui-address", "127.0.0.1:8442", "--gui-apikey", peerKey)
	cmd.Env = append(os.Environ(), "STNODEFAULTFOLDER=1", "STNOUPGRADE=1")
	logf, _ := os.Create(filepath.Join(base, "peer.log"))
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	peer := restClient{base: "http://127.0.0.1:8442", key: peerKey}
	waitFor(t, "peer up", 30*time.Second, func() bool { return peer.do("GET", "/rest/system/ping", nil, nil) == nil })

	// Phone (the real embedded engine).
	ident, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	eng, err := NewEngine(&EngineConfig{HomeDir: phoneHome, CertPEM: ident.CertPEM, KeyPEM: ident.KeyPEM,
		DeviceName: "psy-test-phone", APIAddress: "127.0.0.1:0"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	ep, err := eng.Start(30_000)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Stop(10_000) })
	phone := restClient{base: ep.BaseURL, key: ep.APIKey}

	isolate := func(c restClient, listen string) {
		must(t, c.do("PATCH", "/rest/config/options", map[string]any{
			"listenAddresses": []string{"tcp://" + listen}, "globalAnnounceEnabled": false,
			"localAnnounceEnabled": false, "relaysEnabled": false, "natEnabled": false,
		}, nil))
	}
	isolate(peer, "127.0.0.1:22511")
	isolate(phone, "127.0.0.1:22512")
	must(t, peer.do("PUT", "/rest/config/devices/"+ep.DeviceID, map[string]any{
		"deviceID": ep.DeviceID, "name": "psy-test-phone", "addresses": []string{"tcp://127.0.0.1:22512"},
	}, nil))
	must(t, phone.do("PUT", "/rest/config/devices/"+peerID, map[string]any{
		"deviceID": peerID, "name": "psy-test-peer", "addresses": []string{"tcp://127.0.0.1:22511"},
	}, nil))
	must(t, peer.do("PUT", "/rest/config/folders/"+folderID, map[string]any{
		"id": folderID, "label": "psy-test-ondemand", "path": peerData, "type": "sendreceive",
		"devices": []map[string]string{{"deviceID": ep.DeviceID}},
	}, nil))

	// Accept on demand exactly like LiveSyncEngine.addFolder.
	must(t, os.MkdirAll(phoneData, 0o755))
	must(t, os.WriteFile(filepath.Join(phoneData, ".stignore-user"), nil, 0o644))
	must(t, os.WriteFile(filepath.Join(phoneData, ".stignore"),
		[]byte("// === Psynguechthyngue managed — do not edit below ===\n#include .stignore-user\n*\n"), 0o644))
	mode := envOr("PSY_E2E_MODE", "ondemand")
	if mode == "everything" {
		_ = os.Remove(filepath.Join(phoneData, ".stignore"))
	}
	must(t, phone.do("PUT", "/rest/config/folders/"+folderID, map[string]any{
		"id": folderID, "label": "psy-test-ondemand", "path": phoneData, "type": "sendreceive",
		"devices": []map[string]string{{"deviceID": peerID}},
	}, nil))

	waitFor(t, "phone has the global index and is idle", 120*time.Second, func() bool {
		var st struct {
			GlobalFiles, GlobalDirectories int
			State                          string
		}
		if phone.do("GET", "/rest/db/status?folder="+folderID, nil, &st) != nil {
			return false
		}
		return st.State == "idle" && st.GlobalFiles+st.GlobalDirectories >= len(tree)
	})

	got := streamAll(t, eng, folderID)
	var missing, invalid []string
	for _, name := range tree {
		e, ok := got[name]
		switch {
		case !ok:
			missing = append(missing, name)
		case e.Invalid || e.Deleted:
			invalid = append(invalid, name)
		}
	}
	t.Logf("mode=%s peer entries=%d stream entries=%d missing=%d invalid=%d", mode, len(tree), len(got), len(missing), len(invalid))
	if len(missing) > 0 || len(invalid) > 0 {
		t.Errorf("missing: %q\ninvalid: %q", missing, invalid)
	}
}

func makePeerTree(t *testing.T, root string) []string {
	t.Helper()
	old := time.Date(2019, 3, 4, 5, 6, 7, 0, time.UTC)
	files := map[string]int64{
		"2026-11-04 05-27-39.mkv":                 300 << 20,
		"角色摄影/封面 01.png":                          4096,
		"角色摄影/子目录/草稿.txt":                         10,
		"arch-vtbs.model-concat.tar.gz":           50 << 20,
		"arch-vtbs.model-concat.tar.gz.sha256":    65,
		"character-pipeline-20261001/run.sh":      100,
		"character-pipeline-20261001/out/a.json":  200,
		"config.yaml":                             30,
		"genshin-export-sprites.txt":              40,
		"ghost-camera-intro-v5.mp4":               200 << 20,
		"h3-archive/part1.bin":                    1000,
		"h3-archive/part2.bin":                    1000,
		"lens-sim-gallery/index.html":             500,
		"lens-sim-gallery-builder-20261022/a.txt": 5,
		"lens-sim-intro-v11-4k.mp4":               400 << 20,
		"lens-sim-scene-redesign/scene 1.blend":   9000,
		"native-maps-share-20261021/notes.md":     12,
		"p 文件夹/x.txt":                             3,
		"Zeta Old.doc":                            77,
	}
	seen := map[string]bool{}
	for name, size := range files {
		p := filepath.Join(root, name)
		must(t, os.MkdirAll(filepath.Dir(p), 0o755))
		f, err := os.Create(p)
		must(t, err)
		if size > 1<<20 {
			must(t, f.Truncate(size)) // sparse
			_, _ = f.WriteAt([]byte(name), 0)
		} else {
			_, _ = f.Write(bytes.Repeat([]byte("x"), int(size)))
		}
		_ = f.Close()
		must(t, os.Chtimes(p, old, old))
		for d := name; d != "."; d = filepath.Dir(d) {
			seen[d] = true
		}
	}
	var out []string
	for n := range seen {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func streamAll(t *testing.T, eng *Engine, folder string) map[string]IndexEntryJSON {
	s, err := eng.OpenIndexStream(folder)
	must(t, err)
	defer s.Close()
	out := map[string]IndexEntryJSON{}
	for {
		b, err := s.Next(7)
		must(t, err)
		var page []IndexEntryJSON
		must(t, json.Unmarshal(b, &page))
		if len(page) == 0 {
			return out
		}
		for _, e := range page {
			out[e.Name] = e
		}
	}
}

type restClient struct{ base, key string }

func (c restClient) do(method, path string, body, out any) error {
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+path, r)
	req.Header.Set("X-API-Key", c.key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: %d %s", method, path, resp.StatusCode, b)
	}
	if out != nil {
		return json.Unmarshal(b, out)
	}
	return nil
}

func waitFor(t *testing.T, what string, d time.Duration, f func() bool) {
	t.Helper()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if f() {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func mustRun(t *testing.T, name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		t.Fatalf("%s %v: %v", name, args, err)
	}
	return string(out)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
