// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

// Peer address cache.
//
// The App engine records, per device, addresses that are known to be
// dialable: the address of every *outgoing* connection that completed, plus
// what discovery (local, global, relays) currently knows. The restricted
// FetchFile core puts these in front of "dynamic" so its very first dial
// round (t≈0) already targets them, instead of waiting for local discovery
// (30 s broadcast interval) or a global lookup / relay.
const (
	PeerCacheFileName     = "peer-addresses.json"
	peerCacheVersion      = 1
	peerCacheMaxAddresses = 16
	peerCacheMaxAge       = 30 * 24 * time.Hour
	peerCacheRefresh      = 5 * time.Minute
)

type peerCacheFile struct {
	Version int                       `json:"version"`
	Updated time.Time                 `json:"updated"`
	Devices map[string]peerCacheEntry `json:"devices"`
}

type peerCacheEntry struct {
	// Addresses: dialable URIs, best first (last successful outgoing
	// connection, then discovery results incl. relay:// URIs).
	Addresses []string `json:"addresses"`
	// LastAddress / LastConnected: last outgoing connection that completed.
	LastAddress   string    `json:"lastAddress,omitempty"`
	LastConnected time.Time `json:"lastConnected,omitzero"`
	// Seen: when Addresses was last refreshed.
	Seen time.Time `json:"seen"`
}

func peerCachePath(homeDir string) string { return filepath.Join(homeDir, PeerCacheFileName) }

func readPeerCache(homeDir string) peerCacheFile {
	c := peerCacheFile{Version: peerCacheVersion, Devices: map[string]peerCacheEntry{}}
	raw, err := os.ReadFile(peerCachePath(homeDir))
	if err != nil {
		return c
	}
	var f peerCacheFile
	if json.Unmarshal(raw, &f) != nil || f.Version != peerCacheVersion || f.Devices == nil {
		return c
	}
	return f
}

func writePeerCache(homeDir string, c peerCacheFile) error {
	c.Version = peerCacheVersion
	c.Updated = time.Now().UTC()
	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := peerCachePath(homeDir) + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, peerCachePath(homeDir))
}

// cachedAddresses returns the usable cached addresses for a device.
func (c peerCacheFile) cachedAddresses(id protocol.DeviceID, now time.Time) []string {
	e, ok := c.Devices[id.String()]
	if !ok || now.Sub(e.Seen) > peerCacheMaxAge {
		return nil
	}
	var out []string
	for _, a := range e.Addresses {
		if a != "" && a != "dynamic" && !slices.Contains(out, a) {
			out = append(out, a)
		}
	}
	return out
}

// withCachedAddresses puts cached addresses in front of the configured ones
// (keeping "dynamic" so discovery and relays still run).
func withCachedAddresses(configured, cached []string) []string {
	out := make([]string, 0, len(cached)+len(configured))
	for _, a := range append(append([]string{}, cached...), configured...) {
		if !slices.Contains(out, a) {
			out = append(out, a)
		}
	}
	if len(out) == 0 {
		out = []string{"dynamic"}
	}
	return out
}

// connectionURI turns a DeviceConnected event into a dialable URI, or "" for
// incoming connections (their remote port is ephemeral) and relays (the
// relay URI needs parameters only discovery has).
func connectionURI(connType, addr string) string {
	scheme, dir, ok := strings.Cut(connType, "-")
	if !ok || dir != "client" || addr == "" {
		return ""
	}
	switch scheme {
	case "tcp", "quic":
		return scheme + "://" + addr
	}
	return ""
}

// peerCacheWriter runs inside the App engine.
type peerCacheWriter struct {
	homeDir string
	baseURL string
	apiKey  string
	myID    protocol.DeviceID

	mu    sync.Mutex
	cache peerCacheFile
}

func startPeerCacheWriter(ctx context.Context, homeDir, baseURL, apiKey string, myID protocol.DeviceID, evLogger events.Logger) {
	w := &peerCacheWriter{homeDir: homeDir, baseURL: baseURL, apiKey: apiKey, myID: myID, cache: readPeerCache(homeDir)}
	sub := evLogger.Subscribe(events.DeviceConnected)
	go func() {
		defer sub.Unsubscribe()
		tick := time.NewTicker(peerCacheRefresh)
		defer tick.Stop()
		// First discovery snapshot shortly after start.
		first := time.NewTimer(20 * time.Second)
		defer first.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case ev, ok := <-sub.C():
				if !ok {
					return
				}
				w.onConnected(ev)
				w.refreshDiscovery(ctx)
			case <-first.C:
				w.refreshDiscovery(ctx)
			case <-tick.C:
				w.refreshDiscovery(ctx)
			}
		}
	}()
}

func (w *peerCacheWriter) onConnected(ev events.Event) {
	data, ok := ev.Data.(map[string]string)
	if !ok {
		return
	}
	uri := connectionURI(data["type"], data["addr"])
	if uri == "" || data["id"] == "" {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.cache.Devices[data["id"]]
	e.LastAddress = uri
	e.LastConnected = time.Now().UTC()
	e.Seen = e.LastConnected
	e.Addresses = withCachedAddresses(nil, append([]string{uri}, e.Addresses...))
	e.Addresses = trimAddresses(e.Addresses)
	w.cache.Devices[data["id"]] = e
	_ = writePeerCache(w.homeDir, w.cache)
}

// refreshDiscovery merges the engine's discovery cache
// (GET /rest/system/discovery) into the file.
func (w *peerCacheWriter) refreshDiscovery(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, w.baseURL+"/rest/system/discovery", nil)
	if err != nil {
		return
	}
	req.Header.Set("X-API-Key", w.apiKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}
	var disco map[string]struct {
		Addresses []string `json:"addresses"`
	}
	if json.NewDecoder(resp.Body).Decode(&disco) != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	now := time.Now().UTC()
	changed := false
	for id, d := range disco {
		if id == w.myID.String() || len(d.Addresses) == 0 {
			continue
		}
		e := w.cache.Devices[id]
		var addrs []string
		if e.LastAddress != "" {
			addrs = append(addrs, e.LastAddress)
		}
		addrs = trimAddresses(withCachedAddresses(d.Addresses, addrs))
		if !slices.Equal(addrs, e.Addresses) || now.Sub(e.Seen) > time.Hour {
			e.Addresses, e.Seen = addrs, now
			w.cache.Devices[id] = e
			changed = true
		}
	}
	if changed {
		_ = writePeerCache(w.homeDir, w.cache)
	}
}

func trimAddresses(a []string) []string {
	a = slices.DeleteFunc(a, func(s string) bool { return s == "dynamic" || s == "" })
	if len(a) > peerCacheMaxAddresses {
		a = a[:peerCacheMaxAddresses]
	}
	return a
}
