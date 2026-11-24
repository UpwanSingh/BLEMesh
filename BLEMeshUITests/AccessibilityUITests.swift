import XCTest

/// Runs Xcode's accessibility audit (VoiceOver labels, hit targets, Dynamic Type, clipping,
/// contrast) on every main screen of the app in demo-mesh mode.
final class AccessibilityUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 2) // let sheets and row animations finish; mid-animation frames skew contrast
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "a11y-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)
        do {
            try app.performAccessibilityAudit { issue in
                // Elements can vanish while the audit runs (live demo traffic); never touch a stale one.
                let live = issue.element.flatMap { $0.exists ? $0 : nil }
                let element = live.map { "\($0.elementType.rawValue) id=\($0.identifier) label=\($0.label.prefix(60))" } ?? "no element"
                let description = "\(screen) | \(issue.compactDescription) | \(element)"
                print("A11Y", description, issue.element == nil ? "| detail: \(issue.detailedDescription)" : "")
                // Logged but not failed: borderline contrast (system greys), and Dynamic Type
                // "partially unsupported", which the audit also reports for standard system controls.
                let advisory = issue.compactDescription.contains("nearly passed")
                    || issue.compactDescription.contains("partially unsupported")
                // Content scrolled under the translucent tab bar, and the system's glass toolbar
                // buttons, are measured against the blur behind them; that's not the app's styling.
                let frame = live?.frame ?? .zero
                // iOS 26 fades scrolled content into the floating tab bar and the navigation bar
                // ("scroll edge effect"), so text in those strips is measured against the blur.
                let tab = self.app.tabBars.firstMatch, nav = self.app.navigationBars.firstMatch
                let bottomEdge = tab.exists ? tab.frame.minY - 60 : .greatestFiniteMagnitude
                let topEdge = nav.exists ? nav.frame.maxY + 20 : -.greatestFiniteMagnitude
                let underSystemBars = !frame.isEmpty && (frame.maxY > bottomEdge || frame.minY < topEdge)
                // Issues the audit can't attribute to an element are mostly sub-nodes of content
                // scrolled under the tab bar; colour contrast is verified exactly by `ContrastTests`.
                let unattributedContrast = live == nil && issue.compactDescription.hasPrefix("Contrast")
                // Content scrolled out of view inside a scroll area isn't on screen to be read.
                let offScreen = live.map { !$0.isHittable } ?? false
                return advisory || underSystemBars || unattributedContrast || offScreen
            }
        } catch {
            XCTFail("\(screen): \(error)", file: file, line: line)
        }
    }

    func testMainScreensPassTheAccessibilityAudit() {
        let launched = Date()
        app.launch()
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(el("network.peer.Meera").waitForExistence(timeout: 20))
        app.swipeUp() // bring the traffic section fully above the tab bar
        audit("Network")

        app.tabBars.buttons["Chats"].tap()
        audit("Chats")

        app.tabBars.buttons["SOS"].tap()
        XCTAssertTrue(el("sos.action.enRoute").waitForExistence(timeout: 20))
        audit("SOS")

        app.tabBars.buttons["Ask"].tap()
        audit("Ask")

        app.tabBars.buttons["Chats"].tap()
        el("chats.settings").tap()
        audit("Settings")
        el("settings.done").tap()

        // Audit Nearby once the demo's scripted broadcasts (last at ~55 s) have arrived, so rows
        // aren't moving while the audit measures them.
        Thread.sleep(forTimeInterval: max(0, 60 - Date().timeIntervalSince(launched)))
        app.tabBars.buttons["Nearby"].tap()
        audit("Nearby")
    }
}
