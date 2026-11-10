import XCTest
@testable import PiKVMKit

final class TextPasteTests: XCTestCase {
    func testNormalizeLineEndingsAndControlCharacters() {
        XCTAssertEqual(TextPaste.normalize("a\r\nb\rc\n\td\u{0}\u{1B}e"), "a\nb\nc\n\tde")
        XCTAssertEqual(TextPaste.normalize("naïve — ok"), "naïve — ok")
    }

    func testChunks() {
        XCTAssertEqual(TextPaste.chunks("abcdefg", size: 3), ["abc", "def", "g"])
        XCTAssertEqual(TextPaste.chunks("abc", size: 3), ["abc"])
        XCTAssertEqual(TextPaste.chunks("", size: 3), [])
        let long = String(repeating: "x", count: 200)
        let chunks = TextPaste.chunks(long)
        XCTAssertEqual(chunks.joined(), long)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TextPaste.chunkSize })
    }

    func testTypingRatesGetSlower() {
        let delays = TypingRate.allCases.map(\.delay)
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(TypingRate.normal.delay, 0.02)
    }

    func testTypeTextRequest() throws {
        let client = KVMDClient(baseURL: URL(string: "https://kvm")!, username: "u", password: "p", pinnedSHA256: nil)
        let req = try client.makeRequest("api/hid/print", method: "POST", query: ["limit": "0", "delay": "0.050"])
        XCTAssertEqual(req.url?.absoluteString, "https://kvm/api/hid/print?delay=0.050&limit=0")
        XCTAssertEqual(req.httpMethod, "POST")
    }
}
