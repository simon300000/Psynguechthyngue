import CoreSpotlight
import UniformTypeIdentifiers

/// Makes the app findable as "Syncthing" in system search.
///
/// There is no Info.plist key for an app-name alias in Spotlight, so the app
/// indexes one searchable item titled "Syncthing" (plus keywords). Spotlight
/// lists it under this app; tapping it simply opens the app. Siri / Shortcuts
/// pick up the same alias from `INAlternativeAppNames` in Info.plist.
enum SearchAlias {
    static let indexName = "app.psynguechthyngue.alias"
    static let itemIdentifier = "app.psynguechthyngue.alias.syncthing"
    static let keywords = ["Syncthing", "syncthing", "sync", "同步", "文件同步"]

    static func makeItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .application)
        attributes.title = "Syncthing"
        attributes.displayName = "Syncthing"
        attributes.contentDescription = String(localized: "Open Psynguechthyngue, the Syncthing client.")
        attributes.keywords = keywords
        let item = CSSearchableItem(uniqueIdentifier: itemIdentifier, domainIdentifier: "alias", attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    /// Idempotent; cheap enough to run on every launch.
    static func register() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex(name: indexName).indexSearchableItems([makeItem()]) { error in
            if let error { LifecycleLog.shared.record("search-alias", "index failed: \(error.localizedDescription)") }
        }
    }
}
