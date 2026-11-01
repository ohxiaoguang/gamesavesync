import XCTest
import Foundation

/// Covers the split between the authorised root and the folder that is actually synced.
final class LocalAccessTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private var engine: SyncEngine!
    private var harness: GitHubTestHarness!
    private var documentsA: URL!
    private var documentsB: URL!
    private let gameId = "split-game"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gss-access-\(UUID().uuidString)")
        paths = AppPaths(container: root.appendingPathComponent("app"))
        engine = SyncEngine(paths: paths)
        harness = GitHubTestHarness()
        documentsA = root.appendingPathComponent("A/Documents")
        documentsB = root.appendingPathComponent("B/Documents")
        try TestSupport.makeDirectory(documentsA.appendingPathComponent("saves"))
        try TestSupport.makeDirectory(documentsB.appendingPathComponent("saves"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        harness = nil
    }

    // MARK: - Helpers

    private func game(rootURL: URL, relativePath: String) throws -> Game {
        Game(name: "Split",
             gameId: gameId,
             accessRootBookmark: try DirectoryAccessManager.bookmark(for: rootURL),
             accessRootHint: "Documents",
             syncRelativePath: relativePath)
    }

    private func resolved(_ game: Game) throws -> LocalAccess {
        try LocalAccessResolver.resolve(game: game).access
    }

    private func request(_ access: LocalAccess, hasSyncedBefore: Bool = true) -> SyncRequest {
        harness.makeRequest(gameId: gameId,
                            gameName: "Split",
                            localDirectory: access.syncDirectory,
                            accessRoot: access.root,
                            syncRelativePath: access.relativePath,
                            hasSyncedBefore: hasSyncedBefore)
    }

    private func seedDocuments(_ documents: URL, savesStamp: Date) throws {
        try TestSupport.write(documents, "saves/slot1.sav", "alpha", modified: savesStamp)
        try TestSupport.write(documents, "saves/profile/settings.ini", "beta", modified: savesStamp.addingTimeInterval(-30))
        try TestSupport.write(documents, "cache/blob.bin", "cache-data", modified: savesStamp)
        try TestSupport.write(documents, "config.json", "{\"volume\":1}", modified: savesStamp)
    }

    // MARK: - Path validation

    func testRelativePathNormalisation() {
        XCTAssertEqual(SyncPath.normalize(""), "")
        XCTAssertEqual(SyncPath.normalize("saves"), "saves")
        XCTAssertEqual(SyncPath.normalize("saves//run1"), "saves/run1")
        XCTAssertEqual(SyncPath.normalize("saves "), "saves")
        XCTAssertNil(SyncPath.normalize(" /saves "), "an absolute path stays absolute even with padding")

        XCTAssertNil(SyncPath.normalize(".."))
        XCTAssertNil(SyncPath.normalize("../saves"))
        XCTAssertNil(SyncPath.normalize("saves/../../etc"))
        XCTAssertNil(SyncPath.normalize("/etc/passwd"))
        XCTAssertNil(SyncPath.normalize("saves/."))
        XCTAssertNil(SyncPath.normalize(".gamesavesync-stage-1234"))
    }

    func testResolveRejectsEscapingPaths() throws {
        let game = try game(rootURL: documentsA, relativePath: "saves")
        let resolved = try LocalAccessResolver.resolve(game: game)
        XCTAssertEqual(resolved.access.syncDirectory.standardizedFileURL.path,
                       documentsA.appendingPathComponent("saves").standardizedFileURL.path)

        var escaping = game
        escaping.syncRelativePath = "../B/Documents/saves"
        XCTAssertThrowsError(try LocalAccessResolver.resolve(game: escaping)) { error in
            guard case .invalidSyncPath = (error as? SyncError) else {
                return XCTFail("expected invalidSyncPath, got \(error)")
            }
        }
    }

    func testResolveRejectsSymlinkEscape() throws {
        let outside = root.appendingPathComponent("outside")
        try TestSupport.makeDirectory(outside)
        try TestSupport.write(outside, "secret.sav", "outside", modified: Date())
        let link = documentsA.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        var game = try game(rootURL: documentsA, relativePath: "linked")
        XCTAssertThrowsError(try LocalAccessResolver.resolve(game: game)) { error in
            guard case .invalidSyncPath = (error as? SyncError) else {
                return XCTFail("a symlinked folder must be rejected, got \(error)")
            }
        }

        // A symlink deeper inside an otherwise valid path is rejected too.
        game.syncRelativePath = "saves/linked"
        _ = try? FileManager.default.createSymbolicLink(at: documentsA.appendingPathComponent("saves/linked"),
                                                        withDestinationURL: outside)
        XCTAssertThrowsError(try LocalAccessResolver.resolve(game: game))
    }

    /// The Files-app fallback stores only a relative path, and only for folders inside the grant.
    func testPickedFolderIsConvertedToARelativePathInsideTheRoot() throws {
        let saves = documentsA.appendingPathComponent("saves", isDirectory: true)
        XCTAssertEqual(try SyncPath.relativePath(of: saves, inside: documentsA), "saves")
        XCTAssertEqual(try SyncPath.relativePath(of: documentsA, inside: documentsA), "")

        let deep = saves.appendingPathComponent("slot-1", isDirectory: true)
        try TestSupport.makeDirectory(deep)
        XCTAssertEqual(try SyncPath.relativePath(of: deep, inside: documentsA), "saves/slot-1")

        let sibling = root.appendingPathComponent("other", isDirectory: true)
        try TestSupport.makeDirectory(sibling)
        XCTAssertThrowsError(try SyncPath.relativePath(of: sibling, inside: documentsA))

        // A pick that only looks contained after a symlink hop is still refused.
        let outside = root.appendingPathComponent("outside")
        try TestSupport.makeDirectory(outside)
        let link = documentsA.appendingPathComponent("escapes")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try SyncPath.relativePath(of: link, inside: documentsA))
    }

    // A provider call remains blocked until AFTER the async wait returns. These tests would
    // fail with a task-group race, which waits for the blocked child before leaving its scope.
    func testBrowserTimeoutDoesNotWaitForBlockedProvider() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let finished = expectation(description: "browser reports timeout while provider is blocked")
        let task = Task {
            do {
                _ = try await BrowserFileOperation.run(timeout: .milliseconds(30)) {
                    _ = gate.wait(timeout: .now() + 3)
                    return [URL]()
                }
                XCTFail("expected timeout")
            } catch BrowserFileOperation.Failure.timedOut {
                finished.fulfill()
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
    }

    func testBrowserCancellationDoesNotWaitForBlockedProvider() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = expectation(description: "provider started")
        let finished = expectation(description: "browser wait cancelled")
        let task = Task {
            do {
                _ = try await BrowserFileOperation.run {
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 3)
                    return [URL]()
                }
                XCTFail("expected cancellation")
            } catch is CancellationError {
                finished.fulfill()
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testBrowserReturnsFoldersAndReadErrors() async throws {
        let root = documentsA!
        let children = try await BrowserFileOperation.run {
            try SyncPath.subdirectories(of: root)
        }
        XCTAssertEqual(children.map(\.lastPathComponent), ["saves"])
        do {
            _ = try await BrowserFileOperation.run {
                try SyncPath.subdirectories(of: root.appendingPathComponent("missing"))
            }
            XCTFail("an unreadable folder must not appear empty")
        } catch {
            XCTAssertFalse(error is BrowserFileOperation.Failure)
        }
    }

    // MARK: - Upload scope
    func testUploadOnlyIncludesTheSyncSubfolder() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)

        let access = try resolved(try game(rootURL: documentsA, relativePath: "saves"))
        let report = try await engine.upload(request(access))

        XCTAssertEqual(report.files, 2, "only the two files inside saves may be uploaded")
        let manifest = try XCTUnwrap(harness.manifest(gameId: gameId))
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertEqual(manifest.saveModifiedAt!.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.01)
    }

    func testRestoreLeavesDocumentsAndSiblingsUntouched() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)
        let accessA = try resolved(try game(rootURL: documentsA, relativePath: "saves"))
        _ = try await engine.upload(request(accessA))

        // The second device has its own caches and an older save slot.
        let older = stamp.addingTimeInterval(-3600)
        try TestSupport.write(documentsB, "saves/old.sav", "stale", modified: older)
        try TestSupport.write(documentsB, "cache/blob.bin", "device-b-cache", modified: stamp)
        try TestSupport.write(documentsB, "config.json", "{\"volume\":2}", modified: stamp)

        let accessB = try resolved(try game(rootURL: documentsB, relativePath: "saves"))
        let report = try await engine.restore(request(accessB))
        XCTAssertEqual(report.outcome, .restored)

        XCTAssertEqual(TestSupport.contents(documentsB, "saves/slot1.sav"), "alpha")
        XCTAssertEqual(TestSupport.contents(documentsB, "saves/profile/settings.ini"), "beta")
        XCTAssertNil(TestSupport.contents(documentsB, "saves/old.sav"),
                     "files that are not in the cloud copy must be removed from the sync folder")

        XCTAssertEqual(TestSupport.contents(documentsB, "cache/blob.bin"), "device-b-cache",
                       "sibling folders must not be touched by a restore")
        XCTAssertEqual(TestSupport.contents(documentsB, "config.json"), "{\"volume\":2}",
                       "files next to the sync folder must not be touched by a restore")
        XCTAssertTrue(FileSystem.isDirectory(documentsB), "the authorised folder itself must survive")
    }

    func testSyncFolderCanBeTheAuthorisedRootItself() async throws {
        let stamp = TestSupport.date("2026-10-31T18:00:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)

        let access = try resolved(try game(rootURL: documentsA, relativePath: ""))
        XCTAssertEqual(access.syncDirectory.standardizedFileURL.path, documentsA.standardizedFileURL.path)

        let report = try await engine.upload(request(access))
        XCTAssertEqual(report.files, 4, "choosing the root syncs everything inside it")

        let accessB = try resolved(try game(rootURL: documentsB, relativePath: ""))
        try TestSupport.write(documentsB, "saves/old.sav", "stale", modified: stamp.addingTimeInterval(-60))
        let restored = try await engine.restore(request(accessB))
        XCTAssertEqual(restored.outcome, .restored)
        XCTAssertTrue(FileSystem.isDirectory(documentsB), "replacing the root must keep the root folder itself")
        XCTAssertEqual(TestSupport.contents(documentsB, "config.json"), "{\"volume\":1}")
    }

    // MARK: - A recreated save folder

    func testSaveFolderCanBeRecreatedAtTheSamePath() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)
        let game = try game(rootURL: documentsA, relativePath: "saves")
        let first = try resolved(game)

        // The game deletes and recreates the folder while GameSaveSync is closed.
        try FileManager.default.removeItem(at: first.syncDirectory)
        try TestSupport.makeDirectory(first.syncDirectory)
        try TestSupport.write(documentsA, "saves/fresh.sav", "recreated", modified: stamp.addingTimeInterval(120))

        let second = try resolved(game)
        XCTAssertEqual(second.syncDirectory.standardizedFileURL.path,
                       first.syncDirectory.standardizedFileURL.path)
        XCTAssertEqual(second.root.standardizedFileURL.path, first.root.standardizedFileURL.path,
                       "the grant still points at Documents, not at the recreated folder")

        let report = try await engine.upload(request(second))
        XCTAssertEqual(report.outcome, .uploaded)
        XCTAssertEqual(try XCTUnwrap(harness.manifest(gameId: gameId)).fileCount, 1)
    }

    func testMissingSaveFolderIsReportedAsMissingNotAsLostAccess() async throws {
        let game = try game(rootURL: documentsA, relativePath: "saves")
        try FileManager.default.removeItem(at: documentsA.appendingPathComponent("saves"))

        let access = try resolved(game)
        let analysis = await engine.analyze(request(access))
        guard case .blocked(let error) = analysis.decision else {
            return XCTFail("expected a blocked decision, got \(analysis.decision)")
        }
        XCTAssertEqual(error, .syncFolderMissing("saves"))
        XCTAssertTrue(FileSystem.isDirectory(documentsA), "the authorised root is still readable")
    }

    func testMissingSaveFolderBecomesADownloadInsteadOfAnError() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)
        let accessA = try resolved(try game(rootURL: documentsA, relativePath: "saves"))
        _ = try await engine.upload(request(accessA))

        try FileManager.default.removeItem(at: documentsB.appendingPathComponent("saves"))
        let accessB = try resolved(try game(rootURL: documentsB, relativePath: "saves"))
        let analysis = await engine.analyze(request(accessB))

        XCTAssertEqual(analysis.localError, .syncFolderMissing("saves"))
        XCTAssertEqual(analysis.decision, .download(.localEmpty),
                       "a missing sync folder must be fetched, not reported as lost access")
    }

    func testMissingSaveFolderIsFilledByRestore() async throws {
        let stamp = TestSupport.date("2026-10-31T20:30:00.000Z")
        try seedDocuments(documentsA, savesStamp: stamp)
        let accessA = try resolved(try game(rootURL: documentsA, relativePath: "saves"))
        _ = try await engine.upload(request(accessA))

        try FileManager.default.removeItem(at: documentsB.appendingPathComponent("saves"))
        let accessB = try resolved(try game(rootURL: documentsB, relativePath: "saves"))
        let report = try await engine.restore(request(accessB))

        XCTAssertEqual(report.outcome, .restored)
        XCTAssertEqual(TestSupport.contents(documentsB, "saves/slot1.sav"), "alpha")
        XCTAssertTrue(FileSystem.isDirectory(documentsB))
    }

    // MARK: - Broken grants

    func testUnreadableBookmarkIsReportedAsLostAccess() {
        let broken = Game(name: "Broken",
                          gameId: gameId,
                          accessRootBookmark: Data("not a bookmark".utf8),
                          accessRootHint: "Documents",
                          syncRelativePath: "saves")
        XCTAssertThrowsError(try LocalAccessResolver.resolve(game: broken)) { error in
            guard case .accessRootUnavailable = (error as? SyncError) else {
                return XCTFail("expected accessRootUnavailable, got \(error)")
            }
        }
    }

    func testConfigurationSurvivesARestart() throws {
        let store = ConfigurationStore(paths: paths)
        let original = try game(rootURL: documentsA, relativePath: "saves")
        try store.saveGames([original])

        let loaded = store.loadGames()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].syncRelativePath, "saves")
        XCTAssertFalse(loaded[0].accessRootIsLegacy)

        let resolved = try LocalAccessResolver.resolve(game: loaded[0])
        XCTAssertEqual(resolved.access.syncDirectory.standardizedFileURL.path,
                       documentsA.appendingPathComponent("saves").standardizedFileURL.path,
                       "the bookmark must still resolve after a relaunch")
    }

    // MARK: - Legacy configurations

    func testLegacyConfigurationIsKeptAndMarked() throws {
        let bookmark = try DirectoryAccessManager.bookmark(for: documentsA.appendingPathComponent("saves"))
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Old Game",
            "gameId": "old-game",
            "localFolderBookmark": bookmark.base64EncodedString(),
            "localFolderHint": "Documents/saves",
            "createdAt": "2026-10-01T10:00:00Z",
            "updatedAt": "2026-10-01T10:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacy])
        let decoded = try Coders.decode([Game].self, from: data)

        XCTAssertEqual(decoded.count, 1, "an old configuration must never be dropped")
        let game = decoded[0]
        XCTAssertEqual(game.name, "Old Game")
        XCTAssertEqual(game.accessRootIsLegacy, true)
        XCTAssertEqual(game.syncRelativePath, "")
        XCTAssertEqual(game.accessRootBookmark, bookmark, "the existing grant has to be preserved")

        // It keeps working as before: the old grant pointed straight at the save folder.
        let resolved = try LocalAccessResolver.resolve(game: game)
        XCTAssertEqual(resolved.access.syncDirectory.standardizedFileURL.path,
                       documentsA.appendingPathComponent("saves").standardizedFileURL.path)

        // Re-encoding writes the new fields, so the record is upgraded from now on.
        let roundTrip = try Coders.decode([Game].self, from: try Coders.encode([game]))
        XCTAssertEqual(roundTrip[0].syncRelativePath, "")
        XCTAssertEqual(roundTrip[0].accessRootBookmark, bookmark)
    }

    func testDuplicateGameIdsAreNotCreatedByTheUpgrade() throws {
        let store = ConfigurationStore(paths: paths)
        var game = try game(rootURL: documentsA, relativePath: "saves")
        try store.saveGames([game])

        // Saving again must update the same record, not append a second one.
        var loaded = store.loadGames()
        loaded[0].syncRelativePath = "saves"
        loaded[0].updatedAt = Date()
        try store.saveGames(loaded)

        let reloaded = store.loadGames()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].gameId, game.gameId)
        game.id = reloaded[0].id
        XCTAssertEqual(reloaded[0].id, game.id)
    }
}
