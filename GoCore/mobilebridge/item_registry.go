// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

const (
	itemRegistrySchemaVersion = 1
	maxItemRegistryEntries    = 1_000_000
)

type itemRegistryEntry struct {
	FolderID string `json:"folderID"`
	Path     string `json:"path"`
	ItemID   string `json:"itemID"`
}

type itemRegistryDocument struct {
	SchemaVersion        int                 `json:"schemaVersion"`
	Items                []itemRegistryEntry `json:"items"`
	Tombstones           []itemRegistryEntry `json:"tombstones"`
	SuppressedTombstones []itemRegistryEntry `json:"suppressedTombstones"`
}

// itemIDRegistry is app-owned identity state. Syncthing keys its index by
// path, so this small registry is what lets a bridge-originated rename retain
// its File Provider identifier without pretending remote delete/create pairs
// have an identity relationship that upstream does not expose.
type itemIDRegistry struct {
	path       string
	items      map[string]itemRegistryEntry
	tombstones map[string]itemRegistryEntry
	suppressed map[string]itemRegistryEntry
	ids        map[string]struct{}
	dirty      bool
}

type itemRegistryState struct {
	items      map[string]itemRegistryEntry
	tombstones map[string]itemRegistryEntry
	suppressed map[string]itemRegistryEntry
	dirty      bool
}

func loadItemIDRegistry(home string) (*itemIDRegistry, error) {
	registry := &itemIDRegistry{
		path:       filepath.Join(home, "Bridge", "item-identifiers-v1.json"),
		items:      make(map[string]itemRegistryEntry),
		tombstones: make(map[string]itemRegistryEntry),
		suppressed: make(map[string]itemRegistryEntry),
		ids:        make(map[string]struct{}),
	}
	registryDirectory := filepath.Dir(registry.path)
	if info, statErr := os.Lstat(registryDirectory); statErr == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("item identity registry directory is not a real directory")
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect item identity registry directory: %w", statErr)
	}
	if info, statErr := os.Lstat(registry.path); statErr == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("item identity registry is not a regular non-symlink file")
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect item identity registry: %w", statErr)
	}
	data, err := os.ReadFile(registry.path)
	if errors.Is(err, os.ErrNotExist) {
		return registry, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read item identity registry: %w", err)
	}
	if len(data) > 128<<20 {
		return nil, errors.New("item identity registry exceeds the supported size")
	}
	var document itemRegistryDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("decode item identity registry: %w", err)
	}
	if document.SchemaVersion != itemRegistrySchemaVersion {
		return nil, fmt.Errorf("unsupported item identity registry schema %d", document.SchemaVersion)
	}
	if len(document.Items)+len(document.Tombstones)+len(document.SuppressedTombstones) > maxItemRegistryEntries {
		return nil, errors.New("item identity registry entry limit exceeded")
	}
	seenIDs := make(map[string]string, len(document.Items)+len(document.Tombstones))
	for _, source := range []struct {
		name        string
		entries     []itemRegistryEntry
		destination map[string]itemRegistryEntry
		uniqueID    bool
	}{
		{"items", document.Items, registry.items, true},
		{"tombstones", document.Tombstones, registry.tombstones, true},
		{"suppressed tombstones", document.SuppressedTombstones, registry.suppressed, false},
	} {
		for _, entry := range source.entries {
			if entry.FolderID == "" || entry.Path == "" || entry.ItemID == "" {
				return nil, fmt.Errorf("%s contains an empty field", source.name)
			}
			if _, pathErr := validateRelativePath(entry.Path, false); pathErr != nil {
				return nil, fmt.Errorf("%s contains an unsafe path", source.name)
			}
			key := itemRegistryKey(entry.FolderID, entry.Path)
			if existing, ok := source.destination[key]; ok && existing.Path != entry.Path {
				return nil, fmt.Errorf("%s contains a case or Unicode path collision", source.name)
			}
			if source.uniqueID {
				if prior, ok := seenIDs[entry.ItemID]; ok && prior != key {
					return nil, fmt.Errorf("item identity %q is assigned to multiple paths", entry.ItemID)
				}
				seenIDs[entry.ItemID] = key
				registry.ids[entry.ItemID] = struct{}{}
			}
			source.destination[key] = entry
		}
	}
	return registry, nil
}

func itemRegistryKey(folderID, relativePath string) string {
	canonicalPath := cases.Fold().String(norm.NFC.String(relativePath))
	return folderID + "\x00" + canonicalPath
}

func (r *itemIDRegistry) itemID(folderID, relativePath string, deleted bool) (string, bool, error) {
	key := itemRegistryKey(folderID, relativePath)
	if suppressed, ok := r.suppressed[key]; ok {
		if suppressed.Path != relativePath {
			return "", false, errors.New("path collides by case or Unicode normalization")
		}
		if deleted {
			return "", true, nil
		}
		delete(r.suppressed, key)
		r.dirty = true
	}
	if deleted {
		if entry, ok := r.tombstones[key]; ok {
			if entry.Path != relativePath {
				return "", false, errors.New("path collides by case or Unicode normalization")
			}
			return entry.ItemID, false, nil
		}
		if entry, ok := r.items[key]; ok {
			if entry.Path != relativePath {
				return "", false, errors.New("path collides by case or Unicode normalization")
			}
			delete(r.items, key)
			r.tombstones[key] = entry
			r.dirty = true
			return entry.ItemID, false, nil
		}
		id, err := r.newID()
		if err != nil {
			return "", false, err
		}
		r.tombstones[key] = itemRegistryEntry{FolderID: folderID, Path: relativePath, ItemID: id}
		r.ids[id] = struct{}{}
		r.dirty = true
		return id, false, nil
	}
	if entry, ok := r.tombstones[key]; ok {
		if entry.Path != relativePath {
			return "", false, errors.New("path collides by case or Unicode normalization")
		}
		// A newly live object at a previously deleted path is a distinct File
		// Provider identity. Drop the old tombstone before allocating it so a
		// later delete cannot accidentally resurrect the stale identifier.
		delete(r.tombstones, key)
		r.dirty = true
	}
	if entry, ok := r.items[key]; ok {
		if entry.Path != relativePath {
			return "", false, errors.New("path collides by case or Unicode normalization")
		}
		return entry.ItemID, false, nil
	}
	id, err := r.newID()
	if err != nil {
		return "", false, err
	}
	r.items[key] = itemRegistryEntry{FolderID: folderID, Path: relativePath, ItemID: id}
	r.ids[id] = struct{}{}
	r.dirty = true
	return id, false, nil
}

func (r *itemIDRegistry) pathForItem(folderID, itemID string) (string, bool) {
	for _, entry := range r.items {
		if entry.FolderID == folderID && entry.ItemID == itemID {
			return entry.Path, true
		}
	}
	return "", false
}

func (r *itemIDRegistry) move(folderID, sourcePath, destinationPath, itemID string) error {
	sourceKey := itemRegistryKey(folderID, sourcePath)
	destinationKey := itemRegistryKey(folderID, destinationPath)
	if sourceKey == destinationKey && sourcePath != destinationPath {
		return errors.New("source and destination collide by case or Unicode normalization")
	}
	source, ok := r.items[sourceKey]
	if !ok || source.Path != sourcePath || source.ItemID != itemID {
		return errors.New("source item identity is not registered")
	}
	if destination, ok := r.items[destinationKey]; ok && destination.Path != sourcePath {
		return errors.New("destination identity already exists or collides by case or Unicode normalization")
	}
	delete(r.items, sourceKey)
	r.suppressed[sourceKey] = source
	source.Path = destinationPath
	r.items[destinationKey] = source
	r.dirty = true
	return nil
}

func (r *itemIDRegistry) snapshot() itemRegistryState {
	return itemRegistryState{
		items:      cloneRegistryEntries(r.items),
		tombstones: cloneRegistryEntries(r.tombstones),
		suppressed: cloneRegistryEntries(r.suppressed),
		dirty:      r.dirty,
	}
}

func (r *itemIDRegistry) restore(state itemRegistryState) {
	r.items = cloneRegistryEntries(state.items)
	r.tombstones = cloneRegistryEntries(state.tombstones)
	r.suppressed = cloneRegistryEntries(state.suppressed)
	r.dirty = state.dirty
	r.ids = make(map[string]struct{}, len(r.items)+len(r.tombstones))
	for _, entries := range []map[string]itemRegistryEntry{r.items, r.tombstones} {
		for _, entry := range entries {
			r.ids[entry.ItemID] = struct{}{}
		}
	}
}

func (r *itemIDRegistry) restoreAndSave(state itemRegistryState) error {
	r.restore(state)
	r.dirty = true
	return r.save()
}

func cloneRegistryEntries(source map[string]itemRegistryEntry) map[string]itemRegistryEntry {
	destination := make(map[string]itemRegistryEntry, len(source))
	for key, entry := range source {
		destination[key] = entry
	}
	return destination
}

func (r *itemIDRegistry) delete(folderID, relativePath, itemID string) error {
	key := itemRegistryKey(folderID, relativePath)
	entry, ok := r.items[key]
	if !ok || entry.Path != relativePath || entry.ItemID != itemID {
		return errors.New("item identity is not registered")
	}
	delete(r.items, key)
	r.tombstones[key] = entry
	r.dirty = true
	return nil
}

func (r *itemIDRegistry) newID() (string, error) {
	if len(r.items)+len(r.tombstones)+len(r.suppressed) >= maxItemRegistryEntries {
		return "", errors.New("item identity registry is full")
	}
	for range 8 {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return "", fmt.Errorf("generate item identity: %w", err)
		}
		candidate := "i1_" + base64.RawURLEncoding.EncodeToString(random[:])
		if _, collision := r.ids[candidate]; !collision {
			return candidate, nil
		}
	}
	return "", errors.New("could not allocate a unique item identity")
}

func (r *itemIDRegistry) save() error {
	if !r.dirty {
		return nil
	}
	document := itemRegistryDocument{
		SchemaVersion:        itemRegistrySchemaVersion,
		Items:                registryEntries(r.items),
		Tombstones:           registryEntries(r.tombstones),
		SuppressedTombstones: registryEntries(r.suppressed),
	}
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode item identity registry: %w", err)
	}
	directory := filepath.Dir(r.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create item identity registry directory: %w", err)
	}
	directoryInfo, err := os.Lstat(directory)
	if err != nil || !directoryInfo.IsDir() || directoryInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("item identity registry directory is not a real directory")
	}
	temporary, err := os.CreateTemp(directory, ".item-identifiers-*")
	if err != nil {
		return fmt.Errorf("create item identity registry temporary file: %w", err)
	}
	temporaryPath := temporary.Name()
	cleanup := func() { _ = os.Remove(temporaryPath) }
	defer cleanup()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("protect item identity registry: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write item identity registry: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync item identity registry: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close item identity registry: %w", err)
	}
	if err := os.Rename(temporaryPath, r.path); err != nil {
		return fmt.Errorf("replace item identity registry: %w", err)
	}
	if directoryHandle, err := os.Open(directory); err == nil {
		_ = directoryHandle.Sync()
		_ = directoryHandle.Close()
	}
	r.dirty = false
	return nil
}

func registryEntries(source map[string]itemRegistryEntry) []itemRegistryEntry {
	entries := make([]itemRegistryEntry, 0, len(source))
	for _, entry := range source {
		entries = append(entries, entry)
	}
	slices.SortFunc(entries, func(left, right itemRegistryEntry) int {
		if left.FolderID != right.FolderID {
			if left.FolderID < right.FolderID {
				return -1
			}
			return 1
		}
		if left.Path < right.Path {
			return -1
		}
		if left.Path > right.Path {
			return 1
		}
		return 0
	})
	return entries
}
