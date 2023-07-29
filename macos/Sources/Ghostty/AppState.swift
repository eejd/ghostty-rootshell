import SwiftUI
import GhosttyKit

extension Ghostty {
    enum AppReadiness {
        case loading, error, ready
    }
    
    /// The AppState is the global state that is associated with the Swift app. This handles initially
    /// initializing Ghostty, loading the configuration, etc.
    class AppState: ObservableObject {
        /// The readiness value of the state.
        @Published var readiness: AppReadiness = .loading
        
        /// The ghostty global configuration. This should only be changed when it is definitely
        /// safe to change. It is definite safe to change only when the embedded app runtime
        /// in Ghostty says so (usually, only in a reload configuration callback).
        var config: ghostty_config_t? = nil {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }
        
        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        var app: ghostty_app_t? = nil {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }
        
        /// Cached clipboard string for `read_clipboard` callback.
        private var cached_clipboard_string: String? = nil

        init() {
            // Initialize ghostty global state. This happens once per process.
            guard ghostty_init() == GHOSTTY_SUCCESS else {
                GhosttyAppController.logger.critical("ghostty_init failed")
                readiness = .error
                return
            }
            
            // Initialize the global configuration.
            guard let cfg = Self.reloadConfig() else {
                readiness = .error
                return
            }
            self.config = cfg;
            
            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                wakeup_cb: { userdata in AppState.wakeup(userdata) },
                reload_config_cb: { userdata in AppState.reloadConfig(userdata) },
                set_title_cb: { userdata, title in AppState.setTitle(userdata, title: title) },
                read_clipboard_cb: { userdata in AppState.readClipboard(userdata) },
                write_clipboard_cb: { userdata, str in AppState.writeClipboard(userdata, string: str) },
                new_split_cb: { userdata, direction in AppState.newSplit(userdata, direction: direction) },
                close_surface_cb: { userdata, processAlive in AppState.closeSurface(userdata, processAlive: processAlive) },
                focus_split_cb: { userdata, direction in AppState.focusSplit(userdata, direction: direction) },
                goto_tab_cb: { userdata, n in AppState.gotoTab(userdata, n: n) },
                toggle_fullscreen_cb: { userdata, nonNativeFullscreen in AppState.toggleFullscreen(userdata, useNonNativeFullscreen: nonNativeFullscreen) }
            )

            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
                GhosttyAppController.logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app

            self.readiness = .ready
        }
        
        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            self.config = nil
        }
        
        /// Initializes a new configuration and loads all the values.
        static func reloadConfig() -> ghostty_config_t? {
            // Initialize the global configuration.
            guard let cfg = ghostty_config_new() else {
                GhosttyAppController.logger.critical("ghostty_config_new failed")
                return nil
            }
            
            // Load our configuration files from the home directory.
            ghostty_config_load_default_files(cfg);
            ghostty_config_load_cli_args(cfg);
            ghostty_config_load_recursive_files(cfg);
            
            // TODO: we'd probably do some config loading here... for now we'd
            // have to do this synchronously. When we support config updating we can do
            // this async and update later.
            
            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)
            
            return cfg
        }
        
        func appTick() {
            guard let app = self.app else { return }
            
            // Tick our app, which lets us know if we want to quit
            let exit = ghostty_app_tick(app)
            if (!exit) { return }
                
            // We want to quit, start that process
            NSApplication.shared.terminate(nil)
        }
        
        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }
        
        func split(surface: ghostty_surface_t, direction: ghostty_split_direction_e) {
            ghostty_surface_split(surface, direction)
        }
        
        func splitMoveFocus(surface: ghostty_surface_t, direction: SplitFocusDirection) {
            ghostty_surface_split_focus(surface, direction.toNative())
        }
        
        // MARK: Ghostty Callbacks
        
        static func newSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_direction_e) {
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            NotificationCenter.default.post(name: Notification.ghosttyNewSplit, object: surface, userInfo: [
                "direction": direction,
            ])
        }
        
        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            NotificationCenter.default.post(name: Notification.ghosttyCloseSurface, object: surface, userInfo: [
                "process_alive": processAlive,
            ])
        }
        
        static func focusSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_focus_direction_e) {
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            guard let splitDirection = SplitFocusDirection.from(direction: direction) else { return }
            NotificationCenter.default.post(
                name: Notification.ghosttyFocusSplit,
                object: surface,
                userInfo: [
                    Notification.SplitDirectionKey: splitDirection,
                ]
            )
        }
        
        static func gotoTab(_ userdata: UnsafeMutableRawPointer?, n: Int32) {
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            NotificationCenter.default.post(
                name: Notification.ghosttyGotoTab,
                object: surface,
                userInfo: [
                    Notification.GotoTabKey: n,
                ]
            )
        }
        
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
        
        static func reloadConfig(_ userdata: UnsafeMutableRawPointer?) -> ghostty_config_t? {
            guard let newConfig = AppState.reloadConfig() else {
                GhosttyAppController.logger.warning("failed to reload configuration")
                return nil
            }
            
            // Assign the new config. This will automatically free the old config.
            // It is safe to free the old config from within this function call.
            let state = Unmanaged<AppState>.fromOpaque(userdata!).takeUnretainedValue()
            state.config = newConfig
            
            return newConfig
        }
        
        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<AppState>.fromOpaque(userdata!).takeUnretainedValue()
            
            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread. There is probably some improvements we can make
            // to coalesce multiple ticks but I don't think it matters from a performance
            // standpoint since we don't do this much.
            DispatchQueue.main.async { state.appTick() }
        }
        
        static func setTitle(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) {
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
            guard let titleStr = String(cString: title!, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                surfaceView.title = titleStr
            }
        }

        static func toggleFullscreen(_ userdata: UnsafeMutableRawPointer?, useNonNativeFullscreen: Bool) {
            // togo: use non-native fullscreen
            guard let surface = self.surfaceUserdata(from: userdata) else { return }
            NotificationCenter.default.post(
                name: Notification.ghosttyToggleFullscreen,
                object: surface,
                userInfo: [
                    Notification.NonNativeFullscreenKey: useNonNativeFullscreen,
                ]
            )
        }
        
        /// Returns the GhosttyState from the given userdata value.
        static private func appState(fromSurface userdata: UnsafeMutableRawPointer?) -> AppState? {
            let surfaceView = Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
            guard let surface = surfaceView.surface else { return nil }
            guard let app = ghostty_surface_app(surface) else { return nil }
            guard let app_ud = ghostty_app_userdata(app) else { return nil }
            return Unmanaged<AppState>.fromOpaque(app_ud).takeUnretainedValue()
        }
        
        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }
    }
}

// MARK: AppState Environment Keys

private struct GhosttyAppKey: EnvironmentKey {
    static let defaultValue: ghostty_app_t? = nil
}

extension EnvironmentValues {
    var ghosttyApp: ghostty_app_t? {
        get { self[GhosttyAppKey.self] }
        set { self[GhosttyAppKey.self] = newValue }
    }
}

extension View {
    func ghosttyApp(_ app: ghostty_app_t?) -> some View {
        environment(\.ghosttyApp, app)
    }
}
