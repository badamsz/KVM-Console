import Foundation

/// Persists the device list (without passwords) as JSON.
public struct DeviceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/KVM Console/devices.json`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KVM Console", isDirectory: true).appendingPathComponent("devices.json")
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
