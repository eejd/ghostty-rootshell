import Cocoa

// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.
class TerminalToolbar: NSToolbar, NSToolbarDelegate {
	static private let identifier = NSToolbarItem.Identifier("TitleText")
	private let titleTextField = NSTextField(labelWithString: "👻 Ghostty")
    
    var titleText: String {
        get {
            titleTextField.stringValue
        }
        
        set {
            titleTextField.stringValue = newValue
        }
    }
	
	override init(identifier: NSToolbar.Identifier) {
		super.init(identifier: identifier)
        
		delegate = self
        
		if #available(macOS 13.0, *) {
			centeredItemIdentifiers.insert(Self.identifier)
		} else {
			centeredItemIdentifier = Self.identifier
		}
	}
	
	func toolbar(_ toolbar: NSToolbar, 
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, 
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		guard itemIdentifier == Self.identifier else { return nil }
		
		let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
		toolbarItem.isEnabled = true
		toolbarItem.view = self.titleTextField
		return toolbarItem
	}
	
	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [Self.identifier]
	}
	
	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [Self.identifier]
	}
}
