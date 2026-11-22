import XCTest

/// Taps every remaining interactive control that the simulator can drive, checking each one does
/// what it says. Complements the journey tests in BLEMeshUITests.
final class ControlCoverageUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-skipSplash"]
        // Accept system permission prompts (microphone, speech) if they appear.
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].firstMatch.exists {
                alert.buttons[label].firstMatch.tap()
                return true
            }
            return false
        }
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func messageContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message.' AND identifier CONTAINS %@", text)).firstMatch
    }

    private func hideKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let hide = el("composer.hideKeyboard")
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    /// Long-press until the context menu shows `item` (a press can be swallowed while the bubble re-lays out).
    private func openMenu(on element: XCUIElement, expecting item: String) {
        for _ in 0..<3 {
            element.press(forDuration: 1.2)
            if app.buttons[item].waitForExistence(timeout: 3) { return }
            app.tap()
        }
        XCTFail("context menu with \(item) never appeared")
    }

    /// Scroll the current form/list until `element` is loaded (forms create rows lazily).
    @discardableResult
    private func reveal(_ element: XCUIElement, up: Bool = true) -> XCUIElement {
        for _ in 0..<6 where !element.exists {
            up ? app.swipeUp() : app.swipeDown()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "\(element) not found")
        return element
    }

    private func waitForMesh() {
        app.tabBars.buttons["Network"].tap()
        XCTAssertTrue(el("network.peer.Meera").waitForExistence(timeout: 20))
    }

    private func openChat(with name: String) {
        app.tabBars.buttons["Chats"].tap()
        el("chats.newChat").tap()
        let peer = el("peer.\(name)")
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        peer.tap()
    }

    private func send(_ text: String) {
        let field = el("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        el("composer.send").tap()
        XCTAssertTrue(messageContaining(text).waitForExistence(timeout: 5))
    }

    // MARK: - Onboarding

    func testOnboardingSkip() {
        app.launchArguments += ["-showOnboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5))
    }

    // MARK: - Chats list

    func testEmptyStateNewChatButtonRowNavigationAndSwipeDelete() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Chats"].tap()
        // Empty-state button opens the picker.
        let newChat = app.buttons["New Chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(el("peer.Kabir").waitForExistence(timeout: 10))
        el("peer.Kabir").tap()
        send("row test")
        app.navigationBars.buttons["BackButton"].tap() // back to list

        // Row navigation.
        let row = el("conversation.Kabir")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(messageContaining("row test").waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()

        // Swipe to delete (swipe the list cell, not the inner label).
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let cell = app.cells.containing(.any, identifier: "conversation.Kabir").firstMatch
        cell.swipeLeft()
        let delete = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    func testPeerPickerCancelAndGroupSheetCancel() {
        app.launch()
        app.tabBars.buttons["Chats"].tap()
        el("chats.newChat").tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        el("chats.newGroup").tap()
        let create = el("group.create")
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "Create must be disabled without a name and members")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(el("chats.newChat").waitForExistence(timeout: 5))
    }

    // MARK: - Conversation

    func testConversationInfoShowsSafetyNumbers() {
        app.launch()
        waitForMesh()
        openChat(with: "Asha")
        el("conversation.info").tap()
        let theirs = el("info.theirSafetyNumber")
        XCTAssertTrue(theirs.waitForExistence(timeout: 5))
        XCTAssertEqual(theirs.label.split(separator: " ").count, 6)
        app.buttons["Done"].tap()
        XCTAssertTrue(el("composer.text").waitForExistence(timeout: 5))
    }

    func testLeaveGroupFromInfoSheet() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Chats"].tap()
        el("chats.newGroup").tap()
        el("group.name").tap()
        el("group.name").typeText("Temp group")
        el("groupMember.Asha").tap()
        el("group.create").tap()
        XCTAssertTrue(el("conversation.info").waitForExistence(timeout: 5))
        el("conversation.info").tap()
        XCTAssertTrue(app.staticTexts["Members"].waitForExistence(timeout: 5))
        app.buttons["Leave group"].tap()
        app.buttons["Leave"].firstMatch.tap()
        // Back on the list, and the group is gone.
        XCTAssertTrue(el("conversation.Temp group").waitForNonExistence(timeout: 5))
    }

    func testMessageContextMenuCopyReadAloudTranslate() {
        app.launch()
        waitForMesh()
        openChat(with: "Asha")
        send("hello context menu")
        hideKeyboard()
        let bubble = messageContaining("hello context menu")
        bubble.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 3))
        app.buttons["Copy"].tap()
        // The test runner may not read the pasteboard; paste inside the app instead.
        let field = el("composer.text")
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].firstMatch.exists ? app.menuItems["Paste"].firstMatch : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertEqual(field.value as? String, "hello context menu")
        hideKeyboard()

        bubble.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 3))
        app.buttons["Read aloud"].tap()

        openMenu(on: bubble, expecting: "Translate")
        app.buttons["Translate"].tap()
        // Same language as the target: the app says so instead of calling the translator.
        XCTAssertTrue(app.staticTexts["Already in your language"].waitForExistence(timeout: 10))
        openMenu(on: bubble, expecting: "Hide translation")
        app.buttons["Hide translation"].tap()
        XCTAssertTrue(app.staticTexts["Already in your language"].waitForNonExistence(timeout: 5))
    }

    func testMicHoldDoesNotSendEmptyVoiceNotes() {
        app.launch()
        waitForMesh()
        openChat(with: "Kabir")
        let mic = el("composer.mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.press(forDuration: 2.5)
        app.tap() // trigger the interruption monitor if a permission alert appeared
        mic.press(forDuration: 2.5)
        // No speech in the simulator: nothing must be sent, and the app stays usable.
        XCTAssertFalse(messageContaining("🎙").exists)
        XCTAssertTrue(el("composer.text").exists)
    }

    // MARK: - Nearby

    func testVoiceNotePlaybackAndDigestCollapse() {
        app.launch()
        app.tabBars.buttons["Nearby"].tap()
        let voice = messageContaining("Road is blocked near the old bridge")
        XCTAssertTrue(voice.waitForExistence(timeout: 15), "scripted voice note never arrived")
        let play = app.buttons["Play voice note"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.buttons["Stop"].firstMatch.waitForExistence(timeout: 5), "playback didn't start")
        app.buttons["Stop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play voice note"].firstMatch.waitForExistence(timeout: 5))

        let toggle = el("digest.toggle")
        el("digest.refresh").tap()
        XCTAssertTrue(el("digest.overview").waitForExistence(timeout: 20))
        toggle.tap()
        XCTAssertTrue(el("digest.overview").waitForNonExistence(timeout: 3))
        toggle.tap()
        XCTAssertTrue(el("digest.overview").waitForExistence(timeout: 3))
    }

    // MARK: - SOS

    func testSOSQuickPicksLocationToggleAndReply() {
        app.launch()
        app.tabBars.buttons["SOS"].tap()
        // A scripted SOS from Meera arrives; reply opens a direct chat with her.
        let row = el("sos.row")
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        let reply = app.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        XCTAssertTrue(el("composer.text").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Meera"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()

        el("sos.compose").tap()
        XCTAssertFalse(el("sos.send").isEnabled, "Send must be disabled until text is entered")
        app.buttons["Fire"].tap()
        let text = el("sos.text")
        XCTAssertEqual(text.value as? String, "Fire")
        let gps = app.switches["Include my GPS location"]
        XCTAssertTrue(gps.exists)
        gps.switches.firstMatch.tap()
        XCTAssertEqual(gps.value as? String, "0")
        XCTAssertTrue(el("sos.send").isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(el("sos.compose").waitForExistence(timeout: 5))
    }

    // MARK: - Ask

    func testAskSuggestionButton() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Ask"].tap()
        let suggestion = app.buttons["What should I do in a flood?"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        let answer = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'message.🤖' AND NOT (identifier CONTAINS 'Asked')")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
    }

    // MARK: - Network

    func testNetworkPullToRefresh() {
        app.launch()
        waitForMesh()
        let list = app.collectionViews.firstMatch
        list.swipeDown()
        XCTAssertTrue(el("network.peer.Asha").waitForExistence(timeout: 5))
        XCTAssertEqual(el("network.links").label.contains("2"), true)
    }

    // MARK: - Settings

    func testSettingsControls() {
        app.launch()
        waitForMesh()
        app.tabBars.buttons["Chats"].tap()
        el("chats.settings").tap()

        // Rename → visible on the Network tab after Done.
        let name = el("settings.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText(XCUIKeyboardKey.delete.rawValue)
        name.typeText("Field Medic\n") // submit: renames and dismisses the keyboard

        // Toggles flip.
        for label in ["Auto-translate incoming messages", "Read voice notes aloud on arrival", "Message & SOS alerts"] {
            let toggle = reveal(app.switches[label])
            let before = toggle.value as? String
            toggle.switches.firstMatch.tap()
            XCTAssertNotEqual(toggle.value as? String, before, "\(label) didn't change")
        }

        // Pickers open and select (picker buttons are labelled "Title, current value").
        let language = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'My language'")).firstMatch
        for _ in 0..<6 where !(language.exists && language.isHittable) { app.swipeDown() }
        XCTAssertTrue(language.waitForExistence(timeout: 3))
        language.tap()
        XCTAssertTrue(app.buttons["Español"].waitForExistence(timeout: 3))
        app.buttons["Español"].tap()
        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keep messages'")).firstMatch).tap()
        XCTAssertTrue(app.buttons["7 days"].waitForExistence(timeout: 3))
        app.buttons["7 days"].tap()

        // Demo range buttons (scroll: the form loads rows lazily).
        reveal(el("demo.leave")).tap()
        XCTAssertTrue(el("demo.return").waitForExistence(timeout: 3))
        el("demo.return").tap()

        // Replay introduction opens and closes.
        reveal(app.buttons["Replay introduction"]).tap()
        XCTAssertTrue(app.staticTexts["Welcome to BLE Mesh"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()

        // Reset settings restores defaults.
        reveal(app.buttons["Reset settings"]).tap()
        app.buttons["Reset"].firstMatch.tap()
        XCTAssertEqual(reveal(app.switches["Auto-translate incoming messages"], up: false).value as? String, "0")

        el("settings.done").tap()
        app.tabBars.buttons["Network"].tap()
        let renamed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Field Medic'")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), "rename didn't apply")
    }
}
