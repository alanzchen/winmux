import Common
import Foundation

/// The one path WinMux's MCP server answers on.
let mcpServerPath = "/mcp"
/// Newest first: an `initialize` asking for one of these gets it, any other the newest.
let mcpSupportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
/// How long a tool waits for its command. The command isn't stopped then, as the CLI's never is.
let mcpToolTimeout: Duration = .seconds(60)

/// Where a request arrived: the server's own port, which only this Mac reaches, or its tailnet port, which
/// `tailscale serve` forwards requests from the tailnet to. Told by the listener that accepted the connection alone,
/// never by anything the request says.
enum MCPAccess: String, Sendable {
    case local
    case tailnet
}

/// Who asked, on which port, and the token a request must carry, if one's required.
struct MCPRequestContext: Sendable {
    var peer: String
    var token: String?
    var access: MCPAccess = .local
    /// This Mac's machine name in the tailnet, which a tailnet request's Host must name.
    var tailnetName: String = ""
    /// Allow debug screenshots is on: the screenshot and recording tools are offered.
    var debugCapture: Bool = false
}

/// What a request may not do, set for the commands it runs however they're reached, a binding included.
enum MCPRequestRestrictions {
    /// `list-exec-env-vars` refuses: see `mcpRestrictsEnvironmentListing`.
    @TaskLocal static var refusesEnvironmentListing = false
    /// No screen image is captured or sent: see `mcpRestrictsScreenImages`.
    @TaskLocal static var refusesScreenImages = false
}

let mcpScreenImagesRefusal = "Screen images aren't captured or sent for a request from the tailnet while the server requires no "
    + "access token: they show whatever is on screen and can't be redacted. To allow them, turn on Require access token in "
    + "Settings → General → MCP server."

/// Screenshots and recorded frames show whatever is on screen and can't be redacted. A request from the tailnet gets
/// none while the server requires no token; structured snapshots and recordings still work.
func mcpRestrictsScreenImages(_ context: MCPRequestContext) -> Bool {
    context.access == .tailnet && context.token == nil
}

let mcpEnvironmentListingRefusal = "list-exec-env-vars prints the environment WinMux's commands inherit, which may hold "
    + "secrets, so it isn't run for a request from the tailnet while the server requires no access token. To allow it, "
    + "turn on Require access token in Settings → General → MCP server."

/// `list-exec-env-vars` prints the environment WinMux's commands inherit, which may hold secrets. A request from the
/// tailnet gets it only while the server requires a token; one on this Mac's own port runs it as from the CLI. The
/// command itself refuses, so running it through `trigger-binding` is refused too; its help isn't.
func mcpRestrictsEnvironmentListing(_ context: MCPRequestContext) -> Bool {
    context.access == .tailnet && context.token == nil
}

struct MCPToolArgumentError: Error, Sendable {
    let message: String
}

/// A tool runs CLI commands through the CLI's own dispatch, so it can do nothing the CLI can't.
struct MCPTool: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: MCPJSON
    var outputSchema: MCPJSON? = nil
    let readOnly: Bool
    /// Offered only while Allow debug screenshots is on.
    var needsDebugCapture = false
    /// Whether it may destroy anything; by default, whether it isn't read-only.
    var destructive: Bool? = nil
    let run: @Sendable ([String: MCPJSON]) async -> Result<MCPJSON, MCPToolArgumentError>

    /// The arguments its schema declares; any other is refused.
    var argumentNames: Set<String> { Set(inputSchema["properties"]?.object?.keys.map { $0 } ?? []) }

    var json: MCPJSON {
        var object: [String: MCPJSON] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive ?? !readOnly),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": .bool(false),
            ]),
        ]
        if let outputSchema { object["outputSchema"] = outputSchema }
        return .object(object)
    }
}

// MARK: - HTTP

/// One HTTP request to the server, answered whole. A refused peer, host, origin, path, token or message runs
/// nothing.
func handleMCPHTTPRequest(_ request: MCPHTTPRequest, _ context: MCPRequestContext) async -> MCPHTTPResponse {
    guard mcpPeerIsAllowed(context.peer) else {
        return .refusal(403, "WinMux's MCP server answers only this Mac.")
    }
    // tailscaled marks what `tailscale funnel` brings from the internet, and drops a mark a client sent. Neither port
    // is for the internet. The mark is only ever a reason to refuse.
    guard request.header("Tailscale-Funnel-Request") == nil else {
        return .refusal(403, "WinMux's MCP server doesn't answer requests from Tailscale Funnel.")
    }
    switch context.access {
        case .local:
            // The local port is this Mac's. A request a proxy forwarded isn't, whatever Host its client chose: the
            // proxy's own HTTPS name decides where it goes, and the Host it passes on is the client's. So
            // `tailscale serve` pointed here, or at a port this one later takes, gets nothing.
            guard !mcpRequestWasForwarded(request) else {
                return .refusal(403, "WinMux's local MCP port doesn't answer requests a proxy forwarded. Point tailscale serve at "
                    + "the tailnet port: Settings → General → MCP server → Allow access from my tailnet.")
            }
            guard mcpHostIsAllowed(request.header("Host")) else {
                return .refusal(403, "The Host header doesn't name this server.")
            }
            guard mcpOriginIsAllowed(request.header("Origin")) else {
                return .refusal(403, "Requests from this web page's origin aren't allowed.")
            }
        case .tailnet:
            // Whatever the request says, it's from the tailnet: its headers are never taken as who sent it.
            guard mcpTailnetHostIsAllowed(request.header("Host"), machineName: context.tailnetName) else {
                return .refusal(403, "The Host header doesn't name this Mac in your tailnet.")
            }
            guard mcpTailnetOriginIsAllowed(request.header("Origin"), host: request.header("Host")) else {
                return .refusal(403, "Requests from this web page's origin aren't allowed.")
            }
    }
    let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    guard path == mcpServerPath else {
        return .refusal(404, "WinMux's MCP server is at \(mcpServerPath).")
    }
    guard mcpRequestIsAuthorized(authorization: request.header("Authorization"), token: context.token) else {
        return .refusal(401, "This server requires its access token: Authorization: Bearer <token>.",
            headers: [MCPHTTPHeader(name: "WWW-Authenticate", value: "Bearer")])
    }
    guard request.method == "POST" else {
        return .refusal(405, "Send JSON-RPC messages with POST. This server doesn't offer an event stream.",
            headers: [MCPHTTPHeader(name: "Allow", value: "POST")])
    }
    let type = request.header("Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
    guard type == "application/json" else {
        return .refusal(415, "Send JSON-RPC messages as application/json.")
    }
    if let version = request.header("MCP-Protocol-Version"), !mcpSupportedProtocolVersions.contains(version) {
        return .refusal(400, "Unsupported MCP protocol version. Supported: \(mcpSupportedProtocolVersions.joined(separator: ", ")).")
    }
    guard let message = MCPJSON.decode(request.body) else {
        return .json(mcpRPCError(id: .null, code: -32700, "Parse error"), status: 400)
    }
    // One message per POST, as 2025-06-18 requires. Older versions' batches aren't supported either: no
    // client is known to send them, and refusing them whole runs nothing half-way.
    if case .array = message {
        return .json(mcpRPCError(id: .null, code: -32600, "Batches aren't supported: send one JSON-RPC message per request."), status: 400)
    }
    guard let answer = await mcpAnswer(message, context) else { return MCPHTTPResponse(status: 202) }
    return .json(answer)
}

// MARK: - JSON-RPC

/// A request's id, if it's one MCP allows: a string or an integer, never null.
private func mcpRequestId(_ id: MCPJSON?) -> MCPJSON? {
    switch id {
        case .string?, .int?: id
        default: nil
    }
}

/// The answer to one JSON-RPC message, or nil for a notification or a client's response, which get none. The
/// message is checked whole before anything runs.
private func mcpAnswer(_ message: MCPJSON, _ context: MCPRequestContext) async -> MCPJSON? {
    guard let object = message.object else { return mcpRPCError(id: .null, code: -32600, "Invalid Request") }
    let validId = mcpRequestId(object["id"])
    guard object["jsonrpc"] == .string("2.0") else { return mcpRPCError(id: validId ?? .null, code: -32600, "Invalid Request") }
    if object["method"] == nil, object["result"] != nil || object["error"] != nil { return nil }
    guard let method = object["method"]?.string else { return mcpRPCError(id: validId ?? .null, code: -32600, "Invalid Request") }
    // Present but not a string or an integer, null included: invalid, and nothing runs.
    if object["id"] != nil, validId == nil {
        return mcpRPCError(id: .null, code: -32600, "Invalid Request: an id must be a string or an integer")
    }
    var params: [String: MCPJSON] = [:]
    if let raw = object["params"] {
        guard let given = raw.object else {
            return validId.map { mcpRPCError(id: $0, code: -32602, "Invalid params: params must be an object") }
        }
        params = given
    }
    guard let id = validId else { return nil }
    switch method {
        case "initialize":
            return mcpRPCResult(id: id, mcpInitializeResult(params))
        case "ping":
            return mcpRPCResult(id: id, .object([:]))
        case "tools/list":
            return mcpRPCResult(id: id, .object(["tools": .array(mcpOfferedTools(context).map(\.json))]))
        case "tools/call":
            guard let name = params["name"]?.string else { return mcpRPCError(id: id, code: -32602, "Invalid params: name a tool") }
            guard let tool = mcpOfferedTools(context).first(where: { $0.name == name }) else {
                return mcpRPCError(id: id, code: -32602, "Unknown tool")
            }
            var arguments: [String: MCPJSON] = [:]
            if let raw = params["arguments"] {
                guard let given = raw.object else {
                    return mcpRPCError(id: id, code: -32602, "Invalid params: arguments must be an object")
                }
                arguments = given
            }
            if let unknown = arguments.keys.sorted().first(where: { !tool.argumentNames.contains($0) }) {
                return mcpRPCError(id: id, code: -32602, "Invalid params: \(name) has no argument \(unknown)")
            }
            // Set for whatever the tool runs, in this request's task only.
            let outcome = await MCPRequestRestrictions.$refusesEnvironmentListing.withValue(mcpRestrictsEnvironmentListing(context)) {
                await MCPRequestRestrictions.$refusesScreenImages.withValue(mcpRestrictsScreenImages(context)) {
                    await tool.run(arguments)
                }
            }
            switch outcome {
                case .success(let result): return mcpRPCResult(id: id, result)
                case .failure(let error): return mcpRPCError(id: id, code: -32602, error.message)
            }
        default:
            return mcpRPCError(id: id, code: -32601, "Method not found")
    }
}

private func mcpRPCResult(id: MCPJSON, _ result: MCPJSON) -> MCPJSON {
    .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
}

private func mcpRPCError(id: MCPJSON, code: Int, _ message: String) -> MCPJSON {
    .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
}

private func mcpInitializeResult(_ params: [String: MCPJSON]) -> MCPJSON {
    let requested = params["protocolVersion"]?.string
    let version = requested.flatMap { mcpSupportedProtocolVersions.contains($0) ? $0 : nil } ?? mcpSupportedProtocolVersions[0]
    return .object([
        "protocolVersion": .string(version),
        "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
        "serverInfo": .object(["name": .string("winmux"), "title": .string("WinMux"), "version": .string(winMuxAppVersion)]),
        "instructions": .string("""
            WinMux is a macOS window manager. Its workspaces are the tabs of Tabs mode; a pinned workspace is a pin. \
            Read windows, workspaces, pins, displays, projects and apps with the list_ tools, or query_desktop for one \
            structured snapshot of the layout. The winmux tool runs any winmux command-line command, given its \
            arguments without the leading "winmux", with exactly the CLI's effects; ["--help"] lists the commands and \
            [<command>, "--help"] explains one.
            """),
    ])
}

// MARK: - Tools

/// The tools this request is offered: the debug capture tools only while Allow debug screenshots is on.
func mcpOfferedTools(_ context: MCPRequestContext) -> [MCPTool] {
    mcpTools.filter { !$0.needsDebugCapture || context.debugCapture }
}

private let mcpWindowFields = "%{window-id} %{window-title} %{window-layout} %{window-is-fullscreen} %{app-name} %{app-bundle-id} "
    + "%{app-pid} %{workspace} %{workspace-display-name} %{workspace-is-pinned} %{monitor-id} %{monitor-name}"
private let mcpWorkspaceFields = "%{workspace} %{workspace-display-name} %{workspace-is-focused} %{workspace-is-visible} "
    + "%{workspace-is-saved} %{workspace-is-pinned} %{workspace-root-container-layout} %{monitor-id} %{monitor-name}"

private let mcpNoArguments: MCPJSON = .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])

let mcpTools: [MCPTool] = [
    MCPTool(name: "list_windows", title: "List windows",
        description: "Windows WinMux manages, as JSON: id, title, layout, app, workspace (tab), whether that workspace is pinned, and display. "
            + "Runs `winmux list-windows --all --json` (or `--workspace <name>`).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["workspace": .object([
                "type": .string("string"),
                "description": .string("Only this workspace's windows, by the name commands accept (the `workspace` field)."),
            ])]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: true,
        run: { arguments in
            let scope: [String]
            switch arguments["workspace"] {
                case nil, .null?: scope = ["--all"]
                case .string(let name)?: scope = ["--workspace", name]
                default: return .failure(MCPToolArgumentError(message: "workspace must be a string"))
            }
            return .success(mcpReadResult(await mcpRunCli(["list-windows"] + scope + ["--json", "--format", mcpWindowFields])))
        }),
    MCPTool(name: "get_focused_window", title: "Get the focused window",
        description: "The focused window, as `list_windows` describes it; an empty list when no window has focus. "
            + "Runs `winmux list-windows --focused --json`.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in
            let answer = await mcpRunCli(["list-windows", "--focused", "--json", "--format", mcpWindowFields])
            // No window has focus: the CLI says so as an error; the tool's answer is an empty list. Other errors stay errors.
            if let answer, answer.exitCode != 0, answer.stderr == noWindowIsFocused { return .success(mcpTextResult("[]", isError: false)) }
            return .success(mcpReadResult(answer))
        }),
    MCPTool(name: "list_workspaces", title: "List workspaces",
        description: "Workspaces (the tabs of Tabs mode), as JSON: name, display name, focused, visible, saved, pinned, layout and display. "
            + "Runs `winmux list-workspaces --all --json`.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in .success(mcpReadResult(await mcpRunCli(["list-workspaces", "--all", "--json", "--format", mcpWorkspaceFields]))) }),
    MCPTool(name: "list_pins", title: "List pins",
        description: "Pinned workspaces only, as `list_workspaces` describes them.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in
            let answer = await mcpRunCli(["list-workspaces", "--all", "--json", "--format", mcpWorkspaceFields])
            guard let answer, answer.exitCode == 0, let rows = MCPJSON.decode(Data(answer.stdout.utf8))?.array else {
                return .success(mcpReadResult(answer))
            }
            let pins = MCPJSON.array(rows.filter { $0["workspace-is-pinned"] == .bool(true) })
            return .success(mcpTextResult(String(decoding: pins.encoded(), as: UTF8.self), isError: false))
        }),
    MCPTool(name: "list_monitors", title: "List displays",
        description: "Displays, as JSON: id, name, whether it's the main display. Runs `winmux list-monitors --json`.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in
            .success(mcpReadResult(await mcpRunCli(["list-monitors", "--json", "--format",
                "%{monitor-id} %{monitor-name} %{monitor-is-main} %{monitor-appkit-nsscreen-screens-id}"])))
        }),
    MCPTool(name: "list_projects", title: "List projects",
        description: "Projects, as JSON: index, id, name, color, focused, visible, and workspace and window counts. "
            + "Runs `winmux list-projects --json`.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in
            .success(mcpReadResult(await mcpRunCli(["list-projects", "--json", "--format",
                "%{project-index} %{project-id} %{project-name} %{project-color} %{project-is-focused} %{project-is-visible} "
                    + "%{project-workspace-count} %{project-window-count}"])))
        }),
    MCPTool(name: "list_apps", title: "List apps",
        description: "Running apps with a user interface, as JSON: name, bundle id, process id. Runs `winmux list-apps --json`.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in .success(mcpReadResult(await mcpRunCli(["list-apps", "--json", "--format", "%{app-name} %{app-bundle-id} %{app-pid}"]))) }),
    MCPTool(name: "query_desktop", title: "Query the desktop",
        description: "One structured snapshot of every workspace's windows, tab groups and layout, as `winmux agent query` prints it. "
            + "`winmux agent skill` (through the winmux tool) explains it and how to apply edits.",
        inputSchema: mcpNoArguments, readOnly: true,
        run: { _ in .success(mcpReadResult(await mcpRunCli(["agent", "query"]))) }),
    MCPTool(name: "winmux_debug_snapshot", title: "Debug snapshot",
        description: "One JSON document for diagnosing window and sidebar problems: WinMux and macOS versions, every display "
            + "(frame, visible frame, the workspace it shows, focus), the sidebar's rows as drawn with each member window's "
            + "state (workspace, container, floating or tiled, auxiliary parent, hidden, minimized, full screen, parked in "
            + "a corner, the frame WinMux last placed it at and the one macOS reports, whether its app still lists it, its "
            + "last Accessibility error) and recent window events. Reads only: nothing is run, moved or refreshed. Titles, "
            + "tab labels and app paths are left out unless include_titles is true.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "window_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer"), "minimum": .int(0)]),
                    "description": .string("Only these windows: the rows they're in, whole, and their events. Displays are always described."),
                ]),
                "include_titles": .object([
                    "type": .string("boolean"),
                    "description": .string("Include window titles, tab labels and app paths. Default false."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: true,
        run: { arguments in
            switch mcpDebugSnapshotOptions(arguments) {
                case .success(let options):
                    let document = await mcpDebugSnapshot(options)
                    return .success(mcpTextResult(String(decoding: document.encoded(), as: UTF8.self), isError: false))
                case .failure(let error):
                    return .failure(error)
            }
        }),
    MCPTool(name: "winmux_debug_screenshot", title: "Debug screenshot",
        description: "An image of each display, or of one, as it is now, WinMux's own sidebar and panels included, with each "
            + "display's id and frame in the coordinates winmux_debug_snapshot uses, so the two line up. Images can't be "
            + "redacted: they show whatever is on screen, titles and private content included. Downscaled to max_long_edge "
            + "(default 1600 px, at most the display's own size). Kept in memory only. Offered while Allow debug screenshots "
            + "is on; needs macOS's Screen Recording permission. From the tailnet, only while the server requires a token.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "display": .object(["type": .string("integer"), "minimum": .int(1),
                                    "description": .string("Only this display: its id in winmux_debug_snapshot's monitors.")]),
                "max_long_edge": .object(["type": .string("integer"), "minimum": .int(debugCaptureLongEdgeRange.lowerBound),
                                          "maximum": .int(debugCaptureLongEdgeRange.upperBound),
                                          "description": .string("The longest side of each image, in pixels. Default 1600; never more than native.")]),
                "format": .object(["type": .string("string"), "enum": .array([.string("jpeg"), .string("png")]),
                                   "description": .string("jpeg (default) or png.")]),
            ]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: true,
        needsDebugCapture: true,
        run: { arguments in
            switch mcpDebugScreenshotOptions(arguments) {
                case .success(let options): .success(await mcpDebugScreenshot(options))
                case .failure(let error): .failure(error)
            }
        }),
    MCPTool(name: "winmux_debug_recording", title: "Debug recording",
        description: "Records WinMux for up to 120 seconds: every interval_ms, a winmux_debug_snapshot and, if allowed, a "
            + "downscaled frame of each display, plus every window event between them. action start begins one (one at a "
            + "time); status reports it; fetch returns it a page at a time from cursor (pass the nextCursor it gave); stop "
            + "ends it and discards everything. It's kept in memory only, at most 64 MB (the oldest frames go first, and it "
            + "says so), and discarded once its last page is fetched or 10 minutes after it ends. The menu bar shows a running "
            + "recording. Frames can't be redacted: they show whatever is on screen. Without Screen Recording permission, or "
            + "from the tailnet while no token is required, it records snapshots and events only.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "enum": .array(["start", "status", "fetch", "stop"].map(MCPJSON.string))]),
                "duration_seconds": .object(["type": .string("integer"), "minimum": .int(debugRecordingDurationRange.lowerBound),
                                             "maximum": .int(debugRecordingDurationRange.upperBound),
                                             "description": .string("start: how long, default 60.")]),
                "interval_ms": .object(["type": .string("integer"), "minimum": .int(debugRecordingIntervalRange.lowerBound),
                                        "maximum": .int(debugRecordingIntervalRange.upperBound),
                                        "description": .string("start: time between captures, default 1000.")]),
                "frames": .object(["type": .string("boolean"), "description": .string("start: capture frames too, if allowed. Default true.")]),
                "display": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("start: frames of this display only.")]),
                "max_long_edge": .object(["type": .string("integer"), "minimum": .int(debugCaptureLongEdgeRange.lowerBound),
                                          "maximum": .int(debugCaptureLongEdgeRange.upperBound),
                                          "description": .string("start: the longest side of a frame, default 1024.")]),
                "format": .object(["type": .string("string"), "enum": .array([.string("jpeg"), .string("png")])]),
                "window_ids": .object(["type": .string("array"), "items": .object(["type": .string("integer"), "minimum": .int(0)]),
                                       "description": .string("start: snapshots of the rows with these windows only.")]),
                "include_titles": .object(["type": .string("boolean"), "description": .string("start: titles in the snapshots. Default false.")]),
                "cursor": .object(["type": .string("integer"), "minimum": .int(-1), "description": .string("fetch: the nextCursor of the page before.")]),
                "id": .object(["type": .string("string"), "description": .string("fetch, stop: the recording's id, to be sure it's that one.")]),
            ]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false),
        ]),
        readOnly: false,
        needsDebugCapture: true,
        destructive: false,
        run: { arguments in await mcpDebugRecording(arguments) }),
    MCPTool(name: "winmux", title: "Run a winmux command",
        description: "Runs one winmux command-line command, with exactly the CLI's effects and limits: give its arguments without "
            + "the leading \"winmux\", such as [\"workspace\", \"mail\"] or [\"focus\", \"--window-id\", \"123\"]. "
            + "[\"--help\"] lists the commands. `exec-and-forget` is refused, as it is from the CLI, and `subscribe` "
            + "isn't available here: it's the one CLI command not offered, because it streams.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "args": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "minItems": .int(1),
                    "description": .string("The command and its arguments, as you'd type them after `winmux`."),
                ]),
                "stdin": .object([
                    "type": .string("string"),
                    "description": .string("Standard input, for commands that read it, such as `agent apply --stdin`."),
                ]),
            ]),
            "required": .array([.string("args")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "exitCode": .object(["type": .string("integer")]),
                "stdout": .object(["type": .string("string")]),
                "stderr": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("exitCode"), .string("stdout"), .string("stderr")]),
        ]),
        readOnly: false,
        run: { arguments in
            guard let list = arguments["args"]?.array, !list.isEmpty else {
                return .failure(MCPToolArgumentError(message: "args must be a non-empty array of strings"))
            }
            let args = list.compactMap(\.string)
            guard args.count == list.count else { return .failure(MCPToolArgumentError(message: "args must be strings")) }
            var stdin = ""
            switch arguments["stdin"] {
                case nil, .null?: break
                case .string(let text)?: stdin = text
                default: return .failure(MCPToolArgumentError(message: "stdin must be a string"))
            }
            if args.first == "subscribe" {
                return .success(mcpTextResult("subscribe streams events and isn't available over MCP. "
                    + "Read state with the list tools instead.", isError: true))
            }
            // The CLI prints its help and version itself, before asking WinMux.app: answered here from the same text.
            if args.first == "--help" || args.first == "-h" {
                return .success(mcpCommandResult(mcpLocalAnswer(winmuxUsage(program: "winmux", includesClientCommands: false))))
            }
            if args.first == "--version" || args.first == "-v" {
                return .success(mcpCommandResult(mcpLocalAnswer(winmuxVersionText(clientVersionAndHash: nil,
                    serverVersionAndHash: "\(winMuxAppVersion) \(gitHash)"))))
            }
            return .success(mcpCommandResult(await mcpRunCli(args, stdin: stdin)))
        }),
]

private func mcpIntArgument(_ arguments: [String: MCPJSON], _ name: String, _ range: ClosedRange<Int>) -> Result<Int?, MCPToolArgumentError> {
    switch arguments[name] {
        case nil, .null?: return .success(nil)
        case .int(let value)? where range.contains(value): return .success(value)
        default: return .failure(MCPToolArgumentError(message: "\(name) must be an integer from \(range.lowerBound) to \(range.upperBound)"))
    }
}

private func mcpBoolArgument(_ arguments: [String: MCPJSON], _ name: String) -> Result<Bool?, MCPToolArgumentError> {
    switch arguments[name] {
        case nil, .null?: .success(nil)
        case .bool(let value)?: .success(value)
        default: .failure(MCPToolArgumentError(message: "\(name) must be true or false"))
    }
}

private func mcpFormatArgument(_ arguments: [String: MCPJSON]) -> Result<DebugImageFormat?, MCPToolArgumentError> {
    switch arguments["format"] {
        case nil, .null?: .success(nil)
        case .string(let text)? where DebugImageFormat(rawValue: text) != nil: .success(DebugImageFormat(rawValue: text))
        default: .failure(MCPToolArgumentError(message: "format must be jpeg or png"))
    }
}

private func mcpDebugScreenshotOptions(_ arguments: [String: MCPJSON]) -> Result<MCPDebugScreenshotOptions, MCPToolArgumentError> {
    var options = MCPDebugScreenshotOptions()
    do {
        options.monitorId = try mcpIntArgument(arguments, "display", 1 ... 64).get()
        options.maxLongEdge = try mcpIntArgument(arguments, "max_long_edge", debugCaptureLongEdgeRange).get() ?? options.maxLongEdge
        options.format = try mcpFormatArgument(arguments).get() ?? options.format
    } catch {
        return .failure(error)
    }
    return .success(options)
}

private let mcpRecordingStartArguments: Set<String> = ["duration_seconds", "interval_ms", "frames", "display", "max_long_edge", "format",
                                                       "window_ids", "include_titles"]

/// The recording tool's actions. Each takes only its own arguments.
@MainActor
private func mcpDebugRecording(_ arguments: [String: MCPJSON]) async -> Result<MCPJSON, MCPToolArgumentError> {
    guard let action = arguments["action"]?.string else {
        return .failure(MCPToolArgumentError(message: "action must be start, status, fetch or stop"))
    }
    let allowed: Set<String> = switch action {
        case "start": mcpRecordingStartArguments
        case "fetch": ["cursor", "id"]
        case "stop": ["id"]
        default: []
    }
    guard ["start", "status", "fetch", "stop"].contains(action) else {
        return .failure(MCPToolArgumentError(message: "action must be start, status, fetch or stop"))
    }
    if let other = arguments.keys.sorted().first(where: { $0 != "action" && !allowed.contains($0) }) {
        return .failure(MCPToolArgumentError(message: "\(other) isn't an argument of \(action)"))
    }
    let recorder = DebugRecorder.shared
    let refusesImages = MCPRequestRestrictions.refusesScreenImages
    let id = arguments["id"]?.string
    if arguments["id"] != nil, id == nil { return .failure(MCPToolArgumentError(message: "id must be a string")) }
    func result(_ document: MCPJSON) -> MCPJSON {
        .object(["content": .array([debugTextContent(document)]), "isError": .bool(false)])
    }
    switch action {
        case "start":
            var settings = DebugRecordingSettings()
            do {
                settings.durationSeconds = try mcpIntArgument(arguments, "duration_seconds", debugRecordingDurationRange).get() ?? settings.durationSeconds
                settings.intervalMs = try mcpIntArgument(arguments, "interval_ms", debugRecordingIntervalRange).get() ?? settings.intervalMs
                settings.frames = try mcpBoolArgument(arguments, "frames").get() ?? settings.frames
                settings.monitorId = try mcpIntArgument(arguments, "display", 1 ... 64).get()
                settings.maxLongEdge = try mcpIntArgument(arguments, "max_long_edge", debugCaptureLongEdgeRange).get() ?? settings.maxLongEdge
                settings.format = try mcpFormatArgument(arguments).get() ?? settings.format
                settings.snapshot = try mcpDebugSnapshotOptions(arguments.filter { ["window_ids", "include_titles"].contains($0.key) }).get()
            } catch {
                return .failure(error)
            }
            return recorder.start(settings, refusesImages: refusesImages).map(result)
        case "fetch":
            switch mcpIntArgument(arguments, "cursor", -1 ... Int.max) {
                case .success(let cursor): return recorder.fetch(after: cursor, id: id, refusesImages: refusesImages)
                case .failure(let error): return .failure(error)
            }
        case "stop":
            return recorder.stop(reason: "a client stopped it", id: id).map(result)
        default:
            return .success(result(recorder.status()))
    }
}

private func mcpDebugSnapshotOptions(_ arguments: [String: MCPJSON]) -> Result<MCPDebugSnapshotOptions, MCPToolArgumentError> {
    var options = MCPDebugSnapshotOptions()
    switch arguments["window_ids"] {
        case nil, .null?: break
        case .array(let list)?:
            var ids: Set<UInt32> = []
            for item in list {
                guard case .int(let value) = item, let id = UInt32(exactly: value) else {
                    return .failure(MCPToolArgumentError(message: "window_ids must be window ids: integers, 0 or more"))
                }
                ids.insert(id)
            }
            options.windowIds = ids
        default:
            return .failure(MCPToolArgumentError(message: "window_ids must be an array of window ids"))
    }
    switch arguments["include_titles"] {
        case nil, .null?: break
        case .bool(let value)?: options.includeTitles = value
        default: return .failure(MCPToolArgumentError(message: "include_titles must be true or false"))
    }
    return .success(options)
}

private func mcpLocalAnswer(_ stdout: String) -> ServerAnswer {
    ServerAnswer(exitCode: 0, stdout: stdout, stderr: "", serverVersionAndHash: "\(winMuxAppVersion) \(gitHash)")
}

/// Runs a CLI command through the CLI's dispatch, as a client with no WINMUX_WINDOW_ID or WINMUX_WORKSPACE would.
/// Nil when it hasn't answered within `mcpToolTimeout`.
private func mcpRunCli(_ args: [String], stdin: String = "") async -> ServerAnswer? {
    // Explicit nulls, as the CLI sends them when those variables are unset.
    let request = ClientRequest(args: args, stdin: stdin, windowId: nil, workspace: nil)
    return await mcpFirst(orAfter: mcpToolTimeout) { await runCliRequest(request) }
}

private func mcpTextResult(_ text: String, isError: Bool) -> MCPJSON {
    .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
}

private let mcpTimedOut = "The command didn't answer within \(mcpToolTimeout.components.seconds) seconds. It may still finish."

/// A read: the CLI's JSON as it printed it, or its error.
private func mcpReadResult(_ answer: ServerAnswer?) -> MCPJSON {
    guard let answer else { return mcpTextResult(mcpTimedOut, isError: true) }
    if answer.exitCode == 0 { return mcpTextResult(answer.stdout, isError: false) }
    return mcpTextResult(answer.stderr.isEmpty ? "Exit code \(answer.exitCode)" : answer.stderr, isError: true)
}

/// A command: what it printed, and its exit code, which says whether it failed.
private func mcpCommandResult(_ answer: ServerAnswer?) -> MCPJSON {
    guard let answer else { return mcpTextResult(mcpTimedOut, isError: true) }
    let text = [answer.stdout, answer.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text.isEmpty ? "Exit code \(answer.exitCode)" : text)])]),
        "structuredContent": .object([
            "exitCode": .int(Int(answer.exitCode)),
            "stdout": .string(answer.stdout),
            "stderr": .string(answer.stderr),
        ]),
        "isError": .bool(answer.exitCode != 0),
    ])
}

/// `work`'s value, or nil if it takes longer than `timeout`. `work` isn't cancelled: it finishes either way.
func mcpFirst<T: Sendable>(orAfter timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = MCPOnce()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if once.claim() { continuation.resume(returning: nil) }
        }
        Task {
            let value = await work()
            timer.cancel()
            if once.claim() { continuation.resume(returning: value) }
        }
    }
}

private final class MCPOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
