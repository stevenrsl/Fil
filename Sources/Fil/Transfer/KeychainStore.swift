import Foundation
import Security

/// Où vivent les secrets. Le Keychain en production, la mémoire dans les tests.
protocol SecretStore: Sendable {
    func password(for connectionID: UUID) -> String?
    /// Ne lit pas le secret : ne déclenche donc pas de demande d'autorisation.
    func hasPassword(for connectionID: UUID) -> Bool
    func save(password: String, for connectionID: UUID, label: String) throws
    func deletePassword(for connectionID: UUID)
}

struct KeychainStore: SecretStore {
    static let service = "com.fil.connections"

    private func baseQuery(for connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
    }

    func password(for connectionID: UUID) -> String? {
        var query = baseQuery(for: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for connectionID: UUID) -> Bool {
        var query = baseQuery(for: connectionID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func save(password: String, for connectionID: UUID, label: String) throws {
        let data = Data(password.utf8)
        let query = baseQuery(for: connectionID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Fil — \(label)"
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrDescription as String] = "Mot de passe de connexion Fil"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deletePassword(for connectionID: UUID) {
        SecItemDelete(baseQuery(for: connectionID) as CFDictionary)
    }
}

struct KeychainError: LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            "L'accès au trousseau a été refusé. Le mot de passe n'a pas été enregistré."
        default:
            "Impossible d'enregistrer le mot de passe dans le trousseau (code \(status))."
        }
    }
}
