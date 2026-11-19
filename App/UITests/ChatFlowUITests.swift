import XCTest

/// End-to-end UI flows against the DEBUG demo backend (`LLM_UI_DEMO`), in the simulator.
/// Run with `scripts/test-ui.sh`.
final class ChatFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LLM_UI_DEMO"] = scene
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    /// First run: confirm the download (size + source shown), the model loads, a suggested
    /// prompt streams a reply with the live readout, and the finished reply shows its stats.
    @MainActor
    func testFirstRunDownloadThenChat() throws {
        let app = launch(scene: "onboarding")

        let download = app.buttons["onboarding.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let message = alert.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'huggingface.co' AND label CONTAINS 'MB'")
        ).firstMatch
        XCTAssertTrue(message.exists, "the confirmation states the size and the source")
        alert.buttons["Download"].tap()

        XCTAssertTrue(
            app.buttons["Cancel download"].waitForExistence(timeout: 5), "progress with cancel")

        let suggestion = app.buttons["suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 20), "model downloaded")
        XCTAssertTrue(suggestion.waitForEnabled(timeout: 10), "model loaded")
        suggestion.tap()

        let send = app.buttons["composer.send"]
        XCTAssertTrue(
            send.waitForLabel("Stop generating", timeout: 5), "send turns into stop while generating")
        XCTAssertTrue(
            app.staticTexts["tok/s"].waitForExistence(timeout: 5), "live readout visible")

        XCTAssertTrue(send.waitForLabel("Send", timeout: 30), "generation finished")
        let footer = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH ' tok/s'"))
            .firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "per-message stats footer")
    }

    /// Typing and sending, then Stop keeps the partial reply and marks it stopped.
    @MainActor
    func testSendThenStop() throws {
        let app = launch(scene: "ready")

        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Tell me about transistors")

        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForEnabled(timeout: 5))
        send.tap()
        XCTAssertTrue(send.waitForLabel("Stop generating", timeout: 5))
        Thread.sleep(forTimeInterval: 1.2)
        send.tap()

        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 5), "stopped marker")
        XCTAssertTrue(send.waitForLabel("Send", timeout: 5))
    }

    /// The model pill opens the model list; the settings button opens Settings.
    @MainActor
    func testModelsAndSettingsSheets() throws {
        let app = launch(scene: "chat")

        let pill = app.buttons["toolbar.modelPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 5), "active model marked")
        app.navigationBars["Models"].buttons["Done"].tap()

        let settings = app.buttons["toolbar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Temperature"].exists)

        // A vertical drag that starts on the temperature slider's track (not its thumb) still
        // scrolls the form.
        let slider = app.otherElements["Temperature"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let before = slider.frame.minY
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(slider.frame.minY, before - 100, "the form scrolled")

        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
    }
}

extension XCUIElement {
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
