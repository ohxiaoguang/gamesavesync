import Foundation

/// Reads and writes the cloud layout:
///
///     <root>/<gameId>/manifest.json
///     <root>/<gameId>/latest.zip
///     <root>/<gameId>/history/<versionId>.zip
///     <root>/<gameId>/history/<versionId>.json
///
/// Everything is plain files inside a folder the user picked in iCloud Drive. No iCloud
/// container, no CloudKit, no network API.
public struct CloudStorageManager: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Layout

    public func gameDirectory(gameId: String) -> URL {
        root.appendingPathComponent(gameId, isDirectory: true)
    }

    public func historyDirectory(gameId: String) -> URL {
        gameDirectory(gameId: gameId).appendingPathComponent("history", isDirectory: true)
    }

    public func manifestURL(gameId: String) -> URL {
        gameDirectory(gameId: gameId).appendingPathComponent(CloudManifest.fileName)
    }

    public func archiveURL(gameId: String, manifest: CloudManifest) -> URL {
        gameDirectory(gameId: gameId).appendingPathComponent(manifest.archiveFileName)
    }

    public func historyArchiveURL(gameId: String, versionId: String) -> URL {
        historyDirectory(gameId: gameId).appendingPathComponent("\(versionId).zip")
    }

    public func historyEntryURL(gameId: String, versionId: String) -> URL {
        historyDirectory(gameId: gameId).appendingPathComponent("\(versionId).json")
    }

    @discardableResult
    public func ensureGameDirectory(gameId: String) throws -> URL {
        let directory = gameDirectory(gameId: gameId)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: historyDirectory(gameId: gameId), withIntermediateDirectories: true)
        } catch {
            throw SyncError.folderCreationFailed(error.localizedDescription)
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw SyncError.folderCreationFailed("The cloud folder is read-only.")
        }
        return directory
    }

    public func hasBackup(gameId: String) -> Bool {
        FileSystem.exists(manifestURL(gameId: gameId))
    }

    // MARK: - Manifest

    public func loadManifestState(gameId: String) -> (manifest: CloudManifest?, error: SyncError?) {
        let url = manifestURL(gameId: gameId)
        guard FileSystem.exists(url) else {
            return (nil, nil)
        }
        do {
            try ICloudSupport.ensureDownloaded(url)
            let data = try coordinatedRead(url)
            let manifest = try Coders.decode(CloudManifest.self, from: data)
            guard manifest.status == .complete else {
                return (manifest, .cloudBackupIncomplete)
            }
            return (manifest, nil)
        } catch let error as SyncError {
            return (nil, error)
        } catch {
            return (nil, .archiveCorrupt("manifest.json: \(error.localizedDescription)"))
        }
    }

    public func loadManifest(gameId: String) throws -> CloudManifest {
        let state = loadManifestState(gameId: gameId)
        if let manifest = state.manifest, state.error == nil {
            return manifest
        }
        if let error = state.error {
            throw error
        }
        throw SyncError.cloudBackupMissing
    }

    /// Makes sure the archive is fully downloaded and matches what the manifest describes.
    public func prepareArchive(gameId: String, manifest: CloudManifest) throws -> URL {
        var url = archiveURL(gameId: gameId, manifest: manifest)

        if !FileSystem.exists(url) {
            // Self-heal: the newest archive may have been moved to history before an interrupted
            // publish. The manifest still points at a version we can recover.
            let fallback = historyArchiveURL(gameId: gameId, versionId: manifest.versionId)
            if FileSystem.exists(fallback) {
                try? FileManager.default.createDirectory(at: gameDirectory(gameId: gameId), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: fallback, to: url)
            }
        }

        guard FileSystem.exists(url) else {
            throw SyncError.cloudBackupMissing
        }

        try ICloudSupport.ensureDownloaded(url)

        let size = FileSystem.size(of: url)
        if manifest.archiveBytes > 0, size != Int64(manifest.archiveBytes) {
            throw SyncError.cloudVerificationFailed
        }
        if !manifest.archiveSHA256.isEmpty {
            let digest = try Hashing.sha256Hex(fileAt: url)
            guard digest == manifest.archiveSHA256 else {
                throw SyncError.cloudVerificationFailed
            }
        }
        return url
    }

    // MARK: - Publish

    public struct PublishResult: Sendable {
        public var uploadState: ICloudSupport.UploadState
        public var archivedVersion: String?
    }

    /// Writes `latest.zip` and then `manifest.json`, keeping the replaced version in `history/`.
    public func publish(manifest: CloudManifest,
                        archive localArchive: URL,
                        retention: Int) throws -> PublishResult {
        try ensureGameDirectory(gameId: manifest.gameId)

        let existing = loadManifestState(gameId: manifest.gameId).manifest
        var archivedVersion: String?

        if let existing, existing.versionId != manifest.versionId {
            archivedVersion = try archiveCurrentAsHistory(gameId: manifest.gameId, manifest: existing)
        }

        let destination = gameDirectory(gameId: manifest.gameId).appendingPathComponent(manifest.archiveFileName)
        let temp = gameDirectory(gameId: manifest.gameId).appendingPathComponent(".\(manifest.archiveFileName).tmp-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: localArchive, to: temp)
        } catch {
            throw SyncError.generic("Could not write the archive: \(error.localizedDescription)")
        }

        if FileSystem.size(of: temp) != Int64(manifest.archiveBytes) {
            try? FileManager.default.removeItem(at: temp)
            throw SyncError.generic("The archive copy is incomplete.")
        }

        // Move the previous archive out of the way only after the new copy is complete.
        FileSystem.removeIfExists(destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw SyncError.generic("Could not replace latest.zip: \(error.localizedDescription)")
        }

        // The manifest is written last: a reader never sees a manifest for an archive that is
        // not in place.
        let manifestData = try Coders.encode(manifest)
        do {
            try coordinatedWrite(manifestData, to: manifestURL(gameId: manifest.gameId))
        } catch {
            throw SyncError.generic("Could not write manifest.json: \(error.localizedDescription)")
        }

        pruneHistory(gameId: manifest.gameId, keep: max(retention, 1))

        let uploadState = ICloudSupport.awaitUpload([destination, manifestURL(gameId: manifest.gameId)])
        return PublishResult(uploadState: uploadState, archivedVersion: archivedVersion)
    }

    @discardableResult
    private func archiveCurrentAsHistory(gameId: String, manifest: CloudManifest) throws -> String? {
        let existingArchive = archiveURL(gameId: gameId, manifest: manifest)
        guard FileSystem.exists(existingArchive) else { return nil }

        let historyZip = historyArchiveURL(gameId: gameId, versionId: manifest.versionId)
        let historyJSON = historyEntryURL(gameId: gameId, versionId: manifest.versionId)

        if !FileSystem.exists(historyZip) {
            try FileManager.default.createDirectory(at: historyDirectory(gameId: gameId), withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(at: existingArchive, to: historyZip)
            } catch {
                throw SyncError.generic("Could not keep the previous backup: \(error.localizedDescription)")
            }
        }
        if !FileSystem.exists(historyJSON) {
            let entry = CloudHistoryEntry(manifest: manifest)
            let data = try Coders.encode(entry)
            try FileSystem.atomicWrite(data, to: historyJSON)
        }
        return manifest.versionId
    }

    // MARK: - History

    public func historyEntries(gameId: String) -> [CloudHistoryEntry] {
        let directory = historyDirectory(gameId: gameId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [CloudHistoryEntry] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? Coders.decode(CloudHistoryEntry.self, from: data) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.backupCreatedAt > $1.backupCreatedAt }
    }

    public func loadHistoryEntry(gameId: String, versionId: String) throws -> CloudHistoryEntry {
        let url = historyEntryURL(gameId: gameId, versionId: versionId)
        guard FileSystem.exists(url) else { throw SyncError.cloudBackupMissing }
        try ICloudSupport.ensureDownloaded(url)
        let data = try coordinatedRead(url)
        return try Coders.decode(CloudHistoryEntry.self, from: data)
    }

    public func prepareHistoryArchive(gameId: String, versionId: String) throws -> URL {
        let url = historyArchiveURL(gameId: gameId, versionId: versionId)
        guard FileSystem.exists(url) else { throw SyncError.cloudBackupMissing }
        try ICloudSupport.ensureDownloaded(url)
        return url
    }

    public func pruneHistory(gameId: String, keep: Int) {
        let entries = historyEntries(gameId: gameId)
        guard entries.count > keep else { return }
        for entry in entries.dropFirst(keep) {
            FileSystem.removeIfExists(historyArchiveURL(gameId: gameId, versionId: entry.versionId))
            FileSystem.removeIfExists(historyEntryURL(gameId: gameId, versionId: entry.versionId))
        }
    }

    // MARK: - Coordination

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error> = .failure(SyncError.cloudNotDownloaded)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var innerError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            do {
                try FileSystem.atomicWrite(data, to: writeURL)
            } catch {
                innerError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let innerError { throw innerError }
    }
}
