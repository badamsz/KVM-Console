import XCTest
@testable import KVMKit

final class HTTPParserTests: XCTestCase {
    func testParsesRequestArrivingInPieces() {
        var parser = HTTPRequestParser()
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:47823\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let bytes = Data(raw.utf8)
        let first = parser.append(bytes.prefix(20))
        XCTAssertEqual(first, .incomplete)
        let second = parser.append(bytes.dropFirst(20).dropLast(3))
        XCTAssertEqual(second, .incomplete)
        let third = parser.append(bytes.suffix(3))
        guard case .request(let request) = third else { return XCTFail("expected a request") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("HOST"), "127.0.0.1:47823")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"a\":1}")
    }

    func testRequestWithoutBody() {
        var parser = HTTPRequestParser()
        guard case .request(let request) = parser.append(Data("GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testRejectsMalformedAndOversized() {
        var a = HTTPRequestParser()
        let malformed = a.append(Data("NONSENSE\r\n\r\n".utf8))
        XCTAssertEqual(malformed, .failure(status: 400, message: "The request line is malformed."))
        var b = HTTPRequestParser()
        if case .failure(let status, _) = b.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) {
            XCTAssertEqual(status, 413)
        } else { XCTFail("expected 413") }
        var c = HTTPRequestParser()
        if case .failure(let status, _) = c.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) {
            XCTAssertEqual(status, 400)
        } else { XCTFail("expected 400") }
        var d = HTTPRequestParser()
        if case .failure(let status, _) = d.append(Data(repeating: 65, count: HTTPRequestParser.maxHeaderBytes + 1)) {
            XCTAssertEqual(status, 431)
        } else { XCTFail("expected 431") }
    }

    func testResponseSerialization() {
        let text = String(data: HTTPResponse.json(200, Data("{}".utf8)).serialized(), encoding: .utf8)
        XCTAssertEqual(text, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    }
}

final class MCPEndpointTests: XCTestCase {
    static let token = "secret-token"

    func makeEndpoint(allowControl: Bool = false, calls: CallLog = CallLog()) -> MCPEndpoint {
        MCPEndpoint(serverName: "kvm-console", serverVersion: "1.0", instructions: "Hi", token: Self.token,
                    tools: { KVMTool.offered(allowControl: allowControl) },
                    callTool: { tool, args in
                        await calls.add(tool.name, args)
                        return .text("ran \(tool.name)")
                    })
    }

    actor CallLog {
        var calls: [(String, [String: JSONValue])] = []
        func add(_ name: String, _ args: [String: JSONValue]) { calls.append((name, args)) }
    }

    func post(_ body: String, headers: [String: String] = [:]) -> HTTPRequest {
        var h = ["Host": "127.0.0.1:47823", "Authorization": "Bearer \(Self.token)", "Content-Type": "application/json"]
        for (k, v) in headers { h[k] = v }
        return HTTPRequest(method: "POST", path: "/mcp", headers: h, body: Data(body.utf8))
    }

    func decode(_ response: HTTPResponse) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: response.body)
    }

    func testRefusesWithoutTokenOrFromWebPages() async {
        let endpoint = makeEndpoint()
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let noToken = await endpoint.handle(post(body, headers: ["Authorization": "Bearer wrong"]))
        XCTAssertEqual(noToken.status, 401)
        let rebinding = await endpoint.handle(post(body, headers: ["Host": "evil.example:47823"]))
        XCTAssertEqual(rebinding.status, 403)
        let webPage = await endpoint.handle(post(body, headers: ["Origin": "https://evil.example"]))
        XCTAssertEqual(webPage.status, 403)
        let localPage = await endpoint.handle(post(body, headers: ["Origin": "http://localhost:3000"]))
        XCTAssertEqual(localPage.status, 200)
        let ipv6 = await endpoint.handle(post(body, headers: ["Host": "[::1]:47823"]))
        XCTAssertEqual(ipv6.status, 200)
    }

    func testEmptyTokenRefusesEverything() async {
        var endpoint = makeEndpoint()
        endpoint.token = ""
        let response = await endpoint.handle(post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["Authorization": "Bearer "]))
        XCTAssertEqual(response.status, 401)
    }

    func testOnlyPostOnMCPPath() async {
        let endpoint = makeEndpoint()
        var get = post("")
        get.method = "GET"
        let getResponse = await endpoint.handle(get)
        XCTAssertEqual(getResponse.status, 405)
        var other = post("{}")
        other.path = "/other"
        let otherResponse = await endpoint.handle(other)
        XCTAssertEqual(otherResponse.status, 404)
    }

    func testInitializeNegotiatesVersion() async throws {
        let endpoint = makeEndpoint()
        let known = try decode(await endpoint.handle(post(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)))
        XCTAssertEqual(known["id"], .number(1))
        XCTAssertEqual(known["result"]?["protocolVersion"], .string("2025-03-26"))
        XCTAssertEqual(known["result"]?["serverInfo"]?["name"], .string("kvm-console"))
        XCTAssertNotNil(known["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(known["result"]?["instructions"], .string("Hi"))

        let unknown = try decode(await endpoint.handle(post(
            #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)))
        XCTAssertEqual(unknown["id"], .string("a"))
        XCTAssertEqual(unknown["result"]?["protocolVersion"], .string(MCPEndpoint.protocolVersions[0]))
    }

    func testNotificationsGet202() async {
        let response = await makeEndpoint().handle(post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(response.status, 202)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testToolsListFollowsAllowControl() async throws {
        let readOnly = try decode(await makeEndpoint(allowControl: false).handle(post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
        let names = readOnly["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(Set(names), ["list_machines", "get_machine_status", "take_screenshot"])
        let first = readOnly["result"]?["tools"]?.arrayValue?.first
        XCTAssertEqual(first?["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertEqual(first?["inputSchema"]?["type"], .string("object"))

        let control = try decode(await makeEndpoint(allowControl: true).handle(post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
        let all = control["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(all.count, KVMTool.allCases.count)
        let power = all.first { $0["name"] == .string("power") }
        XCTAssertEqual(power?["annotations"]?["destructiveHint"], .bool(true))
    }

    func testToolsCall() async throws {
        let log = CallLog()
        let endpoint = makeEndpoint(calls: log)
        let reply = try decode(await endpoint.handle(post(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_machine_status","arguments":{"machine":"Rack"}}}"#)))
        XCTAssertEqual(reply["result"]?["content"]?.arrayValue?.first?["text"], .string("ran get_machine_status"))
        XCTAssertEqual(reply["result"]?["isError"], .bool(false))
        let calls = await log.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["machine"], .string("Rack"))

        // Control tools don't exist while control is off.
        let refused = try decode(await endpoint.handle(post(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"power","arguments":{"machine":"Rack","action":"on"}}}"#)))
        XCTAssertEqual(refused["error"]?["code"], .number(-32602))
        let callsAfter = await log.calls
        XCTAssertEqual(callsAfter.count, 1)
    }

    func testErrors() async throws {
        let endpoint = makeEndpoint()
        let unknown = try decode(await endpoint.handle(post(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)))
        XCTAssertEqual(unknown["error"]?["code"], .number(-32601))
        let parse = await endpoint.handle(post("not json"))
        XCTAssertEqual(parse.status, 400)
        XCTAssertEqual(try decode(parse)["error"]?["code"], .number(-32700))
        let batch = await endpoint.handle(post(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#))
        XCTAssertEqual(batch.status, 400)
        let wrongType = await endpoint.handle(post("{}", headers: ["Content-Type": "text/plain"]))
        XCTAssertEqual(wrongType.status, 415)
    }

    func testImageContent() {
        let result = MCPToolResult(content: [.image(Data([1, 2, 3]), mimeType: "image/jpeg"), .text("x")])
        let json = result.json
        XCTAssertEqual(json["content"]?.arrayValue?.first?["type"], .string("image"))
        XCTAssertEqual(json["content"]?.arrayValue?.first?["data"], .string("AQID"))
        XCTAssertEqual(json["content"]?.arrayValue?.first?["mimeType"], .string("image/jpeg"))
    }
}

final class KeyComboTests: XCTestCase {
    func testCommonCombinations() throws {
        XCTAssertEqual(try KeyCombo.parse("ctrl+alt+delete"), ["ControlLeft", "AltLeft", "Delete"])
        XCTAssertEqual(try KeyCombo.parse("Ctrl + Alt + Del"), ["ControlLeft", "AltLeft", "Delete"])
        XCTAssertEqual(try KeyCombo.parse("F2"), ["F2"])
        XCTAssertEqual(try KeyCombo.parse("enter"), ["Enter"])
        XCTAssertEqual(try KeyCombo.parse("shift+tab"), ["ShiftLeft", "Tab"])
        XCTAssertEqual(try KeyCombo.parse("win+r"), ["MetaLeft", "KeyR"])
        XCTAssertEqual(try KeyCombo.parse("down"), ["ArrowDown"])
        XCTAssertEqual(try KeyCombo.parse("7"), ["Digit7"])
        XCTAssertEqual(try KeyCombo.parse("KeyA"), ["KeyA"])
        XCTAssertEqual(try KeyCombo.parse("arrowup"), ["ArrowUp"])
        XCTAssertEqual(try KeyCombo.parse("ctrl+/"), ["ControlLeft", "Slash"])
        XCTAssertEqual(try KeyCombo.parse("shift++"), ["ShiftLeft", "Equal"])
    }

    func testEveryCodeIsSendable() throws {
        for name in KeyCombo.aliases.values { XCTAssertTrue(KeyCombo.knownCodes.contains(name), name) }
        for name in KeyCombo.punctuation.values { XCTAssertTrue(KeyCombo.knownCodes.contains(name), name) }
        for n in 1...12 { XCTAssertEqual(try KeyCombo.code(for: "f\(n)"), "F\(n)") }
    }

    func testRejectsUnknownKeys() {
        XCTAssertThrowsError(try KeyCombo.parse("ctrl+banana"))
        XCTAssertThrowsError(try KeyCombo.parse(""))
        XCTAssertThrowsError(try KeyCombo.parse("f25"))
        XCTAssertThrowsError(try KeyCombo.parse("f13"))
    }
}

final class KVMToolTests: XCTestCase {
    func testToolNamesAndKinds() {
        XCTAssertEqual(Set(KVMTool.allCases.map(\.rawValue)).count, KVMTool.allCases.count)
        XCTAssertEqual(KVMTool.offered(allowControl: false).map(\.kind), [.read, .read, .read])
        XCTAssertEqual(KVMTool.power.kind, .power)
        for tool in KVMTool.allCases {
            let schema = tool.definition.inputSchema
            XCTAssertEqual(schema["type"], .string("object"), tool.rawValue)
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in required { XCTAssertNotNil(properties[name], "\(tool.rawValue).\(name)") }
            if tool != .listMachines { XCTAssertTrue(required.contains("machine"), tool.rawValue) }
        }
    }
}

final class MCPHTTPServerTests: XCTestCase {
    func testServesOverLoopback() async throws {
        let endpoint = MCPEndpoint(serverName: "t", serverVersion: "1", instructions: "", token: "tok",
                                   tools: { [] }, callTool: { _, _ in .text("") })
        let server = MCPHTTPServer(port: 0) { await endpoint.handle($0) }
        let ready = expectation(description: "listening")
        let port = PortBox()
        server.onStateChange = { state in
            if case .listening(let p) = state, p != 0 {
                port.value = p
                ready.fulfill()
            }
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port.value)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(reply["id"], .number(7))
        XCTAssertEqual(reply["result"], .object([:]))

        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
    }

    final class PortBox: @unchecked Sendable {
        var value: UInt16 = 0
    }
}
