import XCTest
import Foundation

// MARK: - Token storage

final class GitHubCredentialTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryGitHubTokenStore()
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(try store.readToken())

        try store.saveToken("  github_pat_abc  ")
        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(try store.readToken(), "github_pat_abc", "the token is trimmed before storage")

        try store.saveToken("github_pat_def")
        XCTAssertEqual(try store.readToken(), "github_pat_def", "saving again replaces the token")

        try store.deleteToken()
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(try store.readToken())
    }

    func testEmptyTokenIsRejected() {
        let store = InMemoryGitHubTokenStore()
        XCTAssertThrowsError(try store.saveToken("   ")) { error in
            XCTAssertEqual(error as? GitHubTokenStoreError, .emptyToken)
        }
    }

    func testKeychainStorePersistsAndDeletes() throws {
        let service = "com.gamesavesync.tests.\(UUID().uuidString)"
        let store = KeychainGitHubTokenStore(service: service, account: "access-token")
        defer { try? store.deleteToken() }

        do {
            XCTAssertNil(try store.readToken())
            try store.saveToken("github_pat_keychain")
            XCTAssertEqual(try store.readToken(), "github_pat_keychain")

            // A second instance with the same identifiers sees the same item, as on relaunch.
            let reopened = KeychainGitHubTokenStore(service: service, account: "access-token")
            XCTAssertEqual(try reopened.readToken(), "github_pat_keychain")

            try store.saveToken("github_pat_replaced")
            XCTAssertEqual(try reopened.readToken(), "github_pat_replaced")

            try store.deleteToken()
            XCTAssertNil(try store.readToken())
        } catch let error as GitHubTokenStoreError {
            throw XCTSkip("The Keychain is not available in this environment: \(error)")
        }
    }

    func testTokenNeverLandsInSettings() throws {
        // AppSettings has no token field at all: the only place a token can live is the Keychain.
        var settings = AppSettings()
        settings.localBackupRetention = 4
        let json = String(decoding: try Coders.encode(settings), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("github_pat"))
    }
}

// MARK: - Connection

final class GitHubConnectionTests: XCTestCase {
    private var harness: GitHubTestHarness!

    override func setUp() {
        harness = GitHubTestHarness()
    }

    override func tearDown() {
        harness = nil
    }

    func testEmptyRepositoryReportsNoCommit() async throws {
        let report = try await harness.manager.verifyConnection()
        XCTAssertTrue(report.isPrivate)
        XCTAssertTrue(report.canWrite)
        XCTAssertTrue(report.isEmptyRepository)
        XCTAssertEqual(report.defaultBranch, "main")
        XCTAssertEqual(report.account, "ohxiaoguang")
    }

    func testConnectionRejectsPublicRepository() async {
        harness.server.isPrivate = false
        do {
            _ = try await harness.manager.verifyConnection()
            XCTFail("a public repository must be refused")
        } catch {
            XCTAssertEqual(error as? SyncError, .gitHubRepositoryNotPrivate)
        }
    }

    func testConnectionReportsMissingRepository() async {
        let other = GitHubTestHarness(owner: "someone-else", name: "saves")
        do {
            _ = try await other.manager.verifyConnection()
            XCTFail("a repository that does not exist must be reported")
        } catch {
            guard case .gitHubRepositoryNotFound = (error as? SyncError) else {
                return XCTFail("expected gitHubRepositoryNotFound, got \(error)")
            }
        }
    }

    func testConnectionWithInvalidTokenIsReportedAsAuthenticationFailure() async {
        harness.server.acceptedToken = "another-token"
        do {
            _ = try await harness.manager.verifyConnection()
            XCTFail("a rejected token must be reported")
        } catch {
            guard case .gitHubAuthFailed = (error as? SyncError) else {
                return XCTFail("expected gitHubAuthFailed, got \(error)")
            }
        }
    }

    func testConnectionReportsReadOnlyToken() async throws {
        harness.server.canPush = false
        let report = try await harness.manager.verifyConnection()
        XCTAssertTrue(report.canRead)
        XCTAssertFalse(report.canWrite, "the settings screen must be able to say the token is read only")
    }

    func testPermissionDeniedIsReported() async {
        harness.server.persistentFault = .status(403, "Resource not accessible by personal access token")
        do {
            _ = try await harness.manager.head()
            XCTFail("403 must not be swallowed")
        } catch {
            guard case .gitHubPermissionDenied = (error as? SyncError) else {
                return XCTFail("expected gitHubPermissionDenied, got \(error)")
            }
        }
    }

    func testRateLimitIsReportedAfterBoundedRetries() async {
        harness.server.persistentFault = .rateLimited
        do {
            _ = try await harness.manager.head()
            XCTFail("a rate limited request must fail")
        } catch {
            guard case .gitHubRateLimited = (error as? SyncError) else {
                return XCTFail("expected gitHubRateLimited, got \(error)")
            }
        }
        let attempts = harness.server.requestLog.filter { $0.hasPrefix("GET") }.count
        XCTAssertLessThanOrEqual(attempts, 3, "retries must be bounded, not endless")
    }

    func testUnprocessableResponseIsReported() async {
        harness.server.persistentFault = .status(422, "Validation Failed")
        do {
            _ = try await harness.manager.head()
            XCTFail("422 must not be swallowed")
        } catch {
            XCTAssertEqual(error as? SyncError, .gitHubUnprocessable)
        }
    }

    func testMissingBranchIsReported() async throws {
        let other = GitHubTestHarness(branch: "trunk")
        // Give the repository a commit on `main` so it is not "empty".
        other.server.simulateRemoteUpload(gameId: "g", manifest: Self.sampleManifest(gameId: "g"), archive: Data("zip".utf8))
        do {
            _ = try await other.manager.head()
            XCTFail("a missing branch must not be treated as an empty repository")
        } catch {
            XCTAssertEqual(error as? SyncError, .gitHubBranchMissing("trunk"))
        }
    }

    static func sampleManifest(gameId: String, hash: String = "hash") -> CloudManifest {
        CloudManifest(gameId: gameId,
                      gameName: gameId,
                      versionId: "v-\(hash)",
                      saveModifiedAt: Date(),
                      saveWasEmpty: false,
                      backupCreatedAt: Date(),
                      sourceDevice: "Device",
                      sourceAppVersion: "1.0",
                      contentHash: hash,
                      fileCount: 1,
                      totalBytes: 3,
                      archiveBytes: 3,
                      archiveSHA256: "sha")
    }
}

// MARK: - Uploading through the Git Database API

final class GitHubUploadTests: XCTestCase {
    private var harness: GitHubTestHarness!
    private var work: URL!

    override func setUpWithError() throws {
        harness = GitHubTestHarness()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("gss-gh-\(UUID().uuidString)")
        try TestSupport.makeDirectory(work)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
        harness = nil
    }

    private func archive(_ contents: String, named name: String = "save.zip") throws -> URL {
        let url = work.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func manifest(_ hash: String, gameId: String = "game-a") -> CloudManifest {
        GitHubConnectionTests.sampleManifest(gameId: gameId, hash: hash)
    }

    /// A manifest whose archive metadata matches the given file, as the engine always builds it.
    private func manifest(_ hash: String, archiveAt url: URL) -> CloudManifest {
        var manifest = manifest(hash)
        let data = try? Data(contentsOf: url)
        manifest.archiveBytes = data?.count ?? 0
        manifest.archiveSHA256 = data.map { Hashing.sha256Hex($0) } ?? ""
        return manifest
    }

    func testEmptyRepositoryIsInitialisedBeforeTheFirstSaveCommit() async throws {
        XCTAssertTrue(harness.server.repositoryIsEmpty)

        let result = try await harness.manager.upload(manifest: manifest("h1"),
                                                      archive: try archive("abc"),
                                                      precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                      progress: nil)

        XCTAssertFalse(result.unchanged)
        XCTAssertEqual(harness.server.headCommit, result.commit)
        XCTAssertEqual(harness.manifest(gameId: "game-a")?.contentHash, "h1")
        XCTAssertNotNil(harness.server.archiveData(at: result.commit, gameId: "game-a"),
                        "the archive must be in the same commit as its manifest")

        // GitHub refuses to create a reference in a repository without any branch, so the first
        // commit has to come from the contents endpoint.
        XCTAssertTrue(harness.server.requestLog.contains { $0.hasPrefix("PUT ") && $0.contains("/contents/") },
                      "an empty repository must be initialised through the contents endpoint")
        XCTAssertFalse(harness.server.requestLog.contains { $0.hasPrefix("POST ") && $0.hasSuffix("/git/refs") },
                       "a reference must not be created while the repository is empty")
        XCTAssertNotNil(harness.server.fileContents(at: result.commit, path: GitHubLayout.initialisationPath))
    }

    func testInitialUploadLeavesExistingRepositoryFilesAlone() async throws {
        harness.server.seedRepository(files: ["README.md": "# My save archives\n", "notes/todo.txt": "keep me"])

        let result = try await harness.manager.upload(manifest: manifest("h1"),
                                                      archive: try archive("abc"),
                                                      precondition: UploadPrecondition(baseCommit: harness.server.headCommit, remoteContentHash: nil),
                                                      progress: nil)

        XCTAssertEqual(harness.server.fileContents(at: result.commit, path: "README.md"), "# My save archives\n")
        XCTAssertEqual(harness.server.fileContents(at: result.commit, path: "notes/todo.txt"), "keep me")
        XCTAssertNil(harness.server.fileContents(at: result.commit, path: GitHubLayout.initialisationPath),
                     "a repository that already has commits must not be initialised again")
        XCTAssertNil(harness.server.requestLog.first { $0.hasPrefix("PUT ") && $0.contains("/contents/") })
    }

    func testConfiguredBranchIsCreatedWhenItIsNotTheDefaultBranch() async throws {
        // The user keeps "main" as the default branch but stores saves on another one.
        harness.server.defaultBranch = "main"
        let manager = harness.makeManager(branch: "archives")

        let result = try await manager.upload(manifest: manifest("h1"),
                                              archive: try archive("abc"),
                                              precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                              progress: nil)

        let archives = try XCTUnwrap(harness.server.branchHead("archives"))
        XCTAssertEqual(archives, result.commit)
        XCTAssertEqual(harness.server.manifest(at: archives, gameId: "game-a")?.contentHash, "h1")
        XCTAssertNotNil(harness.server.branchHead("main"), "the default branch stays as GitHub created it")
        XCTAssertNil(harness.server.manifest(at: try XCTUnwrap(harness.server.branchHead("main")), gameId: "game-a"),
                     "the save must only land on the configured branch")
    }

    func testTwoDevicesCanInitialiseTheSameEmptyRepository() async throws {
        let other = harness.makeManager()

        async let first = harness.manager.upload(manifest: manifest("h1", gameId: "game-a"),
                                                 archive: try archive("first"),
                                                 precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                 progress: nil)
        async let second = other.upload(manifest: manifest("h2", gameId: "game-b"),
                                        archive: try archive("second"),
                                        precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                        progress: nil)
        let results = try await [first, second]

        XCTAssertTrue([results[0].commit, results[1].commit].contains(harness.server.headCommit ?? ""),
                      "the branch must end on one of the two commits")
        XCTAssertEqual(harness.manifest(gameId: "game-a")?.contentHash, "h1")
        XCTAssertEqual(harness.manifest(gameId: "game-b")?.contentHash, "h2",
                       "the second device must not lose its game while initialising")
    }

    func testSecondCommitIsFastForward() async throws {
        let first = try await harness.manager.upload(manifest: manifest("h1"),
                                                     archive: try archive("abc"),
                                                     precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                     progress: nil)
        let second = try await harness.manager.upload(manifest: manifest("h2"),
                                                      archive: try archive("abcd"),
                                                      precondition: UploadPrecondition(baseCommit: first.commit, remoteContentHash: "h1"),
                                                      progress: nil)
        XCTAssertNotEqual(first.commit, second.commit)
        XCTAssertEqual(harness.server.headCommit, second.commit)
    }

    func testSameContentIsNotReuploaded() async throws {
        let first = try await harness.manager.upload(manifest: manifest("h1"),
                                                     archive: try archive("abc"),
                                                     precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                     progress: nil)
        let baseline = harness.server.commitLog.count
        let second = try await harness.manager.upload(manifest: manifest("h1"),
                                                      archive: try archive("abc"),
                                                      precondition: UploadPrecondition(baseCommit: first.commit, remoteContentHash: "h1"),
                                                      progress: nil)
        XCTAssertTrue(second.unchanged)
        XCTAssertEqual(second.commit, first.commit)
        XCTAssertEqual(harness.server.commitLog.count, baseline, "no duplicate commit may be created")
    }

    func testUnrelatedCommitIsRebasedInsteadOfFailing() async throws {
        let first = try await harness.manager.upload(manifest: manifest("h1"),
                                                     archive: try archive("abc"),
                                                     precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                     progress: nil)

        // Another device publishes a different game between our read and our ref update.
        harness.server.beforeRefUpdate = { server in
            server.simulateRemoteUpload(gameId: "game-b",
                                        manifest: GitHubConnectionTests.sampleManifest(gameId: "game-b", hash: "other"),
                                        archive: Data("other".utf8))
        }

        let second = try await harness.manager.upload(manifest: manifest("h2"),
                                                      archive: try archive("abcd"),
                                                      precondition: UploadPrecondition(baseCommit: first.commit, remoteContentHash: "h1"),
                                                      progress: nil)

        XCTAssertEqual(harness.server.headCommit, second.commit)
        XCTAssertEqual(harness.manifest(gameId: "game-a")?.contentHash, "h2")
        XCTAssertNotNil(harness.manifest(gameId: "game-b"), "the other device's game must survive the rebase")
    }

    func testConcurrentUploadOfTheSameGameIsNeverOverwritten() async throws {
        let first = try await harness.manager.upload(manifest: manifest("h1"),
                                                     archive: try archive("abc"),
                                                     precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                     progress: nil)

        harness.server.beforeRefUpdate = { server in
            server.simulateRemoteUpload(gameId: "game-a",
                                        manifest: GitHubConnectionTests.sampleManifest(gameId: "game-a", hash: "from-other-device"),
                                        archive: Data("other".utf8))
        }

        do {
            _ = try await harness.manager.upload(manifest: manifest("mine"),
                                                 archive: try archive("mine"),
                                                 precondition: UploadPrecondition(baseCommit: first.commit, remoteContentHash: "h1"),
                                                 progress: nil)
            XCTFail("a newer version from another device must stop the upload")
        } catch {
            XCTAssertEqual(error as? SyncError, .gitHubRemoteChanged)
        }

        XCTAssertEqual(harness.manifest(gameId: "game-a")?.contentHash, "from-other-device",
                       "the other device's version must still be the one on the branch")
    }

    func testUncertainTimeoutDoesNotCreateASecondCommit() async throws {
        harness.server.seedRepository()
        let base = try XCTUnwrap(harness.server.headCommit)
        let baseline = harness.server.commitLog.count
        harness.server.failRefUpdateAfterApplying = true

        let result = try await harness.manager.upload(manifest: manifest("h1"),
                                                      archive: try archive("abc"),
                                                      precondition: UploadPrecondition(baseCommit: base, remoteContentHash: nil),
                                                      progress: nil)
        XCTAssertFalse(result.unchanged)
        XCTAssertEqual(harness.server.commitLog.count, baseline + 1)
        XCTAssertEqual(harness.server.headCommit, result.commit,
                       "the commit that landed despite the timeout must be recognised")

        // A retry after the timeout must not add a commit.
        let retry = try await harness.manager.upload(manifest: manifest("h1"),
                                                     archive: try archive("abc"),
                                                     precondition: UploadPrecondition(baseCommit: result.commit, remoteContentHash: "h1"),
                                                     progress: nil)
        XCTAssertTrue(retry.unchanged)
        XCTAssertEqual(harness.server.commitLog.count, baseline + 1)
    }

    func testArchiveAboveTheGitHubLimitIsRejectedBeforeAnyRequest() async throws {
        let url = work.appendingPathComponent("huge.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(GitHubLimits.maximumBytes) + 1)
        try handle.close()

        do {
            _ = try await harness.manager.upload(manifest: manifest("h1"),
                                                 archive: url,
                                                 precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                 progress: nil)
            XCTFail("an archive over 100 MiB must be refused")
        } catch {
            guard case .gitHubFileTooLarge(let bytes, let limit) = (error as? SyncError) else {
                return XCTFail("expected gitHubFileTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(bytes, limit)
            XCTAssertEqual(limit, 100 << 20)
        }
        XCTAssertTrue(harness.server.requestLog.isEmpty, "the size must be checked before uploading")
    }

    func testLostConnectionDuringUploadCreatesNoCommit() async throws {
        harness.server.seedRepository()
        let base = try XCTUnwrap(harness.server.headCommit)
        harness.server.persistentFault = .network(.notConnectedToInternet)

        do {
            _ = try await harness.manager.upload(manifest: manifest("h1"),
                                                 archive: try archive("abc"),
                                                 precondition: UploadPrecondition(baseCommit: base, remoteContentHash: nil),
                                                 progress: nil)
            XCTFail("an upload without a connection must fail")
        } catch {
            XCTAssertEqual(error as? SyncError, .networkUnavailable)
        }
        harness.server.persistentFault = nil
        XCTAssertEqual(harness.server.headCommit, base, "the branch must not move")
        XCTAssertNil(harness.manifest(gameId: "game-a"))
    }

    func testDownloadUsesTheRequestedCommit() async throws {
        let firstArchive = try archive("first-bytes")
        let secondArchive = try archive("second-bytes")
        let first = try await harness.manager.upload(manifest: manifest("h1", archiveAt: firstArchive),
                                                     archive: firstArchive,
                                                     precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                                     progress: nil)
        _ = try await harness.manager.upload(manifest: manifest("h2", archiveAt: secondArchive),
                                             archive: secondArchive,
                                             precondition: UploadPrecondition(baseCommit: first.commit, remoteContentHash: "h1"),
                                             progress: nil)

        let directory = work.appendingPathComponent("download", isDirectory: true)
        let old = try await harness.manager.download(gameId: "game-a", commit: first.commit, into: directory)
        XCTAssertEqual(try String(contentsOf: old.archiveURL, encoding: .utf8), "first-bytes")
        XCTAssertEqual(old.manifest.contentHash, "h1")

        let head = try XCTUnwrap(harness.server.headCommit)
        let current = try await harness.manager.download(gameId: "game-a", commit: head, into: directory)
        XCTAssertEqual(try String(contentsOf: current.archiveURL, encoding: .utf8), "second-bytes")
    }

    func testDownloadRejectsAnArchiveThatDoesNotMatchItsManifest() async throws {
        let url = try archive("abc")
        _ = try await harness.manager.upload(manifest: manifest("h1", archiveAt: url),
                                             archive: url,
                                             precondition: UploadPrecondition(baseCommit: nil, remoteContentHash: nil),
                                             progress: nil)
        harness.server.corruptArchiveDownloads = true
        let directory = work.appendingPathComponent("download", isDirectory: true)
        do {
            _ = try await harness.manager.download(gameId: "game-a",
                                                   commit: try XCTUnwrap(harness.server.headCommit),
                                                   into: directory)
            XCTFail("a corrupted blob must be rejected")
        } catch {
            XCTAssertEqual(error as? SyncError, .cloudVerificationFailed)
        }
    }
}

// MARK: - Repository validation and configuration migration

final class GitHubConfigurationTests: XCTestCase {
    func testNoRepositoryIsConfiguredByDefault() {
        let settings = AppSettings()
        XCTAssertFalse(settings.repository.isConfigured)
        XCTAssertFalse(settings.repository.isValid)
        XCTAssertEqual(settings.gitHubOwner, "", "the source repository must never be a default")
        XCTAssertEqual(settings.gitHubBranch, "main")
    }

    func testRepositoryValidation() {
        XCTAssertTrue(GitHubRepository(owner: "ohxiaoguang", name: "game-saves", branch: "main").isValid)
        XCTAssertTrue(GitHubRepository(owner: "a", name: "b", branch: "feature/saves").isValid)

        XCTAssertFalse(GitHubRepository(owner: "", name: "saves", branch: "main").isValid)
        XCTAssertTrue(GitHubRepository(owner: "ohxiaoguang", name: "saves", branch: "").isValid,
                       "an empty branch falls back to main")
        XCTAssertFalse(GitHubRepository(owner: "-bad", name: "saves", branch: "main").isValid)
        XCTAssertFalse(GitHubRepository(owner: "owner", name: "sa ves", branch: "main").isValid)
        XCTAssertFalse(GitHubRepository(owner: "owner", name: "saves", branch: "../main").isValid)
        XCTAssertFalse(GitHubRepository(owner: "owner", name: "saves", branch: "feature..x").isValid)
    }

    func testIdentifierDistinguishesRepositories() {
        let first = GitHubRepository(owner: "Owner", name: "Saves", branch: "main")
        let second = GitHubRepository(owner: "owner", name: "saves", branch: "main")
        let otherBranch = GitHubRepository(owner: "owner", name: "saves", branch: "dev")

        XCTAssertEqual(first.identifier, second.identifier, "GitHub names are case insensitive")
        XCTAssertNotEqual(first.identifier, otherBranch.identifier)
    }

    func testLegacySettingsAreMigratedWithoutLosingChoices() throws {
        let legacy: [String: Any] = [
            "cloudRootBookmark": Data("bookmark".utf8).base64EncodedString(),
            "cloudRootHint": "iCloud Drive/GameSaveSync",
            "cloudRootIsICloud": true,
            "cloudSubpath": "GameSaveSync",
            "historyRetention": 7,
            "language": "chinese",
            "deviceName": "zzg 的 iPhone"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let settings = try Coders.decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.localBackupRetention, 7, "the old history count becomes the local backup count")
        XCTAssertEqual(settings.language, .chinese)
        XCTAssertEqual(settings.deviceName, "zzg 的 iPhone")
        XCTAssertFalse(settings.repository.isConfigured)
    }

    func testSettingsWithoutLegacyKeysStillDecode() throws {
        let data = try JSONSerialization.data(withJSONObject: ["language": "english"])
        let settings = try Coders.decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.localBackupRetention, 3)
        XCTAssertEqual(settings.gitHubBranch, "main")
        XCTAssertEqual(settings.language, .english)
    }

    func testLegacyGamesJSONKeepsEveryGame() throws {
        // Written by the iCloud build: an unknown sync kind and iCloud-only fields must not make
        // the file undecodable, which would drop every game configuration.
        let legacy: [[String: Any]] = [[
            "id": UUID().uuidString,
            "name": "Darkest Dungeon",
            "gameId": "darkest-dungeon",
            "accessRootBookmark": Data("bookmark".utf8).base64EncodedString(),
            "accessRootHint": "Documents",
            "syncRelativePath": "saves",
            "accessRootIsLegacy": false,
            "lastCloudModified": "2026-10-01T10:00:00.000Z",
            "lastSync": ["kind": "uploadedPendingICloud", "date": "2026-10-01T10:05:00.000Z"],
            "createdAt": "2026-09-01T10:00:00.000Z",
            "updatedAt": "2026-10-01T10:05:00.000Z"
        ]]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let games = try Coders.decode([Game].self, from: data)

        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games[0].gameId, "darkest-dungeon")
        XCTAssertEqual(games[0].lastSync?.kind, .uploaded, "the legacy kind is mapped, not dropped")
        XCTAssertNil(games[0].syncedRemoteId)
        XCTAssertFalse(games[0].hasSynced(with: GitHubRepository(owner: "o", name: "r").identifier),
                       "an iCloud sync record must never count as a GitHub sync")
    }

    func testSyncKindDecodingIsTolerant() throws {
        for raw in ["uploaded", "restored", "restoredHistory", "upToDate", "failed"] {
            let data = try JSONSerialization.data(withJSONObject: ["kind": raw, "date": "2026-10-01T10:05:00.000Z"])
            XCTAssertNoThrow(try Coders.decode(SyncRecord.self, from: data), "\(raw) must decode")
        }
        let unknown = try JSONSerialization.data(withJSONObject: ["kind": "somethingNew", "date": "2026-10-01T10:05:00.000Z"])
        XCTAssertNoThrow(try Coders.decode(SyncRecord.self, from: unknown))
    }

    func testGameRecordsWhichRemoteItSyncedWith() throws {
        var game = Game(name: "G", gameId: "g", accessRootBookmark: Data("b".utf8), accessRootHint: "Documents")
        let remote = GitHubRepository(owner: "owner", name: "saves").identifier
        XCTAssertFalse(game.hasSynced(with: remote))

        game.lastSync = SyncRecord(kind: .uploaded)
        game.syncedRemoteId = remote
        XCTAssertTrue(game.hasSynced(with: remote))
        XCTAssertFalse(game.hasSynced(with: GitHubRepository(owner: "owner", name: "other").identifier))
        XCTAssertFalse(game.hasSynced(with: GitHubRepository(owner: "owner", name: "saves", branch: "dev").identifier))
    }

    func testDefaultRepositoryIsNeverTheSourceRepository() {
        let settings = AppSettings()
        XCTAssertNotEqual(settings.repository.fullName.lowercased(), "ohxiaoguang/gamesavesync")
    }
}
