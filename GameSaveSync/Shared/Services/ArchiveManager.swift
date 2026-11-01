import Foundation

/// Turns a scanned save folder into a ZIP archive and back.
///
/// ZIP stores timestamps with 2-second resolution and no time zone, so each archive also carries
/// a `.gamesavesync-archive.json` sidecar with exact modification dates. On extraction the sidecar
/// is applied and then removed from the save folder.
public enum ArchiveManager {
    public struct Metadata: Codable, Sendable {
        public struct FileRecord: Codable, Sendable {
            public var path: String
            public var modifiedAt: Date
            public var size: Int64

            public init(path: String, modifiedAt: Date, size: Int64) {
                self.path = path
                self.modifiedAt = modifiedAt
                self.size = size
            }
        }

        public var tool: String
        public var version: Int
        public var createdAt: Date
        public var saveModifiedAt: Date?
        public var contentHash: String
        public var fileCount: Int
        public var totalBytes: Int64
        public var files: [FileRecord]
        public var directories: [String]
    }

    public static let metadataVersion = 1

    /// Archives over this size are rejected rather than risking memory exhaustion on a phone.
    public static let maxArchiveInputBytes: Int64 = 4 << 30

    @discardableResult
    public static func createArchive(from scan: ScanResult,
                                     to zipURL: URL,
                                     gameId: String,
                                     saveModifiedAt: Date?) throws -> Metadata {
        guard scan.snapshot.totalBytes <= maxArchiveInputBytes else {
            throw SyncError.archiveTooLarge(ByteText.string(scan.snapshot.totalBytes))
        }

        var entries: [ZipEntrySource] = []
        var fileRecords: [Metadata.FileRecord] = []

        let sortedDirectories = scan.directories.sorted()
        for directory in sortedDirectories {
            entries.append(ZipEntrySource(path: directory + "/",
                                          modificationDate: saveModifiedAt ?? Date(),
                                          isDirectory: true))
        }

        for file in scan.files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let data: Data
            do {
                data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            } catch {
                throw SyncError.generic("Could not read \(file.relativePath): \(error.localizedDescription)")
            }
            entries.append(ZipEntrySource(path: file.relativePath,
                                          data: data,
                                          modificationDate: file.modified))
            fileRecords.append(Metadata.FileRecord(path: file.relativePath,
                                                   modifiedAt: file.modified,
                                                   size: file.size))
        }

        let metadata = Metadata(tool: "GameSaveSync",
                                version: metadataVersion,
                                createdAt: Date(),
                                saveModifiedAt: saveModifiedAt,
                                contentHash: scan.snapshot.contentHash,
                                fileCount: scan.files.count,
                                totalBytes: scan.snapshot.totalBytes,
                                files: fileRecords,
                                directories: sortedDirectories)

        let metadataData = try Coders.encode(metadata)
        entries.append(ZipEntrySource(path: SavePathFilter.archiveMetadataName,
                                      data: metadataData,
                                      modificationDate: Date()))

        try? FileManager.default.removeItem(at: zipURL)
        try ZipWriter.write(entries: entries, to: zipURL)
        Log.write("archive \(zipURL.lastPathComponent) game=\(gameId) files=\(fileRecords.count) bytes=\(scan.snapshot.totalBytes)")
        return metadata
    }

    /// Extracts an archive and restores exact modification dates from the sidecar.
    @discardableResult
    public static func extract(zipURL: URL, to destination: URL) throws -> Metadata? {
        do {
            try ZipReader.extract(at: zipURL, to: destination)
        } catch let error as ZipError {
            switch error {
            case .unsafePath(let path):
                throw SyncError.unsafeArchivePath(path)
            case .tooLarge(let detail):
                throw SyncError.archiveTooLarge(detail)
            case .unsupportedZip64(let detail):
                throw SyncError.archiveCorrupt(detail)
            case .checksumMismatch(let detail), .readFailed(let detail), .writeFailed(let detail):
                throw SyncError.archiveCorrupt(detail)
            }
        }

        let metadataURL = destination.appendingPathComponent(SavePathFilter.archiveMetadataName)
        var metadata: Metadata?
        if let data = try? Data(contentsOf: metadataURL) {
            metadata = try? Coders.decode(Metadata.self, from: data)
        }

        if let metadata {
            let fm = FileManager.default
            for record in metadata.files {
                let fileURL = destination.appendingPathComponent(record.path)
                guard FileSystem.exists(fileURL) else { continue }
                try? fm.setAttributes([.modificationDate: record.modifiedAt], ofItemAtPath: fileURL.path)
            }
            // Give directories their newest child timestamp so listings look natural.
            for directory in metadata.directories.sorted(by: { $0.count > $1.count }) {
                let directoryURL = destination.appendingPathComponent(directory)
                guard FileSystem.exists(directoryURL) else { continue }
                let newest = metadata.files
                    .filter { $0.path.hasPrefix(directory + "/") }
                    .map(\.modifiedAt)
                    .max()
                if let newest {
                    try? fm.setAttributes([.modificationDate: newest], ofItemAtPath: directoryURL.path)
                }
            }
        }

        try? FileManager.default.removeItem(at: metadataURL)
        return metadata
    }

    /// Re-reads a freshly extracted folder and compares it with the expected fingerprint.
    public static func verifyExtractedFolder(_ directory: URL,
                                             expectedHash: String,
                                             expectedFileCount: Int? = nil) throws -> SaveSnapshot {
        let snapshot = try SaveScanner().scan(directory: directory, computeHash: true).snapshot
        if let expectedFileCount, snapshot.fileCount != expectedFileCount {
            throw SyncError.cloudVerificationFailed
        }
        guard snapshot.contentHash == expectedHash else {
            throw SyncError.cloudVerificationFailed
        }
        return snapshot
    }
}
