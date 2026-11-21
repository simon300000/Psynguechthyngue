// SPDX-License-Identifier: MIT

package psybridge

import "runtime/debug"

// Runtime memory profiles (DESIGN.md §3.5). Values in MiB.
const (
	// App foreground engine: soft limit; GC works harder near it, never OOMs by itself.
	DefaultForegroundMemoryLimitMiB = 256
	// BGTask / BGContinuedProcessingTask engine.
	DefaultBackgroundMemoryLimitMiB = 160
	// File Provider extension restricted fetch (must stay far below the
	// extension's jetsam limit, which is undocumented and must be measured).
	DefaultRestrictedMemoryLimitMiB = 40

	DefaultGCPercent           = 100
	DefaultRestrictedGCPercent = 50
)

// ApplyMemoryProfile sets GOMEMLIMIT and GOGC for this process. Safe to call
// repeatedly (e.g. when moving between foreground and BGTask). Returns the
// previous limit in MiB.
func ApplyMemoryProfile(limitMiB int64, gcPercent int64) int64 {
	if limitMiB <= 0 {
		limitMiB = DefaultForegroundMemoryLimitMiB
	}
	if gcPercent <= 0 {
		gcPercent = DefaultGCPercent
	}
	prev := debug.SetMemoryLimit(limitMiB << 20)
	debug.SetGCPercent(int(gcPercent))
	return prev >> 20
}

// FreeOSMemory forces a GC and returns memory to the OS.
func FreeOSMemory() { debug.FreeOSMemory() }
