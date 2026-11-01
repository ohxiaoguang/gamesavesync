import Foundation

/// Thin wrapper over the GitHub REST API that only speaks HTTPS and never knows about the
/// Keychain itself — the token is handed in by the caller for exactly one operation.
public final class GitHubAPIClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var userAgent: String
        public var requestTimeout: TimeInterval
        /// Retries are only used for idempotent (GET) requests.
        public var maximumRetries: Int
        public var retryDelay: TimeInterval

        public init(baseURL: URL = URL(string: "https://api.github.com")!,
                    userAgent: String = "GameSaveSync",
                    requestTimeout: TimeInterval = 60,
                    maximumRetries: Int = 2,
                    retryDelay: TimeInterval = 0.8) {
            self.baseURL = baseURL
            self.userAgent = userAgent
            self.requestTimeout = requestTimeout
            self.maximumRetries = maximumRetries
            self.retryDelay = retryDelay
        }
    }

    private let session: URLSession
    private let token: String
    private let configuration: Configuration

    public init(token: String, session: URLSession? = nil, configuration: Configuration = Configuration()) {
        self.token = token
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = configuration.requestTimeout * 4
            config.httpAdditionalHeaders = ["User-Agent": configuration.userAgent]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Endpoints

    public func repository(_ repo: GitHubRepository) async throws -> GHRepositoryResponse {
        let response = try await send(request(for: [], path: "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)"),
                                      allowsRetry: true)
        return try decode(GHRepositoryResponse.self, from: response, context: .repository)
    }

    /// HEAD of the configured branch. `nil` means the repository has no commit at all yet.
    ///
    /// A missing ref is reported as **404** ("Not Found") when the branch does not exist and as
    /// **409** ("Git Repository is empty.") when the repository has no commit at all. Neither
    /// status may be trusted on its own — a proxy, an expired token or a repository that is still
    /// being created can produce them too — so both are resolved against the repository itself
    /// before anything is concluded.
    public func headCommit(_ repo: GitHubRepository) async throws -> String? {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/ref/heads/\(escape(repo.trimmedBranch))"
        let response = try await send(request(for: [], path: path), allowsRetry: true)
        switch response.status {
        case 200..<300:
            let ref = try decode(GHRefResponse.self, from: response, context: .branch(repo.trimmedBranch))
            return ref.object.sha
        case 404, 409:
            return try await resolveMissingReference(repo, refStatus: response.status)
        default:
            throw try mapError(response, context: .branch(repo.trimmedBranch))
        }
    }

    /// Answers "is this branch missing, or is the whole repository empty?" after a failed ref read.
    private func resolveMissingReference(_ repo: GitHubRepository, refStatus: Int) async throws -> String? {
        // 1. The repository itself must be readable. A 401/403/404 here is the real story and is
        //    reported as such instead of being disguised as "the repository is empty".
        let info = try await repository(repo)

        // 2. Ask the configured branch for one commit. An empty repository answers 409 again, a
        //    repository with commits answers 422 for a branch it does not have.
        let query = [
            URLQueryItem(name: "sha", value: repo.trimmedBranch),
            URLQueryItem(name: "per_page", value: "1")
        ]
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/commits"
        let probe = try await send(request(for: query, path: path), allowsRetry: true)

        switch probe.status {
        case 200:
            let items = (try? JSONDecoder().decode([GHCommitListItem].self, from: probe.body)) ?? []
            if let head = items.first {
                // The requested branch resolved, so this really is its head: the ref lookup was
                // the odd one out. Using it keeps a transient ref failure from starting a second
                // history for the same branch.
                Log.write("[GitHub] ref read answered \(refStatus) but branch \(repo.trimmedBranch) has commits; using its head")
                return head.sha
            }
            // No commits at all: the repository is genuinely empty, which is not an error.
            Log.write("[GitHub] repository \(repo.fullName) has no commit yet")
            return nil
        case 409:
            Log.write("[GitHub] repository \(repo.fullName) is empty (409 from commits)")
            return nil
        case 404, 422:
            Log.write("[GitHub] branch \(repo.trimmedBranch) does not exist in \(repo.fullName) (default branch: \(info.defaultBranch ?? "-"))")
            throw SyncError.gitHubBranchMissing(repo.trimmedBranch)
        default:
            throw try mapError(probe, context: .branch(repo.trimmedBranch))
        }
    }

    /// Writes the first commit of a repository that has no branches yet and returns its SHA.
    ///
    /// `POST /git/refs` cannot create a reference while a repository is empty, so the documented
    /// way in is the contents endpoint: it creates the default branch together with a first
    /// commit. Everything else in the repository is left alone.
    public func initializeRepository(_ repo: GitHubRepository,
                                     authorName: String,
                                     authorEmail: String) async throws -> String {
        let payload = GHContentsRequest(
            message: GitHubLayout.initialisationMessage,
            content: Data(#"{"application":"GameSaveSync","version":1}"#.utf8).base64EncodedString(),
            branch: nil,
            committer: GHContentsRequest.Person(name: authorName, email: authorEmail))
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/contents/\(GitHubLayout.initialisationPath)"
        let response = try await send(request(for: [], path: path, method: "PUT", body: payload), allowsRetry: false)
        let created = try decode(GHContentsResponse.self, from: response, context: .resource("contents"))
        guard let sha = created.commit?.sha else {
            throw SyncError.gitHubUnexpectedResponse("The repository was initialised without a commit.")
        }
        return sha
    }

    public func commit(_ repo: GitHubRepository, sha: String) async throws -> GHCommitResponse {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/commits/\(sha)"
        let response = try await send(request(for: [], path: path), allowsRetry: true)
        return try decode(GHCommitResponse.self, from: response, context: .resource("commit"))
    }

    public func tree(_ repo: GitHubRepository, sha: String) async throws -> GHTreeResponse {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/trees/\(sha)"
        let response = try await send(request(for: [], path: path), allowsRetry: true)
        return try decode(GHTreeResponse.self, from: response, context: .resource("tree"))
    }

    public func commits(_ repo: GitHubRepository,
                        branch: String,
                        path: String?,
                        perPage: Int,
                        page: Int) async throws -> [GHCommitListItem] {
        var query = [
            URLQueryItem(name: "sha", value: branch.isEmpty ? repo.trimmedBranch : branch),
            URLQueryItem(name: "per_page", value: String(max(1, min(perPage, 100)))),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ]
        if let path, !path.isEmpty {
            query.append(URLQueryItem(name: "path", value: path))
        }
        let endpoint = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/commits"
        let response = try await send(request(for: query, path: endpoint), allowsRetry: true)
        if response.status == 409 { return [] }
        let data = try requireSuccess(response, context: .resource("commits"))
        do {
            return try JSONDecoder().decode([GHCommitListItem].self, from: data)
        } catch {
            throw SyncError.gitHubUnexpectedResponse(error.localizedDescription)
        }
    }

    /// Uploads a file as a blob and returns GitHub's blob SHA.
    ///
    /// The JSON body is assembled in a file on disk so a large archive is never fully base64
    /// encoded in memory.
    public func createBlob(_ repo: GitHubRepository, fileAt url: URL) async throws -> String {
        let body = try Base64JSONBody.make(from: url)
        defer { body.cleanup() }

        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/blobs"
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        guard let endpoint = components?.url else { throw SyncError.gitHubUnexpectedResponse("Bad blob URL") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (payload, response) = try await performUpload(request, bodyFile: body.file, allowsRetry: false)
        guard (200..<300).contains(response.statusCode) else {
            throw try mapError(GitHubHTTPResponse(status: response.statusCode,
                                                  headers: headerDictionary(response),
                                                  body: payload),
                               context: .resource("blob"))
        }
        let blob = try decodeGH(GHBlobResponse.self, from: payload)
        guard let sha = blob.sha else {
            throw SyncError.gitHubUnexpectedResponse("The blob upload did not return a SHA.")
        }
        return sha
    }

    public func createTree(_ repo: GitHubRepository,
                           baseTree: String?,
                           entries: [GHTreeRequest.Entry]) async throws -> String {
        let body = GHTreeRequest(baseTree: baseTree, tree: entries)
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/trees"
        let response = try await send(request(for: [], path: path, method: "POST", body: body), allowsRetry: false)
        let tree = try decode(GHTreeResponse.self, from: response, context: .resource("tree"))
        return tree.sha
    }

    public func createCommit(_ repo: GitHubRepository,
                             message: String,
                             tree: String,
                             parents: [String],
                             authorName: String,
                             authorEmail: String) async throws -> String {
        let now = ISO8601DateFormatter.github.string(from: Date())
        let person = GHCommitRequest.Person(name: authorName, email: authorEmail, date: now)
        let body = GHCommitRequest(message: message,
                                   tree: tree,
                                   parents: parents,
                                   author: person,
                                   committer: person)
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/commits"
        let response = try await send(request(for: [], path: path, method: "POST", body: body), allowsRetry: false)
        let commit = try decode(GHCommitResponse.self, from: response, context: .resource("commit"))
        return commit.sha
    }

    /// Fast-forward only update of an existing branch.
    public func updateRef(_ repo: GitHubRepository, commit: String) async throws {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/refs/heads/\(escape(repo.trimmedBranch))"
        let body = GHUpdateRefRequest(sha: commit, force: false)
        let response = try await send(request(for: [], path: path, method: "PATCH", body: body), allowsRetry: false)
        _ = try requireSuccess(response, context: .branch(repo.trimmedBranch), mapUnprocessableTo: .gitHubRemoteChanged)
    }

    /// Creates a branch that the repository does not have yet, from an existing commit.
    ///
    /// Only usable once the repository has at least one branch; see `initializeRepository`.
    public func createRef(_ repo: GitHubRepository, commit: String) async throws {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/refs"
        let body = GHCreateRefRequest(ref: "refs/heads/\(repo.trimmedBranch)", sha: commit)
        let response = try await send(request(for: [], path: path, method: "POST", body: body), allowsRetry: false)
        do {
            _ = try requireSuccess(response, context: .branch(repo.trimmedBranch))
        } catch SyncError.gitHubUnprocessable {
            // Another device created the branch first; the caller re-reads and decides.
            throw SyncError.gitHubRemoteChanged
        }
    }

    /// Downloads raw blob bytes straight to a file, avoiding the base64 round trip in memory.
    public func downloadBlob(_ repo: GitHubRepository, sha: String, to destination: URL) async throws {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/blobs/\(sha)"
        var request = request(for: [], path: path)
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")

        let (temporaryURL, response) = try await download(request, allowsRetry: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: temporaryURL)) ?? Data()
            throw try mapError(GitHubHTTPResponse(status: http.statusCode,
                                                  headers: headerDictionary(http),
                                                  body: body),
                               context: .resource("blob"))
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("json") {
            // Defensive fallback: some proxies ignore the raw media type.
            let body = try Data(contentsOf: temporaryURL)
            let blob = try decodeGH(GHBlobResponse.self, from: body)
            guard let encoded = blob.content,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw SyncError.gitHubUnexpectedResponse("The blob could not be decoded.")
            }
            try data.write(to: destination, options: .atomic)
            return
        }

        do {
            if FileSystem.exists(destination) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw SyncError.generic("Could not store the downloaded archive: \(error.localizedDescription)")
        }
    }

    public func readBlob(_ repo: GitHubRepository, sha: String) async throws -> Data {
        let path = "/repos/\(repo.trimmedOwner)/\(repo.trimmedName)/git/blobs/\(sha)"
        let response = try await send(request(for: [], path: path), allowsRetry: true)
        let data = try requireSuccess(response, context: .resource("blob"))
        let blob = try decodeGH(GHBlobResponse.self, from: data)
        guard let encoded = blob.content, blob.encoding == "base64",
              let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw SyncError.gitHubUnexpectedResponse("The blob could not be decoded.")
        }
        return decoded
    }

    // MARK: - Request plumbing

    private enum ErrorContext {
        case repository
        case branch(String)
        case resource(String)
    }

    private struct GitHubHTTPResponse {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func request(for query: [URLQueryItem],
                         path: String,
                         method: String = "GET",
                         body: Encodable? = nil) -> URLRequest {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        if !query.isEmpty { components?.queryItems = query }
        let url = components?.url ?? configuration.baseURL

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(AnyEncodable(body))
        }
        return request
    }

    private func send(_ request: URLRequest, allowsRetry: Bool) async throws -> GitHubHTTPResponse {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncError.networkUnavailable }
                let mapped = GitHubHTTPResponse(status: http.statusCode,
                                                headers: headerDictionary(http),
                                                body: data)
                Self.trace(request, status: mapped.status)
                if allowsRetry, shouldRetry(status: mapped.status, attempt: attempt) {
                    attempt += 1
                    try await backoff(attempt: attempt, response: mapped)
                    continue
                }
                return mapped
            } catch let error as SyncError {
                Self.trace(request, error: error)
                throw error
            } catch {
                let syncError = Self.mapTransportError(error)
                Self.trace(request, error: syncError)
                if allowsRetry, case .networkUnavailable = syncError, attempt < configuration.maximumRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, response: nil)
                    continue
                }
                throw syncError
            }
        }
    }

    private func download(_ request: URLRequest, allowsRetry: Bool) async throws -> (URL, URLResponse) {
        var attempt = 0
        while true {
            do {
                let (url, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: url)
                    throw SyncError.networkUnavailable
                }
                Self.trace(request, status: http.statusCode)
                if allowsRetry, shouldRetry(status: http.statusCode, attempt: attempt) {
                    try? FileManager.default.removeItem(at: url)
                    attempt += 1
                    try await backoff(attempt: attempt,
                                      response: GitHubHTTPResponse(status: http.statusCode,
                                                                   headers: headerDictionary(http),
                                                                   body: Data()))
                    continue
                }
                return (url, response)
            } catch let error as SyncError {
                Self.trace(request, error: error)
                throw error
            } catch {
                let syncError = Self.mapTransportError(error)
                Self.trace(request, error: syncError)
                if allowsRetry, case .networkUnavailable = syncError, attempt < configuration.maximumRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, response: nil)
                    continue
                }
                throw syncError
            }
        }
    }

    private func performUpload(_ request: URLRequest,
                               bodyFile: URL,
                               allowsRetry: Bool) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
            guard let http = response as? HTTPURLResponse else { throw SyncError.networkUnavailable }
            Self.trace(request, status: http.statusCode)
            return (data, http)
        } catch let error as SyncError {
            Self.trace(request, error: error)
            throw error
        } catch {
            let syncError = Self.mapTransportError(error)
            Self.trace(request, error: syncError)
            throw syncError
        }
    }

    private func shouldRetry(status: Int, attempt: Int) -> Bool {
        guard attempt < configuration.maximumRetries else { return false }
        if status == 429 { return true }
        if status == 408 { return true }
        return status >= 500
    }

    private func backoff(attempt: Int, response: GitHubHTTPResponse?) async throws {
        var delay = configuration.retryDelay * Double(max(attempt, 1))
        if let retryAfter = response.flatMap({ retryAfterSeconds($0) }) {
            delay = min(TimeInterval(retryAfter), 15)
        }
        try await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
    }

    // MARK: - Decoding & error mapping

    private func decode<T: Decodable>(_ type: T.Type,
                                      from response: GitHubHTTPResponse,
                                      context: ErrorContext) throws -> T {
        let data = try requireSuccess(response, context: context)
        return try decodeGH(type, from: data)
    }

    private func decodeGH<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SyncError.gitHubUnexpectedResponse(error.localizedDescription)
        }
    }

    private func requireSuccess(_ response: GitHubHTTPResponse,
                                context: ErrorContext,
                                mapUnprocessableTo: SyncError? = nil) throws -> Data {
        if (200..<300).contains(response.status) { return response.body }
        if response.status == 422, let mapUnprocessableTo { throw mapUnprocessableTo }
        throw try mapError(response, context: context)
    }

    private func mapError(_ response: GitHubHTTPResponse, context: ErrorContext) throws -> SyncError {
        let message = (try? JSONDecoder().decode(GHErrorBody.self, from: response.body))?.message
        switch response.status {
        case 401:
            return .gitHubAuthFailed(detail: message)
        case 403:
            if response.headers["x-ratelimit-remaining"] == "0" {
                return .gitHubRateLimited(retryAfter: retryAfterSeconds(response))
            }
            return .gitHubPermissionDenied(detail: message)
        case 404:
            switch context {
            case .repository:
                return .gitHubRepositoryNotFound(message ?? "")
            case .branch(let name):
                return .gitHubBranchMissing(name)
            case .resource(let name):
                return .gitHubNotFound(name)
            }
        case 409:
            // 409 does not mean the same thing everywhere: on a branch write it is a competing
            // writer, on a repository read it is not "empty", and only the git object endpoints
            // answer it while the repository still has no commit.
            switch context {
            case .branch:
                return .gitHubRemoteChanged
            case .repository:
                return .gitHubUnexpectedResponse(message ?? "HTTP 409")
            case .resource:
                return .gitHubRepositoryEmpty
            }
        case 422:
            return .gitHubUnprocessable
        case 429:
            return .gitHubRateLimited(retryAfter: retryAfterSeconds(response))
        case 500...599:
            return .gitHubServerError(status: response.status)
        default:
            return .gitHubUnexpectedResponse(message ?? "HTTP \(response.status)")
        }
    }

    private func retryAfterSeconds(_ response: GitHubHTTPResponse) -> Int? {
        if let value = response.headers["retry-after"], let seconds = Int(value) {
            return max(seconds, 0)
        }
        if let reset = response.headers["x-ratelimit-reset"], let epoch = TimeInterval(reset) {
            return max(Int(epoch - Date().timeIntervalSince1970), 0)
        }
        return nil
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            result[key.lowercased()] = String(describing: value)
        }
        return result
    }

    // MARK: - Diagnostics

    /// Logs the request line and status only: never the token, the body or a token-bearing URL.
    private static func trace(_ request: URLRequest, status: Int) {
        Log.write("[GitHub] \(method(of: request)) \(path(of: request)) → HTTP \(status)")
    }

    private static func trace(_ request: URLRequest, error: SyncError) {
        Log.write("[GitHub] \(method(of: request)) \(path(of: request)) → \(diagnosticName(of: error))")
    }

    private static func method(of request: URLRequest) -> String { request.httpMethod ?? "GET" }

    private static func path(of request: URLRequest) -> String { request.url?.path ?? "-" }

    /// Case name without its payload, for logs that must stay free of server messages.
    static func diagnosticName(of error: SyncError) -> String {
        String(String(describing: error).prefix(while: { $0 != "(" }))
    }

    static func mapTransportError(_ error: Error) -> SyncError {
        guard let urlError = error as? URLError else {
            if error is CancellationError { return .cancelled }
            return .networkUnavailable
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .networkTimeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .networkUnavailable
        default:
            return .networkUnavailable
        }
    }
}

/// Type eraser so a heterogeneous set of request bodies can share one `request(for:)` helper.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeClosure = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

/// Builds `{"content":"<base64>","encoding":"base64"}` in a temporary file, chunk by chunk.
struct Base64JSONBody {
    let file: URL
    let byteCount: Int

    static func make(from source: URL) throws -> Base64JSONBody {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gss-blob-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: file) else {
            throw SyncError.generic("Could not create the upload body.")
        }
        defer { try? output.close() }

        do {
            try output.write(contentsOf: Data(#"{"content":""#.utf8))
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }

            // 3 bytes per group keeps every chunk independently base64-encodable.
            let chunkSize = 3 * 48 * 1024
            while true {
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk.base64EncodedData())
            }
            try output.write(contentsOf: Data(#"","encoding":"base64"}"#.utf8))
            try output.synchronize()
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return Base64JSONBody(file: file, byteCount: size)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: file)
    }
}
