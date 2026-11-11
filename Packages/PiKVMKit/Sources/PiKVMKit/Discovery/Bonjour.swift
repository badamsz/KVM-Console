import Foundation
import Network

/// A Bonjour service resolved to an address.
public struct BonjourService: Hashable, Sendable {
    /// The instance name, e.g. `pikvm-0000000012345678.local` or `nanokvm`.
    public var name: String
    /// e.g. `_pikvm._tcp`.
    public var type: String
    public var host: String
    public var port: Int
    public var txt: [String: String]
}

/// Browses Bonjour for KVM web servers.
///
/// PiKVM OS publishes `_pikvm._tcp` (and `_https._tcp`) with TXT records naming
/// the model, once Avahi is turned on. NanoKVMs run Avahi but publish no web
/// service type of their own, so ordinary `_http`/`_https`/`_ssh` hosts are
/// returned too, for the caller to fingerprint.
///
/// Each type must also be listed under `NSBonjourServices` in Info.plist.
public enum BonjourBrowser {
    public static let pikvmType = "_pikvm._tcp"
    public static let serviceTypes = [pikvmType, "_https._tcp", "_http._tcp", "_ssh._tcp"]

    /// Yields each service as it is found and resolved, until the consumer stops.
    public static func browse(types: [String] = serviceTypes) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "PiKVMKit.Bonjour")
            let state = BrowseState()
            var browsers: [NWBrowser] = []
            for type in types {
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
                browser.browseResultsChangedHandler = { _, changes in
                    for change in changes {
                        guard case .added(let result) = change,
                              case .service(let name, _, _, _) = result.endpoint,
                              state.claim(result.endpoint) else { continue }
                        let txt: [String: String]
                        if case .bonjour(let record) = result.metadata { txt = record.dictionary } else { txt = [:] }
                        BonjourBrowser.resolve(result.endpoint, queue: queue) { host, port in
                            continuation.yield(BonjourService(name: name, type: type, host: host, port: port, txt: txt))
                        }
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
            let running = browsers
            continuation.onTermination = { _ in running.forEach { $0.cancel() } }
        }
    }

    /// Connects briefly to learn the service's IPv4 address and port.
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue,
                                found: @escaping @Sendable (String, Int) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let once = Once()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if once.claim(), case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    found(Self.string(host), Int(port.rawValue))
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }

    static func string(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    /// Maps the `model` TXT value kvmd publishes (`v3`, `v4mini`, `v4plus`, …).
    public static func pikvmModel(fromTXT txt: [String: String]) -> PiKVMModel? {
        let raw = (txt["model"] ?? txt["platform"] ?? "").lowercased()
        if raw.hasPrefix("v4plus") { return .v4Plus }
        if raw.hasPrefix("v4mini") { return .v4Mini }
        if raw.hasPrefix("v3") { return .v3 }
        return raw.isEmpty ? nil : .other
    }
}

/// Remembers which Bonjour endpoints have been handled.
private final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<NWEndpoint>()
    func claim(_ endpoint: NWEndpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(endpoint).inserted
    }
}
