import AppKit
import Foundation
import PiKVMKit

/// The console's connection to a Sipeed NanoKVM, NanoKVM Pro or NanoKVM Go:
/// MJPEG video from `/api/stream/mjpeg`, and keyboard and mouse as standard
/// USB HID reports on the `/api/ws` socket.
@MainActor
final class NanoKVMConsoleLink {
    let client: NanoKVMClient
    let socket: URLSessionWebSocketTask
    private var streamer: MJPEGStreamer?
    private var heartbeat: Task<Void, Never>?
    private var keyboard = HIDReport.Keyboard()
    private var buttons: UInt8 = 0
    private var lastPosition: (x: UInt16, y: UInt16) = (16384, 16384)

    init(client: NanoKVMClient) throws {
        self.client = client
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

    func startVideo(onFrame: @escaping MJPEGStreamer.FrameHandler, onEnd: @escaping MJPEGStreamer.EndHandler) throws {
        streamer?.stop()
        let streamer = MJPEGStreamer(request: try client.mjpegRequest(), trust: client.effectiveTrustPolicy,
                                     onFrame: onFrame, onEnd: onEnd)
        self.streamer = streamer
        streamer.start()
    }

    func stop() {
        // Let go of anything still held before the socket closes.
        if keyboard.keys.isEmpty == false || keyboard.modifiers != 0 { send(NanoKVMMessage.keyboard(keyboard.reset())) }
        if buttons != 0 {
            buttons = 0
            send(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: 0)))
            send(NanoKVMMessage.mouse(HIDReport.absoluteMouse(buttons: 0, x: lastPosition.x, y: lastPosition.y)))
        }
        heartbeat?.cancel()
        heartbeat = nil
        streamer?.stop()
        streamer = nil
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ data: Data) {
        socket.send(.data(data)) { _ in }
    }

    // MARK: Input

    func key(_ code: String, down: Bool) {
        if let report = keyboard.update(webCode: code, down: down) {
            send(NanoKVMMessage.keyboard(report))
        }
    }

    func mouseButton(_ button: MouseButton, down: Bool, mode: MouseMode) {
        let bit = HIDReport.buttonBit(button)
        if down { buttons |= bit } else { buttons &= ~bit }
        switch mode {
        case .absolute:
            send(NanoKVMMessage.mouse(HIDReport.absoluteMouse(buttons: buttons, x: lastPosition.x, y: lastPosition.y)))
        case .relative:
            send(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: buttons)))
        }
    }

    func mouseMove(toVideoPoint point: CGPoint, videoSize: CGSize) {
        guard let pos = HIDReport.absolutePosition(x: point.x, y: point.y,
                                                   videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        lastPosition = pos
        send(NanoKVMMessage.mouse(HIDReport.absoluteMouse(buttons: buttons, x: pos.x, y: pos.y)))
    }

    func mouseRelative(dx: Int, dy: Int) {
        for step in HIDMessage.splitDelta(dx: dx, dy: dy) {
            send(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: buttons, dx: step.dx, dy: step.dy)))
        }
    }

    /// Positive `dy` scrolls up. Boot mice have no horizontal wheel.
    func mouseWheel(dy: Int, mode: MouseMode) {
        guard dy != 0 else { return }
        switch mode {
        case .absolute:
            send(NanoKVMMessage.mouse(HIDReport.absoluteMouse(buttons: buttons, x: lastPosition.x, y: lastPosition.y, wheel: dy)))
        case .relative:
            send(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: buttons, wheel: dy)))
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
        fallbackReason = videoMode == .h264 ? "H.264 isn't supported for Sipeed devices yet." : nil
        var wasLive = false
        do {
            let link = try NanoKVMConsoleLink(client: client)
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
            try link.startVideo(onFrame: { [weak self] data in
                guard let image = ConsoleModel.decode(data) else { return }
                Task { @MainActor [weak self] in self?.receive(image, generation: gen) }
            }, onEnd: { [weak self] error in
                Task { @MainActor [weak self] in self?.nanoKVMVideoEnded(error, link: link, generation: gen) }
            })
        } catch {
            state = .failed(error.localizedDescription)
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
