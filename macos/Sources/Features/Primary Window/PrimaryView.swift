import SwiftUI
import GhosttyKit

struct PrimaryView: View {
    @ObservedObject var ghostty: Ghostty.AppState
    
    // We need access to our app delegate to know if we're quitting or not.
    // Make sure to use `@ObservedObject` so we can keep track of `appDelegate.confirmQuit`.
    @ObservedObject var appDelegate: AppDelegate
    
    // We need this to report back up the app controller which surface in this view is focused.
    let focusedSurfaceWrapper: FocusedSurfaceWrapper
    
    // If this is set, this is the base configuration that we build our surface out of.
    let baseConfig: Ghostty.SurfaceConfiguration?
    
    // We need access to our window to know if we're the key window and to
    // modify window properties in response to events from the surface (e.g.
    // updating the window title)
    var window: NSWindow
    
    // This handles non-native fullscreen
    @State private var fullScreen = FullScreenHandler()
    
    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool
    
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle
    @FocusedValue(\.ghosttySurfaceZoomed) private var zoomedSplit
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize
    
    // The title for our window
    private var title: String {
        var title = "👻"
        
        if let surfaceTitle = surfaceTitle {
            if (surfaceTitle.count > 0) {
                title = surfaceTitle
            }
        }
        
        if let zoomedSplit = zoomedSplit {
            if zoomedSplit {
                title = "🔍 " + title
            }
        }
        
        return title
    }
    
    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            let center = NotificationCenter.default
            let gotoTab = center.publisher(for: Ghostty.Notification.ghosttyGotoTab)
            let toggleFullscreen = center.publisher(for: Ghostty.Notification.ghosttyToggleFullscreen)
            
            VStack(spacing: 0) {
                // If we're running in debug mode we show a warning so that users
                // know that performance will be degraded.
                if (ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG) {
                    DebugBuildWarningView()
                }
                
                Ghostty.TerminalSplit(onClose: Self.closeWindow, baseConfig: self.baseConfig)
                    .ghosttyApp(ghostty.app!)
                    .ghosttyConfig(ghostty.config!)
                    .onReceive(gotoTab) { onGotoTab(notification: $0) }
                    .onReceive(toggleFullscreen) { onToggleFullscreen(notification: $0) }
                    .focused($focused)
                    .onAppear { self.focused = true }
                    .onChange(of: focusedSurface) { newValue in
                        self.focusedSurfaceWrapper.surface = newValue?.surface
                    }
                    .onChange(of: title) { newValue in
                        // We need to handle this manually because we are using AppKit lifecycle
                        // so navigationTitle no longer works.
                        self.window.title = newValue
                    }
                    .onChange(of: cellSize) { newValue in
                        if !ghostty.windowStepResize { return }
                        guard let size = newValue else { return }
                        self.window.contentResizeIncrements = size
                    }
            }
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
    
    private func onGotoTab(notification: SwiftUI.Notification) {
        // Notification center indiscriminately sends to every subscriber (makes sense)
        // but we only want to process this once. In order to process it once lets only
        // handle it if we're the focused window.
        guard self.window.isKeyWindow else { return }
        
        // Get the tab index from the notification
        guard let tabIndexAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabIndex = tabIndexAny as? Int32 else { return }
        
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows
        
        // This will be the index we want to actual go to
        let finalIndex: Int
        
        // An index that is invalid is used to signal some special values.
        if (tabIndex <= 0) {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }
            
            if (tabIndex == GHOSTTY_TAB_PREVIOUS.rawValue) {
                finalIndex = selectedIndex - 1
            } else if (tabIndex == GHOSTTY_TAB_NEXT.rawValue) {
                finalIndex = selectedIndex + 1
            } else {
                return
            }
        } else {
            // Tabs are 0-indexed here, so we subtract one from the key the user hit.
            finalIndex = Int(tabIndex - 1)
        }
        
        guard finalIndex >= 0 && finalIndex < tabbedWindows.count else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    private func onToggleFullscreen(notification: SwiftUI.Notification) {
        // Just like in `onGotoTab`, we might receive this multiple times. But
        // it's fine, because `toggleFullscreen` should only apply to the
        // currently focused window.
        guard self.window.isKeyWindow else { return }

        // Check whether we use non-native fullscreen
        guard let useNonNativeFullscreenAny = notification.userInfo?[Ghostty.Notification.NonNativeFullscreenKey] else { return }
        guard let useNonNativeFullscreen = useNonNativeFullscreenAny as? ghostty_non_native_fullscreen_e else { return }

        self.fullScreen.toggleFullscreen(window: window, nonNativeFullscreen: useNonNativeFullscreen)
        // After toggling fullscreen we need to focus the terminal again.
        self.focused = true
        
        // For some reason focus always gets moved to the first split when
        // toggling fullscreen, so we set it back to the correct one.
        if let focusedSurface {
            Ghostty.moveFocus(to: focusedSurface)
        }
    }
}
