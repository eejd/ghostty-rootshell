import Foundation

extension OSColor {
    var isLightColor: Bool {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
        return luminance > 0.5
    }

    func darken(by amount: CGFloat) -> OSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return OSColor(hue: h, saturation: s, brightness: min(b * (1 - amount), 1), alpha: a)
    }
}
