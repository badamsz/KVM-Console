import Foundation
import Security

/// Stores device passwords in the macOS login Keychain.
public struct CredentialStore: Sendable {
    public let service: String

    public init(service: String = "com.badamsz.KVMConsole") {
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
        query(account: deviceID.uuidString + kind.rawValue)
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func password(for deviceID: UUID, kind: Kind = .kvmd) -> String? {
        read(query(deviceID, kind))
    }

    @discardableResult
    public func setPassword(_ password: String, for deviceID: UUID, kind: Kind = .kvmd) -> Bool {
        write(password, query(deviceID, kind))
    }

    public func deletePassword(for deviceID: UUID, kind: Kind = .kvmd) {
        SecItemDelete(query(deviceID, kind) as CFDictionary)
    }

    // MARK: App secrets

    /// A secret of the app's own that isn't tied to a device, such as the
    /// MCP server's token. `name` must not look like a device id.
    public func secret(named name: String) -> String? {
        read(query(account: "app." + name))
    }

    @discardableResult
    public func setSecret(_ value: String, named name: String) -> Bool {
        write(value, query(account: "app." + name))
    }

    public func deleteSecret(named name: String) {
        SecItemDelete(query(account: "app." + name) as CFDictionary)
    }

    // MARK: Keychain

    private func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, _ query: [String: Any]) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
