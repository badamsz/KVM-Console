import AppKit
import AVFoundation
import CoreImage
import Foundation

/// Shows an Openterface's HDMI capture and plays its audio, with AVFoundation.
@MainActor
final class OpenterfaceCapture {
    enum CaptureError: LocalizedError {
        case notFound
        case cantUse(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "The Openterface's video device isn't plugged in."
            case .cantUse(let reason): return "Couldn't start the Openterface's video: \(reason)"
            }
        }
    }

    /// Holds the session for the background queue that starts and stops it.
    private final class SessionBox: @unchecked Sendable {
        let session = AVCaptureSession()
    }

    private let box = SessionBox()
    private let queue = DispatchQueue(label: "KVMConsole.OpenterfaceCapture")
    let videoDevice: AVCaptureDevice
    /// The view the video is drawn in.
    let view: CapturePreviewView
    /// The capture resolution in use.
    private(set) var videoSize: CGSize = .zero
    private(set) var frameRate = 0
    private var audioOutput: AVCaptureAudioPreviewOutput?
    private var observers: [NSObjectProtocol] = []
    /// Called once when the device goes away or capture fails.
    var onEnd: (@MainActor (String) -> Void)?

    var hasAudio: Bool { audioOutput != nil }

    /// 0...1. Zero mutes.
    var volume: Float = 1 {
        didSet { audioOutput?.volume = volume }
    }

    init(videoID: String, audioID: String?) throws {
        guard let device = AVCaptureDevice(uniqueID: videoID) else { throw CaptureError.notFound }
        videoDevice = device
        let session = box.session
        view = CapturePreviewView(session: session)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cantUse("the video device is busy.") }
            session.addInput(input)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.cantUse(error.localizedDescription)
        }
        chooseFormat(for: device)

        if let audioID, let audioDevice = AVCaptureDevice(uniqueID: audioID),
           let input = try? AVCaptureDeviceInput(device: audioDevice), session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureAudioPreviewOutput()
            output.volume = volume
            if session.canAddOutput(output) {
                session.addOutput(output)
                audioOutput = output
            }
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end("The Openterface was unplugged.") }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated { self?.end("Video stopped: \(error?.localizedDescription ?? "unknown error").") }
        })
    }

    /// Picks the largest format up to 1920×1080, then the highest frame rate.
    private func chooseFormat(for device: AVCaptureDevice) {
        func size(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let candidates = device.formats.filter { size($0).width <= 1920 && size($0).height <= 1080 }
        let best = candidates.max { a, b in
            let areaA = Int(size(a).width) * Int(size(a).height), areaB = Int(size(b).width) * Int(size(b).height)
            return areaA != areaB ? areaA < areaB : maxRate(a) < maxRate(b)
        }
        if let best, (try? device.lockForConfiguration()) != nil {
            device.activeFormat = best
            if let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                device.activeVideoMinFrameDuration = range.minFrameDuration
            }
            device.unlockForConfiguration()
        }
        let format = device.activeFormat
        let dims = size(format)
        videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        frameRate = Int(maxRate(format).rounded())
    }

    func start() {
        let box = self.box
        queue.async { box.session.startRunning() }
    }

    func stop() {
        onEnd = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let box = self.box
        queue.async { box.session.stopRunning() }
    }

    private func end(_ reason: String) {
        let handler = onEnd
        onEnd = nil
        handler?(reason)
    }

    // MARK: Permissions

    /// Asks for camera access if it hasn't been decided. Returns whether it's allowed.
    static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    // MARK: Snapshot

    /// Takes one picture from the capture device, for the machine's screen preview.
    static func snapshot(videoID: String) async throws -> NSImage {
        guard await requestAccess(for: .video) else {
            throw CaptureError.cantUse("allow camera access for KVM Console in System Settings > Privacy & Security > Camera.")
        }
        guard let device = AVCaptureDevice(uniqueID: videoID) else { throw CaptureError.notFound }
        let grabber = FrameGrabber()
        return try await grabber.grab(from: device)
    }
}

/// An `NSView` backed by a capture preview layer.
final class CapturePreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { previewLayer }
}

/// Runs a short capture session and returns its first good frame.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "KVMConsole.FrameGrabber")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var frames = 0

    func grab(from device: AVCaptureDevice) async throws -> NSImage {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw OpenterfaceCapture.CaptureError.cantUse("the video device is busy.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            queue.async { self.session.startRunning() }
            queue.asyncAfter(deadline: .now() + 6) {
                self.finish(.failure(OpenterfaceCapture.CaptureError.cantUse("no picture arrived.")))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        // The first frames after starting are often black or half drawn.
        guard frames > 5, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return }
        finish(.success(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))))
    }

    private func finish(_ result: Result<NSImage, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
        continuation.resume(with: result)
    }
}
