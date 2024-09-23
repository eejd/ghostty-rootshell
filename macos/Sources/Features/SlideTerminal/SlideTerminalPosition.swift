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
                origin: initialOrigin(for: window, on: screen),
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
                origin: finalOrigin(for: window, on: screen),
                size: window.frame.size
            ), display: true)
        }
    }

    /// Restrict the frame size during resizing.
    func restrictFrameSize(_ size: NSSize, on screen: NSScreen) -> NSSize {
        var finalSize = size
        switch (self) {
        case .top:
            finalSize.width = screen.frame.width
        }

        return finalSize
    }

    /// The initial point origin for this position.
    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: 0, y: screen.frame.maxY)
        }
    }

    /// The final point origin for this position.
    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        switch (self) {
        case .top:
            return .init(x: window.frame.origin.x, y: screen.visibleFrame.maxY - window.frame.height)
        }
    }
}
