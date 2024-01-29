//
//  NSColor+Extension.swift
//  Ghostty
//
//  Created by Pete Schaffner on 28/01/2024.
//

import AppKit

extension NSColor {
    var isLightColor: Bool {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
        return luminance > 0.5
    }
}
