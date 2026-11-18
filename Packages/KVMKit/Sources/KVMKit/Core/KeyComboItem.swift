import Foundation

/// The operating system a key combination is meant for. It only changes how
/// keys are labelled (⌘ on a Mac, Win on Windows, Super on Linux); the same
/// key codes are sent either way.
public enum TargetOS: String, Codable, CaseIterable, Identifiable, Sendable {
    case windows, macOS, linux

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .macOS: return "macOS"
        case .linux: return "Linux"
        }
    }
}

/// A named key combination for the Send Keys menu, either built in
/// (`KeyComboLibrary`) or made by the user.
///
/// `keys` is written the way `KeyCombo.parse` reads it, such as
/// "ctrl+alt+delete". Several combinations pressed one after another are
/// separated by commas, such as "alt+sysrq+s, alt+sysrq+u, alt+sysrq+b";
/// `stepDelay` is the pause between them. A comma right after "+" (or on its
/// own) is the comma key, as in "cmd+,". "comma" also works.
public struct KeyComboItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var keys: String
    /// Only changes the labels. `nil` labels keys for no particular system.
    public var os: TargetOS?
    /// Seconds between the steps of a sequence.
    public var stepDelay: Double

    public static let defaultStepDelay = 0.15
    public static let stepDelayRange = 0.0...10.0
    /// At most this many steps, so a typo can't press keys for minutes.
    public static let maxSteps = 50

    public init(id: UUID = UUID(), name: String, keys: String, os: TargetOS? = nil,
                stepDelay: Double = KeyComboItem.defaultStepDelay) {
        self.id = id
        self.name = name
        self.keys = keys
        self.os = os
        self.stepDelay = stepDelay
    }

    enum CodingKeys: String, CodingKey { case id, name, keys, os, stepDelay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        keys = try c.decode(String.self, forKey: .keys)
        // An OS this version doesn't know is treated as none.
        os = (try? c.decodeIfPresent(TargetOS.self, forKey: .os)) ?? nil
        stepDelay = try c.decodeIfPresent(Double.self, forKey: .stepDelay) ?? Self.defaultStepDelay
    }

    /// The combinations to press, in order, as web `KeyboardEvent.code` names.
    public func steps() throws -> [[String]] {
        try Self.parseSteps(keys)
    }

    /// The delay, kept within `stepDelayRange`.
    public var clampedStepDelay: Double {
        min(max(stepDelay, Self.stepDelayRange.lowerBound), Self.stepDelayRange.upperBound)
    }

    /// The keys as they'd be printed on the target's keyboard, such as
    /// "Ctrl+Alt+Del" or "⌥⌘Esc". `nil` when they don't parse.
    public var keysLabel: String? {
        guard let steps = try? steps() else { return nil }
        return KeyComboLabel.label(steps, os: os)
    }

    /// The menu title: the name followed by the keys, or just the keys when
    /// it has no name.
    public var menuTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let label = keysLabel else { return trimmed.isEmpty ? keys : trimmed }
        if trimmed.isEmpty || trimmed == label { return label }
        return "\(trimmed) (\(label))"
    }

    /// A copy with a new identity, for adding a library combination to the
    /// user's own list.
    public func copy() -> KeyComboItem {
        KeyComboItem(name: name, keys: keys, os: os, stepDelay: stepDelay)
    }

    public enum StepError: Error, LocalizedError, Equatable {
        case tooManySteps(Int)
        case step(Int, KeyCombo.ParseError)

        public var errorDescription: String? {
            switch self {
            case .tooManySteps(let n): return "Use at most \(n) steps."
            case .step(let i, let error):
                return i == 0 ? error.errorDescription : "Step \(i + 1): \(error.errorDescription ?? "")"
            }
        }
    }

    /// Splits text into steps at commas and parses each one.
    public static func parseSteps(_ text: String) throws -> [[String]] {
        var pieces: [String] = []
        var current = ""
        for ch in text {
            let soFar = current.trimmingCharacters(in: .whitespaces)
            // A comma ends a step, unless it is the key itself: at the start
            // of a step, or right after "+".
            if ch == ",", !soFar.isEmpty, !soFar.hasSuffix("+") {
                pieces.append(soFar)
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || pieces.isEmpty { pieces.append(last) }
        guard pieces.count <= maxSteps else { throw StepError.tooManySteps(maxSteps) }
        return try pieces.enumerated().map { i, piece in
            do { return try KeyCombo.parse(piece) } catch let error as KeyCombo.ParseError {
                throw StepError.step(i, error)
            }
        }
    }
}

/// Readable names for key codes.
public enum KeyComboLabel {
    /// Labels a sequence: its steps joined with ", ".
    public static func label(_ steps: [[String]], os: TargetOS?) -> String {
        steps.map { label($0, os: os) }.joined(separator: ", ")
    }

    /// Labels one combination. On a Mac, modifiers are symbols with no "+"
    /// between them, as macOS writes shortcuts ("⌥⌘Esc").
    public static func label(_ codes: [String], os: TargetOS?) -> String {
        if os == .macOS {
            let isModifier = { (code: String) in macSymbols[code] != nil }
            // Mac order: ⌃⌥⇧⌘, then the other keys.
            let mods = codes.filter(isModifier).sorted { macOrder($0) < macOrder($1) }.compactMap { macSymbols[$0] }
            let rest = codes.filter { !isModifier($0) }.map { name($0, os: os) }
            let tail = rest.joined(separator: "+")
            return mods.joined() + tail
        }
        // On Linux, Alt+PrintScreen is the Magic SysRq key.
        let sysRq = os == .linux && codes.contains(where: { $0.hasPrefix("Alt") }) && codes.contains("PrintScreen")
        return codes.map { sysRq && $0 == "PrintScreen" ? "SysRq" : name($0, os: os) }.joined(separator: "+")
    }

    static let macSymbols: [String: String] = [
        "ControlLeft": "⌃", "ControlRight": "⌃", "AltLeft": "⌥", "AltRight": "⌥",
        "ShiftLeft": "⇧", "ShiftRight": "⇧", "MetaLeft": "⌘", "MetaRight": "⌘",
    ]

    static func macOrder(_ code: String) -> Int {
        if code.hasPrefix("Control") { return 0 }
        if code.hasPrefix("Alt") { return 1 }
        if code.hasPrefix("Shift") { return 2 }
        return 3
    }

    /// The name of one key, such as "Ctrl", "Win", "Del" or "F4".
    public static func name(_ code: String, os: TargetOS?) -> String {
        if code.hasPrefix("Key"), code.count == 4 { return String(code.dropFirst(3)) }
        if code.hasPrefix("Digit"), code.count == 6 { return String(code.dropFirst(5)) }
        if code.hasPrefix("Numpad"), code.count == 7 { return "Num" + code.dropFirst(6) }
        let side = code.hasSuffix("Right") ? "Right " : ""
        switch code {
        case "ControlLeft", "ControlRight": return side + (os == .macOS ? "Control" : "Ctrl")
        case "AltLeft", "AltRight":
            if os == .macOS { return side + "Option" }
            return code == "AltRight" && os != nil ? "AltGr" : side + "Alt"
        case "ShiftLeft", "ShiftRight": return side + "Shift"
        case "MetaLeft", "MetaRight":
            switch os {
            case .windows: return side + "Win"
            case .macOS: return side + "Cmd"
            case .linux: return side + "Super"
            case nil: return side + "Win"
            }
        default: return names[code] ?? code
        }
    }

    static let names: [String: String] = [
        "Escape": "Esc", "Delete": "Del", "Insert": "Ins", "Backspace": "Backspace", "Enter": "Enter",
        "Tab": "Tab", "Space": "Space", "PrintScreen": "PrtSc", "ScrollLock": "ScrLk", "Pause": "Pause",
        "ArrowUp": "Up", "ArrowDown": "Down", "ArrowLeft": "Left", "ArrowRight": "Right",
        "PageUp": "PgUp", "PageDown": "PgDn", "ContextMenu": "Menu", "CapsLock": "Caps Lock", "NumLock": "Num Lock",
        "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]", "Backslash": "\\",
        "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/", "Backquote": "`",
        "NumpadAdd": "Num+", "NumpadSubtract": "Num-", "NumpadMultiply": "Num*", "NumpadDivide": "Num/",
        "NumpadDecimal": "Num.", "NumpadEnter": "Num Enter",
        "AudioVolumeUp": "Volume Up", "AudioVolumeDown": "Volume Down", "AudioVolumeMute": "Mute",
    ]
}

/// Saves the user's own key combinations in `UserDefaults`.
public enum KeyComboStorage {
    public static let defaultsKey = "console.customKeyCombos"

    public static func load(from defaults: UserDefaults = .standard) -> [KeyComboItem] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([KeyComboItem].self, from: data)) ?? []
    }

    public static func save(_ items: [KeyComboItem], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
