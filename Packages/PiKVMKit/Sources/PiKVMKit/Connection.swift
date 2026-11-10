import Foundation

/// A working connection to a device through one of its endpoints.
public struct Connection: Sendable {
    public let device: Device
    public let endpoint: Endpoint
    public let client: KVMDClient

    /// The certificate fingerprint seen on this connection; pin it on the
    /// device if `device.pinnedCertificateSHA256` is nil.
    public var observedCertificateSHA256: String? { client.trustDelegate.observedSHA256 }
}

public enum ConnectionResolver {
    /// Tries each endpoint in order (e.g. LAN first, then Tailscale) and
    /// returns the first that authenticates. Bad credentials fail fast rather
    /// than falling through to the next endpoint.
    public static func connect(to device: Device, password: String, probeTimeout: TimeInterval = 4) async throws -> Connection {
        var tried: [String] = []
        for endpoint in device.endpoints {
            guard let url = endpoint.baseURL else { continue }
            tried.append("\(endpoint.label) (\(endpoint.host))")
            let probe = KVMDClient(baseURL: url, username: device.username, password: password,
                                   pinnedSHA256: device.pinnedCertificateSHA256, timeout: probeTimeout)
            do {
                try await probe.checkAuth()
            } catch KVMDError.unauthorized {
                throw KVMDError.unauthorized
            } catch {
                continue
            }
            let client = KVMDClient(baseURL: url, username: device.username, password: password,
                                    pinnedSHA256: device.pinnedCertificateSHA256 ?? probe.trustDelegate.observedSHA256)
            return Connection(device: device, endpoint: endpoint, client: client)
        }
        throw KVMDError.noReachableEndpoint(tried)
    }
}
