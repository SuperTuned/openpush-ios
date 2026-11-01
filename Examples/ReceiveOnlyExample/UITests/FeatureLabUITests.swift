import UIKit
import XCTest

final class FeatureLabUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleInterfaceStyle", "Light",
            "-example.appearance", "light"
        ]
        app.launch()
    }

    func testFeatureWorkspacesAreReachable() {
        XCTAssertTrue(app.navigationBars["Status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["lab-intro"].exists)
        XCTAssertTrue(bringIntoView(app.buttons["Request notification permission"]))
        capture("status-light")

        app.tabBars.buttons["User"].tap()
        XCTAssertTrue(app.navigationBars["User"].exists)
        let login = app.buttons["Log in"]
        XCTAssertTrue(bringIntoView(login))
        login.tap()
        XCTAssertTrue(app.staticTexts["demo-user"].waitForExistence(timeout: 2))
        capture("user-identified")

        app.tabBars.buttons["Events"].tap()
        XCTAssertTrue(app.navigationBars["Events"].exists)
        XCTAssertTrue(bringIntoView(app.buttons["Schedule real local notification"]))
        XCTAssertTrue(bringIntoView(app.buttons["Preview an observer event"]))
        capture("events-stream")

        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].exists)
        XCTAssertTrue(bringIntoView(app.buttons["Start Live Activity"]))
        capture("activity-preview")

        app.tabBars.buttons["In-app"].tap()
        XCTAssertTrue(app.navigationBars["In-app"].exists)
        XCTAssertTrue(bringIntoView(app.buttons["inapp-add-trigger"]))
        capture("inapp-workspace")
    }

    /// The custom-event call is the one workspace write with no side effect of
    /// its own to look at: the batch is persisted and flushed in the
    /// background, so the stream row is the only evidence the call was made.
    func testCustomEventControl() {
        let tab = app.tabBars.buttons["Events"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Events"].waitForExistence(timeout: 3))

        let field = app.textFields["custom-event-name"]
        XCTAssertTrue(bringIntoView(field))
        XCTAssertTrue(type("checkout_started", into: field))

        let track = app.buttons["custom-event-track"]
        XCTAssertTrue(bringIntoView(track))
        track.tap()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Custom event tracked"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "the stream records the tracked event")
        XCTAssertTrue(
            text(of: row).contains("checkout_started"),
            "the stream row names the event that was tracked"
        )
        capture("events-custom-event")
    }

    func testInAppWorkspaceControls() {
        let tab = app.tabBars.buttons["In-app"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.navigationBars["In-app"].waitForExistence(timeout: 3))

        let add = app.buttons["inapp-add-trigger"]
        XCTAssertTrue(bringIntoView(add))
        add.tap()

        XCTAssertTrue(app.navigationBars["Add Trigger"].waitForExistence(timeout: 3))
        XCTAssertTrue(type("tier", into: app.textFields["editor-key-0"]))
        XCTAssertTrue(type("gold", into: app.textFields["editor-value-0"]))
        app.buttons["Add"].tap()

        XCTAssertTrue(app.staticTexts["tier"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["gold"].exists)
        capture("inapp-trigger-added")

        let paused = app.switches["inapp-paused"]
        XCTAssertTrue(bringIntoView(paused))
        let initial = paused.value as? String
        tapSwitchControl(paused)
        XCTAssertNotEqual(paused.value as? String, initial)
        tapSwitchControl(paused)
        XCTAssertEqual(paused.value as? String, initial)

        let clear = app.buttons["inapp-clear"]
        XCTAssertTrue(bringIntoView(clear))
        clear.tap()
        XCTAssertFalse(app.staticTexts["tier"].waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["gold"].exists)
    }

    /// Demo mode has no queue, so the preview action is the only way to see the
    /// shape of the events the listeners report. What is checked here is that
    /// the workspace renders the typed stage and the click's `firstClick` at
    /// all — the two things a host cannot read off a string phase.
    func testInAppEventBadgesRender() {
        let tab = app.tabBars.buttons["In-app"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.navigationBars["In-app"].waitForExistence(timeout: 3))

        let preview = app.buttons["inapp-preview-lifecycle"]
        XCTAssertTrue(bringIntoView(preview), "Demo mode offers the lifecycle preview")
        preview.tap()

        let stage = app.descendants(matching: .any)["inapp-last-stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: stage), "didDismiss", "the badge shows the stage's raw value")

        let layout = app.descendants(matching: .any)["inapp-last-layout"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        XCTAssertTrue(text(of: layout).contains("center"),
                      "the lifecycle event carries how the message was presented")

        let click = app.descendants(matching: .any)["inapp-last-click"].firstMatch
        XCTAssertTrue(click.waitForExistence(timeout: 3))
        XCTAssertTrue(text(of: click).contains("first"),
                      "the click row says whether this was the message's first click")
        capture("inapp-event-badges")
    }

    /// `addTags(_:)`/`addAliases(_:)` and `removeTags(_:)`/`removeAliases(_:)`
    /// are the plural calls the SDK is built around — several pairs in one
    /// coalesced registration. The editor has to be able to express that, and
    /// removal has to be able to name more than one key, or the workspace only
    /// ever demonstrates the singular convenience wrappers.
    func testPluralTagAndAliasWrites() {
        let user = app.tabBars.buttons["User"]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        user.tap()
        XCTAssertTrue(app.navigationBars["User"].waitForExistence(timeout: 3))

        addTwoRows(
            openedBy: "tags-add",
            sheet: "Add Tags",
            first: ("plan", "pro"),
            second: ("tier", "gold")
        )
        for text in ["plan", "pro", "tier", "gold"] {
            XCTAssertTrue(
                app.staticTexts[text].waitForExistence(timeout: 3),
                "\(text) should have travelled in the one addTags call"
            )
        }
        capture("user-plural-tags")

        // Multi-select removal: both keys leave through one removeTags call.
        XCTAssertTrue(bringIntoView(app.buttons["Select plan"]))
        app.buttons["Select plan"].tap()
        XCTAssertTrue(bringIntoView(app.buttons["Select tier"]))
        app.buttons["Select tier"].tap()

        let removeSelected = app.buttons["tags-remove-selected"]
        XCTAssertTrue(bringIntoView(removeSelected), "two selected rows offer a plural removal")
        removeSelected.tap()
        XCTAssertFalse(app.staticTexts["plan"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["tier"].exists)
        XCTAssertTrue(app.staticTexts["example_build"].exists, "an unselected tag is untouched")
        capture("user-plural-tag-removal")

        addTwoRows(
            openedBy: "aliases-add",
            sheet: "Add Aliases",
            first: ("player_id", "p-1042"),
            second: ("crm_id", "c-77")
        )
        for text in ["player_id", "p-1042", "crm_id", "c-77"] {
            XCTAssertTrue(
                app.staticTexts[text].waitForExistence(timeout: 3),
                "\(text) should have travelled in the one addAliases call"
            )
        }
        capture("user-plural-aliases")
    }

    private func addTwoRows(
        openedBy identifier: String,
        sheet: String,
        first: (key: String, value: String),
        second: (key: String, value: String)
    ) {
        let open = app.buttons[identifier]
        XCTAssertTrue(bringIntoView(open), "\(identifier) opens the editor")
        open.tap()
        XCTAssertTrue(app.navigationBars[sheet].waitForExistence(timeout: 3))

        XCTAssertTrue(type(first.key, into: app.textFields["editor-key-0"]))
        XCTAssertTrue(type(first.value, into: app.textFields["editor-value-0"]))

        let addRow = app.buttons["editor-add-row"]
        XCTAssertTrue(bringIntoSheet(addRow), "the editor offers another row")
        addRow.tap()

        XCTAssertTrue(type(second.key, into: app.textFields["editor-key-1"]))
        XCTAssertTrue(type(second.value, into: app.textFields["editor-value-1"]))

        app.buttons["Add"].tap()
        XCTAssertTrue(
            app.navigationBars[sheet].waitForNonExistence(timeout: 3),
            "saving dismisses the editor"
        )
    }

    /// A `Form` is not a scroll view to XCUITest, so the sheet's scrollable
    /// container has to be found among the collection, table, and scroll view
    /// queries before a swipe can reach an element the keyboard covers.
    private func bringIntoSheet(_ element: XCUIElement, maxSwipes: Int = 4) -> Bool {
        if element.exists, element.isHittable { return true }
        let containers = [
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
            app.scrollViews.firstMatch
        ]
        guard let container = containers.first(where: { $0.exists }) else { return false }
        for _ in 0..<maxSwipes {
            container.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    func testActivityKitStartAndEndFlow() throws {
        app.tabBars.buttons["Activity"].tap()
        let start = app.buttons["Start Live Activity"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.tap()

        let end = app.buttons["End Live Activity"]
        guard end.waitForExistence(timeout: 5) else {
            throw XCTSkip("ActivityKit is unavailable in this Simulator runtime")
        }
        XCTAssertTrue(app.buttons["Update Live Activity"].exists)
        end.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    func testActivityAuthorizationStateIsVisible() {
        app.tabBars.buttons["Activity"].tap()

        XCTAssertTrue(bringIntoView(
            app.descendants(matching: .any)["activitykit-live-activities"]
        ))
        XCTAssertTrue(bringIntoView(
            app.descendants(matching: .any)["activitykit-frequent-updates"]
        ))
        XCTAssertTrue(bringIntoView(app.buttons["Open iOS app settings"]))
    }

    /// The default-attributes path is the one an app with no ActivityKit
    /// attributes type of its own takes. The controls are asserted, not driven:
    /// starting a real activity here would leave one running for the rest of
    /// the suite, and the Simulator runtime may refuse it outright.
    func testDefaultLiveActivityControlsExist() {
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 3))

        // Asserted top-down, which is the order the panel scrolls in, so each
        // row is found on bringIntoView's downward pass.
        XCTAssertTrue(bringIntoView(
            app.descendants(matching: .any)["default-activity-status"]
        ))
        XCTAssertTrue(bringIntoView(app.switches["default-activity-push-to-start"]))
        XCTAssertTrue(bringIntoView(app.switches["default-activity-push-to-update"]))
        XCTAssertTrue(bringIntoView(app.buttons["default-activity-setup"]))
        XCTAssertTrue(bringIntoView(app.buttons["default-activity-start"]))
        XCTAssertTrue(bringIntoView(app.buttons["default-activity-remove-start-token"]))
        capture("activity-default-attributes")
    }

    func testPNSExamplesAreAvailable() {
        let examples = ["Simple", "Image", "Button", "Custom", "Sound"]
        for example in examples {
            XCTAssertTrue(bringIntoView(app.buttons["Schedule \(example) notification"]))
        }
        capture("pns-fixtures")

        let image = app.buttons["Schedule Image notification"]
        XCTAssertTrue(bringIntoView(image))
        image.tap()
        let receipt = app.descendants(matching: .any)["pns-last-request"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 1))
        XCTAssertEqual(receipt.value as? String, "Image scheduled")
    }

    func testCustomNotificationCanBeEditedBeforeScheduling() {
        let custom = app.buttons["Schedule Custom notification"]
        XCTAssertTrue(bringIntoView(custom))
        custom.tap()

        XCTAssertTrue(app.navigationBars["Custom Notification"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["custom-notification-title"].exists)
        XCTAssertTrue(app.textViews["custom-notification-description"].exists)
        XCTAssertTrue(app.textFields["custom-notification-key"].exists)
        XCTAssertTrue(app.textFields["custom-notification-value"].exists)
        XCTAssertTrue(app.buttons["Schedule"].isEnabled)
        capture("custom-notification-editor")
    }

    func testSettingsSheetUpdatesAppearanceWhilePresented() {
        app.buttons["Feature lab settings"].tap()
        let navigationBar = app.navigationBars["Feature Lab"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 3))
        app.buttons["Dark"].tap()
        XCTAssertTrue(waitForBrightness(of: navigationBar, matching: { $0 < 0.45 }))

        app.buttons["System"].tap()
        XCTAssertTrue(
            waitForBrightness(of: navigationBar, matching: { $0 > 0.55 }),
            "The presented settings sheet should return to the light system appearance"
        )
        capture("settings-system-live")
    }

    func testHostConsentGateCanBeExercised() {
        let consentToggle = app.switches["consent-required-toggle"]
        XCTAssertTrue(bringIntoView(consentToggle))
        if consentToggle.value as? String == "1" {
            tapSwitchControl(consentToggle)
        }
        XCTAssertEqual(consentToggle.value as? String, "0")
        tapSwitchControl(consentToggle)
        XCTAssertEqual(consentToggle.value as? String, "1")

        let grant = app.buttons["Grant consent & start SDK"]
        XCTAssertTrue(bringIntoView(grant))
        grant.tap()

        XCTAssertTrue(bringIntoView(app.buttons["Reset saved consent"]))
        capture("host-consent-granted")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A combined accessibility element reports its text as a value, a label,
    /// or both depending on how it was built. Read whichever one is there so a
    /// row assertion does not depend on that detail.
    private func text(of element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return value.isEmpty ? element.label : value
    }

    /// Searches the workspace in both directions: further down first, then all
    /// the way back up. A caller that asserts rows top-down never needs the
    /// second pass, but one that returns to an element an earlier assertion
    /// already scrolled past — the workspace is then sitting below it — would
    /// otherwise swipe into the bottom stop and report the element missing.
    /// The upward budget is twice the downward one so the second pass can undo
    /// the first and still reach the top of a workspace that started scrolled.
    private func bringIntoView(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if element.exists, element.isHittable { return true }
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 1) else { return false }
        for _ in 0..<maxSwipes {
            scrollView.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        for _ in 0..<(maxSwipes * 2) {
            scrollView.swipeDown()
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    /// A single tap on a field inside a sheet that is still settling does not
    /// always take keyboard focus, and `typeText` then fails outright. Tap until
    /// the field reports focus, then type.
    private func type(_ text: String, into field: XCUIElement, attempts: Int = 5) -> Bool {
        guard field.waitForExistence(timeout: 3) else { return false }
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<attempts {
            field.tap()
            // Let the tap land before asking: querying in a tight loop keeps the
            // app busy answering snapshots instead of taking focus.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            if focused.evaluate(with: field) {
                field.typeText(text)
                return true
            }
        }
        return false
    }

    private func tapSwitchControl(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func waitForBrightness(
        of element: XCUIElement,
        matching predicate: (CGFloat) -> Bool,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate(averageBrightness(of: element.screenshot().image)) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func averageBrightness(of image: UIImage) -> CGFloat {
        guard let source = image.cgImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * CGFloat(pixel[0])
                + 0.7152 * CGFloat(pixel[1])
                + 0.0722 * CGFloat(pixel[2])) / 255
    }
}
