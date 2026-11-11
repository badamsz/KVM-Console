import Foundation

/// The kind of software a device runs, which decides the API the app speaks.
public enum DeviceFamily: String, Codable, CaseIterable, Sendable {
    /// PiKVM OS (kvmd). See https://docs.pikvm.org/api/
    case pikvm
    /// Sipeed NanoKVM (Cube, Lite, PCIe): the NanoKVM server, HTTP by default.
    case nanoKVM
    /// Sipeed NanoKVM Pro and NanoKVM Go: the NanoKVM Pro server, HTTPS by default.
    case nanoKVMPro
    /// Openterface: a USB KVM plugged into this Mac. Video and audio arrive as
    /// a USB camera and microphone; keyboard and mouse go out over USB serial.
    case openterface

    public var isSipeed: Bool { self == .nanoKVM || self == .nanoKVMPro }

    /// Plugged into this Mac rather than reached over the network.
    public var isLocal: Bool { self == .openterface }
}

/// The device's hardware model. It picks the API (`family`) and is used for
/// display and feature hints; the authoritative capabilities come from the
/// device itself.
public enum PiKVMModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case v3
    case v4Mini
    case v4Plus
    case other
    /// Sipeed NanoKVM Cube, Lite or PCIe.
    case nanoKVM
    /// Sipeed NanoKVM Pro (Desk or ATX).
    case nanoKVMPro
    /// Sipeed NanoKVM Go.
    case nanoKVMGo
    /// Openterface Mini-KVM or KVM-Go, plugged into this Mac by USB.
    case openterface

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .v3: return "PiKVM V3"
        case .v4Mini: return "PiKVM V4 Mini"
        case .v4Plus: return "PiKVM V4 Plus"
        case .other: return "Other PiKVM / DIY"
        case .nanoKVM: return "Sipeed NanoKVM"
        case .nanoKVMPro: return "Sipeed NanoKVM Pro"
        case .nanoKVMGo: return "Sipeed NanoKVM Go"
        case .openterface: return "Openterface (USB)"
        }
    }

    public var family: DeviceFamily {
        switch self {
        case .v3, .v4Mini, .v4Plus, .other: return .pikvm
        case .nanoKVM: return .nanoKVM
        case .nanoKVMPro, .nanoKVMGo: return .nanoKVMPro
        case .openterface: return .openterface
        }
    }

    /// What the device calls itself in messages ("the PiKVM", "the NanoKVM").
    public var shortName: String {
        switch family {
        case .pikvm: return "PiKVM"
        case .nanoKVM: return "NanoKVM"
        case .nanoKVMPro: return self == .nanoKVMGo ? "NanoKVM Go" : "NanoKVM Pro"
        case .openterface: return "Openterface"
        }
    }

    /// Unknown values (including ones written by early builds) decode
    /// instead of failing the whole device list.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "v3Lite": self = .v4Mini
        case "plus": self = .v4Plus
        default: self = PiKVMModel(rawValue: raw) ?? .other
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

    /// Whether the address names its own scheme (`http://...` or `https://...`).
    public var hasExplicitScheme: Bool { host.contains("://") }

    /// The address over plain HTTP, for devices that don't use TLS by default
    /// (a NanoKVM ships with HTTPS off). Nil when the address names a scheme.
    public var plainHTTPURL: URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasExplicitScheme else { return nil }
        return URL(string: "http://\(trimmed)")
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
    /// Renaming a device without a Switch renames its one machine too, since
    /// the sidebar and console show the machine's name.
    public var name: String {
        didSet { syncSingleTargetName() }
    }
    public var model: PiKVMModel
    public var endpoints: [Endpoint]
    public var username: String
    public var targets: [Target]
    /// SHA-256 fingerprint (hex) of the device's TLS certificate, pinned on
    /// first successful connection. PiKVMs ship with self-signed certificates.
    public var pinnedCertificateSHA256: String?
    /// How the certificate is checked. Nil until the first successful
    /// connection decides it.
    public var certificateTrust: CertificateTrust?
    /// For a device plugged into this Mac (Openterface): which one, by the
    /// unique ID of its video capture device. Nil uses the first one found.
    public var localDeviceID: String?
    /// For a device plugged into this Mac: its USB serial number, when it
    /// reports one, so it is recognised in any USB port.
    public var localSerialNumber: String?

    public init(
        id: UUID = UUID(),
        name: String,
        model: PiKVMModel = .v3,
        endpoints: [Endpoint] = [],
        username: String = "admin",
        targets: [Target]? = nil,
        pinnedCertificateSHA256: String? = nil,
        certificateTrust: CertificateTrust? = nil,
        localDeviceID: String? = nil,
        localSerialNumber: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.endpoints = endpoints
        self.username = username
        self.targets = targets ?? [Target(name: name)]
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.certificateTrust = certificateTrust
        self.localDeviceID = localDeviceID
        self.localSerialNumber = localSerialNumber
    }

    /// Records what the first successful connection saw: a CA-issued
    /// certificate switches the device to CA trust (and drops any pin, so
    /// renewals keep working); a self-signed one is pinned.
    public mutating func learnCertificate(sha256: String?, trustedByCA: Bool?) {
        if trustedByCA == true {
            certificateTrust = .certificateAuthority
            pinnedCertificateSHA256 = nil
        } else if certificateTrust == nil, pinnedCertificateSHA256 == nil, let sha256 {
            certificateTrust = .pinned
            pinnedCertificateSHA256 = sha256
        }
    }

    /// Forgets what is known about the certificate, for example after the
    /// addresses change.
    public mutating func resetCertificateTrust() {
        pinnedCertificateSHA256 = nil
        certificateTrust = nil
    }

    public var hasSwitch: Bool { targets.contains { $0.switchPort != nil } }

    /// Gives the single machine of a device without a Switch the device's name.
    public mutating func syncSingleTargetName() {
        guard !hasSwitch, targets.count == 1, targets[0].name != name else { return }
        targets[0].name = name
    }

    public var family: DeviceFamily { model.family }

    /// Reconciles the target list with the switch ports reported by kvmd,
    /// keeping existing per-port settings (name, mouse mode) where the port
    /// already exists. Passing an empty list reverts to a single target.
    public mutating func syncTargets(withSwitchPorts ports: [SwitchPortInfo]) {
        guard !ports.isEmpty else {
            if hasSwitch || targets.isEmpty {
                let mode = targets.first?.mouseMode ?? .absolute
                targets = [Target(name: name, mouseMode: mode)]
            }
            syncSingleTargetName()
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
