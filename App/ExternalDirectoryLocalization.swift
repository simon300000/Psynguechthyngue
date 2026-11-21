import PsyCore

func localizedExternalDirectoryAuthorizationError(
    _ error: ExternalDirectoryError
) -> String {
    switch error {
    case .authorizationDenied:
        String(localized: "Access to the selected directory was denied or revoked.")
    case .bookmarkStale, .unavailable:
        String(localized: "The selected directory or file provider is currently unavailable.")
    case .capabilityProbeFailed:
        String(
            localized: "The selected directory did not pass the safe capability checks. No authorization was saved."
        )
    case .bindingConflict:
        String(
            localized:
                "The selected directory conflicts with another authorized or app-managed directory, or changed during authorization. Choose it again or select a non-overlapping folder."
        )
    case .unsafeManagedRoot:
        String(
            localized: "A safe managed mirror could not be prepared. No external directory authorization was saved."
        )
    case .invalidBindingIdentifier:
        String(
            localized:
                "A safe Syncthing folder identifier could not be created. No external directory authorization was saved."
        )
    default:
        String(
            localized: "External directory authorization failed before any external data changed."
        )
    }
}

func localizedExternalDirectoryChildNameError(
    _ error: ExternalDirectoryChildNameValidationError
) -> String {
    switch error {
    case .empty:
        String(localized: "Enter a folder name.")
    case .dotComponent:
        String(localized: "The folder name cannot be a dot component.")
    case .pathSeparator:
        String(localized: "Enter one folder name without a path separator.")
    case .controlCharacter:
        String(localized: "The folder name contains an unsupported control character.")
    case .tooLong:
        String(localized: "The folder name is too long.")
    }
}

func localizedExternalDirectoryNamedChildError(
    _ error: ExternalDirectoryNamedChildError
) -> String {
    switch error {
    case .parentAuthorizationDenied:
        String(localized: "Access to the selected parent directory was denied or revoked.")
    case .unsafeParent:
        String(localized: "The selected parent directory is unsafe or unavailable.")
    case .unsafeExistingItem:
        String(localized: "An item with that name already exists and is not a safe directory.")
    case .creationFailed:
        String(localized: "The folder could not be created safely in the selected parent directory.")
    case .authorizationFailed:
        String(localized: "The new folder could not be authorized. No external path details were retained.")
    case .rollbackFailed:
        String(
            localized:
                "Authorization failed, and the new folder could not be removed because it changed or is no longer empty."
        )
    }
}
