import XCTest

/// End-to-end UI tests. The app runs in demo mode (simulated neighbours Asha, Kabir, Ravi, Meera)
/// with an in-memory store, so every flow is exercised exactly as a user would, without radios.
final class BLEMeshUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The keyboard covers the tab bar; hide it with the composer's keyboard button.
    private func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let hide = element("composer.hideKeyboard")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "keyboard didn't hide")
    }

    private func waitForPeers() {
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(element("network.peer.Meera").waitForExistence(timeout: 20), "mesh didn't converge")
    }

    func testOnboardingLeadsToMainApp() {
        launch(["-showOnboarding"])
        XCTAssertTrue(app.staticTexts["Welcome to BLE Mesh"].waitForExistence(timeout: 5))
        screenshot("01-onboarding")
        for _ in 0..<4 { app.buttons["Continue"].tap() }
        XCTAssertTrue(app.staticTexts["Help when it matters"].waitForExistence(timeout: 3))
        app.buttons["Get Started"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5))
    }

    func testDirectChatIsDeliveredReadAndAnswered() {
        launch()
        waitForPeers()
        screenshot("02-network")
        app.tabBars.buttons["Chats"].tap()
        element("chats.newChat").tap()
        let asha = element("peer.Asha")
        XCTAssertTrue(asha.waitForExistence(timeout: 10))
        screenshot("03-peer-picker")
        asha.tap()

        let field = element("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("hello from the test")
        element("composer.send").tap()

        XCTAssertTrue(element("message.hello from the test").waitForExistence(timeout: 5))
        XCTAssertTrue(element("status.read").waitForExistence(timeout: 15), "read receipt never arrived")
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message.Hi! Asha here'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "no reply from Asha")
        screenshot("04-direct-chat")
    }

    func testMultiHopChatToMeera() {
        launch()
        waitForPeers()
        app.tabBars.buttons["Chats"].tap()
        element("chats.newChat").tap()
        element("peer.Meera").tap()
        let field = element("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("where are you")
        element("composer.send").tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS 'community hall'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "no multi-hop reply from Meera")
        screenshot("05-multihop-chat")
    }

    func testCreateGroupAndReceiveGroupMessages() {
        launch()
        waitForPeers()
        app.tabBars.buttons["Chats"].tap()
        element("chats.newGroup").tap()
        let name = element("group.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Rescue team")
        element("groupMember.Asha").tap()
        element("groupMember.Kabir").tap()
        screenshot("06-new-group")
        element("group.create").tap()
        let hello = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message.Hi everyone'")).firstMatch
        XCTAssertTrue(hello.waitForExistence(timeout: 20), "group members never posted")
        screenshot("07-group-chat")
    }

    func testSOSIsTriagedAndShownOnTheBoard() {
        launch()
        app.tabBars.buttons["SOS"].tap()
        element("sos.compose").tap()
        let text = element("sos.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Man unconscious and not breathing near the bus stand")
        XCTAssertTrue(element("priority.Critical").waitForExistence(timeout: 10), "triage preview missing")
        screenshot("08-sos-compose")
        element("sos.send").tap()
        XCTAssertTrue(element("sos.sent").waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(element("sos.row").waitForExistence(timeout: 5))
        screenshot("09-sos-board")
    }

    func testNearbyBroadcastAndAreaDigest() {
        launch()
        app.tabBars.buttons["Nearby"].tap()
        let field = element("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Fire near the market, avoid Main Road")
        element("composer.send").tap()
        XCTAssertTrue(element("message.Fire near the market, avoid Main Road").waitForExistence(timeout: 5))
        element("digest.refresh").tap()
        XCTAssertTrue(element("digest.overview").waitForExistence(timeout: 20))
        screenshot("10-nearby-digest")
    }

    func testAskTheMesh() {
        launch()
        waitForPeers()
        app.tabBars.buttons["Ask"].tap()
        let field = element("ask.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("How do I treat a burn?")
        element("ask.send").tap()
        // Answered by this simulator's on-device model if available, otherwise by Ravi over the mesh.
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message.🤖' AND NOT (identifier CONTAINS 'Asked')")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60), "no answer")
        screenshot("11-ask-the-mesh")
    }

    func testSettingsShowSafetyNumberAndPanicWipe() {
        launch()
        app.tabBars.buttons["Nearby"].tap()
        let field = element("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("to be wiped")
        element("composer.send").tap()
        XCTAssertTrue(element("message.to be wiped").waitForExistence(timeout: 5))
        dismissKeyboard()

        app.tabBars.buttons["Chats"].tap()
        element("chats.settings").tap()
        let safety = element("settings.safetyNumber")
        XCTAssertTrue(safety.waitForExistence(timeout: 5))
        let before = safety.label
        screenshot("12-settings")
        app.swipeUp()
        element("settings.panicWipe").tap()
        app.buttons["Erase now"].firstMatch.tap()

        app.tabBars.buttons["Nearby"].tap()
        XCTAssertFalse(element("message.to be wiped").waitForExistence(timeout: 2))
        dismissKeyboard()
        app.tabBars.buttons["Chats"].tap()
        element("chats.settings").tap()
        XCTAssertTrue(element("settings.safetyNumber").waitForExistence(timeout: 5))
        XCTAssertNotEqual(element("settings.safetyNumber").label, before, "identity was not rotated")
    }
}
