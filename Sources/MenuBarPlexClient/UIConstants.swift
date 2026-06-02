import AppKit
import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.10, green: 0.11, blue: 0.07)
    static let backgroundBottom = Color(red: 0.08, green: 0.09, blue: 0.06)
    static let accent = Color(red: 0.97, green: 0.88, blue: 0.29)
    static let accentActiveBackground = accent.opacity(0.32)
    static let panelFill = Color.white.opacity(0.08)
    static let panelFillSoft = Color.white.opacity(0.06)
    static let settingsPanelFill = Color.white.opacity(0.035)
    static let settingsFieldFill = Color.white.opacity(0.05)
    static let settingsDivider = Color.white.opacity(0.14)
    static let overlaySoft = Color.black.opacity(0.14)
    static let overlayMedium = Color.black.opacity(0.16)
    static let overlayStrong = Color.black.opacity(0.18)
    static let transportFill = Color.black.opacity(0.26)
    static let panelBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
}

enum AppCornerRadius {
    static let panel: CGFloat = 16
    static let card: CGFloat = 14
    static let medium: CGFloat = 12
    static let small: CGFloat = 10
    static let compact: CGFloat = 8
}
