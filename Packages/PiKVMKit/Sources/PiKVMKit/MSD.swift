import Foundation

// MARK: /api/msd (virtual media)

/// An ISO or disk image stored on the PiKVM.
public struct MSDImage: Sendable, Hashable, Identifiable {
    public let name: String
    public let size: Int64
    /// False for a partial upload.
    public let complete: Bool
    public let removable: Bool
    /// Whether kvmd can present this image as a CD/DVD (older PiKVMs limit the size).
    public let cdromable: Bool

    public var id: String { name }

    public init(name: String, size: Int64, complete: Bool = true, removable: Bool = true, cdromable: Bool = true) {
        self.name = name
        self.size = size
        self.complete = complete
        self.removable = removable
        self.cdromable = cdromable
    }

    /// Whether the name looks like an optical disc image.
    public var looksLikeCD: Bool { name.lowercased().hasSuffix(".iso") }
}

/// The PiKVM's virtual drive (Mass Storage Device) and its image storage.
/// There is one drive per PiKVM; behind a Switch it follows the active port.
public struct MSDState: Decodable, Sendable, Hashable {
    public struct Drive: Sendable, Hashable {
        /// The image selected for the drive, if any.
        public let image: MSDImage?
        /// True while the drive is plugged into the remote machine.
        public let connected: Bool
        public let cdrom: Bool
        public let writable: Bool
    }

    public struct Transfer: Sendable, Hashable {
        public let name: String
        public let size: Int64
        public let written: Int64
    }

    /// False when the PiKVM has no virtual drive configured.
    public let enabled: Bool
    public let online: Bool
    public let busy: Bool
    public let images: [MSDImage]
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    /// An upload in progress, from this app or anyone else.
    public let uploading: Transfer?
    public let drive: Drive?

    private struct RawImage: Decodable {
        let name: String?
        let size: Int64?
        let complete: Bool?
        let removable: Bool?
        let cdromable: Bool?

        func image(named fallback: String) -> MSDImage {
            MSDImage(name: name ?? fallback, size: size ?? 0, complete: complete ?? true,
                     removable: removable ?? true, cdromable: cdromable ?? true)
        }
    }

    private struct RawPart: Decodable {
        let size: Int64?
        let free: Int64?
    }

    private struct RawTransfer: Decodable {
        let name: String?
        let size: Int64?
        let written: Int64?
    }

    private struct RawStorage: Decodable {
        let images: [String: RawImage]?
        let parts: [String: RawPart]?
        // Older kvmd reports one storage area directly.
        let size: Int64?
        let free: Int64?
        let uploading: RawTransfer?
    }

    private struct RawDrive: Decodable {
        let image: RawImage?
        let connected: Bool?
        let cdrom: Bool?
        let rw: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, online, busy, storage, drive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false

        let storage = try c.decodeIfPresent(RawStorage.self, forKey: .storage)
        images = (storage?.images ?? [:])
            .map { $0.value.image(named: $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The root storage area is the part with the empty name.
        let root = storage?.parts?[""]
        totalBytes = root?.size ?? storage?.size
        freeBytes = root?.free ?? storage?.free
        uploading = storage?.uploading.flatMap { raw in
            guard let name = raw.name else { return nil }
            return Transfer(name: name, size: raw.size ?? 0, written: raw.written ?? 0)
        }

        if let raw = try c.decodeIfPresent(RawDrive.self, forKey: .drive) {
            drive = Drive(image: raw.image.flatMap { $0.name == nil ? nil : $0.image(named: "") },
                          connected: raw.connected ?? false, cdrom: raw.cdrom ?? false, writable: raw.rw ?? false)
        } else {
            drive = nil
        }
    }
}

public enum MSDImageName {
    /// Turns a local file name into one kvmd accepts: no slashes or control
    /// characters, no leading dot, at most 255 characters.
    public static func sanitized(_ fileName: String) -> String {
        var name = String(fileName.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar.value < 0x20 || scalar.value == 0x7F { return "_" }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty || name == "lost+found" { name = "image.iso" }
        if name.count > 255 {
            // Keep the extension when shortening.
            let ext = (name as NSString).pathExtension
            let suffix = ext.isEmpty || ext.count > 16 ? "" : "." + ext
            name = String(name.prefix(255 - suffix.count)) + suffix
        }
        return name
    }
}

/// Reports upload progress, at most a few times a second.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var lastReport = Date.distantPast

    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastReport) >= 0.25 || totalBytesSent >= totalBytesExpectedToSend
        if due { lastReport = now }
        lock.unlock()
        if due { report(totalBytesSent, totalBytesExpectedToSend) }
    }
}
