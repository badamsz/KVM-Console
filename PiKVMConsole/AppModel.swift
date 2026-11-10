import Foundation
import Observation
import PiKVMKit

struct TargetSelection: Hashable, Codable {
    let deviceID: UUID
    let targetID: UUID
}

enum EditorRequest: Identifiable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let id): return id.uuidString
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
    var lastError: String?
    private(set) var sessions: [UUID: DeviceSession] = [:]

    private let store: DeviceStore
    let credentials: CredentialStore

    init(store: DeviceStore = DeviceStore(fileURL: DeviceStore.defaultURL), credentials: CredentialStore = CredentialStore()) {
        self.store = store
        self.credentials = credentials
        do { devices = try store.load() } catch { lastError = "Couldn't load devices: \(error.localizedDescription)" }
    }

    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }

    func session(for deviceID: UUID) -> DeviceSession {
        if let s = sessions[deviceID] { return s }
        let s = DeviceSession(deviceID: deviceID, model: self)
        sessions[deviceID] = s
        return s
    }

    // MARK: Editing

    func save(_ device: Device, password: String?) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            // Endpoints changed: the certificate may legitimately differ.
            if devices[i].endpoints.map(\.host) != device.endpoints.map(\.host) { updated.pinnedCertificateSHA256 = nil }
            devices[i] = updated
        } else {
            devices.append(device)
        }
        if let password, !password.isEmpty { credentials.setPassword(password, for: device.id) }
        persist()
        sessions[device.id]?.disconnect()
        sessions[device.id] = nil
        if selection == nil, let t = device.targets.first {
            selection = TargetSelection(deviceID: device.id, targetID: t.id)
        }
    }

    func delete(_ deviceID: UUID) {
        sessions[deviceID]?.disconnect()
        sessions[deviceID] = nil
        devices.removeAll { $0.id == deviceID }
        credentials.deletePassword(for: deviceID)
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
