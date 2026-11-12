import Darwin
import Foundation

/// A plain IPv4 address, for subnet arithmetic.
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let octet = UInt8(p) else { return nil }
            v = v << 8 | UInt32(octet)
        }
        value = v
    }

    public var description: String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

    /// 169.254.0.0/16: self-assigned, never a configured KVM.
    public var isLinkLocal: Bool { value & 0xFFFF_0000 == 0xA9FE_0000 }
    /// 100.64.0.0/10: carrier-grade NAT space, which Tailscale uses.
    public var isCGNAT: Bool { value & 0xFFC0_0000 == 0x6440_0000 }
}

/// An IPv4 network attached to this Mac, e.g. `192.168.1.23/24` on `en0`.
public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    public var interface: String
    public var address: IPv4
    public var prefixLength: Int

    /// Networks larger than this are narrowed to the /24 around the Mac's own
    /// address, so a /16 office network doesn't mean probing 65,000 hosts.
    public static let widestScannedPrefix = 24

    public init(interface: String, address: IPv4, prefixLength: Int) {
        self.interface = interface
        self.address = address
        self.prefixLength = max(0, min(32, prefixLength))
    }

    public var description: String { "\(address)/\(prefixLength) (\(interface))" }

    /// The prefix that will actually be scanned.
    public var scannedPrefixLength: Int { max(prefixLength, Self.widestScannedPrefix) }

    /// The range shown to the user, e.g. `192.168.1.0/24`.
    public var scannedRange: String {
        "\(IPv4(address.value & Self.mask(scannedPrefixLength)))/\(scannedPrefixLength)"
    }

    /// Every host address in the scanned range except the network, broadcast
    /// and this Mac's own address.
    public func scanAddresses() -> [IPv4] {
        let prefix = scannedPrefixLength
        guard prefix < 31 else { return [] }
        let mask = Self.mask(prefix)
        let network = address.value & mask
        let broadcast = network | ~mask
        return (network + 1 ..< broadcast).compactMap { $0 == address.value ? nil : IPv4($0) }
    }

    static func mask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    }

    static func prefixLength(ofMask mask: UInt32) -> Int { mask.nonzeroBitCount }

    /// Whether this interface is worth scanning: an ordinary LAN, not
    /// loopback, a VPN tunnel (Tailscale is listed separately), or a
    /// self-assigned address.
    public var isScannable: Bool {
        !address.isLinkLocal && !address.isCGNAT && prefixLength >= 8 && prefixLength < 31
    }

    /// The IPv4 networks on this Mac's active, non-tunnel interfaces.
    public static func local() -> [IPv4Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [IPv4Subnet] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(truncatingIfNeeded: ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let subnet = IPv4Subnet(interface: String(cString: ifa.pointee.ifa_name),
                                    address: IPv4(ip), prefixLength: prefixLength(ofMask: mask))
            if subnet.isScannable, !result.contains(subnet) { result.append(subnet) }
        }
        return result
    }
}
