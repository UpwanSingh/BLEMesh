import SwiftUI

// Centralized theme tokens for colors, spacing and typography
enum Theme {
    enum Color {
        static let primary = Color("AccentColor")
        static let background = Color(.systemBackground)
        static let card = Color(.secondarySystemBackground)
        static let accent = Color.blue
        static let success = Color.green
        static let muted = Color(.secondaryLabel)
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
            .background(Theme.Color.card)
            .cornerRadius(Theme.Corner.medium)
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}
