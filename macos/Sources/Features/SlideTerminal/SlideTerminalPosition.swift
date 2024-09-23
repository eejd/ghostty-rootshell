import Cocoa

enum SlideTerminalPosition {
    case top

    /// Set the initial state for a window for animating out of this position.
    func setInitial(in window: NSWindow, on screen: NSScreen) {
        // We always start invisible
        window.alphaValue = 0

        // Position depends
        switch (self) {
        case .top:
            window.setFrame(.init(
                origin: .init(
                    x: 0,
                    y: screen.frame.maxY),
                size: .init(
                    width: screen.frame.width,
                    height: window.frame.height)
            ), display: false)
        }
    }

    /// Set the final state for a window in this position.
    func setFinal(in window: NSWindow, on screen: NSScreen) {
        // We always end visible
        window.alphaValue = 1

        // Position depends
        switch (self) {
        case .top:
            window.setFrame(.init(
                origin: .init(
                    x: window.frame.origin.x,
                    y: screen.visibleFrame.maxY - window.frame.height),
                size: window.frame.size
            ), display: true)
        }
    }
}
