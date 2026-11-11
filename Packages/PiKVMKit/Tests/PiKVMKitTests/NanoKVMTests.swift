import XCTest
@testable import PiKVMKit

final class NanoKVMTests: XCTestCase {
    // MARK: Models

    func testModelFamilies() {
        XCTAssertEqual(PiKVMModel.v4Plus.family, .pikvm)
        XCTAssertEqual(PiKVMModel.nanoKVM.family, .nanoKVM)
        XCTAssertEqual(PiKVMModel.nanoKVMPro.family, .nanoKVMPro)
        XCTAssertEqual(PiKVMModel.nanoKVMGo.family, .nanoKVMPro)
        XCTAssertFalse(DeviceFamily.pikvm.isSipeed)
        XCTAssertTrue(DeviceFamily.nanoKVM.isSipeed)
    }

    func testSipeedModelsRoundTrip() throws {
        let device = Device(name: "Nano", model: .nanoKVMGo, endpoints: [Endpoint(label: "LAN", host: "10.0.0.9")])
        let decoded = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(device))
        XCTAssertEqual(decoded.model, .nanoKVMGo)
        XCTAssertEqual(decoded.family, .nanoKVMPro)
    }

    func testCandidateURLsTryHTTPSThenHTTP() {
        let lan = Endpoint(label: "LAN", host: "192.168.1.60")
        let device = Device(name: "Nano", model: .nanoKVM, endpoints: [lan])
        XCTAssertEqual(NanoKVMConnectionResolver.candidateURLs(for: lan, device: device).map(\.absoluteString),
                       ["https://192.168.1.60", "http://192.168.1.60"])
    }

    func testCandidateURLsStayOnHTTPSOnceACertificateIsKnown() {
        let lan = Endpoint(label: "LAN", host: "192.168.1.60")
        var device = Device(name: "Nano", model: .nanoKVMPro, endpoints: [lan])
        device.learnCertificate(sha256: "ab", trustedByCA: false)
        XCTAssertEqual(NanoKVMConnectionResolver.candidateURLs(for: lan, device: device).map(\.absoluteString),
                       ["https://192.168.1.60"])
    }

    func testCandidateURLsKeepAnExplicitScheme() {
        let lan = Endpoint(label: "LAN", host: "http://nanokvm.local:8080")
        let device = Device(name: "Nano", model: .nanoKVM, endpoints: [lan])
        XCTAssertEqual(NanoKVMConnectionResolver.candidateURLs(for: lan, device: device).map(\.absoluteString),
                       ["http://nanokvm.local:8080"])
    }

    // MARK: Password wrapping

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

    func testKeyDerivationMatchesOpenSSL() {
        // openssl enc -aes-256-cbc -md md5 -S 0102030405060708 -k nanokvm-sipeed-2024 -P
        let (key, iv) = NanoKVMPassword.deriveKeyAndIV(passphrase: Array("nanokvm-sipeed-2024".utf8),
                                                       salt: [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(hex(key), "42C3FE5FE864EE325657646AE8C9D363BA0B3496E5A88C44BA6CE6EEA6C952FE")
        XCTAssertEqual(hex(iv), "116C9A4F3B5668E5F13C47B174267D36")
    }

    func testEncryptMatchesOpenSSL() {
        // printf admin | openssl enc -aes-256-cbc -md md5 -S 0908070605040302 -k nanokvm-sipeed-2024 -a,
        // with the "Salted__" header CryptoJS adds.
        XCTAssertEqual(NanoKVMPassword.encrypt("admin", salt: [9, 8, 7, 6, 5, 4, 3, 2]),
                       "U2FsdGVkX18JCAcGBQQDAkuMvZcc2cz/8vyB6fKnDDw=")
    }

    func testPasswordWrapRoundTrips() {
        let encrypted = NanoKVMPassword.encrypt("s3cret pässword", salt: [9, 8, 7, 6, 5, 4, 3, 2])
        XCTAssertTrue(encrypted.hasPrefix("U2FsdGVkX1")) // base64 of "Salted__"
        XCTAssertEqual(NanoKVMPassword.decrypt(encrypted), "s3cret pässword")
    }

    func testWrapIsURLEncoded() {
        let wrapped = NanoKVMPassword.wrap("admin")
        XCTAssertFalse(wrapped.contains("+"))
        XCTAssertFalse(wrapped.contains("/"))
        XCTAssertFalse(wrapped.contains("="))
        XCTAssertEqual(NanoKVMPassword.decrypt(wrapped.removingPercentEncoding ?? ""), "admin")
    }

    // MARK: Login answers

    private let base = URL(string: "http://nanokvm.local")!

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testLoginTokenFromBody() throws {
        let body = Data(#"{"code":0,"msg":"success","data":{"token":"jwt-1"}}"#.utf8)
        XCTAssertEqual(try NanoKVMClient.parseLogin(data: body, response: response(200), baseURL: base), "jwt-1")
    }

    func testLoginTokenFromCookie() throws {
        let body = Data(#"{"code":0,"msg":"success","data":null}"#.utf8)
        let r = response(200, headers: ["Set-Cookie": "nano-kvm-token=jwt-2; Path=/; Max-Age=2678400; HttpOnly; SameSite=Strict"])
        XCTAssertEqual(try NanoKVMClient.parseLogin(data: body, response: r, baseURL: base), "jwt-2")
    }

    func testLoginWrongPassword() {
        let body = Data(#"{"code":-2,"msg":"invalid username or password","data":null}"#.utf8)
        XCTAssertThrowsError(try NanoKVMClient.parseLogin(data: body, response: response(200), baseURL: base)) { error in
            guard case KVMDError.unauthorized = error else { return XCTFail("\(error)") }
        }
    }

    func testLoginNotANanoKVM() {
        XCTAssertThrowsError(try NanoKVMClient.parseLogin(data: Data("<html>".utf8), response: response(200), baseURL: base))
    }

    func testEnvelopeError() {
        let body = Data(#"{"code":-3,"msg":"operation failed","data":null}"#.utf8)
        XCTAssertThrowsError(try NanoKVMClient.decode(NanoKVMLEDs.self, data: body, response: response(200))) { error in
            XCTAssertEqual(error.localizedDescription, "operation failed")
        }
    }

    func testDecodeLEDs() throws {
        let body = Data(#"{"code":0,"msg":"success","data":{"pwr":true,"hdd":false}}"#.utf8)
        let leds = try NanoKVMClient.decode(NanoKVMLEDs.self, data: body, response: response(200))
        XCTAssertEqual(leds, NanoKVMLEDs(pwr: true, hdd: false))
    }

    // MARK: HID reports

    func testKeyboardReports() {
        var kb = HIDReport.Keyboard()
        XCTAssertEqual(kb.update(webCode: "ShiftLeft", down: true), Data([0x02, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(kb.update(webCode: "KeyA", down: true), Data([0x02, 0, 0x04, 0, 0, 0, 0, 0]))
        XCTAssertNil(kb.update(webCode: "KeyA", down: true), "repeat of a held key sends nothing")
        XCTAssertEqual(kb.update(webCode: "Digit1", down: true), Data([0x02, 0, 0x04, 0x1E, 0, 0, 0, 0]))
        XCTAssertEqual(kb.update(webCode: "KeyA", down: false), Data([0x02, 0, 0x1E, 0, 0, 0, 0, 0]))
        XCTAssertEqual(kb.reset(), Data(repeating: 0, count: 8))
    }

    func testKeyboardIgnoresASeventhKey() {
        var kb = HIDReport.Keyboard()
        for code in ["KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF"] { _ = kb.update(webCode: code, down: true) }
        XCTAssertNil(kb.update(webCode: "KeyG", down: true))
        XCTAssertEqual(kb.keys.count, 6)
    }

    func testEveryMacKeyHasAHIDUsage() {
        for code in KeyMap.table.values {
            XCTAssertNotNil(HIDReport.usage(forWebCode: code), code)
        }
    }

    func testUsageSpotChecks() {
        XCTAssertEqual(HIDReport.usage(forWebCode: "KeyZ"), 0x1D)
        XCTAssertEqual(HIDReport.usage(forWebCode: "Digit0"), 0x27)
        XCTAssertEqual(HIDReport.usage(forWebCode: "F12"), 0x45)
        XCTAssertEqual(HIDReport.usage(forWebCode: "F13"), 0x68)
        XCTAssertEqual(HIDReport.usage(forWebCode: "Numpad0"), 0x62)
        XCTAssertEqual(HIDReport.usage(forWebCode: "ArrowUp"), 0x52)
        XCTAssertEqual(HIDReport.usage(forWebCode: "MetaRight"), 0xE7)
    }

    func testMouseReports() {
        XCTAssertEqual(HIDReport.relativeMouse(buttons: 1, dx: -1, dy: 200, wheel: 1), Data([1, 0xFF, 127, 1]))
        XCTAssertEqual(HIDReport.absoluteMouse(buttons: 2, x: 0x1234, y: 40000), Data([2, 0x34, 0x12, 0xFF, 0x7F, 0]))
        XCTAssertEqual(NanoKVMMessage.mouse(HIDReport.relativeMouse(buttons: 0)), Data([2, 0, 0, 0, 0]))
        XCTAssertEqual(NanoKVMMessage.keyboard(HIDReport.Keyboard().report).count, 9)
    }

    func testAbsolutePosition() {
        let topLeft = HIDReport.absolutePosition(x: 0, y: 0, videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(topLeft?.x, 0)
        XCTAssertEqual(topLeft?.y, 0)
        let bottomRight = HIDReport.absolutePosition(x: 1919, y: 1079, videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(bottomRight?.x, 32767)
        XCTAssertEqual(bottomRight?.y, 32767)
        XCTAssertNil(HIDReport.absolutePosition(x: 0, y: 0, videoWidth: 0, videoHeight: 0))
    }

    // MARK: Adapters

    func testMSDFromNanoKVM() {
        let state = MSDState(nanoKVMImages: ["/data/b.iso", "/data/a.img"],
                             mounted: NanoKVMMountedImage(file: "/data/b.iso", cdrom: nil), cdrom: true)
        XCTAssertEqual(state.images.map(\.name), ["/data/a.img", "/data/b.iso"])
        XCTAssertEqual(state.drive?.connected, true)
        XCTAssertEqual(state.drive?.cdrom, true)
        XCTAssertEqual(state.drive?.image?.name, "/data/b.iso")

        let empty = MSDState(nanoKVMImages: [], mounted: NanoKVMMountedImage(file: "", cdrom: false), cdrom: false)
        XCTAssertEqual(empty.drive?.connected, false)
    }

    func testPowerActionsBecomeButtonPresses() {
        XCTAssertEqual(ATXPowerAction.on.nanoKVMPress(powerIsOn: true), .none)
        XCTAssertEqual(ATXPowerAction.on.nanoKVMPress(powerIsOn: false), .power(milliseconds: 800))
        XCTAssertEqual(ATXPowerAction.off.nanoKVMPress(powerIsOn: false), .none)
        XCTAssertEqual(ATXPowerAction.off.nanoKVMPress(powerIsOn: true), .power(milliseconds: 800))
        XCTAssertEqual(ATXPowerAction.offHard.nanoKVMPress(powerIsOn: true), .power(milliseconds: 8000))
        XCTAssertEqual(ATXPowerAction.resetHard.nanoKVMPress(powerIsOn: nil), .reset)
        XCTAssertEqual(ATXButton.powerLong.nanoKVMPress, .power(milliseconds: 8000))
    }
}
