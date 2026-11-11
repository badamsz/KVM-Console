import Foundation

/// Messages of the Janus websocket protocol, as used by PiKVM's
/// `janus.plugin.ustreamer` (H.264 video and Opus audio over WebRTC).
/// The flow mirrors `web/share/js/kvm/stream_janus.js`:
/// create session → attach plugin → `features` → `watch` → server sends an
/// SDP offer → `start` with the SDP answer.
public enum JanusMessage {
    public static let pluginName = "janus.plugin.ustreamer"

    public static func create(transaction: String) -> [String: Any] {
        ["janus": "create", "transaction": transaction]
    }

    public static func attach(session: Int64, transaction: String) -> [String: Any] {
        ["janus": "attach", "plugin": pluginName, "session_id": session, "transaction": transaction]
    }

    public static func keepalive(session: Int64, transaction: String) -> [String: Any] {
        ["janus": "keepalive", "session_id": session, "transaction": transaction]
    }

    public static func features(session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        message(body: ["request": "features"], session: session, handle: handle, transaction: transaction)
    }

    /// - Parameters:
    ///   - audio: receive the remote machine's audio.
    ///   - mic: send this Mac's microphone to the remote machine.
    ///   - camera: send this Mac's camera to the remote machine.
    public static func watch(audio: Bool, mic: Bool = false, camera: Bool = false,
                             session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        message(body: ["request": "watch",
                       "params": ["orientation": 0, "audio": audio, "mic": mic, "camera": camera]],
                session: session, handle: handle, transaction: transaction)
    }

    public static func start(answerSDP: String, session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        var msg = message(body: ["request": "start"], session: session, handle: handle, transaction: transaction)
        msg["jsep"] = ["type": "answer", "sdp": answerSDP]
        return msg
    }

    public static func stop(session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        message(body: ["request": "stop"], session: session, handle: handle, transaction: transaction)
    }

    public static func trickle(candidate: String, sdpMid: String?, sdpMLineIndex: Int32,
                               session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        var c: [String: Any] = ["candidate": candidate, "sdpMLineIndex": Int(sdpMLineIndex)]
        if let sdpMid { c["sdpMid"] = sdpMid }
        return ["janus": "trickle", "candidate": c, "session_id": session, "handle_id": handle, "transaction": transaction]
    }

    public static func trickleCompleted(session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        ["janus": "trickle", "candidate": ["completed": true],
         "session_id": session, "handle_id": handle, "transaction": transaction]
    }

    private static func message(body: [String: Any], session: Int64, handle: Int64, transaction: String) -> [String: Any] {
        ["janus": "message", "body": body, "session_id": session, "handle_id": handle, "transaction": transaction]
    }
}

/// What the streamer plugin reports it can do.
public struct JanusFeatures: Equatable, Sendable {
    /// What the remote machine's camera driver asked for once it opened the
    /// PiKVM's virtual webcam.
    public struct CameraRequest: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int

        public init(width: Int, height: Int, fps: Int) {
            self.width = width
            self.height = height
            self.fps = fps
        }
    }

    /// The PiKVM can send the remote machine's audio.
    public var audio: Bool
    /// The PiKVM presents a USB microphone to the remote machine and accepts audio for it.
    public var mic: Bool
    /// The PiKVM presents a USB webcam to the remote machine.
    public var camera: Bool
    /// Set while an app on the remote machine is using that webcam and nobody
    /// else is feeding it. Video can only be sent while this is set.
    public var cameraRequest: CameraRequest?
    /// A STUN/TURN URL configured on the PiKVM, if any.
    public var iceURL: String?

    public init(audio: Bool, mic: Bool = false, camera: Bool = false, cameraRequest: CameraRequest? = nil, iceURL: String? = nil) {
        self.audio = audio
        self.mic = mic
        self.camera = camera
        self.cameraRequest = cameraRequest
        self.iceURL = iceURL
    }
}

/// A parsed message from Janus.
public enum JanusIncoming: Equatable, Sendable {
    /// Reply to `create` / `attach`, carrying the new id.
    case success(transaction: String?, id: Int64?)
    case ack(transaction: String?)
    /// A Janus-level error (bad session, unknown plugin, ...).
    case error(transaction: String?, reason: String)
    case features(JanusFeatures)
    /// The remote machine's use of the virtual webcam changed: `online`, `offline` or `lost`.
    case camera(action: String)
    /// Plugin status: `starting`, `started`, `stopped`.
    case status(String)
    /// An SDP offer from the plugin.
    case offer(sdp: String)
    /// A plugin-level error, e.g. the stream isn't ready yet.
    case pluginError(String)
    case webrtcUp
    case hangup(reason: String)
    case other

    public static func parse(_ data: Data) -> [JanusIncoming] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["janus"] as? String else { return [] }
        let transaction = obj["transaction"] as? String
        switch kind {
        case "success":
            let id = (obj["data"] as? [String: Any])?["id"] as? NSNumber
            return [.success(transaction: transaction, id: id?.int64Value)]
        case "ack":
            return [.ack(transaction: transaction)]
        case "error":
            let reason = (obj["error"] as? [String: Any])?["reason"] as? String ?? "Unknown Janus error"
            return [.error(transaction: transaction, reason: reason)]
        case "webrtcup":
            return [.webrtcUp]
        case "hangup":
            return [.hangup(reason: obj["reason"] as? String ?? "")]
        case "event":
            var out: [JanusIncoming] = []
            let data = (obj["plugindata"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
            if let result = data["result"] as? [String: Any], let status = result["status"] as? String {
                if status == "features", let f = result["features"] as? [String: Any] {
                    let ice = (f["ice"] as? [String: Any])?["url"] as? String
                    let camera = f["camera"] as? [String: Any]
                    var request: JanusFeatures.CameraRequest?
                    if let req = camera?["request"] as? [String: Any],
                       let res = req["resolution"] as? [String: Any],
                       let w = (res["width"] as? NSNumber)?.intValue, let h = (res["height"] as? NSNumber)?.intValue,
                       w > 0, h > 0 {
                        request = .init(width: w, height: h, fps: max(1, (req["fps"] as? NSNumber)?.intValue ?? 30))
                    }
                    out.append(.features(JanusFeatures(audio: f["audio"] as? Bool ?? false,
                                                       mic: f["mic"] as? Bool ?? false,
                                                       camera: camera?["enabled"] as? Bool ?? false,
                                                       cameraRequest: request,
                                                       iceURL: (ice?.isEmpty == false) ? ice : nil)))
                } else if status == "camera", let action = (result["camera"] as? [String: Any])?["action"] as? String {
                    out.append(.camera(action: action))
                } else {
                    out.append(.status(status))
                }
            } else if let message = data["error"] as? String {
                out.append(.pluginError(message))
            } else if data["error_code"] != nil {
                out.append(.pluginError("Streamer error \(data["error_code"] ?? "")"))
            }
            if let jsep = obj["jsep"] as? [String: Any], jsep["type"] as? String == "offer",
               let sdp = jsep["sdp"] as? String {
                out.append(.offer(sdp: sdp))
            }
            return out.isEmpty ? [.other] : out
        default:
            return [.other]
        }
    }
}

public enum JanusError: Error, LocalizedError, Sendable {
    case janus(String)
    case closed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .janus(let reason): return "The PiKVM's WebRTC gateway reported: \(reason)"
        case .closed: return "The connection to the PiKVM's WebRTC gateway closed."
        case .timeout: return "The PiKVM's WebRTC gateway didn't answer."
        }
    }
}

/// A Janus session attached to the ustreamer plugin, over the PiKVM's
/// `/janus/ws` websocket. Signalling only; the caller owns the WebRTC
/// peer connection.
public actor JanusSession {
    private let task: URLSessionWebSocketTask
    private var pending: [String: CheckedContinuation<Int64?, Error>] = [:]
    private var session: Int64 = 0
    private var handle: Int64 = 0
    private var readerTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var closed = false

    private let eventContinuation: AsyncStream<JanusIncoming>.Continuation
    /// Plugin events (features, offer, status, hangup). Ends when the socket closes.
    public nonisolated let events: AsyncStream<JanusIncoming>

    public init(client: KVMDClient) throws {
        task = try client.webSocket(path: "janus/ws", protocols: ["janus-protocol"])
        (events, eventContinuation) = AsyncStream.makeStream(of: JanusIncoming.self)
    }

    /// Opens the socket, creates a session and attaches to the streamer plugin.
    public func connect() async throws {
        task.resume()
        readerTask = Task { [weak self] in await self?.readLoop() }
        guard let s = try await request({ JanusMessage.create(transaction: $0) }) else { throw JanusError.janus("no session id") }
        session = s
        guard let h = try await request({ JanusMessage.attach(session: s, transaction: $0) }) else { throw JanusError.janus("no handle id") }
        handle = h
        // Janus drops sessions that are silent for 60 seconds.
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                await self?.sendKeepalive()
            }
        }
    }

    public func requestFeatures() async throws {
        try await send(JanusMessage.features(session: session, handle: handle, transaction: Self.newTransaction()))
    }

    public func watch(audio: Bool, mic: Bool = false, camera: Bool = false) async throws {
        try await send(JanusMessage.watch(audio: audio, mic: mic, camera: camera,
                                          session: session, handle: handle, transaction: Self.newTransaction()))
    }

    public func start(answerSDP: String) async throws {
        try await send(JanusMessage.start(answerSDP: answerSDP, session: session, handle: handle, transaction: Self.newTransaction()))
    }

    public func trickle(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async throws {
        try await send(JanusMessage.trickle(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex,
                                            session: session, handle: handle, transaction: Self.newTransaction()))
    }

    public func trickleCompleted() async throws {
        try await send(JanusMessage.trickleCompleted(session: session, handle: handle, transaction: Self.newTransaction()))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        keepaliveTask?.cancel()
        readerTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        failPending(JanusError.closed)
        eventContinuation.finish()
    }

    // MARK: Internals

    private static func newTransaction() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
    }

    private func sendKeepalive() async {
        guard !closed, session != 0 else { return }
        try? await send(JanusMessage.keepalive(session: session, transaction: Self.newTransaction()))
    }

    private func send(_ message: [String: Any]) async throws {
        guard !closed else { throw JanusError.closed }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Sends a request and waits for its `success` reply.
    private func request(_ build: (String) -> [String: Any]) async throws -> Int64? {
        let transaction = Self.newTransaction()
        let message = build(transaction)
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { await self?.resolve(transaction, .failure(JanusError.timeout)) }
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[transaction] = continuation
            Task {
                do { try await self.send(message) } catch { self.resolve(transaction, .failure(error)) }
            }
        }
    }

    private func resolve(_ transaction: String, _ result: Result<Int64?, Error>) {
        guard let continuation = pending.removeValue(forKey: transaction) else { return }
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            let data: Data
            do {
                switch try await task.receive() {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
            } catch {
                break
            }
            for incoming in JanusIncoming.parse(data) { dispatch(incoming) }
        }
        if !closed {
            closed = true
            keepaliveTask?.cancel()
            failPending(JanusError.closed)
            eventContinuation.finish()
        }
    }

    private func dispatch(_ incoming: JanusIncoming) {
        switch incoming {
        case .success(let transaction, let id):
            if let transaction { resolve(transaction, .success(id)) }
        case .error(let transaction, let reason):
            if let transaction, pending[transaction] != nil {
                resolve(transaction, .failure(JanusError.janus(reason)))
            } else {
                eventContinuation.yield(incoming)
            }
        case .ack, .other:
            break
        default:
            eventContinuation.yield(incoming)
        }
    }
}
