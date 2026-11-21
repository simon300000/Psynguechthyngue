// SPDX-License-Identifier: MIT

package integration

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoBridge/psybridge"
)

// TestStopWhilePeerDiesMidTransfer: B (in-process engine) is pulling a large
// file from a temporary official peer A when A disappears; Stop must still
// finish within its deadline, and the engine must start again afterwards.
func TestStopWhilePeerDiesMidTransfer(t *testing.T) {
	if testing.Short() {
		t.Skip("transfers 200 MiB with an official syncthing instance")
	}
	for _, c := range []struct {
		name   string
		upload bool // B sends to A (else B pulls from A)
		sig    syscall.Signal
		wait   time.Duration // between losing the peer and Stop
	}{
		{"download, peer frozen", false, syscall.SIGSTOP, 0},
		{"download, peer killed", false, syscall.SIGKILL, 0},
		{"upload, peer frozen", true, syscall.SIGSTOP, 0},
		{"upload, peer frozen, stop 5s later", true, syscall.SIGSTOP, 5 * time.Second},
		{"upload, peer killed", true, syscall.SIGKILL, 0},
	} {
		t.Run(c.name, func(t *testing.T) { stopWhilePeerDies(t, c.upload, c.sig, c.wait) })
	}
}

func stopWhilePeerDies(t *testing.T, upload bool, sig syscall.Signal, wait time.Duration) {
	bin := officialBinary(t)
	root := t.TempDir()
	a := newNode(t, root, "official")
	b := newNode(t, root, "B")
	a.dynamicPeers = true
	sender := a
	if upload {
		sender = b
	}
	sender.maxSendKbps = 20_000 // ~20 MB/s: the transfer lasts ~10 s
	writeConfig(t, a, b)
	writeConfig(t, b, a)
	if err := os.WriteFile(filepath.Join(sender.dir, "huge.bin"), randomBytes(200<<20, 7), 0o644); err != nil {
		t.Fatal(err)
	}
	aEP, aProc := startOfficialProc(t, bin, a)
	eventually(t, 60*time.Second, "official peer up", func() bool {
		var st struct {
			State string `json:"state"`
		}
		restTry(aEP, "/rest/db/status?folder=f", &st)
		return st.State == "idle"
	})
	e, err := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: b.home, CertPEM: b.id.CertPEM, KeyPEM: b.id.KeyPEM}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	ep, err := e.Start(30_000)
	if err != nil {
		t.Fatal(err)
	}
	stopped := false
	t.Cleanup(func() {
		_ = aProc.Signal(syscall.SIGCONT)
		if !stopped {
			_ = e.Stop(30_000)
		}
	})
	lastLog := time.Now()
	eventually(t, 90*time.Second, "B to be mid-transfer", func() bool {
		var st struct {
			State       string `json:"state"`
			GlobalBytes int64  `json:"globalBytes"`
			InSyncBytes int64  `json:"inSyncBytes"`
			NeedBytes   int64  `json:"needBytes"`
		}
		restTry(ep, "/rest/db/status?folder=f", &st)
		var conns struct {
			Total struct {
				InBytesTotal  int64 `json:"inBytesTotal"`
				OutBytesTotal int64 `json:"outBytesTotal"`
			} `json:"total"`
		}
		restTry(ep, "/rest/system/connections", &conns)
		moved := conns.Total.InBytesTotal
		if upload {
			moved = conns.Total.OutBytesTotal
		}
		if time.Since(lastLog) > 3*time.Second {
			t.Logf("B: state=%s need=%d global=%d moved=%d", st.State, st.NeedBytes, st.GlobalBytes, moved)
			lastLog = time.Now()
		}
		// Mid-transfer: between 10 MiB and 150 MiB moved.
		return (upload || st.State == "syncing") && moved > 10<<20 && moved < 150<<20
	})
	if err := aProc.Signal(sig); err != nil {
		t.Fatal(err)
	}
	time.Sleep(wait)

	start := time.Now()
	err = e.Stop(10_000)
	took := time.Since(start)
	t.Logf("Stop after peer %v: %v in %v", sig, err, took)
	if err != nil || took > 5*time.Second {
		t.Errorf("Stop after losing the peer: %v in %v (want clean stop well inside the 10 s budget)", err, took)
	}
	stopped = true
	assertNoOpenFilesUnder(t, b.home)

	// The engine must be usable again in this process.
	ep2, err := e.Start(30_000)
	if err != nil {
		t.Fatalf("restart after Stop: %v", err)
	}
	if ep2.APIKey == ep.APIKey {
		t.Fatal("restart reused the API key")
	}
	if err := e.Stop(10_000); err != nil {
		t.Fatalf("second Stop: %v", err)
	}
	stopped = true
}

// TestStopTimeoutDoesNotPoison: a Stop that misses its deadline returns
// stop_timeout, the shutdown finishes in the background, and Start works
// again in the same process (on the same or a new Engine).
func TestStopTimeoutDoesNotPoison(t *testing.T) {
	root := t.TempDir()
	n := newNode(t, root, "solo")
	writeConfig(t, n)
	e, err := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.Start(30_000); err != nil {
		t.Fatal(err)
	}
	// 1 ms is far below what a real shutdown needs: forces the timeout path.
	err = e.Stop(1)
	if psybridge.ErrorCode(errString(err)) != psybridge.CodeStopTimeout {
		t.Fatalf("Stop(1ms) = %v, want stop_timeout", err)
	}
	if e.IsRunning() {
		t.Fatal("engine still reports running after a timed-out Stop")
	}
	// Same Engine object: Start waits for the background shutdown.
	if _, err := e.Start(30_000); err != nil {
		t.Fatalf("Start after stop_timeout: %v", err)
	}
	if err := e.Stop(1); psybridge.ErrorCode(errString(err)) != psybridge.CodeStopTimeout {
		t.Fatalf("second Stop(1ms) = %v", err)
	}
	// A new Engine object (what the Swift adapter does) works too.
	e2, _ := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM}, nil, nil)
	if _, err := e2.Start(30_000); err != nil {
		t.Fatalf("new Engine after stop_timeout: %v", err)
	}
	if err := e2.Stop(10_000); err != nil {
		t.Fatal(err)
	}
	assertNoOpenFilesUnder(t, root)
}
