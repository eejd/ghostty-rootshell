// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.

import Foundation
import Cocoa
import SwiftUI

class TerminalToolbar: NSToolbar, NSToolbarDelegate {
	static private let TitleIdentifier = NSToolbarItem.Identifier("TitleText")
	private let TitleTextField = NSTextField(
		labelWithString: "👻 Ghostty"
	)
	
	func setTitleText(_ text: String) {
		self.TitleTextField.stringValue = text
	}
	
	override init(identifier: NSToolbar.Identifier) {
		super.init(identifier: identifier)
		delegate = self
		if #available(macOS 13.0, *) {
			centeredItemIdentifiers.insert(Self.TitleIdentifier)
		} else {
			centeredItemIdentifier = Self.TitleIdentifier
		}
	}
	
	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		guard itemIdentifier == Self.TitleIdentifier else { return nil }
		
		let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
		toolbarItem.isEnabled = true
		toolbarItem.view = self.TitleTextField
		return toolbarItem
	}
	
	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [Self.TitleIdentifier]
	}
	
	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [Self.TitleIdentifier]
	}
}
