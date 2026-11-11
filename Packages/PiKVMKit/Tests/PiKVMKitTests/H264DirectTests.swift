import XCTest
@testable import PiKVMKit

final class H264DirectTests: XCTestCase {
    func testFrameHeader() throws {
        var message = Data([1])
        message.append(contentsOf: [0x10, 0x27, 0, 0, 0, 0, 0, 0]) // 10000 µs
        message.append(contentsOf: [0, 0, 0, 1, 0x65, 0xAA])
        let frame = try XCTUnwrap(H264DirectFrame(message: message))
        XCTAssertTrue(frame.isKeyFrame)
        XCTAssertEqual(frame.timestamp, 10000)
        XCTAssertEqual(frame.annexB, Data([0, 0, 0, 1, 0x65, 0xAA]))
        XCTAssertNil(H264DirectFrame(message: Data([0, 1, 2])))
        XCTAssertFalse(try XCTUnwrap(H264DirectFrame(message: Data([0] + [UInt8](repeating: 0, count: 8) + [9]))).isKeyFrame)
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
        let decoder = H264Decoder()
        let delta = H264DirectFrame(message: Data([0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 1, 0x41, 0x9A]))!
        XCTAssertNil(decoder.decode(delta))
    }

    /// A 64x48 baseline keyframe (AUD, SPS, PPS, IDR) made with ffmpeg/x264.
    static let keyFrame = Data(base64Encoded: "AAAAAQkQAAAAAWdCwArZBHsBEAAAAwAQAAADACDxImSAAAAAAWjLg8sgAAABZYiEX/kXsQeKAAIHPigACAlAAtkW/0BYVrP2AA9pffSt/v5X3/+f//44APJQLeFGMLALCD65gJRJXyNnXYHG2MIAAsDpQEAAIEoAAgEDn4APQ6iWGgcuUBuv29m24AHg4BIx5OWFzGHUgLEIhGQwnIchSuXCH+Gi3f1CjMKfmDDigACA/4SAEABQABAoCEAAQOQABBGAAEKDjMzGqlKri+lIYfjMxldRW6klLWhhwxg4AAgwAACPJ/gAiNp2to//gUAAIB4AAjdg4AAgzAA5AAyq5rmk4cADKpxrRpOH54QSKU5OFnIdi43BG1/wYAAAgAwAeUqSzSV/N8UAAQEv8CqpztXf8+AucCK8CJW6O2fB6DSAncm7VNFi/+3hAAFDDgACAEEAAID4AAgHgwAByiTKCeoCF/roObvz4DK3HlI1a004hN0H2rWnabQe0P/4IsBREIZKvDf5Hhs//6MMmqZScz7/p/9gsIAORsJ2ee1jB2hjK9WQkhD+keIBgwH4AFkpxnVFOyUpX9/waAgACAIgJgIEQfHBDcHNwHQM45UPfg7mNnCPwH8dbINQEfi1U18B4Mqy8D/XIQAoABgAEhAACAgAOAWAaAYC4CdcgcABsAAEAS0oEMC5wGU8FUwcb33gCwGFAFR2omADCgAOrtSATAE7gCkXOiUDqptuCTnAcAIQ8SeDkHwoAaZ54k8OE5mpoI6mMvd19u6MWEUiU0XY48MAAQBQoXCQABACAAYASGgAEcAAIAlXIFQATAASWMr3mvAAwABAHhvkaGFAS4dAABKAAID1XIHBoACXS7Pi14EBwNikAAg94cAwBIAcvwYBFQFAIOgxwgvBxC4cHoEeYcHHRDYK/P8ZYfkGbf/vLsKj24EAQABAyAA9kIAAQBVHDg0AAkwAAgK/cgcAAlKAAICtpNxAAgABAM3ZXAAOAACAdqYFQBpAARPaiUDSADr7UiCOCb8FoYgVfng2GQhAfiiwuGgADnhl7Vrz3ehH//8MUPEP2iACEtGa2Qj8gASn+xWb5dMAAAQoCBDwiir6HfwkYDAwKHQABA0BwAqAAuUiIAPMwkBT7wW5gxy3/KoUzNiKEETcgcAwAHmkBOhdDYArcH7HEj/jYAEANI4=")!

    func testDecodesAKeyFrame() throws {
        let decoder = H264Decoder()
        let message = Data([1] + [UInt8](repeating: 0, count: 8)) + Self.keyFrame
        let image = try XCTUnwrap(decoder.decode(try XCTUnwrap(H264DirectFrame(message: message))))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertNotNil(JPEG.data(from: image))
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
