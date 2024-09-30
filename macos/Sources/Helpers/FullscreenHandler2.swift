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

        case .nonNative, .nonNativeVisibleMenu:
            return nil
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
