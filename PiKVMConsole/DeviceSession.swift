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

    private weak var model: AppModel?
    private var connection: Connection?
    private var eventTask: Task<Void, Never>?

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
