// SPDX-License-Identifier: MIT

package psybridge

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
)

// sinkHandler forwards upstream slog records to the Swift LogSink with the
// current API key redacted. Upstream logs through slog.Default, which we
// replace while an engine or fetch is running.
type sinkHandler struct {
	shared *sinkShared
	attrs  []slog.Attr
	group  string
}

type sinkShared struct {
	mu      sync.RWMutex
	sink    LogSink
	level   slog.Level
	secrets []string
}

func (s *sinkShared) redact(msg string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, secret := range s.secrets {
		if secret != "" {
			msg = strings.ReplaceAll(msg, secret, "<redacted>")
		}
	}
	return msg
}

func (s *sinkShared) addSecret(secret string) {
	s.mu.Lock()
	s.secrets = append(s.secrets, secret)
	s.mu.Unlock()
}

func (h *sinkHandler) Enabled(_ context.Context, level slog.Level) bool {
	return h.shared.sink != nil && level >= h.shared.level
}

func (h *sinkHandler) Handle(_ context.Context, rec slog.Record) error {
	sink := h.shared.sink
	if sink == nil {
		return nil
	}
	var b strings.Builder
	b.WriteString(rec.Message)
	write := func(a slog.Attr) {
		key := a.Key
		if h.group != "" {
			key = h.group + "." + key
		}
		fmt.Fprintf(&b, " %s=%v", key, a.Value.Resolve().Any())
	}
	for _, a := range h.attrs {
		write(a)
	}
	rec.Attrs(func(a slog.Attr) bool { write(a); return true })
	level := "info"
	switch {
	case rec.Level >= slog.LevelError:
		level = "error"
	case rec.Level >= slog.LevelWarn:
		level = "warn"
	case rec.Level < slog.LevelInfo:
		level = "debug"
	}
	sink.Log(level, h.shared.redact(b.String()))
	return nil
}

func (h *sinkHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	n := *h
	n.attrs = append(append([]slog.Attr(nil), h.attrs...), attrs...)
	return &n
}

func (h *sinkHandler) WithGroup(name string) slog.Handler {
	n := *h
	if n.group != "" {
		name = n.group + "." + name
	}
	n.group = name
	return &n
}

// installLogSink makes upstream logging go to sink (or nowhere if nil) and
// returns the shared state so callers can register secrets to redact.
func installLogSink(sink LogSink, levelName string) *sinkShared {
	level := slog.LevelInfo
	if levelName == "debug" {
		level = slog.LevelDebug
	}
	shared := &sinkShared{sink: sink, level: level}
	slog.SetDefault(slog.New(&sinkHandler{shared: shared}))
	return shared
}
