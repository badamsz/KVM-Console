import AppKit
import Foundation
import KVMKit

/// Part of a device's state that changed and should be read again.
enum DeviceStateChange: Sendable {
    case atx
    case hid
    case switchPorts
    /// The virtual drive and stored images. `full` also reads free space,
    /// which is slow on some devices and skipped by background polling.
    case media(full: Bool)
}

/// One kind of device, connected. `DeviceSession` owns the observable state
/// and talks to every kind of device through this protocol, so it has no
/// per-family branches. Adding a kind of device means writing one backend
/// (and, for the console, one `ConsoleInput`).
///
/// Methods a device can't do have default implementations that do nothing
/// or return nil; override only what the device supports.
@MainActor
protocol DeviceBackend: AnyObject {
    /// How the device was reached, shown as "Connected via <label> (<host>)".
    var endpointLabel: String { get }
    var host: String { get }

    /// Software versions and names for the detail page, as label/value rows.
    var infoRows: [(label: String, value: String)] { get }

    /// Tells the session what to read again. Finishes when the backend stops.
    var changes: AsyncStream<DeviceStateChange> { get }

    /// Reads the parts of the state this device has. Nil when it has none.
    func readATX() async -> ATXState?
    func readHID() async -> HIDState?
    func readSwitch() async -> SwitchState?
    func readMedia(full: Bool) async -> MSDState?

    // Machines and input
    func setActiveSwitchPort(_ port: Int) async throws
    func setSwitchBeacon(port: Int, on: Bool) async throws
    /// Applies the machine's saved mouse mode, when the device keeps one.
    func applyMouseMode(_ mode: MouseMode, hid: HIDState?) async throws

    // Power
    func power(_ action: ATXPowerAction, switchPort: Int?, poweredOn: Bool?) async throws
    func click(_ button: ATXButton, switchPort: Int?) async throws

    /// A still picture of the screen.
    func snapshot() async throws -> NSImage

    // Virtual media
    /// Whether images can be uploaded from this Mac right now.
    var canUploadImages: Bool { get }
    /// The name an uploaded file is stored under on the device.
    func storedImageName(for fileName: String) -> String
    /// A reason this file can't be uploaded, checked before starting.
    func uploadProblem(for fileName: String) -> String?
    /// Uploads a file. Cancelling the calling task cancels the upload.
    func uploadImage(fileURL: URL, as name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    /// Removes what a failed or cancelled upload left behind.
    func cleanUpFailedUpload(storedName: String) async
    func mountImage(_ image: String, cdrom: Bool, writable: Bool, driveConnected: Bool) async throws
    func ejectImage() async throws
    func deleteImage(_ name: String) async throws

    /// Stops background work. The backend isn't used afterwards.
    func stop()
}

extension DeviceBackend {
    var infoRows: [(label: String, value: String)] { [] }
    func readATX() async -> ATXState? { nil }
    func readHID() async -> HIDState? { nil }
    func readSwitch() async -> SwitchState? { nil }
    func readMedia(full: Bool) async -> MSDState? { nil }
    func setActiveSwitchPort(_ port: Int) async throws {}
    func setSwitchBeacon(port: Int, on: Bool) async throws {}
    func applyMouseMode(_ mode: MouseMode, hid: HIDState?) async throws {}
    func power(_ action: ATXPowerAction, switchPort: Int?, poweredOn: Bool?) async throws {}
    func click(_ button: ATXButton, switchPort: Int?) async throws {}
    var canUploadImages: Bool { false }
    func storedImageName(for fileName: String) -> String { fileName }
    func uploadProblem(for fileName: String) -> String? { nil }
    func uploadImage(fileURL: URL, as name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func cleanUpFailedUpload(storedName: String) async {}
    func mountImage(_ image: String, cdrom: Bool, writable: Bool, driveConnected: Bool) async throws {}
    func ejectImage() async throws {}
    func deleteImage(_ name: String) async throws {}
}

/// A device that can download an image from a URL itself (Sipeed).
@MainActor
protocol URLImageDownloading: DeviceBackend {
    var canCancelDownload: Bool { get }
    func startDownload(url: URL) async throws
    func cancelDownload() async throws
    func downloadStatus() async throws -> NanoKVMDownloadStatus?
}

/// Builds the backend for a device. The only place that maps a device
/// family to its implementation.
@MainActor
enum DeviceBackends {
    struct Connected {
        let backend: any DeviceBackend
        /// What the TLS handshake showed, for trust-on-first-use.
        var certificateSHA256: String?
        var trustedByCA: Bool?
    }

    static func connect(to device: Device, app: AppModel) async throws -> Connected {
        switch device.family {
        case .openterface:
            app.refreshUSB()
            guard let unit = app.pluggedUnits[device.id] else {
                throw KVMDError.api("This Openterface isn't plugged into this Mac. Connect its USB-C host cable to this Mac.")
            }
            return Connected(backend: OpenterfaceBackend(unit: unit))
        case .pikvm, .nanoKVM, .nanoKVMPro:
            guard let password = app.credentials.password(for: device.id) else {
                throw KVMDError.api("No password saved for this device. Edit the device to add one.")
            }
            if device.family.isSipeed {
                let conn = try await NanoKVMConnectionResolver.connect(to: device, password: password)
                let backend = await NanoKVMBackend.start(conn)
                return Connected(backend: backend, certificateSHA256: conn.observedCertificateSHA256,
                                 trustedByCA: conn.observedTrustedByCA)
            }
            let conn = try await ConnectionResolver.connect(to: device, password: password)
            let backend = await PiKVMBackend.start(conn)
            return Connected(backend: backend, certificateSHA256: conn.observedCertificateSHA256,
                             trustedByCA: conn.observedTrustedByCA)
        }
    }
}

extension NSImage {
    /// Decodes a snapshot, or throws a message the user can read.
    static func snapshot(_ data: Data) throws -> NSImage {
        guard let image = NSImage(data: data) else {
            throw KVMDError.api("The device returned a picture this Mac can't read.")
        }
        return image
    }
}
