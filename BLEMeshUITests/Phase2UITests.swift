import XCTest

/// End-to-end UI flows for Phase 2 (local AI): answers from nearby messages with sources,
/// catch-up, rumour labels, the spam filter, suggested responders, and responder roles.
final class Phase2UITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func any(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", text, text)).firstMatch
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<6 where !element.exists { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "\(element) not found")
        return element
    }

    /// Wait on the Network tab until a scripted broadcast has had time to arrive (the Nearby tab
    /// would mark it read and move the catch-up window).
    private func waitOnNetwork(seconds: TimeInterval) {
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(el("network.peer.Meera").waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - #6 answers from what the mesh heard

    func testLocalQuestionIsAnsweredFromNearbyMessagesWithItsSource() {
        app.launch()
        waitOnNetwork(seconds: 45) // Ravi's "water … community hall" broadcast at ~40 s
        app.tabBars.buttons["Ask"].tap()
        el("ask.text").tap()
        el("ask.text").typeText("Where is water being given out?")
        el("ask.send").tap()
        XCTAssertTrue(any(containing: "community hall").waitForExistence(timeout: 20), "answer didn't quote the nearby message")
        XCTAssertTrue(any(containing: "not verified").exists)
        XCTAssertTrue(any(containing: "Messages nearby").exists, "answer should be labelled by its real source")
        screenshot("p2-01-local-answer")

        el("ask.text").tap()
        el("ask.text").typeText("How much paracetamol can I give my child?")
        el("ask.send").tap()
        XCTAssertTrue(any(containing: "pharmacist").waitForExistence(timeout: 30), "dosing questions must be refused")
        screenshot("p2-02-dose-refused")
    }

    // MARK: - #10 catch-up

    func testCatchUpLeadsWithTheSOS() {
        app.launch()
        waitOnNetwork(seconds: 25) // Meera's SOS ~14 s, Asha's fire report ~22 s
        app.tabBars.buttons["Nearby"].tap()
        el("nearby.catchUp").tap()
        let overview = el("catchup.overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 30))
        XCTAssertTrue(overview.label.contains("SOS"), overview.label)
        let first = el("catchup.highlight")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("trapped under rubble"), "the SOS should be first: \(first.label)")
        XCTAssertTrue(el("catchup.abstract").waitForExistence(timeout: 30), "Ravi's phone should summarise it")
        screenshot("p2-03-catch-up")
        app.buttons["Done"].tap()
        XCTAssertFalse(overview.exists)
    }

    // MARK: - #11 rumour labels

    func testDigestShowsCorroboratedAndSingleReportLabels() {
        app.launch()
        waitOnNetwork(seconds: 33) // fire reported by Asha (~22 s) and Kabir (~30 s)
        app.tabBars.buttons["Nearby"].tap()
        if !el("digest.overview").exists { el("digest.toggle").tap() }
        el("digest.refresh").tap()
        XCTAssertTrue(el("digest.credibility.corroborated").waitForExistence(timeout: 15), "two independent fire reports")
        XCTAssertTrue(el("digest.credibility.unverified").exists, "Meera's SOS is a single report")
        screenshot("p2-04-credibility")
    }

    // MARK: - #12 spam

    func testScamBroadcastIsHiddenAndCanBeShown() {
        app.launchArguments.append("-demoSpam")
        app.launch()
        app.tabBars.buttons["Nearby"].tap()
        let toggle = el("nearby.spamToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "the scam broadcast should be caught")
        XCTAssertFalse(any(containing: "FREE MONEY").exists, "spam must be hidden by default")
        toggle.tap()
        XCTAssertTrue(any(containing: "FREE MONEY").waitForExistence(timeout: 5))
        screenshot("p2-05-spam-shown")
        el("nearby.spamToggle").tap()
        XCTAssertTrue(any(containing: "FREE MONEY").waitForNonExistence(timeout: 5))
    }

    // MARK: - Responder matching and roles

    func testSOSSuggestsNearbyResponders() {
        app.launch()
        app.tabBars.buttons["SOS"].tap()
        let suggestion = el("sos.suggestedResponders")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 30), "Meera's SOS should suggest a nearby rescuer")
        XCTAssertTrue(suggestion.label.contains("Asha (rescuer"), suggestion.label)
        screenshot("p2-06-responders")
    }

    func testResponderRoleTogglesPersist() {
        app.launch()
        app.tabBars.buttons["Chats"].tap()
        el("chats.settings").tap()
        let medic = reveal(el("settings.medic"))
        let autoReply = reveal(el("settings.autoReply"))
        XCTAssertEqual(medic.value as? String, "0")
        XCTAssertEqual(autoReply.value as? String, "1", "auto-reply is on by default")
        if medic.switches.firstMatch.exists { medic.switches.firstMatch.tap() } else { medic.tap() }
        XCTAssertEqual(el("settings.medic").value as? String, "1")
        el("settings.done").tap()
        el("chats.settings").tap()
        XCTAssertEqual(reveal(el("settings.medic")).value as? String, "1")
        screenshot("p2-07-roles")
    }
}
