import Foundation

/// Prepares clipboard text for typing on the remote machine through
/// kvmd's `/api/hid/print`, which turns characters into key presses.
public enum TextPaste {
    /// Characters per request. Small enough that progress is visible and
    /// a cancel takes effect quickly, even at slow typing rates.
    public static let chunkSize = 64

    /// Normalises line endings to `\n` (typed as Enter) and drops
    /// characters kvmd can't type anyway (other control characters).
    public static func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars
        where scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Splits text into chunks of at most `size` characters.
    public static func chunks(_ text: String, size: Int = chunkSize) -> [String] {
        guard size > 0, !text.isEmpty else { return [] }
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[start..<end]))
            start = end
        }
        return out
    }

    /// A rough time to type `count` characters, in seconds. kvmd presses
    /// and releases each key, pausing `delay` after each event.
    public static func estimatedDuration(characters count: Int, delay: TimeInterval) -> TimeInterval {
        Double(count) * max(delay * 2, 0.004)
    }
}

/// One thing to do while typing pasted text.
public enum PasteStep: Equatable, Sendable {
    /// Type these characters (a newline is Enter).
    case text(String)
    /// Empty the line the cursor is on, removing the indent an editor added
    /// after the Enter just typed. See `TextPaste.formattedSteps`.
    case clearLine
}

extension TextPaste {
    /// Typed on a fresh line before clearing it, so the line is never empty
    /// when it's selected: the selection always holds at least this
    /// character, and Backspace removes the selection rather than joining
    /// the line onto the one above.
    public static let lineSentinel = "x"

    /// Plain paste: the text as it is.
    public static func plainSteps(_ text: String) -> [PasteStep] {
        text.isEmpty ? [] : [.text(text)]
    }

    /// Formatted paste, for editors that indent a new line to match the one
    /// above (VS Code, JetBrains, Xcode, Sublime). Typing text with its own
    /// indentation there indents every line twice. So after each Enter the
    /// line is cleared first, and then the next line is typed with its own
    /// indentation, which leaves the result exactly as it was copied. The
    /// first line is typed as it is, where the cursor already is.
    /// Whitespace-only lines are left empty.
    public static func formattedSteps(_ text: String) -> [PasteStep] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return plainSteps(text) }
        var steps: [PasteStep] = []
        var pending = String(lines[0])
        for line in lines.dropFirst() {
            pending += "\n"
            steps.append(.text(pending))
            steps.append(.clearLine)
            pending = line.allSatisfy { $0 == " " || $0 == "\t" } ? "" : String(line)
        }
        if !pending.isEmpty { steps.append(.text(pending)) }
        return steps
    }

    public static func steps(_ text: String, mode: PasteMode) -> [PasteStep] {
        switch mode {
        case .plain: return plainSteps(text)
        case .formatted: return formattedSteps(text)
        }
    }
}

/// How pasted text is typed.
public enum PasteMode: String, CaseIterable, Identifiable, Sendable {
    /// Every character as it is.
    case plain
    /// Each line's indent replaces the one an editor adds after Enter.
    case formatted

    public var id: String { rawValue }
}

/// The shortcut that selects back to the start of the line on the remote
/// machine, used by formatted paste. Pressed twice: editors with "smart
/// home" go to the first non-blank character first, then to the start.
public enum LineStartKey: String, CaseIterable, Identifiable, Sendable {
    /// Shift+Home, on Windows and Linux.
    case home
    /// Shift+Command+Left Arrow, on a Mac.
    case commandLeft

    public var id: String { rawValue }

    /// Web `KeyboardEvent.code`s, pressed in order and released in reverse.
    public var selectCombo: [String] {
        switch self {
        case .home: return ["ShiftLeft", "Home"]
        case .commandLeft: return ["ShiftLeft", "MetaLeft", "ArrowLeft"]
        }
    }

    public var displayName: String {
        switch self {
        case .home: return "Windows or Linux (Shift+Home)"
        case .commandLeft: return "macOS (Shift+Command+Left)"
        }
    }
}

/// How fast pasted text is typed.
public enum TypingRate: String, CaseIterable, Identifiable, Sendable {
    case fastest, fast, normal, slow, verySlow

    public var id: String { rawValue }

    /// The pause kvmd inserts after each key event, in seconds.
    public var delay: TimeInterval {
        switch self {
        case .fastest: return 0
        case .fast: return 0.01
        case .normal: return 0.02
        case .slow: return 0.05
        case .verySlow: return 0.1
        }
    }

    public var displayName: String {
        switch self {
        case .fastest: return "Fastest"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .slow: return "Slow"
        case .verySlow: return "Very Slow"
        }
    }

    public var detail: String {
        switch self {
        case .fastest: return "no pause; some systems drop keys"
        case .fast: return "about 50 characters a second"
        case .normal: return "about 25 characters a second"
        case .slow: return "about 10 characters a second"
        case .verySlow: return "about 5 characters a second, for BIOS screens"
        }
    }
}
