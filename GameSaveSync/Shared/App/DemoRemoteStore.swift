import Foundation

/// File-system backed `RemoteStore` used **only** when the app is launched with `-GSSDemoSeed`.
///
/// The UI tests and the manual layout checks need a remote that works offline; the shipping code
/// path always talks to GitHub. Nothing in the normal app ever constructs this type.
///
/// It deliberately mimics git: every upload creates one commit that contains the game's manifest
/// and archive, commits form a chain, and a game's manifest is resolved by walking back from the
/// requested commit.
final class DemoRemoteStore: RemoteStore, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var identifier: String { "demo:local@main" }
    var displayName: String { "Demo" }

    func verifyConnection() async throws -> GitHubConnectionReport {
        GitHubConnectionReport(repository: GitHubRepository(owner: "demo", name: "demo", branch: "main"),
                               account: "demo",
                               isPrivate: true,
                               canRead: true,
                               canWrite: true,
                               defaultBranch: "main",
                               isEmptyRepository: false)
    }

    // MARK: - Layout

    private var headFile: URL { root.appendingPathComponent("HEAD") }

    private func commitDirectory(_ commit: String) -> URL {
        root.appendingPathComponent("commits", isDirectory: true).appendingPathComponent(commit, isDirectory: true)
    }

    private func readHead() -> String? {
        guard let data = try? Data(contentsOf: headFile) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func parent(of commit: String) -> String? {
        let url = commitDirectory(commit).appendingPathComponent("parent")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func manifest(at commit: String, gameId: String) -> CloudManifest? {
        let url = commitDirectory(commit)
            .appendingPathComponent(gameId, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Coders.decode(CloudManifest.self, from: data)
    }

    /// Walks the commit chain back until a commit that contains this game is found.
    private func resolveManifest(gameId: String, from commit: String?) -> (commit: String, manifest: CloudManifest)? {
        var current = commit
        var hops = 0
        while let candidate = current, hops < 500 {
            if let manifest = manifest(at: candidate, gameId: gameId) {
                return (candidate, manifest)
            }
            current = parent(of: candidate)
            hops += 1
        }
        return nil
    }

    // MARK: - RemoteStore

    func head() async throws -> RemoteHead {
        lock.withLock { RemoteHead(commit: readHead()) }
    }

    func manifest(gameId: String, commit: String) async throws -> CloudManifest? {
        lock.withLock { manifest(at: commit, gameId: gameId) }
    }

    func download(gameId: String, commit: String, into directory: URL) async throws -> DownloadedSave {
        let resolved: (CloudManifest, URL) = try lock.withLock {
            guard let stored = manifest(at: commit, gameId: gameId) else {
                throw SyncError.cloudBackupMissing
            }
            let name = stored.archiveFileName.isEmpty ? "save.zip" : stored.archiveFileName
            let source = commitDirectory(commit)
                .appendingPathComponent(gameId, isDirectory: true)
                .appendingPathComponent(name)
            return (stored, source)
        }

        let (stored, source) = resolved
        guard FileSystem.exists(source) else { throw SyncError.cloudBackupMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("remote-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: source, to: destination)
        return DownloadedSave(commit: commit, manifest: stored, archiveURL: destination)
    }

    func upload(manifest: CloudManifest,
                archive: URL,
                precondition: UploadPrecondition,
                progress: (@Sendable (SyncPhase) -> Void)?) async throws -> UploadResult {
        try lock.withLock {
            try write(manifest: manifest, archive: archive, precondition: precondition, progress: progress)
        }
    }

    func history(gameId: String, limit: Int, page: Int) async throws -> [CloudHistoryEntry] {
        lock.withLock { collectHistory(gameId: gameId, limit: limit, page: page) }
    }

    // MARK: - Synchronous core (always called with the lock held)

    private func write(manifest: CloudManifest,
                       archive: URL,
                       precondition: UploadPrecondition,
                       progress: (@Sendable (SyncPhase) -> Void)?) throws -> UploadResult {
        let head = readHead()
        let current = resolveManifest(gameId: manifest.gameId, from: head)?.manifest

        if let current, current.contentHash == manifest.contentHash, let head {
            return UploadResult(commit: head, unchanged: true)
        }
        if let expected = precondition.remoteContentHash {
            guard current?.contentHash == expected else { throw SyncError.gitHubRemoteChanged }
        }

        progress?(.committing)
        let currentNumber = Int(head.map { String($0.dropFirst()) } ?? "") ?? 0
        let next = "c\(currentNumber + 1)"
        let directory = commitDirectory(next)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A commit carries the whole tree forward, exactly like GitHub's `base_tree`: every other
        // game keeps the version it had at the parent commit.
        if let head {
            let parentDirectory = commitDirectory(head)
            let items = (try? FileManager.default.contentsOfDirectory(at: parentDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent != "parent" {
                try? FileManager.default.copyItem(at: item,
                                                  to: directory.appendingPathComponent(item.lastPathComponent))
            }
            try Data(head.utf8).write(to: directory.appendingPathComponent("parent"))
        }

        let gameDirectory = directory.appendingPathComponent(manifest.gameId, isDirectory: true)
        FileSystem.removeIfExists(gameDirectory)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive, to: gameDirectory.appendingPathComponent(manifest.archiveFileName))
        try Coders.encode(manifest).write(to: gameDirectory.appendingPathComponent("manifest.json"))
        try Data(next.utf8).write(to: headFile)

        return UploadResult(commit: next, unchanged: false)
    }

    private func collectHistory(gameId: String, limit: Int, page: Int) -> [CloudHistoryEntry] {
        var entries: [CloudHistoryEntry] = []
        var current = readHead()
        var hops = 0
        while let commit = current, hops < 500 {
            // Every commit carries the tree forward, so only count the ones that changed this game.
            if let snapshot = manifest(at: commit, gameId: gameId) {
                let previous = parent(of: commit).flatMap { manifest(at: $0, gameId: gameId) }
                if previous?.versionId != snapshot.versionId {
                    entries.append(CloudHistoryEntry(commitSHA: commit, manifest: snapshot))
                }
            }
            current = parent(of: commit)
            hops += 1
        }
        let start = max(0, (page - 1) * limit)
        guard start < entries.count else { return [] }
        return Array(entries[start..<min(start + limit, entries.count)])
    }
}
