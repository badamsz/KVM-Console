import AVFoundation
import Foundation
import Observation
import SwiftUI
import KVMKit

struct TargetSelection: Hashable, Codable {
    let deviceID: UUID
    let targetID: UUID
}

enum EditorRequest: Identifiable {
    case new
    case edit(UUID)
    /// A new device prefilled from network discovery.
    case discovered(Device)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let id): return id.uuidString
        case .discovered(let device): return "discovered-" + device.id.uuidString
        }
    }
}

/// App-wide state: the device list, credentials and one live session per device.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [Device] = []
    var selection: TargetSelection?
    var editorRequest: EditorRequest?
    /// The Find Devices sheet (network discovery).
    var showingDiscovery = false
    var updateRequest: UpdateRequest?
    var configRequest: ConfigRequest?
    var lastError: String?
    /// The console whose window is in front, for the Console menu. Not observed:
    /// the menu reads it when a command runs, so console updates never rebuild the menu.
    @ObservationIgnored weak var frontConsole: ConsoleModel?
    /// Not observed: `session(for:)` adds to it while views are being built, and
    /// each session is observable on its own.
    @ObservationIgnored private(set) var sessions: [UUID: DeviceSession] = [:]
    /// The menu bar item. Created once, by the first main window.
    @ObservationIgnored private(set) var statusItem: StatusItemController?
    /// The USB KVMs plugged in now, by the saved device each one is.
    private(set) var pluggedUnits: [UUID: OpenterfaceUnit] = [:]
    /// Units removed from the list while plugged in. They aren't added back
    /// until they are unplugged.
    @ObservationIgnored private var dismissedUnits: Set<String> = []
    @ObservationIgnored private var usbWatch: Task<Void, Never>?

    private let store: DeviceStore
    let credentials: CredentialStore

    init(store: DeviceStore = DeviceStore(fileURL: DeviceStore.defaultURL), credentials: CredentialStore = CredentialStore()) {
        self.store = store
        self.credentials = credentials
        do {
            devices = try store.load()
        } catch { lastError = "Couldn't load devices: \(error.localizedDescription)" }
        refreshUSB()
        watchUSB()
    }

    /// The devices the sidebar lists: USB KVMs only while plugged in, unless
    /// the setting to show unplugged ones is on.
    func visibleDevices(showUnplugged: Bool = UserDefaults.standard.bool(forKey: AppPreferences.showUnpluggedUSBKey)) -> [Device] {
        devices.filter { !$0.family.isLocal || showUnplugged || pluggedUnits[$0.id] != nil }
    }

    // MARK: USB KVMs

    /// Matches the Openterface units plugged in to saved devices, adds new
    /// ones to the list (unless that's turned off), and tells sessions.
    func refreshUSB() {
        let units = OpenterfaceScanner.scan()
        let unitIDs = Set(units.map(\.id))
        dismissedUnits.formIntersection(unitIDs)

        let local = devices.filter { $0.family.isLocal }
        let assignment = LocalUnitMatcher.assign(
            saved: local.map { LocalUnitMatcher.Saved(deviceID: $0.id, unitID: $0.localDeviceID, serialNumber: $0.localSerialNumber) },
            plugged: units.map { LocalUnitMatcher.Plugged(unitID: $0.id, serialNumber: $0.serialNumber) })

        var plugged: [UUID: OpenterfaceUnit] = [:]
        var changed = false
        for (deviceID, index) in assignment {
            let unit = units[index]
            plugged[deviceID] = unit
            // Follow the unit to a new port, and learn its serial number.
            if let i = devices.firstIndex(where: { $0.id == deviceID }),
               devices[i].localDeviceID != unit.id || (unit.serialNumber != nil && devices[i].localSerialNumber != unit.serialNumber) {
                devices[i].localDeviceID = unit.id
                if let serial = unit.serialNumber { devices[i].localSerialNumber = serial }
                changed = true
            }
        }

        let autoAdd = UserDefaults.standard.object(forKey: AppPreferences.autoAddUSBKey) as? Bool ?? true
        let claimed = Set(assignment.values)
        for (index, unit) in units.enumerated() where autoAdd && !claimed.contains(index) && !dismissedUnits.contains(unit.id) {
            let device = Device(name: LocalUnitMatcher.newName(taken: devices.map(\.name)), model: .openterface,
                                endpoints: [], username: "", localDeviceID: unit.id, localSerialNumber: unit.serialNumber)
            devices.append(device)
            plugged[device.id] = unit
            changed = true
        }

        if changed { persist() }
        let before = pluggedUnits
        if plugged != before { pluggedUnits = plugged }

        // Don't leave the sidebar pointing at a unit that was just unplugged.
        if let selected = selection?.deviceID, before[selected] != nil, plugged[selected] == nil,
           !visibleDevices().contains(where: { $0.id == selected }) {
            selection = nil
        }
        for device in devices where device.family.isLocal && before[device.id] != plugged[device.id] {
            sessions[device.id]?.usbChanged()
        }
    }

    /// Re-scans when a camera is plugged in or unplugged. The serial port and
    /// audio appear alongside the camera, so wait a moment for them.
    private func watchUSB() {
        guard usbWatch == nil else { return }
        usbWatch = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                    group.addTask { @MainActor [weak self] in
                        for await _ in NotificationCenter.default.notifications(named: name) {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard let self else { return }
                            self.refreshUSB()
                        }
                    }
                }
            }
        }
    }

    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }

    func installStatusItem(openWindow: OpenWindowAction, visible: Bool) {
        if statusItem == nil {
            statusItem = StatusItemController(app: self, openWindow: openWindow)
        }
        statusItem?.setVisible(visible)
    }

    /// Makes a machine's Switch port the active one. Returns false, and does
    /// nothing, when there is no port to change: a PiKVM without a Switch, or
    /// a port that is already active.
    @discardableResult
    func switchPort(to selection: TargetSelection) -> Bool {
        guard let target = device(selection.deviceID)?.targets.first(where: { $0.id == selection.targetID }),
              target.switchPort != nil else { return false }
        let session = session(for: selection.deviceID)
        guard !session.isOnScreen(target) else { return false }
        Task {
            do { try await session.activate(target) } catch { lastError = error.localizedDescription }
        }
        return true
    }

    func session(for deviceID: UUID) -> DeviceSession {
        if let s = sessions[deviceID] { return s }
        let s = DeviceSession(deviceID: deviceID, model: self)
        sessions[deviceID] = s
        return s
    }

    // MARK: Editing

    func save(_ device: Device, password: String?) {
        // A USB KVM added by hand that is already in the list replaces that entry.
        if device.family.isLocal, let unitID = device.localDeviceID,
           !devices.contains(where: { $0.id == device.id }) {
            devices.removeAll { $0.family.isLocal && $0.localDeviceID == unitID }
        }
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            // Pointed at another unit: its serial number is learned again.
            if updated.localDeviceID != devices[i].localDeviceID { updated.localSerialNumber = nil }
            updated.syncSingleTargetName()
            // Endpoints or kind of device changed: the certificate may legitimately differ.
            if devices[i].endpoints.map(\.host) != device.endpoints.map(\.host) || devices[i].family != device.family {
                updated.resetCertificateTrust()
            }
            devices[i] = updated
        } else {
            var added = device
            added.syncSingleTargetName()
            devices.append(added)
        }
        if let password, !password.isEmpty { credentials.setPassword(password, for: device.id) }
        persist()
        sessions[device.id]?.disconnect()
        sessions[device.id] = nil
        if selection == nil, let t = device.targets.first {
            selection = TargetSelection(deviceID: device.id, targetID: t.id)
        }
        if device.family.isLocal { refreshUSB() }
    }

    func rename(_ deviceID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(deviceID) { $0.name = trimmed }
    }

    func delete(_ deviceID: UUID) {
        // A USB KVM removed while plugged in stays off the list until it's replugged.
        if let unit = pluggedUnits[deviceID] {
            dismissedUnits.insert(unit.id)
            pluggedUnits[deviceID] = nil
        }
        sessions[deviceID]?.disconnect()
        sessions[deviceID] = nil
        devices.removeAll { $0.id == deviceID }
        credentials.deletePassword(for: deviceID)
        credentials.deletePassword(for: deviceID, kind: .root)
        if selection?.deviceID == deviceID { selection = nil }
        persist()
    }

    func update(_ deviceID: UUID, _ change: (inout Device) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        change(&devices[i])
        persist()
    }

    func setMouseMode(_ mode: MouseMode, deviceID: UUID, targetID: UUID) {
        update(deviceID) { d in
            if let i = d.targets.firstIndex(where: { $0.id == targetID }) { d.targets[i].mouseMode = mode }
        }
    }

    private func persist() {
        do { try store.save(devices) } catch { lastError = "Couldn't save devices: \(error.localizedDescription)" }
    }
}
