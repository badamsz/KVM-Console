import XCTest
@testable import KVMKit

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

    func testRenamingDeviceWithoutSwitchRenamesItsMachine() {
        var device = Device(name: "kvm-da21")
        let id = device.targets[0].id
        device.name = "NanoKVM Pro"
        XCTAssertEqual(device.targets.map(\.name), ["NanoKVM Pro"])
        XCTAssertEqual(device.targets[0].id, id)

        // A target saved with an old name is fixed on the next sync.
        device.targets[0].name = "stale"
        device.syncTargets(withSwitchPorts: [])
        XCTAssertEqual(device.targets[0].name, "NanoKVM Pro")
    }

    func testRenamingDeviceWithSwitchKeepsPortNames() {
        var device = Device(name: "Rack", model: .v4Plus)
        device.syncTargets(withSwitchPorts: (0..<2).map { SwitchPortInfo(index: $0) })
        device.name = "Rack 2"
        XCTAssertEqual(device.targets.map(\.name), ["Port 1", "Port 2"])
    }

    func testUnknownModelValuesDecodeAsOther() throws {
        let decode = { (raw: String) in try JSONDecoder().decode(DeviceModel.self, from: Data("\"\(raw)\"".utf8)) }
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

final class ReorderTests: XCTestCase {
    private func devices(_ names: String...) -> [Device] {
        names.map { Device(name: $0, model: .v3) }
    }

    func testMoveDownPlacesAfterDestination() {
        var list = devices("A", "B", "C", "D")
        XCTAssertTrue(list.move(list[0].id, onto: list[2].id))
        XCTAssertEqual(list.map(\.name), ["B", "C", "A", "D"])
    }

    func testMoveUpPlacesBeforeDestination() {
        var list = devices("A", "B", "C", "D")
        XCTAssertTrue(list.move(list[3].id, onto: list[1].id))
        XCTAssertEqual(list.map(\.name), ["A", "D", "B", "C"])
    }

    func testMoveToEnds() {
        var list = devices("A", "B", "C")
        list.move(list[0].id, onto: list[2].id)
        XCTAssertEqual(list.map(\.name), ["B", "C", "A"])
        list.move(list[2].id, onto: list[0].id)
        XCTAssertEqual(list.map(\.name), ["A", "B", "C"])
    }

    func testHiddenItemsBetweenStayInPlace() {
        // "h" is hidden in the sidebar; moving C up past B leaves it where it was.
        var list = devices("A", "B", "h", "C")
        list.move(list[3].id, onto: list[1].id)
        XCTAssertEqual(list.map(\.name), ["A", "C", "B", "h"])
    }

    func testNoOpForSameOrMissing() {
        var list = devices("A", "B")
        XCTAssertFalse(list.move(list[0].id, onto: list[0].id))
        XCTAssertFalse(list.move(UUID(), onto: list[0].id))
        XCTAssertEqual(list.map(\.name), ["A", "B"])
    }
}
