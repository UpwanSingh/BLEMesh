import XCTest

/// The watch app on its own (no paired iPhone in the simulator): the SOS needs a 2-second hold,
/// and without a reachable iPhone it's queued, not lost, and the app says so.
final class WatchSOSUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testShortTapDoesNotSendButHoldingDoes() {
        app.launch()
        let sos = el("watch.sos")
        XCTAssertTrue(sos.waitForExistence(timeout: 15))
        sos.tap()
        XCTAssertFalse(el("watch.sosState").waitForExistence(timeout: 2), "a tap must not send an SOS")
        sos.press(forDuration: 2.6)
        let state = el("watch.sosState")
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(state.label.contains("iPhone not reachable") || state.label.contains("Couldn't send"), state.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-sos"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testImSafeReportsItsDelivery() {
        app.launch()
        let safe = el("watch.safe")
        for _ in 0..<3 where !safe.isHittable { app.swipeUp() }
        safe.tap()
        XCTAssertTrue(el("watch.safeState").waitForExistence(timeout: 10))
    }
}
