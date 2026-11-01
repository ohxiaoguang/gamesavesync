import Foundation
import CryptoKit

#if os(iOS)
import UIKit
#endif

/// Every URL the app needs, all inside the app container.
public struct AppPaths: Sendable {
    public let container: URL

    public init(container: URL) {
        self.container = container
    }

    public var support: URL { container.appendingPathComponent("GameSaveSync", isDirectory: true) }
    public var gamesFile: URL { support.appendingPathComponent("games.json") }
    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    public var work: URL { support.appendingPathComponent("Work", isDirectory: true) }
    public var logs: URL { support.appendingPathComponent("Logs", isDirectory: true) }

    public static func standard() -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AppPaths(container: base)
    }

    /// Container used for this launch. `-GSSDemoSeed` (UI tests, manual layout checks) writes to a
    /// throwaway container so sample data never mixes with a real installation.
    public static func launch() -> AppPaths {
        guard ProcessInfo.processInfo.arguments.contains("-GSSDemoSeed") else { return standard() }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameSaveSyncDemoContainer", isDirectory: true)
        return AppPaths(container: base)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [support, backups, work, logs] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A fresh, unique working directory that the caller is responsible for deleting.
    public func makeWorkDirectory(name: String) throws -> URL {
        try ensureDirectories()
        let url = work.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum FileSystem {
    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Writes `data` to `url` through a temporary sibling file so a failed write never leaves a
    /// truncated file behind. Used for manifest/marker files that are small.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            if FileSystem.exists(url) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public static func copyItem(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileSystem.exists(destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public static func removeIfExists(_ url: URL) {
        guard FileSystem.exists(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Frees a URL's coordinated access. On iOS the security scope must wrap every file access.
    public static func withSecurityScope<T>(_ url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    /// Absolute path with symlinks resolved for the part that exists.
    ///
    /// `standardizedFileURL` is not enough on its own: it resolves `/var` → `/private/var` for
    /// paths that exist but leaves them alone for paths that do not, so comparing a folder with a
    /// not-yet-created child inside it produced false "outside the folder" results.
    public static func canonicalPath(for url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !exists(existing) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        let base = existing.resolvingSymlinksInPath().standardizedFileURL.path
        guard !tail.isEmpty else { return base }
        return base.hasSuffix("/") ? base + tail.joined(separator: "/") : base + "/" + tail.joined(separator: "/")
    }

    public static func displayPath(for url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Files the app never treats as save data. Applied consistently by the scanner, the archiver
/// and the replace step so all three agree on what a save folder contains.
public enum SavePathFilter {
    public static let archiveMetadataName = ".gamesavesync-archive.json"
    public static let stagingPrefix = ".gamesavesync-stage-"
    public static let previousPrefix = ".gamesavesync-previous-"

    public static func isExcluded(relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if name.isEmpty { return true }
        if name == ".DS_Store" { return true }
        if name.hasPrefix("._") { return true }
        if name == archiveMetadataName { return true }
        if name.hasPrefix(stagingPrefix) { return true }
        if name.hasPrefix(previousPrefix) { return true }
        if name.hasPrefix(".gamesavesync-tmp") { return true }
        return false
    }

    public static func isReservedDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(stagingPrefix) || name.hasPrefix(previousPrefix)
    }
}

public enum Log {
    private static let queue = DispatchQueue(label: "com.gamesavesync.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static func write(_ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        let stamp = formatter.string(from: Date())
        let name = file.split(separator: "/").last.map(String.init) ?? file
        Swift.print("[\(stamp)] \(name):\(line) \(message)")
        #endif
    }

    /// Appends to a rolling file log inside the app container. Useful on devices where the
    /// console is not attached.
    public static func persist(_ message: String, to directory: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("gamesavesync.log")
                let line = "\(formatter.string(from: Date())) \(message)\n"
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                } else {
                    try Data(line.utf8).write(to: url)
                }
            } catch {
                // Logging must never break an operation.
            }
        }
    }
}
