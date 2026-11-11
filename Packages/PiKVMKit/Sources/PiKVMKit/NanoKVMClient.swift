import Foundation

// Client for Sipeed NanoKVM devices (NanoKVM Cube/Lite/PCIe, NanoKVM Pro and
// NanoKVM Go). Sources: https://github.com/sipeed/NanoKVM and
// https://github.com/sipeed/NanoKVM-Pro (server/router/*.go).
//
// How it differs from kvmd:
// * Login: `POST /api/auth/login` with JSON `{username, password}` returns a
//   JWT, as `data.token` (Pro, older NanoKVM) and/or the `nano-kvm-token`
//   cookie (NanoKVM 2.5.1+, which only reads the cookie). Requests then carry
//   the cookie; Pro also takes `Authorization: Bearer`. kvmd instead takes the
//   password on every request.
// * The classic NanoKVM wants the password AES-wrapped (`NanoKVMPassword`);
//   Pro and Go take it plain.
// * Responses are `{code, msg, data}` with HTTP 200; `code` 0 is success.
// * Video: MJPEG at `/api/stream/mjpeg` (no separate session socket needed).
//   H.264 is WebRTC with its own signalling, not Janus; not supported here yet.
// * HID: binary messages on `/api/ws`, a type byte followed by a standard USB
//   HID report (`HIDReport`), since NanoKVM 2.3.2. kvmd uses key names.
// * Power: GPIO "button presses" (`/api/vm/gpio`) and the power/HDD LEDs.
// * Virtual media: images already on the device (`/api/storage/image`),
//   mounted as a CD-ROM or a USB disk.

/// The JSON envelope every NanoKVM API answer uses.
struct NanoKVMEnvelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let message: String?
    let data: T?
}

/// For calls whose `data` doesn't matter.
struct NanoKVMIgnored: Decodable {
    init(from decoder: Decoder) throws {}
}

/// `/api/vm/info`.
public struct NanoKVMInfo: Decodable, Sendable, Hashable {
    public struct IP: Decodable, Sendable, Hashable {
        public let name: String?
        public let addr: String?
    }
    public let ips: [IP]?
    public let mdns: String?
    /// The system image version.
    public let image: String?
    /// The NanoKVM application version, e.g. "2.5.4".
    public let application: String?
    public let deviceKey: String?
    /// Pro and Go only: the product number.
    public let pn: String?
    /// Pro and Go only.
    public let arch: String?
}

/// `/api/vm/gpio`: the ATX power and HDD LEDs.
public struct NanoKVMLEDs: Decodable, Sendable, Hashable {
    public let pwr: Bool
    public let hdd: Bool
}

/// `/api/storage/image/mounted`.
public struct NanoKVMMountedImage: Decodable, Sendable, Hashable {
    /// The mounted image's path, or empty when none is.
    public let file: String
    /// Pro only; the classic NanoKVM reports it at `/api/storage/cdrom`.
    public let cdrom: Bool?
}

public final class NanoKVMClient: @unchecked Sendable {
    public let baseURL: URL
    public let family: DeviceFamily
    private let username: String
    private let password: String
    private let session: URLSession
    public let trustPolicy: TrustPolicy
    public let trustDelegate: CertificatePinningDelegate

    private let lock = NSLock()
    private var _token: String?

    /// Press durations, matching the NanoKVM web page.
    public static let shortPressMilliseconds = 800
    public static let longPressMilliseconds = 8000

    public init(baseURL: URL, family: DeviceFamily, username: String, password: String,
                trust: TrustPolicy, timeout: TimeInterval = 10, token: String? = nil) {
        precondition(family.isSipeed, "NanoKVMClient is for Sipeed devices")
        self.baseURL = baseURL
        self.family = family
        self.username = username
        self.password = password
        self.trustPolicy = trust
        let delegate = CertificatePinningDelegate(policy: trust)
        self.trustDelegate = delegate
        self._token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        // The token is sent by hand, so the same login works for the video
        // stream and the websocket, which use their own sessions.
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// The session token from the last login.
    public var token: String? {
        lock.lock(); defer { lock.unlock() }
        return _token
    }

    private func setToken(_ token: String?) {
        lock.lock(); _token = token; lock.unlock()
    }

    /// The trust policy for other connections to the same device, including
    /// the pin learned on this connection for a self-signed certificate.
    public var effectiveTrustPolicy: TrustPolicy {
        var policy = trustPolicy
        if !policy.requireCertificateAuthority, policy.pinnedSHA256 == nil, trustDelegate.observedTrustedByCA != true {
            policy.pinnedSHA256 = trustDelegate.observedSHA256
        }
        return policy
    }

    // MARK: Requests

    public func makeRequest(_ path: String, method: String = "GET", query: [String: String] = [:]) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw KVMDError.invalidURL
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw KVMDError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue("nano-kvm-token=\(token)", forHTTPHeaderField: "Cookie")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func jsonRequest(_ path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        var req = try makeRequest(path, method: method)
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Sends a request and decodes `data`. On a 401 it logs in again once,
    /// since tokens expire.
    func call<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                            body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T? {
        for attempt in 0..<2 {
            var req = try jsonRequest(path, method: method, body: body)
            if let timeout { req.timeoutInterval = timeout }
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 401, attempt == 0 {
                try await login()
                continue
            }
            return try Self.decode(T.self, data: data, response: response)
        }
        throw KVMDError.unauthorized
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T? {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw KVMDError.unauthorized }
            if http.statusCode == 403 { throw KVMDError.api("This NanoKVM account isn't allowed to do that.") }
            if !(200..<300).contains(http.statusCode) { throw KVMDError.http(http.statusCode) }
        }
        let envelope = try JSONDecoder().decode(NanoKVMEnvelope<T>.self, from: data)
        guard envelope.code == 0 else {
            throw KVMDError.api(envelope.msg ?? envelope.message ?? "The NanoKVM reported error \(envelope.code).")
        }
        return envelope.data
    }

    // MARK: Authentication

    private struct LoginData: Decodable {
        let token: String?
    }

    /// Logs in and keeps the session token. Throws `KVMDError.unauthorized`
    /// for a wrong username or password.
    public func login() async throws {
        let wrapped = family == .nanoKVM ? NanoKVMPassword.wrap(password) : password
        var req = try makeRequest("api/auth/login", method: "POST")
        req.setValue(nil, forHTTPHeaderField: "Cookie")
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": wrapped])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        setToken(try Self.parseLogin(data: data, response: response, baseURL: baseURL))
    }

    /// Reads the token from a login answer: the `nano-kvm-token` cookie or
    /// `data.token`. Nil when the device has authentication turned off.
    static func parseLogin(data: Data, response: URLResponse, baseURL: URL) throws -> String? {
        guard let http = response as? HTTPURLResponse else { throw KVMDError.api("The NanoKVM sent no answer.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw KVMDError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw KVMDError.http(http.statusCode) }
        guard let envelope = try? JSONDecoder().decode(NanoKVMEnvelope<LoginData>.self, from: data) else {
            throw KVMDError.api("This doesn't look like a NanoKVM. Check the model and address.")
        }
        switch envelope.code {
        case 0: break
        case -2: throw KVMDError.unauthorized
        default:
            // -4/-5: too many failed attempts, locked for a while.
            throw KVMDError.api(envelope.msg ?? envelope.message ?? "Login failed (error \(envelope.code)).")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let k = pair.key as? String, let v = pair.value as? String { result[k] = v }
        }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
            .first { $0.name == "nano-kvm-token" && !$0.value.isEmpty }?.value
        if let cookie { return cookie }
        if let token = envelope.data?.token, !token.isEmpty, token != "disabled" { return token }
        return nil
    }

    // MARK: Device

    public func info() async throws -> NanoKVMInfo? {
        try await call(NanoKVMInfo.self, "api/vm/info")
    }

    private struct Hardware: Decodable { let version: String? }

    /// The hardware revision, e.g. "Alpha", "Beta", "PCIE" on a classic NanoKVM.
    public func hardwareVersion() async throws -> String? {
        try await call(Hardware.self, "api/vm/hardware")?.version
    }

    // MARK: Power

    /// Power and HDD LEDs. Throws when the device has no ATX board.
    public func leds() async throws -> NanoKVMLEDs {
        guard let leds = try await call(NanoKVMLEDs.self, "api/vm/gpio") else {
            throw KVMDError.api("The NanoKVM didn't report its power LEDs.")
        }
        return leds
    }

    /// Presses the power button for `milliseconds`. Returns once released.
    public func pressPower(milliseconds: Int = NanoKVMClient.shortPressMilliseconds) async throws {
        _ = try await call(NanoKVMIgnored.self, "api/vm/gpio", method: "POST",
                           body: ["type": "power", "duration": milliseconds],
                           timeout: 15 + Double(milliseconds) / 1000)
    }

    public func pressReset() async throws {
        _ = try await call(NanoKVMIgnored.self, "api/vm/gpio", method: "POST",
                           body: ["type": "reset", "duration": NanoKVMClient.shortPressMilliseconds],
                           timeout: 15)
    }

    // MARK: Virtual media

    private struct Images: Decodable { let files: [String]? }

    /// Paths of the images stored on the device.
    public func images() async throws -> [String] {
        try await call(Images.self, "api/storage/image")?.files ?? []
    }

    public func mountedImage() async throws -> NanoKVMMountedImage? {
        try await call(NanoKVMMountedImage.self, "api/storage/image/mounted")
    }

    private struct CDROM: Decodable { let cdrom: Int? }

    /// Classic NanoKVM: whether the mounted image is presented as a CD-ROM.
    public func cdromMode() async throws -> Bool {
        (try await call(CDROM.self, "api/storage/cdrom")?.cdrom ?? 0) != 0
    }

    /// Presents `file` (a path from `images()`) to the remote machine. An
    /// empty `file` ejects the image (a classic NanoKVM then goes back to
    /// sharing its data partition).
    public func mountImage(_ file: String, cdrom: Bool) async throws {
        _ = try await call(NanoKVMIgnored.self, "api/storage/image/mount", method: "POST",
                           body: ["file": file, "cdrom": cdrom], timeout: 60)
    }

    public func deleteImage(_ file: String) async throws {
        _ = try await call(NanoKVMIgnored.self, "api/storage/image/delete", method: "POST", body: ["file": file])
    }

    // MARK: Keyboard

    /// Characters sent per paste request. The NanoKVM caps a request at
    /// about 1024 characters; small requests keep Cancel responsive.
    public static let pasteChunkSize = 64

    /// Types `text` on the remote machine (US keyboard layout). Returns when
    /// typing is done; the NanoKVM types about 20 characters a second.
    public func paste(_ text: String) async throws {
        _ = try await call(NanoKVMIgnored.self, "api/hid/paste", method: "POST",
                           body: ["content": text], timeout: 30 + Double(text.count) * 0.1)
    }

    // MARK: Video and input

    /// The MJPEG stream request, for `MJPEGStreamer(request:trust:...)`.
    public func mjpegRequest() throws -> URLRequest {
        var req = try makeRequest("api/stream/mjpeg")
        req.setValue("multipart/x-mixed-replace, image/jpeg", forHTTPHeaderField: "Accept")
        return req
    }

    /// The HID websocket. Send `NanoKVMMessage`s on it; send a heartbeat at
    /// least every 30 seconds.
    public func hidSocket() throws -> URLSessionWebSocketTask {
        var req = try makeRequest("api/ws")
        guard var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else { throw KVMDError.invalidURL }
        comps.scheme = (comps.scheme == "http") ? "ws" : "wss"
        req.url = comps.url
        req.timeoutInterval = 15
        return session.webSocketTask(with: req)
    }

    /// One frame of the video, as JPEG. NanoKVM has no snapshot API, so this
    /// reads the MJPEG stream until a frame arrives.
    public func snapshot(timeout: TimeInterval = 8) async throws -> Data {
        let request = try mjpegRequest()
        let trust = effectiveTrustPolicy
        let box = SnapshotBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                box.begin(continuation)
                let streamer = MJPEGStreamer(request: request, trust: trust, onFrame: { frame in
                    box.finish(.success(frame))
                }, onEnd: { error in
                    box.finish(.failure(error ?? KVMDError.api("The NanoKVM's video stream ended before a picture arrived.")))
                })
                box.streamer = streamer
                streamer.start()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    box.finish(.failure(KVMDError.api("The NanoKVM sent no picture. Is the remote machine's screen on?")))
                }
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }
}

/// Resolves `snapshot()` exactly once and stops its stream.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var done = false
    var streamer: MJPEGStreamer? {
        get { lock.lock(); defer { lock.unlock() }; return _streamer }
        set { lock.lock(); _streamer = newValue; let stop = done; lock.unlock(); if stop { newValue?.stop() } }
    }
    private var _streamer: MJPEGStreamer?

    func begin(_ c: CheckedContinuation<Data, Error>) {
        lock.lock()
        if done { lock.unlock(); c.resume(throwing: CancellationError()); return }
        continuation = c
        lock.unlock()
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        let s = _streamer
        _streamer = nil
        lock.unlock()
        s?.stop()
        c?.resume(with: result)
    }
}

// MARK: - Connecting

/// A working, logged-in connection to a Sipeed device.
public struct NanoKVMConnection: Sendable {
    public let device: Device
    public let endpoint: Endpoint
    public let client: NanoKVMClient

    public var observedCertificateSHA256: String? { client.trustDelegate.observedSHA256 }
    public var observedTrustedByCA: Bool? { client.trustDelegate.observedTrustedByCA }
}

public enum NanoKVMConnectionResolver {
    /// The URLs to try for an endpoint: HTTPS first, then plain HTTP, because
    /// a NanoKVM ships with HTTPS off. Once a certificate is known for the
    /// device, only HTTPS is tried, so a network can't downgrade it.
    static func candidateURLs(for endpoint: Endpoint, device: Device) -> [URL] {
        guard let https = endpoint.baseURL else { return [] }
        if endpoint.hasExplicitScheme { return [https] }
        let knowsCertificate = device.pinnedCertificateSHA256 != nil || device.certificateTrust != nil
        if knowsCertificate { return [https] }
        return [https] + (endpoint.plainHTTPURL.map { [$0] } ?? [])
    }

    /// Tries each endpoint in order (LAN first, then Tailscale) and returns
    /// the first that logs in. A wrong password fails right away, so the
    /// NanoKVM's failed-login lockout isn't triggered by retries.
    public static func connect(to device: Device, password: String, probeTimeout: TimeInterval = 4) async throws -> NanoKVMConnection {
        var tried: [String] = []
        var rejection: String?
        var apiError: Error?
        for endpoint in device.endpoints {
            let urls = candidateURLs(for: endpoint, device: device)
            guard !urls.isEmpty else { continue }
            tried.append("\(endpoint.label) (\(endpoint.host))")
            for url in urls {
                let policy = TrustPolicy(device: device)
                let probe = NanoKVMClient(baseURL: url, family: device.family, username: device.username,
                                          password: password, trust: policy, timeout: probeTimeout)
                do {
                    try await probe.login()
                } catch KVMDError.unauthorized {
                    throw KVMDError.unauthorized
                } catch let error as KVMDError {
                    if case .api = error { apiError = error }
                    if let reason = probe.trustDelegate.rejection { rejection = reason }
                    continue
                } catch {
                    if let reason = probe.trustDelegate.rejection { rejection = reason }
                    continue
                }
                let client = NanoKVMClient(baseURL: url, family: device.family, username: device.username,
                                           password: password, trust: probe.effectiveTrustPolicy, token: probe.token)
                return NanoKVMConnection(device: device, endpoint: endpoint, client: client)
            }
        }
        if let rejection { throw KVMDError.certificateRejected(rejection) }
        if let apiError { throw apiError }
        throw KVMDError.noReachableEndpoint(tried)
    }
}
