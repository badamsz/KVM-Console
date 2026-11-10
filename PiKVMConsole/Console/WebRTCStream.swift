import AppKit
import PiKVMKit
import WebRTC

/// Receives the PiKVM's H.264 video and Opus audio over WebRTC, using the
/// Janus gateway on the device for signalling. Video is drawn into
/// `videoView`; audio plays through the Mac's default output.
@MainActor
final class WebRTCStream: NSObject {
    enum Event {
        /// The media connection is up.
        case connected
        /// The first frame arrived, or the remote resolution changed.
        case videoSize(CGSize)
        /// Whether the PiKVM offers audio (it needs an HDMI audio-capable model).
        case audioAvailable(Bool)
        /// The stream ended. `error` is nil for a normal close.
        case ended(error: String?)
    }

    let videoView: RTCMTLNSVideoView
    var onEvent: (@MainActor (Event) -> Void)?

    /// 0...1
    var volume: Double = 1 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }

    private static let factory: RTCPeerConnectionFactory = {
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

    override init() {
        videoView = RTCMTLNSVideoView(frame: .zero)
        super.init()
        let sizeDelegate = VideoSizeDelegate { [weak self] size in
            Task { @MainActor [weak self] in self?.emit(.videoSize(size)) }
        }
        self.sizeDelegate = sizeDelegate
        videoView.delegate = sizeDelegate
    }

    func start(client: KVMDClient, wantAudio: Bool) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run(client: client, wantAudio: wantAudio)
        }
    }

    func stop() {
        ended = true
        runTask?.cancel()
        runTask = nil
        cleanup()
    }

    private func cleanup() {
        if let videoTrack { videoTrack.remove(videoView) }
        videoTrack = nil
        audioTrack = nil
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

    private func run(client: KVMDClient, wantAudio: Bool) async {
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
                    makePeer(iceURL: features.iceURL)
                    try await janus.watch(audio: useAudio)
                case .offer(let sdp):
                    let answer = try await answer(toOffer: sdp)
                    try await janus.start(answerSDP: answer)
                case .pluginError:
                    // Usually "no video yet": ask again shortly, like the web UI does.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled || ended { return }
                    try await janus.watch(audio: useAudio)
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

    private func answer(toOffer sdp: String) async throws -> String {
        guard let peer else { throw JanusError.janus("no peer connection") }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
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
