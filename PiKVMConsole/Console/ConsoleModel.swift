import AppKit
import Foundation
import Observation
import PiKVMKit

/// How the console receives video.
enum VideoMode: String, CaseIterable, Identifiable {
    /// H.264 video and audio over WebRTC. Sharper motion and far less bandwidth.
    case h264
    /// A stream of JPEG images. Works everywhere, no audio.
    case mjpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264 (WebRTC)"
        case .mjpeg: return "MJPEG"
        }
    }
}

/// Console preferences shared by all console windows.
enum ConsolePreferences {
    private static let videoModeKey = "console.videoMode"
    private static let volumeKey = "console.volume"
    private static let mutedKey = "console.muted"
    /// Whether the toolbar is hidden while a console is in full screen. On unless turned off.
    static let hideToolbarInFullScreenKey = "console.hideToolbarInFullScreen"

    static var videoMode: VideoMode {
        get { VideoMode(rawValue: UserDefaults.standard.string(forKey: videoModeKey) ?? "") ?? .h264 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: videoModeKey) }
    }

    static var volume: Double {
        get { UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: volumeKey) }
    }

    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
}

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
    var state: State = .connecting
    /// The latest video frame.
    private(set) var frame: CGImage?
    private(set) var videoSize: CGSize = .zero
    private(set) var fps: Int = 0
    /// True while the Mac cursor is captured for relative mouse mode.
    var mouseCaptured = false
    /// True while this console's window is in full screen.
    var isFullScreen = false
    /// Shows the virtual media panel over this console.
    var showingMedia = false

    /// The mode the user asked for.
    private(set) var videoMode = ConsolePreferences.videoMode
    /// The mode in use right now; differs from `videoMode` after a fallback.
    var activeVideoMode: VideoMode = .mjpeg
    /// Set when H.264 was requested but the console fell back to MJPEG.
    var fallbackReason: String?
    /// The view WebRTC draws into, while H.264 is active.
    private(set) var webRTCView: NSView?
    /// Whether this PiKVM offers audio (only known in H.264 mode).
    private(set) var audioAvailable = false
    /// Whether the PiKVM can take this Mac's microphone or camera (H.264 mode only).
    private(set) var micAvailable = false
    private(set) var cameraAvailable = false
    /// True while an app on the remote machine has the PiKVM's webcam open.
    private(set) var cameraInUse = false
    /// What the user asked to send. Off whenever a console opens.
    private(set) var sendMic = false
    private(set) var sendCamera = false
    /// What is actually being sent right now.
    private(set) var sendingMic = false
    private(set) var sendingCamera = false
    var volume = ConsolePreferences.volume {
        didSet { ConsolePreferences.volume = volume; webRTC?.volume = volume }
    }
    var muted = ConsolePreferences.muted {
        didSet { ConsolePreferences.muted = muted; webRTC?.muted = muted }
    }

    struct PasteProgress: Equatable {
        let typed: Int
        let total: Int
    }

    /// Set while pasted text is being typed.
    var pasteProgress: PasteProgress?
    /// Clipboard text waiting for the user to confirm.
    var pendingPaste: String?
    /// How fast pasted text is typed. Shared by all consoles.
    var typingRate = TypingRate(rawValue: UserDefaults.standard.string(forKey: "console.typingRate") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(typingRate.rawValue, forKey: "console.typingRate") }
    }
    var pasteTask: Task<Void, Never>?

    weak var app: AppModel?
    var socket: URLSessionWebSocketTask?
    private var streamer: MJPEGStreamer?
    private var webRTC: WebRTCStream?
    private var webRTCUp = false
    private var webRTCWatchdog: Task<Void, Never>?
    /// H.264 failed on this connection, so don't retry it until the user asks.
    private var h264Unavailable = false
    private var runTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var frameCount = 0
    private var fpsWindowStart = Date()
    var generation = 0
    /// Set while connected to a Sipeed NanoKVM, which takes standard HID
    /// reports instead of kvmd's key names. See `ConsoleModel+NanoKVM.swift`.
    var nano: NanoKVMConsoleLink?

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
        pasteTask?.cancel()
        runTask?.cancel()
        runTask = nil
        teardown()
    }

    func teardown() {
        generation += 1
        nano?.stop()
        nano = nil
        pingTask?.cancel()
        pingTask = nil
        streamer?.stop()
        streamer = nil
        stopWebRTC()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func stopWebRTC() {
        webRTCWatchdog?.cancel()
        webRTCWatchdog = nil
        webRTC?.onEvent = nil
        webRTC?.stop()
        webRTC = nil
        webRTCView = nil
        webRTCUp = false
        audioAvailable = false
        micAvailable = false
        cameraAvailable = false
        cameraInUse = false
        sendingMic = false
        sendingCamera = false
    }

    /// Drops the connection so the run loop connects again from scratch.
    func reconnect() {
        h264Unavailable = false
        fallbackReason = nil
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Called when this console's window becomes or stops being the key window.
    func windowIsKey(_ isKey: Bool) {
        if isKey {
            app?.frontConsole = self
        } else if app?.frontConsole === self {
            app?.frontConsole = nil
        }
    }

    /// Starts or stops sending this Mac's microphone and camera to the remote
    /// machine. The video reconnects briefly to apply it.
    func setPassthrough(mic: Bool, camera: Bool) {
        sendMic = mic
        sendCamera = camera
        webRTC?.setSending(mic: mic, camera: camera)
    }

    func toggleMouseMode() {
        setMouseMode(mouseMode == .relative ? .absolute : .relative)
    }

    /// Switches between H.264 and MJPEG and reconnects the video.
    func setVideoMode(_ mode: VideoMode) {
        ConsolePreferences.videoMode = mode
        videoMode = mode
        h264Unavailable = false
        fallbackReason = nil
        // Dropping the socket makes the run loop reconnect with the new mode.
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Connects and runs until the socket or stream drops.
    /// Returns true if the console was live at some point.
    private func runOnce() async -> Bool {
        guard let app, let target else {
            state = .failed("This machine is no longer configured.")
            return false
        }
        if frame == nil, webRTCView == nil { state = .connecting }
        let session = app.session(for: selection.deviceID)
        await session.connectIfNeeded()
        if let nanoClient = session.nanoClient {
            return await runNanoKVMOnce(nanoClient)
        }
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
            if videoMode == .h264, !h264Unavailable {
                startWebRTC(client: client, generation: gen)
            } else {
                startStream(client: client, generation: gen)
            }

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

    // MARK: H.264 (WebRTC)

    private func startWebRTC(client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        activeVideoMode = .h264
        frame = nil
        let stream = WebRTCStream()
        stream.volume = volume
        stream.muted = muted
        stream.onEvent = { [weak self] event in
            self?.handleWebRTC(event, client: client, generation: gen)
        }
        webRTC = stream
        webRTCView = stream.videoView
        stream.start(client: client, wantAudio: true, sendMic: sendMic, sendCamera: sendCamera)

        // If the media connection never comes up, use MJPEG instead.
        webRTCWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, gen == self.generation, !self.webRTCUp else { return }
            self.fallBackToMJPEG("H.264 didn't connect.", client: client, generation: gen)
        }
    }

    private func handleWebRTC(_ event: WebRTCStream.Event, client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .connected:
            webRTCUp = true
            webRTCWatchdog?.cancel()
            if videoSize != .zero, state == .connecting { state = .live }
        case .videoSize(let size):
            guard size.width > 0, size.height > 0 else { return }
            videoSize = size
            if state != .noSignal { state = .live }
        case .audioAvailable(let available):
            audioAvailable = available
        case .passthrough(let mic, let camera, let inUse):
            micAvailable = mic
            cameraAvailable = camera
            cameraInUse = inUse
        case .sending(let mic, let camera):
            sendingMic = mic
            sendingCamera = camera
        case .notice(let message):
            app?.lastError = message
        case .ended(let error):
            if webRTCUp {
                // It was working: reconnect the whole session.
                socket?.cancel(with: .goingAway, reason: nil)
            } else {
                fallBackToMJPEG(error ?? "H.264 isn't available on this PiKVM.", client: client, generation: gen)
            }
        }
    }

    private func fallBackToMJPEG(_ reason: String, client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        stopWebRTC()
        h264Unavailable = true
        fallbackReason = reason
        startStream(client: client, generation: gen)
    }

    // MARK: MJPEG

    private func startStream(client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        activeVideoMode = .mjpeg
        streamer?.stop()
        streamer = try? MJPEGStreamer(client: client, onFrame: { [weak self] data in
            guard let image = ConsoleModel.decode(data) else { return }
            Task { @MainActor [weak self] in self?.receive(image, generation: gen) }
        }, onEnd: { [weak self] error in
            Task { @MainActor [weak self] in self?.streamEnded(error, client: client, generation: gen) }
        })
        streamer?.start()
    }

    nonisolated static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func receive(_ image: CGImage, generation gen: Int) {
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
            if activeVideoMode == .h264 {
                // WebRTC keeps its connection; frames simply resume.
                state = (webRTCUp && videoSize != .zero) ? .live : .connecting
            } else {
                state = frame == nil ? .connecting : .live
            }
        }
    }

    /// The video stream closed while the session socket is still up, e.g.
    /// the streamer wasn't ready yet or restarted for a new video mode.
    /// Retry the stream alone; a lost connection is handled by the socket.
    private func streamEnded(_ error: Error?, client: KVMDClient, generation gen: Int) {
        guard gen == generation else { return }
        if let kvmdError = error as? KVMDError, case .unauthorized = kvmdError {
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
        if let nano { nano.key(code, down: down); return }
        send(HIDMessage.key(code, down: down))
    }

    func mouseButton(_ button: MouseButton, down: Bool) {
        if let nano { nano.mouseButton(button, down: down, mode: mouseMode); return }
        send(HIDMessage.mouseButton(button, down: down))
    }

    /// `point` is in video pixels with the origin at the top-left.
    func mouseMove(toVideoPoint point: CGPoint) {
        if let nano { nano.mouseMove(toVideoPoint: point, videoSize: videoSize); return }
        guard let pos = HIDMessage.absolutePosition(x: point.x, y: point.y,
                                                    videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        send(HIDMessage.mouseMove(x: pos.x, y: pos.y))
    }

    func mouseRelative(dx: Int, dy: Int) {
        if let nano { nano.mouseRelative(dx: dx, dy: dy); return }
        let steps = HIDMessage.splitDelta(dx: dx, dy: dy)
        guard !steps.isEmpty else { return }
        send(HIDMessage.mouseRelative(steps, squash: steps.count > 1))
    }

    func mouseWheel(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        if let nano { nano.mouseWheel(dy: dy, mode: mouseMode); return }
        send(HIDMessage.mouseWheel(dx: dx, dy: dy))
    }

    // MARK: Paste

    /// Reads the Mac clipboard and types it on the remote machine. Long or
    /// multi-line text is held in `pendingPaste` for confirmation first.
    func pasteClipboard() {
        guard pasteProgress == nil else { return }
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            app?.lastError = "The clipboard has no text to paste."
            return
        }
        let text = TextPaste.normalize(raw)
        guard !text.isEmpty else {
            app?.lastError = "The clipboard has no text to paste."
            return
        }
        if text.count > 200 || text.contains("\n") {
            pendingPaste = text
        } else {
            typeText(text)
        }
    }

    /// Types `text` on the remote machine at the chosen typing rate.
    func typeText(_ text: String) {
        pendingPaste = nil
        if let app, let nanoClient = app.session(for: selection.deviceID).nanoClient {
            typeTextOnNanoKVM(text, client: nanoClient)
            return
        }
        guard pasteProgress == nil, let app, let client = app.session(for: selection.deviceID).client else { return }
        let chunks = TextPaste.chunks(text)
        let total = text.count
        let delay = typingRate.delay
        pasteProgress = PasteProgress(typed: 0, total: total)
        pasteTask = Task { [weak self] in
            var typed = 0
            do {
                for chunk in chunks {
                    try Task.checkCancellation()
                    try await client.typeText(chunk, delay: delay)
                    typed += chunk.count
                    self?.pasteProgress = PasteProgress(typed: typed, total: total)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { app.lastError = "Paste stopped after \(typed) of \(total) characters: \(error.localizedDescription)" }
            }
            self?.pasteProgress = nil
            self?.pasteTask = nil
        }
    }

    /// Stops a paste in progress. Characters already sent to the PiKVM
    /// (up to one small chunk) are still typed.
    func cancelPaste() {
        pasteTask?.cancel()
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
