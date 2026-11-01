import XCTest
import Foundation

final class SyncEngineTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private var engine: SyncEngine!
    private var harness: GitHubTestHarness!
    private var deviceA: URL!
    private var deviceB: URL!
    private let gameId = "test-game"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-engine-\(UUID().uuidString)")
        paths = AppPaths(container: root.appendingPathComponent("app"))
        engine = SyncEngine(paths: paths)
        harness = GitHubTestHarness()
        deviceA = root.appendingPathComponent("A/saves")
        deviceB = root.appendingPathComponent("B/saves")
        try TestSupport.makeDirectory(deviceA)
        try TestSupport.makeDirectory(deviceB)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        harness = nil
    }

    private func request(_ local: URL, hasSyncedBefore: Bool = true, retention: Int = 3) -> SyncRequest {
        harness.makeRequest(gameId: gameId,
                            localDirectory: local,
                            hasSyncedBefore: hasSyncedBefore,
                            retention: retention)
    }

    // MARK: - Empty repository

    func testEmptyRepositoryFirstSyncUsesTheUploadFlow() async throws {
        try TestSupport.write(deviceA, "slot.sav", "first", modified: TestSupport.date("2026-11-01T09:00:00.000Z"))
        XCTAssertTrue(harness.server.repositoryIsEmpty)

        let analysis = await engine.analyze(request(deviceA, hasSyncedBefore: false))

        XCTAssertNil(analysis.remoteError, "a repository without commits is not an error")
        XCTAssertNil(analysis.remote)
        XCTAssertNil(analysis.remoteCommit)
        XCTAssertEqual(analysis.decision, .upload(.firstSyncLocalOnly))
        XCTAssertEqual(analysis.confirmation, .firstUpload,
                       "the first archive of a game must be confirmed before it is uploaded")
        XCTAssertTrue(harness.server.repositoryIsEmpty, "analysing must not write anything")
    }

    func testFirstUploadIntoAnEmptyRepositoryInitialisesAndCommitsTheSave() async throws {
        let stamp = TestSupport.date("2026-11-01T09:00:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: stamp)
        try TestSupport.write(deviceA, "profile/opts.ini", "x", modified: stamp.addingTimeInterval(-30))

        let report = try await engine.perform(request(deviceA, hasSyncedBefore: false), direction: .upload)

        XCTAssertEqual(report.outcome, .uploaded)
        let head = try XCTUnwrap(harness.server.headCommit)
        XCTAssertEqual(report.commitSHA, head)
        XCTAssertNotNil(harness.server.fileContents(at: head, path: GitHubLayout.initialisationPath),
                        "an empty repository must be initialised through the contents endpoint")

        let manifest = try XCTUnwrap(harness.manifest(gameId: gameId))
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertNotNil(harness.server.archiveData(at: head, gameId: gameId),
                        "the archive must sit in the same commit as its manifest")

        // HEAD is readable as soon as the repository has a commit.
        let after = try await harness.manager.head()
        XCTAssertEqual(after.commit, head)

        // And the next sync recognises the archive it just uploaded.
        let analysis = await engine.analyze(request(deviceA))
        XCTAssertNil(analysis.remoteError)
        XCTAssertEqual(analysis.remote?.contentHash, manifest.contentHash)
        XCTAssertEqual(analysis.decision, .upToDate)
    }

    func testEmptyRepositorySyncInitialisesOnlyOnce() async throws {
        try TestSupport.write(deviceA, "slot.sav", "first", modified: TestSupport.date("2026-11-01T09:00:00.000Z"))
        _ = try await engine.perform(request(deviceA, hasSyncedBefore: false), direction: .upload)

        try TestSupport.write(deviceA, "slot.sav", "second", modified: TestSupport.date("2026-11-02T09:00:00.000Z"))
        let second = try await engine.perform(request(deviceA), direction: .upload)

        XCTAssertEqual(second.outcome, .uploaded)
        let initialisations = harness.server.statusLog.filter {
            $0.hasPrefix("PUT ") && $0.contains("/contents/") && $0.hasSuffix(" 201")
        }
        XCTAssertEqual(initialisations.count, 1, "the repository must be initialised exactly once")
        XCTAssertEqual(harness.manifest(gameId: gameId)?.fileCount, 1)
    }

    func testRepositoryWithCommitsAndMissingBranchIsNotInitialised() async throws {
        harness.server.seedRepository()
        try TestSupport.write(deviceA, "slot.sav", "first", modified: TestSupport.date("2026-11-01T09:00:00.000Z"))
        let manager = harness.makeManager(branch: "archives")
        let custom = harness.makeRequest(gameId: gameId,
                                        localDirectory: deviceA,
                                        hasSyncedBefore: false,
                                        remote: manager)

        let analysis = await engine.analyze(custom)

        XCTAssertEqual(analysis.decision, .blocked(.gitHubBranchMissing("archives")))
        XCTAssertFalse(harness.server.statusLog.contains { $0.hasPrefix("PUT ") && $0.contains("/contents/") },
                       "a repository that already has commits must never be re-initialised")
        XCTAssertNil(harness.server.branchHead("archives"))
    }

    func testPermissionFailureIsNotTreatedAsAnEmptyRepository() async throws {
        try TestSupport.write(deviceA, "slot.sav", "first", modified: TestSupport.date("2026-11-01T09:00:00.000Z"))
        harness.server.persistentFault = .status(403, "Resource not accessible by personal access token")

        let analysis = await engine.analyze(request(deviceA, hasSyncedBefore: false))

        guard case .blocked(let error) = analysis.decision else {
            return XCTFail("a permission failure must block the sync, got \(analysis.decision)")
        }
        guard case .gitHubPermissionDenied = error else {
            return XCTFail("expected gitHubPermissionDenied, got \(error)")
        }
        XCTAssertFalse(harness.server.statusLog.contains { $0.hasPrefix("PUT ") })
    }

    // MARK: - Upload

    func testFirstUploadCreatesACommitWithManifestAndArchive() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: stamp)
        try TestSupport.write(deviceA, "profile/settings.ini", "beta", modified: stamp.addingTimeInterval(-60))

        let report = try await engine.upload(request(deviceA))
        XCTAssertEqual(report.outcome, .uploaded)
        XCTAssertEqual(report.files, 2)
        XCTAssertNotNil(report.commitSHA)
        XCTAssertEqual(harness.server.headCommit, report.commitSHA)

        let manifest = try XCTUnwrap(harness.manifest(gameId: gameId))
        XCTAssertEqual(manifest.gameId, gameId)
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertEqual(manifest.saveModifiedAt!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertFalse(manifest.archiveSHA256.isEmpty)
        XCTAssertGreaterThan(manifest.archiveBytes, 0)
    }

    func testManifestAndArchiveLiveInTheSameCommit() async throws {
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: TestSupport.date("2026-10-31T20:30:00.000Z"))
        let firstUpload = try await engine.upload(request(deviceA))
        try TestSupport.write(deviceA, "slot1.sav", "alpha-v2", modified: TestSupport.date("2026-11-01T09:00:00.000Z"))
        let second = try await engine.upload(request(deviceA))

        let commit = try XCTUnwrap(second.commitSHA)
        let manifest = try XCTUnwrap(harness.server.manifest(at: commit, gameId: gameId))
        let archive = try XCTUnwrap(harness.server.archiveData(at: commit, gameId: gameId))

        // The archive the commit points at must match the manifest in the same commit.
        XCTAssertEqual(Hashing.sha256Hex(archive), manifest.archiveSHA256)
        XCTAssertEqual(Int(archive.count), manifest.archiveBytes)

        // And the previous commit still holds the old pair.
        let firstCommit = try XCTUnwrap(firstUpload.commitSHA)
        XCTAssertNotEqual(firstCommit, commit)
        let oldManifest = try XCTUnwrap(harness.server.manifest(at: firstCommit, gameId: gameId))
        XCTAssertNotEqual(oldManifest.contentHash, manifest.contentHash)
    }

    func testSecondUploadKeepsOtherGamesIntact() async throws {
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: TestSupport.date("2026-10-31T20:30:00.000Z"))

        // Another game already in the repository.
        let otherManifest = CloudManifest(gameId: "other-game",
                                          gameName: "Other",
                                          versionId: "v-other",
                                          saveModifiedAt: Date(),
                                          saveWasEmpty: false,
                                          backupCreatedAt: Date(),
                                          sourceDevice: "Device X",
                                          sourceAppVersion: "1.0",
                                          contentHash: "hash-other",
                                          fileCount: 3,
                                          totalBytes: 42,
                                          archiveBytes: 10,
                                          archiveSHA256: "abc")
        harness.server.simulateRemoteUpload(gameId: "other-game",
                                            manifest: otherManifest,
                                            archive: Data("other-zip".utf8))

        let upload = try await engine.upload(request(deviceA))
        let commit = try XCTUnwrap(upload.commitSHA)

        XCTAssertNotNil(harness.server.manifest(at: commit, gameId: "other-game"),
                        "a commit for one game must never delete another game")
        XCTAssertNotNil(harness.server.manifest(at: commit, gameId: gameId))
    }

    func testEmptyFolderIsNotUploaded() async throws {
        do {
            _ = try await engine.upload(request(deviceA))
            XCTFail("an empty folder must not be uploaded")
        } catch {
            XCTAssertEqual(error as? SyncError, .emptyLocalSave)
        }
        XCTAssertTrue(harness.server.repositoryIsEmpty)
    }

    // MARK: - Restore

    func testRestoreCopiesFilesAndPreservesModificationTimes() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot1.sav", "alpha", modified: stamp)
        try TestSupport.write(deviceA, "deep/dir/slot2.sav", "beta", modified: stamp.addingTimeInterval(-3600))
        _ = try await engine.upload(request(deviceA))

        let report = try await engine.restore(request(deviceB))
        XCTAssertEqual(report.outcome, .restored)
        XCTAssertEqual(report.files, 2)

        XCTAssertEqual(TestSupport.contents(deviceB, "slot1.sav"), "alpha")
        XCTAssertEqual(TestSupport.contents(deviceB, "deep/dir/slot2.sav"), "beta")
        let restored = TestSupport.modificationDate(deviceB, "slot1.sav")
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.05)
    }

    func testRestoreRemovesFilesThatAreNotOnTheRemote() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "keep.sav", "remote", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "keep.sav", "old", modified: stamp.addingTimeInterval(-9999))
        try TestSupport.write(deviceB, "stale.sav", "should disappear", modified: stamp.addingTimeInterval(-9999))
        try TestSupport.makeDirectory(deviceB.appendingPathComponent("emptydir"))

        _ = try await engine.restore(request(deviceB))

        XCTAssertEqual(TestSupport.contents(deviceB, "keep.sav"), "remote")
        XCTAssertNil(TestSupport.contents(deviceB, "stale.sav"))
        XCTAssertEqual(TestSupport.relativeFileList(deviceB), ["keep.sav"])
    }

    func testRestoreCreatesLocalFolderWhenMissing() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "alpha", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        let fresh = root.appendingPathComponent("C/saves")
        let report = try await engine.restore(request(fresh))
        XCTAssertEqual(report.outcome, .restored)
        XCTAssertEqual(TestSupport.contents(fresh, "slot.sav"), "alpha")
    }

    // MARK: - Analysis

    func testAnalysisDetectsRemoteNewerThanLocal() async throws {
        let remoteStamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: remoteStamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "old-local", modified: remoteStamp.addingTimeInterval(-7200))
        let analysis = await engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .download(.cloudNewer))
    }

    func testAnalysisDetectsLocalNewer() async throws {
        let remoteStamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: remoteStamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "new-local", modified: remoteStamp.addingTimeInterval(7200))
        let analysis = await engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .upload(.localNewer))
    }

    func testAnalysisTreatsIdenticalContentAsUpToDate() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "same", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        // Same bytes, different mtime (e.g. copied by another tool).
        try TestSupport.write(deviceB, "slot.sav", "same", modified: stamp.addingTimeInterval(86_400))
        let analysis = await engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision, .upToDate)
    }

    func testSyncReturnsConflictWithoutWriting() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp)
        let report = try await engine.sync(request(deviceB))
        XCTAssertEqual(report.outcome, .conflictPending)
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version", "conflict must never overwrite silently")
    }

    func testForcedUploadAbortsWhenTheSameGameChangedAfterAnalysis() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        // Another device publishes a new version of this game between our analysis and our write.
        var otherDevice = try XCTUnwrap(harness.manifest(gameId: gameId))
        otherDevice.versionId = "from-other-device"
        otherDevice.contentHash = "hash-from-other-device"
        harness.server.beforeRefUpdate = { server in
            server.simulateRemoteUpload(gameId: "test-game",
                                        manifest: otherDevice,
                                        archive: Data("other-device-zip".utf8))
        }

        try TestSupport.write(deviceA, "slot.sav", "mine-newer", modified: stamp.addingTimeInterval(3600))
        do {
            _ = try await engine.perform(request(deviceA), direction: .upload)
            XCTFail("an explicit upload must not overwrite a version it never saw")
        } catch {
            XCTAssertEqual(error as? SyncError, .gitHubRemoteChanged)
        }
        XCTAssertEqual(harness.manifest(gameId: gameId)?.contentHash, "hash-from-other-device",
                       "the other device's version must survive a forced upload")
    }

    func testLegacySyncRecordDoesNotSkipTheFirstGitHubConfirmation() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        // A device that synced with the old iCloud folder has a successful record but no remote id.
        try TestSupport.write(deviceB, "slot.sav", "local-newer", modified: stamp.addingTimeInterval(3600))
        let analysis = await engine.analyze(request(deviceB, hasSyncedBefore: false))
        XCTAssertEqual(analysis.decision, .upload(.localNewer))
        XCTAssertEqual(analysis.confirmation, .firstSyncOverwrite(.upload))
    }

    // MARK: - Safety

    func testCorruptRemoteArchiveIsRejectedAndLocalUntouched() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp.addingTimeInterval(-3600))
        harness.server.corruptArchiveDownloads = true

        do {
            _ = try await engine.restore(request(deviceB))
            XCTFail("a corrupted archive must not be restored")
        } catch {
            XCTAssertEqual(error as? SyncError, .cloudVerificationFailed)
        }
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version")
    }

    func testIncompleteManifestBlocksSync() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        // Replace the remote manifest with an incomplete one.
        var manifest = try XCTUnwrap(harness.manifest(gameId: gameId))
        manifest.status = .incomplete
        harness.server.simulateRemoteUpload(gameId: gameId,
                                            manifest: manifest,
                                            archive: Data("unused".utf8))

        do {
            _ = try await engine.restore(request(deviceB))
            XCTFail("an incomplete manifest must block the restore")
        } catch {
            XCTAssertEqual(error as? SyncError, .cloudBackupIncomplete)
        }
    }

    func testLostConnectionDuringRestoreLeavesLocalSavesUntouched() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp.addingTimeInterval(-3600))
        let analysis = await engine.analyze(request(deviceB))
        XCTAssertEqual(analysis.decision.direction, .download)

        harness.server.persistentFault = .network(.notConnectedToInternet)
        do {
            _ = try await engine.restore(request(deviceB), from: analysis)
            XCTFail("a lost connection must not replace the local saves")
        } catch {
            XCTAssertEqual(error as? SyncError, .networkUnavailable)
        }
        harness.server.persistentFault = nil
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version")
    }

    func testRestoreCreatesLocalSafetyBackup() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "remote-version", modified: stamp)
        _ = try await engine.upload(request(deviceA))

        try TestSupport.write(deviceB, "slot.sav", "local-version", modified: stamp.addingTimeInterval(-3600))
        let report = try await engine.restore(request(deviceB))

        XCTAssertNotNil(report.localBackupId)
        let backups = engine.localBackups(gameId: gameId)
        XCTAssertEqual(backups.count, 1)

        let payload = engine.backupManager.payloadURL(backups[0])
        XCTAssertEqual(TestSupport.contents(payload, "slot.sav"), "local-version")

        // And the backup can be restored again.
        _ = try await engine.restoreLocalBackup(request(deviceB), backup: backups[0])
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local-version")
    }

    // MARK: - History

    func testHistoryIsOneCommitPerUploadAndCanBeRestored() async throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: base)
        _ = try await engine.upload(request(deviceA))
        try TestSupport.write(deviceA, "slot.sav", "second", modified: base.addingTimeInterval(86_400))
        _ = try await engine.upload(request(deviceA))

        let history = try await engine.history(request(deviceA))
        XCTAssertEqual(history.count, 2, "every upload is a commit, so both versions are listed")
        XCTAssertEqual(history[0].commitSHA, harness.server.headCommit)

        let older = try XCTUnwrap(history.last)
        XCTAssertNotEqual(older.contentHash, history[0].contentHash)

        let report = try await engine.restoreHistory(request(deviceB), commit: older.commitSHA)
        XCTAssertEqual(report.outcome, .restoredHistory)
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "first")
    }

    func testHistoryPagingReturnsTenAtATime() async throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        for index in 0..<12 {
            let stamp = base.addingTimeInterval(Double(index) * 3600)
            try TestSupport.write(deviceA, "slot.sav", "version-\(index)", modified: stamp)
            _ = try await engine.upload(request(deviceA))
        }

        let firstPage = try await engine.history(request(deviceA), limit: 10, page: 1)
        XCTAssertEqual(firstPage.count, 10)

        let secondPage = try await engine.history(request(deviceA), limit: 10, page: 2)
        XCTAssertEqual(secondPage.count, 2)
        XCTAssertTrue(Set(firstPage.map(\.commitSHA)).isDisjoint(with: Set(secondPage.map(\.commitSHA))))
    }

    func testRestoreFromHistoryChecksumFailureKeepsLocal() async throws {
        let base = TestSupport.date("2026-10-01T10:00:00.000Z")
        try TestSupport.write(deviceA, "slot.sav", "first", modified: base)
        _ = try await engine.upload(request(deviceA))
        try TestSupport.write(deviceA, "slot.sav", "second", modified: base.addingTimeInterval(86_400))
        _ = try await engine.upload(request(deviceA))

        let history = try await engine.history(request(deviceA))
        let older = try XCTUnwrap(history.last)

        try TestSupport.write(deviceB, "slot.sav", "local", modified: base)
        harness.server.corruptArchiveDownloads = true

        do {
            _ = try await engine.restoreHistory(request(deviceB), commit: older.commitSHA)
            XCTFail("a corrupted historical archive must not be applied")
        } catch {
            XCTAssertEqual(error as? SyncError, .cloudVerificationFailed)
        }
        XCTAssertEqual(TestSupport.contents(deviceB, "slot.sav"), "local",
                       "a failed verification must leave the local folder untouched")
    }

    func testUnicodeAndEmptyDirectoriesRoundTrip() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try TestSupport.write(deviceA, "存档/角色 一.sav", "数据", modified: stamp)
        try TestSupport.makeDirectory(deviceA.appendingPathComponent("空目录"))

        _ = try await engine.upload(request(deviceA))
        _ = try await engine.restore(request(deviceB))

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
