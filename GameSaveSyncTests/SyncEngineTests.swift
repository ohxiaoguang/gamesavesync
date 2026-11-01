import XCTest
import Foundation

final class SyncEngineTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private var engine: SyncEngine!
    private var cloud: URL!
    private var deviceA: URL!
    private var deviceB: URL!
    private let gameId = "test-game"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-engine-\(UUID().uuidString)")
        paths = AppPaths(container: root.appendingPathComponent("app"))
        engine = SyncEngine(paths: paths)
        cloud = root.appendingPathComponent("cloud")
        deviceA = root.appendingPathComponent("A/saves")
        deviceB = root.appendingPathComponent("B/saves")
        try TestSupport.makeDirectory(cloud)
        try TestSupport.makeDirectory(deviceA)
        try TestSupport.makeDirectory(deviceB)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ local: URL, hasSyncedBefore: Bool = true, retention: Int = 3) -> SyncRequest {
        SyncRequest(gameId: gameId,
                    gameName: "Test Game",
                    localDirectory: local,
                    cloudRoot: cloud,
                    retention: retention,
                    deviceName: "TestDevice",
                    appVersion: "1.0",
                    hasSyncedBefore: hasSyncedBefore)
    }

    // MARK: - Upload

    func testUploadWritesManifestAndArchive() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: stamp)
        try TestSupport.write(deviceA, "profile/settings.ini", "beta", modified: stamp.addingTimeInterval(-60))

        let report = try engine.upload(request(deviceA))
        XCTAssertEqual(report.outcome, .uploaded)
        XCTAssertEqual(report.files, 2)

        let gameFolder = cloud.appendingPathComponent(gameId)
        XCTAssertTrue(FileSystem.exists(gameFolder.appendingPathComponent("latest.zip")))
        XCTAssertTrue(FileSystem.exists(gameFolder.appendingPathComponent("manifest.json")))

        let manifest = try TestSupport.manifest(at: cloud, gameId: gameId)
        XCTAssertEqual(manifest.gameId, gameId)
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertEqual(manifest.saveModifiedAt!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertFalse(manifest.archiveSHA256.isEmpty)
        XCTAssertGreaterThan(manifest.archiveBytes, 0)
    }

    func testEmptyFolderIsNotUploaded() throws {
        XCTAssertThrowsError(try engine.upload(request(deviceA))) { error in
            XCTAssertEqual(error as? SyncError, .emptyLocalSave)
        }
        XCTAssertFalse(FileSystem.exists(cloud.appendingPathComponent(gameId).appendingPathComponent("manifest.json")))
    }

    // MARK: - Restore

    func testRestoreCopiesFilesAndPreservesModificationTimes() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: stamp)
        try TestSupport.write(deviceA, "deep/dir/slot2.sav", "beta", modified: stamp.addingTimeInterval(-3600))
        _ = try engine.upload(request(deviceA))

        let report = try engine.restore(request(deviceB))
        XCTAssertEqual(report.outcome, .restored)
        XCTAssertEqual(report.files, 2)

        XCTAssertEqual(TestSupport.contents(deviceB, "slot1.sav"), "alpha")
        XCTAssertEqual(TestSupport.contents(deviceB, "deep/dir/slot2.sav"), "beta")
        let restored = TestSupport.modificationDate(deviceB, "slot1.sav")
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.05)
    }

    func testRestoreRemovesFilesThatAreNotInTheCloud() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "keep.sav", "cloud", modified: stamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "keep.sav", "old", modified: stamp.addingTimeInterval(-9999))
        try TestSupport.write(deviceB, "stale.sav", "should disappear", modified: stamp.addingTimeInterval(-9999))
        try TestSupport.makeDirectory(deviceB.appendingPathComponent("emptydir"))

        _ = try engine.restore(request(deviceB))

        XCTAssertEqual(TestSupport.contents(deviceB, "keep.sav"), "cloud")
        XCTAssertNil(TestSupport.contents(deviceB, "stale.sav"))
        XCTAssertEqual(TestSupport.relativeFileList(deviceB), ["keep.sav"])
    }

    func testRestoreCreatesLocalFolderWhenMissing() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "alpha", modified: stamp)
        _ = try engine.upload(request(deviceA))

        let fresh = root.appendingPathComponent("C/saves")
        let report = try engine.restore(request(fresh))
        XCTAssertEqual(report.outcome, .restored)
        XCTAssertEqual(TestSupport.contents(fresh, "slot.sav"), "alpha")
    }

    // MARK: - Analysis

    func testAnalysisDetectsCloudNewerThanLocal() throws {
        let cloudStamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: cloudStamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "old-local", modified: cloudStamp.addingTimeInterval(-7200))
        let analysis = engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .download(.cloudNewer))
    }

    func testAnalysisDetectsLocalNewer() throws {
        let cloudStamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: cloudStamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "new-local", modified: cloudStamp.addingTimeInterval(7200))
        let analysis = engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .upload(.localNewer))
    }

    func testAnalysisTreatsIdenticalContentAsUpToDate() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "same", modified: stamp)
        _ = try engine.upload(request(deviceA))

        // Same bytes, different mtime (e.g. copied by another tool).
        try TestSupport.write(deviceB, "slot.sav", "same", modified: stamp.addingTimeInterval(86_400))
        let analysis = engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .upToDate)
    }

    func testSyncReturnsConflictWithoutWriting() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: stamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp)
        let report = try engine.sync(request(deviceB))
        XCTAssertEqual(report.outcome, .conflictPending)
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version", "conflict must never overwrite silently")
    }

    // MARK: - Safety

    func testCorruptCloudArchiveIsRejectedAndLocalUntouched() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: stamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp.addingTimeInterval(-3600))

        // Corrupt the archive: the manifest hash no longer matches.
        let archive = cloud.appendingPathComponent(gameId).appendingPathComponent("latest.zip")
        var data = try Data(contentsOf: archive)
        data.append(Data(repeating: 0x00, count: 16))
        try data.write(to: archive)

        XCTAssertThrowsError(try engine.restore(request(deviceB))) { error in
            XCTAssertEqual(error as? SyncError, .cloudVerificationFailed)
        }
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version")
    }

    func testIncompleteManifestBlocksSync() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: stamp)
        _ = try engine.upload(request(deviceA))

        let manifestURL = cloud.appendingPathComponent(gameId).appendingPathComponent("manifest.json")
        var manifest = try TestSupport.manifest(at: cloud, gameId: gameId)
        manifest.status = .incomplete
        try Coders.encode(manifest).write(to: manifestURL)

        let analysis = engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .blocked(.cloudBackupIncomplete))
        XCTAssertThrowsError(try engine.sync(request(deviceB)))
    }

    func testRestoreCreatesLocalSafetyBackup() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "cloud-version", modified: stamp)
        _ = try engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp.addingTimeInterval(-3600))
        let report = try engine.restore(request(deviceB))

        XCTAssertNotNil(report.localBackupId)
        let backups = engine.localBackups(gameId: gameId)
        XCTAssertEqual(backups.count, 1)

        let payload = engine.backupManager.payloadURL(backups[0])
        XCTAssertEqual(TestSupport.contents(payload, "slot.sav"), "local-version")

        // And the backup can be restored again.
        _ = try engine.restoreLocalBackup(request(deviceB), backup: backups[0])
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version")
    }

    func testHistoryRetentionKeepsConfiguredNumber() throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        for index in 0..<5 {
            let stamp = base.addingTimeInterval(Double(index) * 86_400)
            try TestSupport.write(deviceA, "slot.sav", "version-\(index)", modified: stamp)
            _ = try engine.upload(request(deviceA, retention: 3))
        }

        let history = engine.history(request(deviceA))
        XCTAssertEqual(history.count, 3)
        // Newest first.
        XCTAssertTrue(history[0].backupCreatedAt >= history[1].backupCreatedAt)

        let historyFolder = cloud.appendingPathComponent(gameId).appendingPathComponent("history")
        let files = try FileManager.default.contentsOfDirectory(atPath: historyFolder.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".zip") }.count, 3)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 3)
    }

    func testHistoryVersionCanBeRestored() throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: base)
        _ = try engine.upload(request(deviceA))
        try TestSupport.write(deviceA, "slot.sav", "second", modified: base.addingTimeInterval(86_400))
        _ = try engine.upload(request(deviceA))

        let history = engine.history(request(deviceA))
        XCTAssertEqual(history.count, 1)
        let report = try engine.restoreHistory(request(deviceB), versionId: history[0].versionId)
        XCTAssertEqual(report.outcome, .restoredHistory)
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "first")
    }

    func testRestoreFromHistoryChecksumFailureKeepsLocal() throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: base)
        _ = try engine.upload(request(deviceA))
        try TestSupport.write(deviceA, "slot.sav", "second", modified: base.addingTimeInterval(86_400))
        _ = try engine.upload(request(deviceA))

        let history = engine.history(request(deviceA))
        let zip = cloud.appendingPathComponent(gameId).appendingPathComponent("history")
            .appendingPathComponent("\(history[0].versionId).zip")
        var data = try Data(contentsOf: zip)
        // Flip a byte inside the stored payload so the CRC check fails.
        let payload = data.range(of: Data("first".utf8))
        XCTAssertNotNil(payload)
        if let index = payload?.lowerBound {
            data[index] = 0x46 // 'F'
        }
        try data.write(to: zip)

        try TestSupport.write(deviceB, "slot.sav", "local", modified: base)
        XCTAssertThrowsError(try engine.restoreHistory(request(deviceB), versionId: history[0].versionId))
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local",
                       "a failed verification must leave the local folder untouched")
    }

    func testUnicodeAndEmptyDirectoriesRoundTrip() throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "存档/角色 一.sav", "数据", modified: stamp)
        try TestSupport.makeDirectory(deviceA.appendingPathComponent("空目录"))

        _ = try engine.upload(request(deviceA))
        _ = try engine.restore(request(deviceB))

        XCTAssertEqual(TestSupport.contents(deviceB, "存档/角色 一.sav"), "数据")
        XCTAssertTrue(FileSystem.isDirectory(deviceB.appendingPathComponent("空目录")),
                      "empty directories must survive a round trip")
    }
}

final class DirectoryReplacerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-replace-\(UUID().uuidString)")
        try TestSupport.makeDirectory(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCommitSwapsContents() throws {
        try TestSupport.write(root, "dest/old.sav", "old", modified: Date())
        let staging = try DirectoryReplacer.makeStagingDirectory(in: root.appendingPathComponent("dest"))
        try TestSupport.write(staging, "new.sav", "new", modified: Date())

        try DirectoryReplacer.commit(staging: staging, into: root.appendingPathComponent("dest"))

        XCTAssertEqual(TestSupport.relativeFileList(root.appendingPathComponent("dest")), ["new.sav"])
        XCTAssertFalse(FileSystem.exists(staging))
    }

    func testCommitRollsBackWhenStagingIsUnreadable() throws {
        let dest = root.appendingPathComponent("dest")
        try TestSupport.write(dest, "keep.sav", "keep-me", modified: Date())

        let missingStaging = dest.appendingPathComponent(".gamesavesync-stage-missing")
        XCTAssertThrowsError(try DirectoryReplacer.commit(staging: missingStaging, into: dest)) { error in
            guard case SyncError.replaceFailed(let recovered, _)? = error as? SyncError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(recovered)
        }
        XCTAssertEqual(TestSupport.contents(dest, "keep.sav"), "keep-me")
    }

    func testLeftoverDetectionAndRecovery() throws {
        let dest = root.appendingPathComponent("dest")
        try TestSupport.makeDirectory(dest)
        let previous = dest.appendingPathComponent(SavePathFilter.previousPrefix + "1234")
        try TestSupport.write(previous, "rescued.sav", "rescued", modified: Date())

        let leftovers = DirectoryReplacer.leftovers(in: dest)
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertEqual(leftovers[0].kind, .previous)
        XCTAssertEqual(leftovers[0].fileCount, 1)

        try DirectoryReplacer.restoreLeftover(leftovers[0], into: dest)
        XCTAssertEqual(TestSupport.contents(dest, "rescued.sav"), "rescued")
        XCTAssertTrue(DirectoryReplacer.leftovers(in: dest).isEmpty)
    }
}

final class SluggerTests: XCTestCase {
    func testSlugFromName() {
        XCTAssertEqual(Slugger.slug(from: "Darkest Dungeon"), "darkest-dungeon")
        XCTAssertEqual(Slugger.slug(from: "暗黑地牢"), "game")
        XCTAssertEqual(Slugger.slug(from: "FC 27!!"), "fc-27")
    }

    func testSanitizeRejectsTraversal() {
        XCTAssertEqual(Slugger.sanitizeGameId("../etc/passwd"), "etcpasswd")
        XCTAssertFalse(Slugger.isValidGameId("../etc"))
        XCTAssertTrue(Slugger.isValidGameId("darkest-dungeon"))
        XCTAssertTrue(Slugger.isValidGameId("fc.27"))
    }
}
