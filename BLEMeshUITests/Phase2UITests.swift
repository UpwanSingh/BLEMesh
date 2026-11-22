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
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "\(element) not found")
        return element
    }

    /// Tap a text field until the keyboard is up (a slow simulator can drop the first tap).
    private func focus(_ field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) { return }
        }
        XCTFail("keyboard never appeared for \(field)")
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
        focus(el("ask.text"))
        el("ask.text").typeText("Where is water being given out?")
        el("ask.send").tap()
        XCTAssertTrue(any(containing: "community hall").waitForExistence(timeout: 20), "answer didn't quote the nearby message")
        XCTAssertTrue(any(containing: "not verified").exists)
        XCTAssertTrue(any(containing: "Messages nearby").exists, "answer should be labelled by its real source")
        screenshot("p2-01-local-answer")

        focus(el("ask.text"))
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
        let autoReply = app.switches.matching(NSPredicate(format: "label == %@", "Auto-reply to “are you safe?” after 5 min")).firstMatch
        XCTAssertEqual(reveal(autoReply).value as? String, "1", "auto-reply is on by default")
        // The form loads rows lazily: look the medic row up again after scrolling.
        let medic = app.switches.matching(NSPredicate(format: "label == %@", "I'm a medic (doctor, nurse, first-aider)")).firstMatch
        XCTAssertEqual(reveal(medic).value as? String, "0")
        medic.switches.firstMatch.tap()
        let on = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: reveal(medic))
        wait(for: [on], timeout: 10)
        el("settings.done").tap()
        el("chats.settings").tap()
        XCTAssertEqual(reveal(app.switches.matching(NSPredicate(format: "label == %@", "I'm a medic (doctor, nurse, first-aider)")).firstMatch).value as? String, "1")
        screenshot("p2-07-roles")
    }
}

/// Phase 3: offline directions and the SOS map.
final class SOSMapUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testSOSShowsDirectionsAndMap() {
        app.launch()
        app.tabBars.buttons["SOS"].tap()
        // Meera's SOS (~14 s) carries GPS; the demo phone stands ~290 m south-west of it.
        let directions = el("sos.directions")
        XCTAssertTrue(directions.waitForExistence(timeout: 30))
        XCTAssertTrue(directions.label.contains("290 m NE"), directions.label)
        app.segmentedControls.buttons["Map"].tap()
        XCTAssertTrue(el("sosmap.pin").waitForExistence(timeout: 10), "SOS pin on the map")
        XCTAssertTrue(el("sosmap.pin").label.contains("Meera"), el("sosmap.pin").label)
        XCTAssertTrue(el("sosmap.me").exists, "this phone on the map")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "p3-sos-map"
        shot.lifetime = .keepAlways
        add(shot)
        app.segmentedControls.buttons["List"].tap()
        XCTAssertTrue(el("sos.directions").waitForExistence(timeout: 5))
    }
}

/// Phase 3: QR invite codes.
final class GroupInviteUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testAdminShowsInviteCodeAndSomeoneJoins() {
        app.launch()
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(el("network.peer.Meera").waitForExistence(timeout: 20))
        app.tabBars.buttons["Chats"].tap()
        el("chats.newGroup").tap()
        el("group.name").tap()
        el("group.name").typeText("Family")
        el("groupMember.Asha").tap()
        el("group.create").tap()
        el("conversation.info").tap()
        let invite = el("info.invite")
        for _ in 0..<4 where !invite.exists { app.swipeUp() }
        invite.tap()
        let code = el("invite.code")
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertTrue(code.label.hasPrefix("blemesh:join:v1:"), code.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "p3-invite-qr"
        shot.lifetime = .keepAlways
        add(shot)
        el("invite.demoScan").tap()
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Meera joined with the invite code'"))
            .firstMatch.waitForExistence(timeout: 20))
    }

    func testJoinScreenRejectsGarbage() {
        app.launch()
        app.tabBars.buttons["Chats"].tap()
        el("chats.join").tap()
        el("join.code").tap()
        el("join.code").typeText("not a code")
        el("join.submit").tap()
        XCTAssertTrue(el("join.invalid").waitForExistence(timeout: 5))
    }
}
