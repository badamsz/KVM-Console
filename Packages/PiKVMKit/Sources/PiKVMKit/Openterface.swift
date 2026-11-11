import Foundation

// Openterface (https://openterface.com) is a USB KVM that plugs straight into
// this Mac. It shows up as three things on a small internal USB hub:
//
// * a UVC capture device (MacroSilicon MS2109 / MS2109S / MS2130S) carrying
//   the target's HDMI video, plus a USB audio input with its sound;
// * a serial port (a WCH CH340 bridge to a CH9329 HID emulator on the
//   original Mini-KVM, or a CH32V208 on newer Mini-KVMs and the KVM-GO) that
//   turns commands into USB keyboard and mouse reports on the target.
//
// The KVM-GO (USB 2.0 and USB 3.0 versions) pairs an MS2130S capture chip
// with a CH32V208, which also switches the unit's microSD card between the
// target and this Mac.
//
// The serial protocol is WCH's published CH9329 command protocol. This file
// is written from that protocol, not from Openterface's own (AGPL) code.

/// USB identities of Openterface parts, and helpers to tell which capture
/// device, serial port and audio input belong to the same unit.
public enum OpenterfaceHardware {
    public struct USBID: Hashable, Sendable {
        public let vendor: UInt16
        public let product: UInt16

        public init(vendor: UInt16, product: UInt16) {
            self.vendor = vendor
            self.product = product
        }
    }

    /// HDMI capture chips, by name.
    public static let videoChips: [USBID: String] = [
        USBID(vendor: 0x534D, product: 0x2109): "MS2109",
        USBID(vendor: 0x345F, product: 0x2109): "MS2109S",
        USBID(vendor: 0x345F, product: 0x2132): "MS2130S",
    ]

    /// Keyboard and mouse controllers, by name. Both speak the CH9329 protocol.
    public static let controlChips: [USBID: String] = [
        USBID(vendor: 0x1A86, product: 0x7523): "CH9329",
        USBID(vendor: 0x1A86, product: 0xFE0C): "CH32V208",
    ]

    /// Names Openterface units give their audio input, for when the audio
    /// device's ID doesn't carry a USB location.
    public static let audioNames = ["OpenterfaceA", "USB2 Digital Audio"]

    /// Reads the USB location and IDs out of a macOS capture device's
    /// `uniqueID`, which for a UVC camera is `0x` followed by the location ID
    /// (32 bits), vendor ID and product ID (16 bits each) in hex, such as
    /// `0x14210000534d2109`.
    public static func parseCaptureUniqueID(_ uniqueID: String) -> (location: UInt32, id: USBID)? {
        var hex = uniqueID.lowercased()
        guard hex.hasPrefix("0x") else { return nil }
        hex.removeFirst(2)
        guard (9...16).contains(hex.count), let value = UInt64(hex, radix: 16) else { return nil }
        let id = USBID(vendor: UInt16((value >> 16) & 0xFFFF), product: UInt16(value & 0xFFFF))
        return (UInt32(truncatingIfNeeded: value >> 32), id)
    }

    /// Reads the vendor and product out of a capture device's `modelID`,
    /// such as `UVC Camera VendorID_21325 ProductID_8457` (decimal).
    public static func parseModelID(_ modelID: String) -> USBID? {
        func number(after key: String) -> UInt16? {
            guard let range = modelID.range(of: key) else { return nil }
            let digits = modelID[range.upperBound...].prefix { $0.isNumber }
            return UInt16(digits)
        }
        guard let vendor = number(after: "VendorID_"), let product = number(after: "ProductID_") else { return nil }
        return USBID(vendor: vendor, product: product)
    }

    /// Whether a capture device is an Openterface's video, judging by its IDs.
    public static func isVideoCapture(uniqueID: String, modelID: String) -> Bool {
        if let parsed = parseCaptureUniqueID(uniqueID), videoChips[parsed.id] != nil { return true }
        if let id = parseModelID(modelID), videoChips[id] != nil { return true }
        return false
    }

    /// The location of the hub a USB device hangs off. A location ID is the
    /// bus number in the top byte, then one hex digit per hub port on the way
    /// to the device; the hub's location drops the last port.
    public static func parentLocation(of location: UInt32) -> UInt32? {
        for shift in stride(from: 0, through: 20, by: 4) where (location >> UInt32(shift)) & 0xF != 0 {
            return location & ~(UInt32(0xF) << UInt32(shift))
        }
        return nil
    }

    /// Whether two USB devices sit on the same hub, as the parts of one
    /// Openterface do.
    public static func shareHub(_ a: UInt32, _ b: UInt32) -> Bool {
        guard let pa = parentLocation(of: a), let pb = parentLocation(of: b) else { return false }
        return pa == pb
    }

    /// The hub ports on the way to a device, after the bus byte.
    static func portPath(_ location: UInt32) -> [UInt8] {
        var path: [UInt8] = []
        for shift in stride(from: 20, through: 0, by: -4) {
            let port = UInt8((location >> UInt32(shift)) & 0xF)
            if port == 0 { break }
            path.append(port)
        }
        return path
    }

    /// Whether a capture chip and a serial controller come through the same
    /// physical USB port when one of them runs at USB 3 speed. A USB-C port
    /// shows up as two root ports on one bus, a SuperSpeed one and a USB 2
    /// one (on Apple silicon, `…2…` and `…1…`), and a USB 3 hub likewise
    /// shows up once on each. So the paths match once the root port is left
    /// out.
    ///
    /// * KVM-GO: the MS2130S is on the port's SuperSpeed lanes (`0x03240000`)
    ///   while the CH32V208 is behind a USB 2 hub on the same port
    ///   (`0x03142000`, hub `0x03140000`).
    /// * A unit with a USB 3 hub inside: both are on that hub, on its two halves.
    public static func sharePhysicalPort(video: UInt32, serial: UInt32) -> Bool {
        guard video >> 24 == serial >> 24 else { return false }
        let v = portPath(video).dropFirst(), s = portPath(serial).dropFirst()
        guard !portPath(video).isEmpty, !s.isEmpty else { return false }
        // The serial controller's hub sits where the capture chip is.
        if Array(v) == Array(s.dropLast()) { return true }
        // Both on the two halves of one USB 3 hub.
        let vHub = Array(v.dropLast()), sHub = Array(s.dropLast())
        return !v.isEmpty && !vHub.isEmpty && vHub == sHub
    }

    /// The location as it appears inside a Core Audio device UID, such as
    /// `AppleUSBAudioEngine:…:14210000:3`.
    public static func audioLocationTag(_ location: UInt32) -> String {
        String(format: "%08x", location)
    }

    /// Scales a 0...32767 position (`HIDReport.absolutePosition`) to the
    /// CH9329's 0...4095 absolute range.
    public static func absoluteCoordinate(_ v: UInt16) -> UInt16 {
        UInt16((Double(min(v, 32767)) / 32767 * 4095).rounded())
    }
}

/// The CH9329 serial command protocol, used by every Openterface controller.
///
/// A frame is `57 AB`, an address (`00`), a command, a payload length, the
/// payload, and a checksum: the low byte of the sum of all earlier bytes.
/// The chip answers each command with the same frame shape, the command
/// byte OR'd with `0x80` (success) or `0xC0` (error).
public enum CH9329 {
    public static let header: [UInt8] = [0x57, 0xAB]
    public static let address: UInt8 = 0x00

    public enum Command: UInt8, Sendable {
        case getInfo = 0x01
        case keyboard = 0x02
        case mediaKey = 0x03
        case absoluteMouse = 0x04
        case relativeMouse = 0x05
        case getConfig = 0x08
        case setConfig = 0x09
        case reset = 0x0F
        /// CH32V208 only (KVM-GO): which side the microSD card is connected to.
        case sdCard = 0x17
    }

    /// Which machine a KVM-GO's microSD card is connected to.
    public enum SDCardSide: UInt8, Sendable {
        /// This Mac (the Openterface's host side).
        case host = 0x00
        /// The machine being controlled.
        case target = 0x01

        /// Reads the answer to `sdCard`, which the unit also sends by itself
        /// when its button switches the card.
        public init?(_ response: Response) {
            guard !response.isError, response.answers == Command.sdCard.rawValue,
                  let byte = response.payload.first else { return nil }
            self.init(rawValue: byte)
        }
    }

    /// Switches the microSD card to `side`, or asks where it is when nil.
    public static func sdCard(_ side: SDCardSide?) -> Data {
        frame(.sdCard, [0, 0, 0, 0, side?.rawValue ?? 0x03])
    }

    /// Serial speeds the chip is found at: 115200 (Openterface's default) or
    /// 9600 (the CH9329's factory setting).
    public static let baudRates = [115_200, 9_600]

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    public static func frame(_ command: Command, _ payload: [UInt8] = []) -> Data {
        frame(command: command.rawValue, payload)
    }

    static func frame(command: UInt8, _ payload: [UInt8]) -> Data {
        var bytes = header + [address, command, UInt8(payload.count)] + payload
        bytes.append(checksum(bytes))
        return Data(bytes)
    }

    /// Asks for the chip version, whether the target has enumerated it, and
    /// the keyboard lights.
    public static var getInfo: Data { frame(.getInfo) }

    /// Sends an 8-byte boot keyboard report (`HIDReport.Keyboard.report`).
    public static func keyboard(_ report: Data) -> Data {
        var payload = [UInt8](report.prefix(8))
        payload += [UInt8](repeating: 0, count: 8 - payload.count)
        return frame(.keyboard, payload)
    }

    /// An absolute mouse report. `x` and `y` are in 0...4095; positive
    /// `wheel` scrolls up.
    public static func absoluteMouse(buttons: UInt8, x: UInt16, y: UInt16, wheel: Int = 0) -> Data {
        let cx = min(x, 4095), cy = min(y, 4095)
        return frame(.absoluteMouse, [0x02, buttons & 0x07, UInt8(cx & 0xFF), UInt8(cx >> 8),
                                      UInt8(cy & 0xFF), UInt8(cy >> 8), signedByte(wheel)])
    }

    /// A relative mouse report. Deltas are clamped to -127...127.
    public static func relativeMouse(buttons: UInt8, dx: Int = 0, dy: Int = 0, wheel: Int = 0) -> Data {
        frame(.relativeMouse, [0x01, buttons & 0x07, signedByte(dx), signedByte(dy), signedByte(wheel)])
    }

    private static func signedByte(_ v: Int) -> UInt8 {
        UInt8(bitPattern: Int8(max(-127, min(127, v))))
    }

    /// A frame received from the chip.
    public struct Response: Equatable, Sendable {
        public let command: UInt8
        public let payload: [UInt8]

        /// The command this answers.
        public var answers: UInt8 { command & 0x3F }
        public var isError: Bool { command & 0xC0 == 0xC0 }
    }

    /// The answer to `getInfo`.
    public struct Info: Equatable, Sendable {
        public let version: UInt8
        /// Whether the target machine has enumerated the keyboard and mouse.
        public let targetConnected: Bool
        public let numLock: Bool
        public let capsLock: Bool
        public let scrollLock: Bool

        public init?(_ response: Response) {
            guard !response.isError, response.answers == Command.getInfo.rawValue, response.payload.count >= 3 else { return nil }
            version = response.payload[0]
            targetConnected = response.payload[1] != 0
            let leds = response.payload[2]
            numLock = leds & 0x01 != 0
            capsLock = leds & 0x02 != 0
            scrollLock = leds & 0x04 != 0
        }
    }

    /// Splits the serial byte stream into frames, skipping noise and frames
    /// with a bad checksum.
    public struct Parser: Sendable {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func feed(_ data: Data) -> [Response] {
            buffer.append(contentsOf: data)
            var out: [Response] = []
            while true {
                // Drop anything before the next header.
                guard let start = headerIndex() else {
                    // Keep a trailing 0x57 that may start the next header.
                    buffer = buffer.last == header[0] ? [header[0]] : []
                    break
                }
                if start > 0 { buffer.removeFirst(start) }
                guard buffer.count >= 5 else { break }
                let length = Int(buffer[4])
                let total = 5 + length + 1
                guard buffer.count >= total else { break }
                let body = buffer[0..<(total - 1)]
                if checksum(body) == buffer[total - 1] {
                    out.append(Response(command: buffer[3], payload: Array(buffer[5..<(5 + length)])))
                    buffer.removeFirst(total)
                } else {
                    // Not a real frame: look for the next header after this one.
                    buffer.removeFirst(1)
                }
            }
            if buffer.count > 4096 { buffer.removeAll() }
            return out
        }

        private func headerIndex() -> Int? {
            guard buffer.count >= 2 else { return nil }
            for i in 0..<(buffer.count - 1) where buffer[i] == header[0] && buffer[i + 1] == header[1] {
                return i
            }
            return nil
        }
    }
}

/// Turns text into key presses for a US keyboard layout, for typing pasted
/// text through a plain USB keyboard (Openterface has no paste API).
public enum USKeyboardTyping {
    public struct Stroke: Equatable, Sendable {
        /// Web `KeyboardEvent.code`, as used by `HIDReport.Keyboard`.
        public let code: String
        public let shift: Bool
    }

    /// The key (and whether Shift is held) that types `character`, or nil
    /// when a US keyboard has no key for it.
    public static func stroke(for character: Character) -> Stroke? {
        if character == "\n" || character == "\r\n" { return Stroke(code: "Enter", shift: false) }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.isASCII else { return nil }
        let c = Character(scalar)
        if let letter = c.lowercased().first, ("a"..."z").contains(letter) {
            return Stroke(code: "Key" + letter.uppercased(), shift: c.isUppercase)
        }
        if c.isNumber, let digit = c.wholeNumberValue { return Stroke(code: "Digit\(digit)", shift: false) }
        if let (code, shift) = symbols[c] { return Stroke(code: code, shift: shift) }
        return nil
    }

    private static let symbols: [Character: (String, Bool)] = [
        " ": ("Space", false), "\t": ("Tab", false),
        "-": ("Minus", false), "_": ("Minus", true), "=": ("Equal", false), "+": ("Equal", true),
        "[": ("BracketLeft", false), "{": ("BracketLeft", true), "]": ("BracketRight", false), "}": ("BracketRight", true),
        "\\": ("Backslash", false), "|": ("Backslash", true), ";": ("Semicolon", false), ":": ("Semicolon", true),
        "'": ("Quote", false), "\"": ("Quote", true), "`": ("Backquote", false), "~": ("Backquote", true),
        ",": ("Comma", false), "<": ("Comma", true), ".": ("Period", false), ">": ("Period", true),
        "/": ("Slash", false), "?": ("Slash", true),
        "!": ("Digit1", true), "@": ("Digit2", true), "#": ("Digit3", true), "$": ("Digit4", true),
        "%": ("Digit5", true), "^": ("Digit6", true), "&": ("Digit7", true), "*": ("Digit8", true),
        "(": ("Digit9", true), ")": ("Digit0", true),
    ]
}
