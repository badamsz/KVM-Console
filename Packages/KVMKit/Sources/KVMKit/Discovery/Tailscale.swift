import Foundation

/// A machine in the user's tailnet.
public struct TailscalePeer: Hashable, Sendable, Identifiable {
    public var id: String
    /// The MagicDNS name, e.g. `pikvm.tail1234.ts.net`.
    public var dnsName: String
    /// The machine's own host name, e.g. `pikvm`.
    public var hostname: String
    public var addresses: [String]
    public var os: String
    public var online: Bool

    public var ipv4: String? { addresses.first { IPv4(string: $0) != nil } }

    /// The address to store: the MagicDNS name, else the Tailscale IP.
    public var preferredHost: String? { dnsName.isEmpty ? ipv4 : dnsName }

    /// KVMs run Linux; skip phones, Macs and Windows boxes when probing.
    public var mightBeKVM: Bool { os.isEmpty || os.lowercased() == "linux" }
}

/// Lists tailnet machines through the Tailscale API.
///
/// The app is sandboxed, so it can't run the `tailscale` command or reach the
/// local Tailscale daemon. Instead the user creates an API access token in the
/// Tailscale admin console (Settings > Keys) and pastes it in once; it is kept
/// in the Keychain.
public struct TailscaleClient: Sendable {
    /// Keychain slot for the token, used with `CredentialStore`.
    public static let credentialID = UUID(uuidString: "7A11C0DE-5CA1-4E00-8000-000000000001")!

    public var token: String
    public var tailnet: String
    public var baseURL: URL

    public init(token: String, tailnet: String = "-", baseURL: URL = URL(string: "https://api.tailscale.com")!) {
        self.token = token
        self.tailnet = tailnet
        self.baseURL = baseURL
    }

    public enum Failure: LocalizedError {
        case badStatus(Int, String)

        public var errorDescription: String? {
            switch self {
            case .badStatus(401, _), .badStatus(403, _):
                return "Tailscale didn't accept the API token. Check that it hasn't expired, or create a new one in the Tailscale admin console under Settings > Keys."
            case .badStatus(let code, let body):
                return "Tailscale answered with HTTP \(code). \(body.prefix(200))"
            }
        }
    }

    public func peers() async throws -> [TailscalePeer] {
        let url = baseURL.appendingPathComponent("api/v2/tailnet/\(tailnet)/devices")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.badStatus(status, String(decoding: data, as: UTF8.self)) }
        return try Self.decodePeers(data)
    }

    static func decodePeers(_ data: Data) throws -> [TailscalePeer] {
        struct Response: Decodable { var devices: [Dev] }
        struct Dev: Decodable {
            var id: String?
            var nodeId: String?
            var name: String?
            var hostname: String?
            var addresses: [String]?
            var os: String?
            var connectedToControl: Bool?
        }
        return try JSONDecoder().decode(Response.self, from: data).devices.map { d in
            let dns = (d.name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return TailscalePeer(
                id: d.nodeId ?? d.id ?? dns,
                dnsName: dns,
                hostname: d.hostname ?? "",
                addresses: d.addresses ?? [],
                os: d.os ?? "",
                online: d.connectedToControl ?? true
            )
        }
    }
}
