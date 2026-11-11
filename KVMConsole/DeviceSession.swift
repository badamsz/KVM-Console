import AppKit
import AVFoundation
import Foundation
import Observation
import PiKVMKit

/// A live connection to one device: picks a reachable endpoint, keeps ATX,
/// HID and Switch state fresh (from the kvmd event socket, or by polling a
/// Sipeed NanoKVM), and applies the selected target's saved settings.
///
/// A PiKVM is driven through `client` (kvmd); a Sipeed device through
/// `nanoClient`; an Openterface plugged into this Mac is `localUnit`.
/// Exactly one of them is set while connected.
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
    /// The machine whose Switch port is being made active, for a spinner in the sidebar.
    private(set) var switchingTo: UUID?

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
    private var nanoConnection: NanoKVMConnection?
    private var eventTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    init(deviceID: UUID, model: AppModel) {
        self.deviceID = deviceID
        self.model = model
    }

    /// The kvmd client, while connected to a PiKVM.
    var client: KVMDClient? { connection?.client }
    /// The NanoKVM client, while connected to a Sipeed device.
    var nanoClient: NanoKVMClient? { nanoConnection?.client }
    /// The Openterface this device stands for, while it is plugged in.
    private(set) var localUnit: OpenterfaceUnit?
    /// Connected to any kind of device.
    var isConnected: Bool { client != nil || nanoClient != nil || localUnit != nil }
    /// The NanoKVM application version, while connected to a Sipeed device.
    private(set) var nanoInfo: NanoKVMInfo?

    /// Which API this device speaks.
    var family: DeviceFamily { model?.device(deviceID)?.family ?? .pikvm }
    /// Whether images can be uploaded from this Mac (kvmd only, for now).
    var supportsImageUpload: Bool { family == .pikvm || nanoCanUpload }
    /// Whether the device can download images from a URL itself (Sipeed only).
    var supportsURLDownload: Bool { nanoClient != nil }
    /// Classic NanoKVM firmware before 2.5.3 has no upload API.
    private var nanoCanUpload = false
    /// A download the device is making from a URL, while one runs.
    private(set) var download: NanoKVMDownloadStatus?
    private var downloadWatch: Task<Void, Never>?

    func connectIfNeeded() async {
        switch status {
        case .idle, .failed: await connect()
        default: break
        }
    }

    func connect() async {
        guard let model, let device = model.device(deviceID) else { return }
        if device.family.isLocal {
            model.refreshUSB()
            connectLocal()
            return
        }
        guard let password = model.credentials.password(for: deviceID) else {
            status = .failed("No password saved for this device. Edit the device to add one.")
            return
        }
        status = .connecting
        if device.family.isSipeed {
            await connectNanoKVM(device, password: password, model: model)
            return
        }
        do {
            let conn = try await ConnectionResolver.connect(to: device, password: password)
            connection = conn
            var learned = device
            learned.learnCertificate(sha256: conn.observedCertificateSHA256, trustedByCA: conn.observedTrustedByCA)
            if learned.certificateTrust != device.certificateTrust || learned.pinnedCertificateSHA256 != device.pinnedCertificateSHA256 {
                model.update(deviceID) { $0.learnCertificate(sha256: conn.observedCertificateSHA256, trustedByCA: conn.observedTrustedByCA) }
            }
            status = .connected(endpointLabel: conn.endpoint.label, host: conn.endpoint.host)
            info = try? await conn.client.info()
            await refreshAll()
            startEvents()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Takes the Openterface this device is, if it is plugged in. The
    /// console opens its video and serial port itself.
    private func connectLocal() {
        guard let unit = model?.pluggedUnits[deviceID] else {
            localUnit = nil
            status = .failed("This Openterface isn't plugged into this Mac. Connect its USB-C host cable to this Mac.")
            return
        }
        localUnit = unit
        status = .connected(endpointLabel: "USB", host: unit.displayName)
    }

    /// The app noticed this device's Openterface being plugged in, unplugged
    /// or moved to another port.
    func usbChanged() {
        switch status {
        case .connecting: return
        case .idle where localUnit == nil: return
        default: connectLocal()
        }
    }

    private func connectNanoKVM(_ device: Device, password: String, model: AppModel) async {
        do {
            let conn = try await NanoKVMConnectionResolver.connect(to: device, password: password)
            nanoConnection = conn
            var learned = device
            learned.learnCertificate(sha256: conn.observedCertificateSHA256, trustedByCA: conn.observedTrustedByCA)
            if learned.certificateTrust != device.certificateTrust || learned.pinnedCertificateSHA256 != device.pinnedCertificateSHA256 {
                model.update(deviceID) { $0.learnCertificate(sha256: conn.observedCertificateSHA256, trustedByCA: conn.observedTrustedByCA) }
            }
            status = .connected(endpointLabel: conn.endpoint.label, host: conn.endpoint.host)
            nanoInfo = try? await conn.client.info()
            await refreshAll()
            startPolling()
            if let status = try? await conn.client.downloadStatus(), status.inProgress {
                download = status
                watchDownload()
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        connection = nil
        nanoConnection = nil
        nanoInfo = nil
        localUnit = nil
        downloadWatch?.cancel()
        downloadWatch = nil
        download = nil
        status = .idle
    }

    func refreshAll() async {
        if localUnit != nil { return }
        if nanoClient != nil {
            await refreshNanoATX()
            await refreshMSD()
            return
        }
        await refreshATX()
        await refreshHID()
        await refreshSwitch()
        await refreshMSD()
    }

    /// - Parameter includeFreeSpace: NanoKVM only; left out by background polling.
    func refreshMSD(includeFreeSpace: Bool = true) async {
        if let nanoClient {
            // Without a fresh reading, keep showing the last free space.
            let previous: (total: Int64?, free: Int64?)? = includeFreeSpace ? nil : (msd?.totalBytes, msd?.freeBytes)
            let result = await Self.nanoMSD(nanoClient, includeFreeSpace: includeFreeSpace, previousSpace: previous)
            msd = result?.state
            nanoCanUpload = result?.canUpload ?? false
            return
        }
        msd = try? await client?.msd()
    }

    nonisolated private static func nanoMSD(_ client: NanoKVMClient, includeFreeSpace: Bool,
                                            previousSpace: (total: Int64?, free: Int64?)?) async -> (state: MSDState, canUpload: Bool)? {
        guard var library = try? await client.library(includeFreeSpace: includeFreeSpace) else { return nil }
        if let previousSpace, library.canUpload {
            library.totalBytes = previousSpace.total
            library.freeBytes = previousSpace.free
        }
        let mounted = try? await client.mountedImage()
        var cdrom = mounted?.cdrom ?? false
        if mounted?.cdrom == nil, client.family == .nanoKVM, mounted?.file.isEmpty == false {
            cdrom = (try? await client.cdromMode()) ?? false
        }
        return (MSDState(nanoKVM: library, mounted: mounted, cdrom: cdrom), library.canUpload)
    }

    /// NanoKVM: the LEDs, shown as ATX state. Devices without an ATX board
    /// (NanoKVM Lite, NanoKVM Go) fail to read them and show no power controls.
    private func refreshNanoATX() async {
        guard let nanoClient else { return }
        if let leds = try? await nanoClient.leds() {
            atx = ATXState(nanoKVM: leds, busy: powerPressing)
        } else {
            atx = nil
        }
    }

    /// True while a NanoKVM power or reset button press is being held.
    private var powerPressing = false

    /// NanoKVM has no event socket for state, so poll the LEDs and media.
    private func startPolling() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.nanoClient != nil else { return }
                await self.refreshNanoATX()
                tick += 1
                if tick % 5 == 0 { await self.refreshMSD(includeFreeSpace: false) }
            }
        }
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
        // A NanoKVM has one machine and picks the mouse per report.
        guard let client else { return }
        if let port = target.switchPort, switchState?.activePort != port {
            switchingTo = target.id
            defer { if switchingTo == target.id { switchingTo = nil } }
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
        if nanoClient != nil {
            try await pressNano(action.nanoKVMPress(powerIsOn: atx?.leds.power))
            return
        }
        guard let client else { return }
        if let port = target.switchPort {
            try await client.switchATXPower(port: port, action)
        } else {
            try await client.atxPower(action)
        }
    }

    func click(_ button: ATXButton, for target: Target) async throws {
        if nanoClient != nil {
            try await pressNano(button.nanoKVMPress)
            return
        }
        guard let client else { return }
        if let port = target.switchPort {
            try await client.switchATXClick(port: port, button)
        } else {
            try await client.atxClick(button)
        }
    }

    private func pressNano(_ press: ATXPowerAction.NanoKVMPress) async throws {
        guard let nanoClient, press != .none, !powerPressing else { return }
        powerPressing = true
        if let atx { self.atx = ATXState(enabled: atx.enabled, busy: true, power: atx.leds.power, hdd: atx.leds.hdd) }
        do {
            switch press {
            case .none: break
            case .power(let ms): try await nanoClient.pressPower(milliseconds: ms)
            case .reset: try await nanoClient.pressReset()
            }
        } catch {
            powerPressing = false
            await refreshNanoATX()
            throw error
        }
        powerPressing = false
        await refreshNanoATX()
    }

    // MARK: Screen preview

    /// Whether `target` is what the PiKVM's video shows right now. Behind a
    /// Switch that is only the active port.
    func isOnScreen(_ target: Target) -> Bool {
        target.switchPort == nil || switchState?.activePort == target.switchPort
    }

    /// Takes a fresh picture of the machine's screen.
    func refreshPreview(for target: Target) async {
        guard isConnected, isOnScreen(target), !previewsLoading.contains(target.id) else { return }
        previewsLoading.insert(target.id)
        defer { previewsLoading.remove(target.id) }
        do {
            if let localUnit {
                let image = try await OpenterfaceCapture.snapshot(videoID: localUnit.id)
                previews[target.id] = ScreenPreview(image: image, date: Date(), error: nil)
                return
            }
            let data: Data
            if let nanoClient {
                data = try await nanoClient.snapshot()
            } else if let client {
                data = try await client.snapshot()
            } else {
                return
            }
            guard let image = NSImage(data: data) else { throw KVMDError.api("The device returned a picture this Mac can't read.") }
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
        if let nanoClient {
            try await nanoClient.mountImage(image, cdrom: cdrom, writable: writable)
            await refreshMSD()
            return
        }
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
        if let nanoClient {
            try await nanoClient.mountImage("", cdrom: false)
            await refreshMSD()
            return
        }
        guard let client else { return }
        try await client.msdSetConnected(false)
        await refreshMSD()
    }

    func removeImage(_ name: String) async throws {
        if let nanoClient {
            try await nanoClient.deleteImage(name)
            await refreshMSD()
            return
        }
        guard let client else { return }
        try await client.msdRemove(image: name)
        await refreshMSD()
    }

    /// Uploads a local ISO or disk image to the PiKVM. Progress is in `upload`.
    func startUpload(fileURL: URL) {
        guard upload == nil, client != nil || nanoClient != nil else { return }
        let name = MSDImageName.sanitized(fileURL.lastPathComponent)
        // Files picked in an open panel need this in the sandbox.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let deviceName = model?.device(deviceID)?.model.shortName ?? "PiKVM"
        // A NanoKVM names images by their path in /data.
        let storedName = nanoClient == nil ? name : NanoKVMClient.imageDirectory + "/" + name

        var problem: String?
        if nanoClient != nil, !NanoKVMClient.isImageName(name) {
            problem = "The \(deviceName) only uses .iso and .img files. Rename \(name) if it is a disk image."
        } else if msd?.images.contains(where: { $0.name.lowercased() == storedName.lowercased() }) == true {
            problem = "The \(deviceName) already has an image named \(name). Delete it first, or rename the file."
        } else if let free = msd?.freeBytes, size > free {
            let f = ByteCountFormatter()
            problem = "\(name) is \(f.string(fromByteCount: size)), but the \(deviceName) has only \(f.string(fromByteCount: free)) free."
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
        let client = self.client
        let nanoClient = self.nanoClient
        uploadTask = Task { [weak self] in
            do {
                if let nanoClient {
                    try await nanoClient.uploadImage(fileURL: fileURL, as: name, progress: report)
                } else if let client {
                    try await client.msdUpload(fileURL: fileURL, as: name, progress: report)
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self?.mediaError = "Uploading \(name) failed: \(error.localizedDescription)"
                }
                // A NanoKVM keeps what arrived; remove the partial image (the
                // name was checked to be free before starting).
                if let nanoClient { try? await nanoClient.deleteImage(storedName) }
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

    // MARK: Download from a URL (Sipeed)

    /// Asks the device to download an image from `url`. Progress is in `download`.
    func startDownload(url: URL) async throws {
        guard let nanoClient, download?.inProgress != true else { return }
        let name = url.lastPathComponent
        if !NanoKVMClient.isImageName(name) {
            throw KVMDError.api("The address must end in an .iso or .img file name, such as …/ubuntu-24.04-desktop-amd64.iso.")
        }
        if msd?.images.contains(where: { ($0.name as NSString).lastPathComponent.lowercased() == name.lowercased() }) == true {
            throw KVMDError.api("The device already has an image named \(name). Delete it first.")
        }
        try await nanoClient.startDownload(url: url)
        download = try? await nanoClient.downloadStatus()
        watchDownload()
    }

    func cancelDownload() async throws {
        try await nanoClient?.cancelDownload()
        download = try? await nanoClient?.downloadStatus()
    }

    /// Follows the device's download until it finishes, then refreshes the list.
    private func watchDownload() {
        downloadWatch?.cancel()
        downloadWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, let nanoClient = self.nanoClient else { return }
                guard let status = try? await nanoClient.downloadStatus() else { continue }
                if status.inProgress {
                    self.download = status
                    continue
                }
                self.download = nil
                switch status.status {
                case "failed": self.mediaError = "The download failed. Check that the device can reach the address."
                case "checksum_failed": self.mediaError = "The downloaded image didn't match its checksum and was removed."
                default: break
                }
                await self.refreshMSD()
                return
            }
        }
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
