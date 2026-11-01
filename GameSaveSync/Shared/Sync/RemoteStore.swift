import Foundation

/// The cloud side of a sync, as the engine sees it.
///
/// Everything is addressed by commit, so a read can never mix a manifest from one version with an
/// archive from another, and a write always states which version it was based on.
public struct RemoteHead: Equatable, Sendable {
    /// `nil` when the repository has no commit at all yet.
    public var commit: String?

    public init(commit: String?) {
        self.commit = commit
    }
}

public struct DownloadedSave: Sendable {
    public var commit: String
    public var manifest: CloudManifest
    /// Temporary file owned by the caller's work directory.
    public var archiveURL: URL

    public init(commit: String, manifest: CloudManifest, archiveURL: URL) {
        self.commit = commit
        self.manifest = manifest
        self.archiveURL = archiveURL
    }
}

/// What the analysis saw. The upload uses it to detect that another device wrote first.
public struct UploadPrecondition: Sendable {
    /// Commit the analysis was based on; `nil` when the repository was empty.
    public var baseCommit: String?
    /// Content hash of the game's remote manifest at analysis time; `nil` when there was none.
    public var remoteContentHash: String?

    public init(baseCommit: String?, remoteContentHash: String?) {
        self.baseCommit = baseCommit
        self.remoteContentHash = remoteContentHash
    }
}

public struct UploadResult: Sendable {
    public var commit: String
    /// True when the remote already carried exactly this content, so no commit was needed.
    public var unchanged: Bool

    public init(commit: String, unchanged: Bool) {
        self.commit = commit
        self.unchanged = unchanged
    }
}

public protocol RemoteStore: Sendable {
    /// Stable identity of the remote, stored per game so a legacy sync record cannot pass for a
    /// successful GitHub sync.
    var identifier: String { get }
    /// `owner/name`, for display.
    var displayName: String { get }

    func verifyConnection() async throws -> GitHubConnectionReport
    func head() async throws -> RemoteHead
    func manifest(gameId: String, commit: String) async throws -> CloudManifest?
    func download(gameId: String, commit: String, into directory: URL) async throws -> DownloadedSave
    func upload(manifest: CloudManifest,
                archive: URL,
                precondition: UploadPrecondition,
                progress: (@Sendable (SyncPhase) -> Void)?) async throws -> UploadResult
    /// Newest first. `page` is 1-based.
    func history(gameId: String, limit: Int, page: Int) async throws -> [CloudHistoryEntry]
}

/// Names used inside the archive repository.
public enum GitHubLayout {
    public static let rootDirectory = "games"
    public static let manifestFileName = "manifest.json"
    public static let archiveFileName = "save.zip"

    /// Written once, when a completely empty repository is initialised. Its only job is to give
    /// the repository a first commit, because no branch can be created before one exists.
    public static let initialisationPath = ".gamesavesync/init.json"
    public static let initialisationMessage = "chore: initialise GameSaveSync storage"

    public static func directory(gameId: String) -> String { "\(rootDirectory)/\(gameId)" }
    public static func manifestPath(gameId: String) -> String { "\(directory(gameId: gameId))/\(manifestFileName)" }
    public static func archivePath(gameId: String, fileName: String) -> String { "\(directory(gameId: gameId))/\(fileName)" }
}
