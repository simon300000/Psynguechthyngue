import Foundation

/// Metadata may legitimately advance while native materialization publishes
/// local source state. Return the latest metadata with the exact fetched bytes,
/// so the next editor save starts from the version the core actually retained.
public struct FileProviderDeliveryFence: Sendable {
    private let item: IndexedItem
    public init(item: IndexedItem) { self.item = item }

    public func matches(_ current: IndexedItem) -> Bool {
        current.id == item.id && current.folderID == item.folderID && !current.isDirectory
            && current.contentVersion == item.contentVersion && current.size == item.size
    }
}
