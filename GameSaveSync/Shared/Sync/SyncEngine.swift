import Foundation

/// Pure decision logic, kept separate from file I/O so it can be unit tested directly.
public enum SyncDecisionMaker {
    /// Filesystem timestamps are not bit-exact between devices, so a difference smaller than this
    /// is treated as "same time" and content hashes decide instead.
    public static let timestampTolerance: TimeInterval = 2.0

    /// A timestamp gap larger than this suggests a wrong device clock.
    public static let clockSkewThreshold: TimeInterval = 180 * 24 * 60 * 60

    public static func decide(local: SaveSnapshot?, remote: CloudManifest?) -> SyncDecision {
        switch (local, remote) {
        case (nil, nil):
            return .blocked(.localFolderUnavailable)
        case (nil, _):
            return .download(.firstSyncCloudOnly)
        case (_, nil):
            guard let local else { return .blocked(.localFolderUnavailable) }
            if local.isEmpty { return .upToDate }
            return .upload(.firstSyncLocalOnly)
        case (let local?, let remote?):
            return decideBothSides(local: local, remote: remote)
        }
    }

    private static func decideBothSides(local: SaveSnapshot, remote: CloudManifest) -> SyncDecision {
        let localHash = local.contentHash
        let remoteHash = remote.contentHash
        let hashesAvailable = !localHash.isEmpty && !remoteHash.isEmpty

        if local.isEmpty && remote.fileCount == 0 { return .upToDate }
        if hashesAvailable && localHash == remoteHash { return .upToDate }

        if local.isEmpty { return .download(.localEmpty) }
        if remote.fileCount == 0 { return .upload(.cloudEmpty) }

        guard let localTime = local.newestModified, let remoteTime = remote.saveModifiedAt else {
            // Without timestamps the only safe call is to ask the user.
            return .conflict
        }

        let delta = localTime.timeIntervalSince(remoteTime)
        if delta > timestampTolerance { return .upload(.localNewer) }
        if delta < -timestampTolerance { return .download(.cloudNewer) }
        return .conflict
    }

    public static func confirmation(for decision: SyncDecision,
                                    local: SaveSnapshot?,
                                    remote: CloudManifest?,
                                    hasSyncedBefore: Bool) -> SyncConfirmation {
        switch decision {
        case .conflict:
            return .sameTimeConflict
        case .upToDate, .blocked:
            return .none
        case .upload(let reason):
            switch reason {
            case .firstSyncLocalOnly, .cloudEmpty:
                return .none
            case .localNewer:
                if !hasSyncedBefore, (remote?.fileCount ?? 0) > 0 { return .firstSyncOverwrite(.upload) }
                if let localTime = local?.newestModified,
                   let remoteTime = remote?.saveModifiedAt,
                   localTime.timeIntervalSince(remoteTime) > clockSkewThreshold {
                    return .clockSkew(.upload)
                }
                return .none
            default:
                return .none
            }
        case .download(let reason):
            switch reason {
            case .firstSyncCloudOnly:
                return .none
            case .localEmpty:
                return .emptyLocalWillBeFilled
            case .cloudNewer:
                if !hasSyncedBefore, (local?.fileCount ?? 0) > 0 { return .firstSyncOverwrite(.download) }
                return .none
            default:
                return .none
            }
        }
    }
}

public struct SyncRequest: Sendable {
    public var gameId: String
    public var gameName: String
    /// The folder that is actually synced: `accessRoot` + `syncRelativePath`.
    public var localDirectory: URL
    /// The folder the sandbox authorised. Used to explain a missing sync folder correctly.
    public var accessRoot: URL?
    /// Path of `localDirectory` relative to `accessRoot`. Empty when they are the same folder.
    public var syncRelativePath: String
    public var cloudRoot: URL
    public var retention: Int
    public var deviceName: String
    public var appVersion: String
    public var hasSyncedBefore: Bool
    public var progress: (@Sendable (SyncPhase) -> Void)?

    public init(gameId: String,
                gameName: String,
                localDirectory: URL,
                accessRoot: URL? = nil,
                syncRelativePath: String = "",
                cloudRoot: URL,
                retention: Int = 3,
                deviceName: String = "Device",
                appVersion: String = "1.0",
                hasSyncedBefore: Bool = false,
                progress: (@Sendable (SyncPhase) -> Void)? = nil) {
        self.gameId = gameId
        self.gameName = gameName
        self.localDirectory = localDirectory
        self.accessRoot = accessRoot
        self.syncRelativePath = syncRelativePath
        self.cloudRoot = cloudRoot
        self.retention = retention
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.hasSyncedBefore = hasSyncedBefore
        self.progress = progress
    }

    func report(_ phase: SyncPhase) {
        progress?(phase)
    }

    /// Distinguishes "the sync folder was removed" from "the authorisation is gone" so the UI
    /// never asks for a new folder when the game simply recreated its saves.
    var localAvailabilityError: SyncError {
        if syncRelativePath.isEmpty {
            return accessRoot == nil ? .localFolderUnavailable : .accessRootMissing
        }
        if let accessRoot, FileSystem.isDirectory(accessRoot) {
            return .syncFolderMissing(syncRelativePath)
        }
        return .accessRootMissing
    }
}

public struct SyncEngine: Sendable {
    public let paths: AppPaths
    public let backupManager: BackupManager

    public init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.backupManager = BackupManager(root: paths.backups)
        try? paths.ensureDirectories()
    }

    private var scanner: SaveScanner {
        SaveScanner(prepare: { url in
            try ICloudSupport.ensureDownloaded(url)
        })
    }

    // MARK: - Analysis

    /// Full analysis: the local folder is scanned and hashed so identical content is detected
    /// even when timestamps happen to match.
    public func analyze(_ request: SyncRequest) -> SyncAnalysis {
        var local: SaveSnapshot?
        var localError: SyncError?
        var localEmpty = false

        if !FileSystem.isDirectory(request.localDirectory) {
            localError = request.localAvailabilityError
        } else {
            do {
                let result = try scanner.scan(directory: request.localDirectory, computeHash: true)
                local = result.snapshot
                localEmpty = result.snapshot.isEmpty
            } catch let error as SyncError {
                localError = error
            } catch {
                localError = .generic(error.localizedDescription)
            }
        }

        let cloud = CloudStorageManager(root: request.cloudRoot)
        let state = cloud.loadManifestState(gameId: request.gameId)
        let historyCount = cloud.historyEntries(gameId: request.gameId).count

        let decision: SyncDecision
        if let remoteError = state.error {
            decision = .blocked(remoteError)
        } else if let localError, local == nil {
            // A missing sync folder is not a lost authorisation: if the cloud has a backup the
            // folder is simply created and filled, which is exactly what a fresh install needs.
            if case .syncFolderMissing = localError, state.manifest != nil {
                decision = .download(.localEmpty)
            } else {
                decision = .blocked(localError)
            }
        } else {
            decision = SyncDecisionMaker.decide(local: local, remote: state.manifest)
        }

        let confirmation = SyncDecisionMaker.confirmation(for: decision,
                                                          local: local,
                                                          remote: state.manifest,
                                                          hasSyncedBefore: request.hasSyncedBefore)

        return SyncAnalysis(local: local,
                            localError: localError,
                            localFolderEmpty: localEmpty,
                            remote: state.manifest,
                            remoteError: state.error,
                            historyCount: historyCount,
                            decision: decision,
                            confirmation: confirmation,
                            localFolderURL: request.localDirectory,
                            localReadable: local != nil)
    }

    public func history(_ request: SyncRequest) -> [CloudHistoryEntry] {
        CloudStorageManager(root: request.cloudRoot).historyEntries(gameId: request.gameId)
    }

    public func localBackups(gameId: String) -> [LocalBackup] {
        backupManager.list(gameId: gameId)
    }

    public func leftovers(for request: SyncRequest) -> [DirectoryReplacer.Leftover] {
        DirectoryReplacer.leftovers(in: request.localDirectory)
    }

    // MARK: - Sync

    /// Runs the decision produced by `analyze`.
    public func sync(_ request: SyncRequest) throws -> SyncReport {
        let analysis = analyze(request)
        switch analysis.decision {
        case .blocked(let error):
            throw error
        case .conflict:
            return SyncReport(outcome: .conflictPending)
        case .upToDate:
            let snapshot = analysis.local ?? .empty
            return SyncReport(outcome: .upToDate, files: snapshot.fileCount, bytes: snapshot.totalBytes)
        case .upload:
            return try upload(request)
        case .download:
            return try restore(request)
        }
    }

    public func perform(_ request: SyncRequest, direction: SyncDirection) throws -> SyncReport {
        switch direction {
        case .upload: return try upload(request)
        case .download: return try restore(request)
        }
    }

    // MARK: - Upload

    public func upload(_ request: SyncRequest) throws -> SyncReport {
        request.report(.scanning)
        guard FileSystem.isDirectory(request.localDirectory) else {
            throw request.localAvailabilityError
        }

        let scan = try scanner.scan(directory: request.localDirectory, computeHash: true)
        guard !scan.snapshot.isEmpty else {
            throw SyncError.emptyLocalSave
        }

        let work = try paths.makeWorkDirectory(name: "upload")
        defer { try? FileManager.default.removeItem(at: work) }
        let archiveURL = work.appendingPathComponent("latest.zip")

        request.report(.packaging)
        let metadata = try ArchiveManager.createArchive(from: scan,
                                                        to: archiveURL,
                                                        gameId: request.gameId,
                                                        saveModifiedAt: scan.snapshot.newestModified)

        request.report(.verifyingArchive)
        let verifyDirectory = work.appendingPathComponent("verify", isDirectory: true)
        _ = try ArchiveManager.extract(zipURL: archiveURL, to: verifyDirectory)
        guard metadata.contentHash == scan.snapshot.contentHash else {
            throw SyncError.archiveCorrupt("Archive metadata does not match the save folder.")
        }
        _ = try ArchiveManager.verifyExtractedFolder(verifyDirectory,
                                                     expectedHash: scan.snapshot.contentHash,
                                                     expectedFileCount: scan.snapshot.fileCount)

        let archiveBytes = Int(FileSystem.size(of: archiveURL))
        guard archiveBytes > 0 else {
            throw SyncError.archiveCorrupt("The archive is empty.")
        }

        let versionId = Self.makeVersionId()
        let manifest = CloudManifest(gameId: request.gameId,
                                     gameName: request.gameName,
                                     versionId: versionId,
                                     saveModifiedAt: scan.snapshot.newestModified,
                                     saveWasEmpty: scan.snapshot.isEmpty,
                                     backupCreatedAt: Date(),
                                     sourceDevice: request.deviceName,
                                     sourceAppVersion: request.appVersion,
                                     contentHash: scan.snapshot.contentHash,
                                     fileCount: scan.snapshot.fileCount,
                                     totalBytes: scan.snapshot.totalBytes,
                                     archiveFileName: "latest.zip",
                                     archiveBytes: archiveBytes,
                                     archiveSHA256: try Hashing.sha256Hex(fileAt: archiveURL),
                                     status: .complete)

        request.report(.writingCloud)
        let cloud = CloudStorageManager(root: request.cloudRoot)
        let published = try cloud.publish(manifest: manifest,
                                          archive: archiveURL,
                                          retention: request.retention)

        let pending: Bool
        switch published.uploadState {
        case .pending:
            pending = true
        case .uploaded, .notICloud, .unknown:
            pending = false
        }

        request.report(.cleanup)
        return SyncReport(outcome: pending ? .uploadedPendingICloud : .uploaded,
                          files: scan.snapshot.fileCount,
                          bytes: scan.snapshot.totalBytes,
                          versionId: versionId,
                          pendingICloud: pending)
    }

    // MARK: - Restore

    public func restore(_ request: SyncRequest) throws -> SyncReport {
        request.report(.readingManifest)
        let cloud = CloudStorageManager(root: request.cloudRoot)
        let manifest = try cloud.loadManifest(gameId: request.gameId)

        request.report(.waitingDownload)
        let archiveURL = try cloud.prepareArchive(gameId: request.gameId, manifest: manifest)

        return try installArchive(archiveURL,
                                  expectedHash: manifest.contentHash,
                                  expectedCount: manifest.fileCount,
                                  request: request,
                                  versionId: manifest.versionId,
                                  outcome: .restored)
    }

    public func restoreHistory(_ request: SyncRequest, versionId: String) throws -> SyncReport {
        request.report(.readingManifest)
        let cloud = CloudStorageManager(root: request.cloudRoot)
        let entry = try cloud.loadHistoryEntry(gameId: request.gameId, versionId: versionId)

        request.report(.waitingDownload)
        let archiveURL = try cloud.prepareHistoryArchive(gameId: request.gameId, versionId: versionId)

        return try installArchive(archiveURL,
                                  expectedHash: entry.contentHash,
                                  expectedCount: entry.fileCount,
                                  request: request,
                                  versionId: entry.versionId,
                                  outcome: .restoredHistory)
    }

    public func restoreLocalBackup(_ request: SyncRequest, backup: LocalBackup) throws -> SyncReport {
        request.report(.scanning)
        let payload = backupManager.payloadURL(backup)
        guard FileSystem.isDirectory(payload) else {
            throw SyncError.localBackupFailed("The local backup folder is missing.")
        }

        request.report(.backingUp)
        let currentScan = try? scanner.scan(directory: request.localDirectory, computeHash: true)
        if let currentScan, currentScan.snapshot.fileCount > 0 {
            _ = try backupManager.createBackup(gameId: request.gameId,
                                               from: request.localDirectory,
                                               snapshot: currentScan.snapshot,
                                               reason: "before-local-backup-restore",
                                               keep: request.retention)
        }

        request.report(.replacing)
        let staging = try DirectoryReplacer.makeStagingDirectory(in: request.localDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try copyContents(from: payload, to: staging)
        try DirectoryReplacer.commit(staging: staging, into: request.localDirectory)

        request.report(.cleanup)
        return SyncReport(outcome: .restoredHistory,
                          files: backup.fileCount,
                          bytes: backup.totalBytes,
                          versionId: backup.id)
    }

    /// Extracts, verifies, backs up, then atomically swaps the local folder.
    private func installArchive(_ archiveURL: URL,
                                expectedHash: String,
                                expectedCount: Int,
                                request: SyncRequest,
                                versionId: String,
                                outcome: SyncOutcome) throws -> SyncReport {
        let localDirectory = request.localDirectory
        try ensureLocalDirectory(localDirectory, request: request)

        // Snapshot the current saves before touching anything.
        request.report(.scanning)
        let currentScan = try scanner.scan(directory: localDirectory, computeHash: true)

        var localBackupId: String?
        if currentScan.snapshot.fileCount > 0 {
            request.report(.backingUp)
            let backup = try backupManager.createBackup(gameId: request.gameId,
                                                        from: localDirectory,
                                                        snapshot: currentScan.snapshot,
                                                        reason: "before-restore-\(versionId)",
                                                        keep: request.retention)
            localBackupId = backup?.id
        }

        request.report(.extracting)
        let staging = try DirectoryReplacer.makeStagingDirectory(in: localDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        let metadata = try ArchiveManager.extract(zipURL: archiveURL, to: staging)

        request.report(.verifyingRestore)
        let extracted = try ArchiveManager.verifyExtractedFolder(staging,
                                                                expectedHash: expectedHash,
                                                                expectedFileCount: expectedCount)
        if let metadata, metadata.contentHash != expectedHash {
            throw SyncError.cloudVerificationFailed
        }

        request.report(.replacing)
        try DirectoryReplacer.commit(staging: staging, into: localDirectory)

        request.report(.cleanup)
        Log.write("restored game=\(request.gameId) version=\(versionId) files=\(extracted.fileCount)")
        return SyncReport(outcome: outcome,
                          files: extracted.fileCount,
                          bytes: extracted.totalBytes,
                          versionId: versionId,
                          localBackupId: localBackupId)
    }

    /// Creates the sync folder when it is missing — the games often delete and recreate it — but
    /// never touches the authorised root itself.
    private func ensureLocalDirectory(_ directory: URL, request: SyncRequest) throws {
        if FileSystem.isDirectory(directory) { return }
        if FileSystem.exists(directory) {
            throw request.localAvailabilityError
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw request.localAvailabilityError
        }
    }

    private func copyContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let rootPath = source.standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: source,
                                             includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [],
                                             errorHandler: { _, _ in true }) else {
            throw SyncError.localBackupFailed("The backup could not be read.")
        }
        for case let item as URL in enumerator {
            let relative = SaveScanner.relativePath(of: item, rootPath: rootPath)
            guard !relative.isEmpty else { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileSystem.exists(target) { try fm.removeItem(at: target) }
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    static func makeVersionId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return "\(stamp)-\(suffix)"
    }
}
