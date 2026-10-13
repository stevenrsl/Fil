import AppKit
import SwiftUI

enum Palette {
    static let ground = adaptive(light: (0.92, 0.94, 0.97), dark: (0.07, 0.10, 0.15))
    static let groundSunk = adaptive(light: (0.86, 0.90, 0.95), dark: (0.05, 0.08, 0.12))
    static let surface = adaptive(light: (0.98, 0.99, 1.00), dark: (0.11, 0.15, 0.21))
    static let ink = adaptive(light: (0.11, 0.15, 0.21), dark: (0.92, 0.95, 1.00))
    static let inkSoft = adaptive(light: (0.33, 0.39, 0.48), dark: (0.73, 0.78, 0.87))
    static let inkFaint = adaptive(light: (0.43, 0.49, 0.59), dark: (0.62, 0.69, 0.79))
    static let hairline = adaptive(light: (0.78, 0.83, 0.91), dark: (0.20, 0.27, 0.38))
    static let accent = adaptive(light: (0.67, 0.79, 0.94), dark: (0.51, 0.68, 0.90))
    static let accentWash = adaptive(light: (0.85, 0.91, 0.98), dark: (0.15, 0.22, 0.33))
    static let onAccent = adaptive(light: (0.10, 0.20, 0.36), dark: (0.07, 0.13, 0.24))
    static let accentInk = adaptive(light: (0.22, 0.40, 0.70), dark: (0.61, 0.80, 1.00))
    static let alert = adaptive(light: (0.60, 0.27, 0.23), dark: (0.93, 0.58, 0.52))
    static let alertWash = adaptive(light: (0.97, 0.91, 0.89), dark: (0.24, 0.13, 0.13))
    /// Pour le seul avertissement « non chiffré » : ni alarme, ni accent.
    static let caution = adaptive(light: (0.55, 0.42, 0.16), dark: (0.90, 0.76, 0.45))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: values.0, green: values.1, blue: values.2, alpha: 1)
        })
    }
}
