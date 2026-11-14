import Common
import Foundation
import Network
import SystemConfiguration

enum MCPServerState: Equatable, Sendable {
    case off
    case starting
    case listening
    case failed(String)
}

/// At most this many connections at once on each port; more are closed at once.
let mcpMaxConnections = 16
/// A request must arrive whole within this long of the connection waiting for it.
let mcpRequestReadTimeout: TimeInterval = 60

private let mcpServerQueue = DispatchQueue(label: "WinMux.MCPServer")

/// WinMux's MCP server: a listener on 127.0.0.1 and nowhere else while the config turns it on, and, while tailnet
/// access is on too, a second one on 127.0.0.1 for `tailscale serve` to forward requests from the tailnet to. Which
/// one accepted a connection is all that says where its requests came from.
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer(waitsForAppStart: true)

    @Published private(set) var state: MCPServerState = .off
    /// The port it listens on, once listening.
    @Published private(set) var port: Int?
    /// Whether a token is saved, for Settings.
    @Published private(set) var hasToken = false
    /// The tailnet port's listener, for requests `tailscale serve` forwards: its state and the port it listens on.
    @Published private(set) var tailnetState: MCPServerState = .off
    @Published private(set) var tailnetPort: Int?
    /// The machine name a tailnet request's Host must name.
    @Published private(set) var tailnetMachineName = ""
    /// While Allow debug screenshots is on: whether macOS lets WinMux record the screen. Nil while it's off.
    @Published private(set) var screenCaptureAllowed: Bool?

    /// This Mac's local host name, as Tailscale names a Mac by default. Replaced in tests.
    var localHostName: @MainActor () -> String? = { SCDynamicStoreCopyLocalHostName(nil) as String? }

    private var config = MCPServerConfig()
    /// Whether the debug capture tools were offered at the last apply: turning them on asks macOS for the permission.
    private var offersDebugCapture = false
    private let local = MCPListenerSlot(.local)
    private let tailnet = MCPListenerSlot(.tailnet)
    /// WinMux's own server listens only once the app has started, as the CLI's socket does.
    private var waitsForAppStart: Bool

    init(waitsForAppStart: Bool = false) {
        self.waitsForAppStart = waitsForAppStart
    }

    /// The app has started: the server listens if the config asks it to.
    func appDidStart() {
        waitsForAppStart = false
        apply(config)
    }

    /// The addresses it has a listener on now: 127.0.0.1, or none.
    var listeningAddresses: [String] { local.listener == nil && tailnet.listener == nil ? [] : [mcpLoopbackAddress] }

    /// The host its listener is bound to, if there's one.
    var listenerHost: String? { local.boundHost }

    /// The host the tailnet port's listener is bound to, if there's one.
    var tailnetListenerHost: String? { tailnet.boundHost }

    /// Starts or stops the listeners as `config` asks. A listener already on the right port stays, with its
    /// connections; another port, or turning it off, closes it and every connection it let in.
    func apply(_ config: MCPServerConfig) {
        self.config = config
        guard !waitsForAppStart else { return }
        hasToken = readMCPServerToken() != nil
        guard config.enabled else {
            applyDebugCapture(offers: false)
            for slot in [local, tailnet] {
                stopListener(slot)
                slot.reportedFailure = nil
                setState(.off, slot)
            }
            tailnetMachineName = ""
            return
        }
        if config.requireToken {
            var token = readMCPServerToken()
            if token == nil, !serverArgs.isReadOnly { token = try? generateMCPServerToken() }
            guard let token else {
                // Never serve without the token it requires.
                applyDebugCapture(offers: false)
                stopListener(local)
                stopListener(tailnet)
                setState(.off, tailnet)
                return fail("WinMux couldn't make the MCP server's access token, so the server isn't running.", local)
            }
            local.shared.token = token
            tailnet.shared.token = token
            hasToken = true
        } else {
            local.shared.token = nil
            tailnet.shared.token = nil
        }
        applyDebugCapture(offers: config.debugScreenshots)
        // A tailnet listener going away or moving lets go of its port first: the local one may be moving onto it.
        if !tailnetKeepsItsListener(config) { stopListener(tailnet) }
        keepOrStart(local, port: config.port)
        applyTailnet(config)
    }

    private func tailnetKeepsItsListener(_ config: MCPServerConfig) -> Bool {
        config.tailnet && tailnet.listener != nil && tailnet.listenerPort == config.tailnetPort && tailnetState != .off && !tailnetState.isFailed
    }

    /// Offers the debug capture tools while the server runs with Allow debug screenshots on. It never asks macOS for
    /// Screen Recording, at launch, on a reload from any client or ever: only the Settings action does. Turning the tools
    /// off revokes them: a recording is dropped, and a capture under way sends nothing.
    private func applyDebugCapture(offers: Bool) {
        local.shared.debugCapture = offers
        tailnet.shared.debugCapture = offers
        if !offers, offersDebugCapture || DebugRecorder.shared.recording != nil {
            revokeDebugCapture(reason: "Allow debug screenshots or the MCP server was turned off")
        }
        offersDebugCapture = offers
        screenCaptureAllowed = offers ? debugScreenCapture.hasPermission() : nil
    }

    /// Settings looks again, as the permission can change in System Settings at any time.
    func refreshScreenCapturePermission() {
        screenCaptureAllowed = offersDebugCapture ? debugScreenCapture.hasPermission() : nil
    }

    private func applyTailnet(_ config: MCPServerConfig) {
        guard config.tailnet else {
            stopListener(tailnet)
            tailnet.reportedFailure = nil
            setState(.off, tailnet)
            tailnetMachineName = ""
            return
        }
        let name = mcpTailnetMachineName(configured: config.tailnetName, localHostName: localHostName())
        tailnetMachineName = name
        tailnet.shared.tailnetName = name
        guard !name.isEmpty else {
            stopListener(tailnet)
            return fail("WinMux couldn't tell this Mac's name in your tailnet, so the tailnet port isn't open. "
                + "Set Name in your tailnet in Settings → General → MCP server.", tailnet)
        }
        guard config.tailnetPort == 0 || config.tailnetPort != config.port else {
            stopListener(tailnet)
            return fail("The tailnet port must differ from the MCP server's port.", tailnet)
        }
        keepOrStart(tailnet, port: config.tailnetPort)
    }

    func stop() {
        apply(MCPServerConfig(enabled: false, port: config.port))
    }

    /// A new token was saved: requests from now on need it.
    func tokenDidChange() {
        let token = readMCPServerToken()
        hasToken = token != nil
        if config.enabled, config.requireToken, let token {
            local.shared.token = token
            tailnet.shared.token = token
        }
    }

    private func state(of slot: MCPListenerSlot) -> MCPServerState { slot.access == .local ? state : tailnetState }

    private func setState(_ newState: MCPServerState, _ slot: MCPListenerSlot) {
        switch slot.access {
            case .local: state = newState
            case .tailnet: tailnetState = newState
        }
    }

    private func setPort(_ newPort: Int?, _ slot: MCPListenerSlot) {
        switch slot.access {
            case .local: port = newPort
            case .tailnet: tailnetPort = newPort
        }
    }

    private func keepOrStart(_ slot: MCPListenerSlot, port: Int) {
        let current = state(of: slot)
        if slot.listener != nil, slot.listenerPort == port, current != .off, !current.isFailed { return }
        stopListener(slot)
        startListener(slot, port: port)
    }

    private func startListener(_ slot: MCPListenerSlot, port: Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(mcpLoopbackAddress),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return fail(mcpListenFailure(slot.access, port: port, error), slot)
        }
        let generation = slot.generation
        listener.stateUpdateHandler = { [weak self, weak slot] state in
            Task { @MainActor in
                guard let self, let slot else { return }
                self.listener(slot, generation: generation, didChange: state)
            }
        }
        listener.newConnectionHandler = { [shared = slot.shared] connection in MCPConnectionSession.serve(connection, shared) }
        slot.listener = listener
        slot.listenerPort = port
        slot.shared.isListening = true
        setState(.starting, slot)
        listener.start(queue: mcpServerQueue)
    }

    private func listener(_ slot: MCPListenerSlot, generation: Int, didChange newState: NWListener.State) {
        guard generation == slot.generation, let listener = slot.listener else { return }
        switch newState {
            case .ready:
                if let bound = listener.port?.rawValue, bound != 0 { setPort(Int(bound), slot) }
                slot.reportedFailure = nil
                setState(.listening, slot)
            case .failed(let error), .waiting(let error):
                let port = slot.listenerPort ?? 0
                stopListener(slot)
                fail(mcpListenFailure(slot.access, port: port, error), slot)
            default:
                break
        }
    }

    /// Stops a listener and closes the connections it let in: a listener's cancellation alone leaves them open.
    private func stopListener(_ slot: MCPListenerSlot) {
        slot.generation += 1
        slot.listener?.cancel()
        slot.listener = nil
        slot.listenerPort = nil
        setPort(nil, slot)
        slot.shared.isListening = false
        slot.shared.closeConnections()
    }

    /// Shown in Settings, and once as a notice.
    private func fail(_ message: String, _ slot: MCPListenerSlot) {
        setState(.failed(message), slot)
        guard slot.reportedFailure != message else { return }
        slot.reportedFailure = message
        showWorkspaceSidebarNotice(WinMuxToastNotice(title: "MCP Server", body: message))
    }
}

/// One of the server's listeners, with the connections it let in.
@MainActor
private final class MCPListenerSlot {
    let access: MCPAccess
    let shared: MCPServerSharedState
    var listener: NWListener?
    var listenerPort: Int?
    /// Bumped whenever the listener stops, so its late state reports are ignored.
    var generation = 0
    var reportedFailure: String?

    init(_ access: MCPAccess) {
        self.access = access
        shared = MCPServerSharedState(access: access)
    }

    var boundHost: String? {
        guard case .hostPort(let host, _)? = listener?.parameters.requiredLocalEndpoint else { return nil }
        return "\(host)"
    }
}

extension MCPServerState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

private func mcpListenFailure(_ access: MCPAccess, port: Int, _ error: Error) -> String {
    let which = access == .tailnet ? "tailnet port" : "port"
    if case .posix(let code) = error as? NWError {
        switch code {
            case .EADDRINUSE: return "Port \(port) is already in use on 127.0.0.1. Choose another \(which) in Settings."
            case .EACCES: return "macOS didn't allow listening on 127.0.0.1:\(port)."
            default: break
        }
    }
    return "Couldn't listen on 127.0.0.1:\(port): \(error.localizedDescription)"
}

/// What one listener's connections read while they're served: which port it is, the token, the tailnet machine
/// name, and whether it listens, set on the main actor.
final class MCPServerSharedState: @unchecked Sendable {
    let access: MCPAccess
    private let lock = NSLock()
    private var _token: String?
    private var _tailnetName = ""
    private var _debugCapture = false
    private var _isListening = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(access: MCPAccess = .local) {
        self.access = access
    }

    var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    var tailnetName: String {
        get { lock.withLock { _tailnetName } }
        set { lock.withLock { _tailnetName = newValue } }
    }

    var debugCapture: Bool {
        get { lock.withLock { _debugCapture } }
        set { lock.withLock { _debugCapture = newValue } }
    }

    var isListening: Bool {
        get { lock.withLock { _isListening } }
        set { lock.withLock { _isListening = newValue } }
    }

    var connectionCount: Int { lock.withLock { connections.count } }

    /// Whether there's room for one more connection while the server listens.
    func admit(_ connection: NWConnection) -> Bool {
        lock.withLock {
            guard _isListening, connections.count < mcpMaxConnections else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
    }

    func remove(_ connection: NWConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func closeConnections() {
        let open = lock.withLock {
            let open = Array(connections.values)
            connections = [:]
            return open
        }
        for connection in open { connection.cancel() }
    }
}

/// One client connection: requests read one at a time within their limits, each answered before the next.
/// Its state is touched only on the server's queue.
private final class MCPConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let shared: MCPServerSharedState
    private let peer: String
    private var buffer = Data()
    private var deadline: DispatchWorkItem?

    private init(_ connection: NWConnection, _ shared: MCPServerSharedState, peer: String) {
        self.connection = connection
        self.shared = shared
        self.peer = peer
    }

    static func serve(_ connection: NWConnection, _ shared: MCPServerSharedState) {
        // Anyone but this Mac's loopback is closed before anything is read.
        let peer = mcpPeerAddress(connection.endpoint)
        guard mcpPeerIsAllowed(peer), shared.admit(connection) else { return connection.cancel() }
        let session = MCPConnectionSession(connection, shared, peer: peer)
        connection.stateUpdateHandler = { state in
            switch state {
                case .failed:
                    connection.cancel()
                case .cancelled:
                    shared.remove(connection)
                    mcpServerQueue.async { session.deadline?.cancel() }
                    connection.stateUpdateHandler = nil
                default: break
            }
        }
        connection.start(queue: mcpServerQueue)
        session.waitForRequest()
    }

    private func waitForRequest() {
        let deadline = DispatchWorkItem { [connection] in connection.cancel() }
        self.deadline = deadline
        mcpServerQueue.asyncAfter(deadline: .now() + mcpRequestReadTimeout, execute: deadline)
        process()
    }

    /// Answers a request already read, or reads more of it.
    private func process() {
        switch parseMCPHTTPRequest(buffer) {
            case .incomplete:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    if error != nil || (isComplete && data?.isEmpty != false) { return connection.cancel() }
                    process()
                }
            case .invalid(let status, let message):
                deadline?.cancel()
                send(.refusal(status, message), keepAlive: false)
            case .complete(let request, let consumed):
                deadline?.cancel()
                buffer.removeFirst(consumed)
                // The token as it is now, not as it was when the connection was accepted; where it came from is the
                // listener's alone.
                let context = MCPRequestContext(peer: peer, token: shared.token, access: shared.access, tailnetName: shared.tailnetName,
                                                debugCapture: shared.debugCapture)
                Task {
                    let response = await handleMCPHTTPRequest(request, context)
                    send(response, keepAlive: request.keepsAlive)
                }
        }
    }

    private func send(_ response: MCPHTTPResponse, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive), completion: .contentProcessed { [self] error in
            guard error == nil, keepAlive else { return connection.cancel() }
            mcpServerQueue.async { self.waitForRequest() }
        })
    }
}

/// A connection's peer address, in numeric form; empty when it isn't an IP address.
func mcpPeerAddress(_ endpoint: NWEndpoint) -> String {
    guard case .hostPort(let host, _) = endpoint else { return "" }
    switch host {
        case .ipv4(let address): return MCPIPAddress(bytes: Array(address.rawValue))?.text ?? ""
        case .ipv6(let address): return MCPIPAddress(bytes: Array(address.rawValue))?.text ?? ""
        default: return ""
    }
}
