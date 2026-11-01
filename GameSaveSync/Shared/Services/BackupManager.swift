import Foundation

/// Durable safety copies of a save folder, kept inside the app container.
///
/// These exist so that even if the cloud backup is wrong, the version that was on this device
/// before a restore can still be recovered.
public struct BackupManager: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func gameDirectory(_ gameId: String) -> URL {
        root.appendingPathComponent(gameId, isDirectory: true)
    }

    public func payloadURL(_ backup: LocalBackup) -> URL {
        gameDirectory(backup.gameId)
            .appendingPathComponent(backup.folderName, isDirectory: true)
            .appendingPathComponent("Payload", isDirectory: true)
    }

    public func createBackup(gameId: String,
                             from directory: URL,
                             snapshot: SaveSnapshot,
                             reason: String,
                             keep: Int) throws -> LocalBackup? {
        guard snapshot.fileCount > 0 else { return nil }

        let stamp = Coders.iso8601.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let folderName = "\(stamp)-\(String(UUID().uuidString.prefix(6)))"
        let package = gameDirectory(gameId).appendingPathComponent(folderName, isDirectory: true)
        let payload = package.appendingPathComponent("Payload", isDirectory: true)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try copyContents(from: directory, to: payload)
        } catch {
            try? fm.removeItem(at: package)
            throw SyncError.localBackupFailed(error.localizedDescription)
        }

        // Confirm the copy is byte-identical before anyone relies on it.
        let copied: SaveSnapshot
        do {
            copied = try SaveScanner().scan(directory: payload, computeHash: true).snapshot
        } catch {
            try? fm.removeItem(at: package)
            throw SyncError.localBackupFailed("The copy could not be verified: \(error.localizedDescription)")
        }
        guard copied.contentHash == snapshot.contentHash else {
            try? fm.removeItem(at: package)
            throw SyncError.localBackupFailed("The save folder changed while it was being backed up. Close the game and try again.")
        }

        let backup = LocalBackup(gameId: gameId,
                                 reason: reason,
                                 fileCount: copied.fileCount,
                                 totalBytes: copied.totalBytes,
                                 saveModifiedAt: copied.newestModified,
                                 contentHash: copied.contentHash,
                                 folderName: folderName)
        let data = try Coders.encode(backup)
        try FileSystem.atomicWrite(data, to: package.appendingPathComponent("backup.json"))
        prune(gameId: gameId, keep: max(keep, 1))
        return backup
    }

    private func copyContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let rootPath = source.standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: source,
                                             includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [],
                                             errorHandler: { _, _ in true }) else {
            throw SyncError.localBackupFailed("The save folder could not be read.")
        }

        for case let item as URL in enumerator {
            let relative = SaveScanner.relativePath(of: item, rootPath: rootPath)
            guard !relative.isEmpty else { continue }
            if SavePathFilter.isExcluded(relativePath: relative) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
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

    public func list(gameId: String) -> [LocalBackup] {
        let directory = gameDirectory(gameId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var backups: [LocalBackup] = []
        for name in names {
            let url = directory.appendingPathComponent(name).appendingPathComponent("backup.json")
            guard let data = try? Data(contentsOf: url),
                  let backup = try? Coders.decode(LocalBackup.self, from: data) else { continue }
            backups.append(backup)
        }
        return backups.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ backup: LocalBackup) {
        try? FileManager.default.removeItem(at: gameDirectory(backup.gameId).appendingPathComponent(backup.folderName))
    }

    public func prune(gameId: String, keep: Int) {
        let backups = list(gameId: gameId)
        guard backups.count > keep else { return }
        for backup in backups.dropFirst(keep) {
            delete(backup)
        }
    }
}
