import PsySync
import SwiftUI

extension FolderSyncState {
    var title: LocalizedStringKey {
        switch self {
        case .upToDate: "Up to date"
        case .syncing: "Syncing"
        case .scanning: "Scanning"
        case .waitingForDevices: "Waiting for devices"
        case .paused: "Paused"
        case .heldByPolicy: "On hold"
        case .offline: "Not running"
        case .error: "Error"
        }
    }

    var symbol: String {
        switch self {
        case .upToDate: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .scanning: "magnifyingglass"
        case .waitingForDevices: "clock"
        case .paused: "pause.circle"
        case .heldByPolicy: "hand.raised.circle"
        case .offline: "moon.zzz"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .upToDate: .green
        case .syncing, .scanning: .blue
        case .waitingForDevices, .heldByPolicy, .offline: .orange
        case .paused: .secondary
        case .error: .red
        }
    }
}

extension PolicyDecision.HoldReason {
    var message: LocalizedStringKey {
        switch self {
        case .noNetwork: "No network connection"
        case .cellularDisallowed: "Waiting for Wi-Fi (cellular sync is off)"
        case .lowDataMode: "Paused by Low Data Mode"
        case .lowPowerMode: "Paused by Low Power Mode"
        case .thermal: "Paused while the device cools down"
        }
    }
}

extension SyncIssue.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .folderPathMissing: "Folder not found"
        case .permissionDenied: "No permission"
        case .outOfSpace: "Not enough storage"
        case .fileError: "A file could not be synced"
        case .conflict: "File conflict"
        case .engineFailure: "Sync engine problem"
        case .other: "Problem"
        }
    }

    var advice: LocalizedStringKey {
        switch self {
        case .folderPathMissing: "The folder’s location is no longer available. Reconnect the drive or choose another location."
        case .permissionDenied: "The app is not allowed to change files in this folder."
        case .outOfSpace: "Free up some storage on this device, then sync again."
        case .fileError: "Other files keep syncing. Open the details to see which file is affected."
        case .conflict: "The same file was changed on two devices. Both versions were kept; open the folder in Files to choose which one to keep."
        case .engineFailure: "Try closing and reopening the app."
        case .other: "Open the details for more information."
        }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Upstream `type` is "tcp-client"/"quic-server"/"relay-client"…: it names
    /// the protocol, not LAN vs WAN, so LAN comes from `isLocalNetwork`.
    static func connectionLabel(_ conn: DeviceConnection?) -> LocalizedStringKey {
        let t = conn?.transport ?? ""
        if t.contains("relay") { return "Connected via relay" }
        if conn?.isLocalNetwork == true || t.contains("lan") { return "Connected on local network" }
        if conn?.isLocalNetwork == false || t.contains("wan") { return "Connected over the internet" }
        return "Connected"
    }
}
