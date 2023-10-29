import SwiftUI
import GhosttyKit

struct TerminalView: View {
    @ObservedObject var ghostty: Ghostty.AppState
    
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
                
                Ghostty.TerminalSplit(onClose: Self.closeWindow, baseConfig: nil)
                    .ghosttyApp(ghostty.app!)
                    .ghosttyConfig(ghostty.config!)
                    .focused($focused)
                    .onAppear { self.focused = true }
            }
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
}
