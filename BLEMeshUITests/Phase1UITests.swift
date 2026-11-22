import XCTest

/// End-to-end UI flows for Phase 1: SOS status, check-ins & family locator, safety-check answers,
/// medical ID, contact verification, blocking/reporting, and removing group members.
final class Phase1UITests: XCTestCase {
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

    private func waitForMesh() {
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(el("network.peer.Meera").waitForExistence(timeout: 20))
    }

    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<6 where !element.exists { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "\(element) not found")
        return element
    }

    private func createGroup(_ name: String, members: [String]) {
        app.tabBars.buttons["Chats"].tap()
        el("chats.newGroup").tap()
        XCTAssertTrue(el("group.name").waitForExistence(timeout: 5))
        el("group.name").tap()
        el("group.name").typeText(name)
        for member in members { el("groupMember.\(member)").tap() }
        el("group.create").tap()
        XCTAssertTrue(el("conversation.info").waitForExistence(timeout: 5))
    }

    // MARK: - SOS status

    func testMySOSShowsResponderAndICanMarkMyselfSafe() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["SOS"].tap()
        el("sos.compose").tap()
        el("sos.text").tap()
        el("sos.text").typeText("Stuck in the lift at the mall")
        el("sos.send").tap()
        XCTAssertTrue(el("sos.sent").waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(el("sos.status.Help on the way").waitForExistence(timeout: 15), "responder status never showed")
        XCTAssertTrue(any(containing: "Coming from the market").waitForExistence(timeout: 5))
        screenshot("p1-01-sos-responder")
        el("sos.action.resolve").tap()
        XCTAssertTrue(el("sos.status.Resolved").waitForExistence(timeout: 5))
        XCTAssertFalse(el("sos.action.resolve").exists, "actions should disappear once resolved")
    }

    func testRespondingToSomeoneElsesSOS() {
        app.launch()
        app.tabBars.buttons["SOS"].tap()
        let onMyWay = el("sos.action.enRoute")
        XCTAssertTrue(onMyWay.waitForExistence(timeout: 30), "Meera's scripted SOS never arrived")
        XCTAssertTrue(el("sos.newDevice").exists, "brand-new identities should be flagged on SOS")
        onMyWay.tap()
        XCTAssertTrue(el("sos.status.Help on the way").waitForExistence(timeout: 5))
        XCTAssertTrue(any(containing: "Tester: Help on the way").waitForExistence(timeout: 5))
        screenshot("p1-02-sos-responding")
    }

    // MARK: - Check-ins and family locator

    func testCheckInsAndFamilyLocator() {
        app.launch()
        waitForMesh()
        // No groups yet: the app says so instead of pretending.
        app.tabBars.buttons["SOS"].tap()
        el("checkin.safe").tap()
        XCTAssertTrue(any(containing: "not in any group").waitForExistence(timeout: 5))

        createGroup("Family", members: ["Asha", "Meera"])
        XCTAssertTrue(any(containing: "Hi everyone, Meera here").waitForExistence(timeout: 20))
        el("conversation.info").tap()
        el("info.askSafe").tap()
        XCTAssertTrue(any(containing: "Asked everyone").waitForExistence(timeout: 3))
        el("info.locator").tap()
        XCTAssertTrue(el("locator.needHelp").waitForExistence(timeout: 15), "Meera's 'need help' never arrived")
        XCTAssertTrue(any(containing: "Twisted ankle").exists)
        XCTAssertTrue(el("locator.safe").waitForExistence(timeout: 10))
        screenshot("p1-03-family-locator")
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to Details
        app.buttons["Done"].firstMatch.tap()

        // Check in from the SOS tab.
        app.tabBars.buttons["SOS"].tap()
        el("checkin.safe").tap()
        XCTAssertTrue(any(containing: "Sent to 1 group").waitForExistence(timeout: 10))
        XCTAssertTrue(el("checkin.locator.Family").exists)
    }

    func testAnsweringASafetyCheckInAGroupChat() {
        app.launch()
        waitForMesh()
        createGroup("Neighbours", members: ["Kabir"])
        let safe = el("safety.answer.safe")
        XCTAssertTrue(safe.waitForExistence(timeout: 20), "Kabir's 'are you safe?' never arrived")
        screenshot("p1-04-safety-check")
        safe.tap()
        XCTAssertTrue(any(containing: "You answered").waitForExistence(timeout: 5))
        XCTAssertTrue(any(containing: "I'm safe").waitForExistence(timeout: 5))
    }

    // MARK: - Medical ID

    func testMedicalIDIsAttachedToSOSWhenChosen() {
        app.launch()
        app.tabBars.buttons["Chats"].tap()
        el("chats.settings").tap()
        reveal(el("settings.medicalID")).tap()
        let blood = el("medical.bloodType")
        XCTAssertTrue(blood.waitForExistence(timeout: 5))
        blood.tap()
        blood.typeText("O+")
        el("medical.allergies").tap()
        el("medical.allergies").typeText("penicillin")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        el("settings.done").tap()

        app.tabBars.buttons["SOS"].tap()
        el("sos.compose").tap()
        el("sos.text").tap()
        el("sos.text").typeText("Allergic reaction, can't breathe well")
        let attach = app.switches["Attach my medical ID"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.switches.firstMatch.tap()
        el("sos.send").tap()
        XCTAssertTrue(el("sos.sent").waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(any(containing: "Blood type: O+").waitForExistence(timeout: 5))
        XCTAssertTrue(any(containing: "Allergies: penicillin").exists)
        screenshot("p1-05-sos-medical")
    }

    // MARK: - Verification, blocking, reporting

    func testVerificationRejectsWrongCodes() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Chats"].tap()
        el("chats.newChat").tap()
        el("peer.Asha").tap()
        el("conversation.info").tap()
        el("info.verify").tap()
        let myCode = el("verify.myCode")
        XCTAssertTrue(myCode.waitForExistence(timeout: 5))
        XCTAssertTrue(myCode.label.hasPrefix("blemesh:v1:"))
        screenshot("p1-06-verify")
        // Pasting my own code is not Asha's → rejected.
        let field = el("verify.manualCode")
        field.tap()
        field.typeText(myCode.label)
        el("verify.check").tap()
        XCTAssertTrue(el("verify.mismatch").waitForExistence(timeout: 3))
        // Garbage → not a code.
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue + "not a code")
        el("verify.check").tap()
        XCTAssertTrue(el("verify.invalid").waitForExistence(timeout: 3))
        XCTAssertFalse(el("verify.success").exists)
    }

    func testBlockingHidesTheirMessagesAndReportingWorks() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Chats"].tap()
        el("chats.newChat").tap()
        el("peer.Asha").tap()
        el("conversation.info").tap()
        el("info.block").tap()
        XCTAssertEqual(el("info.block").label, "Unblock")
        app.buttons["Done"].tap()
        let field = el("composer.text")
        field.tap()
        field.typeText("are you there?")
        el("composer.send").tap()
        // Asha replies over the mesh, but a blocked device's messages never appear.
        sleep(4)
        XCTAssertFalse(any(containing: "Asha got it").exists)
        XCTAssertFalse(any(containing: "Hi! Asha here").exists)

        el("conversation.info").tap()
        el("info.report").tap()
        app.buttons["Report and block"].firstMatch.tap()
        app.buttons["Done"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        el("chats.settings").tap()
        reveal(el("settings.blocked")).tap()
        XCTAssertTrue(any(containing: "Reported").waitForExistence(timeout: 5))
        app.buttons["Unblock"].firstMatch.tap()
        XCTAssertTrue(any(containing: "haven't blocked anyone").waitForExistence(timeout: 5))
    }

    // MARK: - Group admin

    func testAdminRemovesAMember() {
        app.launch()
        waitForMesh()
        createGroup("Team", members: ["Asha", "Kabir"])
        el("conversation.info").tap()
        let remove = el("info.remove.Asha")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(el("info.remove.Asha").waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(any(containing: "You removed Asha").waitForExistence(timeout: 5))
        screenshot("p1-07-removed-member")
    }
}
