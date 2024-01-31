import Cocoa

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
class WindowDragView: NSView {
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

let TabBarController = NSUserInterfaceItemIdentifier("_tabBarController")

class TerminalWindow: NSWindow {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
	
	// Used by the window controller to enable/disable titlebar tabs.
	public var titlebarTabs = false
	
	override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
		var isTabBar = false
		if (self.titlebarTabs && (
			childViewController.layoutAttribute == .bottom ||
			childViewController.identifier == TabBarController)
		) {
			// Ensure it has the right layoutAttribute
			childViewController.layoutAttribute = .right
			// Hide the title text if the tab bar is showing.
			titleVisibility = .hidden
			// Mark the controller for future reference (it gets re-used sometimes)
			childViewController.identifier = TabBarController
			isTabBar = true
		}
		super.addTitlebarAccessoryViewController(childViewController)
		if (isTabBar) {
			pushTabsToTitlebar(childViewController)
		}
	}
	
	override func removeTitlebarAccessoryViewController(at index: Int) {
		let childViewController = titlebarAccessoryViewControllers[index]
		super.removeTitlebarAccessoryViewController(at: index)
		if (childViewController.layoutAttribute == .right) {
			hideCustomTabBarViews()
		}
	}
	
	// This is a hack - provide a function for the window controller to call in windowDidBecomeKey
	// to check if it's no longer tabbed and fix its appearing if so. This is required because the
	// removeTitlebarAccessoryViewControlle hook does not catch the creation of a new window by
	// "tearing off" a tab from a tabbed window.
	public func fixUntabbedWindow() {
		if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
			hideCustomTabBarViews()
		}
	}
	
	// Assign a background color to the titlebar area.
	public func setTitlebarBackground(_ color: CGColor) {
		guard let titlebarContainer = contentView?.superview?.subviews.first(where: {
			$0.className == "NSTitlebarContainerView"
		}) else { return }
		
		titlebarContainer.wantsLayer = true
		titlebarContainer.layer?.backgroundColor = color
	}
	
	private var windowButtonsBackdrop: NSView? = nil
	
	private func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
		guard windowButtonsBackdrop == nil else { return }
		
		windowButtonsBackdrop = NSView()
		
		guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
		
		windowButtonsBackdrop.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
		titlebarView.addSubview(windowButtonsBackdrop)
		windowButtonsBackdrop.translatesAutoresizingMaskIntoConstraints = false
		windowButtonsBackdrop.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
		windowButtonsBackdrop.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 80).isActive = true
		windowButtonsBackdrop.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
		windowButtonsBackdrop.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
		windowButtonsBackdrop.wantsLayer = true
		windowButtonsBackdrop.layer?.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.45)
		
		let topBorder = NSView()
		windowButtonsBackdrop.addSubview(topBorder)
		topBorder.translatesAutoresizingMaskIntoConstraints = false
		topBorder.leftAnchor.constraint(equalTo: windowButtonsBackdrop.leftAnchor).isActive = true
		topBorder.rightAnchor.constraint(equalTo: windowButtonsBackdrop.rightAnchor).isActive = true
		topBorder.topAnchor.constraint(equalTo: windowButtonsBackdrop.topAnchor).isActive = true
		topBorder.bottomAnchor.constraint(equalTo: windowButtonsBackdrop.topAnchor, constant: 1).isActive = true
		topBorder.wantsLayer = true
		topBorder.layer?.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.85)
	}
	
	var windowDragHandle: WindowDragView? = nil
	
	private func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
		guard windowDragHandle == nil else { return }
		
		windowDragHandle = WindowDragView()
		
		guard let windowDragHandle = windowDragHandle else { return }
		
		windowDragHandle.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
		titlebarView.superview?.addSubview(windowDragHandle)
		windowDragHandle.translatesAutoresizingMaskIntoConstraints = false
		windowDragHandle.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
		windowDragHandle.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
		windowDragHandle.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
		windowDragHandle.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
	}
	
	// To be called immediately after the tab bar is disabled.
	public func hideCustomTabBarViews() {
		// Hide the window buttons backdrop.
		windowButtonsBackdrop?.isHidden = true
		// Hide the window drag handle.
		windowDragHandle?.isHidden = true
		// Enable the window title text.
		titleVisibility = .visible
	}
	
	private func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
		let accessoryView = tabBarController.view
		guard let accessoryClipView = accessoryView.superview else { return }
		guard let titlebarView = accessoryClipView.superview else { return }
		
		guard titlebarView.className == "NSTitlebarView" else { return }
		
		guard let toolbarView = titlebarView.subviews.first(where: {
			$0.className == "NSToolbarView"
		}) else { return }
		
		addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
		windowButtonsBackdrop?.isHidden = false
		guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
		
		addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)
		windowDragHandle?.isHidden = false
		
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
