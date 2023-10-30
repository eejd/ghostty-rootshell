import SwiftUI
import GhosttyKit

protocol TerminalViewDelegate: AnyObject, ObservableObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)
    
    /// The title of the terminal should change.
    func titleDidChange(to: String)
    
    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)
    
    /// The last surface closed so there are no active surfaces.
    func lastSurfaceDidClose()
}

protocol TerminalViewModel: ObservableObject {
    var surfaceTree: Ghostty.SplitNode? { get set }
}

extension TerminalViewDelegate {
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {}
    func titleDidChange(to: String) {}
    func cellSizeDidChange(to: NSSize) {}
    func lastSurfaceDidClose() {}
}

struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.AppState
    
    // The required view model
    @ObservedObject var viewModel: ViewModel
    
    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)? = nil
    
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
                
                Ghostty.TerminalSplit(node: $viewModel.surfaceTree)
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
    
    func onClose() {
        self.delegate?.lastSurfaceDidClose()
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false
    
    var body: some View {
        HStack {
            Spacer()
            
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            
            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }
            
            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .onTapGesture {
            isPopover = true
        }
    }
}
