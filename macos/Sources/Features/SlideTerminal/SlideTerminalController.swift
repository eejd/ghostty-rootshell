import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// Controller for the slide-style terminal.
class SlideTerminalController: NSWindowController, NSWindowDelegate, TerminalViewDelegate, TerminalViewModel {
    override var windowNibName: NSNib.Name? { "SlideTerminal" }

    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// The position for the slide terminal.
    let position: SlideTerminalPosition

    /// The surface tree for this window.
    @Published var surfaceTree: Ghostty.SplitNode? = nil

    init(_ ghostty: Ghostty.App,
         position: SlideTerminalPosition = .top,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: Ghostty.SplitNode? = nil
    ) {
        self.ghostty = ghostty
        self.position = position

        super.init(window: nil)

        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        self.surfaceTree = tree ?? .leaf(.init(ghostty_app, baseConfig: base))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        guard let window = self.window else { return }

        // The controller is the window delegate so we can detect events such as
        // window close so we can animate out.
        window.delegate = self

        // The slide window is not restorable (yet!). "Yet" because in theory we can
        // make this restorable, but it isn't currently implemented.
        window.isRestorable = false

        // Setup our content
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))

        // Animate the window in
        slideIn()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        slideOut()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let screen = NSScreen.main else { return frameSize }
        return position.restrictFrameSize(frameSize, on: screen)
    }

    //MARK: TerminalViewDelegate

    func cellSizeDidChange(to: NSSize) {
        guard ghostty.config.windowStepResize else { return }
        self.window?.contentResizeIncrements = to
    }

    func surfaceTreeDidChange() {
        if (surfaceTree == nil) {
            self.window?.close()
        }
    }

    // MARK: Slide Methods

    func slideIn() {
        guard let window = self.window else { return }
        slideWindowIn(window: window, from: position)
    }

    func slideOut() {
        guard let window = self.window else { return }
        slideWindowOut(window: window, to: position)
    }

    private func slideWindowIn(window: NSWindow, from position: SlideTerminalPosition) {
        guard let screen = NSScreen.main else { return }

        // Move our window off screen to the top
        position.setInitial(in: window, on: screen)

        // Move it to the visible position since animation requires this
        window.makeKeyAndOrderFront(nil)

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen)
        }
    }

    private func slideWindowOut(window: NSWindow, to position: SlideTerminalPosition) {
        guard let screen = NSScreen.main else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen)
        }
    }
}
