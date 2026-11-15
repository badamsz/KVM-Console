import Foundation

/// How a NanoKVM Go (or other direct-stream NanoKVM) should encode the
/// console video. Saved per device and sent on every connect, since the
/// device keeps these only in memory and can't report them
/// (`NanoKVMClient.applyStreamSettings`). A nil setting leaves the device's
/// current value alone (whatever its web page last set, or its default).
///
/// Ranges are the device's own (NanoKVM-Pro `server/service/stream/service.go`).
public struct NanoKVMStreamSettings: Codable, Hashable, Sendable {
    public enum RateControl: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Constant bitrate.
        case cbr
        /// Variable bitrate; the device's default.
        case vbr

        public var id: String { rawValue }
        public var displayName: String { rawValue.uppercased() }

        /// The bitrate the NanoKVM web page picks when switching to this mode.
        public var suggestedBitrate: Int { self == .vbr ? 8000 : 5000 }
    }

    public var codec: DirectVideoCodec
    public var rateControl: RateControl?
    /// Kbit/s, 1000 to 20000. The device's default is 8000.
    public var bitrate: Int?
    /// Frames between keyframes, 1 to 200. The device's default is 50.
    public var gop: Int?
    /// Frames per second, 1 to 120, or 0 for automatic (the device's default).
    public var fps: Int?

    public static let bitrateRange = 1000...20000
    public static let gopRange = 1...200
    public static let fpsRange = 0...120

    public init(codec: DirectVideoCodec = .h264, rateControl: RateControl? = nil, bitrate: Int? = nil,
                gop: Int? = nil, fps: Int? = nil) {
        self.codec = codec
        self.rateControl = rateControl
        self.bitrate = bitrate
        self.gop = gop
        self.fps = fps
    }

    /// Missing keys (say, from an older build) decode as unset.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = try c.decodeIfPresent(DirectVideoCodec.self, forKey: .codec) ?? .h264
        rateControl = try? c.decodeIfPresent(RateControl.self, forKey: .rateControl)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        gop = try c.decodeIfPresent(Int.self, forKey: .gop)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps)
    }

    /// One settings call: its name for messages, its path and its JSON body.
    struct Request: Equatable {
        let name: String
        let path: String
        let body: [String: AnyHashable]
    }

    /// The calls that apply these settings, in the order the device needs:
    /// the stream mode first, and the bitrate after the rate control (whose
    /// change the web page follows with a bitrate).
    func requests(codec: DirectVideoCodec) -> [Request] {
        var out = [Request(name: "video mode", path: "api/stream/mode", body: ["mode": codec.directModeName])]
        if let rateControl {
            out.append(Request(name: "rate control", path: "api/stream/rate-control", body: ["mode": rateControl.rawValue]))
        }
        if let bitrate {
            out.append(Request(name: "bitrate", path: "api/stream/quality", body: ["quality": Self.clampBitrate(bitrate)]))
        }
        if let gop {
            out.append(Request(name: "keyframe interval", path: "api/stream/gop", body: ["gop": Self.clampGOP(gop)]))
        }
        if let fps {
            out.append(Request(name: "frame rate", path: "api/stream/fps", body: ["fps": Self.clampFPS(fps)]))
        }
        return out
    }

    static func clampBitrate(_ v: Int) -> Int { min(max(v, bitrateRange.lowerBound), bitrateRange.upperBound) }
    static func clampGOP(_ v: Int) -> Int { min(max(v, gopRange.lowerBound), gopRange.upperBound) }
    static func clampFPS(_ v: Int) -> Int { min(max(v, fpsRange.lowerBound), fpsRange.upperBound) }
}

extension DirectVideoCodec {
    /// The `/api/stream/mode` value for this codec's direct stream.
    var directModeName: String { self == .h264 ? "h264-direct" : "h265-direct" }
}
