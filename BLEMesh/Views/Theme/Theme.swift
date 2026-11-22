import SwiftUI
import UIKit

// Centralized theme tokens for colors, spacing and typography
enum Theme {
    enum Colors {
        static let primary = SwiftUI.Color("AccentColor")
        static let background = SwiftUI.Color(.systemBackground)
        static let card = SwiftUI.Color(.secondarySystemBackground)
        static let accent = SwiftUI.Color("AccentColor")
        static let muted = SwiftUI.Color(.secondaryLabel)

        // Text colours that meet WCAG AA (4.5:1) for small text on the app's light and dark
        // backgrounds. The system's secondary grey, red, orange and green fall short in light mode.
        static let secondaryText = dynamic(light: 0x545458, dark: 0xAEAEB2)
        static let danger = dynamic(light: 0xC0262D, dark: 0xFF6961)
        static let warning = dynamic(light: 0x9A5200, dark: 0xFFB340)
        static let success = dynamic(light: 0x1E7B34, dark: 0x5BD475)
        static let multiHop = dynamic(light: 0x7A3FB8, dark: 0xC99BFF)

        private static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            func ui(_ hex: UInt32) -> UIColor {
                UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
            return SwiftUI.Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
        }
    }

    enum Spacing {
        static let small: CGFloat = 6
        static let base: CGFloat = 12
        static let large: CGFloat = 20
    }

    enum Corner {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(8)
            .background(Theme.Colors.card)
            .cornerRadius(Theme.Corner.medium)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

/// One line when it fits; otherwise the same items stacked, so nothing is truncated
/// (metadata rows stay readable in long languages and at large text sizes).
struct AdaptiveRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: 2) { content }
        }
    }
}

/// Section header text in the app's accessible secondary colour (the system default is below 4.5:1).
struct SectionTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View { Text(title).foregroundStyle(Theme.Colors.secondaryText) }
}

/// A title/value row like `LabeledContent`, with the value in the accessible secondary colour.
struct InfoRow: View {
    let title: LocalizedStringKey
    let value: String
    init(_ title: LocalizedStringKey, value: String) { self.title = title; self.value = value }

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(Theme.Colors.secondaryText)
        } label: {
            Text(title)
        }
    }
}

/// Icon + text that keeps its natural size inside list rows (SwiftUI's `Label` reserves a fixed
/// icon column in lists, which pads and clips short inline labels).
struct InlineLabel: View {
    let title: Text
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) { self.title = Text(title); self.systemImage = systemImage }
    init(_ title: String, systemImage: String) { self.title = Text(verbatim: title); self.systemImage = systemImage }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).accessibilityHidden(true)
            title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
