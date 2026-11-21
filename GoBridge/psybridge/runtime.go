// SPDX-License-Identifier: MIT

package psybridge

import (
	"math"
	"runtime"
	"runtime/debug"
	"sync"
	"time"
)

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

// memoryWarningFactor/Duration: OnMemoryWarning lowers GOMEMLIMIT to 75% of
// the active profile for a while, then restores it.
const (
	memoryWarningPercent  = 75
	memoryWarningDuration = 2 * time.Minute
)

var (
	pressureMu       sync.Mutex
	pressureTimer    *time.Timer
	pressureBaseline int64
)

// applyRuntimeProfile applies limit/GC/maxprocs with defaults filled in and
// cancels any pending memory-warning restore.
func applyRuntimeProfile(limitMiB, gcPercent, maxProcs int64, defLimit, defGC int64, defProcs int) {
	if limitMiB <= 0 {
		limitMiB = defLimit
	}
	if gcPercent <= 0 {
		gcPercent = defGC
	}
	pressureMu.Lock()
	if pressureTimer != nil {
		pressureTimer.Stop()
		pressureTimer = nil
	}
	pressureMu.Unlock()
	ApplyMemoryProfile(limitMiB, gcPercent)
	if maxProcs <= 0 {
		maxProcs = int64(defProcs)
	}
	runtime.GOMAXPROCS(int(maxProcs))
}

// memoryWarning frees memory and temporarily lowers the soft limit. Repeated
// warnings extend the window but never compound the reduction.
func memoryWarning() {
	debug.FreeOSMemory()
	pressureMu.Lock()
	defer pressureMu.Unlock()
	if pressureTimer != nil {
		pressureTimer.Stop()
	} else {
		pressureBaseline = debug.SetMemoryLimit(-1)
	}
	baseline := pressureBaseline
	if baseline <= 0 || baseline == math.MaxInt64 {
		pressureTimer = nil
		return
	}
	lowered := baseline / 100 * memoryWarningPercent
	debug.SetMemoryLimit(lowered)
	pressureTimer = time.AfterFunc(memoryWarningDuration, func() {
		pressureMu.Lock()
		defer pressureMu.Unlock()
		// Only restore if nobody re-applied a profile meanwhile.
		if debug.SetMemoryLimit(-1) == lowered {
			debug.SetMemoryLimit(baseline)
		}
		pressureTimer = nil
	})
}
