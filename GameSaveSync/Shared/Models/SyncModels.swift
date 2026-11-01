import Foundation

/// Phases reported while a sync runs. Only real steps are shown — never a made-up percentage.
public enum SyncPhase: String, Sendable, CaseIterable {
    case connecting
    case readingRemote
    case scanning
    case hashing
    case packaging
    case verifyingArchive
    case uploading
    case committing
    case downloading
    case extracting
    case verifyingRestore
    case backingUp
    case replacing
    case cleanup

    /// English text is also the localization key.
    public var text: String {
        switch self {
        case .connecting: return "Connecting to GitHub…"
        case .readingRemote: return "Reading the remote version…"
        case .scanning: return "Scanning local saves…"
        case .hashing: return "Computing checksums…"
        case .packaging: return "Creating archive…"
        case .verifyingArchive: return "Verifying archive…"
        case .uploading: return "Uploading to GitHub…"
        case .committing: return "Creating commit…"
        case .downloading: return "Downloading save…"
        case .extracting: return "Extracting archive…"
        case .verifyingRestore: return "Verifying restored files…"
        case .backingUp: return "Backing up current saves…"
        case .replacing: return "Replacing local saves…"
        case .cleanup: return "Cleaning up…"
        }
    }
}

/// Why the engine picked a direction. Used to explain the decision in the UI.
public enum SyncReason: String, Codable, Sendable {
    case firstSyncLocalOnly
    case firstSyncCloudOnly
    case localNewer
    case cloudNewer
    case contentIdentical
    case sameTimeDifferentContent
    case localEmpty
    case cloudEmpty
}

public enum SyncDecision: Equatable, Sendable {
    case upToDate
    case upload(SyncReason)
    case download(SyncReason)
    case conflict
    case blocked(SyncError)

    public var direction: SyncDirection? {
        switch self {
        case .upload: return .upload
        case .download: return .download
        default: return nil
        }
    }

    public var reason: SyncReason? {
        switch self {
        case .upload(let reason), .download(let reason): return reason
        default: return nil
        }
    }
}

public enum SyncDirection: String, Sendable {
    case upload
    case download
}

/// When the user must confirm before anything is overwritten.
public enum SyncConfirmation: Equatable, Sendable {
    case none
    /// Same timestamp, different content: the user picks a side.
    case sameTimeConflict
    /// Both sides already hold saves and this game has never been synced with this remote.
    case firstSyncOverwrite(SyncDirection)
    /// The remote has no save for this game yet: the whole folder becomes the first version.
    case firstUpload
    /// The folder that would be replaced is empty, so the "overwrite" is really a fill.
    case emptyLocalWillBeFilled
    /// Timestamps differ by an implausible amount; ask before trusting them.
    case clockSkew(SyncDirection)
}

public struct SyncAnalysis: Sendable {
    public var local: SaveSnapshot?
    public var localError: SyncError?
    /// True when the folder exists but contains no save files.
    public var localFolderEmpty: Bool
    public var remote: CloudManifest?
    public var remoteError: SyncError?
    /// Commit the remote manifest was read from. Restores and uploads are based on it.
    public var remoteCommit: String?
    public var decision: SyncDecision
    public var confirmation: SyncConfirmation
    public var localFolderURL: URL?
    public var localReadable: Bool

    public init(local: SaveSnapshot?,
                localError: SyncError?,
                localFolderEmpty: Bool,
                remote: CloudManifest?,
                remoteError: SyncError?,
                remoteCommit: String? = nil,
                decision: SyncDecision,
                confirmation: SyncConfirmation = .none,
                localFolderURL: URL? = nil,
                localReadable: Bool = true) {
        self.local = local
        self.localError = localError
        self.localFolderEmpty = localFolderEmpty
        self.remote = remote
        self.remoteError = remoteError
        self.remoteCommit = remoteCommit
        self.decision = decision
        self.confirmation = confirmation
        self.localFolderURL = localFolderURL
        self.localReadable = localReadable
    }

    public static let unavailable = SyncAnalysis(local: nil,
                                                 localError: .localFolderUnavailable,
                                                 localFolderEmpty: false,
                                                 remote: nil,
                                                 remoteError: nil,
                                                 decision: .blocked(.localFolderUnavailable),
                                                 localReadable: false)
}

public enum SyncOutcome: Equatable, Sendable {
    case uploaded
    case restored
    case restoredHistory
    case upToDate
    case nothingToDo
    /// Analysis decided a conflict; nothing was written.
    case conflictPending

    public var recordKind: SyncRecord.Kind {
        switch self {
        case .uploaded: return .uploaded
        case .restored: return .restored
        case .restoredHistory: return .restoredHistory
        case .upToDate, .nothingToDo, .conflictPending: return .upToDate
        }
    }
}

public struct SyncReport: Sendable {
    public var outcome: SyncOutcome
    public var files: Int
    public var bytes: Int64
    public var versionId: String?
    /// Commit the operation produced or restored from.
    public var commitSHA: String?
    public var localBackupId: String?

    public init(outcome: SyncOutcome,
                files: Int = 0,
                bytes: Int64 = 0,
                versionId: String? = nil,
                commitSHA: String? = nil,
                localBackupId: String? = nil) {
        self.outcome = outcome
        self.files = files
        self.bytes = bytes
        self.versionId = versionId
        self.commitSHA = commitSHA
        self.localBackupId = localBackupId
    }
}

public enum SyncError: Error, Equatable, Sendable {
    // MARK: Local
    /// No sync folder configured at all (the folder *is* the authorised root and it is gone).
    case localFolderUnavailable
    /// The bookmark itself cannot be resolved, or the authorised root can no longer be opened.
    case accessRootUnavailable(detail: String?)
    /// The bookmark resolved, but the authorised folder no longer exists at that location.
    case accessRootMissing
    /// The authorised root is fine; only the sync subfolder is missing (a game may recreate it).
    case syncFolderMissing(String)
    /// A stored relative path would leave the authorised root.
    case invalidSyncPath(String)

    // MARK: Configuration
    case gitHubNotConfigured

    // MARK: Remote state
    case cloudBackupMissing
    case cloudBackupIncomplete
    case cloudVerificationFailed
    case gitHubRemoteChanged
    case gitHubRepositoryEmpty

    // MARK: GitHub API
    /// 401 — the token is rejected.
    case gitHubAuthFailed(detail: String?)
    /// 403 — authenticated, but the token may not do this.
    case gitHubPermissionDenied(detail: String?)
    /// 403 with an exhausted budget, or 429.
    case gitHubRateLimited(retryAfter: Int?)
    case gitHubRepositoryNotFound(String)
    case gitHubNotFound(String)
    case gitHubRepositoryNotPrivate
    case gitHubBranchMissing(String)
    /// 422 — the API accepted the request but refused the values.
    case gitHubUnprocessable
    case gitHubServerError(status: Int)
    case gitHubUnexpectedResponse(String)
    case gitHubFileTooLarge(bytes: Int, limit: Int)

    // MARK: Network
    case networkUnavailable
    case networkTimeout
    case cancelled

    // MARK: Local processing
    case archiveCorrupt(String)
    case unsafeArchivePath(String)
    case archiveTooLarge(String)
    case localBackupFailed(String)
    case replaceFailed(recovered: Bool, detail: String)
    case folderCreationFailed(String)
    case emptyLocalSave
    case generic(String)

    /// English message key, also used as the localization key.
    public var messageKey: String {
        switch self {
        case .localFolderUnavailable:
            return "The selected folder is no longer available. Pick it again in the game settings."
        case .accessRootUnavailable:
            return "GameSaveSync lost access to the authorised folder. Choose the folder again."
        case .accessRootMissing:
            return "The authorised folder no longer exists. Choose the folder again."
        case .syncFolderMissing:
            return "The save folder does not exist yet."
        case .invalidSyncPath:
            return "The save folder is outside the authorised folder."
        case .gitHubNotConfigured:
            return "No GitHub repository is configured yet. Add the owner, repository name and access token in Settings."
        case .cloudBackupMissing:
            return "No save exists for this game on GitHub yet."
        case .cloudBackupIncomplete:
            return "The remote save is incomplete and cannot be used."
        case .cloudVerificationFailed:
            return "The remote save failed verification and was not applied."
        case .gitHubRemoteChanged:
            return "Another device changed this game on GitHub after the comparison started. Nothing was overwritten — sync again to compare the new version."
        case .gitHubRepositoryEmpty:
            return "The repository has no commits yet. The first upload sets it up automatically."
        case .gitHubAuthFailed:
            return "GitHub rejected the access token. Check that it is correct and not expired."
        case .gitHubPermissionDenied:
            return "The access token is not allowed to do this. It needs Contents: Read and write on this repository."
        case .gitHubRateLimited:
            return "GitHub is rate limiting requests. Try again later."
        case .gitHubRepositoryNotFound:
            return "The repository was not found. Check the owner and repository name, and that the token can access it."
        case .gitHubNotFound:
            return "The requested item does not exist in the repository."
        case .gitHubRepositoryNotPrivate:
            return "This repository is not private. GameSaveSync only stores saves in a private repository."
        case .gitHubBranchMissing:
            return "The branch does not exist in the repository. Create it on GitHub, or enter an existing branch in Settings."
        case .gitHubUnprocessable:
            return "GitHub rejected the request because the repository changed. Try again."
        case .gitHubServerError:
            return "GitHub returned a server error. Try again later."
        case .gitHubUnexpectedResponse:
            return "GitHub returned an unexpected response."
        case .gitHubFileTooLarge:
            return "The archive is larger than GitHub's 100 MiB file limit, so it was not uploaded."
        case .networkUnavailable:
            return "No network connection. Connect to the internet and try again."
        case .networkTimeout:
            return "The connection to GitHub timed out."
        case .cancelled:
            return "The operation was cancelled."
        case .archiveCorrupt:
            return "The archive is damaged or was modified after it was created."
        case .unsafeArchivePath:
            return "The backup contains an unsafe file path and was rejected."
        case .archiveTooLarge:
            return "The backup is too large to process on this device."
        case .localBackupFailed:
            return "Could not create the safety backup, so nothing was changed."
        case .replaceFailed(let recovered, _):
            return recovered
                ? "Replacing the folder failed. Your previous saves were restored."
                : "Replacing the folder failed and the automatic rollback also failed. Your saves are kept at the path below."
        case .folderCreationFailed:
            return "The folder could not be created."
        case .emptyLocalSave:
            return "The local save folder is empty, so nothing was uploaded."
        case .generic:
            return "Something went wrong."
        }
    }

    public var detail: String? {
        switch self {
        case .archiveCorrupt(let detail), .unsafeArchivePath(let detail),
             .archiveTooLarge(let detail), .localBackupFailed(let detail),
             .folderCreationFailed(let detail), .generic(let detail):
            return detail
        case .accessRootUnavailable(let detail):
            return detail
        case .gitHubAuthFailed(let detail), .gitHubPermissionDenied(let detail):
            return detail
        case .gitHubRepositoryNotFound(let detail), .gitHubNotFound(let detail):
            return detail.isEmpty ? nil : detail
        case .gitHubBranchMissing(let branch):
            return branch.isEmpty ? nil : branch
        case .gitHubUnexpectedResponse(let detail):
            return detail
        case .gitHubRateLimited(let retryAfter):
            guard let retryAfter else { return nil }
            return Localizer(language: .english).f("Retry in %d seconds.", retryAfter)
        case .gitHubServerError(let status):
            return "HTTP \(status)"
        case .gitHubFileTooLarge(let bytes, let limit):
            return "\(ByteText.string(Int64(bytes))) / \(ByteText.string(Int64(limit)))"
        case .syncFolderMissing(let path):
            return path.isEmpty ? nil : path.replacingOccurrences(of: "/", with: " / ")
        case .invalidSyncPath(let path):
            return path
        case .replaceFailed(_, let detail):
            return detail
        default:
            return nil
        }
    }

    public func localized(_ localizer: Localizer) -> String {
        let base = localizer.t(messageKey)
        if let detail, !detail.isEmpty {
            return "\(base)\n\(detail)"
        }
        return base
    }

    /// True for failures where simply trying again can help.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .networkTimeout, .gitHubServerError, .gitHubRateLimited, .gitHubRemoteChanged:
            return true
        default:
            return false
        }
    }
}

extension SyncError: LocalizedError {
    public var errorDescription: String? { messageKey }
}
