import Foundation

/// Reads key combinations written the way people (and language models)
/// write them, such as "ctrl+alt+delete", "F2", "Enter" or "shift+tab", and
/// turns them into the web `KeyboardEvent.code` names the consoles send.
public enum KeyCombo {
    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case unknownKey(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "No key was given."
            case .unknownKey(let k):
                return "Unknown key \"\(k)\". Use names like ctrl, alt, shift, meta, enter, esc, tab, space, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1–f20, a–z, 0–9, or web key codes such as KeyA."
            }
        }
    }

    /// Every code a console can send.
    public static let knownCodes: Set<String> = Set(KeyMap.table.values)

    /// Parses one combination. Keys are joined with "+"; modifiers go first.
    public static func parse(_ combo: String) throws -> [String] {
        let trimmed = combo.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        // "+" on its own, or at the end ("shift++"), is the plus key.
        var parts: [String] = []
        var current = ""
        for ch in trimmed {
            if ch == "+" && !current.isEmpty {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        var codes: [String] = []
        for part in parts {
            let code = try code(for: part.trimmingCharacters(in: .whitespaces))
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// The code for one key name.
    public static func code(for name: String) throws -> String {
        guard !name.isEmpty else { throw ParseError.empty }
        if knownCodes.contains(name) { return name }
        let lower = name.lowercased()
        if let alias = aliases[lower] { return alias }
        if lower.count == 1, let ch = lower.first {
            if ch.isLetter, ch.isASCII { return "Key" + ch.uppercased() }
            if ch.isNumber, ch.isASCII { return "Digit" + String(ch) }
            if let p = punctuation[ch] { return p }
        }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...20).contains(n) { return "F\(n)" }
        // Case-insensitive match of a web code, such as "keya" or "arrowup".
        if let match = knownCodes.first(where: { $0.lowercased() == lower }) { return match }
        throw ParseError.unknownKey(name)
    }

    static let aliases: [String: String] = [
        "ctrl": "ControlLeft", "control": "ControlLeft", "lctrl": "ControlLeft", "rctrl": "ControlRight",
        "alt": "AltLeft", "option": "AltLeft", "opt": "AltLeft", "lalt": "AltLeft", "ralt": "AltRight", "altgr": "AltRight",
        "shift": "ShiftLeft", "lshift": "ShiftLeft", "rshift": "ShiftRight",
        "meta": "MetaLeft", "cmd": "MetaLeft", "command": "MetaLeft", "win": "MetaLeft", "windows": "MetaLeft",
        "super": "MetaLeft", "gui": "MetaLeft",
        "enter": "Enter", "return": "Enter", "esc": "Escape", "escape": "Escape", "tab": "Tab", "space": "Space",
        "spacebar": "Space", "backspace": "Backspace", "bksp": "Backspace", "delete": "Delete", "del": "Delete",
        "insert": "Insert", "ins": "Insert", "home": "Home", "end": "End",
        "pageup": "PageUp", "pgup": "PageUp", "pagedown": "PageDown", "pgdn": "PageDown",
        "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight",
        "capslock": "CapsLock", "numlock": "NumLock", "scrolllock": "ScrollLock",
        "printscreen": "PrintScreen", "prtsc": "PrintScreen", "sysrq": "PrintScreen", "pause": "Pause", "break": "Pause",
        "menu": "ContextMenu", "apps": "ContextMenu", "plus": "Equal", "minus": "Minus",
    ]

    static let punctuation: [Character: String] = [
        "-": "Minus", "=": "Equal", "+": "Equal", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash",
        ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash", "`": "Backquote",
    ]
}
