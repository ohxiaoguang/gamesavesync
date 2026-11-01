import Foundation
import CryptoKit

public struct ScannedFile: Sendable {
    public let relativePath: String
    public let url: URL
    public let size: Int64
    public let modified: Date
}

public struct ScanResult: Sendable {
    public var snapshot: SaveSnapshot
    public var files: [ScannedFile]
    /// Directory paths relative to the root, including empty ones.
    public var directories: [String]

    public var isEmpty: Bool { files.isEmpty }
}

/// Recursively reads a save directory and derives a stable fingerprint from it.
///
/// The fingerprint is the newest *file* modification time plus a SHA-256 over the sorted
/// relative paths and file contents. Folder timestamps, archive timestamps and download
/// timestamps are never used to decide which side is newer.
public struct SaveScanner: Sendable {
    public init() {}

    public func scan(directory: URL, computeHash: Bool = true) throws -> ScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.localFolderUnavailable
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .fileSizeKey]
        let rootPath = directory.standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: keys,
                                             options: [],
                                             errorHandler: { _, _ in true }) else {
            throw SyncError.localFolderUnavailable
        }

        var files: [ScannedFile] = []
        var directories: [String] = []
        var totalBytes: Int64 = 0
        var newest: Date?
        var readFailure: String?

        for case let url as URL in enumerator {
            let relative = Self.relativePath(of: url, rootPath: rootPath)
            guard !relative.isEmpty else { continue }

            if SavePathFilter.isExcluded(relativePath: relative) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                readFailure = error.localizedDescription
                continue
            }

            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                let name = url.lastPathComponent
                if SavePathFilter.isReservedDirectoryName(name) {
                    enumerator.skipDescendants()
                    continue
                }
                directories.append(relative)
                continue
            }

            guard values.isRegularFile == true else { continue }

            let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let size = Int64(values.fileSize ?? 0)
            files.append(ScannedFile(relativePath: relative, url: url, size: size, modified: modified))
            totalBytes += size
            if newest == nil || modified > newest! {
                newest = modified
            }
        }

        if let readFailure {
            throw SyncError.generic("Could not read the save folder: \(readFailure)")
        }

        var hash = ""
        if computeHash {
            hash = try hashFiles(files)
        }

        // An empty folder has no meaningful timestamp of its own; keep it nil and let the
        // hash/emptiness decide instead of trusting a folder modification date.
        let snapshot = SaveSnapshot(newestModified: files.isEmpty ? nil : newest,
                                    fileCount: files.count,
                                    directoryCount: directories.count,
                                    totalBytes: totalBytes,
                                    contentHash: hash)
        return ScanResult(snapshot: snapshot, files: files, directories: directories)
    }

    public func hash(directory: URL) throws -> SaveSnapshot {
        try scan(directory: directory, computeHash: true).snapshot
    }

    public static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(path.dropFirst(rootPath.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    private func hashFiles(_ files: [ScannedFile]) throws -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0x00]))
            hasher.update(data: Data(String(file.size).utf8))
            hasher.update(data: Data([0x00]))

            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: file.url)
            } catch {
                throw SyncError.generic("Could not read \(file.relativePath): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            hasher.update(data: Data([0xFE]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
