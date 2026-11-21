// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"log"
	"log/slog"
	"strings"
	"testing"
)

func TestEmbeddedRuntimeCannotWriteToPresetProcessLogger(t *testing.T) {
	previous := slog.Default()
	var captured bytes.Buffer
	slog.SetDefault(slog.New(slog.NewTextHandler(&captured, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })

	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })

	assertCommandOK(t, core, configurationSessionCommandForTest("private-logger-open", "openConfiguration", "private-logger-session"))
	rawConnectionID := "raw-connection-id-must-never-reach-preset-handler"
	slog.Info("Established secure connection", slog.String("connection", rawConnectionID))
	slog.Warn("Abandoning old index handler in favour of new connection", slog.String("old", rawConnectionID), slog.String("new", rawConnectionID))
	log.Printf("legacy connection log %s", rawConnectionID)
	assertCommandOK(t, core, configurationSessionCommandForTest("private-logger-close", "closeSession", "private-logger-session"))

	// Close must not restore the preset handler: a failed runtime drain may
	// still have a late logging goroutine, so the discard policy is permanent.
	slog.Error("late connection log", slog.String("connection", rawConnectionID))
	if output := captured.String(); output != "" || strings.Contains(output, rawConnectionID) {
		t.Fatalf("preset process logger received embedded runtime data: %q", output)
	}
}
