import Foundation
import Security

public final class KeychainTokenStore: LegacyTokenStore, Sendable {
    private enum Account {
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
        if let credentials = readCredentials(account: Account.sharedCredentials) {
            return credentials
        }

        if let credentials = readCredentials(account: Account.restrictedCredentials) {
            return credentials
        }

        return StoredAuthTokens(
            authToken: readString(account: Account.legacyAuthToken) ?? "",
            refreshToken: readString(account: Account.legacyRefreshToken) ?? ""
        )
    }

    public func deleteTokens() {
        delete(account: Account.sharedCredentials)
        delete(account: Account.restrictedCredentials)
        delete(account: Account.legacyAuthToken)
        delete(account: Account.legacyRefreshToken)
    }

    private func readCredentials(account: String) -> StoredAuthTokens? {
        guard let data = readData(account: account) else {
            return nil
        }
        return try? JSONDecoder.tokenRouter.decode(StoredAuthTokens.self, from: data)
    }

    private func readString(account: String) -> String? {
        guard let data = readData(account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
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
