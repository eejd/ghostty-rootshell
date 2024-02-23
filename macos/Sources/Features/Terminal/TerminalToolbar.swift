import Cocoa

// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.
class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    private let titleTextField = CenteredDynamicLabel(labelWithString: "👻 Ghostty")
    
    var titleText: String {
        get {
            titleTextField.stringValue
        }
        
        set {
            titleTextField.stringValue = newValue
        }
    }

    var hasTitle: Bool = false

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        
        delegate = self
        
        if #available(macOS 13.0, *) {
            centeredItemIdentifiers.insert(.titleText)
        } else {
            centeredItemIdentifier = .titleText
        }
    }
    
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem

        switch itemIdentifier {
        case .titleText:
            item = NSToolbarItem(itemIdentifier: .titleText)
            item.view = self.titleTextField
            item.visibilityPriority = .user

            // NSToolbarItem.minSize and NSToolbarItem.maxSize are deprecated, and make big ugly
            // warnings in Xcode when you use them, but I cannot for the life of me figure out
            // how to get this to work with constraints. The behavior isn't the same, instead of
            // shrinking the item and clipping the subview, it hides the item as soon as the
            // intrinsic size of the subview gets too big for the toolbar width, regardless of
            // whether I have constraints set on its width, height, or both :/
            //
            // If someone can fix this so we don't have to use deprecated properties: Please do.
            item.minSize = NSSize(width: 32, height: 1)
            item.maxSize = NSSize(width: 1024, height: self.titleTextField.intrinsicContentSize.height)

            item.isEnabled = true
        case .unZoom:
            item = NSToolbarItem(itemIdentifier: .unZoom)

            let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 20).isActive = true
            view.heightAnchor.constraint(equalToConstant: 20).isActive = true
            
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left.square.fill", accessibilityDescription: nil)!, target: nil, action: #selector(TerminalController.splitZoom(_:)))

            button.frame = view.bounds
            button.isBordered = false
            button.contentTintColor = .systemBlue
            button.state = .on
            button.imageScaling = .scaleProportionallyUpOrDown
            view.addSubview(button)

            item.view = view
        default:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        return item
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.titleText, .flexibleSpace, .space, .unZoom]
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, two of the
        // built-in spacers plus the un-zoom button item seems to exactly match the space
        // on the left that's reserved for the window buttons.
        if hasTitle {
            return [.titleText, .flexibleSpace, .space, .space, .unZoom]
        } else {
            return [.flexibleSpace, .unZoom]
        }
    }
}

/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
fileprivate class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Truncate the title when it gets too long, cutting it off with an ellipsis.
        cell?.truncatesLastVisibleLine = true
        cell?.lineBreakMode = .byCharWrapping
        
        // Make the text field as small as possible while fitting its text.
        setContentHuggingPriority(.required, for: .horizontal)
        cell?.alignment = .center
        
        // We've changed some alignment settings, make sure the layout is updated immediately.
        needsLayout = true
    }
}

extension NSToolbarItem.Identifier {
    static let unZoom = NSToolbarItem.Identifier("UnZoom")
    static let titleText = NSToolbarItem.Identifier("TitleText")
}
