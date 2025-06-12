import AppKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
class TitlebarTabsTahoeTerminalWindow: TerminalWindow, NSToolbarDelegate {
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

    override func update() {
        super.update()

        if let glass = titlebarContainer?.firstDescendant(withClassName: "NSGlassContainerView") {
            glass.isHidden = true
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
            viewModel.title.isEmpty ? " " : viewModel.title
        }

        var body: some View {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
