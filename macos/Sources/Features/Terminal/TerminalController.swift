import Foundation
import Cocoa
import SwiftUI
import Combine

class TerminalController: NSWindowController, NSWindowDelegate {
    override var windowNibName: NSNib.Name? { "Terminal" }
    
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.AppState
    
    init(_ ghostty: Ghostty.AppState) {
        self.ghostty = ghostty
        super.init(window: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }
    
    //MARK: - NSWindowController
    
    override func windowWillLoad() {
        // We want every new terminal window to cascade so they don't directly overlap.
        shouldCascadeWindows = true
    }
    
    override func windowDidLoad() {
        guard let window = window else { return }

        // Terminals typically operate in sRGB color space and macOS defaults
        // to "native" which is typically P3. There is a lot more resources
        // covered in thie GitHub issue: https://github.com/mitchellh/ghostty/pull/376
        window.colorSpace = NSColorSpace.sRGB
        
        // Center the window to start, we'll move the window frame automatically
        // when cascading.
        window.center()
        
        // Initialize our content view to the SwiftUI root
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty
        ))
    }
    
    //MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
    }
}
