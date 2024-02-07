import AppKit

extension NSView {
    func firstSubview(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            } else if let found = subview.firstSubview(withClassName: name) {
                return found
            }
        }

        return nil
    }

    func subviews(withClassName name: String) -> [NSView] {
        var result = [NSView]()

        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                result.append(subview)
            }

            result += subview.subviews(withClassName: name)
        }

        return result
    }
}
