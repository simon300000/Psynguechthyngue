import Foundation
import Observation

/// Independent read model: search requests supersede older reads, including
/// a request that arrives while SQLite is suspended. Paging never mixes
/// generations, and a routine status refresh preserves the current list.
@MainActor
@Observable
public final class FileIndexModel {
    public init() {
        readPage = { request in
            await Self.read(
                paths: request.paths, snapshot: request.snapshot,
                incarnations: request.incarnations, query: request.query, cursor: request.cursor)
        }
    }

    init(readPage: @escaping @Sendable (ReadRequest) async -> Page) {
        self.readPage = readPage
    }

    @ObservationIgnored private let readPage: @Sendable (ReadRequest) async -> Page

    struct ReadRequest: Sendable {
        var paths: SharedContainerPaths
        var snapshot: CoreSnapshot
        var incarnations: [FolderID: String]
        var query: String
        var cursor: IndexedItemPageCursor?
    }

    public private(set) var items: [IndexedItem] = []
    public private(set) var retentionStatuses: [String: ContentRetentionStatus] = [:]
    public private(set) var totalCount = 0
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public private(set) var isUsingSnapshotFallback = false
    private var query = ""
    private var cursor: IndexedItemPageCursor?
    private var revision = UUID()
    private var loadedGeneration: UInt64?

    public func refresh(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        incarnations: [FolderID: String],
        query requestedQuery: String? = nil,
        force: Bool = false
    ) async {
        let nextQuery = (requestedQuery ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || isUsingSnapshotFallback || nextQuery != query || loadedGeneration != snapshot.generation else {
            return
        }
        if nextQuery != query {
            items = []
            retentionStatuses = [:]
        }
        query = nextQuery
        cursor = nil
        hasMore = false
        await load(paths: paths, snapshot: snapshot, incarnations: incarnations, reset: true)
    }

    public func loadMore(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        incarnations: [FolderID: String]
    ) async {
        guard hasMore, !isLoading else { return }
        guard loadedGeneration == snapshot.generation else {
            await refresh(paths: paths, snapshot: snapshot, incarnations: incarnations)
            return
        }
        await load(paths: paths, snapshot: snapshot, incarnations: incarnations, reset: false)
    }

    private func load(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        incarnations: [FolderID: String],
        reset: Bool
    ) async {
        let requestID = UUID()
        revision = requestID
        isLoading = true
        let requestedQuery = query
        let requestedCursor = reset ? nil : cursor
        let readPage = self.readPage
        let request = ReadRequest(
            paths: paths, snapshot: snapshot, incarnations: incarnations,
            query: requestedQuery, cursor: requestedCursor)
        let result = await Task.detached(priority: .userInitiated) { await readPage(request) }.value
        guard revision == requestID else { return }
        defer { isLoading = false }
        loadedGeneration = snapshot.generation
        totalCount = result.totalCount
        isUsingSnapshotFallback = result.isFallback
        // Fallback has no continuation cursor; replace rather than append it.
        items = reset || result.isFallback ? result.items : items + result.items
        retentionStatuses =
            reset || result.isFallback
            ? result.statuses : retentionStatuses.merging(result.statuses) { _, latest in latest }
        cursor = result.nextCursor
        hasMore = cursor != nil
    }

    struct Page: Sendable {
        var items: [IndexedItem]
        var statuses: [String: ContentRetentionStatus]
        var totalCount: Int
        var nextCursor: IndexedItemPageCursor?
        var isFallback: Bool
    }

    nonisolated private static func read(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        incarnations: [FolderID: String],
        query: String,
        cursor: IndexedItemPageCursor?
    ) async -> Page {
        do {
            let store = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex, accessMode: .readOnly, recoveryPolicy: .fail
            )
            guard try await store.currentGeneration() == snapshot.generation else {
                return fallback(paths: paths, snapshot: snapshot, incarnations: incarnations, query: query)
            }
            let page =
                try await query.isEmpty
                ? store.allItems(after: cursor, limit: 250)
                : store.search(query, after: cursor, limit: 250)
            let count = try await store.itemCount()
            guard try await store.currentGeneration() == snapshot.generation,
                count != 0 || snapshot.items.isEmpty
            else {
                return fallback(paths: paths, snapshot: snapshot, incarnations: incarnations, query: query)
            }
            let items = try ContentRetentionIntentResolver(metadataDatabaseURL: paths.metadataIndex)
                .applying(to: page.items)
            let statuses = try ContentRetentionStore(url: paths.contentRetention).statuses(
                for: items, folderIncarnations: incarnations
            )
            return Page(
                items: items, statuses: statuses, totalCount: count, nextCursor: page.nextCursor, isFallback: false)
        } catch {
            return fallback(paths: paths, snapshot: snapshot, incarnations: incarnations, query: query)
        }
    }

    nonisolated private static func fallback(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        incarnations: [FolderID: String],
        query: String
    ) -> Page {
        let matching = snapshot.items.filter { query.isEmpty || $0.relativePath.localizedStandardContains(query) }
            .sorted(by: IndexedMetadataStore.binaryItemOrderPrecedes)
        let items = Array(matching.prefix(250))
        let statuses =
            (try? ContentRetentionStore(url: paths.contentRetention).statuses(
                for: items, folderIncarnations: incarnations
            )) ?? [:]
        return Page(
            items: items, statuses: statuses, totalCount: snapshot.items.count, nextCursor: nil, isFallback: true)
    }
}
