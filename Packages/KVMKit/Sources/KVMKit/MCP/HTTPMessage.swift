import Foundation

/// An HTTP/1.1 request, as much of it as the MCP server needs.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The path without the query, such as "/mcp".
    public var path: String
    /// Header names are lowercased. A repeated header keeps its last value.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// An HTTP/1.1 response. The server closes the connection after sending it.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int = 200, _ body: Data, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    public static func text(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers,
                     body: Data((message + "\n").utf8))
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body
            && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    /// The bytes sent on the wire.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// Collects bytes from a connection until a whole request has arrived.
public struct HTTPRequestParser: Sendable {
    public enum Result: Sendable, Equatable {
        case incomplete
        case request(HTTPRequest)
        /// The request can't be read; answer with this status and close.
        case failure(status: Int, message: String)
    }

    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> Result {
        buffer.append(data)
        return parse()
    }

    private func parse() -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > Self.maxHeaderBytes
                ? .failure(status: 431, message: "The request headers are too large.")
                : .incomplete
        }
        guard headerEnd.lowerBound <= Self.maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failure(status: 431, message: "The request headers are too large or not text.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(status: 400, message: "The request line is malformed.")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, message: "A header line is malformed.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            return .failure(status: 400, message: "Chunked requests aren't supported; send Content-Length.")
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .failure(status: 400, message: "Content-Length is not a number.") }
            length = n
        } else {
            length = 0
        }
        guard length <= Self.maxBodyBytes else {
            return .failure(status: 413, message: "The request body is too large.")
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }
}
