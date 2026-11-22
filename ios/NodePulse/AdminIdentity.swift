import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct AdminIdentity {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "nodepulse.admin",
         kSecAttrAccount as String: "ed25519"]
    }
    static func load() throws -> Curve25519.Signing.PrivateKey? {
        var q = query
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ProbeError.keychain(status) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    @discardableResult static func generate() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        let attributes: [String: Any] = [kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProbeError.keychain(status) }
        return key
    }
    static func authorize() async throws {
        guard UserDefaults.standard.object(forKey: "adminBiometrics") as? Bool ?? true else { return }
        #if targetEnvironment(simulator)
        return
        #else
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if error?.code == LAError.passcodeNotSet.rawValue { return }
            throw AdminError.message("无法验证设备身份，请检查设备密码设置")
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "验证身份以管理远程节点") else {
                throw AdminError.message("身份验证未通过")
            }
        } catch let error as LAError {
            if [.userCancel, .systemCancel, .appCancel].contains(error.code) { throw AdminError.message("已取消身份验证") }
            throw AdminError.message("身份验证未通过，请使用设备密码重试")
        }
        #endif
    }
}

enum AdminError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    static let handshake = AdminError.message("未授权或握手失败，请检查管理公钥、密钥和探针时间；探针可能未启用 -A")
    static let disconnected = AdminError.message("管理连接已断开，请重新连接")
}
