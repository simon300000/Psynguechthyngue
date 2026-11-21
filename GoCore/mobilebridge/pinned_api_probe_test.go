// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"context"
	"time"

	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/syncthing"
)

// These helpers are deliberately never executed. They make the exact
// unstable upstream seams used by this bridge part of the compile contract so
// an upstream pin change fails here instead of silently changing behavior.
func probePinnedIndexAndBlockAPI(internals *syncthing.Internals, device protocol.DeviceID) {
	pendingFolders, _ := internals.PendingFolders(device)
	for folderID, pending := range pendingFolders {
		_ = folderID
		for offeringDeviceID, observed := range pending.OfferedBy {
			_ = offeringDeviceID
			_ = observed.Time
			_ = observed.Label
			_ = observed.ReceiveEncrypted
			_ = observed.RemoteEncrypted
		}
	}

	files, iterationError := internals.AllGlobalFiles("folder")
	for metadata := range files {
		_ = metadata.Name
		_ = metadata.Sequence
		_ = metadata.ModNanos
		_ = metadata.Size
		_ = metadata.Type
		_ = metadata.Deleted
		break
	}
	_ = iterationError()

	file, _, _ := internals.GlobalFileInfo("folder", "path")
	if len(file.Blocks) != 0 {
		availability, _ := internals.BlockAvailability("folder", file, file.Blocks[0])
		_, _ = internals.DownloadBlock(context.Background(), device, "folder", file.Name, 0, file.Blocks[0], false)
		_ = availability[0].ID
		_ = availability[0].FromTemporary
	}
	counts, _ := internals.LocalSize("folder")
	_ = counts.Sequence
	_ = internals.ScanFolderSubdirs("folder", []string{"path"})
}

func probePinnedEventAPI(logger events.Logger) {
	subscription := logger.Subscribe(
		events.LocalIndexUpdated |
			events.RemoteIndexUpdated |
			events.ItemFinished |
			events.PendingDevicesChanged |
			events.PendingFoldersChanged,
	)
	buffered := events.NewBufferedSubscription(subscription, 512)
	for _, event := range buffered.Since(0, nil, time.Millisecond) {
		_ = event.SubscriptionID
		_ = event.GlobalID
		_ = event.Time
		_ = event.Type
	}
	subscription.Unsubscribe()
}
