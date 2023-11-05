import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

class PasteProtectionController: NSWindowController {
    override var windowNibName: NSNib.Name? { "PasteProtection" }
    
    weak private var delegate: PasteProtectionViewDelegate? = nil
    
    init(delegate: PasteProtectionViewDelegate) {
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
            contents: "Hello",
            delegate: delegate
        ))
    }
}
