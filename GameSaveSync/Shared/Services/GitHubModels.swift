import Foundation

/// The private repository a game archive lives in.
///
/// The app never guesses this: `owner` and `name` start empty and must be filled in by the user,
/// so the source repository can never accidentally become the save archive.
public struct GitHubRepository: Codable, Hashable, Sendable {
    public var owner: String
    public var name: String
    public var branch: String

    public static let fallbackBranch = "main"

    public init(owner: String = "", name: String = "", branch: String = GitHubRepository.fallbackBranch) {
        self.owner = owner
        self.name = name
        self.branch = branch
    }

    public var trimmedOwner: String { owner.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedBranch: String {
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.fallbackBranch : value
    }

    public var fullName: String { "\(trimmedOwner)/\(trimmedName)" }

    /// Stable identity used to remember which remote a game was last synced with, so records
    /// written by the old iCloud flow can never satisfy a GitHub first-sync confirmation.
    public var identifier: String { "github:\(fullName.lowercased())@\(trimmedBranch)" }

    public var isConfigured: Bool { !trimmedOwner.isEmpty && !trimmedName.isEmpty }

    public var validationError: String? {
        guard isConfigured else { return "Enter the repository owner and name." }
        guard Self.isValidOwner(trimmedOwner) else { return "The repository owner is not a valid GitHub name." }
        guard Self.isValidName(trimmedName) else { return "The repository name is not valid." }
        guard Self.isValidBranch(trimmedBranch) else { return "The branch name is not valid." }
        return nil
    }

    public var isValid: Bool { validationError == nil }

    // MARK: - Validation

    public static func isValidOwner(_ value: String) -> Bool {
        guard (1...39).contains(value.count) else { return false }
        guard value.first != "-", value.last != "-" else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public static func isValidName(_ value: String) -> Bool {
        guard (1...100).contains(value.count) else { return false }
        guard value != ".", value != ".." else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// Subset of the git ref rules that matter for a single branch name.
    public static func isValidBranch(_ value: String) -> Bool {
        guard (1...200).contains(value.count) else { return false }
        guard !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        guard !value.hasSuffix("."), !value.hasSuffix(".lock"), !value.contains(".."), !value.contains("//") else { return false }
        guard value != "HEAD", !value.hasPrefix("refs/") else { return false }
        guard value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else { return false }
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\")
        return value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

/// Result of "test connection": everything the settings screen shows.
public struct GitHubConnectionReport: Equatable, Sendable {
    public var repository: GitHubRepository
    public var account: String?
    public var isPrivate: Bool
    public var canRead: Bool
    public var canWrite: Bool
    public var defaultBranch: String
    public var isEmptyRepository: Bool
    public var checkedAt: Date

    public init(repository: GitHubRepository,
                account: String? = nil,
                isPrivate: Bool,
                canRead: Bool,
                canWrite: Bool,
                defaultBranch: String,
                isEmptyRepository: Bool,
                checkedAt: Date = Date()) {
        self.repository = repository
        self.account = account
        self.isPrivate = isPrivate
        self.canRead = canRead
        self.canWrite = canWrite
        self.defaultBranch = defaultBranch
        self.isEmptyRepository = isEmptyRepository
        self.checkedAt = checkedAt
    }
}

/// Sizes GitHub enforces for a plain (non-LFS) repository.
public enum GitHubLimits {
    /// Above this the UI warns that the archive is large.
    public static let warningBytes = 50 << 20
    /// GitHub rejects a blob above this; the app refuses before uploading.
    public static let maximumBytes = 100 << 20

    public static func isTooLarge(_ bytes: Int) -> Bool { bytes >= maximumBytes }
    public static func needsWarning(_ bytes: Int) -> Bool { bytes >= warningBytes }
}

// MARK: - Wire formats

public struct GHPermissions: Decodable, Sendable {
    var admin: Bool?
    var push: Bool?
    var pull: Bool?
}

public struct GHOwner: Decodable, Sendable {
    var login: String?
}

/// `GET /repos/{owner}/{repo}`
public struct GHRepositoryResponse: Decodable, Sendable {
    var name: String?
    var fullName: String?
    var isPrivate: Bool?
    var defaultBranch: String?
    var permissions: GHPermissions?
    var owner: GHOwner?
    var size: Int?
    var empty: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case permissions, owner, size, empty
    }
}

/// `GET /repos/{owner}/{repo}/git/ref/heads/{branch}`
public struct GHRefResponse: Decodable, Sendable {
    struct Object: Decodable, Sendable {
        var sha: String
        var type: String?
    }
    var ref: String?
    var object: Object
}

/// `GET /repos/{owner}/{repo}/git/commits/{sha}`
public struct GHCommitResponse: Decodable, Sendable {
    struct TreeRef: Decodable, Sendable { var sha: String }
    var sha: String
    var tree: TreeRef
    var message: String?
    var parents: [Parent]?

    struct Parent: Decodable, Sendable { var sha: String }
}

/// `GET /repos/{owner}/{repo}/commits`
public struct GHCommitListItem: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        struct Author: Decodable, Sendable {
            var date: String?
            var name: String?
        }
        var message: String?
        var author: Author?
    }
    struct Author: Decodable, Sendable {
        var login: String?
    }
    var sha: String
    var commit: Detail
    var author: Author?

    var date: Date? {
        guard let raw = commit.author?.date else { return nil }
        return ISO8601DateFormatter.github.date(from: raw)
            ?? ISO8601DateFormatter.githubFractional.date(from: raw)
    }
}

/// `GET /repos/{owner}/{repo}/git/trees/{sha}`
public struct GHTreeResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var path: String
        var mode: String?
        var type: String?
        var sha: String
        var size: Int?
    }
    var sha: String
    var tree: [Entry]
    var truncated: Bool?
}

/// `GET /repos/{owner}/{repo}/git/blobs/{sha}`
public struct GHBlobResponse: Decodable, Sendable {
    var sha: String?
    var size: Int?
    var content: String?
    var encoding: String?
}

public struct GHBlobRequest: Encodable, Sendable {
    var content: String
    var encoding: String
}

public struct GHTreeRequest: Encodable, Sendable {
    public struct Entry: Encodable, Sendable {
        public var path: String
        public var mode: String
        public var type: String
        public var sha: String

        public init(path: String, mode: String, type: String, sha: String) {
            self.path = path
            self.mode = mode
            self.type = type
            self.sha = sha
        }
    }
    var baseTree: String?
    var tree: [Entry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

public struct GHCommitRequest: Encodable, Sendable {
    var message: String
    var tree: String
    var parents: [String]
    var author: Person
    var committer: Person

    struct Person: Encodable, Sendable {
        var name: String
        var email: String
        var date: String
    }
}

public struct GHUpdateRefRequest: Encodable, Sendable {
    var sha: String
    var force: Bool
}

public struct GHCreateRefRequest: Encodable, Sendable {
    var ref: String
    var sha: String
}

/// `PUT /repos/{owner}/{repo}/contents/{path}`
///
/// The contents endpoint is the supported way to create the first commit of a repository that has
/// no branches: the refs endpoint refuses to create a reference there.
public struct GHContentsRequest: Encodable, Sendable {
    struct Person: Encodable, Sendable {
        var name: String
        var email: String
    }

    var message: String
    var content: String
    var branch: String?
    var committer: Person
}

public struct GHContentsResponse: Decodable, Sendable {
    struct Commit: Decodable, Sendable {
        var sha: String
    }
    var commit: Commit?
}

/// GitHub error bodies are `{"message": "...", "documentation_url": "..."}`.
public struct GHErrorBody: Decodable, Sendable {
    var message: String?
}

extension ISO8601DateFormatter {
    static let github: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static let githubFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
