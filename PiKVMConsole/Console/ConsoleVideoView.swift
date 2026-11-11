import AppKit
import AVFoundation
import PiKVMKit
import SwiftUI

/// SwiftUI wrapper for the console's video and input view.
struct ConsoleVideoView: NSViewRepresentable {
    let model: ConsoleModel
    // Passed in (rather than read from the model here) so SwiftUI updates
    // this view whenever they change.
    let frame: CGImage?
    /// The view WebRTC renders into while H.264 is active; nil for MJPEG.
    let liveView: NSView?
    let videoSize: CGSize
    let mouseMode: MouseMode
    let captured: Bool

    func makeNSView(context: Context) -> ConsoleNSView {
        ConsoleNSView(model: model)
    }

    func updateNSView(_ view: ConsoleNSView, context: Context) {
        view.display(frame: frame)
        view.setLiveView(liveView, videoSize: videoSize)
        view.apply(mouseMode: mouseMode, captured: captured)
    }

    static func dismantleNSView(_ view: ConsoleNSView, coordinator: ()) {
        view.releaseEverything()
    }
}

/// Shows the video and forwards keyboard and mouse events to the PiKVM.
///
/// Absolute mode: the Mac cursor is hidden over the video and its position
/// is mapped onto the remote screen.
/// Relative mode: clicking the video captures the cursor; movement is sent
/// as deltas until Control+Option is pressed.
final class ConsoleNSView: NSView {
    private let model: ConsoleModel
    private let videoLayer = CALayer()
    private var mouseMode: MouseMode = .absolute
    private var captured = false
    private var pressedKeys = Set<String>()
    private var pressedModifiers = Set<UInt16>()
    private var pressedButtons = Set<MouseButton>()
    private var trackingArea: NSTrackingArea?
    private var cursorHidden = false

    // Absolute moves are coalesced to at most one per 10 ms, like the web UI.
    private var pendingMove: CGPoint?
    private var moveTimer: Timer?
    // Relative deltas and scrolling are accumulated between timer ticks.
    private var pendingDX = 0.0, pendingDY = 0.0
    private var scrollX = 0.0, scrollY = 0.0

    /// Wheel steps sent per scroll notch (the web UI's default rate).
    private let scrollRate = 5
    /// Points of trackpad scrolling per wheel step.
    private let scrollStep = 12.0

    init(model: ConsoleModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.magnificationFilter = .linear
        videoLayer.minificationFilter = .trilinear
        videoLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
        liveView?.frame = videoRect()
    }

    /// All input is handled here, never by the video subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private var liveView: NSView?

    /// Shows (or removes) the WebRTC video view, fitted to the video's aspect ratio.
    func setLiveView(_ view: NSView?, videoSize: CGSize) {
        if view !== liveView {
            liveView?.removeFromSuperview()
            liveView = view
            if let view {
                view.autoresizingMask = []
                addSubview(view)
            }
        }
        liveView?.frame = videoRect()
    }

    // MARK: State from SwiftUI

    func display(frame: CGImage?) {
        videoLayer.contents = frame
    }

    func apply(mouseMode: MouseMode, captured: Bool) {
        self.mouseMode = mouseMode
        if captured != self.captured { setCaptured(captured) }
        if mouseMode == .absolute, self.captured { setCaptured(false) }
    }

    // MARK: Window and focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            releaseEverything()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged(_:)),
                                               name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenChanged(_:)),
                                               name: NSWindow.willExitFullScreenNotification, object: window)
        model.isFullScreen = window.styleMask.contains(.fullScreen)
        window.makeFirstResponder(self)
        startMoveTimer()
    }

    @objc private func windowLostFocus() {
        releaseEverything()
    }

    @objc private func fullScreenChanged(_ note: Notification) {
        model.isFullScreen = note.name == NSWindow.didEnterFullScreenNotification
    }

    override func resignFirstResponder() -> Bool {
        releaseEverything()
        return super.resignFirstResponder()
    }

    /// Releases held keys and buttons on the remote machine and frees the cursor,
    /// so nothing stays stuck down when the console loses focus.
    func releaseEverything() {
        releaseKeys()
        for button in pressedButtons { model.mouseButton(button, down: false) }
        pressedButtons.removeAll()
        if captured { setCaptured(false) }
        showCursor()
    }

    /// Releases every key held on the remote machine, including modifiers.
    func releaseKeys() {
        for code in pressedKeys { model.key(code, down: false) }
        pressedKeys.removeAll()
        for keyCode in pressedModifiers {
            if let code = KeyMap.webCode(forMacKeyCode: keyCode) { model.key(code, down: false) }
        }
        pressedModifiers.removeAll()
    }

    // MARK: Cursor

    private func setCaptured(_ on: Bool) {
        guard on != captured else { return }
        captured = on
        if on {
            CGAssociateMouseAndMouseCursorPosition(0)
            hideCursor()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            showCursor()
            pendingDX = 0
            pendingDY = 0
        }
        if model.mouseCaptured != on { model.mouseCaptured = on }
    }

    private func hideCursor() {
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    private func showCursor() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if mouseMode == .absolute, videoRect().contains(convert(event.locationInWindow, from: nil)) { hideCursor() }
    }

    override func mouseExited(with event: NSEvent) {
        if !captured { showCursor() }
    }

    // MARK: Geometry

    /// The rectangle the video occupies inside this view (aspect fit).
    private func videoRect() -> CGRect {
        let size = model.videoSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: size, insideRect: bounds)
    }

    /// Converts an event location to video pixels (origin top-left).
    private func videoPoint(for event: NSEvent) -> CGPoint? {
        let rect = videoRect()
        guard rect.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let size = model.videoSize
        return CGPoint(x: (p.x - rect.minX) / rect.width * size.width,
                       y: (p.y - rect.minY) / rect.height * size.height)
    }

    // MARK: Mouse

    private func startMoveTimer() {
        moveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushMovement() }
        }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            moveTimer?.invalidate()
            moveTimer = nil
        }
    }

    private func flushMovement() {
        if let point = pendingMove {
            pendingMove = nil
            model.mouseMove(toVideoPoint: point)
        }
        let dx = Int(pendingDX.rounded(.towardZero)), dy = Int(pendingDY.rounded(.towardZero))
        if dx != 0 || dy != 0 {
            pendingDX -= Double(dx)
            pendingDY -= Double(dy)
            model.mouseRelative(dx: dx, dy: dy)
        }
    }

    private func handleMove(_ event: NSEvent) {
        if mouseMode == .relative {
            guard captured else { return }
            pendingDX += event.deltaX
            pendingDY += event.deltaY
        } else if let point = videoPoint(for: event) {
            pendingMove = point
            if videoRect().contains(convert(event.locationInWindow, from: nil)) { hideCursor() } else { showCursor() }
        }
    }

    private func handleButton(_ button: MouseButton, down: Bool, event: NSEvent) {
        window?.makeFirstResponder(self)
        if mouseMode == .relative, !captured {
            // The first click only captures the cursor.
            if down { setCaptured(true) }
            return
        }
        if mouseMode == .absolute, let point = videoPoint(for: event) {
            pendingMove = point
        }
        flushMovement()
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        model.mouseButton(button, down: down)
    }

    private func otherButton(_ event: NSEvent) -> MouseButton? {
        switch event.buttonNumber {
        case 2: return .middle
        case 3: return .up
        case 4: return .down
        default: return nil
        }
    }

    override func mouseMoved(with event: NSEvent) { handleMove(event) }
    override func mouseDragged(with event: NSEvent) { handleMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMove(event) }
    override func otherMouseDragged(with event: NSEvent) { handleMove(event) }

    override func mouseDown(with event: NSEvent) { handleButton(.left, down: true, event: event) }
    override func mouseUp(with event: NSEvent) { handleButton(.left, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { handleButton(.right, down: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { handleButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) {
        if let button = otherButton(event) { handleButton(button, down: true, event: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if let button = otherButton(event) { handleButton(button, down: false, event: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        if mouseMode == .relative, !captured { return }
        var stepsX = 0, stepsY = 0
        if event.hasPreciseScrollingDeltas {
            // Trackpad: turn smooth scrolling into discrete wheel steps.
            scrollX += event.scrollingDeltaX
            scrollY += event.scrollingDeltaY
            stepsX = Int((scrollX / scrollStep).rounded(.towardZero))
            stepsY = Int((scrollY / scrollStep).rounded(.towardZero))
            scrollX -= Double(stepsX) * scrollStep
            scrollY -= Double(stepsY) * scrollStep
            if event.phase == .ended || event.momentumPhase == .ended { scrollX = 0; scrollY = 0 }
        } else {
            stepsX = event.scrollingDeltaX == 0 ? 0 : (event.scrollingDeltaX > 0 ? 1 : -1)
            stepsY = event.scrollingDeltaY == 0 ? 0 : (event.scrollingDeltaY > 0 ? 1 : -1)
        }
        // kvmd: positive y scrolls up, positive x scrolls left, matching AppKit's deltas.
        model.mouseWheel(dx: max(-1, min(1, stepsX)) * scrollRate, dy: max(-1, min(1, stepsY)) * scrollRate)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let code = KeyMap.webCode(forMacKeyCode: event.keyCode) else { return }
        // Key repeat is left to the remote machine, which repeats while the key is held.
        if event.isARepeat { return }
        pressedKeys.insert(code)
        model.key(code, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let code = KeyMap.webCode(forMacKeyCode: event.keyCode) else { return }
        pressedKeys.remove(code)
        model.key(code, down: false)
    }

    /// Sends Command shortcuts (Cmd+C, Cmd+Q, ...) to the remote machine
    /// instead of letting the app's menu handle them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        // Keep Ctrl+Cmd+F (full screen) for the Mac.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Also the app's other Control+Command shortcuts: T (toolbar in full screen), Delete
        // (Ctrl+Alt+Del), M (mouse mode), I (virtual media) and R (reconnect).
        if flags.contains([.command, .control]), [3, 17, 51, 46, 34, 15].contains(event.keyCode) { return false }
        // Option+Cmd+V types the Mac clipboard on the remote machine.
        if flags.subtracting([.capsLock, .numericPad, .function]) == [.command, .option], event.keyCode == 9 {
            if !event.isARepeat {
                // Let go of Option and Command on the remote first, or they'd modify the typed text.
                releaseKeys()
                model.pasteClipboard()
            }
            return true
        }
        // AppKit doesn't deliver keyUp while Command is held, so tap the key.
        if let code = KeyMap.webCode(forMacKeyCode: event.keyCode), !event.isARepeat {
            model.key(code, down: true)
            model.key(code, down: false)
        }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let keyCode = event.keyCode
        guard let code = KeyMap.webCode(forMacKeyCode: keyCode) else { return }

        if keyCode == KeyMap.capsLockKeyCode {
            // macOS reports Caps Lock as a toggle; the remote wants a tap.
            model.key(code, down: true)
            model.key(code, down: false)
            return
        }
        guard KeyMap.modifierKeyCodes.contains(keyCode) else { return }

        if pressedModifiers.contains(keyCode) {
            pressedModifiers.remove(keyCode)
            model.key(code, down: false)
        } else if event.modifierFlags.contains(Self.flag(for: keyCode)) {
            pressedModifiers.insert(keyCode)
            model.key(code, down: true)
            // Control+Option releases a captured mouse.
            if captured, Self.isControl(keyCode) || Self.isOption(keyCode),
               pressedModifiers.contains(where: Self.isControl), pressedModifiers.contains(where: Self.isOption) {
                releaseEverything()
            }
        }
    }

    private static func isControl(_ keyCode: UInt16) -> Bool { keyCode == 59 || keyCode == 62 }
    private static func isOption(_ keyCode: UInt16) -> Bool { keyCode == 58 || keyCode == 61 }

    private static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        default: return .command
        }
    }
}
