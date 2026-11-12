import CryptoKit
import Foundation
import Security

/// How a device's TLS certificate is checked.
public enum CertificateTrust: String, Codable, Sendable, Hashable {
    /// The certificate is self-signed (PiKVM's default) and its fingerprint is pinned.
    case pinned
    /// The certificate is issued by a certificate authority this Mac trusts,
    /// for example an internal step-ca that the PiKVM renews from with ACME.
    /// Renewed certificates are accepted; anything the Mac doesn't trust is refused.
    case certificateAuthority
}

/// What a connection accepts.
public struct TrustPolicy: Sendable, Hashable {
    /// The pinned certificate fingerprint, for self-signed certificates.
    public var pinnedSHA256: String?
    /// Refuse certificates the Mac doesn't trust, instead of falling back to pinning.
    public var requireCertificateAuthority: Bool
    /// Every name the device is reached by. A CA-issued certificate is accepted
    /// when it is valid for any of them, so a certificate issued for the LAN
    /// name still works when connecting through Tailscale.
    public var hostnames: [String]

    public init(pinnedSHA256: String? = nil, requireCertificateAuthority: Bool = false, hostnames: [String] = []) {
        self.pinnedSHA256 = pinnedSHA256?.lowercased()
        self.requireCertificateAuthority = requireCertificateAuthority
        self.hostnames = hostnames
    }

    public init(device: Device) {
        let ca = device.certificateTrust == .certificateAuthority
        self.init(pinnedSHA256: ca ? nil : device.pinnedCertificateSHA256,
                  requireCertificateAuthority: ca,
                  hostnames: device.endpoints.compactMap { $0.baseURL?.host(percentEncoded: false) })
    }
}

/// URLSession delegate that checks a PiKVM's certificate:
///
/// * a certificate the Mac trusts (system or user-installed CA) is accepted
///   when it is valid for the host being connected to, or for any other name
///   of the same device;
/// * otherwise, if the device requires a trusted CA, the connection is refused;
/// * otherwise, if a fingerprint is pinned, the leaf must match it exactly;
/// * otherwise (first contact with a self-signed certificate) the certificate
///   is accepted and its fingerprint is recorded so the caller can pin it.
public final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let policy: TrustPolicy
    private var _observed: String?
    private var _observedTrustedByCA: Bool?
    private var _rejection: String?

    public init(policy: TrustPolicy) {
        self.policy = policy
    }

    public convenience init(pinnedSHA256: String?) {
        self.init(policy: TrustPolicy(pinnedSHA256: pinnedSHA256))
    }

    /// The SHA-256 (hex) of the last leaf certificate presented by the server.
    public var observedSHA256: String? {
        lock.lock(); defer { lock.unlock() }
        return _observed
    }

    /// Whether the last certificate presented was trusted through a certificate authority.
    public var observedTrustedByCA: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _observedTrustedByCA
    }

    /// Why the last certificate was refused, if it was.
    public var rejection: String? {
        lock.lock(); defer { lock.unlock() }
        return _rejection
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let fingerprint = Self.leafFingerprint(trust)
        let caTrusted = Self.trustedByCA(trust, host: host, otherNames: policy.hostnames)

        lock.lock()
        _observed = fingerprint
        _observedTrustedByCA = caTrusted
        lock.unlock()

        let decision = Self.decide(caTrusted: caTrusted, fingerprint: fingerprint, policy: policy)
        lock.lock()
        switch decision {
        case .accept:
            _rejection = nil
        case .reject:
            _rejection = policy.requireCertificateAuthority
                ? "\(host) presented a certificate this Mac doesn't trust. This device uses a certificate authority, so check that its certificate has been renewed and that your CA's root certificate is trusted in Keychain Access."
                : "\(host) presented a different certificate from the one saved for this device. If you replaced it on purpose, edit the device, press Forget Certificate and save to accept the new one."
        }
        lock.unlock()
        switch decision {
        case .accept: completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    enum Decision: Equatable { case accept, reject }

    static func decide(caTrusted: Bool, fingerprint: String?, policy: TrustPolicy) -> Decision {
        if caTrusted { return .accept }
        if policy.requireCertificateAuthority { return .reject }
        if let pinned = policy.pinnedSHA256 {
            return fingerprint == pinned ? .accept : .reject
        }
        // First contact with a self-signed certificate: accept and let the caller pin it.
        return .accept
    }

    /// Evaluates the chain against the Mac's trust settings for `host`, then
    /// for each of the device's other names.
    static func trustedByCA(_ trust: SecTrust, host: String, otherNames: [String]) -> Bool {
        if SecTrustEvaluateWithError(trust, nil) { return true }
        var names = otherNames.filter { $0.caseInsensitiveCompare(host) != .orderedSame }
        // De-duplicate while keeping order.
        var seen = Set<String>()
        names = names.filter { seen.insert($0.lowercased()).inserted }
        for name in names {
            let policy = SecPolicyCreateSSL(true, name as CFString)
            guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { continue }
            if SecTrustEvaluateWithError(trust, nil) { return true }
        }
        // Leave the trust as URLSession expects it for the original host.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        return false
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
