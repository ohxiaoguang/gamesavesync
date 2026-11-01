import Foundation
#if os(macOS)
import AppKit
#endif

/// Describes one scanned save directory.
public struct SaveSnapshot: Codable, Hashable, Sendable {
    /// Newest modification time among the real save files (never the folder itself unless empty).
    public var newestModified: Date?
    public var fileCount: Int
    public var directoryCount: Int
    public var totalBytes: Int64
    /// SHA-256 over relative paths and file contents. Empty when only a quick timestamp scan ran.
    public var contentHash: String

    public init(newestModified: Date?, fileCount: Int, directoryCount: Int, totalBytes: Int64, contentHash: String) {
        self.newestModified = newestModified
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalBytes = totalBytes
        self.contentHash = contentHash
    }

    public var isEmpty: Bool { fileCount == 0 }
    public var hasContentHash: Bool { !contentHash.isEmpty }

    public static let empty = SaveSnapshot(newestModified: nil, fileCount: 0, directoryCount: 0, totalBytes: 0, contentHash: "")
}

/// `manifest.json` stored next to `latest.zip` for every game.
///
/// The save time recorded here is the *original* newest save-file modification time taken from
/// the source device. The archive creation time is stored separately and is never used to decide
/// which side is newer.
public struct CloudManifest: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Archive write finished and was verified before the manifest was written.
        case complete
        /// Reserved: written before a backup completes. Never consumed by the app.
        case incomplete
    }

    public static let schemaVersion = 1
    public static let fileName = "manifest.json"

    public var schema: Int
    public var gameId: String
    public var gameName: String
    public var versionId: String
    public var saveModifiedAt: Date?
    public var saveWasEmpty: Bool
    public var backupCreatedAt: Date
    public var sourceDevice: String
    public var sourceAppVersion: String
    public var contentHash: String
    public var fileCount: Int
    public var totalBytes: Int64
    public var archiveFileName: String
    public var archiveBytes: Int
    public var archiveSHA256: String
    public var status: Status
    /// Best-effort iCloud upload confirmation recorded after the write completed.
    public var iCloudUploaded: Bool?

    public init(schema: Int = CloudManifest.schemaVersion,
                gameId: String,
                gameName: String,
                versionId: String,
                saveModifiedAt: Date?,
                saveWasEmpty: Bool,
                backupCreatedAt: Date,
                sourceDevice: String,
                sourceAppVersion: String,
                contentHash: String,
                fileCount: Int,
                totalBytes: Int64,
                archiveFileName: String = "latest.zip",
                archiveBytes: Int,
                archiveSHA256: String,
                status: Status = .complete,
                iCloudUploaded: Bool? = nil) {
        self.schema = schema
        self.gameId = gameId
        self.gameName = gameName
        self.versionId = versionId
        self.saveModifiedAt = saveModifiedAt
        self.saveWasEmpty = saveWasEmpty
        self.backupCreatedAt = backupCreatedAt
        self.sourceDevice = sourceDevice
        self.sourceAppVersion = sourceAppVersion
        self.contentHash = contentHash
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.archiveFileName = archiveFileName
        self.archiveBytes = archiveBytes
        self.archiveSHA256 = archiveSHA256
        self.status = status
        self.iCloudUploaded = iCloudUploaded
    }

    public var snapshot: SaveSnapshot {
        SaveSnapshot(newestModified: saveModifiedAt,
                     fileCount: fileCount,
                     directoryCount: 0,
                     totalBytes: totalBytes,
                     contentHash: contentHash)
    }
}

/// One entry inside `history/`.
public struct CloudHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { versionId }
    public var versionId: String
    public var gameName: String
    public var saveModifiedAt: Date?
    public var backupCreatedAt: Date
    public var sourceDevice: String
    public var fileCount: Int
    public var totalBytes: Int64
    public var archiveFileName: String
    public var contentHash: String

    public init(versionId: String,
                gameName: String,
                saveModifiedAt: Date?,
                backupCreatedAt: Date,
                sourceDevice: String,
                fileCount: Int,
                totalBytes: Int64,
                archiveFileName: String,
                contentHash: String) {
        self.versionId = versionId
        self.gameName = gameName
        self.saveModifiedAt = saveModifiedAt
        self.backupCreatedAt = backupCreatedAt
        self.sourceDevice = sourceDevice
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.archiveFileName = archiveFileName
        self.contentHash = contentHash
    }

    public init(manifest: CloudManifest) {
        self.init(versionId: manifest.versionId,
                  gameName: manifest.gameName,
                  saveModifiedAt: manifest.saveModifiedAt,
                  backupCreatedAt: manifest.backupCreatedAt,
                  sourceDevice: manifest.sourceDevice,
                  fileCount: manifest.fileCount,
                  totalBytes: manifest.totalBytes,
                  archiveFileName: manifest.archiveFileName,
                  contentHash: manifest.contentHash)
    }
}

/// A full local safety copy kept in Application Support.
public struct LocalBackup: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var gameId: String
    public var createdAt: Date
    public var reason: String
    public var fileCount: Int
    public var totalBytes: Int64
    public var saveModifiedAt: Date?
    public var contentHash: String
    /// Folder name under `<backups>/<gameId>/`, holding the copied files.
    public var folderName: String

    public init(id: String = UUID().uuidString,
                gameId: String,
                createdAt: Date = Date(),
                reason: String,
                fileCount: Int,
                totalBytes: Int64,
                saveModifiedAt: Date?,
                contentHash: String,
                folderName: String) {
        self.id = id
        self.gameId = gameId
        self.createdAt = createdAt
        self.reason = reason
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.saveModifiedAt = saveModifiedAt
        self.contentHash = contentHash
        self.folderName = folderName
    }
}
