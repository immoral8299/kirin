import AppKit
import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let backgroundBottom = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let accent = Color(red: 0.66, green: 0.62, blue: 0.78)
    static let accentActiveBackground = accent.opacity(0.32)
    static let panelFill = Color.white.opacity(0.08)
    static let panelFillSoft = Color.white.opacity(0.06)
    static let settingsPanelFill = Color.white.opacity(0.035)
    static let settingsFieldFill = Color.white.opacity(0.05)
    static let settingsDivider = Color.white.opacity(0.14)
    static let overlaySoft = Color.black.opacity(0.18)
    static let overlayMedium = Color.black.opacity(0.22)
    static let overlayStrong = Color.black.opacity(0.28)
    static let transportFill = Color.black.opacity(0.32)
    static let panelBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
}

enum AppCornerRadius {
    static let panel: CGFloat = 16
    static let card: CGFloat = 14
    static let medium: CGFloat = 12
    static let small: CGFloat = 10
    static let compact: CGFloat = 8
}
