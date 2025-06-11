import AppKit

/// A terminal window style that provides a transparent titlebar effect. With this effect, the titlebar
/// matches the background color of the window.
class TransparentTitlebarTerminalWindow: TerminalWindow {
    /// Stores the last surface configuration to reapply appearance when needed.
    /// This is necessary because various macOS operations (tab switching, tab bar
    /// visibility changes) can reset the titlebar appearance.
    private var lastSurfaceConfig: Ghostty.SurfaceView.DerivedConfig?
    
    /// KVO observation for tab group window changes.
    private var tabGroupWindowsObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?

    override func awakeFromNib() {
        super.awakeFromNib()

        // Setup all the KVO we will use, see the docs for the respective functions
        // to learn why we need KVO.
        setupKVO()
    }
    
    deinit {
        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
    }

    override func becomeMain() {
        super.becomeMain()
        
        guard let lastSurfaceConfig else { return }
        syncAppearance(lastSurfaceConfig)

        // This is a nasty edge case. If we're going from 2 to 1 tab and the tab bar
        // automatically disappears, then we need to resync our appearance because
        // at some point macOS replaces the tab views.
        if tabGroup?.windows.count ?? 0 == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.syncAppearance(self?.lastSurfaceConfig ?? lastSurfaceConfig)
            }
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Save our config in case we need to reapply
        lastSurfaceConfig = surfaceConfig

        // Everytime we change appearance, set KVO up again in case any of our
        // references changed (e.g. tabGroup is new).
        setupKVO()

        if #available(macOS 26.0, *) {
            syncAppearanceTahoe(surfaceConfig)
        } else {
            syncAppearanceVentura(surfaceConfig)
        }
    }

    @available(macOS 26.0, *)
    private func syncAppearanceTahoe(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // When we have transparency, we need to set the titlebar background to match the
        // window background but with opacity. The window background is set using the
        // "preferred background color" property.
        //
        // As an inverse, if we don't have transparency, we don't bother with this because
        // the window background will be set to the correct color so we can just hide the
        // titlebar completely and we're good to go.
        if !isOpaque {
            if let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") {
                titlebarView.wantsLayer = true
                titlebarView.layer?.backgroundColor = preferredBackgroundColor?.cgColor
            }
        }

        // In all cases, we have to hide the background view since this has multiple subviews
        // that force a background color.
        titlebarBackgroundView?.isHidden = true
    }

    @available(macOS 13.0, *)
    private func syncAppearanceVentura(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        guard let titlebarContainer else { return }
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = preferredBackgroundColor?.cgColor
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

    private func setupKVO() {
        // See the docs for the respective setup functions for why.
        setupTabGroupObservation()
        setupTabBarVisibleObservation()
    }

    /// Monitors the tabGroup windows value for any changes and resyncs the appearance on change.
    /// This is necessary because when the windows change, the tab bar and titlebar are recreated
    /// which breaks our changes.
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
        ) { [weak self] _, change in
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

    /// Monitors the tab bar for visibility. This lets the "Show/Hide Tab Bar" manual menu item
    /// to not break our appearance.
    private func setupTabBarVisibleObservation() {
        // Remove existing observation if any
        tabBarVisibleObservation?.invalidate()
        tabBarVisibleObservation = nil
        
        // Set up KVO observation for isTabBarVisible
        tabBarVisibleObservation = tabGroup?.observe(
            \.isTabBarVisible,
             options: [.new]
        ) { [weak self] _, change in
            guard let self else { return }
            guard let lastSurfaceConfig else { return }
            self.syncAppearance(lastSurfaceConfig)
        }
    }
}
