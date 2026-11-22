import FileProvider
import PsySync

/// Maps internal errors to what the File Provider framework understands.
enum ErrorMapping {
    static func map(_ error: Error) -> Error {
        let mapped = mapUnlogged(error)
        #if DEBUG
        let ns = mapped as NSError
        FootprintProbe.file?.append("error-returned \(ns.domain)/\(ns.code) from \(error)")
        #endif
        return mapped
    }

    private static func mapUnlogged(_ error: Error) -> Error {
        switch error {
        case let error as NSFileProviderError:
            return error
        case let error as FilesContentError:
            switch error {
            case .noSuchItem: return NSFileProviderError(.noSuchItem)
            case .isDirectory: return CocoaError(.fileReadUnknown)
            case .cancelled: return CocoaError(.userCancelled)
            case .openAppRequired(let reason):
                return NSFileProviderError(
                    .serverUnreachable,
                    userInfo: [NSLocalizedDescriptionKey: openAppMessage(reason), "PsyReason": reason.rawValue])
            case .requestFailed(let code):
                return NSFileProviderError(.serverUnreachable, userInfo: ["PsyReason": code])
            }
        case let error as FilesStoreError:
            switch error {
            case .anchorExpired: return NSFileProviderError(.syncAnchorExpired)
            case .noSuchItem: return NSFileProviderError(.noSuchItem)
            case .collision: return NSFileProviderError(.filenameCollision)
            case .invalidPath: return CocoaError(.fileWriteInvalidFileName)
            }
        case is PathContainmentError:
            return CocoaError(.fileWriteInvalidFileName)
        case let error as CocoaError where error.code == .fileWriteFileExists:
            return NSFileProviderError(.filenameCollision)
        default:
            return error
        }
    }

    static func openAppMessage(_ reason: FilesContentError.OpenAppReason) -> String {
        switch reason {
        case .tooLarge, .lowMemory:
            return String(localized: "FILES_ERROR_TOO_LARGE", defaultValue: "This file is too large to download here. Open Psynguechthyngue to download it.")
        case .staleIndex:
            return String(localized: "FILES_ERROR_STALE", defaultValue: "This file has changed on other devices. Open Psynguechthyngue to sync.")
        default:
            return String(localized: "FILES_ERROR_OPEN_APP", defaultValue: "No device is reachable. Open Psynguechthyngue to download this file.")
        }
    }
}
