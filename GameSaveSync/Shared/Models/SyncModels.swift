import Foundation

public enum SyncPhase: String, Sendable, CaseIterable {
    case readingManifest
    case scanning
    case hashing
    case packaging
    case verifyingArchive
    case writingCloud
    case waitingUpload
    case waitingDownload
    case extracting
    case verifyingRestore
    case backingUp
    case replacing
    case cleanup

    /// English text is also the localization key.
    public var text: String {
        switch self {
        case .readingManifest: return "Reading cloud manifest…"
        case .scanning: return "Scanning local saves…"
        case .hashing: return "Computing checksums…"
        case .packaging: return "Creating archive…"
        case .verifyingArchive: return "Verifying archive…"
        case .writingCloud: return "Writing to iCloud Drive…"
        case .waitingUpload: return "Waiting for iCloud upload…"
        case .waitingDownload: return "Waiting for iCloud download…"
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
    /// Both sides already hold saves and this game has never been synced on this device.
    case firstSyncOverwrite(SyncDirection)
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
    public var historyCount: Int
    public var decision: SyncDecision
    public var confirmation: SyncConfirmation
    public var localFolderURL: URL?
    public var localReadable: Bool

    public init(local: SaveSnapshot?,
                localError: SyncError?,
                localFolderEmpty: Bool,
                remote: CloudManifest?,
                remoteError: SyncError?,
                historyCount: Int = 0,
                decision: SyncDecision,
                confirmation: SyncConfirmation = .none,
                localFolderURL: URL? = nil,
                localReadable: Bool = true) {
        self.local = local
        self.localError = localError
        self.localFolderEmpty = localFolderEmpty
        self.remote = remote
        self.remoteError = remoteError
        self.historyCount = historyCount
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
    case uploadedPendingICloud
    case restored
    case restoredHistory
    case upToDate
    case nothingToDo
    /// Analysis decided a conflict; nothing was written.
    case conflictPending

    public var recordKind: SyncRecord.Kind {
        switch self {
        case .uploaded: return .uploaded
        case .uploadedPendingICloud: return .uploadedPendingICloud
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
    public var localBackupId: String?
    public var pendingICloud: Bool

    public init(outcome: SyncOutcome,
                files: Int = 0,
                bytes: Int64 = 0,
                versionId: String? = nil,
                localBackupId: String? = nil,
                pendingICloud: Bool = false) {
        self.outcome = outcome
        self.files = files
        self.bytes = bytes
        self.versionId = versionId
        self.localBackupId = localBackupId
        self.pendingICloud = pendingICloud
    }
}

public enum SyncError: Error, Equatable, Sendable {
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
    case cloudRootUnavailable
    case cloudBackupMissing
    case cloudBackupIncomplete
    case cloudNotDownloaded
    case cloudVerificationFailed
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
        case .cloudRootUnavailable:
            return "The iCloud Drive folder is not configured."
        case .cloudBackupMissing:
            return "No cloud backup exists for this game yet."
        case .cloudBackupIncomplete:
            return "The cloud backup is incomplete. It may still be uploading from another device."
        case .cloudNotDownloaded:
            return "The cloud backup has not been downloaded yet. Connect to the internet and try again."
        case .cloudVerificationFailed:
            return "The cloud backup failed verification and was not applied."
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
        case .syncFolderMissing(let path):
            return path.isEmpty ? nil : path.replacingOccurrences(of: "/", with: " / ")
        case .invalidSyncPath(let path):
            return path
        case .accessRootMissing:
            return nil
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
}

extension SyncError: LocalizedError {
    public var errorDescription: String? { messageKey }
}
