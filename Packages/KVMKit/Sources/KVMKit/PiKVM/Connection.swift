import Foundation

/// A working connection to a device through one of its endpoints.
public struct Connection: Sendable {
    public let device: Device
    public let endpoint: Endpoint
    public let client: KVMDClient

    /// The certificate fingerprint seen on this connection.
    public var observedCertificateSHA256: String? { client.trustDelegate.observedSHA256 }
    /// Whether that certificate was trusted through a certificate authority.
    public var observedTrustedByCA: Bool? { client.trustDelegate.observedTrustedByCA }
}

public enum ConnectionResolver {
    /// Tries each endpoint in order (e.g. LAN first, then Tailscale) and
    /// returns the first that authenticates. Bad credentials fail fast rather
    /// than falling through to the next endpoint.
    public static func connect(to device: Device, password: String, probeTimeout: TimeInterval = 4) async throws -> Connection {
        var tried: [String] = []
        var rejection: String?
        for endpoint in device.endpoints {
            guard let url = endpoint.baseURL else { continue }
            tried.append("\(endpoint.label) (\(endpoint.host))")
            let policy = TrustPolicy(device: device)
            let probe = KVMDClient(baseURL: url, username: device.username, password: password,
                                   trust: policy, timeout: probeTimeout)
            do {
                try await probe.checkAuth()
            } catch KVMDError.unauthorized {
                throw KVMDError.unauthorized
            } catch {
                if let reason = probe.trustDelegate.rejection { rejection = reason }
                continue
            }
            let client = KVMDClient(baseURL: url, username: device.username, password: password,
                                    trust: probe.effectiveTrustPolicy)
            return Connection(device: device, endpoint: endpoint, client: client)
        }
        // A refused certificate explains the failure better than "couldn't reach".
        if let rejection { throw KVMDError.certificateRejected(rejection) }
        throw KVMDError.noReachableEndpoint(tried)
    }
}
