import SwiftUI

// Centralized theme tokens for colors, spacing and typography
enum Theme {
    enum Colors {
        static let primary = SwiftUI.Color("AccentColor")
        static let background = SwiftUI.Color(.systemBackground)
        static let card = SwiftUI.Color(.secondarySystemBackground)
        static let accent = SwiftUI.Color.blue
        static let success = SwiftUI.Color.green
        static let muted = SwiftUI.Color(.secondaryLabel)
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
