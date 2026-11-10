import CryptoKit
import Foundation
import Security

/// URLSession delegate that handles PiKVM's self-signed certificates with
/// trust-on-first-use pinning:
///
/// * a certificate the system already trusts is accepted;
/// * otherwise, if a fingerprint is pinned, the leaf must match it exactly;
/// * otherwise (first contact) the certificate is accepted and its
///   fingerprint is recorded so the caller can pin it.
public final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _pinned: String?
    private var _observed: String?

    public init(pinnedSHA256: String?) {
        _pinned = pinnedSHA256?.lowercased()
    }

    /// The SHA-256 (hex) of the last leaf certificate presented by the server.
    public var observedSHA256: String? {
        lock.lock(); defer { lock.unlock() }
        return _observed
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

        let fingerprint = Self.leafFingerprint(trust)
        lock.lock()
        _observed = fingerprint
        let pinned = _pinned
        lock.unlock()

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if let pinned {
            if fingerprint == pinned {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        // First contact: accept and let the caller pin `observedSHA256`.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
