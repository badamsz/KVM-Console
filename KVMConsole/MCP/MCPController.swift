import Foundation
import Observation
import KVMKit

enum MCPPreferences {
    /// Run the MCP server (default off).
    static let enabledKey = "mcp.enabled"
    /// Offer tools that change things: keys, switching, media, power (default off).
    static let allowControlKey = "mcp.allowControl"
    static let portKey = "mcp.port"
    static let defaultPort: UInt16 = 47823
    /// The Keychain name of the bearer token clients send.
    static let tokenSecretName = "mcp.token"
}

/// Runs the MCP server that lets AI agents (Claude Code, Claude Desktop and
/// other MCP clients on this Mac) see and control machines. It listens on
/// 127.0.0.1 only and needs a token. Off by default; read-only tools only
/// until the person allows control; power actions always ask first.
@MainActor
@Observable
final class MCPController {
    enum Status: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    struct Activity: Identifiable {
        let id = UUID()
        let date: Date
        let tool: String
        let machine: String?
        let summary: String
        let failed: Bool
    }

    private(set) var status: Status = .off
    private(set) var enabled: Bool
    private(set) var port: UInt16
    private(set) var token: String = ""
    var allowControl: Bool {
        didSet { UserDefaults.standard.set(allowControl, forKey: MCPPreferences.allowControlKey) }
    }
    /// The latest tool calls, newest first.
    private(set) var activity: [Activity] = []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored let confirmer = MCPConfirmer()

    init(credentials: CredentialStore) {
        self.credentials = credentials
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: MCPPreferences.enabledKey)
        allowControl = defaults.bool(forKey: MCPPreferences.allowControlKey)
        let saved = defaults.integer(forKey: MCPPreferences.portKey)
        port = (1024...65535).contains(saved) ? UInt16(saved) : MCPPreferences.defaultPort
    }

    var endpointURL: String { "http://127.0.0.1:\(port)\(MCPEndpoint.path)" }

    func attach(to app: AppModel) {
        self.app = app
        if enabled { start() }
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: MCPPreferences.enabledKey)
        if on { start() } else { stop() }
    }

    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort >= 1024 else { return }
        port = newPort
        UserDefaults.standard.set(Int(newPort), forKey: MCPPreferences.portKey)
        if enabled { restart() }
    }

    /// Replaces the token. Clients set up with the old one stop working.
    func regenerateToken() {
        token = Self.makeToken()
        credentials.setSecret(token, named: MCPPreferences.tokenSecretName)
        if enabled { restart() }
    }

    /// Loads the token, making one the first time.
    func loadToken() {
        guard token.isEmpty else { return }
        if let saved = credentials.secret(named: MCPPreferences.tokenSecretName), !saved.isEmpty {
            token = saved
        } else {
            token = Self.makeToken()
            credentials.setSecret(token, named: MCPPreferences.tokenSecretName)
        }
    }

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func clearActivity() { activity.removeAll() }

    // MARK: Server

    private func start() {
        stopServer()
        loadToken()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let endpoint = MCPEndpoint(
            serverName: "kvm-console", serverVersion: version, instructions: KVMTool.instructions, token: token,
            tools: { [weak self] in await self?.offeredTools() ?? [] },
            callTool: { [weak self] tool, arguments in
                await self?.call(tool, arguments) ?? .error("KVM Console is quitting.")
            })
        let server = MCPHTTPServer(port: port) { request in await endpoint.handle(request) }
        server.onStateChange = { [weak self, weak server] state in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.serverStateChanged(state)
            }
        }
        self.server = server
        status = .starting
        server.start()
    }

    private func stop() {
        restartTask?.cancel()
        restartTask = nil
        stopServer()
        status = .off
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }

    /// Stops, then starts once the old listener has let go of the port.
    private func restart() {
        stopServer()
        status = .starting
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.enabled else { return }
            self.start()
        }
    }

    private func serverStateChanged(_ state: MCPHTTPServer.State) {
        switch state {
        case .starting: status = .starting
        case .listening(let port): status = .listening(port: port)
        case .failed(let message): status = .failed(message)
        case .stopped: status = .off
        }
    }

    // MARK: Tools

    private func offeredTools() -> [MCPTool] {
        KVMTool.offered(allowControl: allowControl)
    }

    private func call(_ tool: MCPTool, _ arguments: [String: JSONValue]) async -> MCPToolResult {
        guard let app, let kvmTool = KVMTool(rawValue: tool.name) else { return .error("Unknown tool \(tool.name).") }
        // Checked again here: the setting may have changed since the client listed the tools.
        if kvmTool.kind != .read, !allowControl {
            return .error("Control is turned off in KVM Console's settings, so only list, status and screenshot tools work.")
        }
        let runner = MCPToolRunner(app: app, confirmer: confirmer)
        let result = await runner.run(kvmTool, arguments)
        record(tool: tool.title, machine: arguments["machine"]?.stringValue.flatMap { runner.machineName(for: $0) },
               result: result)
        return result
    }

    private func record(tool: String, machine: String?, result: MCPToolResult) {
        let summary: String
        if result.isError, case .text(let message)? = result.content.first {
            summary = message
        } else {
            summary = result.isError ? "Failed" : "Done"
        }
        activity.insert(Activity(date: Date(), tool: tool, machine: machine, summary: summary, failed: result.isError), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
