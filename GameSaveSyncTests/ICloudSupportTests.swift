import XCTest

final class ICloudSupportTests: XCTestCase {
    func testPlainLocalFolderIsNotInICloudDrive() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gss-icloud-\(UUID().uuidString)", isDirectory: true)
        try TestSupport.makeDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertFalse(ICloudSupport.isInICloudDrive(folder),
                       "a temporary folder must not be reported as iCloud Drive")
    }

    func testICloudContainerPathIsDetectedWithoutTheResourceValue() {
        let url = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/GameSaveSync")
        XCTAssertTrue(ICloudSupport.isInICloudDrive(url),
                      "the CloudDocs container path alone must be enough to recognise iCloud Drive")
    }
}
