import Foundation
import Network

/// Recognises a KVM from what its web server says to a visitor who is not
/// logged in. Nothing here sends credentials.
///
/// * kvmd (PiKVM) answers `/api/auth/check` with its JSON envelope
///   `{"ok": false, "result": {"error": "UnauthorizedError", …}}`, and its
///   login page is titled "PiKVM Login".
/// * NanoKVM (classic, Pro and Go) answers `/api/vm/info` with 401 and the
///   bare JSON string `"unauthorized"`, and its page is titled "NanoKVM".
public enum Fingerprint {
    /// The requests to try against one base URL, most specific first.
    public static let probePaths = ["/api/auth/check", "/api/vm/info", "/"]

    /// Classifies one HTTP response. `overTLS` tells a NanoKVM Pro (HTTPS by
    /// default) from a classic NanoKVM (HTTP by default); it is only a guess.
    public static func classify(status: Int, body: Data, overTLS: Bool) -> DiscoveredKind? {
        let text = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            if let object = json as? [String: Any], object["ok"] is Bool, object["result"] != nil {
                return .pikvm(model: nil)
            }
            if status == 401, let string = json as? String, string.lowercased() == "unauthorized" {
                return .nanoKVM(pro: overTLS)
            }
        }
        if let title = htmlTitle(text)?.lowercased() {
            if title.contains("pikvm") { return .pikvm(model: nil) }
            if title.contains("nanokvm") { return .nanoKVM(pro: overTLS) }
        }
        return nil
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex)
        else { return nil }
        return html[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Probes hosts over HTTP(S) to see whether a KVM is there.
public final class FingerprintProber: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: AnyCertificateDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The result of probing one host.
    public struct Match: Sendable, Equatable {
        public var kind: DiscoveredKind
        /// The address to store, e.g. `192.168.1.40` (HTTPS on 443) or
        /// `http://192.168.1.41` (plain HTTP).
        public var endpointHost: String
    }

    /// Tries HTTPS, then HTTP, against the given ports of `host`. Ports 443 and
    /// 80 are the defaults; any other port is tried with both schemes.
    public func probe(host: String, ports: [Int] = [443, 80]) async -> Match? {
        for (scheme, port) in Self.attempts(for: ports) {
            let base = Self.baseString(scheme: scheme, host: host, port: port)
            for path in Fingerprint.probePaths {
                guard !Task.isCancelled else { return nil }
                guard let url = URL(string: base + path) else { continue }
                var request = URLRequest(url: url)
                request.setValue("application/json, text/html;q=0.9", forHTTPHeaderField: "Accept")
                guard let (data, response) = try? await session.data(for: request),
                      let http = response as? HTTPURLResponse else {
                    break // Nothing listening on this scheme/port; skip its other paths.
                }
                // A plain-HTTP kvmd redirects to HTTPS: store the HTTPS form.
                let finalTLS = http.url?.scheme == "https"
                if let kind = Fingerprint.classify(status: http.statusCode, body: data, overTLS: finalTLS) {
                    let storedBase: String
                    if finalTLS, scheme == "http" {
                        storedBase = Self.baseString(scheme: "https", host: host, port: http.url?.port ?? 443)
                    } else {
                        storedBase = base
                    }
                    return Match(kind: kind, endpointHost: Self.endpointHost(fromBase: storedBase))
                }
            }
        }
        return nil
    }

    static func attempts(for ports: [Int]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        if ports.contains(443) { out.append(("https", 443)) }
        if ports.contains(80) { out.append(("http", 80)) }
        for p in ports where p != 443 && p != 80 {
            out.append(("https", p))
            out.append(("http", p))
        }
        return out
    }

    static func baseString(scheme: String, host: String, port: Int) -> String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(h)" + (isDefault ? "" : ":\(port)")
    }

    /// `https://h` -> `h`; `https://h:8443` -> `h:8443`; `http://…` is kept
    /// whole because endpoints default to HTTPS.
    static func endpointHost(fromBase base: String) -> String {
        base.hasPrefix("https://") ? String(base.dropFirst("https://".count)) : base
    }

}

/// Discovery only reads unauthenticated pages, so any certificate will do.
/// KVMs ship with self-signed ones; the real connection pins it later.
private final class AnyCertificateDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Fast check for an open TCP port, used before the slower HTTP probe.
public enum PortCheck {
    public static func isOpen(host: String, port: Int, timeout: TimeInterval = 0.8) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let once = Once()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let finish: @Sendable (Bool) -> Void = { open in
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: open)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    case .waiting: finish(false) // e.g. connection refused
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// A flag that can be claimed exactly once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
