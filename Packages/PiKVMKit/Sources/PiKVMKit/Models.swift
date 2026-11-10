import Foundation

/// The PiKVM hardware model. Used for display and for feature hints only;
/// the authoritative capabilities come from `/api/info` and friends.
public enum PiKVMModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case v3
    case v3Lite
    case v4Mini
    case v4Plus
    case plus
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .v3: return "PiKVM V3"
        case .v3Lite: return "PiKVM V3 Lite"
        case .v4Mini: return "PiKVM V4 Mini"
        case .v4Plus: return "PiKVM V4 Plus"
        case .plus: return "PiKVM Plus"
        case .other: return "Other / DIY"
        }
    }
}

/// How the app should send mouse input to a target.
public enum MouseMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Absolute positioning (USB tablet). The cursor maps 1:1 onto the video.
    case absolute
    /// Relative movement (USB mouse). Needed by some BIOSes and OSes; the app
    /// captures the Mac cursor while the console has focus.
    case relative

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .absolute: return "Absolute"
        case .relative: return "Relative"
        }
    }

    /// The kvmd `mouse_output` value for this mode.
    public var kvmdMouseOutput: String {
        switch self {
        case .absolute: return "usb"
        case .relative: return "usb_rel"
        }
    }

    public init?(kvmdMouseOutput: String) {
        switch kvmdMouseOutput {
        case "usb": self = .absolute
        case "usb_rel": self = .relative
        default: return nil
        }
    }
}

/// One way of reaching a PiKVM, e.g. its LAN address or its Tailscale name.
/// Endpoints are tried in order until one answers.
public struct Endpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// A short label such as "LAN" or "Tailscale".
    public var label: String
    /// Host name or IP, optionally with `:port` (e.g. `pikvm.local`, `100.64.0.3`, `kvm.tailnet.ts.net`).
    public var host: String

    public init(id: UUID = UUID(), label: String, host: String) {
        self.id = id
        self.label = label
        self.host = host
    }

    public var baseURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://\(trimmed)")
    }
}

/// A machine controlled through a PiKVM. A PiKVM without a Switch has a single
/// target; with a PiKVM Switch (and chained expansion units) there is one
/// target per switch port. Settings such as mouse mode are stored per target.
public struct Target: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Zero-based kvmd switch port index, or `nil` when there is no switch.
    public var switchPort: Int?
    public var mouseMode: MouseMode

    public init(id: UUID = UUID(), name: String, switchPort: Int? = nil, mouseMode: MouseMode = .absolute) {
        self.id = id
        self.name = name
        self.switchPort = switchPort
        self.mouseMode = mouseMode
    }
}

/// A configured PiKVM. The password is not stored here; see `CredentialStore`.
public struct Device: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var model: PiKVMModel
    public var endpoints: [Endpoint]
    public var username: String
    public var targets: [Target]
    /// SHA-256 fingerprint (hex) of the device's TLS certificate, pinned on
    /// first successful connection. PiKVMs ship with self-signed certificates.
    public var pinnedCertificateSHA256: String?

    public init(
        id: UUID = UUID(),
        name: String,
        model: PiKVMModel = .v3,
        endpoints: [Endpoint] = [],
        username: String = "admin",
        targets: [Target]? = nil,
        pinnedCertificateSHA256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.endpoints = endpoints
        self.username = username
        self.targets = targets ?? [Target(name: name)]
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }

    public var hasSwitch: Bool { targets.contains { $0.switchPort != nil } }

    /// Reconciles the target list with the switch ports reported by kvmd,
    /// keeping existing per-port settings (name, mouse mode) where the port
    /// already exists. Passing an empty list reverts to a single target.
    public mutating func syncTargets(withSwitchPorts ports: [SwitchPortInfo]) {
        guard !ports.isEmpty else {
            if hasSwitch || targets.isEmpty {
                let mode = targets.first?.mouseMode ?? .absolute
                targets = [Target(name: name, mouseMode: mode)]
            }
            return
        }
        let existing = Dictionary(
            targets.compactMap { t in t.switchPort.map { ($0, t) } },
            uniquingKeysWith: { first, _ in first }
        )
        targets = ports.map { port in
            if var t = existing[port.index] {
                if let reported = port.name, !reported.isEmpty, t.name == Target.defaultName(for: port.index) {
                    t.name = reported
                }
                return t
            }
            let name = (port.name?.isEmpty == false) ? port.name! : Target.defaultName(for: port.index)
            return Target(name: name, switchPort: port.index)
        }
    }
}

extension Target {
    public static func defaultName(for port: Int) -> String { "Port \(port + 1)" }
}
