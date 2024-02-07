import AppKit

extension NSView {

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
