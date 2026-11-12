import AppKit

/// Asks the person at the Mac before an AI agent does something risky.
@MainActor
final class MCPConfirmer {
    enum Answer {
        case allowed
        case declined
        case timedOut
        /// Another question is already showing.
        case busy
    }

    private var asking = false

    /// Shows an alert and waits for the answer. Return picks "Don't Allow",
    /// so a stray keypress can't approve. Unanswered after `timeout`, it closes
    /// and counts as declined.
    func ask(title: String, message: String, allowTitle: String, timeout: TimeInterval = 120) async -> Answer {
        guard !asking else { return .busy }
        asking = true
        defer { asking = false }
        // Let the request that asked finish its own bookkeeping first.
        await Task.yield()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let allow = alert.addButton(withTitle: allowTitle)
        let deny = alert.addButton(withTitle: "Don't Allow")
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\r"
        allow.hasDestructiveAction = true

        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()

        switch response {
        case .alertFirstButtonReturn: return .allowed
        case .abort: return .timedOut
        default: return .declined
        }
    }
}
