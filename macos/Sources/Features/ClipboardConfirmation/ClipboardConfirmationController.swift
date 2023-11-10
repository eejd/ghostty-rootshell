import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// This initializes a clipboard confirmation warning window. The window itself
/// WILL NOT show automatically and the caller must show the window via
/// showWindow, beginSheet, etc.
class ClipboardConfirmationController: NSWindowController {
    override var windowNibName: NSNib.Name? { "ClipboardConfirmation" }

    let surface: ghostty_surface_t
    let contents: String
    let reason: Ghostty.ClipboardPromptReason
    let state: UnsafeMutableRawPointer?
    weak private var delegate: ClipboardConfirmationViewDelegate? = nil

    init(surface: ghostty_surface_t, contents: String, reason: Ghostty.ClipboardPromptReason, state: UnsafeMutableRawPointer?, delegate: ClipboardConfirmationViewDelegate) {
        self.surface = surface
        self.contents = contents
        self.reason = reason
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

        switch (reason) {
        case .unsafe:
            window.title = "Warning: Potentially Unsafe Paste"
        case .read, .write:
            window.title = "Authorize Clipboard Access"
        }

        window.contentView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: contents,
            reason: reason,
            delegate: delegate
        ))
    }
}
