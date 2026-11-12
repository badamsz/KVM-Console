import Foundation

// A Model Context Protocol server over the Streamable HTTP transport, in its
// simplest form: every POST carries one JSON-RPC message and gets one JSON
// answer. There are no server-sent events and no sessions, so GET is refused.
// https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// A whole number, or nil for anything else.
    public var intValue: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 1e15 { return Int(n) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

/// What a tool may do, which decides whether it is offered.
public enum MCPToolKind: String, Sendable, CaseIterable {
    /// Reads state or takes a screenshot; changes nothing.
    case read
    /// Changes something on a machine: keys, switching, virtual media.
    case control
    /// Changes a machine's power. Always asks the person at the Mac first.
    case power
}

public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    /// A JSON Schema object for the arguments.
    public let inputSchema: JSONValue
    public let kind: MCPToolKind

    public init(name: String, title: String, description: String, inputSchema: JSONValue, kind: MCPToolKind) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.kind = kind
    }

    /// The tool as `tools/list` describes it.
    public var listing: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(kind == .read),
                "destructiveHint": .bool(kind == .power),
                "idempotentHint": .bool(kind == .read),
                "openWorldHint": false,
            ],
        ]
    }
}

/// One item of a tool's answer.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let s): return ["type": "text", "text": .string(s)]
        case .image(let data, let mime):
            return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        }
    }
}

public struct MCPToolResult: Sendable, Equatable {
    public var content: [MCPContent]
    /// The tool ran but failed; the text says why, for the model to read.
    public var isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ s: String) -> MCPToolResult { MCPToolResult(content: [.text(s)]) }
    public static func error(_ s: String) -> MCPToolResult { MCPToolResult(content: [.text(s)], isError: true) }

    /// A JSON value as pretty-printed text.
    public static func json(_ value: JSONValue) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return .text(text)
    }

    var json: JSONValue {
        ["content": .array(content.map(\.json)), "isError": .bool(isError)]
    }
}

/// Answers MCP requests that arrive over HTTP. It checks that a request
/// comes from this Mac with the right token, then hands tool calls to
/// `callTool`. It holds no other state.
public struct MCPEndpoint: Sendable {
    public static let path = "/mcp"
    /// Newest first. The newest is offered when the client asks for one we don't know.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public var serverName: String
    public var serverVersion: String
    public var instructions: String
    /// The bearer token clients must send. Requests without it are refused.
    public var token: String
    /// The tools offered right now.
    public var tools: @Sendable () async -> [MCPTool]
    /// Runs a tool that `tools` offered. Arguments are an object.
    public var callTool: @Sendable (_ tool: MCPTool, _ arguments: [String: JSONValue]) async -> MCPToolResult

    public init(serverName: String, serverVersion: String, instructions: String, token: String,
                tools: @escaping @Sendable () async -> [MCPTool],
                callTool: @escaping @Sendable (MCPTool, [String: JSONValue]) async -> MCPToolResult) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.token = token
        self.tools = tools
        self.callTool = callTool
    }

    // MARK: HTTP

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if let refusal = checkAccess(request) { return refusal }
        guard request.path == Self.path else {
            return .text(404, "Not found. The MCP endpoint is \(Self.path).")
        }
        switch request.method {
        case "POST": break
        case "GET", "DELETE":
            // No event stream and no sessions to end.
            return .text(405, "Use POST.", headers: [("Allow", "POST")])
        default:
            return .text(405, "Use POST.", headers: [("Allow", "POST")])
        }
        if let type = request.header("content-type"), !type.lowercased().hasPrefix("application/json") {
            return .text(415, "Send JSON (Content-Type: application/json).")
        }
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: request.body)
        } catch {
            return .json(400, Self.encode(Self.errorResponse(id: .null, code: -32700, message: "Parse error: the body is not JSON.")))
        }
        guard let object = message.objectValue else {
            // JSON-RPC batches were removed from MCP in 2025-06-18.
            return .json(400, Self.encode(Self.errorResponse(id: .null, code: -32600, message: "Send one JSON-RPC message per request.")))
        }
        guard let reply = await handleMessage(object) else {
            // A notification or a response from the client: nothing to answer.
            return HTTPResponse(status: 202)
        }
        return .json(200, Self.encode(reply))
    }

    /// Refuses requests that didn't come from a local client holding the
    /// token. The Host and Origin checks stop web pages from reaching the
    /// server through DNS rebinding; the token stops everything else.
    func checkAccess(_ request: HTTPRequest) -> HTTPResponse? {
        guard let host = request.header("host"), Self.isLoopbackAuthority(host) else {
            return .text(403, "Only clients on this Mac may connect (Host must be 127.0.0.1 or localhost).")
        }
        if let origin = request.header("origin"), origin != "null" {
            guard let url = URL(string: origin), let originHost = url.host, Self.isLoopbackHost(originHost) else {
                return .text(403, "Requests from web pages are not allowed.")
            }
        }
        let expected = "Bearer " + token
        guard !token.isEmpty, let auth = request.header("authorization"), Self.constantTimeEqual(auth, expected) else {
            return .json(401, Self.encode(["error": "Missing or wrong token. Copy the command from KVM Console's settings."]),
                         headers: [("WWW-Authenticate", "Bearer")])
        }
        return nil
    }

    static func isLoopbackAuthority(_ authority: String) -> Bool {
        var host = authority
        if host.hasPrefix("[") {
            // [::1]:port
            guard let end = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return isLoopbackHost(host)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: JSON-RPC

    /// The answer to one message, or nil when none is due.
    func handleMessage(_ message: [String: JSONValue]) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else {
            // A response to a request we never send, or junk.
            return message["id"] == nil ? nil : Self.errorResponse(id: message["id"] ?? .null, code: -32600, message: "Expected a request.")
        }
        guard let id = message["id"], id != .null else {
            // Notifications, such as notifications/initialized, need no answer.
            return nil
        }
        let params = message["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(serverName), "title": "KVM Console", "version": .string(serverVersion)],
                "instructions": .string(instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let tools = await tools()
            return Self.result(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "tools/call needs a tool name.")
            }
            guard let tool = await tools().first(where: { $0.name == name }) else {
                return Self.errorResponse(id: id, code: -32602,
                                          message: "Unknown tool \(name). Control tools are offered only when Allow Control is on in KVM Console's settings.")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let o)?: arguments = o
            default: return Self.errorResponse(id: id, code: -32602, message: "Tool arguments must be an object.")
            }
            let result = await callTool(tool, arguments)
            return Self.result(id: id, result.json)
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
