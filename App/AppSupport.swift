import Foundation
import Network
import PsyCore
import UIKit
import UserNotifications

struct FolderRetentionApplicationContext: Sendable {
    let store: ContentRetentionStore
    let folderIncarnationDigest: String
}

enum FolderPolicyEditingError: LocalizedError, Sendable {
    case sharedContainerUnavailable
    case folderConfigurationChanged
    case folderIncarnationChanged

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            String(localized: "The shared policy store is unavailable.")
        case .folderConfigurationChanged:
            String(localized: "The folder configuration changed. Close this editor and try again.")
        case .folderIncarnationChanged:
            String(
                localized:
                    "This folder was removed or re-added while the editor was open. No settings were applied to the new folder incarnation."
            )
        }
    }
}

enum FolderSelectionContextError: LocalizedError {
    case folderConfigurationChanged
    case folderRootUnavailable
    case unsafeFolderRoot

    var errorDescription: String? {
        switch self {
        case .folderConfigurationChanged:
            String(
                localized:
                    "The folder configuration changed. Close this editor and reopen it before applying a selection.")
        case .folderRootUnavailable:
            String(localized: "The configured folder root is not an accessible directory.")
        case .unsafeFolderRoot:
            String(localized: "The configured folder root cannot be used safely for selection changes.")
        }
    }
}

func pathContains(_ parent: URL, _ child: URL) -> Bool {
    let parentComponents = parent.standardizedFileURL.pathComponents
    let childComponents = child.standardizedFileURL.pathComponents
    return childComponents.count >= parentComponents.count
        && Array(childComponents.prefix(parentComponents.count)) == parentComponents
}

func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
    pathContains(first, second) || pathContains(second, first)
}

let managedFolderMaximumRescanIntervalS = 365 * 24 * 60 * 60

enum PendingAcceptanceInputError: LocalizedError {
    case sharedContainerUnavailable
    case explicitConfirmationRequired
    case pendingStateUnavailable
    case offerChangedOrExpired
    case invalidEncryptedOffer
    case folderAlreadyConfigured
    case offeringDeviceNotSelected
    case invalidDeviceSelection
    case invalidManagedPath
    case suppressionChangedOrExpired
    case suppressionNotConfirmed
    case futureRequestsNotConfirmed
    case observationAlreadyInProgress
    case observationCoreBusy
    case observationConfigurationUnavailable
    case observationPolicyDenied
    case observationFailed
    case observedOfferChangedOrExpired
    case configurationChangedAfterObservation

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            String(localized: "The shared container is not ready.")
        case .explicitConfirmationRequired:
            String(localized: "Review the risks and explicitly confirm this pending request first.")
        case .pendingStateUnavailable:
            String(localized: "The core cannot currently provide authoritative pending-request state.")
        case .offerChangedOrExpired:
            String(
                localized:
                    "This pending request changed or expired. Refresh and review the current offer before accepting it."
            )
        case .invalidEncryptedOffer:
            String(localized: "The offer advertises an invalid encrypted-folder contract and cannot be accepted.")
        case .folderAlreadyConfigured:
            String(localized: "A folder with this ID is already configured, so the pending offer was not accepted.")
        case .offeringDeviceNotSelected:
            String(localized: "Explicitly select the device that offered this folder.")
        case .invalidDeviceSelection:
            String(localized: "Every selected device must still be a configured remote peer.")
        case .invalidManagedPath:
            String(localized: "The App-owned managed folder path could not be verified safely.")
        case .suppressionChangedOrExpired:
            String(
                localized:
                    "This ignored-request record changed or expired. Refresh before allowing future requests."
            )
        case .suppressionNotConfirmed:
            String(
                localized:
                    "The core did not confirm that this request is ignored in the latest snapshot. It was not treated as ignored."
            )
        case .futureRequestsNotConfirmed:
            String(
                localized:
                    "The core did not confirm that future requests are allowed in the latest snapshot. The request remains treated as ignored."
            )
        case .observationAlreadyInProgress:
            String(localized: "This pending folder offer is already being revalidated.")
        case .observationCoreBusy:
            String(localized: "The pending folder offer could not be revalidated because the core is busy.")
        case .observationConfigurationUnavailable:
            String(
                localized:
                    "The pending folder offer could not be revalidated because configuration is unavailable."
            )
        case .observationPolicyDenied:
            String(localized: "Current sync policy does not allow this bounded offer revalidation.")
        case .observationFailed:
            String(localized: "The pending folder offer could not be revalidated safely. Refresh and try again.")
        case .observedOfferChangedOrExpired:
            String(
                localized:
                    "The observed folder offer no longer matches the version you reviewed. Refresh and review the current offer again."
            )
        case .configurationChangedAfterObservation:
            String(
                localized:
                    "The configuration or offer changed after revalidation. Refresh and revalidate the offer before trying again."
            )
        }
    }
}

func pendingAcceptanceErrorMessage(_ error: any Error) -> String {
    if let inputError = error as? PendingAcceptanceInputError {
        return inputError.localizedDescription
    }
    if let sharedContainerError = error as? SharedContainerError {
        switch sharedContainerError {
        case .missingAppGroupIdentifier, .appGroupUnavailable:
            return String(localized: "The shared container is not ready.")
        case .invalidManagedRootToken, .invalidManagedFolderIdentifier,
            .managedFolderEscapesContainer, .unsafeManagedFolderRoot:
            return String(localized: "The App-owned managed folder path could not be verified safely.")
        }
    }
    if let commandError = error as? PendingAcceptanceCommandError {
        switch commandError {
        case .invalidName:
            return String(
                localized: "Enter a name or label no longer than 256 UTF-8 bytes and without control characters.")
        case .invalidManagedPath:
            return String(localized: "The App-owned managed folder path could not be verified safely.")
        case .invalidRescanInterval:
            return String(localized: "Enter a rescan interval from 0 to 31,536,000 seconds.")
        case .invalidDeviceSelection:
            return String(localized: "Every selected device must still be a configured remote peer.")
        case .offeringDeviceNotSelected:
            return String(localized: "Explicitly select the device that offered this folder.")
        case .invalidEncryptedFolderOffer:
            return String(
                localized: "The offer advertises an invalid encrypted-folder contract and cannot be accepted.")
        case .encryptedFolderTypeMismatch:
            return String(
                localized: "Encrypted offers must use Receive Encrypted; unencrypted offers cannot use that type.")
        case .deviceListEncodingFailed:
            return String(localized: "The selected device list could not be encoded.")
        case .observationProofMismatch:
            return String(
                localized:
                    "The observed folder offer no longer matches the version you reviewed. Refresh and review the current offer again."
            )
        case .observationProofExpired:
            return String(
                localized:
                    "The offer revalidation expired before it could be queued. Revalidate and try again."
            )
        }
    }
    if let producerError = error as? ScopedCoreCommandProducerError {
        switch producerError {
        case .snapshotUnavailable, .configurationRevisionUnavailable:
            return String(
                localized:
                    "The authoritative configuration snapshot became unavailable before the proof-backed request could be queued."
            )
        case .configurationRevisionMismatch:
            return String(
                localized:
                    "The configuration changed after offer revalidation. Refresh and revalidate the offer before trying again."
            )
        case .invalidProofBackedPendingFolderCommand:
            return String(localized: "The proof-backed folder request was rejected before it was queued.")
        default:
            return String(localized: "The proof-backed folder request was rejected before it was queued.")
        }
    }
    return String(localized: "The pending request could not be accepted safely.")
}

enum ManagedFolderInputError: LocalizedError {
    case sharedContainerUnavailable
    case invalidFolderID
    case duplicateFolderID
    case invalidLabel
    case invalidRescanInterval
    case invalidDeviceSelection
    case deviceListEncodingFailed

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            String(localized: "The shared container is not ready.")
        case .invalidFolderID:
            String(localized: "Folder ID must contain 1 to 64 characters and no control characters.")
        case .duplicateFolderID:
            String(localized: "A folder with this ID already exists.")
        case .invalidLabel:
            String(localized: "Label must contain 1 to 256 UTF-8 bytes and no control characters.")
        case .invalidRescanInterval:
            String(localized: "Rescan interval must be between 0 and 31,536,000 seconds.")
        case .invalidDeviceSelection:
            String(localized: "Every selected device must still be a configured remote peer.")
        case .deviceListEncodingFailed:
            String(localized: "The selected device list could not be encoded.")
        }
    }
}

enum NotificationDeepLinkError: Error {
    case snapshotUnavailable
}

/// The only bridge from privacy-minimized core requests to UserNotifications.
/// Content is fixed and category-only: it never interpolates snapshot labels,
/// paths, IDs, addresses, or recovery metadata onto the lock screen.
final class SystemNotificationDeliveryClient: NSObject, @unchecked Sendable,
    NotificationDeliveryClient, UNUserNotificationCenterDelegate
{
    static let shared = SystemNotificationDeliveryClient()

    private let center: UNUserNotificationCenter
    private let responseLock = NSLock()
    private var responseHandler: (@Sendable (NotificationDestination) -> Void)?
    private var bufferedDestinations: [NotificationDestination] = []

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func installResponseHandler(
        _ handler: @escaping @Sendable (NotificationDestination) -> Void
    ) {
        responseLock.lock()
        responseHandler = handler
        let bufferedDestinations = bufferedDestinations
        self.bufferedDestinations.removeAll(keepingCapacity: true)
        responseLock.unlock()
        for destination in bufferedDestinations { handler(destination) }
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async throws -> NotificationAuthorizationStatus {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    func schedule(
        _ request: NotificationDeliveryRequest
    ) async -> NotificationSchedulingDisposition {
        let content = UNMutableNotificationContent()
        switch request.kind {
        case .pendingDevice:
            content.title = String(localized: "A device request needs review")
            content.body = String(
                localized: "Open Psynguechthyngue to review the current device request."
            )
        case .pendingFolder:
            content.title = String(localized: "A folder offer needs review")
            content.body = String(
                localized: "Open Psynguechthyngue to review the current folder offer."
            )
        case .snapshotConflict:
            content.title = String(localized: "File conflicts need review")
            content.body = String(
                localized: "Open Psynguechthyngue to review the current conflict state."
            )
        case .mutationRecovery:
            content.title = String(localized: "A recovery item needs review")
            content.body = String(
                localized: "Open Psynguechthyngue to review the current recovery state."
            )
        }
        content.sound = .default
        content.userInfo = request.deepLinkPayload
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: request.identifier,
                    content: content,
                    trigger: nil
                )
            )
            return .accepted
        } catch {
            // Apple documents a non-nil completion error as a definite
            // scheduling failure. Express that distinction explicitly so the
            // durable coordinator never has to guess whether retrying can
            // duplicate a request.
            return .definitelyNotAccepted
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = response.notification.request.content.userInfo
        guard payload.count == 1,
            let rawDestination = payload["destination"] as? String,
            let destination = NotificationDestination(rawValue: rawDestination)
        else {
            return
        }
        deliverResponse(destination)
    }

    private nonisolated func deliverResponse(_ destination: NotificationDestination) {
        responseLock.lock()
        let handler = responseHandler
        if handler == nil, !bufferedDestinations.contains(destination) {
            bufferedDestinations.append(destination)
        }
        responseLock.unlock()
        handler?(destination)
    }

    private func map(
        _ status: UNAuthorizationStatus
    ) -> NotificationAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .provisional: .provisional
        case .authorized: .authorized
        case .ephemeral: .ephemeral
        @unknown default: .denied
        }
    }
}

/// Shared by foreground refresh and handlers that iOS has actually launched.
/// Calling this helper never requests authorization or opens Core/network work.
enum AppNotificationDelivery {
    static func deliver(
        paths: SharedContainerPaths,
        snapshot: CoreSnapshot,
        mutationRecoveries: [CoreMutationRecoverySummary] = []
    ) async -> NotificationDeliveryReport {
        await NotificationEventCoordinator(
            store: NotificationEventStore(url: paths.notificationEvents),
            client: SystemNotificationDeliveryClient.shared
        ).deliverNewEvents(
            snapshot: snapshot,
            mutationRecoveries: mutationRecoveries
        )
    }
}

@MainActor
final class NetworkStateMonitor {
    var onChange: ((NetworkState) -> Void)?
    private let monitor = NWPathMonitor()
    private var hasStarted = false
    private let queue = DispatchQueue(label: "io.psynguechthyngue.network-monitor")

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: NetworkKind
            if path.status != .satisfied {
                kind = .unavailable
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .ethernet
            } else if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else {
                kind = .other
            }
            let state = NetworkState(kind: kind, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor in self?.onChange?(state) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
