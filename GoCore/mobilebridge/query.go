// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"

	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/protocol"
)

const (
	defaultQueryLimit       = 100
	maxQueryLimit           = 200
	maxQueryScanItems       = 250_000
	maxQuerySearchBytes     = 256
	maxBufferedEvents       = 512
	maxEventQueryLimit      = 100
	maxEventQueryTimeout    = time.Second
	itemCursorSchemaVersion = 1
)

const bridgeEventMask = events.DeviceConnected |
	events.DeviceDisconnected |
	events.PendingDevicesChanged |
	events.PendingFoldersChanged |
	events.LocalIndexUpdated |
	events.RemoteIndexUpdated |
	events.ItemFinished |
	events.StateChanged |
	events.ConfigSaved |
	events.FolderPaused |
	events.FolderResumed

type queryRequest struct {
	SchemaVersion                 int     `json:"schemaVersion"`
	RequestID                     string  `json:"requestID"`
	SessionID                     string  `json:"sessionID,omitempty"`
	TaskID                        string  `json:"taskID,omitempty"`
	PlanDigest                    string  `json:"planDigest,omitempty"`
	ExpectedConfigurationRevision string  `json:"expectedConfigurationRevision,omitempty"`
	MaximumNetworkBytes           string  `json:"maximumNetworkBytes,omitempty"`
	NetworkOperation              string  `json:"networkOperation,omitempty"`
	Query                         string  `json:"query"`
	FolderID                      string  `json:"folderID,omitempty"`
	Scope                         string  `json:"scope,omitempty"`
	Parent                        *string `json:"parent,omitempty"`
	Search                        string  `json:"search,omitempty"`
	Cursor                        string  `json:"cursor,omitempty"`
	Limit                         int     `json:"limit,omitempty"`
	IncludeDeleted                bool    `json:"includeDeleted,omitempty"`
	TimeoutMS                     int     `json:"timeoutMS,omitempty"`
	presentFields                 map[string]struct{}
}

func (request *queryRequest) UnmarshalJSON(data []byte) error {
	type queryRequestAlias queryRequest
	var decoded queryRequestAlias
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	*request = queryRequest(decoded)
	request.presentFields = make(map[string]struct{}, len(fields))
	for field := range fields {
		request.presentFields[field] = struct{}{}
	}
	return nil
}

func (request queryRequest) hasField(field string) bool {
	_, ok := request.presentFields[field]
	return ok
}

type itemQueryCursor struct {
	SchemaVersion  int    `json:"v"`
	FolderID       string `json:"folder"`
	Scope          string `json:"scope"`
	ParentPresent  bool   `json:"parentPresent"`
	Parent         string `json:"parent"`
	Search         string `json:"search"`
	IncludeDeleted bool   `json:"includeDeleted"`
	AfterPath      string `json:"afterPath"`
}

type indexedCandidate struct {
	RelativePath string
	Directory    bool
	Symlink      bool
	Size         int64
	ModifiedAt   time.Time
	Sequence     int64
	Tombstone    bool
	LocalOnly    bool
}

type candidatePageCollector struct {
	cursor      itemQueryCursor
	limit       int
	candidates  []indexedCandidate
	scanned     int
	lastScanned string
	scanLimited bool
}

func newCandidatePageCollector(cursor itemQueryCursor, limit int) *candidatePageCollector {
	return &candidatePageCollector{
		cursor:     cursor,
		limit:      limit,
		candidates: make([]indexedCandidate, 0, limit+1),
	}
}

// add returns false when the bounded page has enough information to return.
func (p *candidatePageCollector) add(candidate indexedCandidate) bool {
	if p.cursor.AfterPath != "" && candidate.RelativePath <= p.cursor.AfterPath {
		return true
	}
	p.scanned++
	p.lastScanned = candidate.RelativePath
	if p.scanned > maxQueryScanItems {
		p.scanLimited = true
		return false
	}
	if candidate.Tombstone && !p.cursor.IncludeDeleted {
		return true
	}
	if !queryPathMatches(candidate.RelativePath, p.cursor) {
		return true
	}
	p.candidates = append(p.candidates, candidate)
	return len(p.candidates) <= p.limit
}

type bridgeIndexItem struct {
	ItemID                   string   `json:"itemID"`
	FolderID                 string   `json:"folderID"`
	ParentID                 string   `json:"parentID,omitempty"`
	RelativePath             string   `json:"relativePath"`
	Name                     string   `json:"name"`
	Directory                bool     `json:"directory"`
	Symlink                  bool     `json:"symlink"`
	Size                     int64    `json:"size"`
	ModifiedAt               string   `json:"modifiedAt"`
	Version                  string   `json:"version"`
	ContentVersion           []byte   `json:"contentVersion"`
	MetadataVersion          []byte   `json:"metadataVersion"`
	Availability             string   `json:"availability"`
	LocalPresent             bool     `json:"localPresent"`
	RemoteReplicaCount       int      `json:"remoteReplicaCount"`
	ConnectedRemoteDeviceIDs []string `json:"connectedRemoteDeviceIDs"`
	Pinned                   bool     `json:"pinned"`
	Unuploaded               bool     `json:"unuploaded"`
	Tombstone                bool     `json:"tombstone"`
	Sequence                 int64    `json:"sequence"`
	ChangeCursor             string   `json:"changeCursor"`
	Generation               uint64   `json:"generation"`
	Source                   string   `json:"source"`
	Error                    string   `json:"error,omitempty"`
}

type itemQueryPayload struct {
	Query             string            `json:"query"`
	FolderID          string            `json:"folderID"`
	Scope             string            `json:"scope"`
	Generation        uint64            `json:"generation"`
	ChangeCursor      string            `json:"changeCursor"`
	Items             []bridgeIndexItem `json:"items"`
	NextCursor        string            `json:"nextCursor,omitempty"`
	HasMore           bool              `json:"hasMore"`
	ScanLimited       bool              `json:"scanLimited"`
	CursorConsistency string            `json:"cursorConsistency"`
}

type bridgeEvent struct {
	Cursor   string `json:"cursor"`
	GlobalID int    `json:"globalID"`
	Time     string `json:"time"`
	Type     string `json:"type"`
	FolderID string `json:"folderID,omitempty"`
	ItemPath string `json:"itemPath,omitempty"`
	DeviceID string `json:"deviceID,omitempty"`
	From     string `json:"from,omitempty"`
	To       string `json:"to,omitempty"`
}

type eventQueryPayload struct {
	Query      string        `json:"query"`
	Generation uint64        `json:"generation"`
	Events     []bridgeEvent `json:"events"`
	NextCursor string        `json:"nextCursor"`
	HasMore    bool          `json:"hasMore"`
	CursorGap  bool          `json:"cursorGap"`
}

func (c *Core) queryJSONLocked(raw string) (string, error) {
	var request queryRequest
	if err := decodeRequest(raw, &request); err != nil {
		return failureEnvelope(request.RequestID, "query", "invalid_request", err.Error())
	}
	if validationErr := validateRequest(request.SchemaVersion, request.RequestID); validationErr != nil {
		return failureEnvelope(request.RequestID, "query", validationErr.Code, validationErr.Message)
	}
	if sessionErr := c.preflightDataSessionLocked(
		request.SessionID,
		request.TaskID,
		request.PlanDigest,
		request.ExpectedConfigurationRevision,
		request.MaximumNetworkBytes,
		request.NetworkOperation,
		request.FolderID,
		request.Query == "recoveries",
	); sessionErr != nil {
		return failureEnvelope(request.RequestID, "query", sessionErr.Code, sessionErr.Message)
	}
	if err := c.requireRunningLocked(); err != nil {
		return failureEnvelope(request.RequestID, "query", err.Code, err.Message)
	}
	switch request.Query {
	case "items":
		payload, operationErr := c.queryItemsLocked(request)
		if operationErr != nil {
			return failureEnvelope(request.RequestID, "query", operationErr.Code, operationErr.Message)
		}
		return successEnvelope(request.RequestID, "query", payload)
	case "events":
		payload, operationErr := c.queryEventsLocked(request)
		if operationErr != nil {
			return failureEnvelope(request.RequestID, "query", operationErr.Code, operationErr.Message)
		}
		return successEnvelope(request.RequestID, "query", payload)
	case "recoveries":
		payload, operationErr := c.queryRecoveriesLocked(request)
		if operationErr != nil {
			return failureEnvelope(request.RequestID, "query", operationErr.Code, operationErr.Message)
		}
		return successEnvelope(request.RequestID, "query", payload)
	default:
		return failureEnvelope(request.RequestID, "query", "unsupported_query", "query must be items, events, or recoveries")
	}
}

func (c *Core) queryItemsLocked(request queryRequest) (itemQueryPayload, *responseError) {
	if request.TimeoutMS != 0 {
		return itemQueryPayload{}, commandError("invalid_query", "items query does not accept timeoutMS")
	}
	if request.FolderID == "" {
		return itemQueryPayload{}, commandError("invalid_folder_id", "items query requires folderID")
	}
	if err := validateFolderID(request.FolderID); err != nil {
		return itemQueryPayload{}, err
	}
	folder, ok := c.runtime.configuration.Folder(request.FolderID)
	if !ok {
		return itemQueryPayload{}, commandError("folder_not_found", "folder is not configured")
	}
	scope := request.Scope
	if scope == "" {
		scope = "global"
	}
	if scope != "global" && scope != "local" {
		return itemQueryPayload{}, commandError("invalid_query", "scope must be global or local")
	}
	if scope == "local" && request.IncludeDeleted {
		return itemQueryPayload{}, commandError("invalid_query", "local filesystem scope cannot include tombstones")
	}
	if len(request.Search) > maxQuerySearchBytes {
		return itemQueryPayload{}, commandError("invalid_query", "search exceeds 256 bytes")
	}
	parent := ""
	if request.Parent != nil {
		var parentErr *responseError
		parent, parentErr = validateRelativePath(*request.Parent, true)
		if parentErr != nil {
			return itemQueryPayload{}, parentErr
		}
	}
	limit := request.Limit
	if limit == 0 {
		limit = defaultQueryLimit
	}
	if limit < 1 || limit > maxQueryLimit {
		return itemQueryPayload{}, commandError("invalid_query", "limit must be between 1 and 200")
	}
	cursor := itemQueryCursor{
		SchemaVersion:  itemCursorSchemaVersion,
		FolderID:       request.FolderID,
		Scope:          scope,
		ParentPresent:  request.Parent != nil,
		Parent:         parent,
		Search:         request.Search,
		IncludeDeleted: request.IncludeDeleted,
	}
	if request.Cursor != "" {
		decoded, err := decodeItemQueryCursor(request.Cursor)
		if err != nil {
			return itemQueryPayload{}, commandError("invalid_cursor", err.Error())
		}
		if decoded.SchemaVersion != cursor.SchemaVersion || decoded.FolderID != cursor.FolderID || decoded.Scope != cursor.Scope ||
			decoded.ParentPresent != cursor.ParentPresent || decoded.Parent != cursor.Parent || decoded.Search != cursor.Search ||
			decoded.IncludeDeleted != cursor.IncludeDeleted {
			return itemQueryPayload{}, commandError("cursor_mismatch", "cursor belongs to a different items query")
		}
		cursor.AfterPath = decoded.AfterPath
	}
	changeCursor, cursorErr := c.folderChangeCursorLocked(request.FolderID)
	if cursorErr != nil {
		return itemQueryPayload{}, commandError("query_failed", cursorErr.Error())
	}
	var candidates []indexedCandidate
	var scanLimited bool
	var lastScanned string
	var queryErr error
	if scope == "global" {
		candidates, scanLimited, lastScanned, queryErr = c.globalCandidatesLocked(request.FolderID, cursor, limit)
	} else {
		candidates, scanLimited, lastScanned, queryErr = localCandidates(folder.Path, cursor, limit)
	}
	if queryErr != nil {
		return itemQueryPayload{}, commandError("query_failed", queryErr.Error())
	}
	hasMore := scanLimited || len(candidates) > limit
	if len(candidates) > limit {
		candidates = candidates[:limit]
		lastScanned = candidates[len(candidates)-1].RelativePath
	}
	items := make([]bridgeIndexItem, 0, len(candidates))
	for _, candidate := range candidates {
		item, suppressed, err := c.bridgeIndexItemLocked(folder, candidate, scope, changeCursor)
		if err != nil {
			return itemQueryPayload{}, commandError("query_failed", err.Error())
		}
		if suppressed {
			continue
		}
		items = append(items, item)
	}
	if err := c.itemRegistry.save(); err != nil {
		return itemQueryPayload{}, commandError("identity_registry_save_failed", err.Error())
	}
	payload := itemQueryPayload{
		Query:             "items",
		FolderID:          request.FolderID,
		Scope:             scope,
		Generation:        c.generation,
		ChangeCursor:      changeCursor,
		Items:             items,
		HasMore:           hasMore,
		ScanLimited:       scanLimited,
		CursorConsistency: "keyset-best-effort; compare changeCursor and restart on change",
	}
	if hasMore && lastScanned != "" {
		cursor.AfterPath = lastScanned
		encoded, err := encodeItemQueryCursor(cursor)
		if err != nil {
			return itemQueryPayload{}, commandError("query_failed", err.Error())
		}
		payload.NextCursor = encoded
	}
	return payload, nil
}

func (c *Core) globalCandidatesLocked(folderID string, cursor itemQueryCursor, limit int) ([]indexedCandidate, bool, string, error) {
	sequence, iterationError := c.runtime.app.Internals.AllGlobalFiles(folderID)
	collector := newCandidatePageCollector(cursor, limit)
	for metadata := range sequence {
		relativePath := filepath.ToSlash(metadata.Name)
		if !collector.add(indexedCandidate{
			RelativePath: relativePath,
			Directory:    metadata.IsDirectory(),
			Symlink:      metadata.Type == protocol.FileInfoTypeSymlink,
			Size:         metadata.Size,
			ModifiedAt:   time.Unix(0, metadata.ModNanos),
			Sequence:     metadata.Sequence,
			Tombstone:    metadata.Deleted,
		}) {
			break
		}
	}
	if err := iterationError(); err != nil {
		return nil, false, "", err
	}
	return collector.candidates, collector.scanLimited, collector.lastScanned, nil
}

func localCandidates(root string, cursor itemQueryCursor, limit int) ([]indexedCandidate, bool, string, error) {
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, false, "", fmt.Errorf("resolve folder root: %w", err)
	}
	collector := newCandidatePageCollector(cursor, limit)
	err = filepath.WalkDir(resolvedRoot, func(current string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if current == resolvedRoot {
			return nil
		}
		relative, err := filepath.Rel(resolvedRoot, current)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if isSyncthingInternalPath(relative) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !collector.add(indexedCandidate{
			RelativePath: relative,
			Directory:    info.IsDir(),
			Symlink:      info.Mode()&os.ModeSymlink != 0,
			Size:         info.Size(),
			ModifiedAt:   info.ModTime(),
			LocalOnly:    true,
		}) {
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return nil, false, "", err
	}
	return collector.candidates, collector.scanLimited, collector.lastScanned, nil
}

func queryPathMatches(relativePath string, cursor itemQueryCursor) bool {
	if cursor.ParentPresent && parentPath(relativePath) != cursor.Parent {
		return false
	}
	if cursor.Search == "" {
		return true
	}
	fold := cases.Fold()
	needle := fold.String(norm.NFC.String(cursor.Search))
	haystack := fold.String(norm.NFC.String(relativePath))
	return strings.Contains(haystack, needle)
}

func (c *Core) bridgeIndexItemLocked(folder config.FolderConfiguration, candidate indexedCandidate, scope, changeCursor string) (bridgeIndexItem, bool, error) {
	itemID, suppressed, err := c.itemRegistry.itemID(folder.ID, candidate.RelativePath, candidate.Tombstone)
	if err != nil || suppressed {
		return bridgeIndexItem{}, suppressed, err
	}
	parentID := ""
	if parent := parentPath(candidate.RelativePath); parent != "" {
		parentID, _, err = c.itemRegistry.itemID(folder.ID, parent, false)
		if err != nil {
			return bridgeIndexItem{}, false, err
		}
	}
	item := bridgeIndexItem{
		ItemID:       itemID,
		FolderID:     folder.ID,
		ParentID:     parentID,
		RelativePath: candidate.RelativePath,
		Name:         path.Base(candidate.RelativePath),
		Directory:    candidate.Directory,
		Symlink:      candidate.Symlink,
		Size:         candidate.Size,
		ModifiedAt:   candidate.ModifiedAt.UTC().Format(time.RFC3339Nano),
		Tombstone:    candidate.Tombstone,
		Sequence:     candidate.Sequence,
		ChangeCursor: changeCursor,
		Generation:   c.generation,
		Source:       scope,
		Pinned:       false,
	}
	file, found, infoErr := c.runtime.app.Internals.GlobalFileInfo(folder.ID, candidate.RelativePath)
	if infoErr != nil {
		item.Error = infoErr.Error()
	}
	if found {
		item.Version = file.Version.String()
		item.ContentVersion, item.MetadataVersion = fileVersionTokens(file)
		item.Directory = file.IsDirectory()
		item.Symlink = file.IsSymlink()
		item.Tombstone = file.IsDeleted()
		item.Size = file.Size
		item.ModifiedAt = file.ModTime().UTC().Format(time.RFC3339Nano)
	}
	localPresent, localErr := localItemPresent(folder.Path, candidate.RelativePath, item.Directory, item.Symlink)
	if localErr != nil {
		item.Error = localErr.Error()
	}
	item.LocalPresent = localPresent && !item.Tombstone
	var persistedReplicaIDs []string
	var remoteIDs []string
	if found && !file.IsDeleted() && !file.IsInvalid() {
		holders, holderErr := c.runtime.app.Internals.GlobalFileAvailability(folder.ID, file.Name)
		if holderErr != nil {
			item.Error = holderErr.Error()
		} else {
			seen := make(map[string]struct{}, len(holders))
			for _, deviceID := range holders {
				if deviceID == c.localDeviceID {
					continue
				}
				value := deviceID.String()
				if _, ok := seen[value]; ok {
					continue
				}
				seen[value] = struct{}{}
				persistedReplicaIDs = append(persistedReplicaIDs, value)
			}
		}
		block := protocol.BlockInfo{}
		if len(file.Blocks) != 0 {
			block = file.Blocks[0]
		}
		available, availabilityErr := c.runtime.app.Internals.BlockAvailability(folder.ID, file, block)
		if availabilityErr != nil {
			item.Error = availabilityErr.Error()
		} else {
			seen := make(map[string]struct{}, len(available))
			for _, availability := range available {
				if availability.FromTemporary || availability.ID == c.localDeviceID {
					continue
				}
				deviceID := availability.ID.String()
				if _, ok := seen[deviceID]; ok {
					continue
				}
				seen[deviceID] = struct{}{}
				remoteIDs = append(remoteIDs, deviceID)
			}
		}
	}
	slices.Sort(persistedReplicaIDs)
	slices.Sort(remoteIDs)
	item.ConnectedRemoteDeviceIDs = remoteIDs
	item.RemoteReplicaCount = len(persistedReplicaIDs)
	switch {
	case item.Tombstone:
		item.Availability = "error"
	case isSyncthingConflictCopy(candidate.RelativePath):
		// Conflict copies are intentionally conservative: even if a peer
		// currently reports the same bytes, the App must not expose them as
		// uploaded/evictable until the user resolves the conflict.
		item.Availability = "conflict"
	case item.LocalPresent:
		item.Availability = "local"
	case len(persistedReplicaIDs) != 0:
		item.Availability = "remoteOnly"
	default:
		item.Availability = "error"
	}
	item.Unuploaded = item.LocalPresent &&
		(len(persistedReplicaIDs) == 0 || item.Availability == "conflict")
	if len(item.ContentVersion) == 0 {
		item.ContentVersion, item.MetadataVersion = localVersionTokens(candidate)
	}
	return item, false, nil
}

func isSyncthingConflictCopy(relativePath string) bool {
	return strings.Contains(path.Base(relativePath), ".sync-conflict-")
}

func localItemPresent(root, relativePath string, directory, symlink bool) (bool, error) {
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return false, err
	}
	components := strings.Split(relativePath, "/")
	current := resolvedRoot
	for index, component := range components {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
		last := index == len(components)-1
		if info.Mode()&os.ModeSymlink != 0 {
			if last {
				return symlink, nil
			}
			return false, errors.New("local path contains a symlink ancestor")
		}
		if !last && !info.IsDir() {
			return false, errors.New("local path ancestor is not a directory")
		}
		if last {
			if directory {
				return info.IsDir(), nil
			}
			return info.Mode().IsRegular(), nil
		}
	}
	return false, nil
}

func fileVersionTokens(file protocol.FileInfo) ([]byte, []byte) {
	contentHash := sha256.New()
	_, _ = contentHash.Write([]byte("mobilebridge-content-v1\x00"))
	_, _ = contentHash.Write([]byte(file.Version.String()))
	_, _ = contentHash.Write([]byte{0})
	_, _ = contentHash.Write(file.BlocksHash)
	var numeric [8]byte
	binary.BigEndian.PutUint64(numeric[:], uint64(file.Size))
	_, _ = contentHash.Write(numeric[:])
	content := contentHash.Sum(nil)

	metadataHash := sha256.New()
	_, _ = metadataHash.Write([]byte("mobilebridge-metadata-v1\x00"))
	_, _ = metadataHash.Write(content)
	_, _ = metadataHash.Write([]byte(file.Name))
	binary.BigEndian.PutUint64(numeric[:], uint64(file.ModTime().UnixNano()))
	_, _ = metadataHash.Write(numeric[:])
	binary.BigEndian.PutUint64(numeric[:], uint64(file.Sequence))
	_, _ = metadataHash.Write(numeric[:])
	_, _ = metadataHash.Write([]byte{byte(file.Type)})
	if file.IsDeleted() {
		_, _ = metadataHash.Write([]byte{1})
	}
	return content, metadataHash.Sum(nil)
}

func localVersionTokens(candidate indexedCandidate) ([]byte, []byte) {
	encoded, _ := json.Marshal(struct {
		Path       string `json:"path"`
		Size       int64  `json:"size"`
		ModifiedAt int64  `json:"modifiedAt"`
		Directory  bool   `json:"directory"`
		Symlink    bool   `json:"symlink"`
	}{candidate.RelativePath, candidate.Size, candidate.ModifiedAt.UnixNano(), candidate.Directory, candidate.Symlink})
	content := sha256.Sum256(append([]byte("mobilebridge-local-content-v1\x00"), encoded...))
	metadata := sha256.Sum256(append([]byte("mobilebridge-local-metadata-v1\x00"), encoded...))
	return content[:], metadata[:]
}

func (c *Core) folderChangeCursorLocked(folderID string) (string, error) {
	counts, err := c.runtime.app.Internals.LocalSize(folderID)
	if err != nil {
		return "", err
	}
	eventCursor := 0
	if c.runtime.bufferedEvents != nil {
		events := c.runtime.bufferedEvents.Since(0, nil, 0)
		if len(events) != 0 {
			eventCursor = events[len(events)-1].SubscriptionID
		}
	}
	return fmt.Sprintf("g:%d;l:%d;e:%d", c.generation, counts.Sequence, eventCursor), nil
}

func encodeItemQueryCursor(cursor itemQueryCursor) (string, error) {
	data, err := json.Marshal(cursor)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeItemQueryCursor(raw string) (itemQueryCursor, error) {
	if len(raw) > 8192 {
		return itemQueryCursor{}, errors.New("cursor exceeds the supported size")
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return itemQueryCursor{}, errors.New("cursor is not valid base64url")
	}
	var cursor itemQueryCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return itemQueryCursor{}, errors.New("cursor payload is invalid")
	}
	return cursor, nil
}

func (c *Core) queryEventsLocked(request queryRequest) (eventQueryPayload, *responseError) {
	allowScopedFolder := c.session != nil && c.session.Mode == sessionModeNetwork && request.FolderID == c.session.FolderID
	if request.FolderID != "" && !allowScopedFolder || request.Scope != "" || request.Parent != nil || request.Search != "" || request.IncludeDeleted {
		return eventQueryPayload{}, commandError("invalid_query", "events query does not accept item filters")
	}
	if c.runtime.bufferedEvents == nil {
		return eventQueryPayload{}, commandError("query_failed", "event subscription is unavailable")
	}
	limit := request.Limit
	if limit == 0 {
		limit = maxEventQueryLimit
	}
	if limit < 1 || limit > maxEventQueryLimit {
		return eventQueryPayload{}, commandError("invalid_query", "event limit must be between 1 and 100")
	}
	if request.TimeoutMS < 0 || time.Duration(request.TimeoutMS)*time.Millisecond > maxEventQueryTimeout {
		return eventQueryPayload{}, commandError("invalid_query", "timeoutMS must be between 0 and 1000")
	}
	cursor := 0
	if request.Cursor != "" {
		parsed, err := strconv.Atoi(request.Cursor)
		if err != nil || parsed < 0 {
			return eventQueryPayload{}, commandError("invalid_cursor", "event cursor must be a non-negative integer")
		}
		cursor = parsed
	}
	upstreamEvents := c.runtime.bufferedEvents.Since(cursor, nil, time.Duration(request.TimeoutMS)*time.Millisecond)
	hasMore := len(upstreamEvents) > limit
	if hasMore {
		upstreamEvents = upstreamEvents[:limit]
	}
	result := make([]bridgeEvent, 0, len(upstreamEvents))
	nextCursor := cursor
	for _, upstream := range upstreamEvents {
		nextCursor = upstream.SubscriptionID
		event := bridgeEvent{
			Cursor:   strconv.Itoa(upstream.SubscriptionID),
			GlobalID: upstream.GlobalID,
			Time:     upstream.Time.UTC().Format(time.RFC3339Nano),
			Type:     upstream.Type.String(),
			FolderID: eventDataString(upstream.Data, "folder", "folderID"),
			ItemPath: eventDataString(upstream.Data, "item", "path"),
			DeviceID: eventDataString(upstream.Data, "device", "deviceID"),
			From:     eventDataString(upstream.Data, "from"),
			To:       eventDataString(upstream.Data, "to"),
		}
		if allowScopedFolder && event.FolderID != request.FolderID {
			continue
		}
		result = append(result, event)
	}
	gap := len(upstreamEvents) != 0 && upstreamEvents[0].SubscriptionID > cursor+1
	return eventQueryPayload{
		Query:      "events",
		Generation: c.generation,
		Events:     result,
		NextCursor: strconv.Itoa(nextCursor),
		HasMore:    hasMore,
		CursorGap:  gap,
	}, nil
}

func eventDataString(data any, keys ...string) string {
	encoded, err := json.Marshal(data)
	if err != nil || len(encoded) > 64<<10 {
		return ""
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		return ""
	}
	for _, key := range keys {
		if value, ok := object[key].(string); ok && len(value) <= 4096 {
			return value
		}
	}
	return ""
}

func parentPath(relativePath string) string {
	parent := path.Dir(relativePath)
	if parent == "." {
		return ""
	}
	return parent
}

func isSyncthingInternalPath(relativePath string) bool {
	for _, component := range strings.Split(relativePath, "/") {
		if component == config.DefaultMarkerName || component == ".stversions" ||
			component == ".stignore" || strings.HasPrefix(component, ".syncthing.") {
			return true
		}
	}
	return false
}
