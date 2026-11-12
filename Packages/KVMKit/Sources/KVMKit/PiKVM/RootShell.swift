import Foundation

public enum RootShellError: Error, LocalizedError, Equatable, Sendable {
    case wrongRootPassword
    case notRoot
    case timedOut(String)
    case closed
    case badOutput

    public var errorDescription: String? {
        switch self {
        case .wrongRootPassword: return "The root password was rejected."
        case .notRoot: return "Couldn't become root in the PiKVM's web terminal."
        case .timedOut(let what): return "The PiKVM took too long to \(what)."
        case .closed: return "The PiKVM's web terminal closed."
        case .badOutput: return "The PiKVM sent back something unexpected."
        }
    }
}

/// The text exchanged with a root shell in the web terminal. Pure functions,
/// so the format can be tested without a PiKVM.
///
/// A script travels as base64 in a here-document (so no line is longer than
/// the terminal allows, and nothing in it is interpreted by the interactive
/// shell). Its output comes back as base64 between two markers, so terminal
/// line endings and escape sequences can't change it. The command line
/// spells the markers with `%s`, so its echo never matches them.
public enum RootShellWire {
    /// What to type to run `script` with `/bin/sh` as job number `id`.
    public static func command(script: String, id: Int) -> String {
        let encoded = Data(script.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        let file = "/tmp/pkc.\(id)"
        return "base64 -d >\(file).sh <<'PKC_EOF'\n"
            + encoded + "\n"
            + "PKC_EOF\n"
            + "printf '\\nPKC_B%s\\n' \(id); sh \(file).sh </dev/null >\(file).out 2>&1; pkc_rc=$?;"
            + " base64 -w0 \(file).out; printf '\\nPKC_E%s=%s\\n' \(id) \"$pkc_rc\"; rm -f \(file).sh \(file).out\n"
    }

    /// The exit code and output of job `id`, once its end marker has arrived.
    public static func result(in output: String, id: Int) -> (code: Int, output: Data)? {
        guard let begin = markerLine(in: output, prefix: "PKC_B\(id)", from: output.startIndex) else { return nil }
        let scalars = output.unicodeScalars
        let endPrefix = "PKC_E\(id)="
        var searchFrom = begin.upperBound
        while let range = output.range(of: endPrefix, range: searchFrom..<output.endIndex) {
            let rest = scalars[range.upperBound...]
            let digits = rest.prefix { $0.value >= 48 && $0.value <= 57 }
            let after = rest.dropFirst(digits.count).first
            if !digits.isEmpty, after == Unicode.Scalar("\r") || after == Unicode.Scalar("\n"),
               let code = Int(String(String.UnicodeScalarView(digits))) {
                let payload = scalars[begin.upperBound..<range.lowerBound]
                    .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
                guard let data = Data(base64Encoded: String(String.UnicodeScalarView(payload))) else { return nil }
                return (code, data)
            }
            searchFrom = range.upperBound
        }
        return nil
    }

    /// The range of `prefix` where it is followed directly by a line break,
    /// with the range's end after that line break.
    static func markerLine(in text: String, prefix: String, from start: String.Index) -> Range<String.Index>? {
        var searchFrom = start
        while let range = text.range(of: prefix, range: searchFrom..<text.endIndex) {
            var i = range.upperBound
            let scalars = text.unicodeScalars
            if i < text.endIndex, scalars[i] == "\r" { i = scalars.index(after: i) }
            if i < text.endIndex, scalars[i] == "\n" {
                return range.lowerBound..<scalars.index(after: i)
            }
            searchFrom = range.upperBound
        }
        return nil
    }

    /// Typed after `su -` succeeds: quiets the shell so only job output comes back.
    public static let setup = "stty -echo; PS1=''; PS2=''; unset HISTFILE; umask 077;"
        + " if [ \"$(id -u)\" = 0 ]; then echo PKC_ROOT\"\"_OK; else echo PKC_ROOT\"\"_NO; fi\n"
}

/// A root shell in the PiKVM web terminal (`su -` with the root password).
/// Jobs run one at a time.
public actor RootShell {
    private let terminal: WebTerminal
    private var buffer = ""
    private var closed = false
    private var reader: Task<Void, Never>?
    private var nextID = 1

    private init(terminal: WebTerminal) {
        self.terminal = terminal
    }

    /// Opens the web terminal and becomes root.
    public static func open(client: KVMDClient, rootPassword: String) async throws -> RootShell {
        let shell = RootShell(terminal: try WebTerminal(client: client))
        do {
            try await shell.login(rootPassword: rootPassword)
        } catch {
            await shell.close()
            throw error
        }
        return shell
    }

    private func startReading() {
        let stream = terminal.output()
        reader = Task { [weak self] in
            do {
                for try await chunk in stream { await self?.append(chunk) }
            } catch {}
            await self?.markClosed()
        }
    }

    private func append(_ chunk: String) {
        buffer += chunk
        if buffer.utf8.count > 4_000_000 { buffer = String(buffer.suffix(1_000_000)) }
    }

    private func markClosed() { closed = true }

    /// Polls the output until `check` returns a value.
    private func wait<T>(_ what: String, timeout: TimeInterval, _ check: (String) throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = try check(buffer) { return value }
            if closed { throw RootShellError.closed }
            if Date() > deadline { throw RootShellError.timedOut(what) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func endsWithPrompt(_ text: String) -> Bool {
        let trimmed = text.replacingOccurrences(of: "\u{1B}[?2004h", with: "")
        return trimmed.hasSuffix("$ ") || trimmed.hasSuffix("# ")
    }

    private func login(rootPassword: String) async throws {
        startReading()
        // Wait for the user shell's prompt (or carry on after a few seconds).
        _ = try? await wait("open its web terminal", timeout: 5) { Self.endsWithPrompt($0) ? true : nil }
        if closed { throw RootShellError.closed }
        buffer = ""
        try await terminal.send("su -\n")
        _ = try await wait("ask for the root password", timeout: 15) { $0.contains("Password:") ? true : nil }
        buffer = ""
        try await terminal.send(rootPassword + "\n")
        // Either su fails, or the root shell shows its prompt.
        let failed = try await wait("check the root password", timeout: 20) { text -> Bool? in
            if text.contains("Authentication failure") || text.contains("su: ") { return true }
            if Self.endsWithPrompt(text) { return false }
            return nil
        }
        if failed { throw RootShellError.wrongRootPassword }
        buffer = ""
        try await terminal.send(RootShellWire.setup)
        let isRoot = try await wait("start a root shell", timeout: 15) { text -> Bool? in
            if RootShellWire.markerLine(in: text, prefix: "PKC_ROOT_OK", from: text.startIndex) != nil { return true }
            if RootShellWire.markerLine(in: text, prefix: "PKC_ROOT_NO", from: text.startIndex) != nil { return false }
            return nil
        }
        if !isRoot { throw RootShellError.notRoot }
    }

    /// Runs a shell script as root. Returns its exit code and combined output.
    public func run(_ script: String, timeout: TimeInterval = 120) async throws -> (code: Int, output: String) {
        let id = nextID
        nextID += 1
        buffer = ""
        try await terminal.send(RootShellWire.command(script: script, id: id))
        let result = try await wait("respond", timeout: timeout) { RootShellWire.result(in: $0, id: id) }
        buffer = ""
        return (result.code, String(decoding: result.output, as: UTF8.self))
    }

    public func close() {
        reader?.cancel()
        reader = nil
        terminal.close()
        closed = true
    }
}
