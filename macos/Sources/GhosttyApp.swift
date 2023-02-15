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
        case error, ready
    }
    
    /// The readiness value of the state.
    var readiness: Readiness { ghostty != nil ? .ready : .error }
    
    /// The ghostty global state.
    var ghostty: ghostty_t? = nil
    
    /// The ghostty global configuration.
    var config: ghostty_config_t? = nil
    
    init() {
        // Initialize ghostty global state. This happens once per process.
        guard let g = ghostty_init() else {
            GhosttyApp.logger.critical("ghostty_init failed")
            return
        }
        
        // Initialize the global configuration.
        guard let cfg = ghostty_config_new(g) else {
            GhosttyApp.logger.critical("ghostty_config_new failed")
            return
        }
        
        // TODO: we'd probably do some config loading here... for now we'd
        // have to do this synchronously. When we support config updating we can do
        // this async and update later.
        
        // Finalize will make our defaults available.
        ghostty_config_finalize(cfg)
        
        ghostty = g;
        config = cfg;
    }
    
    deinit {
        ghostty_config_free(ghostty, config)
    }
}
