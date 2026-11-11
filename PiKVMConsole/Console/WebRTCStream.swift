import AppKit
import AVFoundation
import PiKVMKit
import WebRTC

/// Receives the PiKVM's H.264 video and Opus audio over WebRTC, using the
/// Janus gateway on the device for signalling. Video is drawn into
/// `videoView`; audio plays through the Mac's default output.
///
/// On PiKVMs set up for it, the same connection can also carry this Mac's
/// microphone and camera to the remote machine, which sees them as a USB
/// microphone and webcam.
@MainActor
final class WebRTCStream: NSObject {
    enum Event {
        /// The media connection is up.
        case connected
        /// The first frame arrived, or the remote resolution changed.
        case videoSize(CGSize)
        /// Whether the PiKVM offers audio (it needs an HDMI audio-capable model).
        case audioAvailable(Bool)
        /// What the PiKVM can take from this Mac. `cameraInUse` is true while
        /// an app on the remote machine has the virtual webcam open.
        case passthrough(mic: Bool, camera: Bool, cameraInUse: Bool)
        /// Whether this Mac's microphone and camera are being sent right now.
        case sending(mic: Bool, camera: Bool)
        /// A problem worth telling the user about that doesn't end the stream.
        case notice(String)
        /// The stream ended. `error` is nil for a normal close.
        case ended(error: String?)
    }

    let videoView: RTCMTLNSVideoView
    var onEvent: (@MainActor (Event) -> Void)?

    /// 0...1
    var volume: Double = 1 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }

    fileprivate static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var janus: JanusSession?
    private var peer: RTCPeerConnection?
    private var peerDelegate: PeerDelegate?
    private var sizeDelegate: VideoSizeDelegate?
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    private var runTask: Task<Void, Never>?
    private var ended = false

    private var client: KVMDClient?
    private var wantAudio = true
    /// What the user asked to send.
    private var wantMic = false
    private var wantCamera = false
    /// What this connection is negotiating.
    private var usingMic = false
    private var usingCamera = false
    private var cameraRequest: JanusFeatures.CameraRequest?
    private var micTrack: RTCAudioTrack?
    private var cameraTrack: RTCVideoTrack?
    private var cameraSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?

    override init() {
        videoView = RTCMTLNSVideoView(frame: .zero)
        super.init()
        let sizeDelegate = VideoSizeDelegate { [weak self] size in
            Task { @MainActor [weak self] in self?.emit(.videoSize(size)) }
        }
        self.sizeDelegate = sizeDelegate
        videoView.delegate = sizeDelegate
    }

    func start(client: KVMDClient, wantAudio: Bool, sendMic: Bool = false, sendCamera: Bool = false) {
        guard runTask == nil else { return }
        self.client = client
        self.wantAudio = wantAudio
        self.wantMic = sendMic
        self.wantCamera = sendCamera
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Changes what is sent. Takes effect by renegotiating the connection,
    /// which interrupts the video for a moment.
    func setSending(mic: Bool, camera: Bool) {
        guard mic != wantMic || camera != wantCamera else { return }
        wantMic = mic
        wantCamera = camera
        renegotiate()
    }

    func stop() {
        ended = true
        runTask?.cancel()
        runTask = nil
        cleanup()
    }

    /// Starts signalling again on a fresh session, keeping the video view.
    private func renegotiate() {
        guard !ended, client != nil else { return }
        runTask?.cancel()
        cleanup()
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func cleanup() {
        if let videoTrack { videoTrack.remove(videoView) }
        videoTrack = nil
        audioTrack = nil
        capturer?.stopCapture()
        capturer = nil
        cameraSource = nil
        cameraTrack = nil
        micTrack = nil
        usingMic = false
        usingCamera = false
        peer?.close()
        peer = nil
        peerDelegate = nil
        if let janus { Task { await janus.close() } }
        janus = nil
    }

    private func emit(_ event: Event) {
        guard !ended else { return }
        onEvent?(event)
    }

    private func finish(error: String?) {
        guard !ended else { return }
        onEvent?(.ended(error: error))
        ended = true
        cleanup()
    }

    // MARK: Signalling

    private func run() async {
        guard let client else { return }
        do {
            let janus = try JanusSession(client: client)
            self.janus = janus
            try await janus.connect()
            try await janus.requestFeatures()

            var useAudio = false
            for await event in janus.events {
                if Task.isCancelled || ended { return }
                switch event {
                case .features(let features):
                    useAudio = features.audio && wantAudio
                    emit(.audioAvailable(features.audio))
                    emit(.passthrough(mic: features.mic, camera: features.camera, cameraInUse: features.cameraRequest != nil))
                    usingMic = features.mic && wantMic
                    if usingMic, !(await Self.allowed(.audio)) {
                        usingMic = false
                        emit(.notice("PiKVM Console isn't allowed to use the microphone. Turn it on in System Settings → Privacy & Security → Microphone."))
                    }
                    cameraRequest = features.cameraRequest
                    usingCamera = features.camera && wantCamera && features.cameraRequest != nil
                    if usingCamera, !(await Self.allowed(.video)) {
                        usingCamera = false
                        emit(.notice("PiKVM Console isn't allowed to use the camera. Turn it on in System Settings → Privacy & Security → Camera."))
                    }
                    if Task.isCancelled || ended { return }
                    makePeer(iceURL: features.iceURL)
                    try await janus.watch(audio: useAudio, mic: usingMic, camera: usingCamera)
                case .offer(let sdp):
                    let answer = try await answer(toOffer: sdp, receiveAudio: useAudio)
                    try await janus.start(answerSDP: answer)
                    emit(.sending(mic: usingMic, camera: usingCamera))
                case .camera(let action):
                    // The remote machine opened or closed the virtual webcam. The web UI
                    // reconnects in these cases so the camera track can be added or dropped.
                    let relevant = wantCamera && (
                        (action == "online" && !usingCamera) || (action == "offline" && usingCamera) || action == "lost")
                    if relevant {
                        renegotiate()
                        return
                    }
                case .pluginError:
                    // Usually "no video yet": ask again shortly, like the web UI does.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled || ended { return }
                    try await janus.watch(audio: useAudio, mic: usingMic, camera: usingCamera)
                case .webrtcUp:
                    emit(.connected)
                case .hangup(let reason):
                    finish(error: reason.isEmpty ? "The video connection was closed." : reason)
                    return
                case .error(_, let reason):
                    finish(error: reason)
                    return
                default:
                    break
                }
            }
            finish(error: JanusError.closed.localizedDescription)
        } catch {
            if Task.isCancelled { return }
            finish(error: error.localizedDescription)
        }
    }

    private func makePeer(iceURL: String?) {
        guard peer == nil else { return }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        if let iceURL { config.iceServers = [RTCIceServer(urlStrings: [iceURL])] }

        let delegate = PeerDelegate()
        delegate.onCandidate = { [weak self] candidate in
            Task { @MainActor [weak self] in
                try? await self?.janus?.trickle(candidate: candidate.sdp, sdpMid: candidate.sdpMid,
                                                sdpMLineIndex: candidate.sdpMLineIndex)
            }
        }
        delegate.onGatheringComplete = { [weak self] in
            Task { @MainActor [weak self] in try? await self?.janus?.trickleCompleted() }
        }
        delegate.onTrack = { [weak self] track in
            Task { @MainActor [weak self] in self?.attach(track) }
        }
        delegate.onFailed = { [weak self] in
            Task { @MainActor [weak self] in self?.finish(error: "The video connection failed.") }
        }
        peerDelegate = delegate

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer = Self.factory.peerConnection(with: config, constraints: constraints, delegate: delegate)
    }

    private func attach(_ track: RTCMediaStreamTrack) {
        if let video = track as? RTCVideoTrack {
            videoTrack?.remove(videoView)
            videoTrack = video
            video.add(videoView)
        } else if let audio = track as? RTCAudioTrack {
            audioTrack = audio
            applyVolume()
        }
    }

    private func applyVolume() {
        guard let audioTrack else { return }
        audioTrack.isEnabled = !muted
        // WebRTC's scale is 0...10, where 1 is the original level; the app never amplifies.
        audioTrack.source.volume = muted ? 0 : max(0, min(1, volume))
    }

    private func answer(toOffer sdp: String, receiveAudio: Bool) async throws -> String {
        guard let peer else { throw JanusError.janus("no peer connection") }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        attachLocalMedia(to: peer, receiveAudio: receiveAudio)
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            peer.answer(for: constraints) { description, error in
                if let description {
                    c.resume(returning: description)
                } else {
                    c.resume(throwing: error ?? JanusError.janus("could not create an SDP answer"))
                }
            }
        }
        // Without this, Opus is decoded as mono (same workaround as the web UI).
        let stereo = answer.sdp.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1")
        let local = RTCSessionDescription(type: .answer, sdp: stereo)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(local) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        return stereo
    }
}

// MARK: Sending the Mac's microphone and camera

extension WebRTCStream {
    /// Asks for (or checks) permission to use the microphone or camera.
    fileprivate static func allowed(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    /// Puts the Mac's microphone and camera on the transceivers the PiKVM's
    /// offer created. The plugin's offer always has video as mid "v" and audio
    /// as mid "a"; they become two-way when the mic or camera was asked for.
    fileprivate func attachLocalMedia(to peer: RTCPeerConnection, receiveAudio: Bool) {
        for transceiver in peer.transceivers {
            switch transceiver.mediaType {
            case .audio where usingMic:
                let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
                let track = Self.factory.audioTrack(with: source, trackId: "mic")
                micTrack = track
                transceiver.sender.track = track
                transceiver.setDirection(receiveAudio ? .sendRecv : .sendOnly, error: nil)
            case .video where usingCamera:
                guard let track = startCamera() else {
                    usingCamera = false
                    continue
                }
                transceiver.sender.track = track
                transceiver.setDirection(.sendRecv, error: nil)
            default:
                break
            }
        }
    }

    /// Starts the Mac's camera at a size close to what the remote machine asked
    /// for, and scales it to exactly that size.
    private func startCamera() -> RTCVideoTrack? {
        guard let request = cameraRequest else { return nil }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = AVCaptureDevice.default(for: .video).flatMap({ d in devices.first { $0.uniqueID == d.uniqueID } })
                ?? devices.first else {
            emit(.notice("No camera was found on this Mac."))
            return nil
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        func size(_ f: AVCaptureDevice.Format) -> (Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (Int(d.width), Int(d.height))
        }
        // The smallest format at least as large as requested, else the largest there is.
        let bigEnough = formats.filter { size($0).0 >= request.width && size($0).1 >= request.height }
        guard let format = bigEnough.min(by: { size($0).0 * size($0).1 < size($1).0 * size($1).1 })
                ?? formats.max(by: { size($0).0 * size($0).1 < size($1).0 * size($1).1 }) else {
            emit(.notice("The camera doesn't offer a usable video format."))
            return nil
        }
        let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let fps = max(1, min(request.fps, Int(maxFPS)))

        let source = Self.factory.videoSource()
        source.adaptOutputFormat(toWidth: Int32(request.width), height: Int32(request.height), fps: Int32(fps))
        let capturer = RTCCameraVideoCapturer(delegate: source)
        capturer.startCapture(with: device, format: format, fps: fps)
        self.capturer = capturer
        cameraSource = source
        let track = Self.factory.videoTrack(with: source, trackId: "camera")
        cameraTrack = track
        return track
    }
}

/// Receives peer connection callbacks, which arrive on WebRTC's own threads.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    var onCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    var onGatheringComplete: (@Sendable () -> Void)?
    var onTrack: (@Sendable (RTCMediaStreamTrack) -> Void)?
    var onFailed: (@Sendable () -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { onFailed?() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { onGatheringComplete?() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track { onTrack?(track) }
    }
}

private final class VideoSizeDelegate: NSObject, RTCVideoViewDelegate {
    private let onSize: @Sendable (CGSize) -> Void

    init(onSize: @escaping @Sendable (CGSize) -> Void) {
        self.onSize = onSize
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        onSize(size)
    }
}
