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
