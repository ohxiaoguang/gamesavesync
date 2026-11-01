import XCTest
import Foundation

final class ScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-scan-\(UUID().uuidString)")
        try TestSupport.makeDirectory(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNewestFileTimeIsUsedNotFolderTime() throws {
        let old = TestSupport.date("2026-01-01T10:00:00.000Z")
        let newer = TestSupport.date("2026-05-04T18:22:33.000Z")
        try TestSupport.write(root, "a.sav", "a", modified: old)
        try TestSupport.write(root, "sub/b.sav", "b", modified: newer)
        // Folder timestamps deliberately set far in the future: they must be ignored.
        try FileManager.default.setAttributes([.modificationDate: TestSupport.date("2030-01-01T00:00:00.000Z")],
                                              ofItemAtPath: root.path)

        let scan = try SaveScanner().scan(directory: root)
        XCTAssertEqual(scan.snapshot.fileCount, 2)
        XCTAssertEqual(scan.snapshot.newestModified!.timeIntervalSince1970,
                       newer.timeIntervalSince1970,
                       accuracy: 0.01)
    }

    func testHashIsStableAndSensitiveToContent() throws {
        let stamp = TestSupport.date("2026-03-03T03:03:03.000Z")
        try TestSupport.write(root, "slot.sav", "version-one", modified: stamp)
        let first = try SaveScanner().scan(directory: root).snapshot.contentHash
        let second = try SaveScanner().scan(directory: root).snapshot.contentHash
        XCTAssertEqual(first, second, "same content must produce the same hash")

        // Same timestamp, different content.
        try TestSupport.write(root, "slot.sav", "version-two", modified: stamp)
        let third = try SaveScanner().scan(directory: root).snapshot.contentHash
        XCTAssertNotEqual(first, third, "content changes must be detected even with an unchanged timestamp")
    }

    func testHashIgnoresFileOrdering() throws {
        let stamp = TestSupport.date("2026-03-03T03:03:03.000Z")
        // A separate directory, not a child of `root` (that would add files to the scan).
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("gss-hash-\(UUID().uuidString)")
        try TestSupport.makeDirectory(other)
        defer { try? FileManager.default.removeItem(at: other) }
        try TestSupport.write(root, "a.sav", "A", modified: stamp)
        try TestSupport.write(root, "b.sav", "B", modified: stamp)
        try TestSupport.write(other, "b.sav", "B", modified: stamp)
        try TestSupport.write(other, "a.sav", "A", modified: stamp)

        let first = try SaveScanner().scan(directory: root).snapshot.contentHash
        let second = try SaveScanner().scan(directory: other).snapshot.contentHash
        XCTAssertEqual(first, second)
    }

    func testEmptyFolderHasNoTimestampAndZeroFiles() throws {
        let scan = try SaveScanner().scan(directory: root)
        XCTAssertEqual(scan.snapshot.fileCount, 0)
        XCTAssertNil(scan.snapshot.newestModified)
        XCTAssertTrue(scan.snapshot.isEmpty)
        XCTAssertFalse(scan.snapshot.contentHash.isEmpty)
    }

    func testNoiseFilesAreExcluded() throws {
        let stamp = TestSupport.date("2026-02-02T02:02:02.000Z")
        try TestSupport.write(root, "slot.sav", "data", modified: stamp)
        try TestSupport.write(root, ".DS_Store", "junk", modified: TestSupport.date("2027-02-02T02:02:02.000Z"))
        try TestSupport.write(root, "._slot.sav", "junk", modified: TestSupport.date("2027-02-02T02:02:02.000Z"))
        try TestSupport.write(root, SavePathFilter.archiveMetadataName, "{}", modified: TestSupport.date("2027-02-02T02:02:02.000Z"))

        let scan = try SaveScanner().scan(directory: root)
        XCTAssertEqual(scan.snapshot.fileCount, 1)
        XCTAssertEqual(scan.snapshot.newestModified!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.01)
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try SaveScanner().scan(directory: root.appendingPathComponent("nope"))) { error in
            XCTAssertEqual(error as? SyncError, .localFolderUnavailable)
        }
    }
}

final class DecisionTests: XCTestCase {
    private func snapshot(hash: String, time: String?, files: Int = 1) -> SaveSnapshot {
        SaveSnapshot(newestModified: time.map(TestSupport.date),
                     fileCount: files,
                     directoryCount: 0,
                     totalBytes: 100,
                     contentHash: hash)
    }

    private func manifest(hash: String, time: String?, files: Int = 1) -> CloudManifest {
        CloudManifest(gameId: "g",
                      gameName: "G",
                      versionId: "v1",
                      saveModifiedAt: time.map(TestSupport.date),
                      saveWasEmpty: files == 0,
                      backupCreatedAt: Date(),
                      sourceDevice: "A",
                      sourceAppVersion: "1",
                      contentHash: hash,
                      fileCount: files,
                      totalBytes: 100,
                      archiveBytes: 10,
                      archiveSHA256: "x")
    }

    func testLocalNewerUploads() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .upload(.localNewer))
    }

    func testCloudNewerDownloads() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T09:00:00.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .download(.cloudNewer))
    }

    func testIdenticalContentIsUpToDateEvenWithDifferentTimes() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "same", time: "2026-05-01T09:00:00.000Z"),
                                                remote: manifest(hash: "same", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .upToDate)
    }

    func testSameTimeDifferentContentIsConflict() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T10:00:00.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .conflict)
    }

    func testSubSecondDifferenceIsTreatedAsSameTime() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T10:00:01.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .conflict)
    }

    func testFirstSyncLocalOnlyUploads() {
        XCTAssertEqual(SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T10:00:00.000Z"),
                                                remote: nil),
                       .upload(.firstSyncLocalOnly))
    }

    func testFirstSyncCloudOnlyDownloads() {
        XCTAssertEqual(SyncDecisionMaker.decide(local: nil,
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z")),
                       .download(.firstSyncCloudOnly))
    }

    func testEmptyLocalFolderTakesCloudVersion() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "empty", time: nil, files: 0),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        XCTAssertEqual(decision, .download(.localEmpty))
    }

    func testBothEmptyIsUpToDate() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "empty", time: nil, files: 0),
                                                remote: manifest(hash: "empty", time: nil, files: 0))
        XCTAssertEqual(decision, .upToDate)
    }

    func testMissingTimestampsFallsBackToConflict() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: nil),
                                                remote: manifest(hash: "b", time: nil))
        XCTAssertEqual(decision, .conflict)
    }

    func testFirstSyncBothSidesRequiresConfirmation() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        let confirmation = SyncDecisionMaker.confirmation(for: decision,
                                                          local: snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z"),
                                                          remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"),
                                                          hasSyncedBefore: false)
        XCTAssertEqual(confirmation, .firstSyncOverwrite(.upload))
    }

    func testRoutineUploadNeedsNoConfirmationOnceSyncedBefore() {
        let decision = SyncDecisionMaker.decide(local: snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z"),
                                                remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"))
        let confirmation = SyncDecisionMaker.confirmation(for: decision,
                                                          local: snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z"),
                                                          remote: manifest(hash: "b", time: "2026-05-01T10:00:00.000Z"),
                                                          hasSyncedBefore: true)
        XCTAssertEqual(confirmation, .none)
    }

    func testFirstUploadOfAGameWithNoRemoteCopyAsksForConfirmation() {
        let local = snapshot(hash: "a", time: "2026-05-01T12:00:00.000Z")
        let decision = SyncDecisionMaker.decide(local: local, remote: nil)
        XCTAssertEqual(decision, .upload(.firstSyncLocalOnly))

        let confirmation = SyncDecisionMaker.confirmation(for: decision,
                                                          local: local,
                                                          remote: nil,
                                                          hasSyncedBefore: false)
        XCTAssertEqual(confirmation, .firstUpload,
                       "the very first upload of a game must be confirmed, never silent")
    }

    func testClockSkewIsFlagged() {
        let local = snapshot(hash: "a", time: "2027-05-01T12:00:00.000Z")
        let remote = manifest(hash: "b", time: "2026-05-01T10:00:00.000Z")
        let decision = SyncDecisionMaker.decide(local: local, remote: remote)
        let confirmation = SyncDecisionMaker.confirmation(for: decision, local: local, remote: remote, hasSyncedBefore: true)
        XCTAssertEqual(confirmation, .clockSkew(.upload))
    }
}
