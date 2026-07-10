import Foundation
import Security

public enum KeychainTokenStoreError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

public final class KeychainTokenStore: TokenStore, Sendable {
    private enum Account {
        // New account name so older restricted ACL items are migrated without editing ACLs in place.
        static let sharedCredentials = "credentials.shared"
        static let restrictedCredentials = "credentials"
        static let legacyAuthToken = "authToken"
        static let legacyRefreshToken = "refreshToken"
    }

    private let service: String

    public init(service: String = "com.geekywizkid.sub2api-statusbar") {
        self.service = service
    }

    public func loadTokens() -> StoredAuthTokens {
        if let credentials = readCredentials(account: Account.sharedCredentials, allowAuthenticationUI: false) {
            return credentials
        }

        let migrationTokens = loadMigratableTokensWithoutPrompt()
        if !migrationTokens.isEmpty {
            try? saveCredentials(migrationTokens)
            deleteLegacyTokens()
        }
        return migrationTokens
    }

    public func saveTokens(_ tokens: StoredAuthTokens) throws {
        if tokens.isEmpty {
            delete(account: Account.sharedCredentials)
            deleteLegacyTokens()
            return
        }

        try saveCredentials(tokens)
        deleteLegacyTokens()
    }

    private func loadMigratableTokensWithoutPrompt() -> StoredAuthTokens {
        if let credentials = readCredentials(account: Account.restrictedCredentials, allowAuthenticationUI: false) {
            return credentials
        }

        return StoredAuthTokens(
            authToken: readString(account: Account.legacyAuthToken, allowAuthenticationUI: false) ?? "",
            refreshToken: readString(account: Account.legacyRefreshToken, allowAuthenticationUI: false) ?? ""
        )
    }

    private func readCredentials(account: String, allowAuthenticationUI: Bool) -> StoredAuthTokens? {
        guard let data = readData(account: account, allowAuthenticationUI: allowAuthenticationUI) else {
            return nil
        }
        return try? JSONDecoder.tokenRouter.decode(StoredAuthTokens.self, from: data)
    }

    private func saveCredentials(_ tokens: StoredAuthTokens) throws {
        try saveData(JSONEncoder.tokenRouter.encode(tokens), account: Account.sharedCredentials)
    }

    private func readString(account: String, allowAuthenticationUI: Bool) -> String? {
        guard let data = readData(account: account, allowAuthenticationUI: allowAuthenticationUI) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func readData(account: String, allowAuthenticationUI: Bool) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    private func saveData(_ data: Data, account: String) throws {
        var updateQuery = baseQuery(account: account)
        updateQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainTokenStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrLabel as String] = "Sub2APIStatusBar credentials"
        addQuery[kSecAttrDescription as String] = "Sub2APIStatusBar login tokens"
        addQuery[kSecAttrAccess as String] = try sharedKeychainAccess()
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.unexpectedStatus(addStatus)
        }
    }

    private func sharedKeychainAccess() throws -> SecAccess {
        let descriptor = "Sub2APIStatusBar credentials" as CFString
        var accessRef: SecAccess?
        let createStatus = SecAccessCreate(descriptor, NSArray() as CFArray, &accessRef)
        guard createStatus == errSecSuccess, let access = accessRef else {
            throw KeychainTokenStoreError.unexpectedStatus(createStatus)
        }

        var rawACLList: CFArray?
        let copyStatus = SecAccessCopyACLList(access, &rawACLList)
        guard copyStatus == errSecSuccess,
              let aclList = rawACLList as? [SecACL] else {
            throw KeychainTokenStoreError.unexpectedStatus(copyStatus)
        }

        for acl in aclList {
            let removeStatus = SecACLRemove(acl)
            guard removeStatus == errSecSuccess else {
                throw KeychainTokenStoreError.unexpectedStatus(removeStatus)
            }
        }

        var replacementACL: SecACL?
        let aclStatus = SecACLCreateWithSimpleContents(
            access,
            nil,
            descriptor,
            SecKeychainPromptSelector(),
            &replacementACL
        )
        guard aclStatus == errSecSuccess, let replacementACL else {
            throw KeychainTokenStoreError.unexpectedStatus(aclStatus)
        }

        let authorizationStatus = SecACLUpdateAuthorizations(
            replacementACL,
            [kSecACLAuthorizationAny] as CFArray
        )
        guard authorizationStatus == errSecSuccess else {
            throw KeychainTokenStoreError.unexpectedStatus(authorizationStatus)
        }

        return access
    }

    private func deleteLegacyTokens() {
        delete(account: Account.restrictedCredentials)
        delete(account: Account.legacyAuthToken)
        delete(account: Account.legacyRefreshToken)
    }

    private func delete(account: String) {
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
