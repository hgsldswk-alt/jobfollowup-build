import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()
    private let share = [
        "JF_SHARE_TEXT": "Subject: Application received for Product Designer at Northline Studio.\nThanks for sending your portfolio.",
        "JF_SHARE_URL": "https://jobs.northline.example/openings/ux-204"
    ]
    private let csv = [
        "JF_CSV_TEXT": "Company,Role,Applied Date,Status,Notes\nNorthline Studio,Product Designer,2026-10-14,Offer,Portfolio sent\nCitrine Works,Data Designer,2026-11-21,Applied,\"Portfolio\nSecond line\"\nCitrine Works,Data Designer,2026-11-21,Applied,Repeated row\nFog City,QA,03/04/2026,Applied,Ambiguous date\n"
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    func testFirstRunManualAddAndSearch() {
        launch(["-first-run"])
        XCTAssertTrue(element("home.add").waitForExistence(timeout: 10))
        XCTAssertTrue(element("home.dismissTrial").exists)
        tap("home.add")
        enterManual(company: "Daybreak Studio", role: "Researcher")
        tap("editor.save")
        tap("home.search")
        let query = element("search.query")
        XCTAssertTrue(query.waitForExistence(timeout: 8))
        waitForKeyboard()
        query.typeText("daybreak")
        tap("search.job.Researcher")
        XCTAssertTrue(element("detail.status").waitForExistence(timeout: 8))
    }

    func testSharedPrefillSingleSaveAndCancel() {
        launch(["-shared"], environment: share)
        XCTAssertEqual(wait("editor.company").value as? String, "Northline Studio")
        XCTAssertEqual(wait("editor.role").value as? String, "Product Designer")
        XCTAssertEqual(wait("editor.source").value as? String, "Email")
        tap("editor.save")
        XCTAssertTrue(wait("home.job.Northline Studio").exists)

        launch(["-shared"], environment: share)
        tap("editor.cancel")
        XCTAssertTrue(wait("home.add").exists)
        XCTAssertFalse(element("home.job.Northline Studio").exists)
    }

    func testSaveFailureKeepsDraftAndAllowsCancel() {
        launch(["-shared", "-save-error"], environment: share)
        tap("editor.save")
        XCTAssertTrue(wait("editor.error").exists)
        XCTAssertEqual(element("editor.company").value as? String, "Northline Studio")
        XCTAssertTrue(element("editor.save").isEnabled)
        tap("editor.cancel")
        XCTAssertTrue(wait("home.add").exists)
    }

    func testDuplicateViewAndSaveAsSeparate() {
        launch(["-shared", "-demo"], environment: share)
        XCTAssertEqual(wait("editor.save").label, "Save as separate")
        tap("editor.duplicate", slide: true)
        if !element("detail.status").waitForExistence(timeout: 6) { print("HIERARCHY-DUP " + app.debugDescription) }
        XCTAssertTrue(wait("detail.status", timeout: 10).exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("editor.save")
        tap("home.search")
        waitForKeyboard()
        wait("search.query").typeText("Northline")
        let tests = app.descendants(matching: .any).matching(identifier: "search.job.Product Designer")
        XCTAssertEqual(tests.count, 2)
    }

    func testStatusLogUndoAndSearchArchive() {
        launch(["-demo"])
        tap("home.status.Northline Studio")
        tapDialog("Interview")
        XCTAssertTrue(wait("app.undo").exists)
        tap("app.undo")
        tap("home.log.Northline Studio")
        XCTAssertTrue(wait("app.undo").exists)
        let logged = element("home.log.Northline Studio")
        let removed = NSPredicate { _, _ in !logged.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 5), .completed)
        tap("home.job.Northline Studio", slide: true)
        tap("detail.archive", slide: true)
        app.navigationBars.buttons.firstMatch.tap()
        tap("home.search")
        waitForKeyboard()
        wait("search.query").typeText("northline")
        tap("search.job.Product Designer")
        XCTAssertEqual(wait("detail.archive", timeout: 8, slide: true).label, "Restore application")
    }

    func testCSVFromEmptyAndSettingsAndExport() {
        launch(["-csv-fixture"], environment: csv)
        tap("home.import")
        XCTAssertTrue(wait("csv.commit").exists)
        XCTAssertTrue(wait("csv.repair.3").exists)
        tap("csv.commit")
        XCTAssertTrue(wait("app.banner").exists)
        tap("settings.import")
        XCTAssertTrue(wait("csv.commit").exists)
        XCTAssertTrue(wait("csv.repair.3").exists)
        tap("csv.cancel")
        tap("settings.export")
        XCTAssertTrue(wait("share.requested").exists)
    }

    func testExpiredFreeLimitAndExistingData() {
        launch(["-expired", "-many"])
        tap("home.add")
        enterManual(company: "Extra Studio", role: "Designer")
        tap("editor.save")
        XCTAssertTrue(wait("editor.error").label.contains("15"))
        tap("editor.cancel")
        tap("home.search")
        waitForKeyboard()
        wait("search.query").typeText("Test Company 16")
        tap("search.job.Test Role")
        tap("detail.edit")
        XCTAssertEqual(wait("editor.company").value as? String, "Test Company 16")
        let role = wait("editor.role")
        role.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        role.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Test Role".count + 2))
        role.typeText("Existing Editor")
        tap("editor.save")
        XCTAssertTrue(app.staticTexts["Existing Editor"].waitForExistence(timeout: 8))
    }

    func testProgressSharingMilestoneAndCadence() {
        launch(["-demo"])
        tap("tab.progress")
        tap("progress.share")
        XCTAssertTrue(wait("share.preview", timeout: 15).exists)
        tap("share.image")
        XCTAssertTrue(wait("share.requested", timeout: 8, slide: true).exists)
        tap("share.close")
        tap("progress.milestone.interview", slide: true)
        XCTAssertTrue(wait("share.preview", timeout: 15).exists)
        tap("share.close")
        tap("progress.cadence", slide: true)
        XCTAssertTrue(wait("cadence.copied").exists)
        tap("tab.settings")
        tap("settings.cadence")
        let encoded = Data(#"{"version":1,"type":"follow-up","intervals":[5,3]}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let input = wait("cadence.input")
        input.tap()
        input.typeText("JF1:" + encoded)
        tap("cadence.preview", slide: true)
        tap("cadence.use", slide: true)
        XCTAssertTrue(wait("settings.cadence").exists)
    }

    func testNotificationDeniedDoesNotBlockCoreFlowAndWidgetGuide() {
        launch(["-notifications-denied"])
        tap("tab.settings")
        let toggle = wait("settings.reminders", slide: true)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(wait("settings.denied").exists)
        let help = wait("settings.widgetHelp", slide: true)
        let bar = element("tab.applications").frame.minY
        XCTAssertLessThanOrEqual(help.frame.maxY, bar - 4, "小组件说明被标签栏挡住 help=\(help.frame) bar=\(bar)")
        help.tap()
        if !element("widget.guide").waitForExistence(timeout: 6) { print("HIERARCHY-WIDGET " + app.debugDescription) }
        XCTAssertTrue(wait("widget.guide", timeout: 10).exists)
        tap("widget.close")
        tap("tab.applications")
        tap("home.add")
        XCTAssertTrue(wait("editor.company").exists)
    }

    func testStoreScreenshots() {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            launch(["-demo"], language: language)
            XCTAssertTrue(wait("home.job.Northline Studio").exists)
            shot("store-\(language)-01-home")

            launch(["-shared"], language: language, environment: share)
            XCTAssertTrue(wait("editor.save").isEnabled)
            shot("store-\(language)-02-share")

            launch(["-demo"], language: language)
            tap("home.job.Northline Studio")
            XCTAssertTrue(wait("detail.status").exists)
            shot("store-\(language)-03-timeline")

            launch(["-demo"], language: language)
            tap("home.search")
            waitForKeyboard()
            wait("search.query").typeText("Northline\n")
            XCTAssertTrue(wait("search.job.Brand Designer").exists)
            shot("store-\(language)-04-search")

            launch(["-demo", "-csv-fixture"], language: language, environment: csv)
            tap("tab.settings")
            tap("settings.import")
            XCTAssertTrue(wait("csv.overwrite.0").exists)
            shot("store-\(language)-05-csv")
        }
    }

    func testPaidScreenshot() {
        launch(["-paywall", "-expired"], language: "zh-Hans")
        XCTAssertTrue(wait("paywall.buy").exists)
        XCTAssertTrue(wait("paywall.restore").exists)
        shot("paid-01-paywall")
    }

    private func launch(_ flags: [String] = [], language: String = "en", environment: [String: String] = [:]) {
        if app.state != .notRunning { app.terminate() }
        let locale = language == "zh-Hans" ? "zh_CN" : language == "zh-Hant" ? "zh_TW" : "en_US"
        app.launchArguments = ["-ui-testing", "-reset", "-AppleLanguages", "(\(language))", "-AppleLocale", locale] + flags
        app.launchEnvironment = environment
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func wait(_ id: String, timeout: TimeInterval = 6, slide: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = element(id)
        _ = item.waitForExistence(timeout: slide ? min(timeout, 2) : timeout)
        if slide {
            for _ in 0..<5 {
                let bar = element("tab.applications")
                let limit = bar.exists && bar.frame.minY > 0 ? bar.frame.minY : app.frame.maxY
                if item.exists && item.isHittable && item.frame.maxY <= limit - 4 { break }
                app.swipeUp()
                Thread.sleep(forTimeInterval: 1.2)
            }
        }
        XCTAssertTrue(item.exists, id, file: file, line: line)
        return item
    }

    private func tap(_ id: String, slide: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let item = wait(id, slide: slide, file: file, line: line)
        let ready = NSPredicate { _, _ in item.exists && item.isHittable && item.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 8),
                       .completed, id, file: file, line: line)
        item.tap()
    }

    private func waitForKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
    }

    private func enterManual(company: String, role: String) {
        let companyField = wait("editor.company")
        waitForKeyboard()
        companyField.typeText(company + "\n")
        wait("editor.role").typeText(role)
    }

    private func tapDialog(_ title: String) {
        let choices = app.descendants(matching: .any).buttons.matching(NSPredicate(format: "label == %@", title))
        _ = choices.firstMatch.waitForExistence(timeout: 8)
        guard let choice = choices.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) else {
            XCTFail("Missing dialog button: \(title)")
            return
        }
        choice.tap()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
