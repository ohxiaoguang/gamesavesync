import XCTest

final class LocalizationTests: XCTestCase {
    private let chinese = Localizer(language: .chinese)
    private let english = Localizer(language: .english)

    func testEverySyncPhaseHasChineseText() {
        for phase in SyncPhase.allCases {
            XCTAssertNotEqual(chinese.t(phase.text), phase.text, "missing zh translation for phase: \(phase.text)")
            XCTAssertEqual(english.t(phase.text), phase.text)
        }
    }

    func testEverySyncErrorHasChineseText() {
        let errors: [SyncError] = [
            .localFolderUnavailable, .accessRootUnavailable(detail: "x"), .accessRootMissing,
            .syncFolderMissing("saves"), .invalidSyncPath("../x"),
            .gitHubNotConfigured, .cloudBackupMissing, .cloudBackupIncomplete, .cloudVerificationFailed,
            .gitHubRemoteChanged, .gitHubRepositoryEmpty, .gitHubAuthFailed(detail: "x"),
            .gitHubPermissionDenied(detail: "x"), .gitHubRateLimited(retryAfter: 5),
            .gitHubRepositoryNotFound("x"), .gitHubNotFound("blob"), .gitHubRepositoryNotPrivate,
            .gitHubBranchMissing("main"), .gitHubUnprocessable, .gitHubServerError(status: 502),
            .gitHubUnexpectedResponse("x"), .gitHubFileTooLarge(bytes: 1, limit: 2),
            .networkUnavailable, .networkTimeout, .cancelled,
            .archiveCorrupt("x"), .unsafeArchivePath("x"), .archiveTooLarge("x"),
            .localBackupFailed("x"), .replaceFailed(recovered: true, detail: "x"),
            .replaceFailed(recovered: false, detail: "x"), .folderCreationFailed("x"),
            .emptyLocalSave, .generic("x"),
        ]
        for error in errors {
            let translated = chinese.t(error.messageKey)
            XCTAssertNotEqual(translated, error.messageKey, "missing zh translation for error: \(error.messageKey)")
        }
    }

    func testFileCountPluralization() {
        XCTAssertEqual(english.files(1), "1 file")
        XCTAssertEqual(english.files(3), "3 files")
        XCTAssertEqual(chinese.files(3), "3 个文件")
    }

    func testExplicitLanguageSelection() {
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertEqual(AppLanguage.chinese.resolved, .chinese)
        XCTAssertEqual(AppLanguage.system.resolved.localeIdentifier.isEmpty, false)
    }
}
