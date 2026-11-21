// SPDX-License-Identifier: MIT

package psybridge

import (
	"fmt"
	"runtime/metrics"
	"syscall"
	"time"
)

// phaseTracer reports process peak RSS and Go runtime memory at fetch phases
// (debug log level only), so the extension's memory can be attributed.
type phaseTracer struct {
	sink    LogSink
	enabled bool
	start   time.Time
	samples []metrics.Sample
}

func newPhaseTracer(sink LogSink, enabled bool) *phaseTracer {
	t := &phaseTracer{sink: sink, enabled: enabled && sink != nil, start: time.Now()}
	if t.enabled {
		t.samples = []metrics.Sample{
			{Name: "/memory/classes/total:bytes"},         // all memory mapped by the Go runtime
			{Name: "/memory/classes/heap/objects:bytes"},  // live + unswept heap objects
			{Name: "/memory/classes/heap/stacks:bytes"},   // goroutine stacks
			{Name: "/memory/classes/heap/released:bytes"}, // returned to the OS
			{Name: "/sched/goroutines:goroutines"},
		}
	}
	return t
}

// peakRSS: getrusage ru_maxrss (bytes on Darwin/iOS).
func peakRSS() int64 {
	var ru syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &ru) != nil {
		return 0
	}
	return int64(ru.Maxrss)
}

// phase logs one line and returns the current peak RSS.
func (t *phaseTracer) phase(name string) int64 {
	rss := peakRSS()
	if t == nil || !t.enabled {
		return rss
	}
	metrics.Read(t.samples)
	mib := func(i int) string { return fmt.Sprintf("%.1f", float64(t.samples[i].Value.Uint64())/(1<<20)) }
	fp, fpPeak := footprint()
	t.sink.Log("trace", fmt.Sprintf("fetch phase=%s t=%dms footprint=%.1fMiB footprintPeak=%.1fMiB peakRSS=%.1fMiB goMapped=%sMiB goHeap=%sMiB goStacks=%sMiB goReleased=%sMiB goroutines=%d",
		name, time.Since(t.start).Milliseconds(), float64(fp)/(1<<20), float64(fpPeak)/(1<<20), float64(rss)/(1<<20), mib(0), mib(1), mib(2), mib(3), t.samples[4].Value.Uint64()))
	return rss
}

func peakFootprint() int64 {
	_, peak := footprint()
	return peak
}
