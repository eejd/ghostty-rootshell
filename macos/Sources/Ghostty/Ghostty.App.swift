import SwiftUI
import GhosttyKit

extension Ghostty {
    // IMPORTANT: THIS IS NOT DONE.
    // This is a refactor/redo of Ghostty.AppState so that it supports both macOS and iOS
    class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }
        
        /// The readiness value of the state.
        @Published var readiness: Readiness = .loading
        
        /// The global app configuration. This defines the app level configuration plus any behavior
        /// for new windows, tabs, etc. Note that when creating a new window, it may inherit some
        /// configuration (i.e. font size) from the previously focused window. This would override this.
        private(set) var config: Config
        
        /// The ghostty app instance. We only have one of these for the entire app, although I guess
        /// in theory you can have multiple... I don't know why you would...
        @Published var app: ghostty_app_t? = nil {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }
        
        init() {
            // Initialize ghostty global state. This happens once per process.
            if ghostty_init() != GHOSTTY_SUCCESS {
                logger.critical("ghostty_init failed, weird things may happen")
                readiness = .error
            }

            // Initialize the global configuration.
            self.config = Config()
            if self.config.config == nil {
                readiness = .error
                return
            }
            
            // Create our "runtime" config. The "runtime" is the configuration that ghostty
            // uses to interface with the application runtime environment.
            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                reload_config_cb: { userdata in App.reloadConfig(userdata) },
                open_config_cb: { userdata in App.openConfig(userdata) },
                set_title_cb: { userdata, title in App.setTitle(userdata, title: title) },
                set_mouse_shape_cb: { userdata, shape in App.setMouseShape(userdata, shape: shape) },
                set_mouse_visibility_cb: { userdata, visible in App.setMouseVisibility(userdata, visible: visible) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in App.confirmReadClipboard(userdata, string: str, state: state, request: request ) },
                write_clipboard_cb: { userdata, str, loc, confirm in App.writeClipboard(userdata, string: str, location: loc, confirm: confirm) },
                new_split_cb: { userdata, direction, surfaceConfig in App.newSplit(userdata, direction: direction, config: surfaceConfig) },
                new_tab_cb: { userdata, surfaceConfig in App.newTab(userdata, config: surfaceConfig) },
                new_window_cb: { userdata, surfaceConfig in App.newWindow(userdata, config: surfaceConfig) },
                control_inspector_cb: { userdata, mode in App.controlInspector(userdata, mode: mode) },
                close_surface_cb: { userdata, processAlive in App.closeSurface(userdata, processAlive: processAlive) },
                focus_split_cb: { userdata, direction in App.focusSplit(userdata, direction: direction) },
                resize_split_cb: { userdata, direction, amount in
                    App.resizeSplit(userdata, direction: direction, amount: amount) },
                equalize_splits_cb: { userdata in
                    App.equalizeSplits(userdata) },
                toggle_split_zoom_cb: { userdata in App.toggleSplitZoom(userdata) },
                goto_tab_cb: { userdata, n in App.gotoTab(userdata, n: n) },
                toggle_fullscreen_cb: { userdata, nonNativeFullscreen in App.toggleFullscreen(userdata, nonNativeFullscreen: nonNativeFullscreen) },
                set_initial_window_size_cb: { userdata, width, height in App.setInitialWindowSize(userdata, width: width, height: height) },
                render_inspector_cb: { userdata in App.renderInspector(userdata) },
                set_cell_size_cb: { userdata, width, height in App.setCellSize(userdata, width: width, height: height) },
                show_desktop_notification_cb: { userdata, title, body in
                    App.showUserNotification(userdata, title: title, body: body)
                }
            )
            
            // Create the ghostty app.
            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app
            
            #if os(macOS)
            // Subscribe to notifications for keyboard layout change so that we can update Ghostty.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            #endif
            
            self.readiness = .ready
        }
        
        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            
            #if os(macOS)
            // Remove our observer
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            #endif
        }
        
        // MARK: Ghostty Callbacks
        
        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {}
        static func reloadConfig(_ userdata: UnsafeMutableRawPointer?) -> ghostty_config_t? { return nil }
        static func openConfig(_ userdata: UnsafeMutableRawPointer?) {}
        static func setTitle(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?) {}
        static func setMouseShape(_ userdata: UnsafeMutableRawPointer?, shape: ghostty_mouse_shape_e) {}
        static func setMouseVisibility(_ userdata: UnsafeMutableRawPointer?, visible: Bool) {}
        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) {}
        
        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {}
        
        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            location: ghostty_clipboard_e,
            confirm: Bool
        ) {}
        
        static func newSplit(
            _ userdata: UnsafeMutableRawPointer?,
            direction: ghostty_split_direction_e, 
            config: ghostty_surface_config_s
        ) {}
        
        static func newTab(_ userdata: UnsafeMutableRawPointer?, config: ghostty_surface_config_s) {}
        static func newWindow(_ userdata: UnsafeMutableRawPointer?, config: ghostty_surface_config_s) {}
        static func controlInspector(_ userdata: UnsafeMutableRawPointer?, mode: ghostty_inspector_mode_e) {}
        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {}
        static func focusSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_focus_direction_e) {}
        static func resizeSplit(_ userdata: UnsafeMutableRawPointer?, direction: ghostty_split_resize_direction_e, amount: UInt16) {}
        static func equalizeSplits(_ userdata: UnsafeMutableRawPointer?) {}
        static func toggleSplitZoom(_ userdata: UnsafeMutableRawPointer?) {}
        static func gotoTab(_ userdata: UnsafeMutableRawPointer?, n: Int32) {}
        static func toggleFullscreen(_ userdata: UnsafeMutableRawPointer?, nonNativeFullscreen: ghostty_non_native_fullscreen_e) {}
        static func setInitialWindowSize(_ userdata: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) {}
        static func renderInspector(_ userdata: UnsafeMutableRawPointer?) {}
        static func setCellSize(_ userdata: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) {}
        static func showUserNotification(_ userdata: UnsafeMutableRawPointer?, title: UnsafePointer<CChar>?, body: UnsafePointer<CChar>?) {}
    }
}
