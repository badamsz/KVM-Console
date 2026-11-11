import Foundation
import Security

/// Stores device passwords in the macOS login Keychain.
public struct CredentialStore: Sendable {
    public let service: String

    /// The service name dates from when the app was called PiKVM Console. It is
    /// kept so passwords saved by earlier versions are still found.
    public init(service: String = "com.badamsz.PiKVMConsole") {
        self.service = service
    }

    /// Which secret of a device an item holds.
    public enum Kind: String, Sendable {
        /// The kvmd (web UI / API) password.
        case kvmd = ""
        /// The OS root password, used for `pikvm-update`.
        case root = ".root"
    }

    private func query(_ deviceID: UUID, _ kind: Kind = .kvmd) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString + kind.rawValue,
        ]
    }

    public func password(for deviceID: UUID, kind: Kind = .kvmd) -> String? {
        var q = query(deviceID, kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func setPassword(_ password: String, for deviceID: UUID, kind: Kind = .kvmd) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(deviceID, kind) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(deviceID, kind)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func deletePassword(for deviceID: UUID, kind: Kind = .kvmd) {
        SecItemDelete(query(deviceID, kind) as CFDictionary)
    }
}
