import AppKit
import SwiftUI

enum AppTheme {
    static let backgroundTop = adaptiveColor(light: NSColor.white.withAlphaComponent(0.16), dark: NSColor.white.withAlphaComponent(0.05))
    static let backgroundBottom = adaptiveColor(light: NSColor.white.withAlphaComponent(0.04), dark: NSColor.black.withAlphaComponent(0.12))
    static let accent = adaptiveColor(
        light: NSColor(red: 0.34, green: 0.27, blue: 0.52, alpha: 1),
        dark: NSColor(red: 0.66, green: 0.62, blue: 0.78, alpha: 1)
    )
    static let accentActiveBackground = accent.opacity(0.32)
    static let panelFill = adaptiveColor(light: NSColor.white.withAlphaComponent(0.42), dark: NSColor.white.withAlphaComponent(0.08))
    static let panelFillSoft = adaptiveColor(light: NSColor.white.withAlphaComponent(0.26), dark: NSColor.white.withAlphaComponent(0.06))
    static let settingsPanelFill = adaptiveColor(light: NSColor.white.withAlphaComponent(0.18), dark: NSColor.white.withAlphaComponent(0.035))
    static let settingsFieldFill = adaptiveColor(light: NSColor.white.withAlphaComponent(0.32), dark: NSColor.white.withAlphaComponent(0.05))
    static let settingsDivider = adaptiveColor(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.14))
    static let overlaySoft = adaptiveColor(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.black.withAlphaComponent(0.18))
    static let overlayMedium = adaptiveColor(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.black.withAlphaComponent(0.22))
    static let overlayStrong = adaptiveColor(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.black.withAlphaComponent(0.28))
    static let transportFill = adaptiveColor(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.black.withAlphaComponent(0.32))
    static let artworkPlaceholder = adaptiveColor(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.12))
    static let onAccent = Color.black

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum AppCornerRadius {
    static let panel: CGFloat = 16
    static let card: CGFloat = 14
    static let medium: CGFloat = 12
    static let small: CGFloat = 10
    static let compact: CGFloat = 8
}
