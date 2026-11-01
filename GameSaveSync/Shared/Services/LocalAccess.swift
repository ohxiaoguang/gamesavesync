import Foundation

/// The two directory concepts a game configuration has:
///
/// - `root`: the folder the sandbox actually authorised (usually the game's `Documents` folder).
/// - `syncDirectory`: `root` plus `relativePath`, which is the only folder GameSaveSync ever reads,
///   packs, hashes or overwrites.
///
/// The access root is what survives in the security-scoped bookmark. The sync target is stored as
/// a relative path only, so a folder that a game deletes and recreates at the same place keeps
/// working: the next launch re-derives it from the still-valid root.
public struct LocalAccess: Sendable, Equatable {
    public let root: URL
    /// Path relative to `root`. An empty string means "sync the authorised folder itself".
    public let relativePath: String
    public let syncDirectory: URL

    public init(root: URL, relativePath: String, syncDirectory: URL) {
        self.root = root
        self.relativePath = relativePath
        self.syncDirectory = syncDirectory
    }

    public var syncsWholeRoot: Bool { relativePath.isEmpty }

    /// "Documents / saves" — what the UI shows.
    public var displayPath: String {
        syncsWholeRoot ? root.lastPathComponent : "\(root.lastPathComponent)/\(relativePath)"
    }
}

/// Validation and resolution of the relative sync path.
///
/// The relative path comes from stored configuration, so it is treated as untrusted input: it may
/// never be absolute, may never contain `.`/`..`, and may never cross a symlink that leaves the
/// authorised root.
public enum SyncPath {
    /// Guards against runaway nesting from a corrupted configuration.
    public static let maximumDepth = 16

    /// Returns the normalised path (`""` for the root itself) or `nil` when it is not safe.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("/") { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= maximumDepth else { return nil }
        for part in parts {
            if part == "." || part == ".." { return nil }
            if part.contains("\0") { return nil }
            if SavePathFilter.isReservedDirectoryName(part) { return nil }
            if SavePathFilter.isExcluded(relativePath: part) { return nil }
        }
        return parts.joined(separator: "/")
    }

    /// Resolves `relativePath` inside `root`, rejecting anything that would leave it.
    public static func resolve(root: URL, relativePath: String) throws -> URL {
        guard let normalized = normalize(relativePath) else {
            throw SyncError.invalidSyncPath(relativePath)
        }
        guard !normalized.isEmpty else { return root }

        let candidate = root.appendingPathComponent(normalized, isDirectory: true)
        guard isInside(candidate, root: root) else {
            throw SyncError.invalidSyncPath(relativePath)
        }
        // A symlinked component could point outside the authorised tree even though the string
        // prefix check passed, so walk the components that exist and inspect them.
        if containsSymlink(root: root, normalizedPath: normalized) {
            throw SyncError.invalidSyncPath(relativePath)
        }
        // Compare canonical paths: the sync folder may not exist yet, and a not-yet-created child
        // would otherwise be compared with a symlink-resolved root and look like an escape.
        let realRoot = FileSystem.canonicalPath(for: root)
        let realCandidate = FileSystem.canonicalPath(for: candidate)
        guard realCandidate == realRoot || realCandidate.hasPrefix(realRoot + "/") else {
            throw SyncError.invalidSyncPath(relativePath)
        }
        return candidate
    }

    public static func isInside(_ candidate: URL, root: URL) -> Bool {
        // Canonical paths, because `standardizedFileURL` resolves symlinks only for parts that
        // already exist — which made a missing sync folder look like an escaped path.
        let rootPath = FileSystem.canonicalPath(for: root)
        let candidatePath = FileSystem.canonicalPath(for: candidate)
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    /// The relative path of a folder the user picked elsewhere (the Files app), checked against
    /// the authorised root before it is stored.
    ///
    /// This exists because a folder inside a file provider cannot always be listed from inside the
    /// app: when the in-app browser cannot enumerate it, the system picker still can, and the only
    /// thing this app keeps is the relative path.
    public static func relativePath(of candidate: URL, inside root: URL) throws -> String {
        let realRoot = FileSystem.canonicalPath(for: root)
        let realCandidate = FileSystem.canonicalPath(for: candidate)
        if realCandidate == realRoot { return "" }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realCandidate.hasPrefix(prefix) else {
            throw SyncError.invalidSyncPath(realCandidate)
        }
        let relative = String(realCandidate.dropFirst(prefix.count))
        guard let normalized = normalize(relative), !normalized.isEmpty else {
            throw SyncError.invalidSyncPath(relative)
        }
        return normalized
    }

    /// True when one of the components below `root` is a symbolic link. Stops at the first
    /// component that does not exist, because nothing below it can be a link yet.
    public static func containsSymlink(root: URL, normalizedPath: String) -> Bool {
        var current = root
        for part in normalizedPath.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            guard FileSystem.exists(current) else { return false }
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// Subdirectories of `directory`, already filtered to what may be chosen as a sync target.
    ///
    /// Throws instead of returning an empty list when the directory cannot be read: on a real
    /// device that is usually a missing security scope or an unavailable file provider, and
    /// reporting it as "no subfolders" sent people looking for a problem that was not there.
    ///
    /// The read goes through `NSFileCoordinator` because folders served by a file provider — which
    /// is what another app's container is — are only enumerated reliably as a coordinated read;
    /// without it the call can block until the provider decides to answer.
    public static func subdirectories(of directory: URL) throws -> [URL] {
        var coordinationError: NSError?
        var outcome: Result<[URL], Error> = .success([])
        NSFileCoordinator().coordinate(readingItemAt: directory,
                                       options: [.withoutChanges],
                                       error: &coordinationError) { coordinatedURL in
            do {
                outcome = .success(try readSubdirectories(of: coordinatedURL))
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    private static func readSubdirectories(of directory: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return children.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Resolves a stored game configuration into concrete URLs.
public enum LocalAccessResolver {
    public struct Resolution: Sendable {
        public var access: LocalAccess
        /// True when the stored bookmark should be rewritten.
        public var bookmarkIsStale: Bool
    }

    /// Bookmark resolution failures mean the grant itself is gone; a missing sync folder is a
    /// different, much more common situation and must not be reported as a lost authorisation.
    public static func resolve(game: Game) throws -> Resolution {
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try DirectoryAccessManager.resolve(game.accessRootBookmark)
        } catch {
            throw SyncError.accessRootUnavailable(detail: error.localizedDescription)
        }
        // A stored path that no longer normalises cleanly must fail loudly instead of silently
        // falling back to the whole authorised root.
        guard let normalized = SyncPath.normalize(game.syncRelativePath) else {
            throw SyncError.invalidSyncPath(game.syncRelativePath)
        }
        let syncDirectory: URL
        do {
            syncDirectory = try SyncPath.resolve(root: resolved.url, relativePath: normalized)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.invalidSyncPath(game.syncRelativePath)
        }
        let access = LocalAccess(root: resolved.url,
                                 relativePath: normalized,
                                 syncDirectory: syncDirectory)
        return Resolution(access: access, bookmarkIsStale: resolved.isStale)
    }

    /// Rewrites the bookmark while its security scope is held. Creating a bookmark for a URL
    /// whose scope is not active produces a bookmark that cannot be resolved later, which used to
    /// look exactly like a lost authorisation.
    public static func refreshBookmark(for access: LocalAccess, in game: inout Game) {
        let scope = ScopedAccess(url: access.root)
        defer { scope.stop() }
        guard let data = try? DirectoryAccessManager.bookmark(for: access.root) else { return }
        game.accessRootBookmark = data
    }
}

/// Bounds the wait for synchronous file-provider work. A task group cannot implement this:
/// leaving its scope waits for every child, even when a child is stuck in a provider call.
enum BrowserFileOperation {
    enum Failure: Error { case timedOut }

    static func run<Value: Sendable>(
        timeout: Duration = .seconds(12),
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<Result<Value, Error>>.makeStream()
        // Unstructured work may outlive the wait. Its closure must hold any security scopes
        // until the actual file operation returns, including after a timeout or dismissal.
        let worker = Task.detached(priority: .userInitiated) {
            continuation.yield(Result { try operation() })
            continuation.finish()
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.failure(Failure.timedOut))
                continuation.finish()
            } catch { }
        }
        defer {
            worker.cancel()
            timer.cancel()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return try result.get()
    }
}
