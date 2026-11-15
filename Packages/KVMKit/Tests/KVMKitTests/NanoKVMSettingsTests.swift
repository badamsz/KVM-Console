import XCTest
@testable import KVMKit

final class NanoKVMSettingsTests: XCTestCase {
    private let base = URL(string: "http://nanokvm.local")!

    private func ok() -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T? {
        try NanoKVMClient.decode(T.self, data: Data(#"{"code":0,"msg":"success","data":\#(json)}"#.utf8), response: ok())
    }

    func testClassicVirtualDevices() throws {
        let devices = try XCTUnwrap(decode(NanoKVMVirtualDevices.self, #"{"network":true,"media":false,"disk":false}"#))
        var s = NanoKVMSettings()
        s.apply(devices, family: .nanoKVM)
        XCTAssertEqual(s.usbNetwork, true)
        XCTAssertEqual(s.usbDisk, false)
        XCTAssertNil(s.usbMicrophone)
        XCTAssertNil(s.proDisk)
    }

    func testProVirtualDevices() throws {
        let json = #"{"isNetworkEnabled":false,"isMicEnabled":true,"mountedDisk":"sdcard","isEmmcExist":false,"isSdCardExist":true}"#
        let devices = try XCTUnwrap(decode(NanoKVMVirtualDevices.self, json))
        var s = NanoKVMSettings()
        s.apply(devices, family: .nanoKVMPro)
        XCTAssertEqual(s.usbNetwork, false)
        XCTAssertEqual(s.usbMicrophone, true)
        XCTAssertNil(s.usbDisk)
        XCTAssertEqual(s.proDisk, .sdCard)
        XCTAssertEqual(s.proDiskChoices, [.off, .emmc, .sdCard])
        XCTAssertFalse(s.emmcImageExists)
    }

    func testProWithoutSDCardOffersOffAndEMMC() throws {
        let json = #"{"isNetworkEnabled":true,"isMicEnabled":false,"mountedDisk":"","isEmmcExist":true,"isSdCardExist":false}"#
        var s = NanoKVMSettings()
        s.apply(try XCTUnwrap(decode(NanoKVMVirtualDevices.self, json)), family: .nanoKVMPro)
        XCTAssertEqual(s.proDisk, .off)
        XCTAssertEqual(s.proDiskChoices, [.off, .emmc])
        XCTAssertTrue(s.emmcImageExists)
    }

    func testJiggler() throws {
        var s = NanoKVMSettings()
        s.apply(try XCTUnwrap(decode(NanoKVMJigglerData.self, #"{"enabled":false,"mode":"relative"}"#)))
        XCTAssertEqual(s.jiggler, .off)
        s.apply(try XCTUnwrap(decode(NanoKVMJigglerData.self, #"{"enabled":true,"mode":"absolute"}"#)))
        XCTAssertEqual(s.jiggler, .absolute)
        s.apply(try XCTUnwrap(decode(NanoKVMJigglerData.self, #"{"enabled":true,"mode":""}"#)))
        XCTAssertEqual(s.jiggler, .relative)
    }

    func testHDMIStateWithAndWithoutIdleTimeout() throws {
        let new = try XCTUnwrap(decode(NanoKVMHDMIState.self, #"{"enabled":true,"signal":true,"idleTimeout":30}"#))
        XCTAssertEqual(new.idleTimeout, 30)
        let old = try XCTUnwrap(decode(NanoKVMHDMIState.self, #"{"enabled":false}"#))
        XCTAssertNil(old.idleTimeout)
        XCTAssertFalse(old.enabled)
    }

    func testOLEDAndEDID() throws {
        XCTAssertEqual(try decode(NanoKVMOLED.self, #"{"exist":true,"type":"lcd","sleep":60}"#)?.sleep, 60)
        XCTAssertEqual(try decode(NanoKVMOLED.self, #"{"exist":false,"sleep":0}"#)?.exist, false)
        XCTAssertEqual(try decode(NanoKVMEDIDData.self, #"{"edid":"E54-1080P60FPS"}"#)?.edid, "E54-1080P60FPS")
        XCTAssertEqual(try decode(NanoKVMEDIDList.self, #"{"edidList":["mine.bin"]}"#)?.edidList, ["mine.bin"])
        XCTAssertEqual(try decode(NanoKVMEDIDList.self, #"{"edidList":null}"#)?.edidList, nil)
    }

    func testHIDModeValues() {
        XCTAssertEqual(NanoKVMHIDMode(rawValue: "normal"), .normal)
        XCTAssertEqual(NanoKVMHIDMode(rawValue: "hid-only"), .hidOnly)
    }

    func testHostnameValidation() {
        XCTAssertTrue(NanoKVMSettings.isValidHostname("nanokvm-office2"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname(""))
        XCTAssertFalse(NanoKVMSettings.isValidHostname("-nano"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname("nano-"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname("nano kvm"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname("nano.local"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname("nanö"))
        XCTAssertFalse(NanoKVMSettings.isValidHostname(String(repeating: "a", count: 64)))
    }

    func testRequestKeepsATrailingSlash() throws {
        let client = NanoKVMClient(baseURL: base, family: .nanoKVM, username: "admin", password: "admin",
                                   trust: TrustPolicy(pinnedSHA256: nil, requireCertificateAuthority: false))
        XCTAssertEqual(try client.makeRequest("api/vm/mouse-jiggler/").url?.absoluteString,
                       "http://nanokvm.local/api/vm/mouse-jiggler/")
        XCTAssertEqual(try client.makeRequest("api/vm/mouse-jiggler").url?.absoluteString,
                       "http://nanokvm.local/api/vm/mouse-jiggler")
    }

    func testSipeedDevicesCanBeConfigured() {
        XCTAssertTrue(DeviceFamily.pikvm.supportsConfigurationEditing)
        XCTAssertTrue(DeviceFamily.nanoKVM.supportsConfigurationEditing)
        XCTAssertTrue(DeviceFamily.nanoKVMPro.supportsConfigurationEditing)
        XCTAssertFalse(DeviceFamily.openterface.supportsConfigurationEditing)
    }

    func testGoEDIDs() {
        XCTAssertEqual(NanoKVMEDID.builtIn(current: "nanokvm-go-2560x1440-60", isGo: false), NanoKVMEDID.go)
        XCTAssertEqual(NanoKVMEDID.builtIn(current: "", isGo: true), NanoKVMEDID.go)
        XCTAssertEqual(NanoKVMEDID.builtIn(current: "E54-1080P60FPS", isGo: false), NanoKVMEDID.pro)
        XCTAssertTrue(NanoKVMEDID.go.contains { $0.id == "nanokvm-go-2560x1440-60" && $0.label == "2560 × 1440, 60 Hz" })
        XCTAssertEqual(NanoKVMEDID.go.count, 5)
    }

    func testEDIDLabels() {
        XCTAssertEqual(NanoKVMEDID.label(for: "nanokvm-go-3840x2160-30"), "3840 × 2160, 30 Hz")
        XCTAssertEqual(NanoKVMEDID.label(for: "E63-Ultrawide"), "3440 × 1440, 60 Hz")
        XCTAssertNil(NanoKVMEDID.label(for: "mine.bin"))
    }
}
