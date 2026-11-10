import Foundation
import Security

/// Stores device passwords in the macOS login Keychain.
public struct CredentialStore: Sendable {
    public let service: String

    public init(service: String = "com.badamsz.PiKVMConsole") {
        self.service = service
    }

    private func query(_ deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
    }

    public func password(for deviceID: UUID) -> String? {
        var q = query(deviceID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func setPassword(_ password: String, for deviceID: UUID) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(deviceID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(deviceID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func deletePassword(for deviceID: UUID) {
        SecItemDelete(query(deviceID) as CFDictionary)
    }
}
