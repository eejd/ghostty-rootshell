import SwiftUI
import GhosttyKit

protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)
    
    /// The title of the terminal should change.
    func titleDidChange(to: String)
    
    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)
}

extension TerminalViewDelegate {
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {}
    func titleDidChange(to: String) {}
    func cellSizeDidChange(to: NSSize) {}
}

struct TerminalView: View {
    @ObservedObject var ghostty: Ghostty.AppState
    
    // An optional delegate to receive information about terminal changes.
    weak var delegate: TerminalViewDelegate? = nil
    
    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool
    
    // Various state values sent back up from the currently focused terminals.
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
                    .onChange(of: focusedSurface) { newValue in
                        self.delegate?.focusedSurfaceDidChange(to: newValue)
                    }
                    .onChange(of: title) { newValue in
                        self.delegate?.titleDidChange(to: newValue)
                    }
                    .onChange(of: cellSize) { newValue in
                        guard let size = newValue else { return }
                        self.delegate?.cellSizeDidChange(to: size)
                    }
            }
        }
    }
    
    static func closeWindow() {
        guard let currentWindow = NSApp.keyWindow else { return }
        currentWindow.close()
    }
}
