import OSLog
import SwiftUI
import GhosttyKit

/// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
/// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
/// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
///
/// We just wrap an AppKit NSView here at the moment so that we can behave as low level as possible
/// since that is what the Metal renderer in Ghostty expects. In the future, it may make more sense to
/// wrap an MTKView and use that, but for legacy reasons we didn't do that to begin with.
struct TerminalSurfaceView: NSViewRepresentable {
    @StateObject private var state: TerminalSurfaceState
    
    init(app: ghostty_app_t) {
        self._state = StateObject(wrappedValue: TerminalSurfaceState(app))
    }
    
    func makeNSView(context: Context) -> TerminalSurfaceView_Real {
        // We need the view as part of the state to be created previously because
        // the view is sent to the Ghostty API so that it can manipulate it
        // directly since we draw on a render thread.
        return state.view;
    }
    
    func updateNSView(_ view: TerminalSurfaceView_Real, context: Context) {
        // Nothing we need to do here.
    }
}

/// The state for the terminal surface view.
class TerminalSurfaceState: ObservableObject {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: TerminalSurfaceState.self)
    )
    
    var view: TerminalSurfaceView_Real
    private var surface: ghostty_surface_t? = nil
    private var error: Error? = nil
    
    init(_ app: ghostty_app_t) {
        view = TerminalSurfaceView_Real()
        
        var surface_cfg = ghostty_surface_config_s(
            nsview: Unmanaged.passUnretained(view).toOpaque(),
            scale_factor: 2.0)
        guard let surface = ghostty_surface_new(app, &surface_cfg) else {
            self.error = AppError.surfaceCreateError
            return
        }
        
        self.surface = surface;
    }
    
    deinit {
        if let surface = self.surface {
            ghostty_surface_free(surface)
        }
    }
}

// The actual NSView implementation for the terminal surface.
class TerminalSurfaceView_Real: NSView {
    // We need to support being a first responder so that we can get input events
    override var acceptsFirstResponder: Bool { return true }
    
    override func draw(_ dirtyRect: NSRect) {
        print("DRAW: \(dirtyRect)")
        NSColor.green.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
    
    override func mouseDown(with event: NSEvent) {
        print("Mouse down: \(event)")
    }
    
    override func keyDown(with event: NSEvent) {
        print("Key down: \(event)")
    }
}

/*
 struct TerminalSurfaceView_Previews: PreviewProvider {
     static var previews: some View {
         TerminalSurfaceView()
     }
 }
 */
