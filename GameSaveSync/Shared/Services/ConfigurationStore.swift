import Foundation

/// Persists game configurations and settings inside the app container.
public struct ConfigurationStore {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func loadGames() -> [Game] {
        guard let data = try? Data(contentsOf: paths.gamesFile) else { return [] }
        guard let games = try? Coders.decode([Game].self, from: data) else {
            Log.write("games.json could not be decoded; starting empty")
            return []
        }
        return games
    }

    public func saveGames(_ games: [Game]) throws {
        try paths.ensureDirectories()
        let data = try Coders.encode(games)
        try FileSystem.atomicWrite(data, to: paths.gamesFile)
    }

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return AppSettings() }
        return (try? Coders.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try paths.ensureDirectories()
        let data = try Coders.encode(settings)
        try FileSystem.atomicWrite(data, to: paths.settingsFile)
    }
}

/// Security-scoped bookmarks.
///
/// iOS and macOS differ: macOS needs `.withSecurityScope` for bookmarks that survive a relaunch
/// inside the App Sandbox, while iOS restores access from a plain bookmark created for a URL the
/// document picker handed over.
public enum DirectoryAccessManager {
    public static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #else
        return try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #endif
    }

    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        #else
        let url = try URL(resolvingBookmarkData: data,
                          options: [],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        #endif
        return (url, isStale)
    }

    /// Runs `body` with the security scope held open for the whole call.
    public static func withAccess<T>(_ data: Data, _ body: (URL, Bool) throws -> T) throws -> T {
        let resolved = try resolve(data)
        let access = ScopedAccess(url: resolved.url)
        defer { access.stop() }
        return try body(resolved.url, resolved.isStale)
    }
}

/// Keeps a security scope alive for the duration of an operation that hops between threads.
public final class ScopedAccess {
    public let url: URL
    private var started: Bool

    public init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    public func stop() {
        guard started else { return }
        started = false
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        stop()
    }
}

public enum PathHint {
    public static func describe(_ url: URL) -> String {
        #if os(iOS)
        // On iOS the absolute container path is meaningless to the user; show a readable tail.
        let components = url.pathComponents.filter { $0 != "/" }
        if let index = components.firstIndex(of: "com~apple~CloudDocs") {
            let tail = components[(index + 1)...].joined(separator: "/")
            return tail.isEmpty ? "iCloud Drive" : "iCloud Drive/" + tail
        }
        if let index = components.firstIndex(of: "Documents") {
            return components[index...].joined(separator: "/")
        }
        if let index = components.firstIndex(of: "File Provider Storage") {
            let tail = components[(index + 1)...].joined(separator: "/")
            if !tail.isEmpty { return tail }
        }
        return components.suffix(2).joined(separator: "/")
        #else
        return FileSystem.displayPath(for: url)
        #endif
    }
}
