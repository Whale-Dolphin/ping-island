import AppKit
import SwiftUI

extension Color {
    // Unlike a snapshot of NSApp.effectiveAppearance, dynamic colors also
    // honor a window's explicit light/dark choice and the docked dark boundary.
    static func islandAdaptive(light: Color, dark: Color) -> Color {
        let lightColor = NSColor(light)
        let darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? darkColor : lightColor
        })
    }

    static let islandForeground = islandAdaptive(light: .black, dark: .white)
    static let islandSurface = islandAdaptive(light: .white, dark: .black)
}
