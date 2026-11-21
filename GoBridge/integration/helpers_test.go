// SPDX-License-Identifier: MIT

package integration

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoBridge/psybridge"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

// The test binary re-executes itself as a helper process (one upstream
// Syncthing per process, see psybridge/process.go).
func TestMain(m *testing.M) {
	switch os.Getenv("PSY_HELPER") {
	case "engine":
		helperEngine()
		os.Exit(0)
	case "fetch":
		helperFetch()
		os.Exit(0)
	case "record":
		a := readHelperArgs()
		err := psybridge.RecordFetchedFile(&psybridge.RecordRequest{HomeDir: a.Home, CertPEM: a.CertPEM, KeyPEM: a.KeyPEM, FolderID: a.Folder, Path: a.Path, ExpectedVersion: a.Expected})
		fmt.Println("RESULT", errString(err))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

type helperArgs struct {
	Home     string `json:"home"`
	CertPEM  []byte `json:"cert"`
	KeyPEM   []byte `json:"key"`
	Folder   string `json:"folder,omitempty"`
	Path     string `json:"path,omitempty"`
	Dest     string `json:"dest,omitempty"`
	Expected string `json:"expected,omitempty"`
	Deadline int64  `json:"deadline,omitempty"`
	// CancelAfter cancels the fetch once this many bytes completed (0 = never).
	CancelAfter int64 `json:"cancelAfter,omitempty"`
}

type fetchOutcome struct {
	Result    *psybridge.FetchResult `json:"result,omitempty"`
	Error     string                 `json:"error,omitempty"`
	MaxRSS    int64                  `json:"maxRSS"`
	ElapsedMS int64                  `json:"elapsedMS"`
}

func readHelperArgs() helperArgs {
	var a helperArgs
	if err := json.Unmarshal([]byte(os.Getenv("PSY_HELPER_ARGS")), &a); err != nil {
		fmt.Fprintln(os.Stderr, "bad helper args:", err)
		os.Exit(2)
	}
	return a
}

func helperEngine() {
	a := readHelperArgs()
	e, err := psybridge.NewEngine(&psybridge.EngineConfig{HomeDir: a.Home, CertPEM: a.CertPEM, KeyPEM: a.KeyPEM}, nil, nil)
	if err != nil {
		fmt.Println("ERROR", err)
		return
	}
	ep, err := e.Start(60_000)
	if err != nil {
		fmt.Println("ERROR", err)
		return
	}
	b, _ := json.Marshal(ep)
	fmt.Println("READY", string(b))
	_, _ = io.Copy(io.Discard, os.Stdin) // parent closes stdin to stop us
	if err := e.Stop(20_000); err != nil {
		fmt.Println("ERROR", err)
		return
	}
	fmt.Println("STOPPED")
}

type helperProgress struct {
	cancelAfter int64
	done        atomic.Int64
}

func (p *helperProgress) Progress(completed, total int64) { p.done.Store(completed) }
func (p *helperProgress) IsCancelled() bool {
	return p.cancelAfter > 0 && p.done.Load() >= p.cancelAfter
}

func helperFetch() {
	a := readHelperArgs()
	start := time.Now()
	res, err := psybridge.FetchFile(&psybridge.FetchRequest{
		HomeDir: a.Home, CertPEM: a.CertPEM, KeyPEM: a.KeyPEM,
		FolderID: a.Folder, Path: a.Path, ExpectedVersion: a.Expected,
		DestinationPath: a.Dest, DeadlineMillis: a.Deadline,
	}, &helperProgress{cancelAfter: a.CancelAfter})
	out := fetchOutcome{Result: res, ElapsedMS: time.Since(start).Milliseconds()}
	if err != nil {
		out.Error = err.Error()
	}
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	out.MaxRSS = ru.Maxrss // bytes on darwin
	b, _ := json.Marshal(out)
	fmt.Println("RESULT", string(b))
}

// --- parent-side helpers ---

type node struct {
	id       *psybridge.Identity
	devID    protocol.DeviceID
	home     string
	dir      string
	port     int
	endpoint *psybridge.APIEndpoint
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	lines    chan string
}

func newNode(t *testing.T, root, name string) *node {
	t.Helper()
	id, err := psybridge.GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	devID, _ := protocol.DeviceIDFromString(id.DeviceID)
	n := &node{id: id, devID: devID, home: filepath.Join(root, name, "Engine"), dir: filepath.Join(root, name, "Folders", "f"), port: freePort(t)}
	for _, d := range []string{n.home, filepath.Join(n.dir, ".stfolder")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	return n
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// writeConfig writes a hermetic config.xml: loopback listener, no
// discovery/relays/NAT, folder "f" shared with peers, watcher off.
func writeConfig(t *testing.T, n *node, peers ...*node) {
	t.Helper()
	c := config.New(n.devID)
	c.Options.RawListenAddresses = []string{fmt.Sprintf("tcp://127.0.0.1:%d", n.port)}
	c.Options.GlobalAnnEnabled = false
	c.Options.LocalAnnEnabled = false
	c.Options.RelaysEnabled = false
	c.Options.NATEnabled = false
	c.Options.URAccepted = -1
	f := c.Defaults.Folder.Copy()
	f.ID, f.Label, f.Path = "f", "f", n.dir
	f.FilesystemType = config.FilesystemTypeBasic
	f.FSWatcherEnabled = false
	f.RescanIntervalS = 3600
	f.Devices = []config.FolderDeviceConfiguration{{DeviceID: n.devID}}
	for _, p := range peers {
		d := c.Defaults.Device.Copy()
		d.DeviceID = p.devID
		d.Name = "peer"
		d.Addresses = []string{fmt.Sprintf("tcp://127.0.0.1:%d", p.port)}
		c.Devices = append(c.Devices, d)
		f.Devices = append(f.Devices, config.FolderDeviceConfiguration{DeviceID: p.devID})
	}
	c.Folders = []config.FolderConfiguration{f}
	w := config.Wrap(filepath.Join(n.home, "config.xml"), c, n.devID, events.NoopLogger)
	if err := w.Save(); err != nil {
		t.Fatal(err)
	}
}

func helperCmd(t *testing.T, mode string, args helperArgs) *exec.Cmd {
	t.Helper()
	b, _ := json.Marshal(args)
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), "PSY_HELPER="+mode, "PSY_HELPER_ARGS="+string(b))
	cmd.Stderr = os.Stderr
	return cmd
}

func (n *node) startEngine(t *testing.T) {
	t.Helper()
	cmd := helperCmd(t, "engine", helperArgs{Home: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM})
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	n.cmd, n.stdin, n.lines = cmd, stdin, make(chan string, 16)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			n.lines <- sc.Text()
		}
		close(n.lines)
	}()
	t.Cleanup(func() { n.stopEngine(t) })
	select {
	case line := <-n.lines:
		rest, ok := strings.CutPrefix(line, "READY ")
		if !ok {
			t.Fatalf("engine helper: %s", line)
		}
		n.endpoint = &psybridge.APIEndpoint{}
		if err := json.Unmarshal([]byte(rest), n.endpoint); err != nil {
			t.Fatal(err)
		}
	case <-time.After(90 * time.Second):
		t.Fatal("engine helper did not start")
	}
}

func (n *node) stopEngine(t *testing.T) {
	if n.cmd == nil {
		return
	}
	n.stdin.Close()
	for line := range n.lines {
		if strings.HasPrefix(line, "ERROR") {
			t.Errorf("engine stop: %s", line)
		}
	}
	_ = n.cmd.Wait()
	n.cmd = nil
}

func (n *node) fetch(t *testing.T, args helperArgs) fetchOutcome {
	t.Helper()
	args.Home, args.CertPEM, args.KeyPEM = n.home, n.id.CertPEM, n.id.KeyPEM
	if args.Folder == "" {
		args.Folder = "f"
	}
	out, err := helperCmd(t, "fetch", args).Output()
	if err != nil {
		t.Fatalf("fetch helper: %v\n%s", err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "RESULT "); ok {
			var o fetchOutcome
			if err := json.Unmarshal([]byte(rest), &o); err != nil {
				t.Fatal(err)
			}
			return o
		}
	}
	t.Fatalf("fetch helper printed no result:\n%s", out)
	return fetchOutcome{}
}

func restGet(t *testing.T, ep *psybridge.APIEndpoint, path string, into any) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, ep.BaseURL+path, nil)
	if ep.APIKey != "" {
		req.Header.Set("X-API-Key", ep.APIKey)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	if into != nil && resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(resp.Body).Decode(into); err != nil {
			t.Fatalf("decode %s: %v", path, err)
		}
	}
	return resp.StatusCode
}

func eventually(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(end) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func code(errText string) string { return psybridge.ErrorCode(errText) }

func formatMiB(v float64) string { return strconv.FormatFloat(v, 'f', 1, 64) }
func formatInt(v int64) string   { return strconv.FormatInt(v, 10) }

func restPost(t *testing.T, ep *psybridge.APIEndpoint, path string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, ep.BaseURL+path, nil)
	req.Header.Set("X-API-Key", ep.APIKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("POST %s: %d", path, resp.StatusCode)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// record runs RecordFetchedFile in a helper process and returns its error text.
func (n *node) record(t *testing.T, path, version string) string {
	t.Helper()
	out, err := helperCmd(t, "record", helperArgs{Home: n.home, CertPEM: n.id.CertPEM, KeyPEM: n.id.KeyPEM, Folder: "f", Path: path, Expected: version}).Output()
	if err != nil {
		t.Fatalf("record helper: %v\n%s", err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if rest, ok := strings.CutPrefix(line, "RESULT"); ok {
			return strings.TrimSpace(rest)
		}
	}
	t.Fatalf("record helper printed no result:\n%s", out)
	return ""
}
