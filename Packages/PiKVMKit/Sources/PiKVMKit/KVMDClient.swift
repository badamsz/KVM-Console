import Foundation

public enum KVMDError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case http(Int)
    case api(String)
    case noReachableEndpoint([String])
    case certificateRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The device address is not valid."
        case .unauthorized: return "The username or password was rejected."
        case .http(let code): return "The device returned HTTP \(code)."
        case .api(let msg): return msg
        case .noReachableEndpoint(let tried):
            return "Couldn't reach the device at " + tried.joined(separator: " or ") + "."
        case .certificateRejected(let reason): return reason
        }
    }
}

/// Client for the kvmd HTTP and websocket API on a single PiKVM endpoint.
/// See https://docs.pikvm.org/api/
public final class KVMDClient: Sendable {
    public let baseURL: URL
    private let username: String
    private let password: String
    private let session: URLSession
    public let trustPolicy: TrustPolicy
    public let trustDelegate: CertificatePinningDelegate

    /// - Parameters:
    ///   - password: the kvmd password. With 2FA enabled, append the current TOTP code.
    public convenience init(baseURL: URL, username: String, password: String, pinnedSHA256: String?, timeout: TimeInterval = 10) {
        self.init(baseURL: baseURL, username: username, password: password,
                  trust: TrustPolicy(pinnedSHA256: pinnedSHA256), timeout: timeout)
    }

    public init(baseURL: URL, username: String, password: String, trust: TrustPolicy, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.trustPolicy = trust
        let delegate = CertificatePinningDelegate(policy: trust)
        self.trustDelegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: Requests

    /// Builds an authenticated request for a path on this PiKVM (kvmd API,
    /// `streamer/...`, etc.).
    public func makeRequest(_ path: String, method: String = "GET", query: [String: String] = [:]) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw KVMDError.invalidURL
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" alone, but kvmd reads it as a space (file names can contain it).
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw KVMDError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(username, forHTTPHeaderField: "X-KVMD-User")
        req.setValue(password, forHTTPHeaderField: "X-KVMD-Passwd")
        return req
    }

    func send<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", query: [String: String] = [:]) async throws -> T {
        let req = try makeRequest(path, method: method, query: query)
        let (data, response) = try await session.data(for: req)
        return try Self.decode(T.self, data: data, response: response)
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw KVMDError.unauthorized }
            if !(200..<300).contains(http.statusCode) {
                if let err = try? JSONDecoder().decode(KVMDEnvelope<KVMDErrorResult>.self, from: data),
                   let msg = err.result.error_msg ?? err.result.error {
                    throw KVMDError.api(msg)
                }
                throw KVMDError.http(http.statusCode)
            }
        }
        return try JSONDecoder().decode(KVMDEnvelope<T>.self, from: data).result
    }

    private struct Empty: Decodable {
        init(from decoder: Decoder) throws {}
    }

    // MARK: Endpoints

    /// Verifies the credentials. Throws `KVMDError.unauthorized` if rejected.
    public func checkAuth() async throws {
        _ = try await send(Empty.self, "api/auth/check")
    }

    public func info() async throws -> DeviceInfo {
        try await send(DeviceInfo.self, "api/info")
    }

    public func atx() async throws -> ATXState {
        try await send(ATXState.self, "api/atx")
    }

    /// Intelligent power control: `on`/`off` do nothing if already in that state.
    public func atxPower(_ action: ATXPowerAction, wait: Bool = false) async throws {
        _ = try await send(Empty.self, "api/atx/power", method: "POST",
                           query: ["action": action.rawValue, "wait": wait ? "1" : "0"])
    }

    /// Presses a front-panel button directly.
    public func atxClick(_ button: ATXButton, wait: Bool = false) async throws {
        _ = try await send(Empty.self, "api/atx/click", method: "POST",
                           query: ["button": button.rawValue, "wait": wait ? "1" : "0"])
    }

    public func hid() async throws -> HIDState {
        try await send(HIDState.self, "api/hid")
    }

    public func setMouseMode(_ mode: MouseMode) async throws {
        _ = try await send(Empty.self, "api/hid/set_params", method: "POST",
                           query: ["mouse_output": mode.kvmdMouseOutput])
    }

    /// Types `text` on the remote machine as key presses. kvmd maps each
    /// character through `keymap` (its default when nil), which must match
    /// the remote machine's keyboard layout. Returns when typing is done.
    /// - Parameter delay: pause after each key event, 0...5 seconds.
    public func typeText(_ text: String, delay: TimeInterval = 0.02, keymap: String? = nil) async throws {
        var query = ["limit": "0", "delay": String(format: "%.3f", max(0, min(5, delay)))]
        // Older kvmd has no `delay`; `slow` is its 20 ms equivalent.
        if delay >= 0.02 { query["slow"] = "1" }
        if let keymap { query["keymap"] = keymap }
        var req = try makeRequest("api/hid/print", method: "POST", query: query)
        req.httpBody = Data(text.utf8)
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // The request stays open while kvmd types.
        req.timeoutInterval = 30 + TextPaste.estimatedDuration(characters: text.count, delay: delay) * 2
        let (data, response) = try await session.data(for: req)
        _ = try Self.decode(Empty.self, data: data, response: response)
    }

    /// The PiKVM Switch chain state. Throws if no switch is configured.
    public func switchState() async throws -> SwitchState {
        try await send(SwitchState.self, "api/switch")
    }

    public func setActiveSwitchPort(_ port: Int) async throws {
        _ = try await send(Empty.self, "api/switch/set_active", method: "POST", query: ["port": String(port)])
    }

    /// Turns a Switch port's beacon light on or off, to find the port on the hardware.
    public func setSwitchBeacon(port: Int, on: Bool) async throws {
        _ = try await send(Empty.self, "api/switch/set_beacon", method: "POST",
                           query: ["port": String(port), "state": on ? "1" : "0"])
    }

    /// ATX power for a machine behind a PiKVM Switch (the switch's own ATX
    /// headers, not the PiKVM's).
    public func switchATXPower(port: Int, _ action: ATXPowerAction) async throws {
        _ = try await send(Empty.self, "api/switch/atx/power", method: "POST",
                           query: ["port": String(port), "action": action.rawValue])
    }

    public func switchATXClick(port: Int, _ button: ATXButton) async throws {
        _ = try await send(Empty.self, "api/switch/atx/click", method: "POST",
                           query: ["port": String(port), "button": button.rawValue])
    }

    // MARK: Virtual media

    public func msd() async throws -> MSDState {
        try await send(MSDState.self, "api/msd")
    }

    /// Chooses the image and how the drive presents it. Only allowed while
    /// the drive is disconnected. Pass an empty `image` to clear the selection.
    public func msdSetParams(image: String? = nil, cdrom: Bool? = nil, writable: Bool? = nil) async throws {
        var query: [String: String] = [:]
        if let image { query["image"] = image }
        if let cdrom { query["cdrom"] = cdrom ? "1" : "0" }
        if let writable { query["rw"] = writable ? "1" : "0" }
        _ = try await send(Empty.self, "api/msd/set_params", method: "POST", query: query)
    }

    /// Plugs the virtual drive into the remote machine, or unplugs it.
    public func msdSetConnected(_ connected: Bool) async throws {
        _ = try await send(Empty.self, "api/msd/set_connected", method: "POST", query: ["connected": connected ? "1" : "0"])
    }

    public func msdRemove(image: String) async throws {
        _ = try await send(Empty.self, "api/msd/remove", method: "POST", query: ["image": image])
    }

    /// Uploads a local file to the PiKVM's image storage. kvmd deletes the
    /// partial image if the upload fails or is cancelled.
    /// - Parameter progress: bytes sent and total bytes, called off the main thread.
    public func msdUpload(fileURL: URL, as name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var req = try makeRequest("api/msd/write", method: "POST", query: ["image": name, "remove_incomplete": "1"])
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Idle timeout: generous, because the PiKVM can stall while it flushes to its SD card.
        req.timeoutInterval = 600
        let (data, response) = try await session.upload(for: req, fromFile: fileURL, delegate: UploadProgressDelegate(progress))
        _ = try Self.decode(Empty.self, data: data, response: response)
    }

    // MARK: Screen preview

    /// A JPEG of the remote screen, scaled to fit the given size.
    ///
    /// kvmd only runs its video streamer while someone is watching. If it is
    /// stopped, this opens a console session for a few seconds to start it.
    /// Behind a Switch the picture is of the active port.
    public func snapshot(maxWidth: Int = 640, maxHeight: Int = 400) async throws -> Data {
        let query = [
            "preview": "1",
            "preview_max_width": String(maxWidth),
            "preview_max_height": String(maxHeight),
            "preview_quality": "80",
            // With no video signal, return the streamer's placeholder instead of an error.
            "allow_offline": "1",
        ]
        do {
            return try await fetchSnapshot(query)
        } catch KVMDError.http(503) {
            // The streamer isn't running; start it below.
        }
        let socket = try consoleSocket()
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 750_000_000)
            do {
                return try await fetchSnapshot(query)
            } catch KVMDError.http(503) {
                continue
            }
        }
        throw KVMDError.api("The PiKVM's video didn't start in time.")
    }

    private func fetchSnapshot(_ query: [String: String]) async throws -> Data {
        let req = try makeRequest("api/streamer/snapshot", query: query)
        let (data, response) = try await session.data(for: req)
        try Self.checkSnapshot(data: data, response: response)
        return data
    }

    static func checkSnapshot(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw KVMDError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw KVMDError.http(http.statusCode) }
        guard !data.isEmpty else { throw KVMDError.api("The PiKVM returned an empty picture.") }
    }

    // MARK: Console

    /// Opens the session websocket used by the console. `stream=1` asks kvmd
    /// to keep the video streamer running while this socket is open; HID
    /// events are sent over the same socket (see `HIDMessage`).
    public func consoleSocket() throws -> URLSessionWebSocketTask {
        var req = try makeRequest("api/ws", query: ["stream": "1"])
        guard var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else { throw KVMDError.invalidURL }
        comps.scheme = (comps.scheme == "http") ? "ws" : "wss"
        req.url = comps.url
        req.timeoutInterval = 15
        return session.webSocketTask(with: req)
    }

    /// Opens an authenticated websocket to a path on this PiKVM, e.g. the
    /// web terminal. `protocols` are offered as websocket subprotocols.
    public func webSocket(path: String, protocols: [String] = []) throws -> URLSessionWebSocketTask {
        var req = try makeRequest(path)
        guard var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else { throw KVMDError.invalidURL }
        comps.scheme = (comps.scheme == "http") ? "ws" : "wss"
        req.url = comps.url
        req.timeoutInterval = 15
        if !protocols.isEmpty {
            req.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return session.webSocketTask(with: req)
    }

    /// The certificate fingerprint this client trusts (pinned or observed).
    /// The policy for other connections to the same device: the pin learned on
    /// this connection is included for a self-signed certificate.
    public var effectiveTrustPolicy: TrustPolicy {
        var policy = trustPolicy
        if !policy.requireCertificateAuthority, policy.pinnedSHA256 == nil, trustDelegate.observedTrustedByCA != true {
            policy.pinnedSHA256 = trustDelegate.observedSHA256
        }
        return policy
    }

    // MARK: Events

    /// Opens the kvmd event websocket. kvmd sends the full state of every
    /// subsystem on connect, then incremental updates.
    public func events() -> AsyncThrowingStream<KVMDEvent, Error> {
        AsyncThrowingStream { continuation in
            let task: URLSessionWebSocketTask
            do {
                var req = try makeRequest("api/ws", query: ["stream": "0"])
                guard var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) else {
                    throw KVMDError.invalidURL
                }
                comps.scheme = (comps.scheme == "http") ? "ws" : "wss"
                req.url = comps.url
                task = session.webSocketTask(with: req)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let reader = Task {
                task.resume()
                let decoder = JSONDecoder()
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        if let event = try? decoder.decode(KVMDEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
