// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/protocol"
)

func TestApplyEmbeddedPolicyDisablesWatchersForExistingAndDefaultFolders(t *testing.T) {
	configuration := config.Configuration{
		Folders: []config.FolderConfiguration{
			{ID: "existing-folder", FSWatcherEnabled: true},
		},
		Defaults: config.Defaults{
			Folder: config.FolderConfiguration{FSWatcherEnabled: true},
		},
	}

	applyEmbeddedPolicy(&configuration, false)

	if configuration.Defaults.Folder.FSWatcherEnabled {
		t.Fatal("embedded policy left the default folder watcher enabled")
	}
	if configuration.Folders[0].FSWatcherEnabled {
		t.Fatal("embedded policy left an existing folder watcher enabled")
	}
}

func TestFolderCommandsKeepEmbeddedWatcherDisabled(t *testing.T) {
	core, err := NewCore(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	core.disableNetworkingForTests = true
	if err := core.Start(); err != nil {
		t.Fatal(err)
	}

	remote := protocol.NewDeviceID([]byte("embedded watcher policy peer"))
	assertCommandOK(t, core, commandForTest(
		"embedded-policy-add-device",
		"addDevice",
		"",
		remote.String(),
		nil,
	))

	setDefaultFolderWatcherForTest(t, core, true)
	addFolderID := "embedded-policy-added-folder"
	assertCommandOK(t, core, commandForTest(
		"embedded-policy-add-folder",
		"addFolder",
		addFolderID,
		"",
		map[string]string{
			"path":   t.TempDir(),
			"paused": "true",
		},
	))
	assertFolderWatcherDisabledForTest(t, core, addFolderID, "addFolder")

	setConfiguredFolderWatcherForTest(t, core, addFolderID, true)
	assertCommandOK(t, core, commandForTest(
		"embedded-policy-edit-folder",
		"editFolder",
		addFolderID,
		"",
		map[string]string{"label": "Edited while paused"},
	))
	assertFolderWatcherDisabledForTest(t, core, addFolderID, "editFolder")

	setDefaultFolderWatcherForTest(t, core, true)
	offer := pendingFolderOffer{
		FolderID:         "embedded-policy-accepted-folder",
		Label:            "Accepted folder",
		OfferingDeviceID: remote,
		LastSeen:         time.Now().UTC(),
	}
	core.pendingFolderOffersForTests = pendingFolderSourceForTest(offer)
	assertCommandOK(t, core, commandForTest(
		"embedded-policy-accept-folder",
		"acceptFolder",
		offer.FolderID,
		"",
		map[string]string{
			"offeringDeviceID": remote.String(),
			"offerVersion":     pendingFolderOfferVersion(offer),
			"path":             filepath.Clean(t.TempDir()),
			"type":             "sendReceive",
			"paused":           "true",
			"deviceIDs":        remote.String(),
		},
	))
	assertFolderWatcherDisabledForTest(t, core, offer.FolderID, "acceptFolder")
}

func setDefaultFolderWatcherForTest(t *testing.T, core *Core, enabled bool) {
	t.Helper()
	waiter, err := core.runtime.configuration.Modify(func(current *config.Configuration) {
		current.Defaults.Folder.FSWatcherEnabled = enabled
	})
	if err != nil {
		t.Fatal(err)
	}
	waiter.Wait()
}

func setConfiguredFolderWatcherForTest(t *testing.T, core *Core, folderID string, enabled bool) {
	t.Helper()
	waiter, err := core.runtime.configuration.Modify(func(current *config.Configuration) {
		folder, _, ok := current.Folder(folderID)
		if !ok {
			t.Fatalf("folder %q is unavailable", folderID)
		}
		folder.FSWatcherEnabled = enabled
		current.SetFolder(folder)
	})
	if err != nil {
		t.Fatal(err)
	}
	waiter.Wait()
}

func assertFolderWatcherDisabledForTest(t *testing.T, core *Core, folderID, command string) {
	t.Helper()
	folder, ok := core.runtime.configuration.Folder(folderID)
	if !ok {
		t.Fatalf("%s did not configure folder %q", command, folderID)
	}
	if folder.FSWatcherEnabled {
		t.Fatalf("%s left the embedded folder watcher enabled", command)
	}
}
