// SPDX-License-Identifier: MIT

package integration

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoBridge/psybridge"
)

// Official Syncthing binary used as an independent, temporary peer (its own
// home in t.TempDir(), its own ports; never the user's running instance).
func officialBinary(t *testing.T) string {
	t.Helper()
	p := os.Getenv("PSY_OFFICIAL_SYNCTHING")
	if p == "" {
		p = "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("official syncthing binary not available (%s)", p)
	}
	return p
}

// startOfficial runs `syncthing serve` for node n with a loopback GUI.
func startOfficial(t *testing.T, bin string, n *node) *psybridge.APIEndpoint {
	t.Helper()
	ep, _ := startOfficialProc(t, bin, n)
	return ep
}

// startOfficialProc is startOfficial that also returns the process.
func startOfficialProc(t *testing.T, bin string, n *node) (*psybridge.APIEndpoint, *os.Process) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(n.home, "cert.pem"), n.id.CertPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(n.home, "key.pem"), n.id.KeyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	ep := &psybridge.APIEndpoint{BaseURL: fmt.Sprintf("http://127.0.0.1:%d", freePort(t)), APIKey: "psy-test-" + n.id.DeviceID[:7], DeviceID: n.id.DeviceID}
	log, _ := os.Create(filepath.Join(n.home, "official.log"))
	cmd := exec.Command(bin, "serve", "--home="+n.home, "--no-browser", "--no-restart", "--no-upgrade",
		"--gui-address="+ep.BaseURL, "--gui-apikey="+ep.APIKey)
	cmd.Env = append(os.Environ(), "STNOUPGRADE=1", "STNORESTART=1")
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Signal(syscall.SIGCONT)
		_ = cmd.Process.Signal(syscall.SIGTERM)
		done := make(chan struct{})
		go func() { _ = cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			_ = cmd.Process.Kill()
		}
		log.Close()
	})
	eventually(t, 60*time.Second, "official peer REST", func() bool {
		var v map[string]any
		return restTry(ep, "/rest/system/version", &v) == 200 && v["version"] == psybridge.PinnedSyncthingVersion
	})
	return ep, cmd.Process
}

// TestFetchFromOfficialPeerUsesAddressCache: the restricted core reaches an
// official v2.1.6 peer whose address it only knows from the App engine's
// peer-address cache (config says "dynamic", discovery is off): without the
// cache it fails with no_peer, with it the first dial round connects.
func TestFetchFromOfficialPeerUsesAddressCache(t *testing.T) {
	if testing.Short() {
		t.Skip("starts an official syncthing instance")
	}
	_, b, payload, staging := prepareOfficialPeer(t)

	cachePath := filepath.Join(b.home, psybridge.PeerCacheFileName)
	if err := os.Rename(cachePath, cachePath+".off"); err != nil {
		t.Fatal(err)
	}
	o := b.fetch(t, helperArgs{Path: "doc.bin", Dest: filepath.Join(staging, "nocache"), Grace: 5_000, Deadline: 8_000})
	if code(o.Error) != psybridge.CodeNoPeer {
		t.Fatalf("without cache: got %q, want no_peer", o.Error)
	}
	if err := os.Rename(cachePath+".off", cachePath); err != nil {
		t.Fatal(err)
	}

	o = b.fetch(t, helperArgs{Path: "doc.bin", Dest: filepath.Join(staging, "cached"), Grace: 5_000, Trace: true})
	if o.Error != "" {
		t.Fatalf("with cache: %s", o.Error)
	}
	got, _ := os.ReadFile(filepath.Join(staging, "cached"))
	if sha256.Sum256(got) != sha256.Sum256(payload) {
		t.Fatal("content differs from the official peer's file")
	}
	t.Logf("with cache: connected after %d ms, total %d ms, peak RSS %.1f MiB",
		o.Result.ConnectMillis, o.ElapsedMS, float64(o.Result.PeakRSSBytes)/(1<<20))
	if o.Result.ConnectMillis > 3_000 {
		t.Errorf("first connection took %d ms with a cached address", o.Result.ConnectMillis)
	}
}

// prepareOfficialPeer starts a temporary official peer A with doc.bin (5 MiB),
// lets B (psybridge engine) receive A's index and cache A's address, then
// stops B and rewrites its config so A is only "dynamic" (discovery off).
func prepareOfficialPeer(t *testing.T) (a, b *node, payload []byte, staging string) {
	t.Helper()
	bin := officialBinary(t)
	root := t.TempDir()
	a = newNode(t, root, "official")
	b = newNode(t, root, "B")
	a.dynamicPeers = true // A cannot dial B; only B's own dialing can connect
	writeConfig(t, a, b)
	writeConfig(t, b, a)
	if err := os.WriteFile(filepath.Join(b.dir, ".stignore"), []byte("*\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	payload = randomBytes(5<<20, 42)
	if err := os.WriteFile(filepath.Join(a.dir, "doc.bin"), payload, 0o644); err != nil {
		t.Fatal(err)
	}
	aEP := startOfficial(t, bin, a)
	eventually(t, 60*time.Second, "official peer scan", func() bool {
		var st struct {
			State       string `json:"state"`
			GlobalFiles int    `json:"globalFiles"`
		}
		restTry(aEP, "/rest/db/status?folder=f", &st)
		return st.State == "idle" && st.GlobalFiles == 1
	})

	// B as the App engine: connects (outbound) and fills the address cache.
	b.startEngine(t)
	eventually(t, 90*time.Second, "B to receive the index and cache A's address", func() bool {
		var f struct {
			Global struct {
				Size int64 `json:"size"`
			} `json:"global"`
		}
		if restGet(t, b.endpoint, "/rest/db/file?folder=f&file=doc.bin", &f) != 200 || f.Global.Size != int64(len(payload)) {
			return false
		}
		raw, err := os.ReadFile(filepath.Join(b.home, psybridge.PeerCacheFileName))
		return err == nil && strings.Contains(string(raw), fmt.Sprintf("tcp://127.0.0.1:%d", a.port))
	})
	b.stopEngine(t)
	raw, _ := os.ReadFile(filepath.Join(b.home, psybridge.PeerCacheFileName))
	var cache struct {
		Version int `json:"version"`
		Devices map[string]struct {
			Addresses   []string `json:"addresses"`
			LastAddress string   `json:"lastAddress"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(raw, &cache); err != nil || cache.Version != 1 {
		t.Fatalf("cache file: %v\n%s", err, raw)
	}
	if got := cache.Devices[a.id.DeviceID].LastAddress; got != fmt.Sprintf("tcp://127.0.0.1:%d", a.port) {
		t.Fatalf("lastAddress = %q\n%s", got, raw)
	}

	// From now on B only knows "dynamic" for A, and discovery is off.
	b.dynamicPeers = true
	writeConfig(t, b, a)
	staging = filepath.Join(root, "B", "Staging")
	_ = os.MkdirAll(staging, 0o700)

	return a, b, payload, staging
}

// TestSimulatorFetchFootprint runs the restricted fetch inside the iOS
// Simulator (GoBridge/Scripts/sim-fetch-memory.sh sets the env).
func TestSimulatorFetchFootprint(t *testing.T) {
	udid, probe := os.Getenv("PSY_SIM_UDID"), os.Getenv("PSY_SIM_FETCH_BIN")
	if udid == "" || probe == "" {
		t.Skip("run via GoBridge/Scripts/sim-fetch-memory.sh")
	}
	_, b, payload, staging := prepareOfficialPeer(t)
	certPath, keyPath := filepath.Join(staging, "cert.pem"), filepath.Join(staging, "key.pem")
	_ = os.WriteFile(certPath, b.id.CertPEM, 0o600)
	_ = os.WriteFile(keyPath, b.id.KeyPEM, 0o600)
	dest := filepath.Join(staging, "sim.bin")
	out, err := exec.Command("xcrun", "simctl", "spawn", udid, probe, b.home, certPath, keyPath, "f", "doc.bin", dest).CombinedOutput()
	t.Logf("%s", out)
	if err != nil {
		t.Fatalf("simfetch: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if sha256.Sum256(got) != sha256.Sum256(payload) {
		t.Fatal("content differs")
	}
}
