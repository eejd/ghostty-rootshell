import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

class PasteProtectionController: NSWindowController {
    override var windowNibName: NSNib.Name? { "PasteProtection" }
    
    let surface: ghostty_surface_t
    let contents: String
    let state: UnsafeMutableRawPointer?
    weak private var delegate: PasteProtectionViewDelegate? = nil
    
    init(surface: ghostty_surface_t, contents: String, state: UnsafeMutableRawPointer?, delegate: PasteProtectionViewDelegate) {
        self.surface = surface
        self.contents = contents
        self.state = state
        self.delegate = delegate
        super.init(window: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }
    
    //MARK: - NSWindowController
    
    override func windowDidLoad() {
        guard let window = window else { return }
        window.contentView = NSHostingView(rootView: PasteProtectionView(
            contents: contents,
            delegate: delegate
        ))
    }
}
