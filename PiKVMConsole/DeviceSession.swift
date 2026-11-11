import AppKit
import Foundation
import Observation
import PiKVMKit

/// A live connection to one PiKVM: picks a reachable endpoint, keeps ATX,
/// HID and Switch state fresh from the kvmd event socket, and applies the
/// selected target's saved settings.
@MainActor
@Observable
final class DeviceSession {
    enum Status: Equatable {
        case idle
        case connecting
        case connected(endpointLabel: String, host: String)
        case failed(String)
    }

    let deviceID: UUID
    private(set) var status: Status = .idle
    private(set) var info: DeviceInfo?
    private(set) var atx: ATXState?
    private(set) var hid: HIDState?
    private(set) var switchState: SwitchState?
    /// The PiKVM's virtual drive and stored images.
    private(set) var msd: MSDState?
    /// An image upload started from this app.
    private(set) var upload: MediaUpload?
    /// The latest screen preview of each machine, by target id.
    private(set) var previews: [UUID: ScreenPreview] = [:]
    private(set) var previewsLoading: Set<UUID> = []

    struct ScreenPreview {
        var image: NSImage?
        var date: Date?
        var error: String?
    }

    /// The last virtual media problem, shown in the media panel.
    var mediaError: String?

    struct MediaUpload: Equatable {
        let name: String
        var sent: Int64
        var total: Int64
    }

    private weak var model: AppModel?
    private var connection: Connection?
    private var eventTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    init(deviceID: UUID, model: AppModel) {
        self.deviceID = deviceID
        self.model = model
    }

    var client: KVMDClient? { connection?.client }

    func connectIfNeeded() async {
        switch status {
        case .idle, .failed: await connect()
        default: break
        }
    }

    func connect() async {
        guard let model, let device = model.device(deviceID) else { return }
        guard let password = model.credentials.password(for: deviceID) else {
            status = .failed("No password saved for this device. Edit the device to add one.")
            return
        }
        status = .connecting
        do {
            let conn = try await ConnectionResolver.connect(to: device, password: password)
            connection = conn
            if device.pinnedCertificateSHA256 == nil, let fp = conn.observedCertificateSHA256 {
                model.update(deviceID) { $0.pinnedCertificateSHA256 = fp }
            }
            status = .connected(endpointLabel: conn.endpoint.label, host: conn.endpoint.host)
            info = try? await conn.client.info()
            await refreshAll()
            startEvents()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        connection = nil
        status = .idle
    }

    func refreshAll() async {
        await refreshATX()
        await refreshHID()
        await refreshSwitch()
        await refreshMSD()
    }

    func refreshMSD() async {
        msd = try? await client?.msd()
    }

    private func refreshATX() async {
        atx = try? await client?.atx()
    }

    private func refreshHID() async {
        hid = try? await client?.hid()
    }

    private func refreshSwitch() async {
        guard let client else { return }
        let state = try? await client.switchState()
        switchState = state
        model?.update(deviceID) { $0.syncTargets(withSwitchPorts: state?.ports ?? []) }
    }

    private func startEvents() {
        eventTask?.cancel()
        guard let client else { return }
        eventTask = Task { [weak self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                do {
                    for try await event in client.events() {
                        backoff = 1
                        guard let self else { return }
                        // kvmd may send partial updates, so re-read the full state.
                        switch event.eventType {
                        case "atx": await self.refreshATX()
                        case "hid": await self.refreshHID()
                        case "switch": await self.refreshSwitch()
                        case "msd": await self.refreshMSD()
                        default: break
                        }
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    // MARK: Actions

    /// Makes `target` the active machine (switch port) and applies its saved mouse mode.
    func activate(_ target: Target) async throws {
        guard let client else { return }
        if let port = target.switchPort, switchState?.activePort != port {
            try await client.setActiveSwitchPort(port)
        }
        try await applyMouseMode(target.mouseMode)
    }

    /// Whether the Switch's beacon light is blinking for a target's port.
    func beacon(for target: Target) -> Bool? {
        guard let port = target.switchPort, let beacons = switchState?.beacons, port < beacons.count else { return nil }
        return beacons[port]
    }

    func setBeacon(_ on: Bool, for target: Target) async throws {
        guard let client, let port = target.switchPort else { return }
        try await client.setSwitchBeacon(port: port, on: on)
    }

    func applyMouseMode(_ mode: MouseMode) async throws {
        guard let client else { return }
        if hid?.activeMouseMode != mode, hid?.supportedMouseModes.contains(mode) ?? true {
            try await client.setMouseMode(mode)
            await refreshHID()
        }
    }

    func power(_ action: ATXPowerAction, for target: Target) async throws {
        guard let client else { return }
        if let port = target.switchPort {
            try await client.switchATXPower(port: port, action)
        } else {
            try await client.atxPower(action)
        }
    }

    func click(_ button: ATXButton, for target: Target) async throws {
        guard let client else { return }
        if let port = target.switchPort {
            try await client.switchATXClick(port: port, button)
        } else {
            try await client.atxClick(button)
        }
    }

    // MARK: Screen preview

    /// Whether `target` is what the PiKVM's video shows right now. Behind a
    /// Switch that is only the active port.
    func isOnScreen(_ target: Target) -> Bool {
        target.switchPort == nil || switchState?.activePort == target.switchPort
    }

    /// Takes a fresh picture of the machine's screen.
    func refreshPreview(for target: Target) async {
        guard let client, isOnScreen(target), !previewsLoading.contains(target.id) else { return }
        previewsLoading.insert(target.id)
        defer { previewsLoading.remove(target.id) }
        do {
            let data = try await client.snapshot()
            guard let image = NSImage(data: data) else { throw KVMDError.api("The PiKVM returned a picture this Mac can't read.") }
            previews[target.id] = ScreenPreview(image: image, date: Date(), error: nil)
        } catch is CancellationError {
        } catch {
            var preview = previews[target.id] ?? ScreenPreview()
            preview.error = error.localizedDescription
            previews[target.id] = preview
        }
    }

    // MARK: Virtual media

    /// Selects `image` for the virtual drive and plugs it into the remote machine.
    func mountMedia(image: String, cdrom: Bool, writable: Bool) async throws {
        guard let client else { return }
        if msd?.drive?.connected == true {
            try await client.msdSetConnected(false)
        }
        try await client.msdSetParams(image: image, cdrom: cdrom, writable: cdrom ? false : writable)
        try await client.msdSetConnected(true)
        await refreshMSD()
    }

    /// Unplugs the virtual drive from the remote machine.
    func ejectMedia() async throws {
        guard let client else { return }
        try await client.msdSetConnected(false)
        await refreshMSD()
    }

    func removeImage(_ name: String) async throws {
        guard let client else { return }
        try await client.msdRemove(image: name)
        await refreshMSD()
    }

    /// Uploads a local ISO or disk image to the PiKVM. Progress is in `upload`.
    func startUpload(fileURL: URL) {
        guard upload == nil, let client else { return }
        let name = MSDImageName.sanitized(fileURL.lastPathComponent)
        // Files picked in an open panel need this in the sandbox.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        var problem: String?
        if msd?.images.contains(where: { $0.name == name }) == true {
            problem = "The PiKVM already has an image named \(name). Delete it first, or rename the file."
        } else if let free = msd?.freeBytes, size > free {
            let f = ByteCountFormatter()
            problem = "\(name) is \(f.string(fromByteCount: size)), but the PiKVM has only \(f.string(fromByteCount: free)) free."
        }
        if let problem {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            mediaError = problem
            return
        }

        mediaError = nil
        upload = MediaUpload(name: name, sent: 0, total: size)
        // Called off the main thread. It holds the session only while the upload runs.
        let session = self
        let report: @Sendable (Int64, Int64) -> Void = { sent, total in
            Task { @MainActor in
                guard session.upload?.name == name else { return }
                session.upload = MediaUpload(name: name, sent: sent, total: total)
            }
        }
        uploadTask = Task { [weak self] in
            do {
                try await client.msdUpload(fileURL: fileURL, as: name, progress: report)
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self?.mediaError = "Uploading \(name) failed: \(error.localizedDescription)"
                }
            }
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            self?.upload = nil
            self?.uploadTask = nil
            await self?.refreshMSD()
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
    }

    /// Power/HDD LEDs for a target: from the switch for switch ports,
    /// otherwise from the PiKVM's own ATX board.
    func leds(for target: Target) -> (power: Bool, hdd: Bool)? {
        if let port = target.switchPort {
            guard let p = switchState?.powerLEDs, let h = switchState?.hddLEDs, port < p.count, port < h.count else { return nil }
            return (p[port], h[port])
        }
        guard let atx, atx.enabled else { return nil }
        return (atx.leds.power, atx.leds.hdd)
    }

    /// Whether an ATX action is still running for a target, so another can't start yet.
    func atxBusy(for target: Target) -> Bool {
        if let port = target.switchPort {
            guard let busy = switchState?.atxBusy, port < busy.count else { return false }
            return busy[port]
        }
        return atx?.busy ?? false
    }
}
