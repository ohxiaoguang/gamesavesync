import XCTest

final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEnglishScreens() {
        let app = launch(language: "en")
        XCTAssertTrue(app.staticTexts["Darkest Dungeon"].waitForExistence(timeout: 20))
        capture("01-list-en")

        app.staticTexts["FC 27"].tap()
        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 10))
        capture("02-detail-en")
    }

    func testChineseScreens() {
        let app = launch(language: "zh-Hans")
        XCTAssertTrue(app.staticTexts["暗黑地牢"].waitForExistence(timeout: 20)
                        || app.staticTexts["Darkest Dungeon"].waitForExistence(timeout: 5))
        capture("03-list-zh")

        app.staticTexts["FC 27"].tap()
        XCTAssertTrue(app.buttons["同步"].waitForExistence(timeout: 10) || app.buttons["Sync"].waitForExistence(timeout: 5))
        capture("04-detail-zh")
    }

    func testConflictSheet() {
        let app = launch(language: "en")
        XCTAssertTrue(app.staticTexts["Hollow Knight"].waitForExistence(timeout: 20))
        app.staticTexts["Hollow Knight"].tap()
        let syncButton = app.buttons["Sync"].firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 10))
        syncButton.tap()
        XCTAssertTrue(app.staticTexts["Both versions have the same timestamp but different content."].waitForExistence(timeout: 20))
        capture("05-conflict-en")
    }
}

final class SyncFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSyncRestoresNewerRemoteVersion() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["FC 27"].waitForExistence(timeout: 20))
        app.staticTexts["FC 27"].tap()
        XCTAssertTrue(app.buttons["Sync"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Sync"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 90),
                      "the sync must report a real restore")
        capture("06-after-sync")
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 20))
    }
}

final class ConfirmationFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDownloadConfirmationRestoresInsteadOfUploading() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Stardew Valley"].waitForExistence(timeout: 20))
        app.staticTexts["Stardew Valley"].tap()
        XCTAssertTrue(app.buttons["Sync"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Sync"].firstMatch.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "a first overwrite must ask for confirmation")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "07-confirm"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(alert.staticTexts["Restore now?"].exists,
                      "the alert must explain which direction will be taken")
        alert.buttons["Restore"].tap()

        XCTAssertTrue(app.staticTexts["Restored"].waitForExistence(timeout: 90),
                      "confirming must restore the remote version, not upload the local one")
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 20))
    }
}

final class HistoryFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRemoteHistoryListsCommits() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Mario Wonder"].waitForExistence(timeout: 20))
        app.staticTexts["Mario Wonder"].tap()

        // The history lives below the actions, so scroll until the section is on screen.
        let header = app.staticTexts["Version History"]
        var swipes = 0
        while !header.exists, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(header.exists, "the detail page must show the remote commit history")
        XCTAssertFalse(app.staticTexts["No history yet"].exists,
                       "a game that was uploaded has at least one commit")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "11-history"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class SettingsScreenTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsConfiguresTheGitHubRepository() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Darkest Dungeon"].waitForExistence(timeout: 20))
        app.buttons["Settings"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["GitHub Repository"].exists,
                      "the settings screen must configure the remote repository")
        XCTAssertTrue(app.staticTexts["Repository Owner"].exists)
        XCTAssertTrue(app.staticTexts["Access Token"].exists)
        XCTAssertTrue(app.staticTexts["No token stored"].exists)
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "iCloud")
        ).firstMatch.exists, "no iCloud wording may remain in settings")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "08-settings"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

final class EditorFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The detail form is long enough that "Edit Game" sits below the fold, and SwiftUI does not
    /// publish rows that were never on screen, so the test has to scroll before querying it.
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        var swipes = 0
        while !element.isHittable, swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.isHittable
    }

    private func openEditor(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Darkest Dungeon"].waitForExistence(timeout: 20))
        app.staticTexts["Darkest Dungeon"].tap()
        XCTAssertTrue(app.navigationBars["Darkest Dungeon"].waitForExistence(timeout: 10))
        let editButton = app.buttons["Edit Game"]
        XCTAssertTrue(scrollUntilVisible(editButton, in: app), "the Edit Game button must be reachable")
        editButton.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEditorShowsAuthorisedAndSyncFolders() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        openEditor(app)

        XCTAssertTrue(app.staticTexts["Authorised Folder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sync Folder"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "/ saves")).firstMatch.exists,
                      "the editor must show the sync folder as a path inside the authorised folder")
        capture("09-editor")
    }

    func testSyncFolderBrowserOpensFilesPickerAndReturnsAfterDismissal() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()
        openEditor(app)
        app.buttons.matching(NSPredicate(format: "label == %@", "Choose…")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["saves"].waitForExistence(timeout: 10))

        // Exercise presentation twice: dismissing the system sheet must leave the browser usable.
        for _ in 0..<2 {
            let files = app.buttons["Choose with the Files app…"]
            XCTAssertTrue(files.waitForExistence(timeout: 5))
            files.tap()
            let browser = app.otherElements["Browse View (Picker)"]
            XCTAssertTrue(browser.waitForExistence(timeout: 20), app.debugDescription)
            // Drag the system sheet's navigation area down. The remote picker exposes its
            // Cancel control inconsistently on the simulator, so use interactive dismissal.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: browser)
            wait(for: [dismissed], timeout: 5)
            XCTAssertTrue(app.buttons["Choose This Folder"].isHittable)
        }
        XCTAssertTrue(app.staticTexts["profile"].waitForExistence(timeout: 5))
    }

    func testSelectingNestedFolderWithRepeatedNameKeepsFullRelativePath() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()
        openEditor(app)
        app.buttons.matching(NSPredicate(format: "label == %@", "Choose…")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["profile"].waitForExistence(timeout: 10))
        app.buttons["saves"].tap()
        XCTAssertTrue(app.staticTexts["There are no subfolders here."].waitForExistence(timeout: 10))
        app.buttons["Choose This Folder"].tap()
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "/ saves/saves")
        ).firstMatch.waitForExistence(timeout: 5))
    }

    func testSyncFolderBrowserListsSubfolders() {
        let app = XCUIApplication()
        app.launchArguments = ["-GSSDemoSeed", "-AppleLanguages", "(en)"]
        app.launch()

        openEditor(app)

        XCTAssertTrue(app.staticTexts["Sync Folder"].waitForExistence(timeout: 10))
        // The authorised folder row reads "Change" for an existing game, so the only "Choose…"
        // button on screen is the one belonging to the sync folder.
        let chooseSync = app.buttons.matching(NSPredicate(format: "label == %@", "Choose…")).firstMatch
        XCTAssertTrue(chooseSync.isEnabled, "the sync folder button must be enabled")
        chooseSync.tap()

        XCTAssertTrue(app.staticTexts["Subfolders"].waitForExistence(timeout: 10))
        // The browser opens on the folder that is already selected, so it starts inside `saves`.
        XCTAssertTrue(app.navigationBars["saves"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["profile"].waitForExistence(timeout: 5))

        // iOS can shorten the parent title to "Back" when toolbar buttons use the available width.
        let back = app.navigationBars["saves"].buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Sync Folder", "Back")
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        // At the authorised root only folders are listed: `cache` appears, `config.json` does not.
        XCTAssertTrue(app.staticTexts["cache"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["saves"].exists)
        XCTAssertFalse(app.staticTexts["config.json"].exists)
        capture("10-browser")
    }
}
