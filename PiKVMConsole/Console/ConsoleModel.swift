import AppKit
import Foundation
import Observation
import PiKVMKit

/// Drives one console window: keeps the kvmd session socket open (which
/// also keeps the video streamer running), reads video frames, and sends
/// keyboard and mouse input.
@MainActor
@Observable
final class ConsoleModel {
    enum State: Equatable {
        case connecting
        case live
        /// Connected, but the remote machine is sending no video.
        case noSignal
        case failed(String)
    }

    let selection: TargetSelection
    private(set) var state: State = .connecting
    /// The latest video frame.
    private(set) var frame: CGImage?
    private(set) var videoSize: CGSize = .zero
    private(set) var fps: Int = 0
    /// True while the Mac cursor is captured for relative mouse mode.
    var mouseCaptured = false

    private weak var app: AppModel?
    private var socket: URLSessionWebSocketTask?
    private var streamer: MJPEGStreamer?
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var frameCount = 0
    private var fpsWindowStart = Date()
    private var generation = 0

    init(selection: TargetSelection, app: AppModel) {
        self.selection = selection
        self.app = app
    }

    var device: Device? { app?.device(selection.deviceID) }
    var target: Target? { device?.targets.first { $0.id == selection.targetID } }
    var mouseMode: MouseMode { target?.mouseMode ?? .absolute }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                let ranCleanly = await self.runOnce()
                if Task.isCancelled { return }
                backoff = ranCleanly ? 1 : min(backoff * 2, 15)
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        teardown()
    }

    private func teardown() {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        streamer?.stop()
        streamer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Connects and runs until the socket or stream drops.
    /// Returns true if the console was live at some point.
    private func runOnce() async -> Bool {
        guard let app, let target else {
            state = .failed("This machine is no longer configured.")
            return false
        }
        if frame == nil { state = .connecting }
        let session = app.session(for: selection.deviceID)
        await session.connectIfNeeded()
        guard let client = session.client else {
            if case .failed(let message) = session.status { state = .failed(message) }
            return false
        }

        do {
            // Select this machine's switch port and apply its saved mouse mode.
            try await session.activate(target)
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }

        generation += 1
        let gen = generation
        var wasLive = false
        do {
            let socket = try client.consoleSocket()
            self.socket = socket
            socket.resume()

            pingTask = Task { [weak socket] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let socket else { return }
                    try? await socket.send(.data(HIDMessage.ping))
                }
            }

            // kvmd starts the streamer once a stream=1 socket exists; give it a moment.
            try? await Task.sleep(nanoseconds: 500_000_000)
            startStream(client: client, generation: gen)

            // Drain the socket; it ends (throws) when the connection drops.
            while !Task.isCancelled {
                let message = try await socket.receive()
                if state == .live || state == .noSignal { wasLive = true }
                if case .string(let text) = message,
                   let event = try? JSONDecoder().decode(KVMDEvent.self, from: Data(text.utf8)),
                   let online = event.streamerSourceOnline {
                    sourceOnline(online)
                }
            }
        } catch {
            if !Task.isCancelled, !wasLive {
                state = .failed(error.localizedDescription)
            }
        }
        if state == .live || state == .noSignal { wasLive = true }
        teardown()
        if !Task.isCancelled { state = .connecting }
        return wasLive
    }

    private func startStream(client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        streamer?.stop()
        streamer = try? MJPEGStreamer(client: client, onFrame: { [weak self] data in
            guard let image = ConsoleModel.decode(data) else { return }
            Task { @MainActor [weak self] in self?.receive(image, generation: gen) }
        }, onEnd: { [weak self] error in
            Task { @MainActor [weak self] in self?.streamEnded(error, client: client, generation: gen) }
        })
        streamer?.start()
    }

    nonisolated private static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func receive(_ image: CGImage, generation gen: Int) {
        guard gen == generation else { return }
        frame = image
        let size = CGSize(width: image.width, height: image.height)
        if size != videoSize { videoSize = size }
        if state != .live { state = .live }
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1 {
            fps = Int((Double(frameCount) / elapsed).rounded())
            frameCount = 0
            fpsWindowStart = Date()
        }
    }

    /// kvmd reports whether the capture source has a signal. Without one
    /// the streamer sends no frames at all.
    private func sourceOnline(_ online: Bool) {
        if !online {
            frame = nil
            fps = 0
            state = .noSignal
        } else if state == .noSignal {
            state = frame == nil ? .connecting : .live
        }
    }

    /// The video stream closed while the session socket is still up, e.g.
    /// the streamer wasn't ready yet or restarted for a new video mode.
    /// Retry the stream alone; a lost connection is handled by the socket.
    private func streamEnded(_ error: Error?, client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        if case KVMDError.unauthorized? = error {
            state = .failed(KVMDError.unauthorized.localizedDescription)
            socket?.cancel(with: .goingAway, reason: nil)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.startStream(client: client, generation: gen)
        }
    }

    // MARK: Input

    private func send(_ data: Data) {
        guard let socket else { return }
        socket.send(.data(data)) { _ in }
    }

    func key(_ code: String, down: Bool) {
        send(HIDMessage.key(code, down: down))
    }

    func mouseButton(_ button: MouseButton, down: Bool) {
        send(HIDMessage.mouseButton(button, down: down))
    }

    /// `point` is in video pixels with the origin at the top-left.
    func mouseMove(toVideoPoint point: CGPoint) {
        guard let pos = HIDMessage.absolutePosition(x: point.x, y: point.y,
                                                    videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        send(HIDMessage.mouseMove(x: pos.x, y: pos.y))
    }

    func mouseRelative(dx: Int, dy: Int) {
        let steps = HIDMessage.splitDelta(dx: dx, dy: dy)
        guard !steps.isEmpty else { return }
        send(HIDMessage.mouseRelative(steps, squash: steps.count > 1))
    }

    func mouseWheel(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        send(HIDMessage.mouseWheel(dx: dx, dy: dy))
    }

    /// Presses the keys in order, then releases them in reverse.
    func sendCombo(_ codes: [String]) {
        for code in codes { key(code, down: true) }
        for code in codes.reversed() { key(code, down: false) }
    }

    func setMouseMode(_ mode: MouseMode) {
        guard let app else { return }
        app.setMouseMode(mode, deviceID: selection.deviceID, targetID: selection.targetID)
        if mode == .absolute { mouseCaptured = false }
        let session = app.session(for: selection.deviceID)
        Task {
            do { try await session.applyMouseMode(mode) } catch { app.lastError = error.localizedDescription }
        }
    }
}
