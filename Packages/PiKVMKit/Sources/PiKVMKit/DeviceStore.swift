import Foundation

/// Persists the device list (without passwords) as JSON.
public struct DeviceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/KVM Console/devices.json`
    ///
    /// The app used to be called PiKVM Console. If only the old
    /// `PiKVM Console` folder exists, it is renamed so the saved devices carry over.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = base.appendingPathComponent("KVM Console", isDirectory: true)
        migrateLegacyFolder(from: base.appendingPathComponent("PiKVM Console", isDirectory: true), to: folder)
        return folder.appendingPathComponent("devices.json")
    }

    /// Moves `old` to `new` when `old` exists and `new` doesn't. Failures are
    /// ignored: the app then starts with an empty list and the old folder stays put.
    static func migrateLegacyFolder(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    public func load() throws -> [Device] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Device].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ devices: [Device]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices).write(to: fileURL, options: .atomic)
    }
}
