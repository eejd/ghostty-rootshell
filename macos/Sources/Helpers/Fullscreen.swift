import Cocoa
import GhosttyKit

/// The fullscreen modes we support define how the fullscreen behaves.
enum FullscreenMode {
    case native
    case nonNative
    case nonNativeVisibleMenu

    /// Initializes the fullscreen style implementation for the mode. This will not toggle any
    /// fullscreen properties. This may fail if the window isn't configured properly for a given
    /// mode.
    func style(for window: NSWindow) -> FullscreenStyle? {
        switch self {
        case .native:
            return NativeFullscreen(window)

        case .nonNative:
            return NonNativeFullscreen(window)

        case  .nonNativeVisibleMenu:
            return NonNativeFullscreenVisibleMenu(window)
        }
    }
}

/// Protocol that must be implemented by all fullscreen styles.
protocol FullscreenStyle {
    var isFullscreen: Bool { get }
    var supportsTabs: Bool { get }
    init?(_ window: NSWindow)
    func enter()
    func exit()
}

/// macOS native fullscreen. This is the typical behavior you get by pressing the green fullscreen
/// button on regular titlebars.
class NativeFullscreen: FullscreenStyle {
    private let window: NSWindow

    var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }
    var supportsTabs: Bool { true }

    required init?(_ window: NSWindow) {
        // TODO: There are many requirements for native fullscreen we should
        // check here such as the stylemask.

        self.window = window
    }

    func enter() {
        guard !isFullscreen else { return }

        // The titlebar separator shows up erroneously in fullscreen if the tab bar
        // is made to appear and then disappear by opening and then closing a tab.
        // We get rid of the separator while in fullscreen to prevent this.
        window.titlebarSeparatorStyle = .none

        // Enter fullscreen
        window.toggleFullScreen(self)
    }

    func exit() {
        guard isFullscreen else { return }

        // Restore titlebar separator style. See enter for explanation.
        window.titlebarSeparatorStyle = .automatic

        window.toggleFullScreen(nil)
    }
}

class NonNativeFullscreen: FullscreenStyle {
    // Non-native fullscreen never supports tabs because tabs require
    // the "titled" style and we don't have it for non-native fullscreen.
    var supportsTabs: Bool { false }

    // isFullscreen is dependent on if we have saved state currently. We
    // could one day try to do fancier stuff like inspecting the window
    // state but there isn't currently a need for it.
    var isFullscreen: Bool { savedState != nil }

    // The default properties. Subclasses can override this to change
    // behavior. This shouldn't be written to (only computed) because
    // it must be immutable.
    var properties: Properties { Properties() }

    struct Properties {
        var hideMenu: Bool = true
    }

    private let window: NSWindow
    private var savedState: SavedState?

    required init?(_ window: NSWindow) {
        self.window = window
    }

    func enter() {
        // If we are in fullscreen we don't do it again.
        guard !isFullscreen else { return }

        // This is the screen that we're going to go fullscreen on. We use the
        // screen the window is currently on.
        guard let screen = window.screen else { return }

        // Save the state that we need to exit again
        guard let savedState = SavedState(window) else { return }
        self.savedState = savedState

        // Change presentation style to hide menu bar and dock if needed
        // It's important to do this in two calls, because setting them in a single call guarantees
        // that the menu bar will also be hidden on any additional displays (why? nobody knows!)
        // When these options are set separately, the menu bar hiding problem will only occur in
        // specific scenarios. More investigation is needed to pin these scenarios down precisely,
        // but it seems to have something to do with which app had focus last.
        // Furthermore, it's much easier to figure out which screen the dock is on if the menubar
        // has not yet been hidden, so the order matters here!

        // We always hide the dock. There are many scenarios where we don't
        // need to (dock is not on this screen, dock is already hidden, etc.)
        // but I don't think there's a downside to just unconditionally doing this.
        hideDock()

        // Hide the dock whenever this window becomes focused.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideDock),
            name: NSWindow.didBecomeMainNotification,
            object: window)

        // Unhide the dock whenever this window becomes unfocused.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(unhideDock),
            name: NSWindow.didResignMainNotification,
            object: window)

        // Hide the menu if requested
        if (properties.hideMenu) {
            self.hideMenu()

            // Ensure that we always hide the menu bar for this window, but not for non fullscreen ones
            // This is not the best way to do this, not least because it causes the menu to stay visible
            // for a brief moment before being hidden in some cases (e.g. when switching spaces).
            // If we end up adding a NSWindowDelegate to PrimaryWindow, then we may be better off
            // handling this there.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(Self.hideMenu),
                name: NSWindow.didBecomeMainNotification,
                object: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignMain),
                name: NSWindow.didResignMainNotification,
                object: window)
        }

        // Being untitled let's our content take up the full frame.
        window.styleMask.remove(.titled)

        // Set frame to screen size, accounting for the menu bar if needed
        window.setFrame(fullscreenFrame(screen), display: true)

        // Focus window
        window.makeKeyAndOrderFront(nil)
    }

    func exit() {
        guard isFullscreen else { return }
        guard let savedState else { return }

        // Reset all of our dock and menu logic
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignMainNotification, object: window)
        unhideDock()
        unhideMenu()

        // Restore our saved state
        window.styleMask = savedState.styleMask
        window.setFrame(window.frameRect(forContentRect: savedState.contentFrame), display: true)

        // This is a hack that I want to remove from this but for now, we need to
        // fix up the titlebar tabs here before we do everything below.
        if let window = window as? TerminalWindow,
           window.titlebarTabs {
            window.titlebarTabs = true
        }

        // If the window was previously in a tab group that isn't empty now,
        // we re-add it. We have to do this because our process of doing non-native
        // fullscreen removes the window from the tab group.
        if let tabGroup = savedState.tabGroup,
           let tabIndex = savedState.tabGroupIndex,
            !tabGroup.windows.isEmpty {
            if tabIndex == 0 {
                // We were previously the first tab. Add it before ("below")
                // the first window in the tab group currently.
                tabGroup.windows.first!.addTabbedWindow(window, ordered: .below)
            } else if tabIndex <= tabGroup.windows.count {
                // We were somewhere in the middle
                tabGroup.windows[tabIndex - 1].addTabbedWindow(window, ordered: .above)
            } else {
                // We were at the end
                tabGroup.windows.last!.addTabbedWindow(window, ordered: .below)
            }
        }

        // Unset our saved state, we're restored!
        self.savedState = nil

        // Focus window
        window.makeKeyAndOrderFront(nil)
    }

    private func fullscreenFrame(_ screen: NSScreen) -> NSRect {
        // It would make more sense to use "visibleFrame" but visibleFrame
        // will omit space by our dock and isn't updated until an event
        // loop tick which we don't have time for. So we use frame and
        // calculate this ourselves.
        var frame = screen.frame

        if (!properties.hideMenu) {
            // We need to subtract the menu height since we're still showing it.
            frame.size.height -= NSApp.mainMenu?.menuBarHeight ?? 0

            // NOTE on macOS bugs: macOS used to have a bug where menuBarHeight
            // didn't account for the notch. I reported this as a radar and it
            // was fixed at some point. I don't know when that was so I can't
            // put an #available check, but it was in a bug fix release so I think
            // if a bug is reported to Ghostty we can just advise the user to
            // update.
        }

        return frame
    }

    // MARK: Dock

    @objc private func hideDock() {
        NSApp.presentationOptions.insert(.autoHideDock)
    }

    @objc private func unhideDock() {
        NSApp.presentationOptions.remove(.autoHideDock)
    }

    // MARK: Menu

    @objc func hideMenu() {
        NSApp.presentationOptions.insert(.autoHideMenuBar)
    }

    func unhideMenu() {
        NSApp.presentationOptions.remove(.autoHideMenuBar)
    }

    @objc func windowDidResignMain(_ notification: Notification) {
        unhideMenu()
    }

    /// The state that must be saved for non-native fullscreen to exit fullscreen.
    class SavedState {
        let tabGroup: NSWindowTabGroup?
        let tabGroupIndex: Int?
        let contentFrame: NSRect
        let styleMask: NSWindow.StyleMask

        init?(_ window: NSWindow) {
            guard let contentView = window.contentView else { return nil }

            self.tabGroup = window.tabGroup
            self.tabGroupIndex = window.tabGroup?.windows.firstIndex(of: window)
            self.contentFrame = window.convertToScreen(contentView.frame)
            self.styleMask = window.styleMask
        }
    }
}

class NonNativeFullscreenVisibleMenu: NonNativeFullscreen {
    override var properties: Properties { Properties(hideMenu: false) }
}
