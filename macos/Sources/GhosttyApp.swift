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
                TerminalView(app: ghostty.app!)
                    .modifier(WindowObservationModifier())
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
    
    /// The ghostty app instance. We only have one of these for the entire app, although I guess
    /// in theory you can have multiple... I don't know why you would...
    var app: ghostty_app_t? = nil

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
        self.config = cfg;
        
        // TODO: we'd probably do some config loading here... for now we'd
        // have to do this synchronously. When we support config updating we can do
        // this async and update later.
        
        // Finalize will make our defaults available.
        ghostty_config_finalize(cfg)
        
        // Create our "runtime" config. The "runtime" is the configuration that ghostty
        // uses to interface with the application runtime environment.
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            wakeup_cb: { userdata in GhosttyState.wakeup(userdata) })

        // Create the ghostty app.
        guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
            GhosttyApp.logger.critical("ghostty_app_new failed")
            readiness = .error
            return
        }
        self.app = app

        self.readiness = .ready
    }
    
    func appTick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }
    
    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let state = Unmanaged<GhosttyState>.fromOpaque(userdata!).takeUnretainedValue()
        
        // Wakeup can be called from any thread so we schedule the app tick
        // from the main thread. There is probably some improvements we can make
        // to coalesce multiple ticks but I don't think it matters from a performance
        // standpoint since we don't do this much.
        DispatchQueue.main.async { state.appTick() }
    }
    
    deinit {
        ghostty_app_free(app)
        ghostty_config_free(config)
    }
}
