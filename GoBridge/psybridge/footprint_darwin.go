// SPDX-License-Identifier: MIT

//go:build darwin || ios

package psybridge

/*
#include <mach/mach.h>

// psy_footprint returns phys_footprint (what jetsam limits) and its peak.
static int psy_footprint(unsigned long long *now, unsigned long long *peak) {
	task_vm_info_data_t info;
	mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
	kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
	if (kr != KERN_SUCCESS) return -1;
	*now = info.phys_footprint;
	*peak = count >= TASK_VM_INFO_REV2_COUNT ? info.ledger_phys_footprint_peak : 0;
	return 0;
}
*/
import "C"

// footprint returns the process phys_footprint and its peak in bytes
// (Mach TASK_VM_INFO). iOS jetsam limits apply to this number, not to RSS.
func footprint() (now, peak int64) {
	var n, p C.ulonglong
	if C.psy_footprint(&n, &p) != 0 {
		return 0, 0
	}
	return int64(n), int64(p)
}
