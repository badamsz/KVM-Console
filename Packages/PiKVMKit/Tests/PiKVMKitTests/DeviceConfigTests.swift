import XCTest
@testable import PiKVMKit

final class RootShellWireTests: XCTestCase {
    func testCommandKeepsLinesShortAndMarkersHidden() {
        let script = String(repeating: "echo 'a long line of shell'; ", count: 400)
        let command = RootShellWire.command(script: script, id: 7)
        XCTAssertTrue(command.hasPrefix("base64 -d >/tmp/pkc.7.sh <<'PKC_EOF'\n"))
        XCTAssertTrue(command.hasSuffix("\n"))
        for line in command.split(separator: "\n") { XCTAssertLessThan(line.count, 1000) }
        // The terminal's echo of the command never looks like a result.
        XCTAssertNil(RootShellWire.result(in: command.replacingOccurrences(of: "\n", with: "\r\n"), id: 7))
        XCTAssertFalse(command.contains("PKC_B7"))
        XCTAssertFalse(command.contains("PKC_E7="))

        let encoded = command.components(separatedBy: "\n").dropFirst().prefix { $0 != "PKC_EOF" }.joined()
        XCTAssertEqual(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }, script)
    }

    func testResultParsing() {
        let payload = Data("PKC_JSON:{\"ok\": true}\nsecond line\n".utf8).base64EncodedString()
        let half = payload.index(payload.startIndex, offsetBy: payload.count / 2)
        let output = "\u{1B}[?2004l\r\r\nPKC_B3\r\n" + payload[..<half] + "\r\n" + payload[half...] + "\r\nPKC_E3=2\r\n"
        let result = RootShellWire.result(in: output, id: 3)
        XCTAssertEqual(result?.code, 2)
        XCTAssertEqual(result.map { String(decoding: $0.output, as: UTF8.self) }, "PKC_JSON:{\"ok\": true}\nsecond line\n")
    }

    func testResultWaitsForCompleteEndMarker() {
        XCTAssertNil(RootShellWire.result(in: "PKC_B1\r\naGk=\r\nPKC_E1=1", id: 1))
        XCTAssertNil(RootShellWire.result(in: "PKC_B1\r\naGk=", id: 1))
        XCTAssertEqual(RootShellWire.result(in: "PKC_B1\r\naGk=\r\nPKC_E1=12\n", id: 1)?.code, 12)
    }

    func testResultIgnoresOtherJobs() {
        // Job 1's markers are not job 12's, and empty output is fine.
        let output = "PKC_B12\r\naGk=\r\nPKC_E12=0\r\nPKC_B1\r\n\r\nPKC_E1=0\r\n"
        XCTAssertEqual(RootShellWire.result(in: output, id: 1)?.output, Data())
        XCTAssertEqual(RootShellWire.result(in: output, id: 12)?.output, Data("hi".utf8))
    }

    func testSetupHidesMarkers() {
        XCTAssertFalse(RootShellWire.setup.contains("PKC_ROOT_OK"))
        XCTAssertNil(RootShellWire.markerLine(in: RootShellWire.setup, prefix: "PKC_ROOT_OK", from: RootShellWire.setup.startIndex))
        let reply = "\r\nPKC_ROOT_OK\r\n"
        XCTAssertNotNil(RootShellWire.markerLine(in: reply, prefix: "PKC_ROOT_OK", from: reply.startIndex))
    }
}

final class DeviceConfigTests: XCTestCase {
    func testHelperIsBundled() {
        XCTAssertTrue(DeviceConfigurator.helperSource.contains("PKC_JSON:"))
    }

    func testScriptCarriesRequestAndHelper() throws {
        let script = try DeviceConfigurator.script(
            request: ["op": .string("merge"), "text": .string("a: 'x'\n/etc\n"), "patch": .object(["a/b": .number(80), "c": .null])],
            helper: "print('helper')")
        XCTAssertTrue(script.contains("cat >/tmp/pkc-req.json <<'PKC_REQ'\n{"))
        XCTAssertTrue(script.contains(#""patch":{"a/b":80,"c":null}"#), script)
        XCTAssertTrue(script.contains(#""text":"a: 'x'\n\/etc\n""#) || script.contains(#""text":"a: 'x'\n/etc\n""#))
        XCTAssertTrue(script.contains("python3 - /tmp/pkc-req.json <<'PKC_PY'\nprint('helper')\nPKC_PY\n"))
        // The request is one line, so it can't end the here-document early.
        let request = script.components(separatedBy: "\n")[2]
        XCTAssertTrue(request.hasPrefix("{"))
    }

    func testParseResponse() throws {
        let output = "some warning\n\nPKC_JSON:" + #"""
        {"ok": true, "text": "vnc: {}\n", "effective": {"otg/devices/audio/enabled": false, "kvmd/streamer/quality": 80},
         "overridden": [], "backups": [{"name": "20261111-043859.yaml", "size": 12}],
         "units": {"kvmd-vnc": {"enabled": false, "active": false, "exists": true}}, "rootReadOnly": true}
        """#.replacingOccurrences(of: "\n", with: " ") + "\n"
        let r = try DeviceConfigurator.parse(output: output, code: 0)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.effective?["otg/devices/audio/enabled"], .bool(false))
        XCTAssertEqual(r.effective?["kvmd/streamer/quality"], .number(80))
        XCTAssertEqual(r.backups?.first?.name, "20261111-043859.yaml")
        XCTAssertNotNil(r.backups?.first?.date)
        XCTAssertEqual(r.units?["kvmd-vnc"]?.enabled, false)
    }

    func testParseWithoutResultLine() {
        XCTAssertThrowsError(try DeviceConfigurator.parse(output: "python3: command not found\n", code: 127)) { error in
            XCTAssertEqual((error as? DeviceConfigError)?.details, "python3: command not found")
        }
    }

    func testCatalogPathsAreUnique() {
        let paths = ConfigOption.catalog.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(ConfigOption.catalog.filter { $0.path.hasPrefix("otg/") }.allSatisfy(\.needsReboot))
    }
}
