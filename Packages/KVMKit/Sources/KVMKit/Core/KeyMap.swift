import Foundation

/// Maps macOS virtual key codes (`NSEvent.keyCode`, ANSI layout positions)
/// to the web `KeyboardEvent.code` names kvmd expects. Because both are
/// position-based, the remote machine's own keyboard layout decides which
/// character a key produces.
public enum KeyMap {
    public static func webCode(forMacKeyCode keyCode: UInt16) -> String? {
        table[keyCode]
    }

    /// Key codes of modifier keys, which arrive as `flagsChanged` events.
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]
    public static let capsLockKeyCode: UInt16 = 57

    static let table: [UInt16: String] = [
        // Letters
        0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF", 5: "KeyG", 4: "KeyH",
        34: "KeyI", 38: "KeyJ", 40: "KeyK", 37: "KeyL", 46: "KeyM", 45: "KeyN", 31: "KeyO", 35: "KeyP",
        12: "KeyQ", 15: "KeyR", 1: "KeyS", 17: "KeyT", 32: "KeyU", 9: "KeyV", 13: "KeyW", 7: "KeyX",
        16: "KeyY", 6: "KeyZ",
        // Digits
        29: "Digit0", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5",
        22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9",
        // Punctuation
        50: "Backquote", 27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight",
        42: "Backslash", 41: "Semicolon", 39: "Quote", 43: "Comma", 47: "Period", 44: "Slash",
        10: "IntlBackslash", 94: "IntlRo", 93: "IntlYen",
        // Whitespace and editing
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete",
        114: "Insert", // the Help key sits where Insert is on PC keyboards
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        // Modifiers
        56: "ShiftLeft", 60: "ShiftRight", 59: "ControlLeft", 62: "ControlRight",
        58: "AltLeft", 61: "AltRight", 55: "MetaLeft", 54: "MetaRight", 57: "CapsLock",
        110: "ContextMenu",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "PrintScreen", // F13
        107: "ScrollLock", // F14
        113: "Pause", // F15
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        // Keypad
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4", 87: "Numpad5",
        88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
        65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 75: "NumpadDivide",
        76: "NumpadEnter", 78: "NumpadSubtract", 71: "NumLock", // the Clear key
        // Media
        72: "AudioVolumeUp", 73: "AudioVolumeDown", 74: "AudioVolumeMute",
    ]
}
