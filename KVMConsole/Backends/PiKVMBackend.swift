import AppKit
import Foundation
import KVMKit

/// A PiKVM, driven through kvmd's HTTP API. State changes arrive on kvmd's
/// event socket. Behind a PiKVM Switch, ATX actions go to the machine's port.
@MainActor
final class PiKVMBackend: DeviceBackend {
    let connection: Connection
    var client: KVMDClient { connection.client }
    private(set) var info: DeviceInfo?
    let changes: AsyncStream<DeviceStateChange>
    private let continuation: AsyncStream<DeviceStateChange>.Continuation
    private var eventTask: Task<Void, Never>?

    private init(_ connection: Connection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream<DeviceStateChange>.makeStream()
        self.changes = stream
        self.continuation = continuation
    }

    static func start(_ connection: Connection) async -> PiKVMBackend {
        let backend = PiKVMBackend(connection)
        backend.info = try? await connection.client.info()
        backend.watchEvents()
        return backend
    }

    var endpointLabel: String { connection.endpoint.label }
    var host: String { connection.endpoint.host }

    var infoRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let v = info?.kvmdVersion { rows.append(("kvmd", v)) }
        if let h = info?.hostname { rows.append(("Hostname", h)) }
        return rows
    }

    /// Follows kvmd's event socket, reconnecting with backoff. kvmd may send
    /// partial updates, so each event only says what to read again.
    private func watchEvents() {
        let client = self.client
        let continuation = self.continuation
        eventTask = Task {
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                do {
                    for try await event in client.events() {
                        backoff = 1
                        switch event.eventType {
                        case "atx": continuation.yield(.atx)
                        case "hid": continuation.yield(.hid)
                        case "switch": continuation.yield(.switchPorts)
                        case "msd": continuation.yield(.media(full: true))
                        default: break
                        }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        continuation.finish()
    }

    // MARK: State

    func readATX() async -> ATXState? { try? await client.atx() }
    func readHID() async -> HIDState? { try? await client.hid() }
    func readSwitch() async -> SwitchState? { try? await client.switchState() }
    func readMedia(full: Bool) async -> MSDState? { try? await client.msd() }

    // MARK: Machines and input

    func setActiveSwitchPort(_ port: Int) async throws {
        try await client.setActiveSwitchPort(port)
    }

    func setSwitchBeacon(port: Int, on: Bool) async throws {
        try await client.setSwitchBeacon(port: port, on: on)
    }

    func applyMouseMode(_ mode: MouseMode, hid: HIDState?) async throws {
        guard hid?.activeMouseMode != mode, hid?.supportedMouseModes.contains(mode) ?? true else { return }
        try await client.setMouseMode(mode)
        continuation.yield(.hid)
    }

    // MARK: Power

    func power(_ action: ATXPowerAction, switchPort: Int?, poweredOn: Bool?) async throws {
        if let port = switchPort {
            try await client.switchATXPower(port: port, action)
        } else {
            try await client.atxPower(action)
        }
    }

    func click(_ button: ATXButton, switchPort: Int?) async throws {
        if let port = switchPort {
            try await client.switchATXClick(port: port, button)
        } else {
            try await client.atxClick(button)
        }
    }

    func snapshot() async throws -> NSImage {
        try NSImage.snapshot(try await client.snapshot())
    }

    // MARK: Virtual media

    var canUploadImages: Bool { true }

    func uploadImage(fileURL: URL, as name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await client.msdUpload(fileURL: fileURL, as: name, progress: progress)
    }

    func mountImage(_ image: String, cdrom: Bool, writable: Bool, driveConnected: Bool) async throws {
        if driveConnected { try await client.msdSetConnected(false) }
        try await client.msdSetParams(image: image, cdrom: cdrom, writable: cdrom ? false : writable)
        try await client.msdSetConnected(true)
    }

    func ejectImage() async throws {
        try await client.msdSetConnected(false)
    }

    func deleteImage(_ name: String) async throws {
        try await client.msdRemove(image: name)
    }
}
