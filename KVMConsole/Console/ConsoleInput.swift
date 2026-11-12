import CoreGraphics
import Foundation
import KVMKit

/// Where a console sends keyboard, mouse and pasted text. Each kind of
/// device has one: kvmd's session socket (`KVMDConsoleInput`), a NanoKVM's
/// HID socket (`NanoKVMConsoleLink`), an Openterface's serial port
/// (`OpenterfaceConsoleLink`). `ConsoleModel` only talks to this protocol.
@MainActor
protocol ConsoleInput: AnyObject {
    /// `code` is a web `KeyboardEvent.code`, such as "KeyA" or "ShiftLeft".
    func key(_ code: String, down: Bool)
    func mouseButton(_ button: MouseButton, down: Bool, mode: MouseMode)
    /// `point` is in video pixels with the origin at the top-left.
    func mouseMove(toVideoPoint point: CGPoint, videoSize: CGSize)
    func mouseRelative(dx: Int, dy: Int)
    /// Positive `dy` scrolls up. Devices without a horizontal wheel ignore `dx`.
    func mouseWheel(dx: Int, dy: Int, mode: MouseMode)

    // Paste

    /// Splits pasted text into pieces. Progress is shown after each one.
    func pastePieces(_ text: String) -> [String]
    /// Types one piece. Returns how many of its characters couldn't be typed.
    func type(_ piece: String, rate: TypingRate) async throws -> Int
    /// Why characters may be skipped, appended to the warning.
    var pasteLimitation: String { get }
}

extension ConsoleInput {
    func pastePieces(_ text: String) -> [String] { TextPaste.chunks(text) }
    var pasteLimitation: String { "" }

    /// Presses the keys in order, then releases them in reverse.
    func combo(_ codes: [String]) {
        for code in codes { key(code, down: true) }
        for code in codes.reversed() { key(code, down: false) }
    }
}

/// A PiKVM: kvmd's binary HID messages on the session socket, and
/// pasted text through `/api/hid/print`, which uses the PiKVM's keymap.
@MainActor
final class KVMDConsoleInput: ConsoleInput {
    let socket: URLSessionWebSocketTask
    let client: KVMDClient

    init(socket: URLSessionWebSocketTask, client: KVMDClient) {
        self.socket = socket
        self.client = client
    }

    private func send(_ data: Data) {
        socket.send(.data(data)) { _ in }
    }

    func key(_ code: String, down: Bool) {
        send(HIDMessage.key(code, down: down))
    }

    func mouseButton(_ button: MouseButton, down: Bool, mode: MouseMode) {
        send(HIDMessage.mouseButton(button, down: down))
    }

    func mouseMove(toVideoPoint point: CGPoint, videoSize: CGSize) {
        guard let pos = HIDMessage.absolutePosition(x: point.x, y: point.y,
                                                    videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        send(HIDMessage.mouseMove(x: pos.x, y: pos.y))
    }

    func mouseRelative(dx: Int, dy: Int) {
        let steps = HIDMessage.splitDelta(dx: dx, dy: dy)
        guard !steps.isEmpty else { return }
        send(HIDMessage.mouseRelative(steps, squash: steps.count > 1))
    }

    func mouseWheel(dx: Int, dy: Int, mode: MouseMode) {
        send(HIDMessage.mouseWheel(dx: dx, dy: dy))
    }

    func type(_ piece: String, rate: TypingRate) async throws -> Int {
        try await client.typeText(piece, delay: rate.delay)
        return 0
    }
}
