import XCTest
@testable import PiKVMKit

final class MSDTests: XCTestCase {
    private func decode(_ result: String) throws -> MSDState {
        let response = HTTPURLResponse(url: URL(string: "https://kvm")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return try KVMDClient.decode(MSDState.self, data: Data(#"{"ok":true,"result":\#(result)}"#.utf8), response: response)
    }

    func testConnectedCD() throws {
        let state = try decode(#"""
        {"enabled":true,"online":true,"busy":false,
         "storage":{"images":{
            "ubuntu-24.04.iso":{"size":6114656256,"mod_ts":1.0,"writable":false,"cdromable":true,"removable":true,"complete":true},
            "Debian 12.iso":{"size":658505728,"mod_ts":2.0,"writable":false,"cdromable":true,"removable":true,"complete":false}},
          "parts":{"":{"size":29000000000,"free":20000000000,"writable":true}},
          "downloading":null,"uploading":{"name":"Debian 12.iso","size":658505728,"written":1048576}},
         "drive":{"image":{"name":"ubuntu-24.04.iso","size":6114656256,"complete":true,"in_storage":true,"cdromable":true,"removable":true,"url":null},
                  "connected":true,"cdrom":true,"rw":false}}
        """#)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.images.map(\.name), ["Debian 12.iso", "ubuntu-24.04.iso"])
        XCTAssertFalse(state.images[0].complete)
        XCTAssertEqual(state.freeBytes, 20_000_000_000)
        XCTAssertEqual(state.uploading?.written, 1_048_576)
        XCTAssertEqual(state.drive?.image?.name, "ubuntu-24.04.iso")
        XCTAssertEqual(state.drive?.connected, true)
        XCTAssertEqual(state.drive?.cdrom, true)
        XCTAssertEqual(state.drive?.writable, false)
    }

    func testDisabled() throws {
        let state = try decode(#"{"enabled":false,"online":false,"busy":false,"storage":null,"drive":null}"#)
        XCTAssertFalse(state.enabled)
        XCTAssertTrue(state.images.isEmpty)
        XCTAssertNil(state.drive)
        XCTAssertNil(state.freeBytes)
    }

    func testEmptyDriveAndLegacyStorage() throws {
        let state = try decode(#"""
        {"enabled":true,"online":true,"busy":false,
         "storage":{"size":1000,"free":400,"images":{},"uploading":null},
         "drive":{"image":null,"connected":false,"cdrom":true,"rw":false}}
        """#)
        XCTAssertNil(state.drive?.image)
        XCTAssertEqual(state.totalBytes, 1000)
        XCTAssertEqual(state.freeBytes, 400)
    }

    func testImageNames() {
        XCTAssertEqual(MSDImageName.sanitized("ubuntu-24.04.iso"), "ubuntu-24.04.iso")
        XCTAssertEqual(MSDImageName.sanitized("a/b\tc.img"), "a_b_c.img")
        XCTAssertEqual(MSDImageName.sanitized(".hidden.iso"), "hidden.iso")
        XCTAssertEqual(MSDImageName.sanitized(""), "image.iso")
        let long = MSDImageName.sanitized(String(repeating: "x", count: 300) + ".iso")
        XCTAssertEqual(long.count, 255)
        XCTAssertTrue(long.hasSuffix(".iso"))
    }

    func testPlusInQueryIsEncoded() throws {
        let client = KVMDClient(baseURL: URL(string: "https://kvm")!, username: "admin", password: "x", pinnedSHA256: nil)
        let req = try client.makeRequest("api/msd/remove", method: "POST", query: ["image": "c++ tools.iso"])
        XCTAssertEqual(req.url?.query(percentEncoded: true), "image=c%2B%2B%20tools.iso")
    }
}
