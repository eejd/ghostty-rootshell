import Cocoa

class TerminalWindow: NSWindow {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
    
    // MARK: - NSWindow
    
    override func becomeKey() {
        // This is required because the removeTitlebarAccessoryViewControlle hook does not
        // catch the creation of a new window by "tearing off" a tab from a tabbed window.
        if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
            hideCustomTabBarViews()
        }
        
        super.becomeKey()
    }
    
    // MARK: - Titlebar Tabs
    
    // Used by the window controller to enable/disable titlebar tabs.
    var titlebarTabs = false {
        didSet {
            changedTitlebarTabs(to: titlebarTabs)
        }
    }
    
    private var windowButtonsBackdrop: NSView? = nil
    private var windowDragHandle: WindowDragView? = nil
    private var storedTitlebarBackgroundColor: CGColor? = nil
    
    // The tab bar controller ID from macOS
    static private let TabBarController = NSUserInterfaceItemIdentifier("_tabBarController")

    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()

        guard let titlebarContainer = contentView?.superview?.firstSubview(withClassName: "NSTitlebarContainerView") else {
            return
        }

        for v in titlebarContainer.subviews(withClassName: "NSTitlebarSeparatorView") {
            v.isHidden = true
        }
    }

    /// This is called by titlebarTabs changing so that we can setup the rest of our window
    private func changedTitlebarTabs(to newValue: Bool) {
        self.titlebarAppearsTransparent = newValue
        
        if (newValue) {
            // We use the toolbar to anchor our tab bar positions in the titlebar,
            // so we make sure it's the right size/position, and exists.
            self.toolbarStyle = .unifiedCompact
            if (self.toolbar == nil) {
                self.toolbar = TerminalToolbar(identifier: "Toolbar")
            }
            
            // Set a custom background on the titlebar - this is required for when
            // titlebar tabs is used in conjunction with a transparent background.
            self.restoreTitlebarBackground()
            
            // We have to wait before setting the titleVisibility or else it prevents
            // the window from hiding the tab bar when we get down to a single tab.
            DispatchQueue.main.async {
                self.titleVisibility = .hidden
            }
        } else {
            // "expanded" places the toolbar below the titlebar, so setting this style and
            // removing the toolbar ensures that the titlebar will be the default height.
            self.toolbarStyle = .expanded
            self.toolbar = nil
            
            // Reset the appearance to whatever our app global value is
            self.appearance = nil
        }
    }
    
    // Assign a background color to the titlebar area.
    func setTitlebarBackground(_ color: CGColor) {
        storedTitlebarBackgroundColor = color
        
        guard let titlebarContainer = contentView?.superview?.firstSubview(withClassName: "NSTitlebarContainerView") else {
            return
        }

        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = color
    }
    
    // Make sure the titlebar has the assigned background color.
    private func restoreTitlebarBackground() {
        guard let color = storedTitlebarBackgroundColor else { return }
        setTitlebarBackground(color)
    }
    
    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let isTabBar = self.titlebarTabs && (
            childViewController.layoutAttribute == .bottom ||
            childViewController.identifier == Self.TabBarController
        )
        
        if (isTabBar) {
            // Ensure it has the right layoutAttribute to force it next to our titlebar
            childViewController.layoutAttribute = .right
            
            // If we don't set titleVisibility to hidden here, the toolbar will display a
            // "collapsed items" indicator which interferes with the tab bar.
            titleVisibility = .hidden
            
            // Mark the controller for future reference so we can easily find it. Otherwise
            // the tab bar has no ID by default.
            childViewController.identifier = Self.TabBarController
        }
        
        super.addTitlebarAccessoryViewController(childViewController)
        
        if (isTabBar) {
            pushTabsToTitlebar(childViewController)
        }
    }
    
    override func removeTitlebarAccessoryViewController(at index: Int) {
        let isTabBar = titlebarAccessoryViewControllers[index].identifier == Self.TabBarController
        super.removeTitlebarAccessoryViewController(at: index)
        if (isTabBar) {
            hideCustomTabBarViews()
        }
    }
    
    // To be called immediately after the tab bar is disabled.
    private func hideCustomTabBarViews() {
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true
        
        // Hide the window drag handle.
        windowDragHandle?.isHidden = true
    }
    
    private func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
        let accessoryView = tabBarController.view
        guard let accessoryClipView = accessoryView.superview else { return }
        guard let titlebarView = accessoryClipView.superview else { return }
        guard titlebarView.className == "NSTitlebarView" else { return }

        guard let toolbarView = titlebarView.firstSubview(withClassName: "NSToolbarView") else {
            return
        }
        
        addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
        guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
        
        addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)
        
        accessoryClipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryClipView.leftAnchor.constraint(equalTo: windowButtonsBackdrop.rightAnchor).isActive = true
        accessoryClipView.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        accessoryClipView.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        accessoryClipView.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
        accessoryClipView.needsLayout = true
        
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.leftAnchor.constraint(equalTo: accessoryClipView.leftAnchor).isActive = true
        accessoryView.rightAnchor.constraint(equalTo: accessoryClipView.rightAnchor).isActive = true
        accessoryView.topAnchor.constraint(equalTo: accessoryClipView.topAnchor).isActive = true
        accessoryView.heightAnchor.constraint(equalTo: accessoryClipView.heightAnchor).isActive = true
        accessoryView.needsLayout = true
        
        // This is a horrible hack. During the transition while things are resizing to make room for
        // new tabs or expand existing tabs to fill the empty space after one is closed, the centering
        // of the tab titles can't be properly calculated, so we wait for 0.2 seconds and then mark
        // the entire view hierarchy for the tab bar as dirty to fix the positioning...
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.markHierarchyForLayout(accessoryView)
        }
    }
    
    private func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        if let view = windowButtonsBackdrop {
            view.removeFromSuperview()
            view.isHidden = false
            titlebarView.addSubview(view)
            view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
            view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 80).isActive = true
            view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
            return
        }
        
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
        titlebarView.addSubview(view)
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 80).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
        view.wantsLayer = true
        
        // This is jank but this makes the background color for light themes on the button
        // backdrop look MUCH better. I couldn't figure out a perfect color to use that works
        // for both so we just check the appearance.
        if effectiveAppearance.name == .aqua {
            view.layer?.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.95, alpha: 1)
        } else {
            view.layer?.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.45)
        }
        
        windowButtonsBackdrop = view
    }
    
    private func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        if let view = windowDragHandle {
            view.removeFromSuperview()
            view.isHidden = false
            titlebarView.superview?.addSubview(view)
            view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
            view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
            view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
            return
        }
        
        let view = WindowDragView()
        view.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
        titlebarView.superview?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
        
        windowDragHandle = view
    }
    
    // This forces this view and all subviews to update layout and redraw. This is
    // a hack (see the caller).
    private func markHierarchyForLayout(_ view: NSView) {
        view.needsUpdateConstraints = true
        view.needsLayout = true
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        for subview in view.subviews {
            markHierarchyForLayout(subview)
        }
    }
}

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
fileprivate class WindowDragView: NSView {
    override public func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if (event.type == .leftMouseDown && event.clickCount == 1) {
            window?.performDrag(with: event)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }
    
    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.disableCursorRects()
        NSCursor.openHand.set()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        window?.enableCursorRects()
        NSCursor.arrow.set()
    }
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
