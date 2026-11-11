import AppKit
import AVFoundation
import Foundation
import PiKVMKit

/// The console's connection to an Openterface plugged into this Mac: video
/// and audio through AVFoundation, keyboard and mouse as CH9329 commands on
/// the unit's serial port.
@MainActor
final class OpenterfaceConsoleLink {
    let unit: OpenterfaceUnit
    let capture: OpenterfaceCapture
    private var serial: SerialPort?
    private var parser = CH9329.Parser()
    /// The controller's last answer to `getInfo`.
    private(set) var info: CH9329.Info?
    private var keyboard = HIDReport.Keyboard()
    private var buttons: UInt8 = 0
    private var lastPosition: (x: UInt16, y: UInt16) = (2048, 2048)
    private var endReason: String?
    private var ended = false
    private var waiters: [CheckedContinuation<String?, Never>] = []

    init(unit: OpenterfaceUnit, audio: Bool) throws {
        self.unit = unit
        capture = try OpenterfaceCapture(videoID: unit.id, audioID: audio ? unit.audioID : nil)
        capture.onEnd = { [weak self] reason in self?.finish(reason) }
    }

    func start() {
        capture.start()
    }

    /// Opens the keyboard and mouse controller, finding its serial speed.
    /// Returns a problem to show, or nil when it's ready.
    func openSerial() async -> String? {
        guard let path = unit.serialPath else {
            return "The Openterface's keyboard and mouse controller wasn't found, so only video works. Try unplugging it and plugging it in again."
        }
        var lastError: String?
        for baud in CH9329.baudRates {
            guard !ended else { return nil }
            let port = SerialPort(path: path)
            port.onData = { [weak self] data in
                Task { @MainActor [weak self] in self?.received(data) }
            }
            port.onFailure = { [weak self] message in
                Task { @MainActor [weak self] in self?.finish(message) }
            }
            do {
                try port.open(baudRate: baud)
            } catch {
                lastError = error.localizedDescription
                break
            }
            serial = port
            info = nil
            port.write(CH9329.getInfo)
            for _ in 0..<10 {
                if info != nil || ended { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if info != nil || ended { return nil }
            port.onFailure = nil
            port.close()
            serial = nil
        }
        if let lastError { return lastError }
        // No answer at either speed. Keep going at the usual speed: some
        // controllers don't answer queries but still take reports.
        let port = SerialPort(path: path)
        port.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in self?.finish(message) }
        }
        do {
            try port.open(baudRate: CH9329.baudRates[0])
            serial = port
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func received(_ data: Data) {
        for response in parser.feed(data) {
            if let info = CH9329.Info(response) { self.info = info }
        }
    }

    /// Ends the link; `waitUntilEnded` returns `reason`.
    func finish(_ reason: String?) {
        guard !ended else { return }
        ended = true
        endReason = reason
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: reason) }
    }

    /// Waits until the device goes away or `finish` is called. Returns why
    /// it ended, or nil when it was asked to.
    func waitUntilEnded() async -> String? {
        if ended { return endReason }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func stop() {
        // Let go of anything still held before closing the port.
        if !keyboard.keys.isEmpty || keyboard.modifiers != 0 { serial?.write(CH9329.keyboard(keyboard.reset())) }
        if buttons != 0 {
            buttons = 0
            serial?.write(CH9329.relativeMouse(buttons: 0))
        }
        serial?.onFailure = nil
        serial?.onData = nil
        serial?.close()
        serial = nil
        capture.stop()
        finish(nil)
    }

    // MARK: Input

    func key(_ code: String, down: Bool) {
        if let report = keyboard.update(webCode: code, down: down) {
            serial?.write(CH9329.keyboard(report))
        }
    }

    func mouseButton(_ button: MouseButton, down: Bool, mode: MouseMode) {
        // The CH9329 reports left, right and middle only.
        let bit = HIDReport.buttonBit(button) & 0x07
        guard bit != 0 else { return }
        if down { buttons |= bit } else { buttons &= ~bit }
        sendButtons(mode: mode, wheel: 0)
    }

    func mouseMove(toVideoPoint point: CGPoint, videoSize: CGSize) {
        guard let pos = HIDReport.absolutePosition(x: point.x, y: point.y,
                                                   videoWidth: videoSize.width, videoHeight: videoSize.height) else { return }
        lastPosition = (OpenterfaceHardware.absoluteCoordinate(pos.x), OpenterfaceHardware.absoluteCoordinate(pos.y))
        serial?.write(CH9329.absoluteMouse(buttons: buttons, x: lastPosition.x, y: lastPosition.y), droppable: buttons == 0)
    }

    func mouseRelative(dx: Int, dy: Int) {
        let steps = HIDMessage.splitDelta(dx: dx, dy: dy)
        for step in steps {
            serial?.write(CH9329.relativeMouse(buttons: buttons, dx: step.dx, dy: step.dy),
                          droppable: buttons == 0 && steps.count == 1)
        }
    }

    /// Positive `dy` scrolls up.
    func mouseWheel(dy: Int, mode: MouseMode) {
        guard dy != 0 else { return }
        sendButtons(mode: mode, wheel: dy)
    }

    private func sendButtons(mode: MouseMode, wheel: Int) {
        switch mode {
        case .absolute:
            serial?.write(CH9329.absoluteMouse(buttons: buttons, x: lastPosition.x, y: lastPosition.y, wheel: wheel))
        case .relative:
            serial?.write(CH9329.relativeMouse(buttons: buttons, wheel: wheel))
        }
    }

    /// Types one character on a US layout. Returns false when it has no key.
    func type(_ character: Character) -> Bool {
        guard let stroke = USKeyboardTyping.stroke(for: character) else { return false }
        if stroke.shift { key("ShiftLeft", down: true) }
        key(stroke.code, down: true)
        key(stroke.code, down: false)
        if stroke.shift { key("ShiftLeft", down: false) }
        return true
    }
}

extension ConsoleModel {
    /// Shows an Openterface's video and runs until it is unplugged or the
    /// console reconnects. Returns true if the console was live.
    func runOpenterfaceOnce(_ unit: OpenterfaceUnit) async -> Bool {
        generation += 1
        let gen = generation
        fallbackReason = nil
        guard await OpenterfaceCapture.requestAccess(for: .video) else {
            state = .failed("KVM Console can't see the Openterface's video. Allow camera access in System Settings > Privacy & Security > Camera.")
            return false
        }
        var audio = false
        if unit.audioID != nil { audio = await OpenterfaceCapture.requestAccess(for: .audio) }
        guard gen == generation, !Task.isCancelled else { return false }

        let link: OpenterfaceConsoleLink
        do {
            link = try OpenterfaceConsoleLink(unit: unit, audio: audio)
        } catch {
            state = .failed(error.localizedDescription)
            // Look for the unit again next time; it may have been unplugged.
            app?.session(for: selection.deviceID).disconnect()
            return false
        }
        local = link
        link.capture.volume = muted ? 0 : Float(volume)
        showLocalVideo(link.capture.view, size: link.capture.videoSize, fps: link.capture.frameRate,
                       codec: "USB", audio: link.capture.hasAudio)
        link.start()
        state = .live
        if unit.audioID != nil, !audio {
            app?.lastError = "To hear the Openterface's audio, allow microphone access in System Settings > Privacy & Security > Microphone."
        }
        if let problem = await link.openSerial() {
            app?.lastError = problem
        }

        let reason = await withTaskCancellationHandler {
            await link.waitUntilEnded()
        } onCancel: {
            Task { @MainActor in link.finish(nil) }
        }
        teardown()
        if reason != nil {
            // Unplugged: forget the unit so the next attempt looks for it again.
            app?.session(for: selection.deviceID).disconnect()
        }
        if !Task.isCancelled {
            state = reason.map { .failed($0) } ?? .connecting
        }
        return reason == nil
    }

    /// Types text as US-layout key presses at the chosen typing rate.
    func typeTextOnOpenterface(_ text: String, link: OpenterfaceConsoleLink) {
        guard pasteProgress == nil else { return }
        let characters = Array(text)
        let total = characters.count
        // Each key event is a 14-byte frame; leave the serial port time to send it.
        let delay = max(typingRate.delay, 0.01)
        pasteProgress = PasteProgress(typed: 0, total: total)
        pasteTask = Task { [weak self] in
            var typed = 0
            var skipped = 0
            for character in characters {
                if Task.isCancelled { break }
                if !link.type(character) { skipped += 1 }
                typed += 1
                if typed % 8 == 0 || typed == total {
                    self?.pasteProgress = PasteProgress(typed: typed, total: total)
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 2 * 1_000_000_000))
            }
            if skipped > 0 {
                self?.app?.lastError = "\(skipped) character\(skipped == 1 ? "" : "s") couldn't be typed. Openterface pastes with a US keyboard layout."
            }
            self?.pasteProgress = nil
            self?.pasteTask = nil
        }
    }
}
