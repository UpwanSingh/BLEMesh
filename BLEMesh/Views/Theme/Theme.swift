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

/// Lays children out left to right and wraps onto new lines instead of truncating them
/// (metadata rows stay readable at large text sizes).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                // Items that fit get their ideal size (no truncation); only an item wider than the row wraps.
                let fits = subviews[index].sizeThatFits(.unspecified).width <= bounds.width
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                                      proposal: fits ? .unspecified : .init(width: bounds.width, height: nil))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.items.isEmpty }
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
