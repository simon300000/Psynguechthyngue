// SPDX-License-Identifier: MIT

package psybridge

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

func testDeviceIDs(t *testing.T, n int) []protocol.DeviceID {
	t.Helper()
	ids := make([]protocol.DeviceID, n)
	for i := range ids {
		g, err := GenerateIdentity()
		if err != nil {
			t.Fatal(err)
		}
		ids[i], _ = protocol.DeviceIDFromString(g.DeviceID)
	}
	return ids
}

// Devices the App paused for a policy hold (persisted in config.xml by
// /rest/system/pause) must not block the restricted fetch; devices the user
// paused stay paused.
func TestRestrictedFetchIgnoresPolicyPause(t *testing.T) {
	ids := testDeviceIDs(t, 3)
	me, held, userPaused := ids[0], ids[1], ids[2]
	home := t.TempDir()
	state := `{"folders":{},"policyPausedDevices":["` + held.String() + `","not-a-device-id"],"decision":{}}`
	if err := os.WriteFile(filepath.Join(home, AppStateFileName), []byte(state), 0o600); err != nil {
		t.Fatal(err)
	}
	c := config.New(me)
	c.Devices = append(c.Devices,
		config.DeviceConfiguration{DeviceID: held, Paused: true},
		config.DeviceConfiguration{DeviceID: userPaused, Paused: true})
	c.Folders = []config.FolderConfiguration{{ID: "a", Devices: []config.FolderDeviceConfiguration{
		{DeviceID: me}, {DeviceID: held}, {DeviceID: userPaused}}}}

	got := readPolicyPausedDevices(home)
	if len(got) != 1 || !got[held] {
		t.Fatalf("policy paused = %v", got)
	}
	unpausePolicyHeld(&c, got)
	if _, ok := restrictConfig(&c, me, "a"); !ok {
		t.Fatal("folder not found")
	}
	for _, d := range c.Devices {
		switch d.DeviceID {
		case held:
			if d.Paused {
				t.Error("policy-held device still paused in the restricted core")
			}
		case userPaused:
			if !d.Paused {
				t.Error("user-paused device was resumed")
			}
		}
	}
	// No state file: nothing changes.
	if len(readPolicyPausedDevices(t.TempDir())) != 0 {
		t.Fatal("missing state file yielded devices")
	}
}

// The embedded engine uses one connection per peer (see applyEngineConfig).
func TestEngineConfigSingleConnection(t *testing.T) {
	ids := testDeviceIDs(t, 3)
	me, peer, custom := ids[0], ids[1], ids[2]
	c := config.New(me)
	c.Devices = append(c.Devices,
		config.DeviceConfiguration{DeviceID: peer},
		config.DeviceConfiguration{DeviceID: custom, RawNumConnections: 4})
	applyEngineConfig(&c, me, "127.0.0.1:5555", "KEY", "", false)
	if c.Defaults.Device.RawNumConnections != 1 || c.Defaults.Device.NumConnections() != 1 {
		t.Fatalf("default numConnections = %d", c.Defaults.Device.RawNumConnections)
	}
	for _, d := range c.Devices {
		want := 1
		if d.DeviceID == custom {
			want = 4
		}
		if d.NumConnections() != want {
			t.Errorf("%s numConnections = %d, want %d", d.DeviceID.Short(), d.NumConnections(), want)
		}
	}
}
