import XCTest
@testable import PiKVMKit

final class OpenterfaceTests: XCTestCase {
    func testModelFamily() {
        XCTAssertEqual(PiKVMModel.openterface.family, .openterface)
        XCTAssertTrue(DeviceFamily.openterface.isLocal)
        XCTAssertFalse(DeviceFamily.openterface.isSipeed)
        XCTAssertTrue(DeviceFamily.nanoKVMPro.isSipeed)
        XCTAssertFalse(DeviceFamily.pikvm.isLocal)
    }

    func testDeviceDecodesWithoutLocalID() throws {
        let device = Device(name: "Desk", model: .openterface, localDeviceID: "0x14210000534d2109")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as! [String: Any]
        XCTAssertEqual(try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(device)).localDeviceID, "0x14210000534d2109")
        json.removeValue(forKey: "localDeviceID")
        let old = try JSONDecoder().decode(Device.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.localDeviceID)
    }

    func testCaptureUniqueID() throws {
        let parsed = try XCTUnwrap(OpenterfaceHardware.parseCaptureUniqueID("0x14210000534d2109"))
        XCTAssertEqual(parsed.location, 0x1421_0000)
        XCTAssertEqual(parsed.id, .init(vendor: 0x534D, product: 0x2109))
        XCTAssertNil(OpenterfaceHardware.parseCaptureUniqueID("FaceTime HD Camera"))
        XCTAssertTrue(OpenterfaceHardware.isVideoCapture(uniqueID: "0x1100000345f2132", modelID: ""))
        XCTAssertTrue(OpenterfaceHardware.isVideoCapture(uniqueID: "abc", modelID: "UVC Camera VendorID_21325 ProductID_8457"))
        XCTAssertFalse(OpenterfaceHardware.isVideoCapture(uniqueID: "0x14100000046d0825", modelID: "UVC Camera VendorID_1133 ProductID_2085"))
    }

    func testHubPairing() {
        XCTAssertEqual(OpenterfaceHardware.parentLocation(of: 0x1421_0000), 0x1420_0000)
        XCTAssertEqual(OpenterfaceHardware.parentLocation(of: 0x1420_0000), 0x1400_0000)
        XCTAssertNil(OpenterfaceHardware.parentLocation(of: 0x1400_0000))
        XCTAssertTrue(OpenterfaceHardware.shareHub(0x1421_0000, 0x1422_0000))
        XCTAssertFalse(OpenterfaceHardware.shareHub(0x1421_0000, 0x1432_0000))
        XCTAssertEqual(OpenterfaceHardware.audioLocationTag(0x1421_0000), "14210000")
        // A USB 3 hub: capture chip on the SuperSpeed bus, serial on the USB 2 bus.
        XCTAssertTrue(OpenterfaceHardware.sharePortPath(0x0111_0000, 0x0012_0000))
        XCTAssertFalse(OpenterfaceHardware.sharePortPath(0x0111_0000, 0x0022_0000))
        XCTAssertFalse(OpenterfaceHardware.shareHub(0x0111_0000, 0x0012_0000))
        // Two devices plugged straight into different buses aren't paired.
        XCTAssertFalse(OpenterfaceHardware.sharePortPath(0x0110_0000, 0x0020_0000))
    }

    func testSDCard() throws {
        XCTAssertEqual([UInt8](CH9329.sdCard(.target)), [0x57, 0xAB, 0x00, 0x17, 0x05, 0, 0, 0, 0, 0x01, 0x1F])
        XCTAssertEqual([UInt8](CH9329.sdCard(nil)), [0x57, 0xAB, 0x00, 0x17, 0x05, 0, 0, 0, 0, 0x03, 0x21])
        var parser = CH9329.Parser()
        let answer: [UInt8] = [0x57, 0xAB, 0x00, 0x97, 0x01, 0x00]
        let response = try XCTUnwrap(parser.feed(Data(answer + [CH9329.checksum(answer)])).first)
        XCTAssertEqual(CH9329.SDCardSide(response), .host)
        XCTAssertNil(CH9329.Info(response))
    }

    func testFrames() {
        XCTAssertEqual([UInt8](CH9329.getInfo), [0x57, 0xAB, 0x00, 0x01, 0x00, 0x03])
        var keyboard = HIDReport.Keyboard()
        _ = keyboard.update(webCode: "ShiftLeft", down: true)
        let report = keyboard.update(webCode: "KeyA", down: true)!
        XCTAssertEqual([UInt8](CH9329.keyboard(report)),
                       [0x57, 0xAB, 0x00, 0x02, 0x08, 0x02, 0x00, 0x04, 0, 0, 0, 0, 0, 0x12])
        XCTAssertEqual([UInt8](CH9329.absoluteMouse(buttons: 1, x: 4095, y: 0x0800, wheel: -1)),
                       [0x57, 0xAB, 0x00, 0x04, 0x07, 0x02, 0x01, 0xFF, 0x0F, 0x00, 0x08, 0xFF, 0x25])
        XCTAssertEqual([UInt8](CH9329.relativeMouse(buttons: 2, dx: -300, dy: 5)),
                       [0x57, 0xAB, 0x00, 0x05, 0x05, 0x01, 0x02, 0x81, 0x05, 0x00, 0x95])
        XCTAssertEqual(OpenterfaceHardware.absoluteCoordinate(32767), 4095)
        XCTAssertEqual(OpenterfaceHardware.absoluteCoordinate(0), 0)
    }

    func testParser() throws {
        var parser = CH9329.Parser()
        // Noise, then an info answer split across two reads, then a keyboard ack.
        let info: [UInt8] = [0x57, 0xAB, 0x00, 0x81, 0x08, 0x30, 0x01, 0x02, 0, 0, 0, 0, 0]
        let infoFrame = info + [CH9329.checksum(info)]
        let ack: [UInt8] = [0x57, 0xAB, 0x00, 0x82, 0x01, 0x00]
        let ackFrame = ack + [CH9329.checksum(ack)]
        XCTAssertTrue(parser.feed(Data([0x00, 0x13] + infoFrame.prefix(7))).isEmpty)
        let responses = parser.feed(Data(infoFrame.dropFirst(7) + ackFrame))
        XCTAssertEqual(responses.count, 2)
        let decoded = try XCTUnwrap(CH9329.Info(responses[0]))
        XCTAssertEqual(decoded.version, 0x30)
        XCTAssertTrue(decoded.targetConnected)
        XCTAssertTrue(decoded.capsLock)
        XCTAssertFalse(decoded.numLock)
        XCTAssertEqual(responses[1].answers, CH9329.Command.keyboard.rawValue)
        XCTAssertFalse(responses[1].isError)

        // A corrupted frame is skipped.
        var bad = ackFrame
        bad[bad.count - 1] &+= 1
        XCTAssertTrue(parser.feed(Data(bad)).isEmpty)
        XCTAssertEqual(parser.feed(Data(ackFrame)).count, 1)
    }

    func testUSTyping() {
        XCTAssertEqual(USKeyboardTyping.stroke(for: "a"), .init(code: "KeyA", shift: false))
        XCTAssertEqual(USKeyboardTyping.stroke(for: "Q"), .init(code: "KeyQ", shift: true))
        XCTAssertEqual(USKeyboardTyping.stroke(for: "7"), .init(code: "Digit7", shift: false))
        XCTAssertEqual(USKeyboardTyping.stroke(for: "?"), .init(code: "Slash", shift: true))
        XCTAssertEqual(USKeyboardTyping.stroke(for: "\n"), .init(code: "Enter", shift: false))
        XCTAssertNil(USKeyboardTyping.stroke(for: "é"))
    }
}
