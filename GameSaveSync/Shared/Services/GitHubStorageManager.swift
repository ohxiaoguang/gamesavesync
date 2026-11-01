import Foundation

/// Git Database API backed storage for game archives.
///
/// The archive repository looks like this, and nothing else in it is ever touched:
///
///     games/<gameId>/manifest.json
///     games/<gameId>/save.zip
///
/// An upload writes the ZIP blob, the manifest blob, a tree based on the current branch tree and a
/// single commit that contains both files, then fast-forwards the branch. The two files are
/// therefore always visible in the same commit — a reader can never see a manifest that belongs to
/// a different archive.
public struct GitHubStorageManager: RemoteStore {
    public let repository: GitHubRepository
    private let api: GitHubAPIClient
    private let authorName: String
    private let authorEmail: String

    /// Guards against a pathological loop when other devices keep writing while we commit.
    private static let maximumCommitAttempts = 3

    public init(repository: GitHubRepository,
                token: String,
                session: URLSession? = nil,
                authorName: String = "GameSaveSync",
                authorEmail: String = "gamesavesync@users.noreply.github.com",
                configuration: GitHubAPIClient.Configuration = GitHubAPIClient.Configuration()) {
        self.repository = repository
        self.api = GitHubAPIClient(token: token, session: session, configuration: configuration)
        self.authorName = authorName
        self.authorEmail = authorEmail
    }

    public var identifier: String { repository.identifier }
    public var displayName: String { repository.fullName }

    // MARK: - Connection

    public func verifyConnection() async throws -> GitHubConnectionReport {
        let info = try await api.repository(repository)
        // The endpoint is owner-scoped already; this also guards against a proxy answering for a
        // different repository than the one the user typed.
        if let fullName = info.fullName, fullName.lowercased() != repository.fullName.lowercased() {
            throw SyncError.gitHubRepositoryNotFound(repository.fullName)
        }
        guard info.isPrivate == true else {
            throw SyncError.gitHubRepositoryNotPrivate
        }
        let permissions = info.permissions
        let canRead = permissions?.pull ?? true
        let canWrite = permissions?.push ?? false

        let head = try await self.head()

        return GitHubConnectionReport(repository: repository,
                                      account: info.owner?.login,
                                      isPrivate: true,
                                      canRead: canRead,
                                      canWrite: canWrite,
                                      defaultBranch: info.defaultBranch ?? repository.trimmedBranch,
                                      isEmptyRepository: head.commit == nil)
    }

    public func head() async throws -> RemoteHead {
        do {
            return RemoteHead(commit: try await api.headCommit(repository))
        } catch SyncError.gitHubRepositoryEmpty {
            // "No commit yet" is a state, not a failure: the caller decides whether to initialise.
            Log.write("[GitHub] \(repository.fullName) reports an empty repository; HEAD is nil")
            return RemoteHead(commit: nil)
        }
    }

    // MARK: - Reading

    public func manifest(gameId: String, commit: String) async throws -> CloudManifest? {
        guard let tree = try await gameTree(gameId: gameId, commit: commit) else { return nil }
        guard let entry = tree.first(where: { $0.path == GitHubLayout.manifestFileName }) else { return nil }
        let data = try await api.readBlob(repository, sha: entry.sha)
        return try Coders.decode(CloudManifest.self, from: data)
    }

    public func download(gameId: String, commit: String, into directory: URL) async throws -> DownloadedSave {
        guard let entries = try await gameTree(gameId: gameId, commit: commit) else {
            throw SyncError.cloudBackupMissing
        }
        guard let manifestEntry = entries.first(where: { $0.path == GitHubLayout.manifestFileName }) else {
            throw SyncError.cloudBackupMissing
        }

        let manifestData = try await api.readBlob(repository, sha: manifestEntry.sha)
        let manifest: CloudManifest
        do {
            manifest = try Coders.decode(CloudManifest.self, from: manifestData)
        } catch {
            throw SyncError.archiveCorrupt("manifest.json: \(error.localizedDescription)")
        }
        guard manifest.status == .complete else {
            throw SyncError.cloudBackupIncomplete
        }

        let archiveName = manifest.archiveFileName.isEmpty ? GitHubLayout.archiveFileName : manifest.archiveFileName
        guard let archiveEntry = entries.first(where: { $0.path == archiveName }) else {
            throw SyncError.cloudBackupMissing
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("remote-\(UUID().uuidString).zip")
        try await api.downloadBlob(repository, sha: archiveEntry.sha, to: destination)

        let size = FileSystem.size(of: destination)
        if manifest.archiveBytes > 0, size != Int64(manifest.archiveBytes) {
            FileSystem.removeIfExists(destination)
            throw SyncError.cloudVerificationFailed
        }
        if !manifest.archiveSHA256.isEmpty {
            let digest = try Hashing.sha256Hex(fileAt: destination)
            guard digest == manifest.archiveSHA256 else {
                FileSystem.removeIfExists(destination)
                throw SyncError.cloudVerificationFailed
            }
        }

        return DownloadedSave(commit: commit, manifest: manifest, archiveURL: destination)
    }

    public func history(gameId: String, limit: Int, page: Int) async throws -> [CloudHistoryEntry] {
        let items = try await api.commits(repository,
                                          branch: repository.trimmedBranch,
                                          path: GitHubLayout.manifestPath(gameId: gameId),
                                          perPage: max(1, min(limit, 100)),
                                          page: max(1, page))
        guard !items.isEmpty else { return [] }

        // Each commit needs its manifest for the details the UI shows. A handful of small blob
        // reads per page, a few at a time, keeps it responsive without hammering the API.
        var entries: [CloudHistoryEntry] = []
        var index = 0
        while index < items.count {
            let slice = Array(items[index..<min(index + 4, items.count)])
            index += slice.count
            let resolved = await withTaskGroup(of: (Int, CloudHistoryEntry?).self) { group -> [(Int, CloudHistoryEntry?)] in
                for (offset, item) in slice.enumerated() {
                    group.addTask {
                        let manifest = try? await self.manifest(gameId: gameId, commit: item.sha)
                        guard let manifest else { return (offset, nil) }
                        return (offset, CloudHistoryEntry(commitSHA: item.sha, manifest: manifest))
                    }
                }
                var collected: [(Int, CloudHistoryEntry?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            let ordered = resolved.sorted { $0.0 < $1.0 }.compactMap(\.1)
            entries.append(contentsOf: ordered)
        }
        return entries
    }

    // MARK: - Writing

    public func upload(manifest: CloudManifest,
                       archive: URL,
                       precondition: UploadPrecondition,
                       progress: (@Sendable (SyncPhase) -> Void)? = nil) async throws -> UploadResult {
        let archiveBytes = Int(FileSystem.size(of: archive))
        guard archiveBytes > 0 else {
            throw SyncError.archiveCorrupt("The archive is empty.")
        }
        guard !GitHubLimits.isTooLarge(archiveBytes) else {
            throw SyncError.gitHubFileTooLarge(bytes: archiveBytes, limit: GitHubLimits.maximumBytes)
        }

        var attempt = 0
        var initialized = false
        while true {
            attempt += 1

            guard let headCommit = try await head().commit else {
                // A repository with no branch at all cannot take a reference, so the first commit
                // is created through the contents endpoint; the upload then continues on top of it.
                guard !initialized else { throw SyncError.gitHubBranchMissing(repository.trimmedBranch) }
                initialized = true
                Log.write("[GitHub] \(repository.fullName) has no commit; initialising before the first upload")
                do {
                    try await initializeRepository()
                } catch SyncError.gitHubUnprocessable, SyncError.gitHubRemoteChanged {
                    // Another device initialised the repository first; re-read it below.
                    Log.write("[GitHub] initialisation was already done by someone else; re-reading HEAD")
                }
                Log.write("[GitHub] HEAD after initialisation: \(await describeHead())")
                continue
            }

            let current = try await self.manifest(gameId: manifest.gameId, commit: headCommit)

            // Already exactly what we are about to write?
            if let current, current.contentHash == manifest.contentHash {
                return UploadResult(commit: headCommit, unchanged: true)
            }

            // The version the analysis decided on must still be the version on the remote.
            if let expected = precondition.remoteContentHash {
                guard current?.contentHash == expected else { throw SyncError.gitHubRemoteChanged }
            } else if current != nil {
                // The analysis saw no remote save for this game, but there is one now.
                throw SyncError.gitHubRemoteChanged
            }

            do {
                let commit = try await createCommit(manifest: manifest,
                                                    archive: archive,
                                                    parentCommit: headCommit,
                                                    progress: progress)
                try await api.updateRef(repository, commit: commit)
                Log.write("[GitHub] committed \(commit.prefix(7)) for \(manifest.gameId) on \(repository.trimmedBranch)")
                return UploadResult(commit: commit, unchanged: false)
            } catch SyncError.gitHubRemoteChanged where attempt < Self.maximumCommitAttempts {
                // Only another game (or another branch writer) moved: rebuild on the new head.
                continue
            } catch {
                // A timeout does not mean the commit was lost. Ask the branch before deciding.
                if let landed = await landedCommit(for: manifest) {
                    return landed
                }
                throw error
            }
        }
    }

    /// Creates the first commit of a repository that has no branches yet.
    ///
    /// The contents endpoint creates the repository's default branch. When the user configured a
    /// different branch, it is branched off that first commit — `POST /git/refs` works as soon as
    /// the repository has a commit.
    private func initializeRepository() async throws {
        let commit = try await api.initializeRepository(repository,
                                                       authorName: authorName,
                                                       authorEmail: authorEmail)
        let existing: String?
        do {
            existing = try await head().commit
        } catch SyncError.gitHubBranchMissing {
            existing = nil
        }
        guard existing == nil else { return }
        try await api.createRef(repository, commit: commit)
    }

    /// Diagnostic description of the branch after initialisation; never throws.
    private func describeHead() async -> String {
        guard let head = try? await head(), let commit = head.commit else { return "unavailable" }
        return String(commit.prefix(7))
    }

    /// Builds the blobs, tree and commit, but does not move the branch.
    private func createCommit(manifest: CloudManifest,
                              archive: URL,
                              parentCommit: String?,
                              progress: (@Sendable (SyncPhase) -> Void)?) async throws -> String {
        let archiveBlob = try await api.createBlob(repository, fileAt: archive)

        let manifestData = try Coders.encode(manifest)
        let manifestURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gss-manifest-\(UUID().uuidString).json")
        try manifestData.write(to: manifestURL, options: .atomic)
        defer { FileSystem.removeIfExists(manifestURL) }
        let manifestBlob = try await api.createBlob(repository, fileAt: manifestURL)

        progress?(.committing)
        let baseTree: String?
        if let parentCommit {
            baseTree = try await api.commit(repository, sha: parentCommit).tree.sha
        } else {
            baseTree = nil
        }

        // `base_tree` keeps every other game exactly as it is: only the two paths below change.
        let fileName = sanitizedArchiveName(manifest.archiveFileName)
        let entries = [
            GHTreeRequest.Entry(path: GitHubLayout.archivePath(gameId: manifest.gameId, fileName: fileName),
                                mode: "100644",
                                type: "blob",
                                sha: archiveBlob),
            GHTreeRequest.Entry(path: GitHubLayout.manifestPath(gameId: manifest.gameId),
                                mode: "100644",
                                type: "blob",
                                sha: manifestBlob)
        ]
        let tree = try await api.createTree(repository, baseTree: baseTree, entries: entries)

        let message = Self.commitMessage(for: manifest)
        return try await api.createCommit(repository,
                                          message: message,
                                          tree: tree,
                                          parents: parentCommit.map { [$0] } ?? [],
                                          authorName: authorName,
                                          authorEmail: authorEmail)
    }

    /// After an ambiguous failure, look at the branch instead of blindly retrying.
    private func landedCommit(for manifest: CloudManifest) async -> UploadResult? {
        guard let head = try? await head(), let commit = head.commit else { return nil }
        guard let remote = try? await self.manifest(gameId: manifest.gameId, commit: commit) else { return nil }
        guard remote.contentHash == manifest.contentHash else { return nil }
        return UploadResult(commit: commit, unchanged: false)
    }

    /// Only the file name matters, but the manifest comes from a remote file, so never trust a
    /// path that could escape the game directory.
    private func sanitizedArchiveName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return GitHubLayout.archiveFileName
        }
        return name
    }

    static func commitMessage(for manifest: CloudManifest) -> String {
        let stamp = ISO8601DateFormatter.github.string(from: manifest.backupCreatedAt)
        return """
        save(\(manifest.gameId)): \(manifest.sourceDevice) \(stamp)

        version: \(manifest.versionId)
        files: \(manifest.fileCount)
        bytes: \(manifest.totalBytes)
        content-sha256: \(manifest.contentHash)
        """
    }

    // MARK: - Tree helpers

    /// Entries of `games/<gameId>/` at `commit`, or `nil` when the game is not in that commit.
    private func gameTree(gameId: String, commit: String) async throws -> [GHTreeResponse.Entry]? {
        let rootTree: GHTreeResponse
        do {
            rootTree = try await api.tree(repository, sha: commit)
        } catch SyncError.gitHubNotFound {
            return nil
        }
        guard let gamesEntry = rootTree.tree.first(where: { $0.path == GitHubLayout.rootDirectory && $0.type == "tree" }) else {
            return nil
        }
        let gamesTree: GHTreeResponse
        do {
            gamesTree = try await api.tree(repository, sha: gamesEntry.sha)
        } catch SyncError.gitHubNotFound {
            return nil
        }
        guard let gameEntry = gamesTree.tree.first(where: { $0.path == gameId && $0.type == "tree" }) else {
            return nil
        }
        do {
            return try await api.tree(repository, sha: gameEntry.sha).tree
        } catch SyncError.gitHubNotFound {
            return nil
        }
    }
}
