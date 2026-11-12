import Foundation

/// What kind of KVM answered a discovery probe.
public enum DiscoveredKind: Hashable, Sendable {
    /// A PiKVM running kvmd. The model is known when the device advertised it
    /// over Bonjour (`_pikvm._tcp` TXT record); a subnet scan can't tell.
    case pikvm(model: DeviceModel?)
    /// A Sipeed NanoKVM. `pro` is a guess before login: the classic NanoKVM
    /// serves plain HTTP by default and the Pro (and Go) serve HTTPS. Nil when
    /// there was nothing to guess from.
    case nanoKVM(pro: Bool?)

    public var displayName: String {
        switch self {
        case .pikvm(let model): return model?.displayName ?? "PiKVM"
        case .nanoKVM(let pro):
            switch pro {
            case true?: return "NanoKVM Pro"
            case false?: return "NanoKVM"
            case nil: return "NanoKVM"
            }
        }
    }

    public var isPiKVM: Bool { if case .pikvm = self { return true } else { return false } }

    /// The model to prefill when the user adds this device.
    public var suggestedModel: DeviceModel {
        switch self {
        case .pikvm(let model): return model ?? .other
        case .nanoKVM(let pro): return pro == true ? .nanoKVMPro : .nanoKVM
        }
    }
}

/// How a device was found. A device found more than one way lists them all.
public enum DiscoverySource: String, Hashable, Sendable, CaseIterable, Comparable {
    case bonjour
    case subnetScan
    case tailscale

    public var displayName: String {
        switch self {
        case .bonjour: return "Bonjour"
        case .subnetScan: return "Network scan"
        case .tailscale: return "Tailscale"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A KVM found on the network that the user can add in one click.
public struct DiscoveredDevice: Hashable, Identifiable, Sendable {
    /// Stable identity for merging results: the device's serial number when it
    /// advertised one, otherwise its primary address.
    public var id: String
    public var kind: DiscoveredKind
    /// A friendly name: the Bonjour instance or host name, or the address.
    public var name: String
    /// LAN address as it should be stored in an `Endpoint` (host, or
    /// `scheme://host:port` when the default `https://host` would not work).
    public var lanHost: String?
    /// Tailscale address (MagicDNS name preferred) for the same device.
    public var tailscaleHost: String?
    public var sources: Set<DiscoverySource>
    /// Extra facts worth showing, e.g. "platform": "v4plus-hdmi-rpi4", "serial": "…".
    public var details: [String: String]

    public init(
        id: String,
        kind: DiscoveredKind,
        name: String,
        lanHost: String? = nil,
        tailscaleHost: String? = nil,
        sources: Set<DiscoverySource>,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.lanHost = lanHost
        self.tailscaleHost = tailscaleHost
        self.sources = sources
        self.details = details
    }

    /// All addresses this device is known by, for "already added" checks.
    public var hosts: [String] { [lanHost, tailscaleHost].compactMap { $0 } }

    /// A short, host-only name used to match the same machine across sources
    /// (e.g. `pikvm.local`, `pikvm.tail1234.ts.net` and `pikvm` all give `pikvm`).
    public var matchName: String? { Self.matchName(for: name) }

    static func matchName(for raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if s.isEmpty || IPv4(string: s) != nil { return nil }
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        return s.isEmpty ? nil : s
    }

    /// Folds another sighting of the same device into this one. Specific facts
    /// (a known model, a LAN address) win over vague ones.
    public mutating func merge(_ other: DiscoveredDevice) {
        sources.formUnion(other.sources)
        if lanHost == nil { lanHost = other.lanHost }
        if tailscaleHost == nil { tailscaleHost = other.tailscaleHost }
        details.merge(other.details) { mine, _ in mine }
        switch (kind, other.kind) {
        case (.pikvm(nil), .pikvm(let m?)): kind = .pikvm(model: m)
        case (.nanoKVM(nil), .nanoKVM(let p?)): kind = .nanoKVM(pro: p)
        default: break
        }
        // Prefer a real name over a bare IP address.
        if IPv4(string: name) != nil, IPv4(string: other.name) == nil { name = other.name }
    }

    /// Prefills a new device for the editor.
    /// NanoKVM addresses are stored bare: the NanoKVM client tries HTTPS and
    /// falls back to plain HTTP, so turning HTTPS on later keeps working.
    public func makeDevice() -> Device {
        let stored: (String) -> String = { host in
            guard case .nanoKVM = kind, host.lowercased().hasPrefix("http://") else { return host }
            return String(host.dropFirst("http://".count))
        }
        var endpoints: [Endpoint] = []
        if let lanHost { endpoints.append(Endpoint(label: "LAN", host: stored(lanHost))) }
        if let tailscaleHost { endpoints.append(Endpoint(label: "Tailscale", host: stored(tailscaleHost))) }
        return Device(name: Self.prettyName(name), model: kind.suggestedModel, endpoints: endpoints, username: "admin")
    }

    /// `pikvm-01234.local` -> `pikvm-01234`; IPs are left alone.
    static func prettyName(_ raw: String) -> String {
        if IPv4(string: raw) != nil { return raw }
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        for suffix in [".local", ".ts.net"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        if let dot = s.firstIndex(of: "."), raw.lowercased().contains(".ts.net") { s = String(s[..<dot]) }
        return s
    }
}
