import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// H.264 or H.265 video from a NanoKVM's `/api/stream/h264/direct` or
// `/api/stream/h265/direct` websocket. Newer Sipeed firmware (NanoKVM Go)
// has no MJPEG stream, only these and WebRTC. The NanoKVM Pro and Go encode
// one stream type at a time: opening either socket switches the encoder to
// that codec, and a socket of the other codec gets no more frames.
//
// Each binary message is one encoded frame, the same for both codecs:
//   byte 0      1 for a keyframe, else 0
//   bytes 1-8   timestamp in microseconds, unsigned little endian
//   bytes 9...  the frame as Annex B NAL units (start-code separated)
// Text messages are JSON notices, e.g. `{"event":"video-status","data":"-1"}`.
// (The NanoKVM Pro source only sends them on the H.264 socket.)

/// The codec of a NanoKVM's direct video stream.
public enum DirectVideoCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264
    case h265

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        }
    }

    /// The websocket's path on the device.
    var path: String {
        switch self {
        case .h264: return "api/stream/h264/direct"
        case .h265: return "api/stream/h265/direct"
        }
    }

    /// An unknown value (say, from a newer build) decodes as H.264.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DirectVideoCodec(rawValue: raw) ?? .h264
    }
}

/// One message of a direct video stream.
public struct DirectVideoFrame: Equatable, Sendable {
    public let isKeyFrame: Bool
    public let timestamp: UInt64
    public let annexB: Data

    /// Parses a binary message. Nil when it is too short to hold a frame.
    public init?(message: Data) {
        guard message.count > 9 else { return nil }
        let bytes = [UInt8](message.prefix(9))
        isKeyFrame = bytes[0] == 1
        var ts: UInt64 = 0
        for i in 0..<8 { ts |= UInt64(bytes[1 + i]) << (8 * UInt64(i)) }
        timestamp = ts
        annexB = Data(message.dropFirst(9))
    }
}

/// The NanoKVM's video status, sent as `{"event":"video-status","data":"<n>"}`.
public enum NanoKVMVideoStatus: Int, Sendable {
    case normal = 1
    case noImage = -1
    case encoderError = -2
    case bufferFull = -3
    case inconsistentVideoMode = -4
    case captureDisabled = -5

    /// Reads a text message; nil for anything else.
    public init?(message: String) {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["event"] as? String == "video-status",
              let raw = object["data"] as? String, let value = Int(raw) else { return nil }
        self.init(rawValue: value)
    }
}

public enum AnnexB {
    /// Splits Annex B data into NAL units, without their start codes.
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    // A 4-byte start code leaves a zero at the end of the previous unit.
                    var end = i
                    while end > s, bytes[end - 1] == 0 { end -= 1 }
                    if end > s { units.append(Data(bytes[s..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Data(bytes[s...])) }
        return units
    }

    /// The H.264 NAL unit type (low five bits of the first byte).
    public static func type(of unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1F
    }

    /// The H.265 NAL unit type (bits 1-6 of the first byte).
    public static func hevcType(of unit: Data) -> UInt8 {
        ((unit.first ?? 0) >> 1) & 0x3F
    }

    /// Length-prefixed (AVCC) form of the units, as VideoToolbox decodes.
    public static func avcc(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}

/// What a decoder needs to know about one NAL unit.
enum NALRole: Equatable {
    /// A parameter set, by its index in the format description (H.264: SPS,
    /// PPS; H.265: VPS, SPS, PPS).
    case parameterSet(Int)
    /// Dropped: access unit delimiters.
    case skip
    /// Slice data; `random` when decoding can start here.
    case slice(random: Bool)
}

extension DirectVideoCodec {
    var parameterSetCount: Int { self == .h264 ? 2 : 3 }

    func role(of unit: Data) -> NALRole {
        switch self {
        case .h264:
            switch AnnexB.type(of: unit) {
            case 7: return .parameterSet(0)
            case 8: return .parameterSet(1)
            case 9: return .skip
            case 5: return .slice(random: true)
            default: return .slice(random: false)
            }
        case .h265:
            switch AnnexB.hevcType(of: unit) {
            case 32: return .parameterSet(0)
            case 33: return .parameterSet(1)
            case 34: return .parameterSet(2)
            case 35: return .skip
            // IRAP pictures: BLA, IDR and CRA (16-21), plus the reserved 22-23.
            case 16...23: return .slice(random: true)
            default: return .slice(random: false)
            }
        }
    }
}

/// Decodes H.264 or H.265 Annex B frames to images with VideoToolbox. Not
/// thread safe: feed it from one queue.
public final class DirectVideoDecoder {
    public let codec: DirectVideoCodec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data?]
    private var waitingForKeyFrame = true

    public init(codec: DirectVideoCodec = .h264) {
        self.codec = codec
        parameterSets = Array(repeating: nil, count: codec.parameterSetCount)
    }

    deinit { invalidate() }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// Decodes one frame. Returns nil until a keyframe with its parameter
    /// sets has arrived, and for frames that fail to decode.
    public func decode(_ frame: DirectVideoFrame) -> CGImage? {
        var units: [Data] = []
        var newSets = parameterSets
        var hasRandomAccess = false
        for unit in AnnexB.nalUnits(frame.annexB) {
            switch codec.role(of: unit) {
            case .parameterSet(let index): newSets[index] = unit
            case .skip: break
            case .slice(let random):
                units.append(unit)
                if random { hasRandomAccess = true }
            }
        }
        if newSets != parameterSets {
            parameterSets = newSets
            invalidate()
            let complete = newSets.compactMap { $0 }
            format = complete.count == newSets.count ? Self.makeFormat(codec: codec, parameterSets: complete) : nil
        }
        if waitingForKeyFrame {
            guard hasRandomAccess || frame.isKeyFrame else { return nil }
        }
        guard let format, !units.isEmpty else { return nil }
        if session == nil { session = Self.makeSession(format: format) }
        guard let session, let sample = Self.makeSample(AnnexB.avcc(units), format: format) else { return nil }

        var image: CGImage?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
            image = cgImage
        }
        if status != noErr {
            // Start over from the next keyframe, e.g. after a dropped frame.
            invalidate()
            waitingForKeyFrame = true
            return nil
        }
        if image != nil { waitingForKeyFrame = false }
        return image
    }

    private static func makeFormat(codec: DirectVideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        // Copied into one buffer so the pointers stay valid for the call.
        let buffers = parameterSets.map { [UInt8]($0) }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: buffers.reduce(0) { $0 + $1.count })
        defer { storage.deallocate() }
        var pointers: [UnsafePointer<UInt8>] = []
        var offset = 0
        for bytes in buffers {
            (storage + offset).initialize(from: bytes, count: bytes.count)
            pointers.append(UnsafePointer(storage + offset))
            offset += bytes.count
        }
        let sizes = buffers.map(\.count)
        var format: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    private static func makeSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        return status == noErr ? session : nil
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: data.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}

/// Reads a NanoKVM's direct H.264 or H.265 stream and delivers decoded frames.
public final class DirectVideoStreamer: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CGImage) -> Void
    public typealias StatusHandler = @Sendable (NanoKVMVideoStatus) -> Void
    public typealias EndHandler = @Sendable (Error?) -> Void

    public let codec: DirectVideoCodec
    private let socket: URLSessionWebSocketTask
    private let onFrame: FrameHandler
    private let onStatus: StatusHandler
    private let onEnd: EndHandler
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    public init(client: NanoKVMClient, codec: DirectVideoCodec = .h264, onFrame: @escaping FrameHandler,
                onStatus: @escaping StatusHandler = { _ in }, onEnd: @escaping EndHandler) throws {
        self.codec = codec
        self.socket = try client.directVideoSocket(codec)
        self.onFrame = onFrame
        self.onStatus = onStatus
        self.onEnd = onEnd
    }

    public func start() {
        socket.resume()
        let socket = self.socket
        let codec = self.codec
        task = Task.detached { [weak self] in
            let decoder = DirectVideoDecoder(codec: codec)
            defer { decoder.invalidate() }
            do {
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .data(let data):
                        if let frame = DirectVideoFrame(message: data), let image = decoder.decode(frame) {
                            self?.onFrame(image)
                        }
                    case .string(let text):
                        if let status = NanoKVMVideoStatus(message: text) { self?.onStatus(status) }
                    @unknown default:
                        break
                    }
                }
            } catch {
                guard let self, !self.isStopped else { return }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                switch status {
                case 401, 403: self.onEnd(KVMDError.unauthorized)
                case let code? where !(200..<300).contains(code) && code != 101: self.onEnd(KVMDError.http(code))
                default: self.onEnd(error)
                }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        task?.cancel()
        task = nil
        socket.cancel(with: .goingAway, reason: nil)
    }
}

enum JPEG {
    /// Encodes an image as JPEG, for previews.
    static func data(from image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
