import XCTest

/// The app in Hindi: tab bar, SOS screen, runtime labels (priority/category/status) and Settings.
final class LocalizationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash", "-AppleLanguages", "(hi)", "-AppleLocale", "hi_IN"]
    }

    private func any(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testAppRunsInHindi() {
        app.launch()
        for tab in ["चैट", "आस-पास", "SOS", "पूछें", "नेटवर्क"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 10), "tab \(tab)")
        }
        app.tabBars.buttons["SOS"].tap()
        XCTAssertTrue(any(containing: "SOS भेजें").waitForExistence(timeout: 5))
        XCTAssertTrue(any(containing: "मैं सुरक्षित हूँ").exists)
        // Meera's SOS (~14 s): runtime labels from MeshCore are translated too.
        XCTAssertTrue(any(containing: "गंभीर").waitForExistence(timeout: 30), "priority label")
        XCTAssertTrue(any(containing: "फँसे हुए").exists, "category label")
        XCTAssertTrue(any(containing: "खुला").exists, "SOS status label")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "hindi-sos"
        shot.lifetime = .keepAlways
        add(shot)

        app.tabBars.buttons["चैट"].tap()
        app.descendants(matching: .any)["chats.settings"].firstMatch.tap()
        XCTAssertTrue(any(containing: "मेरी भाषा").waitForExistence(timeout: 5))
        XCTAssertTrue(any(containing: "सुरक्षा और निजता").exists)
    }
}
