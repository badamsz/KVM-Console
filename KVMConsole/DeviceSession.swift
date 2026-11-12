import AppKit
import AVFoundation
import Foundation
import Observation
import KVMKit

/// A live connection to one device. It holds the device's observable state
/// (ATX, HID, Switch, virtual media, previews) and applies the selected
/// machine's saved settings. Everything specific to a kind of device lives
/// in its `DeviceBackend`; see `Backends/`.
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
    /// The connected device, or nil while not connected.
    private(set) var backend: (any DeviceBackend)?
    private(set) var atx: ATXState?
    private(set) var hid: HIDState?
    private(set) var switchState: SwitchState?
    /// The device's virtual drive and stored images.
    private(set) var msd: MSDState?
    /// An image upload started from this app.
    private(set) var upload: MediaUpload?
    /// The latest screen preview of each machine, by target id.
    private(set) var previews: [UUID: ScreenPreview] = [:]
    private(set) var previewsLoading: Set<UUID> = []
    /// The machine whose Switch port is being made active, for a spinner in the sidebar.
    private(set) var switchingTo: UUID?
    /// A download the device is making from a URL, while one runs.
    private(set) var download: NanoKVMDownloadStatus?

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
    private var changeTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var downloadWatch: Task<Void, Never>?

    init(deviceID: UUID, model: AppModel) {
        self.deviceID = deviceID
        self.model = model
    }

    // MARK: Backend shortcuts

    /// The kvmd client, while connected to a PiKVM.
    var client: KVMDClient? { (backend as? PiKVMBackend)?.client }
    /// The NanoKVM client, while connected to a Sipeed device.
    var nanoClient: NanoKVMClient? { (backend as? NanoKVMBackend)?.client }
    /// The Openterface this device stands for, while it is plugged in.
    var localUnit: OpenterfaceUnit? { (backend as? OpenterfaceBackend)?.unit }
    /// The device's download-from-URL support, when it has one.
    var downloader: (any URLImageDownloading)? { backend as? any URLImageDownloading }

    var isConnected: Bool { backend != nil }
    /// Whether images can be uploaded from this Mac.
    var supportsImageUpload: Bool { backend?.canUploadImages ?? false }
    /// Whether the device can download images from a URL itself.
    var supportsURLDownload: Bool { downloader != nil }
    /// Versions and names for the detail page.
    var infoRows: [(label: String, value: String)] { backend?.infoRows ?? [] }

    // MARK: Connecting

    func connectIfNeeded() async {
        switch status {
        case .idle, .failed: await connect()
        default: break
        }
    }

    func connect() async {
        guard let model, let device = model.device(deviceID) else { return }
        disconnect()
        status = .connecting
        do {
            let connected = try await DeviceBackends.connect(to: device, app: model)
            learnCertificate(sha256: connected.certificateSHA256, trustedByCA: connected.trustedByCA)
            let backend = connected.backend
            self.backend = backend
            status = .connected(endpointLabel: backend.endpointLabel, host: backend.host)
            await refreshAll()
            follow(backend)
            if let downloader, let status = try? await downloader.downloadStatus(), status.inProgress {
                download = status
                watchDownload()
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Trust on first use: remembers the certificate the first connection saw.
    private func learnCertificate(sha256: String?, trustedByCA: Bool?) {
        guard let model, let device = model.device(deviceID) else { return }
        var learned = device
        learned.learnCertificate(sha256: sha256, trustedByCA: trustedByCA)
        if learned.certificateTrust != device.certificateTrust || learned.pinnedCertificateSHA256 != device.pinnedCertificateSHA256 {
            model.update(deviceID) { $0.learnCertificate(sha256: sha256, trustedByCA: trustedByCA) }
        }
    }

    /// The app noticed this device's Openterface being plugged in, unplugged
    /// or moved to another port.
    func usbChanged() {
        switch status {
        case .connecting: return
        case .idle where backend == nil: return
        default: Task { await connect() }
        }
    }

    func disconnect() {
        changeTask?.cancel()
        changeTask = nil
        backend?.stop()
        backend = nil
        downloadWatch?.cancel()
        downloadWatch = nil
        download = nil
        status = .idle
    }

    // MARK: State

    /// Reads what the backend reports as changed, until it stops.
    private func follow(_ backend: any DeviceBackend) {
        changeTask?.cancel()
        let changes = backend.changes
        changeTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.refresh(change)
            }
        }
    }

    func refreshAll() async {
        await refresh(.atx)
        await refresh(.hid)
        await refresh(.switchPorts)
        await refresh(.media(full: true))
    }

    func refresh(_ change: DeviceStateChange) async {
        guard let backend else { return }
        switch change {
        case .atx:
            atx = await backend.readATX()
        case .hid:
            hid = await backend.readHID()
        case .switchPorts:
            let state = await backend.readSwitch()
            switchState = state
            if model?.device(deviceID)?.family.supportsSwitch == true {
                model?.update(deviceID) { $0.syncTargets(withSwitchPorts: state?.ports ?? []) }
            }
        case .media(let full):
            msd = await backend.readMedia(full: full)
        }
    }

    func refreshMSD() async {
        await refresh(.media(full: true))
    }

    // MARK: Actions

    /// Makes `target` the active machine (switch port) and applies its saved mouse mode.
    func activate(_ target: Target) async throws {
        guard let backend else { return }
        if let port = target.switchPort, switchState?.activePort != port {
            switchingTo = target.id
            defer { if switchingTo == target.id { switchingTo = nil } }
            try await backend.setActiveSwitchPort(port)
        }
        try await applyMouseMode(target.mouseMode)
    }

    /// Whether the Switch's beacon light is blinking for a target's port.
    func beacon(for target: Target) -> Bool? {
        guard let port = target.switchPort, let beacons = switchState?.beacons, port < beacons.count else { return nil }
        return beacons[port]
    }

    func setBeacon(_ on: Bool, for target: Target) async throws {
        guard let port = target.switchPort else { return }
        try await backend?.setSwitchBeacon(port: port, on: on)
    }

    func applyMouseMode(_ mode: MouseMode) async throws {
        try await backend?.applyMouseMode(mode, hid: hid)
    }

    func power(_ action: ATXPowerAction, for target: Target) async throws {
        try await backend?.power(action, switchPort: target.switchPort, poweredOn: leds(for: target)?.power)
    }

    func click(_ button: ATXButton, for target: Target) async throws {
        try await backend?.click(button, switchPort: target.switchPort)
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
            guard let backend else { return }
            let image = try await backend.snapshot()
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
        guard let backend else { return }
        try await backend.mountImage(image, cdrom: cdrom, writable: writable,
                                     driveConnected: msd?.drive?.connected == true)
        await refreshMSD()
    }

    /// Unplugs the virtual drive from the remote machine.
    func ejectMedia() async throws {
        guard let backend else { return }
        try await backend.ejectImage()
        await refreshMSD()
    }

    func removeImage(_ name: String) async throws {
        guard let backend else { return }
        try await backend.deleteImage(name)
        await refreshMSD()
    }

    /// Uploads a local ISO or disk image to the device. Progress is in `upload`.
    func startUpload(fileURL: URL) {
        guard upload == nil, let backend, backend.canUploadImages else { return }
        let name = MSDImageName.sanitized(fileURL.lastPathComponent)
        // Files picked in an open panel need this in the sandbox.
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let deviceName = model?.device(deviceID)?.model.shortName ?? "device"
        let storedName = backend.storedImageName(for: name)

        var problem = backend.uploadProblem(for: name)
        if problem == nil, msd?.images.contains(where: { $0.name.lowercased() == storedName.lowercased() }) == true {
            problem = "The \(deviceName) already has an image named \(name). Delete it first, or rename the file."
        } else if problem == nil, let free = msd?.freeBytes, size > free {
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
        uploadTask = Task { [weak self] in
            do {
                try await backend.uploadImage(fileURL: fileURL, as: name, progress: report)
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self?.mediaError = "Uploading \(name) failed: \(error.localizedDescription)"
                }
                await backend.cleanUpFailedUpload(storedName: storedName)
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

    // MARK: Download from a URL

    /// Asks the device to download an image from `url`. Progress is in `download`.
    func startDownload(url: URL) async throws {
        guard let downloader, download?.inProgress != true else { return }
        let name = url.lastPathComponent
        if !NanoKVMClient.isImageName(name) {
            throw KVMDError.api("The address must end in an .iso or .img file name, such as …/ubuntu-24.04-desktop-amd64.iso.")
        }
        if msd?.images.contains(where: { ($0.name as NSString).lastPathComponent.lowercased() == name.lowercased() }) == true {
            throw KVMDError.api("The device already has an image named \(name). Delete it first.")
        }
        try await downloader.startDownload(url: url)
        download = try? await downloader.downloadStatus()
        watchDownload()
    }

    func cancelDownload() async throws {
        guard let downloader else { return }
        try await downloader.cancelDownload()
        download = try? await downloader.downloadStatus()
    }

    /// Follows the device's download until it finishes, then refreshes the list.
    private func watchDownload() {
        downloadWatch?.cancel()
        downloadWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, let downloader = self.downloader else { return }
                guard let status = try? await downloader.downloadStatus() else { continue }
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
