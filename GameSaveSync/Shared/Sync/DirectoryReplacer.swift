import Foundation

/// Swaps the contents of a save folder without ever leaving it in a half-written state.
///
/// The new files are staged *inside* the destination folder, so the operation never needs write
/// access to the parent directory. That matters on iOS, where a security scope covers the chosen
/// folder and its descendants but not its siblings.
public enum DirectoryReplacer {
    public struct Leftover: Identifiable, Sendable {
        public enum Kind: String, Sendable {
            /// Files that were moved aside by an interrupted replacement.
            case previous
            /// A staged extraction that never got committed.
            case staging
        }

        public var id: String { url.path }
        public let url: URL
        public let kind: Kind
        public let modified: Date?
        public let fileCount: Int
    }

    public static func makeStagingDirectory(in destination: URL) throws -> URL {
        let url = destination.appendingPathComponent(SavePathFilter.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SyncError.folderCreationFailed(error.localizedDescription)
        }
        return url
    }

    /// Moves every existing child into a temporary folder, moves the staged files in, then
    /// deletes the old copies. Any failure rolls the original files back into place.
    public static func commit(staging: URL, into destination: URL) throws {
        let fm = FileManager.default
        let previousName = SavePathFilter.previousPrefix + UUID().uuidString
        let previous = destination.appendingPathComponent(previousName, isDirectory: true)

        let existingChildren: [URL]
        do {
            existingChildren = try fm.contentsOfDirectory(at: destination,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [])
        } catch {
            throw SyncError.replaceFailed(recovered: true, detail: error.localizedDescription)
        }

        do {
            try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        } catch {
            throw SyncError.replaceFailed(recovered: true, detail: error.localizedDescription)
        }

        var movedAside: [String] = []
        var movedIn: [String] = []

        do {
            for child in existingChildren {
                let name = child.lastPathComponent
                if child.standardizedFileURL.path == staging.standardizedFileURL.path { continue }
                if SavePathFilter.isReservedDirectoryName(name) { continue }
                try fm.moveItem(at: child, to: previous.appendingPathComponent(name))
                movedAside.append(name)
            }

            let stagedChildren = try fm.contentsOfDirectory(at: staging,
                                                            includingPropertiesForKeys: nil,
                                                            options: [])
            for child in stagedChildren {
                let name = child.lastPathComponent
                try fm.moveItem(at: child, to: destination.appendingPathComponent(name))
                movedIn.append(name)
            }
        } catch {
            let recovered = rollback(destination: destination,
                                     previous: previous,
                                     movedAside: movedAside,
                                     movedIn: movedIn)
            throw SyncError.replaceFailed(recovered: recovered, detail: error.localizedDescription)
        }

        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: previous)
    }

    private static func rollback(destination: URL, previous: URL, movedAside: [String], movedIn: [String]) -> Bool {
        let fm = FileManager.default
        var recovered = true
        for name in movedIn {
            do {
                try fm.removeItem(at: destination.appendingPathComponent(name))
            } catch {
                recovered = false
            }
        }
        for name in movedAside {
            let source = previous.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            guard FileSystem.exists(source) else { continue }
            do {
                try fm.moveItem(at: source, to: target)
            } catch {
                recovered = false
            }
        }
        if recovered {
            try? fm.removeItem(at: previous)
        }
        return recovered
    }

    /// Finds folders left behind by an interrupted replacement or extraction.
    public static func leftovers(in directory: URL) -> [Leftover] {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                                          options: []) else {
            return []
        }
        var results: [Leftover] = []
        for child in children {
            let name = child.lastPathComponent
            let kind: Leftover.Kind
            if name.hasPrefix(SavePathFilter.previousPrefix) {
                kind = .previous
            } else if name.hasPrefix(SavePathFilter.stagingPrefix) {
                kind = .staging
            } else {
                continue
            }
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let count = recursiveFileCount(child)
            results.append(Leftover(url: child, kind: kind, modified: modified, fileCount: count))
        }
        return results
    }

    private static func recursiveFileCount(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        var count = 0
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    /// Puts the files from an interrupted replacement back, without overwriting newer files.
    public static func restoreLeftover(_ leftover: Leftover, into directory: URL) throws {
        guard leftover.kind == .previous else { throw SyncError.generic("Nothing to restore.") }
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: leftover.url, includingPropertiesForKeys: nil, options: [])
        do {
            for child in children {
                let target = directory.appendingPathComponent(child.lastPathComponent)
                if FileSystem.exists(target) { continue }
                try fm.moveItem(at: child, to: target)
            }
            try? fm.removeItem(at: leftover.url)
        } catch {
            throw SyncError.replaceFailed(recovered: false, detail: error.localizedDescription)
        }
    }

    public static func discardLeftover(_ leftover: Leftover) {
        try? FileManager.default.removeItem(at: leftover.url)
    }
}
