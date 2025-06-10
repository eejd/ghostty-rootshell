import AppKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    // MARK: NSWindow Overrides

    override func awakeFromNib() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // All new windows are based on the app config at the time of creation.
        let config = appDelegate.ghostty.config

        // If window decorations are disabled, remove our title
        if (!config.windowDecorations) { styleMask.remove(.titled) }

        // Set our window positioning to coordinates if config value exists, otherwise
        // fallback to original centering behavior
        setInitialWindowPosition(
            x: config.windowPositionX,
            y: config.windowPositionY,
            windowDecorations: config.windowDecorations)

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // Get our saved level
        level = UserDefaults.standard.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    // MARK: Positioning And Styling

    /// This is called by the controller when there is a need to reset the window apperance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {}

    private func setInitialWindowPosition(x: Int16?, y: Int16?, windowDecorations: Bool) {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x, let y else {
            if (!LastWindowPosition.shared.restore(self)) {
                center()
            }

            return
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            center()
            return
        }

        // Orient based on the top left of the primary monitor
        let frame = screen.visibleFrame
        setFrameOrigin(.init(
            x: frame.minX + CGFloat(x),
            y: frame.maxY - (CGFloat(y) + frame.height)))
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}
