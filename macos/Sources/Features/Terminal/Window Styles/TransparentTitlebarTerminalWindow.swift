import AppKit

class TransparentTitlebarTerminalWindow: TerminalWindow {
    // We need to restore our last synced appearance so that we can reapply
    // the appearance in certain scenarios.
    private var lastSurfaceConfig: Ghostty.SurfaceView.DerivedConfig?
    
    // KVO observations
    private var tabGroupWindowsObservation: NSKeyValueObservation?

    override func awakeFromNib() {
        super.awakeFromNib()

        // We need to observe the tab group because we need to redraw on
        // tabbed window changes and there is no notification for that.
        setupTabGroupObservation()
    }
    
    deinit {
        tabGroupWindowsObservation?.invalidate()
    }

    override func becomeMain() {
        // On macOS Tahoe, the tab bar redraws and restores non-transparency when
        // switching tabs. To overcome this, we resync the appearance whenever this
        // window becomes main (focused).
        if #available(macOS 26.0, *),
           let lastSurfaceConfig {
            syncAppearance(lastSurfaceConfig)
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        lastSurfaceConfig = surfaceConfig
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

    // MARK: View Finders

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
    
    // MARK: Tab Group Observation
    
    private func setupTabGroupObservation() {
        // Remove existing observation if any
        tabGroupWindowsObservation?.invalidate()
        tabGroupWindowsObservation = nil
        
        // Check if tabGroup is available
        guard let tabGroup else { return }

        // Set up KVO observation for the windows array. Whenever it changes
        // we resync the appearance because it can cause macOS to redraw the
        // tab bar.
        tabGroupWindowsObservation = tabGroup.observe(
            \.windows,
             options: [.new]
        ) { [weak self] _, _ in
            // NOTE: At one point, I guarded this on only if we went from 0 to N
            // or N to 0 under the assumption that the tab bar would only get
            // replaced on those cases. This turned out to be false (Tahoe).
            // It's cheap enough to always redraw this so we should just do it
            // unconditionally.

            guard let self else { return }
            guard let lastSurfaceConfig else { return }
            self.syncAppearance(lastSurfaceConfig)
        }
    }
}
