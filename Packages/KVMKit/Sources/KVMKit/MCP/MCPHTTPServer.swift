import Foundation
import Network

/// A small HTTP/1.1 server that listens on 127.0.0.1 only and passes each
/// request to a handler. One request per connection; the connection closes
/// after the answer. Used for the MCP endpoint.
public final class MCPHTTPServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
        case stopped
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "KVMConsole.MCPHTTPServer")
    private let handler: Handler
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Called on a background queue whenever the state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    /// Port 0 picks a free port; read it from `.listening`.
    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.onStateChange?(.stopped)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        onStateChange?(.starting)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        // Bound to the loopback address: never reachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.listening(port: listener?.port?.rawValue ?? self.requestedPort))
            case .failed(let error):
                self.onStateChange?(.failed(Self.describe(error, port: self.requestedPort)))
                listener?.cancel()
                self.queue.async { if self.listener === listener { self.listener = nil } }
            case .waiting(let error):
                self.onStateChange?(.failed(Self.describe(error, port: self.requestedPort)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another app. Choose another port."
        }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser())
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            let result = data.map { parser.append($0) } ?? .incomplete
            switch result {
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, parser: parser)
                }
            case .failure(let status, let message):
                self.send(.text(status, message), on: connection)
            case .request(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
