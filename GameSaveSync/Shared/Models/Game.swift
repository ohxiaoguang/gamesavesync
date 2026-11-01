import Foundation

/// A configured game.
///
/// Two directories are stored, never an absolute path as the source of truth:
/// - a security-scoped bookmark for the *authorised root* (usually the game's `Documents` folder);
/// - `syncRelativePath`, the folder inside that root which is actually synced (`""` = the root).
///
/// Splitting the two means a game that deletes and recreates its `saves` folder no longer
/// invalidates the grant: the root bookmark stays valid and the sync folder is re-derived from it.
public struct Game: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var gameId: String
    /// Security-scoped bookmark for the folder the user authorised.
    public var accessRootBookmark: Data
    /// Human readable hint for the root, e.g. `Documents`.
    public var accessRootHint: String
    /// Folder inside the root that is synced. Empty means the root itself.
    public var syncRelativePath: String
    /// Configurations saved before access roots existed point straight at the save folder.
    /// They still work, but the user is asked to move the grant up to `Documents`.
    public var accessRootIsLegacy: Bool
    public var lastLocalModified: Date?
    public var lastCloudModified: Date?
    public var lastSync: SyncRecord?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                gameId: String,
                accessRootBookmark: Data,
                accessRootHint: String,
                syncRelativePath: String = "",
                accessRootIsLegacy: Bool = false,
                lastLocalModified: Date? = nil,
                lastCloudModified: Date? = nil,
                lastSync: SyncRecord? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.gameId = gameId
        self.accessRootBookmark = accessRootBookmark
        self.accessRootHint = accessRootHint
        self.syncRelativePath = syncRelativePath
        self.accessRootIsLegacy = accessRootIsLegacy
        self.lastLocalModified = lastLocalModified
        self.lastCloudModified = lastCloudModified
        self.lastSync = lastSync
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the UI shows for the sync target: `Documents` or `Documents / saves`.
    public var syncPathDescription: String {
        let root = accessRootHint
        if syncRelativePath.isEmpty { return root }
        if root.isEmpty { return syncRelativePath }
        return "\(root) / \(syncRelativePath)"
    }

    /// True when the sync folder is the authorised folder itself.
    public var syncsWholeRoot: Bool { syncRelativePath.isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, name, gameId
        case accessRootBookmark, accessRootHint, syncRelativePath, accessRootIsLegacy
        // Written by versions that only knew about a single folder.
        case localFolderBookmark, localFolderHint
        case lastLocalModified, lastCloudModified, lastSync, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        gameId = try container.decode(String.self, forKey: .gameId)

        if let bookmark = try container.decodeIfPresent(Data.self, forKey: .accessRootBookmark) {
            accessRootBookmark = bookmark
            accessRootHint = try container.decodeIfPresent(String.self, forKey: .accessRootHint) ?? ""
            syncRelativePath = try container.decodeIfPresent(String.self, forKey: .syncRelativePath) ?? ""
            accessRootIsLegacy = try container.decodeIfPresent(Bool.self, forKey: .accessRootIsLegacy) ?? false
        } else if let legacy = try container.decodeIfPresent(Data.self, forKey: .localFolderBookmark) {
            // Old configuration: the bookmark points at the save folder itself. Keep it usable as
            // the root, remember that it is legacy, and let the user lift the grant later.
            accessRootBookmark = legacy
            accessRootHint = try container.decodeIfPresent(String.self, forKey: .localFolderHint) ?? ""
            syncRelativePath = ""
            accessRootIsLegacy = true
        } else {
            throw DecodingError.dataCorruptedError(forKey: .accessRootBookmark,
                                                   in: container,
                                                   debugDescription: "Game has no folder bookmark.")
        }

        lastLocalModified = try container.decodeIfPresent(Date.self, forKey: .lastLocalModified)
        lastCloudModified = try container.decodeIfPresent(Date.self, forKey: .lastCloudModified)
        lastSync = try container.decodeIfPresent(SyncRecord.self, forKey: .lastSync)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(gameId, forKey: .gameId)
        try container.encode(accessRootBookmark, forKey: .accessRootBookmark)
        try container.encode(accessRootHint, forKey: .accessRootHint)
        try container.encode(syncRelativePath, forKey: .syncRelativePath)
        try container.encode(accessRootIsLegacy, forKey: .accessRootIsLegacy)
        try container.encodeIfPresent(lastLocalModified, forKey: .lastLocalModified)
        try container.encodeIfPresent(lastCloudModified, forKey: .lastCloudModified)
        try container.encodeIfPresent(lastSync, forKey: .lastSync)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct SyncRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case uploaded
        case uploadedPendingICloud
        case restored
        case restoredHistory
        case upToDate
        case failed
    }

    public var kind: Kind
    public var date: Date
    public var detail: String?
    public var fileCount: Int?
    public var totalBytes: Int64?

    public init(kind: Kind, date: Date = Date(), detail: String? = nil, fileCount: Int? = nil, totalBytes: Int64? = nil) {
        self.kind = kind
        self.date = date
        self.detail = detail
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }

    public var isSuccess: Bool {
        switch kind {
        case .failed: return false
        default: return true
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var cloudRootBookmark: Data?
    public var cloudRootHint: String?
    public var historyRetention: Int
    public var language: AppLanguage
    public var deviceName: String
    public var cloudRootIsICloud: Bool
    public var cloudSubpath: String

    public init(cloudRootBookmark: Data? = nil,
                cloudRootHint: String? = nil,
                historyRetention: Int = 3,
                language: AppLanguage = .system,
                deviceName: String = AppSettings.defaultDeviceName,
                cloudRootIsICloud: Bool = false,
                cloudSubpath: String = "GameSaveSync") {
        self.cloudRootBookmark = cloudRootBookmark
        self.cloudRootHint = cloudRootHint
        self.historyRetention = historyRetention
        self.language = language
        self.deviceName = deviceName
        self.cloudRootIsICloud = cloudRootIsICloud
        self.cloudSubpath = cloudSubpath
    }

    public static var defaultDeviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDeviceName.current
        #endif
    }

    public var localizer: Localizer { Localizer(language: language.resolved) }

    enum CodingKeys: String, CodingKey {
        case cloudRootBookmark, cloudRootHint, historyRetention, language, deviceName, cloudRootIsICloud, cloudSubpath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cloudRootBookmark = try container.decodeIfPresent(Data.self, forKey: .cloudRootBookmark)
        cloudRootHint = try container.decodeIfPresent(String.self, forKey: .cloudRootHint)
        historyRetention = try container.decodeIfPresent(Int.self, forKey: .historyRetention) ?? 3
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? AppSettings.defaultDeviceName
        cloudRootIsICloud = try container.decodeIfPresent(Bool.self, forKey: .cloudRootIsICloud) ?? false
        cloudSubpath = try container.decodeIfPresent(String.self, forKey: .cloudSubpath) ?? "GameSaveSync"
        if historyRetention < 1 { historyRetention = 1 }
        if historyRetention > 20 { historyRetention = 20 }
    }
}

#if os(iOS)
import UIKit

enum UIDeviceName {
    static var current: String {
        UIDevice.current.name
    }
}
#endif
