import AppKit
import Foundation
import KVMKit

/// An Openterface plugged into this Mac. The console opens its video and
/// serial port itself; here there is only the screen preview.
@MainActor
final class OpenterfaceBackend: DeviceBackend {
    let unit: OpenterfaceUnit
    let changes: AsyncStream<DeviceStateChange>
    private let continuation: AsyncStream<DeviceStateChange>.Continuation

    init(unit: OpenterfaceUnit) {
        self.unit = unit
        let (stream, continuation) = AsyncStream<DeviceStateChange>.makeStream()
        self.changes = stream
        self.continuation = continuation
    }

    var endpointLabel: String { "USB" }
    var host: String { unit.displayName }

    func snapshot() async throws -> NSImage {
        try await OpenterfaceCapture.snapshot(videoID: unit.id)
    }

    func stop() {
        continuation.finish()
    }
}
