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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate;
    
    var body: some Scene {
        WindowGroup {
            switch ghostty.readiness {
            case .loading:
                Text("Loading")
            case .error:
                ErrorView()
            case .ready:
                TerminalSplittableView(app: ghostty.app!)
                    .modifier(WindowObservationModifier())
            }
        }.commands {
            CommandGroup(after: .newItem) {
                Button("New Tab", action: newTab).keyboardShortcut("t", modifiers: [.command])
            }
        }
        
        Settings {
            SettingsView()
        }
    }
    
    // Create a new tab in the currently active window
    func newTab() {
        guard let currentWindow = NSApp.keyWindow else { return }
        guard let windowController = currentWindow.windowController else { return }
        windowController.newWindowForTab(nil)
        if let newWindow = NSApp.keyWindow, currentWindow != newWindow {
            currentWindow.addTabbedWindow(newWindow, ordered: .above)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])
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
    
    /// Cached clipboard string for `read_clipboard` callback.
    private var cached_clipboard_string: String? = nil

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
        
        // Load our configuration files from the home directory.
        ghostty_config_load_default_files(cfg);
        ghostty_config_load_recursive_files(cfg);
        
        // TODO: we'd probably do some config loading here... for now we'd
        // have to do this synchronously. When we support config updating we can do
        // this async and update later.
        
        // Finalize will make our defaults available.
        ghostty_config_finalize(cfg)
        
        // Create our "runtime" config. The "runtime" is the configuration that ghostty
        // uses to interface with the application runtime environment.
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            wakeup_cb: { userdata in GhosttyState.wakeup(userdata) },
            set_title_cb: { userdata, title in GhosttyState.setTitle(userdata, title: title) },
            read_clipboard_cb: { userdata in GhosttyState.readClipboard(userdata) },
            write_clipboard_cb: { userdata, str in GhosttyState.writeClipboard(userdata, string: str) })

        // Create the ghostty app.
        guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
            GhosttyApp.logger.critical("ghostty_app_new failed")
            readiness = .error
            return
        }
        self.app = app

        self.readiness = .ready
    }
    
    deinit {
        ghostty_app_free(app)
        ghostty_config_free(config)
    }
    
    func appTick() {
        guard let app = self.app else { return }
        ghostty_app_tick(app)
    }
    
    // MARK: Ghostty Callbacks
    
    static func readClipboard(_ userdata: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
        guard let appState = self.appState(fromSurface: userdata) else { return nil }
        guard let str = NSPasteboard.general.string(forType: .string) else { return nil }
        
        // Ghostty requires we cache the string because the pointer we return has to remain
        // stable until the next call to readClipboard.
        appState.cached_clipboard_string = str
        return (str as NSString).utf8String
    }
    
    static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, string: UnsafePointer<CChar>?) {
        guard let valueStr = String(cString: string!, encoding: .utf8) else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(valueStr, forType: .string)
    }
    
    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let state = Unmanaged<GhosttyState>.fromOpaque(userdata!).takeUnretainedValue()
        
        // Wakeup can be called from any thread so we schedule the app tick
        // from the main thread. There is probably some improvements we can make
        // to coalesce multiple ticks but I don't think it matters from a performance
        // standpoint since we don't do this much.
        DispatchQueue.main.async { state.appTick() }
    }
    
    static func setTitle(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) {
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        guard let titleStr = String(cString: title!, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            surfaceView.title = titleStr
        }
    }
    
    /// Returns the GhosttyState from the given userdata value.
    static func appState(fromSurface userdata: UnsafeMutableRawPointer?) -> GhosttyState? {
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        guard let surface = surfaceView.surface else { return nil }
        guard let app = ghostty_surface_app(surface) else { return nil }
        guard let app_ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyState>.fromOpaque(app_ud).takeUnretainedValue()
    }
}
