import Foundation

/// One page of the built-in help. The text is written in a small subset of
/// Markdown (see `HelpBlock.parse`), so topics stay easy to edit in
/// `HelpTopics.swift`.
struct HelpTopic: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    /// Extra words people might search for that don't appear in the text.
    let keywords: [String]
    let body: String

    init(_ id: String, title: String, symbol: String, keywords: [String] = [], body: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.body = body
    }

    var blocks: [HelpBlock] { HelpBlock.parse(body) }

    /// The first paragraph, shown as a summary in Help menu search results.
    var summary: String {
        for block in blocks { if case .paragraph(let text) = block { return HelpTopic.plain(text) } }
        return title
    }

    /// Link to a topic from another topic's text: `[Certificates](help:certificates)`.
    static let linkScheme = "help"

    static func topic(_ id: String) -> HelpTopic? { all.first { $0.id == id } }

    // MARK: Search

    /// Topics containing every word of the search, best matches first:
    /// title hits rank above keyword and heading hits, which rank above body hits.
    static func search(_ query: String, in topics: [HelpTopic] = all) -> [HelpTopic] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return topics }
        return topics.compactMap { topic -> (HelpTopic, Int)? in
            let title = topic.title
            let tags = (topic.keywords + topic.headings).joined(separator: " ")
            let body = plain(topic.body)
            var score = 0
            for word in words {
                if contains(title, word) { score += 10 }
                else if contains(tags, word) { score += 4 }
                else if contains(body, word) { score += 1 }
                else { return nil }
            }
            return (topic, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private var headings: [String] {
        blocks.compactMap { block -> String? in
            if case .heading(let h) = block { return h }
            return nil
        }
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The text without Markdown link targets and emphasis markers.
    static func plain(_ markdown: String) -> String {
        var s = markdown.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
        for mark in ["**", "`", "[", "]"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s
    }
}

/// A block of help text. The supported syntax, one construct per line:
///
///     ## Heading
///     A paragraph; consecutive lines join into one.
///     - A bullet
///     1. A numbered step
///     > A note, shown in a box
///     = ⌘N | What the shortcut does
///
/// Inline Markdown (bold, `code`, links) works inside all of them.
enum HelpBlock: Hashable, Sendable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case steps([String])
    case note(String)
    case shortcuts([Shortcut])

    struct Shortcut: Hashable, Sendable {
        let keys: String
        let action: String
    }

    static func parse(_ text: String) -> [HelpBlock] {
        var blocks: [HelpBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }

            if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                let item = String(line.dropFirst(2))
                if case .bullets(let items) = blocks.last { blocks[blocks.count - 1] = .bullets(items + [item]) }
                else { blocks.append(.bullets([item])) }
            } else if let step = numberedItem(line) {
                flushParagraph()
                if case .steps(let items) = blocks.last { blocks[blocks.count - 1] = .steps(items + [step]) }
                else { blocks.append(.steps([step])) }
            } else if line.hasPrefix("> ") {
                flushParagraph()
                let text = String(line.dropFirst(2))
                if case .note(let previous) = blocks.last { blocks[blocks.count - 1] = .note(previous + " " + text) }
                else { blocks.append(.note(text)) }
            } else if line.hasPrefix("= ") {
                flushParagraph()
                let parts = line.dropFirst(2).split(separator: "|", maxSplits: 1)
                let row = Shortcut(keys: parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
                                   action: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
                if case .shortcuts(let rows) = blocks.last { blocks[blocks.count - 1] = .shortcuts(rows + [row]) }
                else { blocks.append(.shortcuts([row])) }
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// "3. Text" -> "Text".
    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
              line[..<dot].allSatisfy(\.isNumber),
              line[line.index(after: dot)...].hasPrefix(" ") else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }
}
