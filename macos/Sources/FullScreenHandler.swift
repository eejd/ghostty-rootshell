import SwiftUI

class FullScreenHandler {
    var previousTabGroup: NSWindowTabGroup?
    var previousTabGroupIndex: Int?
    var previousContentFrame: NSRect?
    var previousStyleMask: NSWindow.StyleMask?
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
        
        // Save previous style mask
        previousStyleMask = window.styleMask
        // Save previous contentViewFrame and screen
        previousContentFrame = window.convertToScreen(contentView.frame)
        
        // Change presentation style to hide menu bar and dock
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        // Turn it into borderless window
        window.styleMask.insert(.borderless)
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
        guard let previousStyleMask = previousStyleMask else { return }
        
        // Restore previous style
        window.styleMask = previousStyleMask
        
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
}
