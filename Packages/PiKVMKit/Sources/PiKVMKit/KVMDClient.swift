import Foundation

public enum KVMDError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case http(Int)
    case api(String)
    case noReachableEndpoint([String])

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The device address is not valid."
        case .unauthorized: return "The username or password was rejected."
        case .http(let code): return "The device returned HTTP \(code)."
        case .api(let msg): return msg
        case .noReachableEndpoint(let tried):
            return "Couldn't reach the device at " + tried.joined(separator: " or ") + "."
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
    public let trustDelegate: CertificatePinningDelegate

    /// - Parameters:
    ///   - password: the kvmd password. With 2FA enabled, append the current TOTP code.
    public init(baseURL: URL, username: String, password: String, pinnedSHA256: String?, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        let delegate = CertificatePinningDelegate(pinnedSHA256: pinnedSHA256)
        self.trustDelegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: Requests

    func makeRequest(_ path: String, method: String = "GET", query: [String: String] = [:]) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw KVMDError.invalidURL
        }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
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

    /// The PiKVM Switch chain state. Throws if no switch is configured.
    public func switchState() async throws -> SwitchState {
        try await send(SwitchState.self, "api/switch")
    }

    public func setActiveSwitchPort(_ port: Int) async throws {
        _ = try await send(Empty.self, "api/switch/set_active", method: "POST", query: ["port": String(port)])
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
