import AppKit
import SwiftUI

enum DashboardDesignTokens {
    static let brand = Color(nsColor: .controlAccentColor)
    static let safe = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.00, green: 0.34, blue: 0.13, alpha: 1),
        dark: NSColor.systemGreen)
    static let caution = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.48, green: 0.20, blue: 0.00, alpha: 1),
        dark: NSColor.systemOrange)
    static let error = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.62, green: 0.08, blue: 0.05, alpha: 1),
        dark: NSColor.systemRed)
    static let cached = DashboardDesignTokens.caution
    static let safeText = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.00, green: 0.24, blue: 0.08, alpha: 1),
        dark: NSColor(calibratedRed: 0.76, green: 1.00, blue: 0.78, alpha: 1))
    static let cautionText = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.48, green: 0.20, blue: 0.00, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.93, blue: 0.82, alpha: 1))
    static let errorText = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedRed: 0.62, green: 0.08, blue: 0.05, alpha: 1),
        dark: NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.76, alpha: 1))
    static let cachedText = DashboardDesignTokens.cautionText
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = DashboardDesignTokens.adaptive(
        light: NSColor(calibratedWhite: 0.28, alpha: 1),
        dark: NSColor(calibratedWhite: 0.88, alpha: 1))
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let track = Color(nsColor: .separatorColor).opacity(0.35)

    static func contentSurface(_ accessibility: DashboardDisplayAccessibility) -> Color {
        Color(nsColor: .controlBackgroundColor)
            .opacity(accessibility.increaseContrast ? 0.72 : 0.46)
    }

    static func runwaySurface(_ accessibility: DashboardDisplayAccessibility) -> Color {
        Color(nsColor: .selectedContentBackgroundColor)
            .opacity(accessibility.increaseContrast ? 0.24 : 0.13)
    }

    static func subtleSurface(_ accessibility: DashboardDisplayAccessibility) -> Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(accessibility.increaseContrast ? 0.66 : 0.30)
    }

    static func divider(_ accessibility: DashboardDisplayAccessibility) -> Color {
        Color(nsColor: .separatorColor).opacity(accessibility.increaseContrast ? 0.95 : 0.55)
    }

    static func border(_ accessibility: DashboardDisplayAccessibility) -> Color {
        Color(nsColor: .separatorColor).opacity(accessibility.increaseContrast ? 1 : 0.62)
    }

    static let radius: CGFloat = 8
    static let compactRadius: CGFloat = 6
    static let horizontalInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 16

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
