import SwiftUI

class FullScreenHandler {
    var previousTabGroup: NSWindowTabGroup?
    var previousTabGroupIndex: Int?
    var previousContentFrame: NSRect?
    var isInFullscreen: Bool = false
    
    // We keep track of whether we entered non-native fullscreen in case
    // a user goes to fullscreen, changes the config to disable non-native fullscreen
    // and then wants to toggle it off
    var isInNonNativeFullscreen: Bool = false
    
    func toggleFullscreen(window: NSWindow, nonNativeFullscreen: Bool) {
        if isInFullscreen {
            if nonNativeFullscreen || isInNonNativeFullscreen {
                leaveFullscreen(window: window)
                isInNonNativeFullscreen = false
            } else {
                window.toggleFullScreen(nil)
            }
            isInFullscreen = false
        } else {
            if nonNativeFullscreen {
                enterFullscreen(window: window)
                isInNonNativeFullscreen = true
            } else {
                window.toggleFullScreen(nil)
            }
            isInFullscreen = true
        }
    }
    
    func enterFullscreen(window: NSWindow) {
        guard let screen = window.screen else { return }
        guard let contentView = window.contentView else { return }
        
        previousTabGroup = window.tabGroup
        previousTabGroupIndex = window.tabGroup?.windows.firstIndex(of: window)
        
        // Save previous contentViewFrame and screen
        previousContentFrame = window.convertToScreen(contentView.frame)
        
        // Change presentation style to hide menu bar and dock
        // It's important to do this in two calls, because setting them in a single call guarantees
        // that the menu bar will also be hidden on any additional displays (why? nobody knows!)
        // When these options are set separately, the menu bar hiding problem will only occur in
        // specific scenarios. More invesitgation is needed to pin these scenarios down precisely,
        // but it seems to have something to do with which app had focus last.
        // Furthermore, it's much easier to figure out which screen the dock is on if the menubar
        // has not yet been hidden, so the order matters here!
        if (shouldHideDock(screen: screen)) {
            NSApp.presentationOptions.insert(.autoHideDock)
        }
        NSApp.presentationOptions.insert(.autoHideMenuBar)
        
        // This is important: it gives us the full screen, including the
        // notch area on MacBooks.
        window.styleMask.remove(.titled)
        
        // Set frame to screen size
        window.setFrame(screen.frame, display: true)
        
        // Focus window
        window.makeKeyAndOrderFront(nil)
    }
    
    func leaveFullscreen(window: NSWindow) {
        guard let previousFrame = previousContentFrame else { return }
        
        // Restore title bar
        window.styleMask.insert(.titled)
        
        // Restore previous presentation options
        NSApp.presentationOptions = []
        
        // Restore frame
        window.setFrame(window.frameRect(forContentRect: previousFrame), display: true)
        
        // If the window was previously in a tab group that isn't empty now, we re-add it
        if let group = previousTabGroup, let tabIndex = previousTabGroupIndex, !group.windows.isEmpty {
            var tabWindow: NSWindow?
            var order: NSWindow.OrderingMode = .below
            
            // Index of the window before `window`
            let tabIndexBefore = tabIndex-1
            if tabIndexBefore < 0 {
                // If we were the first tab, we add the window *before* (.below) the first one.
                tabWindow = group.windows.first
            } else if tabIndexBefore < group.windows.count {
                // If we weren't the first tab in the group, we add our window after
                // the tab that was before it.
                tabWindow = group.windows[tabIndexBefore]
                order = .above
            } else {
                // If index is after group, add it after last window
                tabWindow = group.windows.last
            }
            
            // Add the window
            tabWindow?.addTabbedWindow(window, ordered: order)
        }
        
        // Focus window
        window.makeKeyAndOrderFront(nil)
    }
    
    // We only want to hide the dock if it's not already going to be hidden automatically, and if
    // it's on the same display as the ghostty window that we want to make fullscreen.
    func shouldHideDock(screen: NSScreen) -> Bool {
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if (dockAutohide) { return false }
        }

        // There is no public API to directly ask about dock visibility, so we have to figure it out
        // by comparing the sizes of visibleFrame (the currently usable area of the screen) and
        // frame (the full screen size). We also need to account for the menubar, any inset caused
        // by the notch on macbooks, and a little extra padding to compensate for the boundary area
        // which triggers showing the dock.
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        var notchInset = 0.0
        if #available(macOS 12, *) {
            notchInset = screen.safeAreaInsets.top
        }
        let boundaryAreaPadding = 5.0

        return visibleFrame.height < (frame.height - max(menuHeight, notchInset) - boundaryAreaPadding) || visibleFrame.width < frame.width
    }
}
