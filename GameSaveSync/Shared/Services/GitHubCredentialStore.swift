import Foundation
import Security

/// Where the GitHub token lives.
///
/// The token is only ever persisted in the Keychain. It is deliberately not part of
/// `AppSettings`, so it can never end up in `settings.json`, in a backup of the container, in the
/// log file or in the save archive that is uploaded to GitHub.
public protocol GitHubTokenStoring: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
    var hasToken: Bool { get }
}

public enum GitHubTokenStoreError: Error, LocalizedError, Equatable {
    case keychainFailure(OSStatus)
    case emptyToken

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The access token could not be stored in the Keychain. \(message)"
        case .emptyToken:
            return "The access token is empty."
        }
    }
}

/// Keychain-backed token storage, shared by iOS, iPadOS and macOS.
public final class KeychainGitHubTokenStore: GitHubTokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.gamesavesync.github",
                account: String = "access-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public var hasToken: Bool {
        (try? readToken()).flatMap { $0?.isEmpty == false } ?? false
    }

    public func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GitHubTokenStoreError.keychainFailure(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubTokenStoreError.keychainFailure(errSecDecode)
        }
        return token
    }

    public func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubTokenStoreError.emptyToken }
        let data = Data(trimmed.utf8)

        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if #available(macOS 15.0, iOS 18.0, *) {
            // Keep the item off any other device even when the user has iCloud Keychain enabled.
            attributes[kSecAttrSynchronizable as String] = false
        }

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GitHubTokenStoreError.keychainFailure(updateStatus)
        }

        var insert = baseQuery
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GitHubTokenStoreError.keychainFailure(addStatus)
        }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubTokenStoreError.keychainFailure(status)
        }
    }
}

/// Test double; also used when the Keychain is unavailable in a unit-test process.
public final class InMemoryGitHubTokenStore: GitHubTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public var hasToken: Bool {
        lock.lock(); defer { lock.unlock() }
        return token?.isEmpty == false
    }

    public func readToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubTokenStoreError.emptyToken }
        lock.lock(); defer { lock.unlock() }
        self.token = trimmed
    }

    public func deleteToken() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}
