import Foundation

/// Mouse buttons as named by kvmd.
public enum MouseButton: String, Sendable, CaseIterable {
    case left, right, middle
    /// Back / forward side buttons.
    case up, down
}

/// Binary HID messages for the kvmd session websocket (`/api/ws`).
/// Layout mirrors `web/share/js/kvm/session.js` and `kvmd/apps/kvmd/api/hid.py`:
/// the first byte is the message type, the rest is the payload.
public enum HIDMessage {
    /// Heartbeat. kvmd answers with a single `0xFF` byte.
    public static let ping = Data([0])

    /// `key` is a web `KeyboardEvent.code` name such as `KeyA` or `ShiftLeft`.
    public static func key(_ key: String, down: Bool) -> Data {
        var data = Data([1, down ? 1 : 0])
        data.append(contentsOf: Array(key.utf8))
        return data
    }

    public static func mouseButton(_ button: MouseButton, down: Bool) -> Data {
        var data = Data([2, down ? 1 : 0])
        data.append(contentsOf: Array(button.rawValue.utf8))
        return data
    }

    /// Absolute move. `x` and `y` are in kvmd's range, -32768...32767,
    /// where (-32768, -32768) is the top-left corner of the screen.
    public static func mouseMove(x: Int16, y: Int16) -> Data {
        let ux = UInt16(bitPattern: x), uy = UInt16(bitPattern: y)
        return Data([3, UInt8(ux >> 8), UInt8(ux & 0xFF), UInt8(uy >> 8), UInt8(uy & 0xFF)])
    }

    /// Relative move. Each delta component must be within -127...127;
    /// use `splitDelta` for larger movements.
    public static func mouseRelative(_ deltas: [(dx: Int, dy: Int)], squash: Bool = false) -> Data {
        deltaMessage(type: 4, deltas, squash: squash)
    }

    public static func mouseWheel(dx: Int, dy: Int) -> Data {
        deltaMessage(type: 5, [(dx, dy)], squash: false)
    }

    private static func deltaMessage(type: UInt8, _ deltas: [(dx: Int, dy: Int)], squash: Bool) -> Data {
        var data = Data([type, squash ? 1 : 0])
        for d in deltas {
            data.append(UInt8(bitPattern: Int8(clamping: max(-127, min(127, d.dx)))))
            data.append(UInt8(bitPattern: Int8(clamping: max(-127, min(127, d.dy)))))
        }
        return data
    }

    /// Splits a large relative movement into steps kvmd accepts (±127).
    public static func splitDelta(dx: Int, dy: Int) -> [(dx: Int, dy: Int)] {
        var out: [(dx: Int, dy: Int)] = []
        var rx = dx, ry = dy
        while rx != 0 || ry != 0 {
            let sx = max(-127, min(127, rx)), sy = max(-127, min(127, ry))
            out.append((sx, sy))
            rx -= sx
            ry -= sy
        }
        return out
    }

    /// Maps a point inside a video rectangle to kvmd's absolute range.
    /// Returns nil when the rectangle is empty. Points outside are clamped.
    public static func absolutePosition(
        x: Double, y: Double, videoWidth: Double, videoHeight: Double
    ) -> (x: Int16, y: Int16)? {
        guard videoWidth > 1, videoHeight > 1 else { return nil }
        func remap(_ v: Double, _ size: Double) -> Int16 {
            let t = max(0, min(1, v / (size - 1)))
            return Int16(clamping: Int((t * 65535).rounded()) - 32768)
        }
        return (remap(x, videoWidth), remap(y, videoHeight))
    }
}
