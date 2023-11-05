import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

class PasteProtectionController: NSWindowController {
    override var windowNibName: NSNib.Name? { "PasteProtection" }
    
    //MARK: - NSWindowController
    
    override func windowDidLoad() {
        guard let window = window else { return }
        window.contentView = NSHostingView(rootView: PasteProtectionView())
    }
}
