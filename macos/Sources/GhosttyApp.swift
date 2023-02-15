import OSLog
import SwiftUI
import GhosttyKit

@main
struct GhosttyApp: App {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: GhosttyApp.self)
    )
    
    /// The ghostty global state. Only one per process.
    @StateObject private var ghostty = GhosttyState()
    
    var body: some Scene {
        WindowGroup {
            switch ghostty.readiness {
            case .loading:
                Text("Loading")
            case .error:
                ErrorView()
            case .ready:
                ContentView()
            }
        }
    }
}

class GhosttyState: ObservableObject {
    enum Readiness {
        case loading, error, ready
    }
    
    /// The readiness value of the state.
    @Published var readiness: Readiness = .loading
    
    /// The ghostty global configuration.
    var config: ghostty_config_t? = nil
    
    init() {
        // Initialize ghostty global state. This happens once per process.
        guard ghostty_init() == GHOSTTY_SUCCESS else {
            GhosttyApp.logger.critical("ghostty_init failed")
            readiness = .error
            return
        }
        
        // Initialize the global configuration.
        guard let cfg = ghostty_config_new() else {
            GhosttyApp.logger.critical("ghostty_config_new failed")
            readiness = .error
            return
        }
        
        // TODO: we'd probably do some config loading here... for now we'd
        // have to do this synchronously. When we support config updating we can do
        // this async and update later.
        
        // Finalize will make our defaults available.
        ghostty_config_finalize(cfg)
        
        config = cfg
        readiness = .ready
    }
    
    deinit {
        ghostty_config_free(config)
    }
}
