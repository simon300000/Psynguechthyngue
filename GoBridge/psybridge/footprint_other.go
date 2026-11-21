// SPDX-License-Identifier: MIT

//go:build !darwin && !ios

package psybridge

func footprint() (now, peak int64) { return 0, 0 }
