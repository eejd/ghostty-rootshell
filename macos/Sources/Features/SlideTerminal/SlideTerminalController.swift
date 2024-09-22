import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// Controller for the slide-style terminal.
class SlideTerminalController: NSWindowController {
    override var windowNibName: NSNib.Name? { "SlideTerminal" }

    override func windowDidLoad() {
        guard let window = self.window else { return }

        // Make the window full width
        let screenFrame = NSScreen.main?.frame ?? .zero
        window.setFrame(NSRect(
            x: 0,
            y: 0,
            width: screenFrame.size.width,
            height: window.frame.size.height
        ), display: false)

        slideWindowIn(window: window)
    }

    private func slideWindowIn(window: NSWindow) {
        guard let screen = NSScreen.main else { return }

        // Determine our final position. Our final position is exactly
        // pinned against the top menu bar.
        let windowFrame = window.frame
        let finalY = screen.visibleFrame.maxY - windowFrame.height

        // Move our window off screen to the top
        window.setFrameOrigin(.init(
            x: windowFrame.origin.x,
            y: screen.frame.maxY))

        // Set the window invisible
        window.alphaValue = 0

        // Move it to the visible position since animation requires this
        window.makeKeyAndOrderFront(nil)

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = .init(name: .easeIn)

            let animator = window.animator()
            animator.setFrame(.init(
                origin: .init(x: windowFrame.origin.x, y: finalY),
                size: windowFrame.size
            ), display: true)
            animator.alphaValue = 1
        }
    }
}

enum SlideTerminalLocation {
    case top
}
