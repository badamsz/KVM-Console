import Foundation

/// Turns raw terminal output into plain text: removes ANSI escape
/// sequences and applies carriage returns (used by progress bars) by
/// overwriting the current line.
public struct TerminalText: Sendable {
    public private(set) var lines: [String] = [""]
    private var pendingEscape = ""
    private var afterCarriageReturn = false

    public init() {}

    public var text: String { lines.joined(separator: "\n") }

    public mutating func append(_ chunk: String) {
        let input = pendingEscape + chunk
        pendingEscape = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "\u{1B}" {
                guard let end = Self.escapeEnd(in: input, from: i) else {
                    pendingEscape = String(input[i...]) // sequence continues in the next chunk
                    return
                }
                i = end
                continue
            }
            i = input.index(after: i)
            switch c {
            case "\r\n":
                newLine()
            case "\n":
                newLine()
            case "\r":
                afterCarriageReturn = true
            case "\u{08}":
                if !lines[lines.count - 1].isEmpty { lines[lines.count - 1].removeLast() }
            case "\u{07}", "\0":
                break
            default:
                if afterCarriageReturn {
                    lines[lines.count - 1] = ""
                    afterCarriageReturn = false
                }
                lines[lines.count - 1].append(c)
            }
        }
    }

    private mutating func newLine() {
        afterCarriageReturn = false
        lines.append("")
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }

    /// Returns the index just past the escape sequence starting at `start`,
    /// or nil if the sequence is incomplete.
    private static func escapeEnd(in s: String, from start: String.Index) -> String.Index? {
        var i = s.index(after: start)
        guard i < s.endIndex else { return nil }
        let kind = s[i]
        i = s.index(after: i)
        switch kind {
        case "[": // CSI: parameters, then a final byte in @...~
            while i < s.endIndex {
                let c = s[i]
                i = s.index(after: i)
                if let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1, (0x40...0x7E).contains(v) { return i }
            }
            return nil
        case "]": // OSC: terminated by BEL or ESC \
            while i < s.endIndex {
                let c = s[i]
                i = s.index(after: i)
                if c == "\u{07}" { return i }
                if c == "\u{1B}" {
                    guard i < s.endIndex else { return nil }
                    return s.index(after: i)
                }
            }
            return nil
        case "(", ")": // charset selection: one more character
            return i < s.endIndex ? s.index(after: i) : nil
        default: // two-character escape
            return i
        }
    }
}

/// Runs `pikvm-update` through the PiKVM web terminal and interprets its
/// output. This type is the pure state machine; `WebTerminal` does the I/O.
///
/// The update is started detached from the terminal (`setsid nohup`) and
/// its log is followed with `tail`, so losing the connection (the script
/// restarts Tailscale, and the app may be closed) does not interrupt it.
public struct DeviceUpdateRun: Sendable {
    public enum Outcome: Equatable, Sendable {
        case upToDate
        /// Updated; the device reboots by itself in 30 seconds.
        case rebooting
        /// The root password was rejected.
        case wrongRootPassword
        /// `pikvm-update` exited with this code.
        case failed(code: Int)
    }

    public enum Phase: Equatable, Sendable {
        case starting
        case waitingForPasswordPrompt
        case running
        case finished(Outcome)
    }

    public static let logPath = "/tmp/pikvm-console-update.log"

    /// The command typed into the web terminal's shell. The markers are
    /// written so the terminal's echo of this line never matches them.
    public static let command =
        "su - -c 'setsid nohup sh -c \"pikvm-update; echo PIKVM_UPDATE_EXIT=\\$?\" >\(logPath) 2>&1 </dev/null &'"
        + " && tail -n +1 -F \(logPath) || echo PIKVM_UPDATE_SU_\"\"FAILED\n"

    public private(set) var phase: Phase = .starting
    public private(set) var output = TerminalText()
    private var sawUpToDate = false
    private var scanned = ""

    public init() {}

    /// Call once the shell is ready. Returns the text to send.
    public mutating func start() -> String {
        phase = .waitingForPasswordPrompt
        scanned = ""
        return Self.command
    }

    /// Feeds terminal output. Returns text to send back (the root password,
    /// when the prompt appears), if any.
    public mutating func receive(_ chunk: String, rootPassword: String) -> String? {
        output.append(chunk)
        scanned += chunk
        if scanned.count > 20_000 { scanned = String(scanned.suffix(4_000)) }

        switch phase {
        case .starting, .finished:
            return nil
        case .waitingForPasswordPrompt:
            if scanned.contains("Password:") {
                phase = .running
                scanned = ""
                return rootPassword + "\n"
            }
            return nil
        case .running:
            if scanned.contains("PIKVM_UPDATE_SU_FAILED") || scanned.contains("Authentication failure") {
                phase = .finished(.wrongRootPassword)
                return nil
            }
            if scanned.contains("already up-to-date") { sawUpToDate = true }
            if scanned.contains("Reboot required. We will make it") {
                phase = .finished(.rebooting)
                return nil
            }
            if let code = Self.exitCode(in: scanned) {
                if code == 0 {
                    phase = .finished(sawUpToDate ? .upToDate : .rebooting)
                } else {
                    phase = .finished(.failed(code: code))
                }
            }
            return nil
        }
    }

    static func exitCode(in text: String) -> Int? {
        // The terminal's echo of the command also contains the marker, but
        // followed by `\$?` rather than digits. Only a complete line counts.
        var searchFrom = text.startIndex
        while let range = text.range(of: "PIKVM_UPDATE_EXIT=", range: searchFrom..<text.endIndex) {
            let rest = text[range.upperBound...]
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, let next = rest.dropFirst(digits.count).first, next.isNewline {
                return Int(digits)
            }
            searchFrom = range.upperBound
        }
        return nil
    }
}

/// A minimal client for the PiKVM web terminal (ttyd) at
/// `/extras/webterm/ttyd/ws`. Protocol: subprotocol `tty`; the first
/// message is a JSON handshake; after that every message starts with a
/// command byte (`0` = input/output).
public final class WebTerminal: @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(client: KVMDClient, columns: Int = 250, rows: Int = 50) throws {
        task = try client.webSocket(path: "extras/webterm/ttyd/ws", protocols: ["tty"])
        task.resume()
        let handshake = "{\"AuthToken\":\"\",\"columns\":\(columns),\"rows\":\(rows)}"
        task.send(.data(Data(handshake.utf8))) { _ in }
    }

    public func send(_ text: String) async throws {
        var data = Data([UInt8(ascii: "0")])
        data.append(Data(text.utf8))
        try await task.send(.data(data))
    }

    /// Terminal output as it arrives. Finishes (or throws) when the connection closes.
    public func output() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = self.task
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let data: Data
                        switch try await task.receive() {
                        case .data(let d): data = d
                        case .string(let s): data = Data(s.utf8)
                        @unknown default: continue
                        }
                        if data.first == UInt8(ascii: "0") {
                            continuation.yield(String(decoding: data.dropFirst(), as: UTF8.self))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
