// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"github.com/syncthing/syncthing/lib/model"
	"github.com/syncthing/syncthing/lib/protocol"
)

type syncPeerReadinessSource interface {
	RemoteIndexReadiness(deviceID protocol.DeviceID, folderID string) (model.RemoteIndexReadiness, error)
}

// syncPeerReadiness queries Syncthing's reliable current receive-primary
// proof directly. It deliberately does not reconstruct security state from
// the lossy public event subscription.
type syncPeerReadiness struct {
	source syncPeerReadinessSource
}

func newSyncPeerReadiness(source syncPeerReadinessSource) *syncPeerReadiness {
	return &syncPeerReadiness{source: source}
}

func (r *syncPeerReadiness) state(deviceID protocol.DeviceID, folderID string) model.RemoteIndexReadinessState {
	if r == nil || r.source == nil {
		return model.RemoteIndexProofMissing
	}
	readiness, err := r.source.RemoteIndexReadiness(deviceID, folderID)
	if err != nil {
		return model.RemoteIndexProofMissing
	}
	return readiness.State
}

func (r *syncPeerReadiness) ready(deviceID protocol.DeviceID, folderID string) bool {
	return r.state(deviceID, folderID) == model.RemoteIndexProofCurrent
}
