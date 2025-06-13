import AppKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
///
/// This inherits from transparent styling so that the titlebar matches the background color
/// of the window.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    override func awakeFromNib() {
        super.awakeFromNib()

        // We must hide the title since we're going to be moving tabs into
        // the titlebar which have their own title.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers.insert(.title)
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }
    // MARK: NSWindow

    override var title: String {
        didSet {
            viewModel.title = title
        }
    }

    override var toolbar: NSToolbar? {
        didSet{
            guard toolbar != nil else { return }

            // When a toolbar is added, remove the Liquid Glass look because we're
            // abusing the toolbar as a tab bar.
            if let glass = titlebarContainer?.firstDescendant(withClassName: "NSGlassContainerView") {
                glass.isHidden = true
            }
        }
    }

    override func becomeMain() {
        super.becomeMain()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
            self.contentView?.printViewHierarchy()
        }
    }

    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        // If this is the tab bar then we need to set it up for the titlebar
        guard isTabBar(childViewController) else {
            super.addTitlebarAccessoryViewController(childViewController)
            return
        }

        // Some setup needs to happen BEFORE it is added, such as layout. If
        // we don't do this before the call below, we'll trigger an AppKit
        // assertion.
        childViewController.layoutAttribute = .right

        super.addTitlebarAccessoryViewController(childViewController)

        // View model updates must happen on their own ticks
        DispatchQueue.main.async {
            self.viewModel.hasTabBar = true
        }

        // Setup the tab bar to go into the titlebar.
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            let accessoryView = childViewController.view
            guard let clipView = accessoryView.firstSuperview(withClassName: "NSTitlebarAccessoryClipView") else { return }
            guard let titlebarView = clipView.firstSuperview(withClassName: "NSTitlebarView") else { return }
            guard let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView") else { return }

            // The container is the view that we'll constrain our tab bar within.
            let container = toolbarView

            // The padding for the tab bar. If we're showing window buttons then
            // we need to offset the window buttons.
            let leftPadding: CGFloat = switch(self.derivedConfig.macosWindowButtons) {
            case .hidden: 0
            case .visible: 70
            }

            // Constrain the accessory clip view (the parent of the accessory view
            // usually that clips the children) to the container view.
            clipView.translatesAutoresizingMaskIntoConstraints = false
            clipView.leftAnchor.constraint(equalTo: container.leftAnchor, constant: leftPadding).isActive = true
            clipView.rightAnchor.constraint(equalTo: container.rightAnchor).isActive = true
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2).isActive = true
            clipView.heightAnchor.constraint(equalTo: container.heightAnchor).isActive = true
            clipView.needsLayout = true

            // Constrain the actual accessory view (the tab bar) to the clip view
            // so it takes up the full space.
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.leftAnchor.constraint(equalTo: clipView.leftAnchor).isActive = true
            accessoryView.rightAnchor.constraint(equalTo: clipView.rightAnchor).isActive = true
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor).isActive = true
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor).isActive = true
            accessoryView.needsLayout = true
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        guard let childViewController = titlebarAccessoryViewControllers[safe: index],
                isTabBar(childViewController) else {
            super.removeTitlebarAccessoryViewController(at: index)
            return
        }

        super.removeTitlebarAccessoryViewController(at: index)

        // View model needs to be updated on another tick because it
        // triggers view updates.
        DispatchQueue.main.async {
            self.viewModel.hasTabBar = false
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.title, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace, .title, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .title:
            let item = NSToolbarItem(itemIdentifier: .title)
            item.view = NSHostingView(rootView: TitleItem(viewModel: viewModel))
            item.visibilityPriority = .user
            item.isEnabled = true
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    // MARK: SwiftUI

    class ViewModel: ObservableObject {
        @Published var title: String = "👻 Ghostty"
        @Published var hasTabBar: Bool = false
    }
}

extension NSToolbarItem.Identifier {
    /// Displays the title of the window
    static let title = NSToolbarItem.Identifier("Title")
}

extension TitlebarTabsTahoeTerminalWindow {
    /// Displays the window title
    struct TitleItem: View {
        @ObservedObject var viewModel: ViewModel

        var title: String {
            // An empty title makes this view zero-sized and NSToolbar on macOS
            // tahoe just deletes the item when that happens. So we use a space
            // instead to ensure there's always some size.
            return viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            if !viewModel.hasTabBar {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // 1x1.gif strikes again! For real: if we render a zero-sized
                // view here then the toolbar just disappears our view. I don't
                // know.
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}
