import XCTest
@testable import PiKVMKit

final class DecodingTests: XCTestCase {
    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://kvm")!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testATX() throws {
        let json = #"{"ok":true,"result":{"enabled":true,"busy":false,"leds":{"power":true,"hdd":false}}}"#
        let atx = try KVMDClient.decode(ATXState.self, data: Data(json.utf8), response: response(200))
        XCTAssertTrue(atx.enabled)
        XCTAssertTrue(atx.leds.power)
        XCTAssertFalse(atx.leds.hdd)
    }

    func testHIDMouseMode() throws {
        let json = #"{"ok":true,"result":{"online":true,"mouse":{"absolute":false,"online":true,"outputs":{"available":["usb","usb_rel"],"active":"usb_rel"}}}}"#
        let hid = try KVMDClient.decode(HIDState.self, data: Data(json.utf8), response: response(200))
        XCTAssertEqual(hid.activeMouseMode, .relative)
        XCTAssertEqual(hid.supportedMouseModes, [.absolute, .relative])
    }

    func testInfoIsLenient() throws {
        let json = #"{"ok":true,"result":{"system":{"kvmd":{"version":"4.20"}},"meta":{"server":{"host":"pikvm-rack"}}}}"#
        let info = try KVMDClient.decode(DeviceInfo.self, data: Data(json.utf8), response: response(200))
        XCTAssertEqual(info.kvmdVersion, "4.20")
        XCTAssertEqual(info.hostname, "pikvm-rack")
        XCTAssertNil(info.platformModel)
    }

    func testSwitchChainOfTwoUnits() throws {
        let ports = (0..<8).map { i in #"{"unit":\#(i / 4),"channel":\#(i % 4),"name":"\#(i == 2 ? "NAS" : "")","id":"\#(i / 4 + 1).\#(i % 4 + 1)"}"# }
        let json = #"{"ok":true,"result":{"model":{"ports":[\#(ports.joined(separator: ","))]},"summary":{"active_port":2},"atx":{"leds":{"power":[true,false,true,false,false,false,false,false]}}}}"#
        let state = try KVMDClient.decode(SwitchState.self, data: Data(json.utf8), response: response(200))
        XCTAssertEqual(state.ports.count, 8)
        XCTAssertEqual(state.ports[5].unit, 1)
        XCTAssertEqual(state.ports[5].channel, 1)
        XCTAssertEqual(state.ports[2].name, "NAS")
        XCTAssertEqual(state.ports[5].displayID, "2.2")
        XCTAssertEqual(state.activePort, 2)
        XCTAssertEqual(state.powerLEDs?[2], true)
    }

    func testSwitchChainOfFiveUnits() throws {
        let count = SwitchState.maxPorts
        let ports = (0..<count).map { i in #"{"unit":\#(i / 4),"channel":\#(i % 4),"id":"\#(i / 4 + 1).\#(i % 4 + 1)"}"# }
        let json = #"{"ok":true,"result":{"model":{"ports":[\#(ports.joined(separator: ","))]},"summary":{"active_port":19}}}"#
        let state = try KVMDClient.decode(SwitchState.self, data: Data(json.utf8), response: response(200))
        XCTAssertEqual(state.ports.count, 20)
        XCTAssertEqual(state.ports[19].displayID, "5.4")
        XCTAssertEqual(state.activePort, 19)
        XCTAssertEqual(state.ports[13].location(inChainOf: state.ports), "Switch 4, port 2")
    }

    func testSingleSwitchHasNoChainLocation() {
        let ports = (0..<4).map { SwitchPortInfo(index: $0, unit: 0, channel: $0, displayID: "\($0 + 1)") }
        XCTAssertNil(ports[2].location(inChainOf: ports))
    }

    func testUnauthorized() {
        XCTAssertThrowsError(try KVMDClient.decode(ATXState.self, data: Data(), response: response(403))) { error in
            guard case KVMDError.unauthorized = error else { return XCTFail("\(error)") }
        }
    }

    func testEvent() throws {
        let json = #"{"event_type":"atx_state","event":{"leds":{"power":true}}}"#
        let event = try JSONDecoder().decode(KVMDEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.eventType, "atx_state")
        XCTAssertEqual(event.event["leds"]?["power"], .bool(true))
    }

    func testStreamerOnlineEvent() throws {
        let decode = { (json: String) in try JSONDecoder().decode(KVMDEvent.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"event_type":"streamer","event":{"streamer":{"source":{"online":false,"resolution":{"width":1920,"height":1080}}}}}"#).streamerSourceOnline, false)
        XCTAssertEqual(try decode(#"{"event_type":"streamer","event":{"streamer":{"source":{"online":true}}}}"#).streamerSourceOnline, true)
        XCTAssertNil(try decode(#"{"event_type":"streamer","event":{"streamer":null}}"#).streamerSourceOnline)
        XCTAssertNil(try decode(#"{"event_type":"streamer","event":{"features":{"h264":true}}}"#).streamerSourceOnline)
        XCTAssertNil(try decode(#"{"event_type":"atx","event":{"streamer":{"source":{"online":true}}}}"#).streamerSourceOnline)
    }
}
