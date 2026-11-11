import Foundation

/// Standard USB HID boot-protocol reports, as sent to Sipeed NanoKVM devices
/// over their `/api/ws` socket. kvmd takes key names instead (see `HIDMessage`).
///
/// * Keyboard: 8 bytes, `[modifiers, 0, key1 ... key6]`.
/// * Relative mouse: 4 bytes, `[buttons, dx, dy, wheel]`, signed deltas.
/// * Absolute mouse: 6 bytes, `[buttons, x lo, x hi, y lo, y hi, wheel]`,
///   with x and y in 0...32767 (little endian).
public enum HIDReport {
    // MARK: Keyboard

    /// Modifier bits in byte 0 of a keyboard report, by web key code.
    static let modifierBits: [String: UInt8] = [
        "ControlLeft": 0x01, "ShiftLeft": 0x02, "AltLeft": 0x04, "MetaLeft": 0x08,
        "ControlRight": 0x10, "ShiftRight": 0x20, "AltRight": 0x40, "MetaRight": 0x80,
    ]

    /// The HID usage (Keyboard/Keypad page 0x07) for a web `KeyboardEvent.code`.
    public static func usage(forWebCode code: String) -> UInt8? { usages[code] }

    static let usages: [String: UInt8] = {
        var t: [String: UInt8] = [:]
        // Letters: KeyA (0x04) ... KeyZ (0x1D)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { t["Key\(c)"] = UInt8(0x04 + i) }
        // Digit1 (0x1E) ... Digit9 (0x26), Digit0 (0x27)
        for i in 1...9 { t["Digit\(i)"] = UInt8(0x1D + i) }
        t["Digit0"] = 0x27
        // F1 (0x3A) ... F12 (0x45), F13 (0x68) ... F24 (0x73)
        for i in 1...12 { t["F\(i)"] = UInt8(0x39 + i) }
        for i in 13...24 { t["F\(i)"] = UInt8(0x68 + i - 13) }
        // Numpad1 (0x59) ... Numpad9 (0x61), Numpad0 (0x62)
        for i in 1...9 { t["Numpad\(i)"] = UInt8(0x58 + i) }
        t["Numpad0"] = 0x62
        let rest: [String: UInt8] = [
            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
            "Minus": 0x2D, "Equal": 0x2E, "BracketLeft": 0x2F, "BracketRight": 0x30, "Backslash": 0x31,
            "Semicolon": 0x33, "Quote": 0x34, "Backquote": 0x35, "Comma": 0x36, "Period": 0x37, "Slash": 0x38,
            "CapsLock": 0x39, "PrintScreen": 0x46, "ScrollLock": 0x47, "Pause": 0x48,
            "Insert": 0x49, "Home": 0x4A, "PageUp": 0x4B, "Delete": 0x4C, "End": 0x4D, "PageDown": 0x4E,
            "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
            "NumLock": 0x53, "NumpadDivide": 0x54, "NumpadMultiply": 0x55, "NumpadSubtract": 0x56,
            "NumpadAdd": 0x57, "NumpadEnter": 0x58, "NumpadDecimal": 0x63, "NumpadEqual": 0x67,
            "IntlBackslash": 0x64, "ContextMenu": 0x65, "Power": 0x66,
            "IntlRo": 0x87, "KanaMode": 0x88, "IntlYen": 0x89, "Convert": 0x8A, "NonConvert": 0x8B,
            "Lang1": 0x90, "Lang2": 0x91,
            "AudioVolumeMute": 0x7F, "AudioVolumeUp": 0x80, "AudioVolumeDown": 0x81,
            "ControlLeft": 0xE0, "ShiftLeft": 0xE1, "AltLeft": 0xE2, "MetaLeft": 0xE3,
            "ControlRight": 0xE4, "ShiftRight": 0xE5, "AltRight": 0xE6, "MetaRight": 0xE7,
        ]
        t.merge(rest) { a, _ in a }
        return t
    }()

    /// Tracks which keys are held and produces the keyboard report for that
    /// state. A boot keyboard reports at most six non-modifier keys at once;
    /// further keys are ignored until one is released.
    public struct Keyboard: Sendable, Equatable {
        public private(set) var modifiers: UInt8 = 0
        public private(set) var keys: [UInt8] = []

        public init() {}

        /// Applies a key press or release and returns the report to send, or
        /// nil if the key is unknown or the state didn't change.
        public mutating func update(webCode code: String, down: Bool) -> Data? {
            if let bit = HIDReport.modifierBits[code] {
                let before = modifiers
                if down { modifiers |= bit } else { modifiers &= ~bit }
                return before == modifiers ? nil : report
            }
            guard let usage = HIDReport.usage(forWebCode: code) else { return nil }
            if down {
                guard !keys.contains(usage), keys.count < 6 else { return nil }
                keys.append(usage)
            } else {
                guard let i = keys.firstIndex(of: usage) else { return nil }
                keys.remove(at: i)
            }
            return report
        }

        /// Releases everything.
        public mutating func reset() -> Data {
            modifiers = 0
            keys = []
            return report
        }

        public var report: Data {
            var bytes: [UInt8] = [modifiers, 0]
            bytes.append(contentsOf: keys)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 6 - keys.count))
            return Data(bytes)
        }
    }

    // MARK: Mouse

    /// Button bits in byte 0 of a mouse report.
    public static func buttonBit(_ button: MouseButton) -> UInt8 {
        switch button {
        case .left: return 0x01
        case .right: return 0x02
        case .middle: return 0x04
        case .up: return 0x08 // back
        case .down: return 0x10 // forward
        }
    }

    private static func signedByte(_ v: Int) -> UInt8 {
        UInt8(bitPattern: Int8(max(-127, min(127, v))))
    }

    /// A relative mouse report. Deltas are clamped to -127...127; positive
    /// `wheel` scrolls up.
    public static func relativeMouse(buttons: UInt8, dx: Int = 0, dy: Int = 0, wheel: Int = 0) -> Data {
        Data([buttons, signedByte(dx), signedByte(dy), signedByte(wheel)])
    }

    /// An absolute mouse report. `x` and `y` are in 0...32767.
    public static func absoluteMouse(buttons: UInt8, x: UInt16, y: UInt16, wheel: Int = 0) -> Data {
        let cx = min(x, 32767), cy = min(y, 32767)
        return Data([buttons, UInt8(cx & 0xFF), UInt8(cx >> 8), UInt8(cy & 0xFF), UInt8(cy >> 8), signedByte(wheel)])
    }

    /// Maps a point inside a video rectangle to the 0...32767 absolute range.
    /// Returns nil when the rectangle is empty. Points outside are clamped.
    public static func absolutePosition(
        x: Double, y: Double, videoWidth: Double, videoHeight: Double
    ) -> (x: UInt16, y: UInt16)? {
        guard videoWidth > 1, videoHeight > 1 else { return nil }
        func remap(_ v: Double, _ size: Double) -> UInt16 {
            let t = max(0, min(1, v / (size - 1)))
            return UInt16((t * 32767).rounded())
        }
        return (remap(x, videoWidth), remap(y, videoHeight))
    }
}

/// Messages on a NanoKVM's `/api/ws` socket: a type byte, then a HID report.
public enum NanoKVMMessage {
    /// Heartbeat. The NanoKVM drops a socket that sends nothing for 90 seconds.
    public static let heartbeat = Data([0])

    public static func keyboard(_ report: Data) -> Data { Data([1]) + report }

    public static func mouse(_ report: Data) -> Data { Data([2]) + report }
}
