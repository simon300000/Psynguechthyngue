// SPDX-License-Identifier: MIT

package integration

import (
	"encoding/json"
	"encoding/xml"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoBridge/psybridge"
)

// TestEngineLifecycle: REST only on 127.0.0.1, random key per start,
// index stream, and everything released after Stop. Runs in-process.
func TestEngineLifecycle(t *testing.T) {
	root := t.TempDir()
	n := newNode(t, root, "solo")
	writeConfig(t, n)
	files := map[string]int{"a.txt": 10, "b.bin": 300 << 10, "c.dat": 0}
	for name, size := range files {
		if err := os.WriteFile(filepath.Join(n.dir, name), randomBytes(size, int64(size)), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	e, err := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM, DeviceName: "solo"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	ep1, err := e.Start(30_000)
	if err != nil {
		t.Fatal(err)
	}
	// A failed check must not leave the runtime to the next test
	// (already_running).
	t.Cleanup(func() {
		if e.IsRunning() {
			_ = e.Stop(30_000)
		}
	})
	if !e.IsRunning() {
		t.Fatal("IsRunning false after Start")
	}
	if ep1.DeviceID != n.id.DeviceID {
		t.Fatalf("endpoint device %s != %s", ep1.DeviceID, n.id.DeviceID)
	}
	port := assertLoopbackOnly(t, ep1)

	// Authenticated vs unauthenticated REST.
	var status struct {
		MyID string `json:"myID"`
	}
	if c := restGet(t, ep1, "/rest/system/status", &status); c != 200 || status.MyID != n.id.DeviceID {
		t.Fatalf("status %d myID %q", c, status.MyID)
	}
	if c := restGet(t, &psybridge.APIEndpoint{BaseURL: ep1.BaseURL}, "/rest/system/status", nil); c != 403 && c != 401 {
		t.Fatalf("unauthenticated request got %d", c)
	}

	// config.xml holds this launch's loopback address and key.
	gui := readGUIConfig(t, n.home)
	if gui.Address != "127.0.0.1:"+port || gui.APIKey != ep1.APIKey || gui.TLS {
		t.Fatalf("persisted gui config = %+v", gui)
	}

	// A second engine or a fetch in the same process is refused.
	e2, _ := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: t.TempDir(), CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM}, nil, nil)
	if _, err := e2.Start(5_000); code(errString(err)) != psybridge.CodeAlreadyRunning {
		t.Fatalf("second engine: %v", err)
	}
	if _, err := psybridge.FetchFile(&psybridge.FetchRequest{HomeDir: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM, FolderID: "f", Path: "a.txt", DestinationPath: filepath.Join(root, "x")}, nil); code(errString(err)) != psybridge.CodeAlreadyRunning {
		t.Fatalf("fetch while engine runs: %v", err)
	}

	// Index stream over the scanned folder.
	eventually(t, 30*time.Second, "initial scan", func() bool {
		var st struct {
			State       string `json:"state"`
			GlobalFiles int    `json:"globalFiles"`
		}
		restGet(t, ep1, "/rest/db/status?folder=f", &st)
		return st.State == "idle" && st.GlobalFiles == len(files)
	})
	if _, err := e.OpenIndexStream("nope"); code(errString(err)) != psybridge.CodeInvalidArgument {
		t.Fatalf("unknown folder stream: %v", err)
	}
	s, err := e.OpenIndexStream("f")
	if err != nil {
		t.Fatal(err)
	}
	var all []map[string]any
	for page := 0; ; page++ {
		raw, err := s.Next(2)
		if err != nil {
			t.Fatal(err)
		}
		var entries []map[string]any
		if err := json.Unmarshal(raw, &entries); err != nil {
			t.Fatal(err)
		}
		if len(entries) > 2 {
			t.Fatalf("page of %d > max 2", len(entries))
		}
		if len(entries) == 0 {
			break
		}
		all = append(all, entries...)
		if page > 10 {
			t.Fatal("stream does not end")
		}
	}
	s.Close()
	s.Close() // idempotent
	if len(all) != len(files) {
		t.Fatalf("stream returned %d entries, want %d: %v", len(all), len(files), all)
	}
	for _, en := range all {
		name := en["name"].(string)
		size, ok := files[name]
		if !ok || int(en["size"].(float64)) != size || en["type"] != "file" || en["localPresent"] != true || en["deleted"] != false {
			t.Errorf("entry %v", en)
		}
		if len(en["version"].(string)) != 44 || len(en["blocksHash"].(string)) != 44 {
			t.Errorf("tokens missing: %v", en)
		}
		if _, err := time.Parse(time.RFC3339Nano, en["modified"].(string)); err != nil {
			t.Errorf("modified: %v", err)
		}
	}
	open, err := e.OpenIndexStream("f")
	if err != nil {
		t.Fatal(err)
	}

	if err := e.Stop(15_000); err != nil {
		t.Fatal(err)
	}
	if e.IsRunning() {
		t.Fatal("IsRunning true after Stop")
	}
	if _, err := open.Next(10); code(errString(err)) != psybridge.CodeNotRunning {
		t.Fatalf("stream after Stop: %v", err)
	}
	if err := e.Stop(1_000); code(errString(err)) != psybridge.CodeNotRunning {
		t.Fatalf("double stop: %v", err)
	}
	if c, err := net.DialTimeout("tcp", "127.0.0.1:"+port, time.Second); err == nil {
		c.Close()
		t.Fatal("REST port still accepting after Stop")
	}
	assertNoOpenFilesUnder(t, root)

	// Restart: fresh random key, same identity, same DB.
	ep2, err := e.Start(30_000)
	if err != nil {
		t.Fatal(err)
	}
	if ep2.APIKey == ep1.APIKey || len(ep2.APIKey) < 20 {
		t.Fatalf("API key not random per start: %q vs %q", ep1.APIKey, ep2.APIKey)
	}
	assertLoopbackOnly(t, ep2)
	if err := e.Stop(15_000); err != nil {
		t.Fatal(err)
	}
	assertNoOpenFilesUnder(t, root)
}

// assertLoopbackOnly checks the endpoint URL, that the kernel reports the
// listening socket on 127.0.0.1 only, and that the port is unreachable via
// every non-loopback interface address.
func assertLoopbackOnly(t *testing.T, ep *psybridge.APIEndpoint) string {
	t.Helper()
	u, err := url.Parse(ep.BaseURL)
	if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" {
		t.Fatalf("BaseURL %q is not http://127.0.0.1:<port>", ep.BaseURL)
	}
	port := u.Port()
	if p, _ := strconv.Atoi(port); p == 0 {
		t.Fatalf("no port in %q", ep.BaseURL)
	}
	if out, err := exec.Command("lsof", "-nP", "-a", "-p", strconv.Itoa(os.Getpid()), "-iTCP:"+port, "-sTCP:LISTEN").Output(); err == nil {
		lines := strings.Split(strings.TrimSpace(string(out)), "\n")
		if len(lines) < 2 {
			t.Fatalf("lsof shows no listener on %s:\n%s", port, out)
		}
		for _, l := range lines[1:] {
			if !strings.Contains(l, "127.0.0.1:"+port) {
				t.Fatalf("listener not bound to 127.0.0.1: %s", l)
			}
		}
	} else {
		t.Logf("lsof unavailable (%v); relying on dial checks", err)
	}
	addrs, _ := net.InterfaceAddrs()
	checked := 0
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.IsLoopback() || ipn.IP.IsLinkLocalUnicast() {
			continue
		}
		c, err := net.DialTimeout("tcp", net.JoinHostPort(ipn.IP.String(), port), 500*time.Millisecond)
		if err == nil {
			c.Close()
			// Control: a port nobody listens on. If that "connects" too, the
			// address belongs to a transparent proxy/TUN (e.g. 198.18.0.0/15)
			// and says nothing about our socket. The control gets the longer
			// timeout: a loaded machine slows the proxy's fake accept, and a
			// control that times out must not turn into a false alarm.
			if c, err := net.DialTimeout("tcp", net.JoinHostPort(ipn.IP.String(), strconv.Itoa(closedPort(t))), 3*time.Second); err == nil {
				c.Close()
				t.Logf("skipping %s: accepts connections on any port (proxy/TUN)", ipn.IP)
				continue
			}
			t.Fatalf("REST reachable via non-loopback address %s", ipn.IP)
		}
		checked++
	}
	t.Logf("REST on %s; unreachable via %d non-loopback addresses", ep.BaseURL, checked)
	return port
}

type guiXML struct {
	Address string `xml:"address"`
	APIKey  string `xml:"apikey"`
	TLS     bool   `xml:"tls,attr"`
}

func readGUIConfig(t *testing.T, home string) guiXML {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(home, "config.xml"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		GUI guiXML `xml:"gui"`
	}
	if err := xml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.GUI
}

// assertNoOpenFilesUnder: after Stop the DB (index-v2/*.db, WAL) and every
// folder file must be closed so Swift can release the App Group lock.
func assertNoOpenFilesUnder(t *testing.T, root string) {
	t.Helper()
	real, _ := filepath.EvalSymlinks(root)
	out, err := exec.Command("lsof", "-nP", "-p", strconv.Itoa(os.Getpid())).Output()
	if err != nil {
		t.Logf("lsof unavailable: %v", err)
		return
	}
	var held []string
	for _, l := range strings.Split(string(out), "\n") {
		if strings.Contains(l, root) || strings.Contains(l, real) {
			held = append(held, l)
		}
	}
	if len(held) > 0 {
		t.Fatalf("files still open after Stop:\n%s", strings.Join(held, "\n"))
	}
}

func closedPort(t *testing.T) int {
	return freePort(t)
}
