import XCTest
import Foundation

enum TestSupport {
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @discardableResult
    static func write(_ root: URL, _ path: String, _ contents: String, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    static func write(_ root: URL, _ path: String, data: Data, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func contents(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func modificationDate(_ root: URL, _ path: String) -> Date? {
        try? root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func relativeFileList(_ root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var paths: [String] = []
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                paths.append(SaveScanner.relativePath(of: item, rootPath: root.standardizedFileURL.path))
            }
        }
        return paths.sorted()
    }

    static func manifest(at cloudRoot: URL, gameId: String) throws -> CloudManifest {
        let url = cloudRoot.appendingPathComponent(gameId).appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try Coders.decode(CloudManifest.self, from: data)
    }
}
