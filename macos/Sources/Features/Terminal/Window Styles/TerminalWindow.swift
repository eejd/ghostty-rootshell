import AppKit
import SwiftUI
import GhosttyKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig?

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    // MARK: NSWindow Overrides

    override func awakeFromNib() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // All new windows are based on the app config at the time of creation.
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)

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

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable.
        let stackView = NSStackView(views: [keyEquivalentLabel, resetZoomTabButton])
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 3
        tab.accessoryView = stackView

        // Get our saved level
        level = UserDefaults.standard.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func becomeKey() {
        super.becomeKey()
        resetZoomTabButton.contentTintColor = .controlAccentColor
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs (issue #1902)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    // MARK: Tab Key Equivalents

    // TODO: rename once Legacy window removes
    var keyEquivalent2: String? = nil {
        didSet {
            // When our key equivalent is set, we must update the tab label.
            guard let keyEquivalent2 else {
                keyEquivalentLabel.attributedStringValue = NSAttributedString()
                return
            }

            keyEquivalentLabel.attributedStringValue = NSAttributedString(
                string: "\(keyEquivalent2) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
        }
    }

    /// The label that has the key equivalent for tab views.
    private lazy var keyEquivalentLabel: NSTextField = {
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
        label.postsFrameChangedNotifications = true
        return label
    }()

    // MARK: Surface Zoom

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            // Show/hide our reset zoom button depending on if we're zoomed.
            // We want to show it if we are zoomed.
            resetZoomTabButton.isHidden = !surfaceIsZoomed
        }
    }

    private lazy var resetZoomTabButton: NSButton = generateResetZoomButton()

    private func generateResetZoomButton() -> NSButton {
        let button = NSButton()
        button.isHidden = true
        button.target = terminalController
        button.action = #selector(TerminalController.splitZoom(_:))
        button.isBordered = false
        button.allowsExpansionToolTips = true
        button.toolTip = "Reset Zoom"
        button.contentTintColor = .controlAccentColor
        button.state = .on
        button.image = NSImage(named:"ResetZoom")
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    // MARK: Title Text

    override var title: String {
        didSet {
            // Whenever we change the window title we must also update our
            // tab title if we're using custom fonts.
            tab.attributedTitle = attributedTitle
        }
    }

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
            tab.attributedTitle = attributedTitle
        }
    }

    // Find the NSTextField responsible for displaying the titlebar's title.
    private var titlebarTextField: NSTextField? {
        titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")?
            .firstDescendant(withClassName: "NSTextField") as? NSTextField
    }

    // Return a styled representation of our title property.
    var attributedTitle: NSAttributedString? {
        guard let titlebarFont = titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: Positioning And Styling

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else { return }

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        if !styleMask.contains(.fullScreen) &&
            surfaceConfig.backgroundOpacity < 1
        {
            isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            backgroundColor = .white.withAlphaComponent(0.001)

            if let appDelegate = NSApp.delegate as? AppDelegate {
                ghostty_set_window_background_blur(
                    appDelegate.ghostty.app,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        } else {
            isOpaque = true

            let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
            self.backgroundColor = backgroundColor.withAlphaComponent(1)
        }
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let terminalController, !terminalController.surfaceTree.isEmpty {
            // If our focused surface borders the top then we prefer its background color
            if let focusedSurface = terminalController.focusedSurface,
               let treeRoot = terminalController.surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode),
               let backgroundcolor = focusedSurface.backgroundColor {
                let alpha = focusedSurface.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
                return NSColor(backgroundcolor).withAlphaComponent(alpha)
            }

            // Doesn't border the top or we don't have a focused surface, so
            // we try to match the top-left surface.
            let topLeftSurface = terminalController.surfaceTree.root?.leftmostLeaf()
            if let topLeftBgColor = topLeftSurface?.backgroundColor {
                let alpha = topLeftSurface?.derivedConfig.backgroundOpacity.clamped(to: 0.001...1) ?? 1
                return NSColor(topLeftBgColor).withAlphaComponent(alpha)
            }
        }

        let alpha = derivedConfig?.backgroundOpacity.clamped(to: 0.001...1) ?? 1
        return derivedConfig?.backgroundColor.withAlphaComponent(alpha)
    }

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

    // MARK: Config

    struct DerivedConfig {
        let backgroundColor: NSColor
        let backgroundOpacity: Double

        init() {
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
        }
    }
}
