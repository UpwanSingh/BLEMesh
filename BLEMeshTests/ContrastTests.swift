import Testing
import SwiftUI
import UIKit
@testable import BLEMesh

/// WCAG 2.x contrast of the app's text colours against the backgrounds they're drawn on,
/// in light and dark mode. 4.5:1 is the AA minimum for normal-size text.
@MainActor
@Suite("Colour contrast (WCAG AA)")
struct ContrastTests {
    static func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func ratio(_ a: UIColor, _ b: UIColor) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    static let backgrounds: [(String, UIColor)] = [
        ("systemBackground", .systemBackground),
        ("secondarySystemBackground", .secondarySystemBackground),
        ("systemGroupedBackground", .systemGroupedBackground),
        ("secondarySystemGroupedBackground", .secondarySystemGroupedBackground),
    ]

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func textColoursMeetAAOnEveryBackground(style: UIUserInterfaceStyle) {
        let texts: [(String, Color)] = [
            ("secondaryText", Theme.Colors.secondaryText), ("danger", Theme.Colors.danger),
            ("warning", Theme.Colors.warning), ("success", Theme.Colors.success),
            ("accent", Theme.Colors.accent), ("multiHop", Theme.Colors.multiHop),
        ]
        for (name, color) in texts {
            for (backgroundName, background) in Self.backgrounds {
                let ratio = Self.ratio(Self.resolve(color, style), background.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
                #expect(ratio >= 4.5, "\(name) on \(backgroundName) (\(style == .dark ? "dark" : "light")): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    @Test func whiteTextOnFilledControlsMeetsAA() {
        // Light mode: filled buttons, badges and the outgoing bubble draw white text on these.
        for (name, color) in [("accent", Theme.Colors.accent), ("danger", Theme.Colors.danger),
                              ("warning", Theme.Colors.warning), ("success", Theme.Colors.success),
                              ("secondaryText", Theme.Colors.secondaryText)] {
            let ratio = Self.ratio(.white, Self.resolve(color, .light))
            #expect(ratio >= 4.5, "white on \(name): \(String(format: "%.2f", ratio)):1")
        }
        // The medium-priority badge is black on yellow.
        #expect(Self.ratio(.black, UIColor(Color.yellow).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) >= 4.5)
    }
}
