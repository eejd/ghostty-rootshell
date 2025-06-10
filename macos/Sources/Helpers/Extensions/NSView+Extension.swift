import AppKit

extension NSView {
    /// Returns true if this view is currently in the responder chain
    var isInResponderChain: Bool {
        var responder = window?.firstResponder
        while let currentResponder = responder {
            if currentResponder === self {
                return true
            }
            responder = currentResponder.nextResponder
        }

        return false
    }
}

// MARK: View Traversal and Search

extension NSView {
    /// Returns the absolute root view by walking up the superview chain.
    var rootView: NSView {
        var root: NSView = self
        while let superview = root.superview {
            root = superview
        }
        return root
    }

    /// Recursively finds and returns the first descendant view that has the given class name.
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            } else if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }

        return nil
    }

    /// Recursively finds and returns descendant views that have the given class name.
    func descendants(withClassName name: String) -> [NSView] {
        var result = [NSView]()

        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                result.append(subview)
            }

            result += subview.descendants(withClassName: name)
        }

        return result
    }

	/// Recursively finds and returns the first descendant view that has the given identifier.
	func firstDescendant(withID id: String) -> NSView? {
		for subview in subviews {
			if subview.identifier == NSUserInterfaceItemIdentifier(id) {
				return subview
			} else if let found = subview.firstDescendant(withID: id) {
				return found
			}
		}

		return nil
	}

	/// Finds and returns the first view with the given class name starting from the absolute root of the view hierarchy.
	/// This includes private views like title bar views.
	func firstViewFromRoot(withClassName name: String) -> NSView? {
		let root = rootView
		
		// Check if the root view itself matches
		if String(describing: type(of: root)) == name {
			return root
		}
		
		// Otherwise search descendants
		return root.firstDescendant(withClassName: name)
	}
}
