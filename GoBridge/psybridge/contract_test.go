// SPDX-License-Identifier: MIT

package psybridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestErrorCodeRoundTrip(t *testing.T) {
	err := newError(CodeNoPeer, "no device for %s", "f1")
	if got := ErrorCode(err.Error()); got != CodeNoPeer {
		t.Fatalf("ErrorCode = %q", got)
	}
	if got := ErrorCode("psy:" + CodeCancelled); got != CodeCancelled {
		t.Fatalf("ErrorCode bare = %q", got)
	}
	if got := ErrorCode("boom"); got != "" {
		t.Fatalf("ErrorCode foreign = %q", got)
	}
}

func TestAPIVersion(t *testing.T) {
	if APIVersion() != 2 {
		t.Fatal("bridge API version must be 2")
	}
}

func TestSyncthingVersionPinned(t *testing.T) {
	if v := SyncthingVersion(); !strings.HasPrefix(v, PinnedSyncthingVersion) {
		t.Fatalf("SyncthingVersion = %q, want prefix %q", v, PinnedSyncthingVersion)
	}
}

// SyncthingPin.json, go.mod and PinnedSyncthingVersion must agree.
func TestPinFileMatchesModule(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "SyncthingPin.json"))
	if err != nil {
		t.Fatal(err)
	}
	var pin struct {
		Tag           string `json:"tag"`
		Commit        string `json:"commit"`
		ModuleVersion string `json:"moduleVersion"`
	}
	if err := json.Unmarshal(raw, &pin); err != nil {
		t.Fatal(err)
	}
	if pin.Tag != PinnedSyncthingVersion {
		t.Fatalf("pin tag %q != %q", pin.Tag, PinnedSyncthingVersion)
	}
	mod, err := os.ReadFile(filepath.Join("..", "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`github.com/syncthing/syncthing (\S+)`)
	m := re.FindSubmatch(mod)
	if m == nil || string(m[1]) != pin.ModuleVersion {
		t.Fatalf("go.mod pins %q, SyncthingPin.json says %q", m, pin.ModuleVersion)
	}
	if !strings.HasSuffix(pin.ModuleVersion, pin.Commit[:12]) {
		t.Fatalf("module version %q does not name commit %q", pin.ModuleVersion, pin.Commit)
	}
	if strings.Contains(string(mod), "=> ../") || strings.Contains(string(mod), "syncthing/syncthing =>") {
		t.Fatal("go.mod must not replace upstream syncthing")
	}
}

func TestStubsGone(t *testing.T) {
	if _, err := FetchFile(&FetchRequest{}, nil); codeOf(err) != CodeInvalidArgument {
		t.Fatalf("FetchFile invalid: %v", err)
	}
	if _, err := FetchFile(&FetchRequest{FolderID: "f", Path: "p", DestinationPath: "/tmp/x"}, nil); codeOf(err) != CodeInvalidArgument {
		t.Fatalf("FetchFile without HomeDir: %v", err)
	}
	if _, err := FetchFile(&FetchRequest{HomeDir: t.TempDir(), FolderID: "f", Path: "p", DestinationPath: "/tmp/x"}, nil); codeOf(err) != CodeIdentity {
		t.Fatalf("FetchFile without identity: %v", err)
	}
}

func TestIdentity(t *testing.T) {
	id, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	got, err := DeviceIDFromCertificate(id.CertPEM)
	if err != nil || got != id.DeviceID {
		t.Fatalf("DeviceIDFromCertificate = %q, %v; want %q", got, err, id.DeviceID)
	}
	if _, _, err := parseIdentity(id.CertPEM, id.KeyPEM); err != nil {
		t.Fatalf("generated identity does not load: %v", err)
	}
	other, _ := GenerateIdentity()
	if _, _, err := parseIdentity(id.CertPEM, other.KeyPEM); codeOf(err) != CodeIdentity {
		t.Fatalf("mismatched key accepted: %v", err)
	}
	if _, err := DeviceIDFromCertificate([]byte("junk")); codeOf(err) != CodeIdentity {
		t.Fatalf("junk cert: %v", err)
	}

	canon, err := ValidateDeviceID("  " + strings.ToLower(strings.ReplaceAll(id.DeviceID, "-", "")) + "\n")
	if err != nil || canon != id.DeviceID {
		t.Fatalf("ValidateDeviceID normalised = %q, %v", canon, err)
	}
	// Flip the final check character; pick a replacement that differs from it.
	flip := "A"
	if strings.HasSuffix(id.DeviceID, "A") {
		flip = "B"
	}
	for _, bad := range []string{"", "abc", id.DeviceID[:len(id.DeviceID)-1] + flip, protocol.LocalDeviceID.String()} {
		if _, err := ValidateDeviceID(bad); codeOf(err) != CodeInvalidArgument {
			t.Errorf("ValidateDeviceID(%q) = %v", bad, err)
		}
	}
}

func TestLoopbackOnly(t *testing.T) {
	for _, ok := range []string{"", "127.0.0.1:0", "127.0.0.1:8385", "[::1]:0"} {
		if _, err := loopbackAddress(ok); err != nil {
			t.Errorf("%q rejected: %v", ok, err)
		}
	}
	for _, bad := range []string{"0.0.0.0:0", ":8384", "[::]:0", "localhost:0", "192.168.1.2:8384", "example.com:80", "unix:///tmp/s", "127.0.0.1"} {
		if _, err := loopbackAddress(bad); codeOf(err) != CodeInvalidArgument {
			t.Errorf("%q accepted: %v", bad, err)
		}
	}
	id, _ := GenerateIdentity()
	if _, err := NewEngine(&EngineConfig{HomeDir: t.TempDir(), CertPEM: id.CertPEM, KeyPEM: id.KeyPEM, APIAddress: "0.0.0.0:8384"}, nil, nil); codeOf(err) != CodeInvalidArgument {
		t.Fatalf("NewEngine accepted a wildcard address: %v", err)
	}
}

func TestEngineConfigPolicy(t *testing.T) {
	id, _ := GenerateIdentity()
	myID, _ := protocol.DeviceIDFromString(id.DeviceID)
	c := config.New(myID)
	c.GUI.RawAddress = "0.0.0.0:8384"
	c.GUI.RawUseTLS = true
	c.GUI.InsecureAdminAccess = true
	c.Options.URAccepted = 3
	c.Folders = append(c.Folders, config.FolderConfiguration{ID: "f", FSWatcherEnabled: true, RescanIntervalS: 60})
	applyEngineConfig(&c, myID, "127.0.0.1:5555", "KEY", "My Phone", true)
	if c.GUI.RawAddress != "127.0.0.1:5555" || c.GUI.APIKey != "KEY" || c.GUI.RawUseTLS || c.GUI.InsecureAdminAccess || !c.GUI.Enabled {
		t.Fatalf("GUI policy not applied: %+v", c.GUI)
	}
	if c.Options.URAccepted != -1 || c.Options.AutoUpgradeIntervalH != 0 || c.Options.CREnabled || c.Options.StartBrowser {
		t.Fatalf("options policy not applied: %+v", c.Options)
	}
	dev, _ := c.DeviceMap()[myID]
	if dev.Name != "My Phone" {
		t.Fatalf("device name = %q", dev.Name)
	}
	// Not first start: name is left alone.
	applyEngineConfig(&c, myID, "127.0.0.1:5555", "KEY", "Other", false)
	if c.DeviceMap()[myID].Name != "My Phone" {
		t.Fatal("device name overwritten on later start")
	}
}

func TestRestrictConfig(t *testing.T) {
	ids := make([]protocol.DeviceID, 3)
	for i := range ids {
		g, _ := GenerateIdentity()
		ids[i], _ = protocol.DeviceIDFromString(g.DeviceID)
	}
	me, peer, stranger := ids[0], ids[1], ids[2]
	c := config.New(me)
	c.Devices = append(c.Devices, config.DeviceConfiguration{DeviceID: peer}, config.DeviceConfiguration{DeviceID: stranger})
	c.Folders = []config.FolderConfiguration{
		{ID: "a", Devices: []config.FolderDeviceConfiguration{{DeviceID: me}, {DeviceID: peer}}},
		{ID: "b", Devices: []config.FolderDeviceConfiguration{{DeviceID: me}, {DeviceID: stranger}}},
	}
	target, ok := restrictConfig(&c, me, "a")
	if !ok || target.ID != "a" {
		t.Fatal("target folder not found")
	}
	for _, f := range c.Folders {
		if !f.Paused {
			t.Errorf("folder %s not paused", f.ID)
		}
	}
	for _, d := range c.Devices {
		switch d.DeviceID {
		case peer:
			if d.Paused || d.RawNumConnections != 1 {
				t.Errorf("peer: %+v", d)
			}
		case stranger:
			if !d.Paused {
				t.Error("device not sharing the folder must be paused")
			}
		}
	}
	if c.GUI.Enabled || c.Options.NATEnabled {
		t.Fatal("GUI/NAT must be off in the restricted core")
	}
	if len(c.Options.RawListenAddresses) != 0 || c.Options.LocalAnnEnabled || !c.Options.RelaysEnabled || !c.Options.GlobalAnnEnabled {
		t.Fatalf("restricted core must be dial-only with global lookups and relay dialing: %+v", c.Options)
	}
	for _, srv := range c.Options.RawGlobalAnnServers {
		if !strings.Contains(srv, "noannounce") || strings.Contains(srv, "nolookup") {
			t.Fatalf("global discovery server %q is not lookup-only", srv)
		}
	}
	if _, ok := restrictConfig(&c, me, "missing"); ok {
		t.Fatal("unknown folder accepted")
	}
	got := candidateDevices(target, me, []protocol.DeviceID{stranger, peer})
	if len(got) != 1 || got[0] != peer {
		t.Fatalf("candidates = %v", got)
	}
}

func TestLookupOnlyServers(t *testing.T) {
	got := lookupOnlyServers([]string{
		"https://discovery-lookup.syncthing.net/v2/?noannounce",
		"https://discovery-announce-v4.syncthing.net/v2/?nolookup",
		"https://disco.example.org:8443/v2/?id=ABC",
		"https://discovery-lookup.syncthing.net/v2/?noannounce",
	})
	want := []string{
		"https://discovery-lookup.syncthing.net/v2/?noannounce",
		"https://disco.example.org:8443/v2/?id=ABC&noannounce",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("got %q", got)
	}
}

func TestVersionToken(t *testing.T) {
	var v protocol.Vector
	v = v.Update(1).Update(7)
	a := versionToken(v)
	if a != versionToken(v.Copy()) {
		t.Fatal("token not deterministic")
	}
	if a == versionToken(v.Update(1)) {
		t.Fatal("token ignores counter change")
	}
	if len(a) != 44 {
		t.Fatalf("token %q is not base64(sha256)", a)
	}
}

type captureSink struct{ lines []string }

func (c *captureSink) Log(level, msg string) { c.lines = append(c.lines, level+" "+msg) }

func TestLogRedaction(t *testing.T) {
	sink := &captureSink{}
	shared := installLogSink(sink, "info")
	defer installLogSink(nil, "")
	shared.addSecret("s3cr3tkey")
	logger := newSlogForTest(shared)
	logger.Info("api key is s3cr3tkey", "key", "s3cr3tkey")
	logger.Debug("hidden")
	if len(sink.lines) != 1 {
		t.Fatalf("lines = %q", sink.lines)
	}
	if strings.Contains(sink.lines[0], "s3cr3tkey") || !strings.Contains(sink.lines[0], "<redacted>") {
		t.Fatalf("not redacted: %q", sink.lines[0])
	}
}

func TestMemoryWarningDoesNotCompound(t *testing.T) {
	prev := ApplyMemoryProfile(100, 100)
	defer ApplyMemoryProfile(prev, 100)
	memoryWarning()
	memoryWarning()
	if got := currentLimitMiB(); got != 75 {
		t.Fatalf("limit after two warnings = %d MiB, want 75", got)
	}
	applyRuntimeProfile(100, 100, 0, 1, 1, 1)
	if got := currentLimitMiB(); got != 100 {
		t.Fatalf("limit after re-apply = %d MiB", got)
	}
}
