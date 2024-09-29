import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// Controller for the "quick" terminal.
class QuickTerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "QuickTerminal" }

    /// The position for the quick terminal.
    let position: QuickTerminalPosition

    /// The current state of the quick terminal
    private(set) var visible: Bool = false

    init(_ ghostty: Ghostty.App,
         position: QuickTerminalPosition = .top,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: Ghostty.SplitNode? = nil
    ) {
        self.position = position
        super.init(ghostty, baseConfig: base, surfaceTree: tree)
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

        // The quick window is not restorable (yet!). "Yet" because in theory we can
        // make this restorable, but it isn't currently implemented.
        window.isRestorable = false

        // Setup our initial size based on our configured position
        position.setLoaded(window)

        // Setup our content
        window.contentView = NSHostingView(rootView: TerminalView(
            ghostty: self.ghostty,
            viewModel: self,
            delegate: self
        ))

        // Animate the window in
        animateIn()
    }

    // MARK: NSWindowDelegate

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)

        // We don't animate out if there is a modal sheet being shown currently.
        // This lets us show alerts without causing the window to disappear.
        guard window?.attachedSheet == nil else { return }

        animateOut()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // We use the actual screen the window is on for this, since it should
        // be on the proper screen.
        guard let screen = window?.screen ?? NSScreen.main else { return frameSize }
        return position.restrictFrameSize(frameSize, on: screen)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: Ghostty.SplitNode?, to: Ghostty.SplitNode?) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is nil then we animate the window out.
        if (to == nil) {
            animateOut()
        }
    }

    // MARK: Methods

    func toggle() {
        if (visible) {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard !visible else { return }
        visible = true

        // If our application is not active, then we grab focus. The quick terminal
        // always grabs focus on animation in.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Animate the window in
        animateWindowIn(window: window, from: position)

        // If our surface tree is nil then we initialize a new terminal. The surface
        // tree can be nil if for example we run "eixt" in the terminal and force
        // animate out.
        if (surfaceTree == nil) {
            let leaf: Ghostty.SplitNode.Leaf = .init(ghostty.app!, baseConfig: nil)
            surfaceTree = .leaf(leaf)
            focusedSurface = leaf.surface
        }
    }

    func animateOut() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard visible else { return }
        visible = false

        animateWindowOut(window: window, to: position)
    }

    private func animateWindowIn(window: NSWindow, from position: QuickTerminalPosition) {
        guard let screen = ghostty.config.quickTerminalScreen.screen else { return }

        // Move our window off screen to the top
        position.setInitial(in: window, on: screen)

        // Move it to the visible position since animation requires this
        window.makeKeyAndOrderFront(nil)

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen)
        }, completionHandler: {
            // If we canceled our animation in we do nothing
            guard self.visible else { return }

            // If our focused view is somehow not connected to this window then the
            // function calls below do nothing. I don't think this is possible but
            // we should guard against it because it is a Cocoa assertion.
            guard let focusedView = self.focusedSurface,
                  focusedView.window == window else { return }

            // The window must become top-level
            window.makeKeyAndOrderFront(self)

            // The view must gain our keyboard focus
            window.makeFirstResponder(focusedView)
        })
    }

    private func animateWindowOut(window: NSWindow, to position: QuickTerminalPosition) {
        // We always animate out to whatever screen the window is actually on.
        guard let screen = window.screen ?? NSScreen.main else { return }

        // Keep track of if we were the key window. If we were the key window then we
        // want to move focus to the next window so that focus is preserved somewhere
        // in the app.
        let wasKey = window.isKeyWindow

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen)
        }, completionHandler: {
            guard wasKey else { return }
            self.focusNextWindow(on: screen)
        })
    }

    private func focusNextWindow(on screen: NSScreen) {
        let windows = NSApp.windows.filter {
            // Visible, otherwise we'll make an invisible window visible.
            guard $0.isVisible else { return false }

            // Same screen, just a preference...
            guard $0.screen == screen else { return false }

            // Same space (virtual screen). Otherwise we'll force an animation to
            // another space which is very jarring.
            guard $0.isOnActiveSpace else { return false }

            return true
        }

        // If we have no windows there is nothing to focus.
        guard !windows.isEmpty else { return }

        // Find the current key window (the window that is currently focused)
        if let keyWindow = NSApp.keyWindow,
           let currentIndex = windows.firstIndex(of: keyWindow) {
            // Calculate the index of the next window (cycle through the list)
            let nextIndex = (currentIndex + 1) % windows.count
            let nextWindow = windows[nextIndex]

            // Make the next window key and bring it to the front
            nextWindow.makeKeyAndOrderFront(nil)
        } else {
            // If there's no key window, focus the first available window
            windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: First Responder

    @IBAction override func closeWindow(_ sender: Any) {
        // Instead of closing the window, we animate it out.
        animateOut()
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Create New Tab"
        alert.informativeText = "Tabs aren't supported in the Quick Terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}
