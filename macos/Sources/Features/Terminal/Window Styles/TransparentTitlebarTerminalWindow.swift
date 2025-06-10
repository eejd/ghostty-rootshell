import AppKit

class TransparentTitlebarTerminalWindow: TerminalWindow {
    private var reapplyTimer: Timer?

    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    deinit {
        reapplyTimer?.invalidate()
    }

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        if #available(macOS 26.0, *) {
            syncAppearanceTahoe(surfaceConfig)
        } else {
            syncAppearanceVentura(surfaceConfig)
        }
    }

    @available(macOS 26.0, *)
    private func syncAppearanceTahoe(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let titlebarBackgroundView else { return }
        titlebarBackgroundView.isHidden = true
        backgroundColor = NSColor(surfaceConfig.backgroundColor)
    }

    @available(macOS 13.0, *)
    private func syncAppearanceVentura(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let titlebarContainer else { return }

        let configBgColor = NSColor(surfaceConfig.backgroundColor)

        // Set our window background color so it shows up
        backgroundColor = configBgColor

        // Set the background color of our titlebar to match
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = configBgColor.withAlphaComponent(surfaceConfig.backgroundOpacity).cgColor
    }

    private var titlebarBackgroundView: NSView? {
        titlebarContainer?.firstDescendant(withClassName: "NSTitlebarBackgroundView")
    }

    private var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return titlebarContainerView
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return titlebarContainerView
        }

        return nil
    }

    private var titlebarContainerView: NSView? {
        contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
    }
}
