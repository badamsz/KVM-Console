import XCTest
@testable import KVMKit

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

    func testPlainStepsKeepText() {
        XCTAssertEqual(TextPaste.steps("a\n    b", mode: .plain), [.text("a\n    b")])
        XCTAssertEqual(TextPaste.steps("", mode: .plain), [])
    }

    func testFormattedStepsClearEachNewLine() {
        let code = "if x:\n    y = 1\n\n    \nz"
        XCTAssertEqual(TextPaste.steps(code, mode: .formatted), [
            .text("if x:\n"), .clearLine,
            .text("    y = 1\n"), .clearLine,
            .text("\n"), .clearLine,
            .text("\n"), .clearLine,
            .text("z"),
        ])
    }

    func testFormattedStepsSingleLineAndTrailingNewline() {
        XCTAssertEqual(TextPaste.formattedSteps("  one line"), [.text("  one line")])
        XCTAssertEqual(TextPaste.formattedSteps("a\n"), [.text("a\n"), .clearLine])
        XCTAssertEqual(TextPaste.formattedSteps("\ta\n\tb"), [.text("\ta\n"), .clearLine, .text("\tb")])
    }

    func testFormattedStepsTypeEveryCharacter() {
        let code = "func f() {\n\tif a {\n\t\tb()\n\t}\n}"
        let typed = TextPaste.formattedSteps(code).compactMap { step -> String? in
            if case .text(let text) = step { return text }
            return nil
        }.joined()
        XCTAssertEqual(typed, code)
    }

    func testLineStartKeys() {
        XCTAssertEqual(LineStartKey.home.selectCombo, ["ShiftLeft", "Home"])
        XCTAssertEqual(LineStartKey.commandLeft.selectCombo, ["ShiftLeft", "MetaLeft", "ArrowLeft"])
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
