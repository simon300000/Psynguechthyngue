// SPDX-License-Identifier: MIT

package psybridge

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestConnectionURI(t *testing.T) {
	cases := map[[2]string]string{
		{"tcp-client", "10.0.0.2:22000"}:  "tcp://10.0.0.2:22000",
		{"quic-client", "10.0.0.2:22000"}: "quic://10.0.0.2:22000",
		{"tcp-server", "10.0.0.2:51234"}:  "", // incoming: ephemeral port
		{"relay-client", "1.2.3.4:22067"}: "", // needs discovery's relay URI
		{"tcp-client", ""}:                "",
	}
	for in, want := range cases {
		if got := connectionURI(in[0], in[1]); got != want {
			t.Errorf("connectionURI%v = %q, want %q", in, got, want)
		}
	}
}

func TestPeerCacheRoundTripAndApply(t *testing.T) {
	home := t.TempDir()
	g1, _ := GenerateIdentity()
	g2, _ := GenerateIdentity()
	g3, _ := GenerateIdentity()
	me, _ := protocol.DeviceIDFromString(g1.DeviceID)
	peer, _ := protocol.DeviceIDFromString(g2.DeviceID)
	other, _ := protocol.DeviceIDFromString(g3.DeviceID)
	now := time.Now()

	if c := readPeerCache(home); len(c.Devices) != 0 {
		t.Fatal("missing file should give an empty cache")
	}
	_ = os.WriteFile(peerCachePath(home), []byte("{garbage"), 0o600)
	if c := readPeerCache(home); len(c.Devices) != 0 {
		t.Fatal("corrupt file should give an empty cache")
	}
	c := readPeerCache(home)
	c.Devices[peer.String()] = peerCacheEntry{Addresses: []string{"tcp://10.0.0.2:22000", "dynamic", "relay://r:22067/?id=X"}, Seen: now}
	c.Devices[other.String()] = peerCacheEntry{Addresses: []string{"tcp://10.0.0.3:22000"}, Seen: now.Add(-60 * 24 * time.Hour)}
	if err := writePeerCache(home, c); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(peerCachePath(home)); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if _, err := os.Stat(filepath.Join(home, PeerCacheFileName+".tmp")); !os.IsNotExist(err) {
		t.Fatal("temp file left behind")
	}
	c = readPeerCache(home)
	if got := c.cachedAddresses(peer, now); !slices.Equal(got, []string{"tcp://10.0.0.2:22000", "relay://r:22067/?id=X"}) {
		t.Fatalf("cached = %v", got)
	}
	if got := c.cachedAddresses(other, now); got != nil {
		t.Fatalf("stale entry used: %v", got)
	}

	cfg := config.New(me)
	cfg.Devices = append(cfg.Devices,
		config.DeviceConfiguration{DeviceID: peer, Addresses: []string{"dynamic"}},
		config.DeviceConfiguration{DeviceID: other, Addresses: []string{"dynamic"}})
	folder := config.FolderConfiguration{ID: "f", Devices: []config.FolderDeviceConfiguration{{DeviceID: me}, {DeviceID: peer}}}
	applyPeerCache(&cfg, folder, c, now)
	for _, d := range cfg.Devices {
		switch d.DeviceID {
		case peer:
			if !slices.Equal(d.Addresses, []string{"tcp://10.0.0.2:22000", "relay://r:22067/?id=X", "dynamic"}) {
				t.Errorf("peer addresses %v", d.Addresses)
			}
		case other:
			if !slices.Equal(d.Addresses, []string{"dynamic"}) {
				t.Errorf("non-sharing device changed: %v", d.Addresses)
			}
		}
	}
}
