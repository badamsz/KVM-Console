import Foundation

/// kvmd wraps every response as `{"ok": true, "result": ...}`.
struct KVMDEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T
}

struct KVMDErrorResult: Decodable {
    let error: String?
    let error_msg: String?
}

// MARK: /api/info

/// A subset of `/api/info`. Every field is optional because the response
/// differs between kvmd versions and hardware.
public struct DeviceInfo: Decodable, Sendable, Hashable {
    public struct HW: Decodable, Sendable, Hashable {
        public struct Platform: Decodable, Sendable, Hashable {
            public let type: String?
            public let base: String?
            public let model: String?
            public let serial: String?
        }
        public let platform: Platform?
    }
    public struct System: Decodable, Sendable, Hashable {
        public struct KVMD: Decodable, Sendable, Hashable { public let version: String? }
        public struct Streamer: Decodable, Sendable, Hashable { public let app: String?; public let version: String? }
        public let kvmd: KVMD?
        public let streamer: Streamer?
    }
    public struct Meta: Decodable, Sendable, Hashable {
        public struct Server: Decodable, Sendable, Hashable { public let host: String? }
        public let server: Server?
    }
    public let hw: HW?
    public let system: System?
    public let meta: Meta?

    public var kvmdVersion: String? { system?.kvmd?.version }
    public var hostname: String? { meta?.server?.host }
    public var platformModel: String? { hw?.platform?.model }
}

// MARK: /api/atx

public struct ATXState: Decodable, Sendable, Hashable {
    public struct LEDs: Decodable, Sendable, Hashable {
        public let power: Bool
        public let hdd: Bool
    }
    public let enabled: Bool
    public let busy: Bool
    public let leds: LEDs
}

public enum ATXPowerAction: String, Sendable, CaseIterable {
    case on, off
    case offHard = "off_hard"
    case resetHard = "reset_hard"
}

public enum ATXButton: String, Sendable, CaseIterable {
    case power
    case powerLong = "power_long"
    case reset
}

// MARK: /api/hid

/// Note: relative mode on a V3/V4 needs kvmd's alternate mouse enabled
/// (`otg.devices.mouse_alt` or the mouse set to `usb_rel`), otherwise
/// `usb_rel` is missing from `outputs.available`.
public struct HIDState: Decodable, Sendable, Hashable {
    public struct Mouse: Decodable, Sendable, Hashable {
        public struct Outputs: Decodable, Sendable, Hashable {
            public let available: [String]
            public let active: String
        }
        public let absolute: Bool?
        public let online: Bool?
        public let outputs: Outputs?
    }
    public let online: Bool?
    public let mouse: Mouse?

    public var activeMouseMode: MouseMode? {
        if let active = mouse?.outputs?.active, let mode = MouseMode(kvmdMouseOutput: active) { return mode }
        if let absolute = mouse?.absolute { return absolute ? .absolute : .relative }
        return nil
    }

    public var supportedMouseModes: [MouseMode] {
        guard let available = mouse?.outputs?.available, !available.isEmpty else { return MouseMode.allCases }
        return MouseMode.allCases.filter { available.contains($0.kvmdMouseOutput) }
    }
}

// MARK: /api/switch

/// One port across a PiKVM Switch chain (4 ports per unit; a chained second
/// unit adds ports 4-7). Mirrors `model.ports[]` in kvmd's
/// `kvmd/apps/kvmd/switch/state.py`.
public struct SwitchPortInfo: Sendable, Hashable {
    /// Zero-based virtual port, as used by `/api/switch/set_active?port=`.
    public let index: Int
    public let unit: Int?
    public let channel: Int?
    public let name: String?
    /// kvmd's display id: "1".."4" with one unit, "1.1".."2.4" with a chain.
    public let displayID: String?

    public init(index: Int, unit: Int? = nil, channel: Int? = nil, name: String? = nil, displayID: String? = nil) {
        self.index = index
        self.unit = unit
        self.channel = channel
        self.name = name
        self.displayID = displayID
    }
}

public struct SwitchState: Sendable, Hashable {
    public let ports: [SwitchPortInfo]
    public let activePort: Int?
    /// Per-port ATX LEDs, when the switch reports them.
    public let powerLEDs: [Bool]?
    public let hddLEDs: [Bool]?
    public let atxBusy: [Bool]?
}

extension SwitchState: Decodable {
    private struct Raw: Decodable {
        struct Model: Decodable {
            struct Port: Decodable {
                let unit: Int?
                let channel: Int?
                let name: String?
                let id: String?
            }
            let ports: [Port]?
        }
        struct Summary: Decodable { let active_port: Int? }
        struct ATX: Decodable {
            struct LEDs: Decodable { let power: [Bool]?; let hdd: [Bool]? }
            let leds: LEDs?
            let busy: [Bool]?
        }
        let model: Model?
        let summary: Summary?
        let atx: ATX?
    }

    public init(from decoder: Decoder) throws {
        let raw = try Raw(from: decoder)
        ports = (raw.model?.ports ?? []).enumerated().map { i, p in
            SwitchPortInfo(index: i, unit: p.unit, channel: p.channel, name: p.name, displayID: p.id)
        }
        activePort = raw.summary?.active_port.flatMap { $0 >= 0 ? $0 : nil }
        powerLEDs = raw.atx?.leds?.power
        hddLEDs = raw.atx?.leds?.hdd
        atxBusy = raw.atx?.busy
    }
}

// MARK: /api/ws

/// One message from the kvmd event websocket.
public struct KVMDEvent: Decodable, Sendable, Hashable {
    public let eventType: String
    public let event: JSONValue

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

extension KVMDEvent {
    /// For a `streamer` event: whether the video source has a signal.
    /// Returns nil for other events, or when the event doesn't say
    /// (kvmd sends partial updates, and `streamer` is null while it starts).
    public var streamerSourceOnline: Bool? {
        guard eventType == "streamer",
              case .bool(let online)? = event["streamer"]?["source"]?["online"] else { return nil }
        return online
    }
}
