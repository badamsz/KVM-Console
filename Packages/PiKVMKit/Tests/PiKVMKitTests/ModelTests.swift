import XCTest
@testable import PiKVMKit

final class ModelTests: XCTestCase {
    func testEndpointURL() {
        XCTAssertEqual(Endpoint(label: "LAN", host: "192.168.1.20").baseURL?.absoluteString, "https://192.168.1.20")
        XCTAssertEqual(Endpoint(label: "TS", host: " kvm.tail1234.ts.net:8443 ").baseURL?.absoluteString, "https://kvm.tail1234.ts.net:8443")
        XCTAssertNil(Endpoint(label: "Empty", host: "  ").baseURL)
    }

    func testMouseModeMapping() {
        XCTAssertEqual(MouseMode.absolute.kvmdMouseOutput, "usb")
        XCTAssertEqual(MouseMode(kvmdMouseOutput: "usb_rel"), .relative)
        XCTAssertNil(MouseMode(kvmdMouseOutput: "ps2"))
    }

    func testSyncTargetsKeepsPerPortMouseMode() {
        var device = Device(name: "Rack", model: .v4Plus)
        device.syncTargets(withSwitchPorts: (0..<4).map { SwitchPortInfo(index: $0) })
        XCTAssertEqual(device.targets.map(\.name), ["Port 1", "Port 2", "Port 3", "Port 4"])
        device.targets[1].mouseMode = .relative
        device.targets[1].name = "Router"
        let routerID = device.targets[1].id

        // A second switch unit is chained on: ports 4-7 appear.
        device.syncTargets(withSwitchPorts: (0..<8).map { SwitchPortInfo(index: $0, name: $0 == 6 ? "NAS" : nil) })
        XCTAssertEqual(device.targets.count, 8)
        XCTAssertEqual(device.targets[1].id, routerID)
        XCTAssertEqual(device.targets[1].name, "Router")
        XCTAssertEqual(device.targets[1].mouseMode, .relative)
        XCTAssertEqual(device.targets[6].name, "NAS")
        XCTAssertTrue(device.hasSwitch)
    }

    func testSyncTargetsWithoutSwitch() {
        var device = Device(name: "Desk PC")
        device.targets[0].mouseMode = .relative
        device.syncTargets(withSwitchPorts: [])
        XCTAssertEqual(device.targets.count, 1)
        XCTAssertEqual(device.targets[0].mouseMode, .relative)
    }

    func testLegacyModelValuesStillDecode() throws {
        let decode = { (raw: String) in try JSONDecoder().decode(PiKVMModel.self, from: Data("\"\(raw)\"".utf8)) }
        XCTAssertEqual(try decode("v3Lite"), .v4Mini)
        XCTAssertEqual(try decode("plus"), .v4Plus)
        XCTAssertEqual(try decode("v4Mini"), .v4Mini)
        XCTAssertEqual(try decode("something-new"), .other)
    }

    func testDeviceStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("d.json")
        let store = DeviceStore(fileURL: url)
        XCTAssertEqual(try store.load(), [])
        let devices = [Device(name: "A", endpoints: [Endpoint(label: "LAN", host: "a.local")])]
        try store.save(devices)
        XCTAssertEqual(try store.load(), devices)
    }
}
