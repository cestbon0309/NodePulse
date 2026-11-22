import Foundation
import Security

protocol SecretStorage {
    func set(_ secret: String, for id: UUID) throws
    func get(_ id: UUID) throws -> String
    func delete(_ id: UUID) throws
}

struct SecretStore: SecretStorage {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "nodepulse", kSecAttrAccount as String: id.uuidString]
    }
    func set(_ secret: String, for id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id).merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProbeError.keychain(status) }
    }
    func get(_ id: UUID) throws -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw ProbeError.missingSecret }
        guard status == errSecSuccess else { throw ProbeError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw ProbeError.missingSecret }
        return value
    }
    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProbeError.keychain(status) }
    }
}
