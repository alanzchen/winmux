@testable import AppBundle
import Foundation
import Network
import XCTest

/// The MCP server's listeners, on real loopback sockets: none while off, 127.0.0.1 while on, gone when
/// turned off again. Port 0 lets the system choose a free port.
@MainActor
final class MCPServerTest: XCTestCase {
    private var server: MCPServer!
    private var savedNotice: (@MainActor (WinMuxToastNotice) -> Void)?
    private var savedTokenURL: (@MainActor () -> URL?)?
    private var notices: [WinMuxToastNotice] = []
    private var folder: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        server = MCPServer()
        savedNotice = showWorkspaceSidebarNotice
        showWorkspaceSidebarNotice = { [unowned self] in notices.append($0) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-mcp-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedTokenURL = mcpServerTokenURL
        mcpServerTokenURL = { [folder] in folder?.appendingPathComponent("mcp-server-token") }
    }

    override func tearDown() async throws {
        server.stop()
        if let savedNotice { showWorkspaceSidebarNotice = savedNotice }
        if let savedTokenURL { mcpServerTokenURL = savedTokenURL }
        try? FileManager.default.removeItem(at: folder)
        config = defaultConfig
    }

    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func post(_ port: Int, _ body: String, authorization: String? = nil) async throws -> (Int, MCPJSON?) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, MCPJSON.decode(data))
    }

    /// Whether a TCP connection to 127.0.0.1 on this port is refused.
    private func isRefused(_ port: Int) async -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let outcome = OutcomeBox()
        connection.stateUpdateHandler = { state in
            switch state {
                case .ready: outcome.set(false)
                case .failed, .waiting: outcome.set(true)
                default: break
            }
        }
        connection.start(queue: .global())
        _ = await eventually({ outcome.value != nil }, timeout: 3)
        connection.cancel()
        return outcome.value ?? false
    }

    func testOffMeansNoListener() async {
        server.apply(MCPServerConfig(enabled: false, port: 0))
        XCTAssertEqual(server.state, .off)
        XCTAssertEqual(server.listeningAddresses, [])
        XCTAssertNil(server.port)
    }

    func testOnItServesMCPOnLoopbackOnlyAndStopsListeningWhenTurnedOff() async throws {
        server.apply(MCPServerConfig(enabled: true, port: 0))
        let listening = await eventually { server.state == .listening && server.port != nil }
        XCTAssertTrue(listening, "\(server.state)")
        XCTAssertEqual(server.listeningAddresses, ["127.0.0.1"])
        let port = try XCTUnwrap(server.port)

        let (status, message) = try await post(port, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(message?["result"]?["serverInfo"]?["name"], .string("winmux"))

        server.apply(MCPServerConfig(enabled: false, port: 0))
        XCTAssertEqual(server.state, .off)
        XCTAssertEqual(server.listeningAddresses, [])
        let refused = await isRefused(port)
        XCTAssertTrue(refused, "Nothing listens once it's off")
    }

    func testAPortInUseIsReportedInSettingsAndAsANotice() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let occupied = try NWListener(using: parameters)
        occupied.newConnectionHandler = { $0.cancel() }
        occupied.start(queue: .global())
        let ready = await eventually { occupied.port != nil && occupied.port?.rawValue != 0 }
        XCTAssertTrue(ready)
        defer { occupied.cancel() }
        let port = Int(try XCTUnwrap(occupied.port).rawValue)

        server.apply(MCPServerConfig(enabled: true, port: port))
        let failed = await eventually { if case .failed = server.state { true } else { false } }
        XCTAssertTrue(failed, "\(server.state)")
        if case .failed(let message) = server.state { XCTAssertTrue(message.contains("\(port)"), message) }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.body.contains("\(port)") == true, "\(notices)")
    }

    func testARequiredTokenIsMadeIfNoneIsSavedAndRequestsWithoutItAreRefused() async throws {
        server.apply(MCPServerConfig(enabled: true, port: 0, requireToken: true))
        let token = try XCTUnwrap(readMCPServerToken(), "Made when the server started")
        let listening = await eventually { server.port != nil }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(server.port)
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let (refused, _) = try await post(port, ping)
        XCTAssertEqual(refused, 401)
        let (allowed, _) = try await post(port, ping, authorization: "Bearer \(token)")
        XCTAssertEqual(allowed, 200)

        // A new token takes effect at once; the old one is refused.
        let next = try generateMCPServerToken()
        server.tokenDidChange()
        let (old, _) = try await post(port, ping, authorization: "Bearer \(token)")
        XCTAssertEqual(old, 401)
        let (fresh, _) = try await post(port, ping, authorization: "Bearer \(next)")
        XCTAssertEqual(fresh, 200)
    }

    // MARK: - Review regressions (Astra, 2026-11-13)

    private func ping(_ client: MCPRawClient, host: String, token: String? = nil) async -> Int? {
        await client.request(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, host: host, token: token)
    }

    /// Requiring a token applies to the very next request, on connections already open.
    func testRequiringATokenAppliesToTheNextRequestOnAnOpenConnection() async throws {
        server.apply(MCPServerConfig(enabled: true, port: 0))
        let ready = await eventually { server.port != nil }
        XCTAssertTrue(ready)
        let port = try XCTUnwrap(server.port)
        let client = try await MCPRawClient.connect(host: "127.0.0.1", port: port)
        defer { client.close() }
        let open = await ping(client, host: "127.0.0.1:\(port)")
        XCTAssertEqual(open, 200)
        server.apply(MCPServerConfig(enabled: true, port: 0, requireToken: true))
        XCTAssertEqual(server.port, port, "Same listener")
        let refused = await ping(client, host: "127.0.0.1:\(port)")
        XCTAssertEqual(refused, 401)
        let token = try XCTUnwrap(readMCPServerToken())
        let allowed = await ping(client, host: "127.0.0.1:\(port)", token: token)
        XCTAssertEqual(allowed, 200)
    }

    /// Why closing connections matters: cancelling a listener leaves the connections it accepted open.
    func testCancellingAListenerLeavesItsAcceptedConnectionsOpen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = AcceptedBox()
        listener.newConnectionHandler = { connection in
            accepted.set(connection)
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel(); accepted.connection?.cancel() }
        let bound = await eventually { listener.port.map { $0.rawValue != 0 } == true }
        XCTAssertTrue(bound)
        let client = try await MCPRawClient.connect(host: "127.0.0.1", port: Int(try XCTUnwrap(listener.port).rawValue))
        defer { client.close() }
        let connected = await eventually { accepted.connection?.state == .ready }
        XCTAssertTrue(connected)
        listener.cancel()
        let cancelled = await eventually { listener.state == .cancelled }
        XCTAssertTrue(cancelled)
        let received = ReceivedBox()
        accepted.connection?.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
            if data == Data("still connected".utf8) { received.set() }
        }
        client.send(Data("still connected".utf8))
        let arrived = await eventually { received.value }
        XCTAssertTrue(arrived)
    }

    // MARK: - Loopback only

    /// Whatever the config says, the server listens on 127.0.0.1 and nowhere else: no key names another address.
    func testItNeverListensAnywhereButLoopback() async throws {
        for config in [MCPServerConfig(enabled: true, port: 0), MCPServerConfig(enabled: true, port: 0, requireToken: true)] {
            server.apply(config)
            let listening = await eventually { server.state == .listening }
            XCTAssertTrue(listening, "\(server.state)")
            XCTAssertEqual(server.listeningAddresses, ["127.0.0.1"])
            XCTAssertEqual(server.listenerHost, "127.0.0.1")
            server.stop()
            XCTAssertEqual(server.listeningAddresses, [])
        }
        let parsed = parseConfig("[mcp-server]\nenabled = true\ntailscale = true\nlisten = '0.0.0.0'\n")
        XCTAssertEqual(parsed.errors.count, 2, "\(parsed.errors.descriptions)")
        server.apply(parsed.config.mcpServer)
        XCTAssertEqual(server.listenerHost ?? "127.0.0.1", "127.0.0.1")
        XCTAssertTrue(server.listeningAddresses.allSatisfy { $0 == "127.0.0.1" })
    }

    func testAdmissionHasACapAndStopsWhenTheServerDoes() {
        let shared = MCPServerSharedState()
        func connection() -> NWConnection { NWConnection(host: "127.0.0.1", port: 41740, using: .tcp) }
        XCTAssertFalse(shared.admit(connection()), "Not while it isn't listening")
        shared.isListening = true
        let open = (0 ..< mcpMaxConnections).map { _ in connection() }
        for item in open { XCTAssertTrue(shared.admit(item)) }
        XCTAssertFalse(shared.admit(connection()), "At the cap")
        shared.remove(open[0])
        XCTAssertTrue(shared.admit(connection()), "Room again")
        shared.closeConnections()
        XCTAssertEqual(shared.connectionCount, 0)
        shared.isListening = false
        XCTAssertFalse(shared.admit(connection()))
    }

    func testARequiredTokenThatCantBeMadeStartsNoListener() throws {
        let blocker = folder.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        mcpServerTokenURL = { blocker.appendingPathComponent("token") }
        server.apply(MCPServerConfig(enabled: true, port: 0, requireToken: true))
        guard case .failed = server.state else { return XCTFail("Must fail closed: \(server.state)") }
        XCTAssertEqual(server.listeningAddresses, [])
        XCTAssertNil(server.port)
    }
}

/// A plain HTTP/1.1 client on one connection, to send several requests over it.
final class MCPRawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(host: String, port: Int) async throws -> MCPRawClient {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))), using: .tcp)
        let client = MCPRawClient(connection)
        let ready = ReceivedBox()
        connection.stateUpdateHandler = { if case .ready = $0 { ready.set() } }
        connection.start(queue: .global())
        let deadline = Date().addingTimeInterval(5)
        while !ready.value, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        guard ready.value else { throw XCTSkip("Couldn't connect to \(host):\(port)") }
        return client
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// The status of the response to one POST to /mcp, or nil if the connection closed first.
    func request(_ body: String, host: String, token: String? = nil) async -> Int? {
        var head = "POST /mcp HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        send(Data((head + "\r\n" + body).utf8))
        let watchdog = Task { [connection] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { watchdog.cancel() }
        while true {
            if let status = takeResponse() { return status }
            let (data, closed) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    continuation.resume(returning: (data, complete || error != nil))
                }
            }
            if let data, !data.isEmpty { lock.withLock { buffer.append(data) } }
            if let status = takeResponse() { return status }
            if closed { return nil }
        }
    }

    func close() { connection.cancel() }

    private func takeResponse() -> Int? {
        lock.withLock {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let length = lines.dropFirst().compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            guard buffer.endIndex - end.upperBound >= length else { return nil }
            buffer.removeSubrange(buffer.startIndex ..< end.upperBound + length)
            return lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") }
        }
    }
}



private final class AcceptedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NWConnection?
    var connection: NWConnection? { lock.withLock { stored } }
    func set(_ connection: NWConnection) { lock.withLock { stored = connection } }
}

private final class ReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { if stored == nil { stored = value } } }
}
