import AppKit
import Foundation
import KVMKit

/// A Sipeed NanoKVM, NanoKVM Pro or NanoKVM Go. It has no event socket, so
/// the LEDs and media are polled. It has one machine and no Switch.
@MainActor
final class NanoKVMBackend: DeviceBackend, URLImageDownloading {
    let connection: NanoKVMConnection
    var client: NanoKVMClient { connection.client }
    private(set) var info: NanoKVMInfo?
    let changes: AsyncStream<DeviceStateChange>
    private let continuation: AsyncStream<DeviceStateChange>.Continuation
    private var pollTask: Task<Void, Never>?
    /// True while a power or reset button press is being held; shown as ATX busy.
    private var pressing = false
    /// Classic NanoKVM firmware before 2.5.3 has no upload API.
    private(set) var canUploadImages = false
    /// The last free space reading, kept while polling skips it.
    private var lastSpace: (total: Int64?, free: Int64?)?

    private init(_ connection: NanoKVMConnection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream<DeviceStateChange>.makeStream()
        self.changes = stream
        self.continuation = continuation
    }

    static func start(_ connection: NanoKVMConnection) async -> NanoKVMBackend {
        let backend = NanoKVMBackend(connection)
        backend.info = try? await connection.client.info()
        backend.poll()
        return backend
    }

    var endpointLabel: String { connection.endpoint.label }
    var host: String { connection.endpoint.host }

    var infoRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let v = info?.application, !v.isEmpty { rows.append(("NanoKVM software", v)) }
        if let h = info?.mdns, !h.isEmpty { rows.append(("Hostname", h)) }
        return rows
    }

    /// LEDs every 3 seconds, media every 15.
    private func poll() {
        let continuation = self.continuation
        pollTask = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                continuation.yield(.atx)
                tick += 1
                if tick % 5 == 0 { continuation.yield(.media(full: false)) }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation.finish()
    }

    // MARK: State

    /// The LEDs, shown as ATX state. Devices without an ATX board (NanoKVM
    /// Lite, NanoKVM Go) fail to read them and show no power controls.
    func readATX() async -> ATXState? {
        guard let leds = try? await client.leds() else { return nil }
        return ATXState(nanoKVM: leds, busy: pressing)
    }

    func readMedia(full: Bool) async -> MSDState? {
        guard var library = try? await client.library(includeFreeSpace: full) else { return nil }
        if library.canUpload {
            if full {
                lastSpace = (library.totalBytes, library.freeBytes)
            } else if let lastSpace {
                library.totalBytes = lastSpace.total
                library.freeBytes = lastSpace.free
            }
        }
        canUploadImages = library.canUpload
        let mounted = try? await client.mountedImage()
        var cdrom = mounted?.cdrom ?? false
        if mounted?.cdrom == nil, client.family == .nanoKVM, mounted?.file.isEmpty == false {
            cdrom = (try? await client.cdromMode()) ?? false
        }
        return MSDState(nanoKVM: library, mounted: mounted, cdrom: cdrom)
    }

    // MARK: Power

    func power(_ action: ATXPowerAction, switchPort: Int?, poweredOn: Bool?) async throws {
        try await press(action.nanoKVMPress(powerIsOn: poweredOn))
    }

    func click(_ button: ATXButton, switchPort: Int?) async throws {
        try await press(button.nanoKVMPress)
    }

    /// Holds the button for the press's length. The session shows ATX busy meanwhile.
    private func press(_ press: ATXPowerAction.NanoKVMPress) async throws {
        guard press != .none, !pressing else { return }
        pressing = true
        continuation.yield(.atx)
        defer {
            pressing = false
            continuation.yield(.atx)
        }
        switch press {
        case .none: break
        case .power(let ms): try await client.pressPower(milliseconds: ms)
        case .reset: try await client.pressReset()
        }
    }

    func snapshot() async throws -> NSImage {
        try NSImage.snapshot(try await client.snapshot())
    }

    // MARK: Virtual media

    /// A NanoKVM names images by their path in /data.
    func storedImageName(for fileName: String) -> String {
        NanoKVMClient.imageDirectory + "/" + fileName
    }

    func uploadProblem(for fileName: String) -> String? {
        NanoKVMClient.isImageName(fileName)
            ? nil
            : "The NanoKVM only uses .iso and .img files. Rename \(fileName) if it is a disk image."
    }

    func uploadImage(fileURL: URL, as name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await client.uploadImage(fileURL: fileURL, as: name, progress: progress)
    }

    /// A NanoKVM keeps what arrived. The name was checked to be free before starting.
    func cleanUpFailedUpload(storedName: String) async {
        try? await client.deleteImage(storedName)
    }

    func mountImage(_ image: String, cdrom: Bool, writable: Bool, driveConnected: Bool) async throws {
        try await client.mountImage(image, cdrom: cdrom, writable: writable)
    }

    func ejectImage() async throws {
        try await client.mountImage("", cdrom: false)
    }

    func deleteImage(_ name: String) async throws {
        try await client.deleteImage(name)
    }

    // MARK: Download from a URL

    var canCancelDownload: Bool { client.canCancelDownload }
    func startDownload(url: URL) async throws { try await client.startDownload(url: url) }
    func cancelDownload() async throws { try await client.cancelDownload() }
    func downloadStatus() async throws -> NanoKVMDownloadStatus? { try await client.downloadStatus() }
}
