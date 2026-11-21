// SPDX-License-Identifier: MIT

package psybridge

import (
	"log/slog"
	"runtime/debug"
)

func newSlogForTest(shared *sinkShared) *slog.Logger { return slog.New(&sinkHandler{shared: shared}) }

func currentLimitMiB() int64 { return debug.SetMemoryLimit(-1) >> 20 }
