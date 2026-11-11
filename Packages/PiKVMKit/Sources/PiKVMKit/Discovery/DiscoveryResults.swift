import Darwin
import Foundation

/// The merged list of found devices. The same KVM is often seen several
/// ways (Bonjour, a subnet scan, Tailscale); sightings are folded together
/// so it is listed, and added, once.
public struct DiscoveryResults: Sendable, Equatable {
    public private(set) var devices: [DiscoveredDevice] = []

    public init() {}

    public mutating func add(_ found: DiscoveredDevice) {
        if let i = indexOfSameDevice(as: found) {
            devices[i].merge(found)
        } else {
            devices.append(found)
        }
        devices.sort { a, b in
            if a.kind.isPiKVM != b.kind.isPiKVM { return a.kind.isPiKVM }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public mutating func removeAll() { devices.removeAll() }

    private func indexOfSameDevice(as found: DiscoveredDevice) -> Int? {
        if let i = devices.firstIndex(where: { $0.id == found.id }) { return i }
        if let lan = found.lanHost.map(Self.normalize),
           let i = devices.firstIndex(where: { $0.lanHost.map(Self.normalize) == lan }) { return i }
        if let ts = found.tailscaleHost.map(Self.normalize),
           let i = devices.firstIndex(where: { $0.tailscaleHost.map(Self.normalize) == ts }) { return i }
        // A Tailscale peer and a LAN find with the same host name are probably
        // one machine, but only when the name is unambiguous: several PiKVMs
        // still called "pikvm" must stay separate.
        guard let name = found.matchName else { return nil }
        let foundIsTailscaleOnly = found.lanHost == nil && found.tailscaleHost != nil
        let foundIsLANOnly = found.lanHost != nil && found.tailscaleHost == nil
        guard foundIsTailscaleOnly || foundIsLANOnly else { return nil }
        let candidates = devices.indices.filter { i in
            let d = devices[i]
            guard d.matchName == name, d.kind.isPiKVM == found.kind.isPiKVM else { return false }
            return foundIsTailscaleOnly ? (d.tailscaleHost == nil && d.lanHost != nil)
                                        : (d.lanHost == nil && d.tailscaleHost != nil)
        }
        let sameNameAnywhere = devices.filter { $0.matchName == name }.count
        return candidates.count == 1 && sameNameAnywhere == 1 ? candidates[0] : nil
    }

    /// Lower-cased host without scheme or trailing dot, for comparisons.
    public static func normalize(_ host: String) -> String {
        var s = host.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        while s.hasSuffix("/") || s.hasSuffix(".") { s.removeLast() }
        if s.hasSuffix(":443") { s.removeLast(4) }
        return s
    }

    /// Whether `device` is already in the user's list, by any address.
    public static func isAlreadyAdded(_ found: DiscoveredDevice, in existing: [Device]) -> Bool {
        let known = Set(existing.flatMap { $0.endpoints.map { normalize($0.host) } })
        return found.hosts.contains { known.contains(normalize($0)) }
    }
}

public enum ReverseDNS {
    /// The host name for an IPv4 address (on a LAN, usually its `.local`
    /// name via multicast DNS), or nil. Blocks for up to a few seconds; call
    /// from a background task.
    public static func name(for ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty || name == ip ? nil : name
    }
}
