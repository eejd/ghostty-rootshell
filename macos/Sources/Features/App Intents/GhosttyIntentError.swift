enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: return "The Ghostty app isn't properly initialized."
        case .surfaceNotFound: return "The terminal no longer exists."
        }
    }
}
