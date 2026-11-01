import XCTest
import Foundation

enum TestSupport {
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @discardableResult
    static func write(_ root: URL, _ path: String, _ contents: String, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    static func write(_ root: URL, _ path: String, data: Data, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func contents(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func modificationDate(_ root: URL, _ path: String) -> Date? {
        try? root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func relativeFileList(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var paths: [String] = []
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                paths.append(SaveScanner.relativePath(of: item, rootPath: root.standardizedFileURL.path))
            }
        }
        return paths.sorted()
    }
}

/// Wires the production GitHub stack to the in-memory mock server.
///
/// These are the same `GitHubAPIClient` and `GitHubStorageManager` the app ships; only the
/// transport is replaced, so the tests exercise the real request building, error mapping, commit
/// construction and conflict handling.
final class GitHubTestHarness {
    let server: MockGitHubServer
    let session: URLSession
    let repository: GitHubRepository
    let manager: GitHubStorageManager
    private let apiConfiguration: GitHubAPIClient.Configuration

    init(owner: String = "ohxiaoguang", name: String = "game-saves", branch: String = "main") {
        let server = MockGitHubServer()
        self.server = server
        self.repository = GitHubRepository(owner: owner, name: name, branch: branch)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        self.session = session

        var apiConfiguration = GitHubAPIClient.Configuration()
        apiConfiguration.baseURL = server.baseURL
        apiConfiguration.maximumRetries = 2
        apiConfiguration.retryDelay = 0.01
        self.apiConfiguration = apiConfiguration
        self.manager = GitHubStorageManager(repository: repository,
                                            token: MockGitHubServer.token,
                                            session: session,
                                            configuration: apiConfiguration)
    }

    /// A second client for the same repository, as another device would have.
    func makeManager(branch: String? = nil) -> GitHubStorageManager {
        GitHubStorageManager(repository: GitHubRepository(owner: repository.trimmedOwner,
                                                          name: repository.trimmedName,
                                                          branch: branch ?? repository.trimmedBranch),
                             token: MockGitHubServer.token,
                             session: session,
                             configuration: apiConfiguration)
    }

    func makeRequest(gameId: String,
                     gameName: String = "Test Game",
                     localDirectory: URL,
                     accessRoot: URL? = nil,
                     syncRelativePath: String = "",
                     hasSyncedBefore: Bool = true,
                     retention: Int = 3,
                     remote: (any RemoteStore)? = nil) -> SyncRequest {
        SyncRequest(gameId: gameId,
                    gameName: gameName,
                    localDirectory: localDirectory,
                    accessRoot: accessRoot,
                    syncRelativePath: syncRelativePath,
                    remote: remote ?? manager,
                    localBackupRetention: retention,
                    deviceName: "TestDevice",
                    appVersion: "1.0",
                    hasSyncedBefore: hasSyncedBefore)
    }

    /// Manifest currently on the remote branch, if any.
    func manifest(gameId: String, branch: String? = nil) -> CloudManifest? {
        guard let commit = server.branchHead(branch ?? repository.trimmedBranch) else { return nil }
        return server.manifest(at: commit, gameId: gameId)
    }

    func archiveData(gameId: String, branch: String? = nil) -> Data? {
        guard let commit = server.branchHead(branch ?? repository.trimmedBranch) else { return nil }
        return server.archiveData(at: commit, gameId: gameId)
    }
}
