import XCTest
@testable import KVMKit

final class DirectVideoTests: XCTestCase {
    func testFrameHeader() throws {
        var message = Data([1])
        message.append(contentsOf: [0x10, 0x27, 0, 0, 0, 0, 0, 0]) // 10000 µs
        message.append(contentsOf: [0, 0, 0, 1, 0x65, 0xAA])
        let frame = try XCTUnwrap(DirectVideoFrame(message: message))
        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertEqual(frame.timestamp, 10000)
        XCTAssertEqual(frame.annexB, Data([0, 0, 0, 1, 0x65, 0xAA]))
        XCTAssertNil(DirectVideoFrame(message: Data([0, 1, 2])))
        XCTAssertFalse(try XCTUnwrap(DirectVideoFrame(message: Data([0] + [UInt8](repeating: 0, count: 8) + [9]))).isKeyFrame)
    }

    func testNALUnitsWithMixedStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])
        let units = AnnexB.nalUnits(data)
        XCTAssertEqual(units, [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5, 6])])
        XCTAssertEqual(units.map(AnnexB.type(of:)), [7, 8, 5])
    }

    func testAVCCPrefixesLengths() {
        let avcc = AnnexB.avcc([Data([0x65, 1, 2]), Data([0x41])])
        XCTAssertEqual(avcc, Data([0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 1, 0x41]))
    }

    func testVideoStatus() {
        XCTAssertEqual(NanoKVMVideoStatus(message: #"{"event":"video-status","data":"-1"}"#), .noImage)
        XCTAssertEqual(NanoKVMVideoStatus(message: #"{"event":"video-status","data":"1"}"#), .normal)
        XCTAssertNil(NanoKVMVideoStatus(message: #"{"event":"heartbeat","data":""}"#))
        XCTAssertNil(NanoKVMVideoStatus(message: "nonsense"))
    }

    func testDecoderWaitsForParameterSets() {
        let decoder = DirectVideoDecoder()
        let delta = DirectVideoFrame(message: Data([0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 1, 0x41, 0x9A]))!
        XCTAssertNil(decoder.decode(delta))
    }

    /// A 64x48 baseline keyframe (AUD, SPS, PPS, IDR) made with ffmpeg/x264.
    static let keyFrame = Data(base64Encoded: "AAAAAQkQAAAAAWdCwArZBHsBEAAAAwAQAAADACDxImSAAAAAAWjLg8sgAAABZYiEX/kXsQeKAAIHPigACAlAAtkW/0BYVrP2AA9pffSt/v5X3/+f//44APJQLeFGMLALCD65gJRJXyNnXYHG2MIAAsDpQEAAIEoAAgEDn4APQ6iWGgcuUBuv29m24AHg4BIx5OWFzGHUgLEIhGQwnIchSuXCH+Gi3f1CjMKfmDDigACA/4SAEABQABAoCEAAQOQABBGAAEKDjMzGqlKri+lIYfjMxldRW6klLWhhwxg4AAgwAACPJ/gAiNp2to//gUAAIB4AAjdg4AAgzAA5AAyq5rmk4cADKpxrRpOH54QSKU5OFnIdi43BG1/wYAAAgAwAeUqSzSV/N8UAAQEv8CqpztXf8+AucCK8CJW6O2fB6DSAncm7VNFi/+3hAAFDDgACAEEAAID4AAgHgwAByiTKCeoCF/roObvz4DK3HlI1a004hN0H2rWnabQe0P/4IsBREIZKvDf5Hhs//6MMmqZScz7/p/9gsIAORsJ2ee1jB2hjK9WQkhD+keIBgwH4AFkpxnVFOyUpX9/waAgACAIgJgIEQfHBDcHNwHQM45UPfg7mNnCPwH8dbINQEfi1U18B4Mqy8D/XIQAoABgAEhAACAgAOAWAaAYC4CdcgcABsAAEAS0oEMC5wGU8FUwcb33gCwGFAFR2omADCgAOrtSATAE7gCkXOiUDqptuCTnAcAIQ8SeDkHwoAaZ54k8OE5mpoI6mMvd19u6MWEUiU0XY48MAAQBQoXCQABACAAYASGgAEcAAIAlXIFQATAASWMr3mvAAwABAHhvkaGFAS4dAABKAAID1XIHBoACXS7Pi14EBwNikAAg94cAwBIAcvwYBFQFAIOgxwgvBxC4cHoEeYcHHRDYK/P8ZYfkGbf/vLsKj24EAQABAyAA9kIAAQBVHDg0AAkwAAgK/cgcAAlKAAICtpNxAAgABAM3ZXAAOAACAdqYFQBpAARPaiUDSADr7UiCOCb8FoYgVfng2GQhAfiiwuGgADnhl7Vrz3ehH//8MUPEP2iACEtGa2Qj8gASn+xWb5dMAAAQoCBDwiir6HfwkYDAwKHQABA0BwAqAAuUiIAPMwkBT7wW5gxy3/KoUzNiKEETcgcAwAHmkBOhdDYArcH7HEj/jYAEANI4=")!

    func testDecodesAKeyFrame() throws {
        let decoder = DirectVideoDecoder()
        let message = Data([1] + [UInt8](repeating: 0, count: 8)) + Self.keyFrame
        let image = try XCTUnwrap(decoder.decode(try XCTUnwrap(DirectVideoFrame(message: message))))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertNotNil(JPEG.data(from: image))
    }

    // MARK: H.265

    /// A 64x48 Main profile keyframe (VPS, SPS, PPS, IDR) made with ffmpeg/x265.
    static let hevcKeyFrame = Data(base64Encoded: "AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpWYCQAAAAFCAQEBYAAAAwCQAAADAAADAB6gIIMWWVmuTK8BaAgAAAMACAAAAwAIQAAAAAFEAcFz0IkAAAEoAa8TgJVv+2v0Tmsbp//X1qqTVoMKsqvserH/cZm41hZCb4PI2l/gVry8f/5vultX2m8NItKCsu60lj3p7WLbLM0tSwxyxfpEM8B3hmzpQMMzp7vWOZJJ23E/KCHPDU5WuI7W/+7/Q/yiZM9v4z76+J37fONHMe2W376S17j/kj7iikTprh2FD/C4lH6iR8ixd2+OyvUQ/1dnShPD068pFfur8IcfzaTbHA/ezKbdqcnrjD+JF9LDrclqSnArSE0YuDmllC2HhLikBwQiJeoOZGjZHniOz0nayCPMY/XPGtxMfZl5pCz7coSeF7bf8jU8G8zXjGU0PmVIwYFUk2e+OwmSDHiMAopBdswzyC77xRC2/iiMMtZGI8r23Ktor4igXIpatnJN/N4J6BBeLhSod6YSVlklbEuEtPzWyrhCVPDSIUeVxCqdfKKIQr+CO0+bZEGe364gVctFB2feq+e7oDetyt7FvSsbzN87FF9fobxWCz499/zwfRLcaEh5i/Rkr8i5yCpYljUbFhoL8uAlx+glVJTfb3Z7JxqaJ2mbFZVZ8O8KUbmREFo3J+TgWpHRZZiN3LuWiGjYCgUbE7YHGXQyXxXpqsjfWsZsM7Vy1FpXo8DYGKu/45xM7pFCsowm3S5MYfSzQ6t7rCt4QzPNJ98NdHJ1m9Asd58JqXe5iSkM3U+ivB8W634XLosvYcbjRqJwFUR614enXgNpjwgUOzfzZ+C0iB5dVs47CDNPsh2rFoonvXzZD2/Kpz1uClAAhGgFSfBOlLd0VWV6hYEIxek136HZHNrNO0pvhcOgkDObLnRTuWUc+ZM4KQ0W1z4TlxXLF+ejFEJSPzS+CC2m3JSnfGpUVKYOOA==")!

    func testHEVCNALTypes() {
        let units = AnnexB.nalUnits(Self.hevcKeyFrame)
        XCTAssertEqual(units.map(AnnexB.hevcType(of:)), [32, 33, 34, 20])
        let roles = units.map(DirectVideoCodec.h265.role(of:))
        XCTAssertEqual(roles, [.parameterSet(0), .parameterSet(1), .parameterSet(2), .slice(random: true)])
        XCTAssertEqual(DirectVideoCodec.h265.role(of: Data([0x46, 0x01])), .skip) // access unit delimiter (35)
        XCTAssertEqual(DirectVideoCodec.h265.role(of: Data([0x02, 0x01])), .slice(random: false)) // TRAIL_R (1)
        XCTAssertEqual(DirectVideoCodec.h265.role(of: Data([0x2A, 0x01])), .slice(random: true)) // CRA (21)
    }

    func testHEVCDecoderWaitsForParameterSets() {
        let decoder = DirectVideoDecoder(codec: .h265)
        let delta = DirectVideoFrame(message: Data([0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 1, 0x02, 0x01, 0xAF]))!
        XCTAssertNil(decoder.decode(delta))
    }

    func testDecodesAnHEVCKeyFrame() throws {
        let decoder = DirectVideoDecoder(codec: .h265)
        let message = Data([1] + [UInt8](repeating: 0, count: 8)) + Self.hevcKeyFrame
        let image = try XCTUnwrap(decoder.decode(try XCTUnwrap(DirectVideoFrame(message: message))))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testH264DecoderIgnoresHEVC() {
        let decoder = DirectVideoDecoder(codec: .h264)
        let message = Data([1] + [UInt8](repeating: 0, count: 8)) + Self.hevcKeyFrame
        XCTAssertNil(decoder.decode(DirectVideoFrame(message: message)!))
    }

    func testCodecPaths() {
        XCTAssertEqual(DirectVideoCodec.h264.path, "api/stream/h264/direct")
        XCTAssertEqual(DirectVideoCodec.h265.path, "api/stream/h265/direct")
        XCTAssertEqual(DirectVideoCodec.h265.directModeName, "h265-direct")
    }

    // MARK: Stream settings

    func testStreamSettingsRequests() {
        XCTAssertEqual(NanoKVMStreamSettings().requests(codec: .h264),
                       [.init(name: "video mode", path: "api/stream/mode", body: ["mode": "h264-direct"])])
        let all = NanoKVMStreamSettings(codec: .h265, rateControl: .cbr, bitrate: 50000, gop: 0, fps: 30)
        XCTAssertEqual(all.requests(codec: .h265), [
            .init(name: "video mode", path: "api/stream/mode", body: ["mode": "h265-direct"]),
            .init(name: "rate control", path: "api/stream/rate-control", body: ["mode": "cbr"]),
            .init(name: "bitrate", path: "api/stream/quality", body: ["quality": 20000]),
            .init(name: "keyframe interval", path: "api/stream/gop", body: ["gop": 1]),
            .init(name: "frame rate", path: "api/stream/fps", body: ["fps": 30]),
        ])
        // After a fallback the mode follows the codec actually streamed.
        XCTAssertEqual(all.requests(codec: .h264).first?.body, ["mode": "h264-direct"])
    }

    func testStreamSettingsDecoding() throws {
        let decoded = try JSONDecoder().decode(NanoKVMStreamSettings.self, from: Data(#"{"codec":"h265","fps":0}"#.utf8))
        XCTAssertEqual(decoded, NanoKVMStreamSettings(codec: .h265, fps: 0))
        let future = try JSONDecoder().decode(NanoKVMStreamSettings.self,
                                              from: Data(#"{"codec":"av1","rateControl":"qvbr"}"#.utf8))
        XCTAssertEqual(future, NanoKVMStreamSettings())
        let settings = NanoKVMStreamSettings(codec: .h265, rateControl: .vbr, bitrate: 6000, gop: 30, fps: 60)
        XCTAssertEqual(try JSONDecoder().decode(NanoKVMStreamSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testDeviceWithoutStreamSettingsDecodes() throws {
        let device = Device(name: "Go", model: .nanoKVMGo)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any])
        XCTAssertNil(json["nanoStream"])
        json["nanoStream"] = ["codec": "h265"]
        let withStream = try JSONDecoder().decode(Device.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(withStream.nanoStream?.codec, .h265)
    }

    // MARK: Input router

    func testRouterKeyboardMessage() {
        var router = NanoKVMInputRouter()
        let report = Data([0x02, 0, 0x04, 0, 0, 0, 0, 0])
        let msg = router.message(source: .keyboard, type: .keyboard, payload: report, timestamp: 0x01020304)
        XCTAssertEqual(msg, Data([3, 1, 1, 1, 0, 1, 0, 0, 0, 4, 3, 2, 1]) + report)
        let next = router.message(source: .keyboard, type: .keyboard, payload: report, timestamp: 0)
        XCTAssertEqual(next[5], 2)
    }

    func testRouterPointerPayloads() {
        XCTAssertEqual(NanoKVMInputRouter.absolutePointer(buttons: 1, x: 0xFFFF, y: 0x8000, wheel: -1),
                       Data([1, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0xFF]))
        XCTAssertEqual(NanoKVMInputRouter.relativePointer(buttons: 2, dx: -2, dy: 300, wheel: 1),
                       Data([2, 0xFE, 0xFF, 0x2C, 0x01, 0x01, 0x00]))
        XCTAssertEqual(NanoKVMInputRouter.widen(0), 0)
        XCTAssertEqual(NanoKVMInputRouter.widen(32767), 65535)
    }
}
