import AppKit
import Foundation
import PiKVMKit

/// The console's connection to a Sipeed NanoKVM, NanoKVM Pro or NanoKVM Go:
/// MJPEG video from `/api/stream/mjpeg` (or, on firmware without it, H.264
/// from `/api/stream/h264/direct`), and keyboard and mouse as standard USB
/// HID reports on the `/api/ws` socket.
@MainActor
final class NanoKVMConsoleLink {
    let client: NanoKVMClient
    let socket: URLSessionWebSocketTask
    let transport: NanoKVMClient.VideoTransport
    private var streamer: MJPEGStreamer?
    private var h264: H264DirectStreamer?
    private var router = NanoKVMInputRouter()
    private let started = Date()
    private var heartbeat: Task<Void, Never>?
    private var keyboard = HIDReport.Keyboard()
    private var buttons: UInt8 = 0
    private var lastPosition: (x: UInt16, y: UInt16) = (16384, 16384)

    init(client: NanoKVMClient, transport: NanoKVMClient.VideoTransport) throws {
        self.client = client
        self.transport = transport
        self.socket = try client.hidSocket()
    }

    func start() {
        socket.resume()
        // The NanoKVM closes a socket that has been silent for 90 seconds.
        heartbeat = Task { [weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let socket else { return }
                try? await socket.send(.data(NanoKVMMessage.heartbeat))
            }
        }
    }

    func startVideo(onFrame: @escaping @Sendable (CGImage) -> Void,
                    onStatus: @escaping H264DirectStreamer.StatusHandler,
                    onEnd: @escaping MJPEGStreamer.EndHandler) throws {
        streamer?.stop()
        streamer = nil
        h264?.stop()
        h264 = nil
        switch transport {
        case .mjpeg:
            let streamer = MJPEGStreamer(request: try client.mjpegRequest(), trust: client.effectiveTrustPolicy,
                                         onFrame: { data in
                                             if let image = ConsoleModel.decode(data) { onFrame(image) }
                                         }, onEnd: onEnd)
            self.streamer = streamer
            streamer.start()
        case .h264Direct:
            let stream = try H264DirectStreamer(client: client, onFrame: onFrame, onStatus: onStatus, onEnd: onEnd)
            h264 = stream
            stream.start()
        }
    }

    func stop() {
        // Let go of anything still held before the socket closes.
        if keyboard.keys.isEmpty == false || keyboard.modifiers != 0 { sendKeyboard(keyboard.reset()) }
        if buttons != 0 {
            buttons = 0
            sendRelative(dx: 0, dy: 0, wheel: 0)
            sendAbsolute(wheel: 0)
        }
        heartbeat?.cancel()
        heartbeat = nil
        streamer?.stop()
        streamer = nil
        h264?.stop()
        h264 = nil
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ data: Data) {
        socket.send(.data(data)) { _ in }
    }

    private var useRouter: Bool { transport == .h264Direct }

    private func routed(_ source: NanoKVMInputRouter.Source, _ type: NanoKVMInputRouter.ReportType, _ payload: Data) {
        let ms = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(started) * 1000))
        send(router.message(source: source, type: type, payload: payload, timestamp: ms))
    }

    private func sendKeyboard(_ report: Data) {
        if useRouter { routed(.keyboard, .keyboard, report) } else { send(NanoKVMMessage.keyboard(report)) }
    }

    private func sendAbsolute(wheel: Int) {
        if useRouter {
            routed(.pointer, .absolutePointer,
                   NanoKVMInputRouter.absolutePointer(buttons: buttons, x: NanoKVMInputRouter.widen(lastPosition.x),
                                                      y: NanoKVMInputRouter.widen(lastPosition.y), wheel: wheel))
        } else {
            send(NanoKVMMessage.mouse(HIDReport.absoluteMouse(buttons: buttons, x: lastPosition.x, y: lastPosition.y,
                                                              wheel: wheel)))
        }
    }

    private func sendRelative(dx: Int, dy: Int, wheel: Int) {
        if useRouter {
            routed(.pointer, .relativePointer,
                   NanoKVMInputRouter.relativePointer(buttons: buttons, dx: dx, dy: dy, wheel: wheel))
        } else {
            send(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: buttons, dx: dx, dy: dy, wheel: wheel)))
        }
    }

    // MARK: Input

    func key(_ code: String, down: Bool) {
        if let report = keyboard.update(webCode: code, down: down) {
            sendKeyboard(report)
        }
    }

    func mouseButton(_ button: MouseButton, down: Bool, mode: MouseMode) {
        let bit = HIDReport.buttonBit(button)
        if down { buttons |= bit } else { buttons &= ~bit }
        switch mode {
        case .absolute: sendAbsolute(wheel: 0)
        case .relative: sendRelative(dx: 0, dy: 0, wheel: 0)
        }
    }

    func mouseMove(toVideoPoint point: CGPoint, videoSize: CGSize) {
        guard let pos = HIDReport.absolutePosition(x: point.x, y: point.y,
                                                   videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        lastPosition = pos
        sendAbsolute(wheel: 0)
    }

    func mouseRelative(dx: Int, dy: Int) {
        for step in HIDMessage.splitDelta(dx: dx, dy: dy) {
            sendRelative(dx: step.dx, dy: step.dy, wheel: 0)
        }
    }

    /// Positive `dy` scrolls up. Boot mice have no horizontal wheel.
    func mouseWheel(dy: Int, mode: MouseMode) {
        guard dy != 0 else { return }
        switch mode {
        case .absolute: sendAbsolute(wheel: dy)
        case .relative: sendRelative(dx: 0, dy: 0, wheel: dy)
        }
    }
}

extension ConsoleModel {
    /// Connects to a NanoKVM and runs until the HID socket drops. Returns
    /// true if the console was live at some point.
    func runNanoKVMOnce(_ client: NanoKVMClient) async -> Bool {
        generation += 1
        let gen = generation
        activeVideoMode = .mjpeg
        frameCodec = "MJPEG"
        fallbackReason = videoMode == .h264 ? "H.264 isn't supported for Sipeed devices yet." : nil
        var wasLive = false
        do {
            let transport = try await client.videoTransport()
            guard gen == generation, !Task.isCancelled else { return false }
            if transport == .h264Direct {
                // Decoded here rather than over WebRTC, so there's no audio.
                frameCodec = "H.264"
                fallbackReason = nil
            }
            let link = try NanoKVMConsoleLink(client: client, transport: transport)
            nano = link
            socket = link.socket
            link.start()
            startNanoKVMVideo(link, generation: gen)

            // Drain the socket; it ends (throws) when the connection drops.
            // The NanoKVM sends JSON notices (keyboard LEDs, capture status) we don't need.
            while !Task.isCancelled {
                _ = try await link.socket.receive()
                if state == .live || state == .noSignal { wasLive = true }
            }
        } catch {
            if !Task.isCancelled, !wasLive, state != .live {
                state = .failed(error.localizedDescription)
            }
        }
        if state == .live || state == .noSignal { wasLive = true }
        teardown()
        if !Task.isCancelled { state = .connecting }
        return wasLive
    }

    private func startNanoKVMVideo(_ link: NanoKVMConsoleLink, generation gen: Int) {
        guard gen == generation, nano === link else { return }
        do {
            try link.startVideo(onFrame: { [weak self] image in
                Task { @MainActor [weak self] in self?.receive(image, generation: gen) }
            }, onStatus: { [weak self] status in
                Task { @MainActor [weak self] in self?.nanoKVMVideoStatus(status, generation: gen) }
            }, onEnd: { [weak self] error in
                Task { @MainActor [weak self] in self?.nanoKVMVideoEnded(error, link: link, generation: gen) }
            })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The H.264 stream reports whether the NanoKVM has a picture to send.
    private func nanoKVMVideoStatus(_ status: NanoKVMVideoStatus, generation gen: Int) {
        guard gen == generation else { return }
        switch status {
        case .normal: sourceOnline(true)
        case .noImage, .captureDisabled, .inconsistentVideoMode: sourceOnline(false)
        case .encoderError, .bufferFull: break
        }
    }

    /// The video stream closed while the HID socket is still up. Retry the
    /// stream alone; a lost connection is handled by the socket.
    private func nanoKVMVideoEnded(_ error: Error?, link: NanoKVMConsoleLink, generation gen: Int) {
        guard gen == generation else { return }
        if let kvmdError = error as? KVMDError, case .unauthorized = kvmdError {
            // The session expired: reconnect from scratch, which logs in again.
            app?.session(for: selection.deviceID).disconnect()
            socket?.cancel(with: .goingAway, reason: nil)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.startNanoKVMVideo(link, generation: gen)
        }
    }

    /// Types text through the NanoKVM's paste API, which uses a US keyboard layout.
    func typeTextOnNanoKVM(_ text: String, client: NanoKVMClient) {
        guard pasteProgress == nil else { return }
        let chunks = TextPaste.chunks(text, size: NanoKVMClient.pasteChunkSize)
        let total = text.count
        pasteProgress = PasteProgress(typed: 0, total: total)
        pasteTask = Task { [weak self] in
            var typed = 0
            do {
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await client.paste(chunk)
                    typed += chunk.count
                    self?.pasteProgress = PasteProgress(typed: typed, total: total)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    self?.app?.lastError = "Paste stopped after \(typed) of \(total) characters: \(error.localizedDescription)"
                }
            }
            self?.pasteProgress = nil
            self?.pasteTask = nil
        }
    }
}
