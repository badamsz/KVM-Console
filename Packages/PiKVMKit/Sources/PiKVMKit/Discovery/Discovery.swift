import Foundation

/// Progress and results from a discovery run.
public enum DiscoveryEvent: Sendable {
    case found(DiscoveredDevice)
    /// Hosts checked so far out of the total, for a subnet scan or Tailscale probe.
    case progress(done: Int, total: Int)
}

/// Finds PiKVMs and NanoKVMs. Each method returns a stream that ends when the
/// work is done (Bonjour never ends on its own) or when the consumer stops
/// iterating, which cancels the work.
public enum Discovery {
    /// Watches Bonjour. `_pikvm._tcp` services are trusted as-is; other web
    /// and SSH hosts are fingerprinted over HTTP(S) first.
    public static func bonjour(prober: FingerprintProber = FingerprintProber()) -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let task = Task {
                var probed = Set<String>()
                await withTaskGroup(of: Void.self) { group in
                    for await service in BonjourBrowser.browse() {
                        if service.type == BonjourBrowser.pikvmType {
                            probed.insert(service.host)
                            continuation.yield(.found(Discovery.device(fromPiKVMService: service)))
                            continue
                        }
                        guard probed.insert(service.host).inserted else { continue }
                        group.addTask {
                            var ports = [443, 80]
                            if service.type != "_ssh._tcp", !ports.contains(service.port) { ports.append(service.port) }
                            guard let match = await prober.probe(host: service.host, ports: ports) else { return }
                            continuation.yield(.found(DiscoveredDevice(
                                id: "lan:\(service.host)", kind: match.kind, name: service.name,
                                lanHost: match.endpointHost, sources: [.bonjour])))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func device(fromPiKVMService s: BonjourService) -> DiscoveredDevice {
        var details: [String: String] = [:]
        for key in ["platform", "serial", "base"] { if let v = s.txt[key], !v.isEmpty { details[key] = v } }
        return DiscoveredDevice(
            id: "lan:\(s.host)",
            kind: .pikvm(model: BonjourBrowser.pikvmModel(fromTXT: s.txt)),
            name: s.name,
            lanHost: s.port == 443 ? s.host : "\(s.host):\(s.port)",
            sources: [.bonjour],
            details: details)
    }

    /// Checks every address in the given subnets for a KVM web server.
    public static func scan(_ subnets: [IPv4Subnet], concurrency: Int = 64,
                            prober: FingerprintProber = FingerprintProber()) -> AsyncStream<DiscoveryEvent> {
        let addresses = Array(Set(subnets.flatMap { $0.scanAddresses() })).sorted()
        return AsyncStream { continuation in
            let task = Task {
                let total = addresses.count
                var done = 0
                continuation.yield(.progress(done: 0, total: total))
                await withTaskGroup(of: DiscoveredDevice?.self) { group in
                    var pending = addresses.makeIterator()
                    for _ in 0..<concurrency {
                        guard let ip = pending.next() else { break }
                        group.addTask { await Discovery.scanOne(ip.description, prober: prober) }
                    }
                    for await result in group {
                        done += 1
                        if let result { continuation.yield(.found(result)) }
                        if done % 8 == 0 || done == total { continuation.yield(.progress(done: done, total: total)) }
                        if Task.isCancelled { group.cancelAll(); break }
                        if let ip = pending.next() {
                            group.addTask { await Discovery.scanOne(ip.description, prober: prober) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func scanOne(_ ip: String, prober: FingerprintProber) async -> DiscoveredDevice? {
        async let https = PortCheck.isOpen(host: ip, port: 443)
        async let http = PortCheck.isOpen(host: ip, port: 80)
        let (httpsOpen, httpOpen) = await (https, http)
        let open = (httpsOpen ? [443] : []) + (httpOpen ? [80] : [])
        guard !open.isEmpty, !Task.isCancelled,
              let match = await prober.probe(host: ip, ports: open) else { return nil }
        let name = await reverseName(ip) ?? ip
        return DiscoveredDevice(id: "lan:\(ip)", kind: match.kind, name: name,
                                lanHost: match.endpointHost, sources: [.subnetScan])
    }

    /// Reverse DNS off the cooperative thread pool, since `getnameinfo` blocks.
    static func reverseName(_ ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ReverseDNS.name(for: ip))
            }
        }
    }

    /// Probes the online Linux machines in the tailnet.
    public static func tailscale(_ peers: [TailscalePeer], concurrency: Int = 16,
                                 prober: FingerprintProber = FingerprintProber()) -> AsyncStream<DiscoveryEvent> {
        let candidates = peers.filter { $0.online && $0.mightBeKVM && $0.preferredHost != nil }
        return AsyncStream { continuation in
            let task = Task {
                var done = 0
                continuation.yield(.progress(done: 0, total: candidates.count))
                await withTaskGroup(of: DiscoveredDevice?.self) { group in
                    var pending = candidates.makeIterator()
                    for _ in 0..<concurrency {
                        guard let peer = pending.next() else { break }
                        group.addTask { await Discovery.probe(peer, prober: prober) }
                    }
                    for await result in group {
                        done += 1
                        if let result { continuation.yield(.found(result)) }
                        continuation.yield(.progress(done: done, total: candidates.count))
                        if Task.isCancelled { group.cancelAll(); break }
                        if let peer = pending.next() {
                            group.addTask { await Discovery.probe(peer, prober: prober) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func probe(_ peer: TailscalePeer, prober: FingerprintProber) async -> DiscoveredDevice? {
        guard let host = peer.preferredHost, let match = await prober.probe(host: host) else { return nil }
        return DiscoveredDevice(
            id: "ts:\(peer.id)", kind: match.kind,
            name: peer.hostname.isEmpty ? host : peer.hostname,
            tailscaleHost: match.endpointHost, sources: [.tailscale],
            details: peer.ipv4.map { ["tailscaleIP": $0] } ?? [:])
    }
}
