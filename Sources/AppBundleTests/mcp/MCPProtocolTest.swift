@testable import AppBundle
import Common
import Foundation
import XCTest

/// MCP over the server's one path: who's refused, the JSON-RPC methods, and tools that run as the CLI's
/// commands do, through the same dispatch. Synthetic workspaces and windows only.
@MainActor
final class MCPProtocolTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func send(_ body: String, method: String = "POST", target: String = "/mcp", headers: [String: String] = [:],
                      peer: String = "127.0.0.1", token: String? = nil) async -> MCPHTTPResponse {
        var all = [MCPHTTPHeader(name: "Host", value: "127.0.0.1:41740"),
                   MCPHTTPHeader(name: "Content-Type", value: "application/json"),
                   MCPHTTPHeader(name: "Accept", value: "application/json, text/event-stream")]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            all.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            all.append(MCPHTTPHeader(name: name, value: value))
        }
        let request = MCPHTTPRequest(method: method, target: target, version: "HTTP/1.1", headers: all, body: Data(body.utf8))
        return await handleMCPHTTPRequest(request, MCPRequestContext(peer: peer, token: token))
    }

    private func call(_ method: String, _ params: String = "{}", headers: [String: String] = [:]) async -> MCPJSON? {
        let response = await send(#"{"jsonrpc":"2.0","id":7,"method":"\#(method)","params":\#(params)}"#, headers: headers)
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        XCTAssertEqual(response.header("Content-Type"), "application/json")
        let message = MCPJSON.decode(response.body)
        XCTAssertEqual(message?["jsonrpc"], .string("2.0"))
        XCTAssertEqual(message?["id"], .int(7))
        return message
    }

    private func tool(_ name: String, _ arguments: String = "{}") async -> MCPJSON? {
        await call("tools/call", #"{"name":"\#(name)","arguments":\#(arguments)}"#)?["result"]
    }

    private func text(_ result: MCPJSON?) -> String {
        result?["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
    }

    func testInitializeNamesWinMuxOffersToolsAndAgreesOnAVersion() async {
        let result = await call("initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#)?["result"]
        XCTAssertEqual(result?["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(result?["serverInfo"]?["name"], .string("winmux"))
        XCTAssertNotNil(result?["capabilities"]?["tools"])
        let older = await call("initialize", #"{"protocolVersion":"2025-03-26","capabilities":{}}"#)?["result"]
        XCTAssertEqual(older?["protocolVersion"], .string("2025-03-26"))
        let unknown = await call("initialize", #"{"protocolVersion":"1999-01-01","capabilities":{}}"#)?["result"]
        XCTAssertEqual(unknown?["protocolVersion"], .string("2025-06-18"), "Any other: the newest")
        let pong = await call("ping")
        XCTAssertEqual(pong?["result"], .object([:]))
    }

    func testANotificationIsAcceptedWithNoBody() async {
        let response = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(response.status, 202)
        XCTAssertEqual(response.body, Data())
    }

    func testOnlyPOSTOnTheMCPPathIsServed() async {
        let get = await send("", method: "GET")
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.header("Allow"), "POST")
        let elsewhere = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, target: "/")
        XCTAssertEqual(elsewhere.status, 404)
        let form = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(form.status, 415)
    }

    func testOtherPeersHostsOriginsAndMissingTokensAreRefusedBeforeAnythingRuns() async throws {
        let workspace = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        _ = Workspace.get(byName: "b")
        let switchTab = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"winmux","arguments":{"args":["workspace","b"]}}}"#

        let lan = await send(switchTab, peer: "192.168.1.20")
        XCTAssertEqual(lan.status, 403)
        let rebound = await send(switchTab, headers: ["Host": "evil.example:41740"])
        XCTAssertEqual(rebound.status, 403)
        let page = await send(switchTab, headers: ["Origin": "http://evil.example"])
        XCTAssertEqual(page.status, 403)
        let anonymous = await send(switchTab, token: "the-token")
        XCTAssertEqual(anonymous.status, 401)
        XCTAssertEqual(anonymous.header("WWW-Authenticate"), "Bearer")
        let wrong = await send(switchTab, headers: ["Authorization": "Bearer not-the-token"], token: "the-token")
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(focus.workspace.name, "a", "Nothing ran for a refused request")

        let allowed = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["Authorization": "Bearer the-token"], token: "the-token")
        XCTAssertEqual(allowed.status, 200)
    }

    func testAnUnsupportedProtocolVersionMalformedJSONOrUnknownMethodIsAnError() async {
        let version = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, headers: ["MCP-Protocol-Version": "1999-01-01"])
        XCTAssertEqual(version.status, 400)
        let malformed = await send("{")
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(MCPJSON.decode(malformed.body)?["error"]?["code"], .int(-32700))
        let unknown = await call("resources/list")
        XCTAssertEqual(unknown?["error"]?["code"], .int(-32601))
        let noTool = await call("tools/call", #"{"name":"no_such_tool","arguments":{}}"#)
        XCTAssertEqual(noTool?["error"]?["code"], .int(-32602))
    }

    func testToolsListNamesEachToolWithAnObjectSchemaAndSaysWhichOnlyRead() async throws {
        let listed = await call("tools/list")
        let tools = try XCTUnwrap(listed?["result"]?["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["list_windows", "get_focused_window", "list_workspaces", "list_pins",
                                                                  "list_monitors", "list_projects", "list_apps", "query_desktop", "winmux"])
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"), "\(tool)")
            XCTAssertNotNil(tool["description"]?.string)
            let readOnly = tool["annotations"]?["readOnlyHint"]?.bool
            XCTAssertEqual(readOnly, tool["name"] != .string("winmux"), "\(tool)")
        }
    }

    func testAReadToolRunsTheCLIsQueryAndShowsPins() async throws {
        let code = Workspace.get(byName: "code")
        _ = TestWindow.new(id: 1, parent: code.rootTilingContainer)
        let mail = Workspace.get(byName: "mail")
        let window = TestWindow.new(id: 2, parent: mail.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(mail, true)
        XCTAssertTrue(window.focusWindow())

        let result = await tool("list_workspaces")
        XCTAssertEqual(result?["isError"], .bool(false), text(result))
        let rows = try XCTUnwrap(MCPJSON.decode(Data(text(result).utf8))?.array, text(result))
        let byName = Dictionary(rows.compactMap { row in row["workspace"]?.string.map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["mail"]?["workspace-is-pinned"], .bool(true))
        XCTAssertEqual(byName["mail"]?["workspace-is-focused"], .bool(true))
        XCTAssertEqual(byName["code"]?["workspace-is-pinned"], .bool(false))

        let pins = await tool("list_pins")
        let pinned = MCPJSON.decode(Data(text(pins).utf8))?.array?.compactMap { $0["workspace"]?.string }
        XCTAssertEqual(pinned, ["mail"])

        let focused = await tool("get_focused_window")
        XCTAssertEqual(MCPJSON.decode(Data(text(focused).utf8))?.array?.first?["window-id"], .int(2))
    }

    func testTheWinmuxToolRunsACommandAsTheCLIDoesAndRefusesWhatTheCLIRefuses() async throws {
        let first = Workspace.get(byName: "a")
        XCTAssertTrue(TestWindow.new(id: 1, parent: first.rootTilingContainer).focusWindow())
        _ = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)

        let switched = await tool("winmux", #"{"args":["workspace","b"]}"#)
        XCTAssertEqual(switched?["isError"], .bool(false), text(switched))
        XCTAssertEqual(switched?["structuredContent"]?["exitCode"], .int(0))
        XCTAssertEqual(focus.workspace.name, "b")

        // The CLI refuses exec-and-forget: it isn't one of its subcommands.
        let exec = await tool("winmux", #"{"args":["exec-and-forget","true"]}"#)
        XCTAssertEqual(exec?["isError"], .bool(true))
        let cli = await runCliRequest(ClientRequest(args: ["exec-and-forget", "true"], stdin: "", windowId: nil, workspace: nil))
        XCTAssertNotEqual(cli.exitCode, 0)
        XCTAssertEqual(text(exec), cli.stderr, "The same answer as the CLI's")
        let subscribe = await tool("winmux", #"{"args":["subscribe","focus-changed"]}"#)
        XCTAssertEqual(subscribe?["isError"], .bool(true))
        XCTAssertTrue(text(subscribe).contains("subscribe"), text(subscribe))
        let unknown = await tool("winmux", #"{"args":["no-such-command"]}"#)
        XCTAssertEqual(unknown?["isError"], .bool(true))
        let empty = await call("tools/call", #"{"name":"winmux","arguments":{"args":[]}}"#)
        XCTAssertEqual(empty?["error"]?["code"], .int(-32602))
        XCTAssertEqual(focus.workspace.name, "b")
    }

    // MARK: - Review regressions (Astra, 2026-11-13)

    private func switchToB(id: MCPJSON = .int(1)) -> MCPJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "method": .string("tools/call"),
            "params": .object(["name": .string("winmux"), "arguments": .object(["args": .array([.string("workspace"), .string("b")])])])])
    }

    private func post(_ message: MCPJSON, _ context: MCPRequestContext, version: String? = "2025-06-18",
                      host: String = "localhost:41740") async -> MCPHTTPResponse {
        var headers = [MCPHTTPHeader(name: "Host", value: host), MCPHTTPHeader(name: "Content-Type", value: "application/json"),
                       MCPHTTPHeader(name: "Accept", value: "application/json, text/event-stream")]
        if let version { headers.append(MCPHTTPHeader(name: "MCP-Protocol-Version", value: version)) }
        return await handleMCPHTTPRequest(MCPHTTPRequest(method: "POST", target: "/mcp", version: "HTTP/1.1", headers: headers,
            body: message.encoded()), context)
    }

    private func startOnA() {
        XCTAssertTrue(TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer).focusWindow())
        _ = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
    }

    /// Only this Mac's loopback is served: a Tailscale or LAN peer is refused, whatever its Host names.
    func testAPeerThatIsntLoopbackIsRefusedWhateverItsHostNames() async {
        startOnA()
        for peer in ["100.101.102.104", "fd7a:115c:a1e0::1234:5679", "::ffff:100.101.102.104", "192.168.1.20"] {
            for host in ["localhost:41740", "127.0.0.1:41740", "mac-studio.tail1234.ts.net:41740"] {
                let response = await post(switchToB(), MCPRequestContext(peer: peer, token: nil), host: host)
                XCTAssertEqual(response.status, 403, "\(peer) \(host)")
                XCTAssertEqual(focus.workspace.name, "a", "A refused peer runs nothing: \(peer)")
            }
        }
    }

    /// Only a well-formed request runs: an id that's a string or an integer, a string method, object params,
    /// and a tool's declared arguments. Anything else is answered with an error and runs nothing.
    func testAMalformedEnvelopeRunsNothing() async {
        startOnA()
        let local = MCPRequestContext(peer: "127.0.0.1", token: nil)
        for id: MCPJSON in [.bool(true), .array([]), .object([:]), .null, .double(1.5)] {
            let response = await post(switchToB(id: id), local)
            XCTAssertEqual(MCPJSON.decode(response.body)?["error"]?["code"], .int(-32600), "id \(id)")
            XCTAssertEqual(MCPJSON.decode(response.body)?["id"], .null, "id \(id)")
            XCTAssertEqual(focus.workspace.name, "a", "id \(id)")
        }
        let params: MCPJSON = .object(["name": .string("winmux"), "arguments": .object(["args": .array([.string("workspace"), .string("b")])])])
        let malformed: [(MCPJSON, Int)] = [
            (.object(["id": .int(1), "method": .string("tools/call"), "params": params]), -32600),
            (.object(["jsonrpc": .string("1.0"), "id": .int(1), "method": .string("tools/call"), "params": params]), -32600),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .int(3), "params": params]), -32600),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"), "params": .array([params])]), -32602),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                      "params": .object(["name": .string("winmux"), "arguments": .array([])])]), -32602),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                      "params": .object(["name": .string("winmux"), "arguments": .object(["args": .array([.string("workspace"), .string("b")]),
                                                                                           "argz": .bool(true)])])]), -32602),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                      "params": .object(["arguments": .object(["args": .array([.string("workspace"), .string("b")])])])]), -32602),
            (.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                      "params": .object(["name": .string("list_windows"), "arguments": .object(["workspace": .int(3)])])]), -32602),
        ]
        for (message, code) in malformed {
            let response = await post(message, local)
            XCTAssertEqual(MCPJSON.decode(response.body)?["error"]?["code"], .int(code), "\(message)")
            XCTAssertEqual(focus.workspace.name, "a", "\(message)")
        }
        for id: MCPJSON in [.string("request-1"), .int(-4)] {
            let response = await post(.object(["jsonrpc": .string("2.0"), "id": id, "method": .string("ping")]), local)
            XCTAssertEqual(MCPJSON.decode(response.body)?["id"], id)
            XCTAssertEqual(MCPJSON.decode(response.body)?["result"], .object([:]))
        }
    }

    /// One JSON-RPC message per POST: a batch is refused whole, whatever protocol version the client names.
    func testABatchRunsNothing() async {
        startOnA()
        let local = MCPRequestContext(peer: "127.0.0.1", token: nil)
        for version: String? in ["2025-06-18", "2025-03-26", nil] {
            let response = await post(.array([switchToB()]), local, version: version)
            XCTAssertEqual(response.status, 400, version ?? "no version")
            XCTAssertEqual(MCPJSON.decode(response.body)?["error"]?["code"], .int(-32600))
            XCTAssertEqual(focus.workspace.name, "a", version ?? "no version")
        }
    }

    func testStandardInputReachesTheCommandAsFromTheCLI() async throws {
        let stdin = try freshAgentJson(#"{"schemaVersion":1,"edit":{"operations":[]}}"#)
        let args = ["agent", "check", "--stdin"]
        let cli = await runCliRequest(ClientRequest(args: args, stdin: stdin, windowId: nil, workspace: nil))
        XCTAssertEqual(cli.exitCode, 0)
        let message = MCPJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string("winmux"), "arguments": .object(["args": .array(args.map(MCPJSON.string)),
                                                                                   "stdin": .string(stdin)])])])
        let response = await post(message, MCPRequestContext(peer: "127.0.0.1", token: nil))
        let content = MCPJSON.decode(response.body)?["result"]?["structuredContent"]
        XCTAssertEqual(content?["exitCode"], .int(Int(cli.exitCode)))
        XCTAssertEqual(content?["stdout"], .string(cli.stdout))
        XCTAssertEqual(content?["stderr"], .string(cli.stderr))
    }

    // MARK: - Review regressions (Carbon, 2026-11-13)

    /// The CLI prints its help and version itself, before asking the server; the winmux tool answers them the same way.
    func testHelpAndVersionWorkAsFromTheCLI() async {
        for args in [["--help"], ["-h"], ["--help", "workspace"]] {
            let help = await tool("winmux", #"{"args":\#(String(decoding: MCPJSON.array(args.map(MCPJSON.string)).encoded(), as: UTF8.self))}"#)
            XCTAssertEqual(help?["isError"], .bool(false), "\(args): \(text(help))")
            XCTAssertTrue(text(help).hasPrefix("USAGE: winmux [-h|--help] [-v|--version] <subcommand> [<args>...]"), text(help))
            for name in ["workspace", "list-windows", "trigger-binding", "agent"] {
                XCTAssertTrue(text(help).contains("\n  \(name) "), "\(name) in \(text(help))")
            }
        }
        for args in [["--version"], ["-v"]] {
            let version = await tool("winmux", #"{"args":\#(String(decoding: MCPJSON.array(args.map(MCPJSON.string)).encoded(), as: UTF8.self))}"#)
            XCTAssertEqual(version?["isError"], .bool(false), "\(args): \(text(version))")
            XCTAssertTrue(text(version).contains("WinMux.app server version: \(winMuxAppVersion) \(gitHash)"), text(version))
        }
        let commandHelp = await tool("winmux", #"{"args":["workspace","--help"]}"#)
        XCTAssertEqual(commandHelp?["isError"], .bool(false), text(commandHelp))
    }

    /// No window has focus: an empty list, as the tool promises, not an error.
    func testTheFocusedWindowIsAnEmptyListWhenNoWindowHasFocus() async throws {
        let empty = Workspace.get(byName: "empty")
        XCTAssertTrue(empty.focusWorkspace())
        XCTAssertNil(focus.windowOrNil)
        let result = await tool("get_focused_window")
        XCTAssertEqual(result?["isError"], .bool(false), text(result))
        XCTAssertEqual(MCPJSON.decode(Data(text(result).utf8)), .array([]))
    }

    func testTheCLINamesPinnedWorkspaces() async throws {
        _ = TestWindow.new(id: 1, parent: Workspace.get(byName: "code").rootTilingContainer)
        let mail = Workspace.get(byName: "mail")
        _ = TestWindow.new(id: 2, parent: mail.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(mail, true)
        let command = try XCTUnwrap(parseCommand("list-workspaces --all --format '%{workspace}|%{workspace-is-pinned}'").cmdOrNil)
        let result = try await command.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertTrue(result.stdout.contains("mail|true"), "\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("code|false"), "\(result.stdout)")
    }
}
