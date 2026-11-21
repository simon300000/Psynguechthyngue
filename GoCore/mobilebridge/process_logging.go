// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"context"
	"log/slog"
)

// embeddedDiscardLogHandler disables record construction as well as output.
// Syncthing's process-global logger can otherwise serialize connection
// identities, filesystem paths, and peer-controlled metadata to stdout.
type embeddedDiscardLogHandler struct{}

func (embeddedDiscardLogHandler) Enabled(context.Context, slog.Level) bool   { return false }
func (embeddedDiscardLogHandler) Handle(context.Context, slog.Record) error  { return nil }
func (handler embeddedDiscardLogHandler) WithAttrs([]slog.Attr) slog.Handler { return handler }
func (handler embeddedDiscardLogHandler) WithGroup(string) slog.Handler      { return handler }

var embeddedProcessLogger = slog.New(embeddedDiscardLogHandler{})

func installEmbeddedProcessLogger() {
	// This is deliberately process-lifetime state. Restoring a host logger on
	// Close could expose a late log from a runtime whose complete drain could
	// not be proved. NewCore and startRuntimeLocked both reinstall it so a host
	// logger configured before either boundary cannot receive Syncthing logs.
	slog.SetDefault(embeddedProcessLogger)
}
