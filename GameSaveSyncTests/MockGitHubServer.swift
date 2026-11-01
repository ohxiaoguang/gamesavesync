import Foundation
import CryptoKit

/// In-memory stand-in for the GitHub REST API.
///
/// It implements the subset of the Git Database API the app uses — repositories, refs, commits,
/// trees and blobs — with real content addressing, so the production `GitHubAPIClient` and
/// `GitHubStorageManager` run unmodified against it. Tests never need a real token or repository.
final class MockGitHubServer: @unchecked Sendable {
    static let token = "test-token-value"

    enum Fault {
        /// Answers with this status and message instead of running the request.
        case status(Int, String)
        /// Fails at the transport level, as if the connection dropped.
        case network(URLError.Code)
        /// Fails with this status once, then behaves normally.
        case rateLimited
    }

    struct Entry: Sendable, Equatable {
        var type: String
        var sha: String
    }

    struct Commit: Sendable {
        var sha: String
        var tree: String
        var parents: [String]
        var message: String
        var date: Date
    }

    private let lock = NSLock()

    var owner = "ohxiaoguang"
    var name = "game-saves"
    var isPrivate = true
    var defaultBranch = "main"
    var canPull = true
    var canPush = true
    var acceptedToken = MockGitHubServer.token

    private(set) var blobs: [String: Data] = [:]
    private(set) var trees: [String: [String: Entry]] = [:]
    private(set) var commits: [String: Commit] = [:]
    private(set) var refs: [String: String] = [:]
    private(set) var commitLog: [String] = []
    private(set) var requestLog: [String] = []
    /// "METHOD path status" for every answered request, so a test can assert which status the
    /// stand-in really produced (a 409 ref on an empty repository, for example).
    private(set) var statusLog: [String] = []

    /// Applied to the next request(s) in order.
    var faults: [Fault] = []
    /// Applied to every request until cleared; used to test bounded retries.
    var persistentFault: Fault?
    /// Applies a branch update and then fails the transport, as a dropped connection would.
    var failRefUpdateAfterApplying = false
    /// Answers every `PATCH /git/refs` with this fault before touching the branch.
    var refUpdateFault: Fault?
    /// Runs once, right before a branch update is processed. Lets a test simulate another device.
    var beforeRefUpdate: ((MockGitHubServer) -> Void)?
    /// When true, archive blob reads answer with corrupted bytes. Manifests are left intact so a
    /// test can isolate "the zip on the server is damaged" without also breaking the metadata.
    var corruptArchiveDownloads = false

    var baseURL: URL { URL(string: "https://\(host)")! }
    let host: String

    init(host: String = "mock-\(UUID().uuidString.lowercased()).github.test") {
        self.host = host
        MockGitHubRegistry.shared.register(self)
    }

    deinit {
        MockGitHubRegistry.shared.unregister(host: host)
    }

    // MARK: - Test helpers

    /// Simulates another client pushing a new version of a game, without going through HTTP.
    func simulateRemoteUpload(gameId: String,
                              manifest: CloudManifest,
                              archive: Data,
                              branch: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let branchName = branch ?? defaultBranch
        let parent = refs[branchName]
        let archiveBlob = storeBlob(archive)
        let manifestBlob = storeBlob(try! Coders.encode(manifest))
        let baseTree = parent.flatMap { commits[$0]?.tree }
        let tree = buildTree(base: baseTree, entries: [
            (GitHubLayout.archivePath(gameId: gameId, fileName: manifest.archiveFileName), archiveBlob),
            (GitHubLayout.manifestPath(gameId: gameId), manifestBlob)
        ])
        let commit = storeCommit(tree: tree, parents: parent.map { [$0] } ?? [], message: "external", date: Date())
        refs[branchName] = commit
    }

    func manifest(at commit: String, gameId: String) -> CloudManifest? {
        lock.lock(); defer { lock.unlock() }
        guard let sha = blobSHA(at: commit, path: GitHubLayout.manifestPath(gameId: gameId)),
              let data = blobs[sha] else { return nil }
        return try? Coders.decode(CloudManifest.self, from: data)
    }

    func archiveData(at commit: String, gameId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let sha = blobSHA(at: commit, path: GitHubLayout.archivePath(gameId: gameId, fileName: "save.zip")) else { return nil }
        return blobs[sha]
    }

    var headCommit: String? {
        lock.lock(); defer { lock.unlock() }
        return refs[defaultBranch]
    }

    func branchHead(_ branch: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return refs[branch]
    }

    var repositoryIsEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return refs.isEmpty
    }

    /// Called by `MockGitHubProtocol` so tests can assert the status a request really received.
    func record(method: String, path: String, status: Int) {
        lock.lock(); defer { lock.unlock() }
        statusLog.append("\(method) \(path) \(status)")
    }

    /// Puts the repository in the state a user's own repository is normally in: one commit on a
    /// branch, optionally with files already in it.
    func seedRepository(files: [String: String] = ["README.md": "# Save archives\n"],
                        branch: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let branchName = branch ?? defaultBranch
        let entries = files.sorted { $0.key < $1.key }.map { ($0.key, storeBlob(Data($0.value.utf8))) }
        let tree = buildTree(base: nil, entries: entries)
        let commit = storeCommit(tree: tree, parents: [], message: "Initial commit", date: Date())
        refs[branchName] = commit
    }

    /// Contents of a file at a commit, for assertions about files the app must not touch.
    func fileContents(at commit: String, path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let sha = blobSHA(at: commit, path: path), let data = blobs[sha] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Git objects

    private func sha(_ data: Data, prefix: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(40).description
    }

    private func storeBlob(_ data: Data) -> String {
        let value = sha(data, prefix: "blob ")
        blobs[value] = data
        return value
    }

    private func storeTree(_ entries: [String: Entry]) -> String {
        let text = entries.keys.sorted().map { "\($0) \(entries[$0]!.type) \(entries[$0]!.sha)" }.joined(separator: "\n")
        let value = sha(Data(text.utf8), prefix: "tree ")
        trees[value] = entries
        return value
    }

    private func storeCommit(tree: String, parents: [String], message: String, date: Date) -> String {
        let text = "\(tree)|\(parents.joined(separator: ","))|\(message)|\(date.timeIntervalSince1970)"
        let value = sha(Data(text.utf8), prefix: "commit ")
        commits[value] = Commit(sha: value, tree: tree, parents: parents, message: message, date: date)
        commitLog.append(value)
        return value
    }

    private func buildTree(base: String?, entries: [(String, String)]) -> String {
        var root = base.flatMap { trees[$0] } ?? [:]
        for (path, blob) in entries {
            insert(path: path.split(separator: "/").map(String.init), blob: blob, into: &root)
        }
        return storeTree(root)
    }

    private func insert(path: [String], blob: String, into tree: inout [String: Entry]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            tree[head] = Entry(type: "blob", sha: blob)
            return
        }
        var child = tree[head].flatMap { trees[$0.sha] } ?? [:]
        insert(path: Array(path.dropFirst()), blob: blob, into: &child)
        tree[head] = Entry(type: "tree", sha: storeTree(child))
    }

    private func blobSHA(at commit: String, path: String) -> String? {
        guard let commit = commits[commit] else { return nil }
        var tree = trees[commit.tree]
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            guard let entry = tree?[part] else { return nil }
            tree = trees[entry.sha]
        }
        guard let final = parts.last, let entry = tree?[final], entry.type == "blob" else { return nil }
        return entry.sha
    }

    // MARK: - Request handling

    struct Response {
        var status: Int
        var body: Data
        var contentType: String = "application/json"
        var headers: [String: String] = [:]
    }

    func handle(method: String,
                path: String,
                query: [URLQueryItem],
                headers: [String: String],
                body: Data) -> Response {
        // Run the "another device pushed first" hook before taking the lock so the hook may call
        // the simulation helpers, which lock as well.
        if method == "PATCH", path.hasPrefix("/repos/"), path.contains("/git/refs/") {
            let hook = takeRefUpdateHook()
            hook?(self)
        }

        lock.lock(); defer { lock.unlock() }
        requestLog.append("\(method) \(path)")

        if let fault = persistentFault {
            return response(for: fault)
        }

        if let fault = faults.first {
            faults.removeFirst()
            return response(for: fault)
        }

        let authorization = headers["authorization"] ?? ""
        guard authorization == "Bearer \(acceptedToken)" else {
            return error(401, "Bad credentials")
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "repos" else { return error(404, "Not Found") }
        guard parts[1] == owner, parts[2] == name else { return error(404, "Not Found") }

        let rest = Array(parts.dropFirst(3))

        if rest.isEmpty, method == "GET" {
            return repositoryJSON()
        }

        if rest.first == "git" {
            return handleGit(method: method, rest: Array(rest.dropFirst()), query: query, headers: headers, body: body)
        }

        if rest.first == "commits", method == "GET" {
            return handleCommitList(query: query)
        }

        if rest.first == "contents" {
            return handleContents(method: method, path: Array(rest.dropFirst()), body: body)
        }

        return error(404, "Not Found")
    }

    private func takeRefUpdateHook() -> ((MockGitHubServer) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        let hook = beforeRefUpdate
        beforeRefUpdate = nil
        return hook
    }

    private func response(for fault: Fault) -> Response {
        switch fault {
        case .status(let code, let message):
            return error(code, message)
        case .rateLimited:
            return Response(status: 429,
                            body: Data(#"{"message":"API rate limit exceeded"}"#.utf8),
                            headers: ["retry-after": "3", "x-ratelimit-remaining": "0"])
        case .network(let code):
            return Response(status: -1, body: Data(), contentType: "error", headers: ["x-url-error": "\(code.rawValue)"])
        }
    }

    private func handleGit(method: String,
                           rest: [String],
                           query: [URLQueryItem],
                           headers: [String: String],
                           body: Data) -> Response {
        guard let section = rest.first else { return error(404, "Not Found") }
        let tail = Array(rest.dropFirst())

        switch (section, method) {
        case ("ref", "GET"):
            // /git/ref/heads/<branch>
            let branch = (tail.first == "heads" ? Array(tail.dropFirst()) : tail).joined(separator: "/")
            // GitHub answers 409 ("Git Repository is empty.") while the repository has no branch
            // at all, and 404 for a branch it does not have. Keeping both answers distinct is what
            // lets the app tell "set the repository up" from "create that branch".
            guard !refs.isEmpty else { return error(409, "Git Repository is empty.") }
            guard let sha = refs[branch] else { return error(404, "Not Found") }
            return json(["ref": "refs/heads/\(branch)",
                         "object": ["sha": sha, "type": "commit"]])

        case ("refs", "POST"):
            // GitHub refuses references while the repository has no branch at all.
            guard !refs.isEmpty else { return error(422, "Reference update failed") }
            guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let ref = payload["ref"] as? String,
                  let sha = payload["sha"] as? String else {
                return error(422, "Validation Failed")
            }
            let branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            guard refs[branch] == nil else { return error(422, "Reference already exists") }
            refs[branch] = sha
            return json(["ref": ref, "object": ["sha": sha]], status: 201)

        case ("refs", "PATCH"):
            // /git/refs/heads/<branch>
            if let fault = refUpdateFault { return response(for: fault) }
            let branch = (tail.first == "heads" ? Array(tail.dropFirst()) : tail).joined(separator: "/")
            guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let sha = payload["sha"] as? String else {
                return error(422, "Validation Failed")
            }
            guard let current = refs[branch] else { return error(404, "Not Found") }
            guard let commit = commits[sha] else { return error(422, "Object does not exist") }
            guard commit.parents.contains(current) else {
                return error(422, "Update is not a fast forward")
            }
            refs[branch] = sha
            if failRefUpdateAfterApplying {
                return Response(status: -1,
                                body: Data(),
                                contentType: "error",
                                headers: ["x-url-error": "\(URLError.timedOut.rawValue)"])
            }
            return json(["ref": "refs/heads/\(branch)", "object": ["sha": sha]])

        case ("commits", "POST"):
            guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let message = payload["message"] as? String,
                  let tree = payload["tree"] as? String else {
                return error(422, "Validation Failed")
            }
            guard trees[tree] != nil else { return error(422, "Tree does not exist") }
            let parents = payload["parents"] as? [String] ?? []
            let sha = storeCommit(tree: tree, parents: parents, message: message, date: Date())
            return json(["sha": sha, "tree": ["sha": tree], "message": message, "parents": parents.map { ["sha": $0] }],
                        status: 201)

        case ("commits", "GET"):
            let sha = tail.first ?? ""
            guard let commit = commits[sha] else { return error(404, "Not Found") }
            return json(["sha": commit.sha,
                         "tree": ["sha": commit.tree],
                         "message": commit.message,
                         "parents": commit.parents.map { ["sha": $0] }])

        case ("trees", "POST"):
            guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return error(422, "Validation Failed")
            }
            let base = payload["base_tree"] as? String
            let entries = (payload["tree"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
                guard let path = item["path"] as? String, let sha = item["sha"] as? String else { return nil }
                return (path, sha)
            }
            let tree = buildTree(base: base, entries: entries)
            // GitHub answers with the whole tree, not just the SHA.
            let list = (trees[tree] ?? [:]).map {
                ["path": $0.key, "mode": "100644", "type": $0.value.type, "sha": $0.value.sha]
            }
            return json(["sha": tree, "tree": list, "truncated": false], status: 201)

        case ("trees", "GET"):
            guard let sha = tail.first else { return error(404, "Not Found") }
            let treeSHA = trees[sha] != nil ? sha : commits[sha]?.tree
            guard let treeSHA, let entries = trees[treeSHA] else { return error(404, "Not Found") }
            let list = entries.map { ["path": $0.key, "mode": "100644", "type": $0.value.type, "sha": $0.value.sha] }
            return json(["sha": treeSHA, "tree": list, "truncated": false])

        case ("blobs", "POST"):
            guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let content = payload["content"] as? String,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                return error(422, "Validation Failed")
            }
            return json(["sha": storeBlob(data)], status: 201)

        case ("blobs", "GET"):
            guard let sha = tail.first, var data = blobs[sha] else { return error(404, "Not Found") }
            // Manifests are the only JSON blobs; everything else is an archive.
            if corruptArchiveDownloads, data.first != UInt8(ascii: "{") {
                data.append(Data(repeating: 0x00, count: 32))
            }
            // GitHub answers with base64 JSON unless the raw media type is requested.
            let accept = headers["accept"] ?? ""
            if accept.contains("raw") {
                return Response(status: 200, body: data, contentType: "application/octet-stream")
            }
            return json(["sha": sha,
                         "size": data.count,
                         "encoding": "base64",
                         "content": data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])])

        default:
            return error(404, "Not Found")
        }
    }

    /// `PUT /repos/{owner}/{repo}/contents/{path}` — the only way to write the first commit of a
    /// repository that has no branches.
    private func handleContents(method: String, path: [String], body: Data) -> Response {
        guard method == "PUT" else { return error(404, "Not Found") }
        let filePath = path.joined(separator: "/")
        guard !filePath.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = payload["message"] as? String,
              let content = payload["content"] as? String,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            return error(422, "Validation Failed")
        }

        let branch = (payload["branch"] as? String) ?? defaultBranch
        let parent = refs[branch]
        if parent == nil, !refs.isEmpty {
            // A repository that already has commits only accepts files on existing branches.
            return error(422, "Branch \(branch) not found")
        }
        if let parent, blobSHA(at: parent, path: filePath) != nil, payload["sha"] == nil {
            return error(422, "sha wasn't supplied")
        }

        let blob = storeBlob(data)
        let baseTree = parent.flatMap { commits[$0]?.tree }
        let tree = buildTree(base: baseTree, entries: [(filePath, blob)])
        let commit = storeCommit(tree: tree, parents: parent.map { [$0] } ?? [], message: message, date: Date())
        refs[branch] = commit
        return json(["content": ["path": filePath, "sha": blob],
                     "commit": ["sha": commit, "message": message]],
                    status: 201)
    }

    private func handleCommitList(query: [URLQueryItem]) -> Response {
        let path = query.first { $0.name == "path" }?.value
        let branch = query.first { $0.name == "sha" }?.value ?? defaultBranch
        let perPage = Int(query.first { $0.name == "per_page" }?.value ?? "30") ?? 30
        let page = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1

        guard let head = refs[branch] else {
            // No branches at all: the repository has no commit. A repository that does have
            // commits answers 422 for a branch it does not have, exactly like GitHub does for an
            // unknown SHA.
            if refs.isEmpty { return error(409, "Git Repository is empty.") }
            return error(422, "No commit found for SHA: \(branch)")
        }

        var chain: [Commit] = []
        var current: String? = head
        while let sha = current, let commit = commits[sha] {
            chain.append(commit)
            current = commit.parents.first
        }

        if let path {
            chain = chain.filter { commit in
                let value = blobSHA(at: commit.sha, path: path)
                guard value != nil else { return false }
                guard let parent = commit.parents.first else { return true }
                return blobSHA(at: parent, path: path) != value
            }
        }

        let start = max(0, (page - 1) * perPage)
        guard start < chain.count else { return json([]) }
        let slice = chain[start..<min(start + perPage, chain.count)]
        let items = slice.map { commit -> [String: Any] in
            ["sha": commit.sha,
             "commit": ["message": commit.message,
                        "author": ["date": ISO8601DateFormatter.github.string(from: commit.date)]]]
        }
        return json(items)
    }

    private func repositoryJSON() -> Response {
        json(["name": name,
              "full_name": "\(owner)/\(name)",
              "private": isPrivate,
              "default_branch": defaultBranch,
              "owner": ["login": owner],
              "permissions": ["admin": canPush, "push": canPush, "pull": canPull],
              "size": 1])
    }

    private func json(_ value: Any, status: Int = 200) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
        return Response(status: status, body: data)
    }

    private func error(_ status: Int, _ message: String) -> Response {
        json(["message": message], status: status)
    }
}

/// Maps mock hosts to their server instance so several tests can run without stepping on each
/// other.
final class MockGitHubRegistry: @unchecked Sendable {
    static let shared = MockGitHubRegistry()

    private let lock = NSLock()
    private var servers: [String: MockGitHubServer] = [:]

    func register(_ server: MockGitHubServer) {
        lock.lock(); defer { lock.unlock() }
        servers[server.host] = server
    }

    func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }
        servers[host] = nil
    }

    func server(for host: String) -> MockGitHubServer? {
        lock.lock(); defer { lock.unlock() }
        return servers[host]
    }
}

final class MockGitHubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let server = MockGitHubRegistry.shared.server(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, item in
            result[item.key.lowercased()] = item.value
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let path = url.path

        let response = server.handle(method: request.httpMethod ?? "GET",
                                     path: path,
                                     query: query,
                                     headers: headers,
                                     body: body)
        server.record(method: request.httpMethod ?? "GET", path: path, status: response.status)

        if response.status == -1, let raw = response.headers["x-url-error"], let code = Int(raw) {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }

        let http = HTTPURLResponse(url: url,
                                   statusCode: response.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": response.contentType].merging(response.headers) { _, new in new })!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
