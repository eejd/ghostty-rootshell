enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: return "The Ghostty app isn't properly initialized."
        }
    }
}
