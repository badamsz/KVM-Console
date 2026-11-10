import XCTest
@testable import PiKVMKit

final class ConsoleTests: XCTestCase {
    func testKeyMessage() {
        XCTAssertEqual(HIDMessage.key("KeyA", down: true), Data([1, 1] + Array("KeyA".utf8)))
        XCTAssertEqual(HIDMessage.key("ShiftLeft", down: false), Data([1, 0] + Array("ShiftLeft".utf8)))
    }

    func testMouseButtonMessage() {
        XCTAssertEqual(HIDMessage.mouseButton(.left, down: true), Data([2, 1] + Array("left".utf8)))
    }

    func testMouseMoveIsBigEndianSigned() {
        XCTAssertEqual(HIDMessage.mouseMove(x: -32768, y: 32767), Data([3, 0x80, 0x00, 0x7F, 0xFF]))
        XCTAssertEqual(HIDMessage.mouseMove(x: 0, y: -1), Data([3, 0x00, 0x00, 0xFF, 0xFF]))
    }

    func testRelativeAndWheel() {
        XCTAssertEqual(HIDMessage.mouseRelative([(5, -3)]), Data([4, 0, 5, 0xFD]))
        XCTAssertEqual(HIDMessage.mouseRelative([(1, 1), (2, 2)], squash: true), Data([4, 1, 1, 1, 2, 2]))
        XCTAssertEqual(HIDMessage.mouseWheel(dx: 0, dy: -5), Data([5, 0, 0, 0xFB]))
    }

    func testSplitDelta() {
        let steps = HIDMessage.splitDelta(dx: 300, dy: -10)
        XCTAssertEqual(steps.map(\.dx), [127, 127, 46])
        XCTAssertEqual(steps.map(\.dy), [-10, 0, 0])
        XCTAssertTrue(HIDMessage.splitDelta(dx: 0, dy: 0).isEmpty)
    }

    func testAbsolutePosition() throws {
        let topLeft = try XCTUnwrap(HIDMessage.absolutePosition(x: 0, y: 0, videoWidth: 1920, videoHeight: 1080))
        XCTAssertEqual(topLeft.x, -32768)
        XCTAssertEqual(topLeft.y, -32768)
        let bottomRight = try XCTUnwrap(HIDMessage.absolutePosition(x: 1919, y: 1079, videoWidth: 1920, videoHeight: 1080))
        XCTAssertEqual(bottomRight.x, 32767)
        XCTAssertEqual(bottomRight.y, 32767)
        let outside = try XCTUnwrap(HIDMessage.absolutePosition(x: -50, y: 5000, videoWidth: 1920, videoHeight: 1080))
        XCTAssertEqual(outside.x, -32768)
        XCTAssertEqual(outside.y, 32767)
        XCTAssertNil(HIDMessage.absolutePosition(x: 0, y: 0, videoWidth: 0, videoHeight: 0))
    }

    func testKeyMapUsesOnlyNamesKVMDAccepts() {
        // From WEB_TO_EVDEV in kvmd/keyboard/mappings.py.
        let valid: Set<String> = ["AltLeft", "AltRight", "ArrowDown", "ArrowLeft", "ArrowRight", "ArrowUp", "AudioVolumeDown", "AudioVolumeMute", "AudioVolumeUp", "Backquote", "Backslash", "Backspace", "BracketLeft", "BracketRight", "CapsLock", "Comma", "ContextMenu", "ControlLeft", "ControlRight", "Convert", "Delete", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "End", "Enter", "Equal", "Escape", "F1", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F2", "F20", "F21", "F22", "F23", "F24", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "Home", "Insert", "IntlBackslash", "IntlRo", "IntlYen", "KanaMode", "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "MetaLeft", "MetaRight", "Minus", "NonConvert", "NumLock", "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9", "NumpadAdd", "NumpadDecimal", "NumpadDivide", "NumpadEnter", "NumpadMultiply", "NumpadSubtract", "PageDown", "PageUp", "Pause", "Period", "Power", "PrintScreen", "Quote", "ScrollLock", "Semicolon", "ShiftLeft", "ShiftRight", "Slash", "Space", "Tab"]
        for (code, name) in KeyMap.table {
            XCTAssertTrue(valid.contains(name), "key code \(code) maps to unknown name \(name)")
        }
        XCTAssertEqual(KeyMap.webCode(forMacKeyCode: 0), "KeyA")
        XCTAssertEqual(KeyMap.webCode(forMacKeyCode: 55), "MetaLeft")
        XCTAssertNil(KeyMap.webCode(forMacKeyCode: 999))
        XCTAssertEqual(Set(KeyMap.table.values).count, KeyMap.table.count, "two key codes map to the same name")
    }

    func testMJPEGParserAcrossChunks() {
        let jpegA = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let jpegB = Data([0xFF, 0xD8, 9, 0xFF, 0xD9])
        var stream = Data()
        for jpeg in [jpegA, jpegB] {
            stream.append(Data("--boundarydonotcross\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\nX-Timestamp: 1.0\r\n\r\n".utf8))
            stream.append(jpeg)
            stream.append(Data("\r\n".utf8))
        }
        var parser = MJPEGParser()
        var frames: [Data] = []
        // Feed in awkward 5-byte chunks.
        var i = 0
        while i < stream.count {
            let end = min(i + 5, stream.count)
            frames += parser.append(stream.subdata(in: i..<end))
            i = end
        }
        XCTAssertEqual(frames, [jpegA, jpegB])
    }

    func testMJPEGParserWithoutContentLength() {
        let jpeg = Data([0xFF, 0xD8, 7, 7, 0xFF, 0xD9])
        var stream = Data("--b\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        stream.append(jpeg)
        stream.append(Data("\r\n--b\r\n".utf8))
        var parser = MJPEGParser()
        XCTAssertEqual(parser.append(stream), [jpeg])
    }
}
