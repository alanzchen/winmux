import Common
import Foundation
import Network

enum MCPServerState: Equatable, Sendable {
    case off
    case starting
    case listening
    case failed(String)
}

/// At most this many connections at once; more are closed at once.
let mcpMaxConnections = 16
/// A request must arrive whole within this long of the connection waiting for it.
let mcpRequestReadTimeout: TimeInterval = 60

private let mcpServerQueue = DispatchQueue(label: "WinMux.MCPServer")

/// WinMux's MCP server: one listener, on 127.0.0.1 and nowhere else, while the config turns it on.
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer(waitsForAppStart: true)

    @Published private(set) var state: MCPServerState = .off
    /// The port it listens on, once listening.
    @Published private(set) var port: Int?
    /// Whether a token is saved, for Settings.
    @Published private(set) var hasToken = false

    private var config = MCPServerConfig()
    private var listener: NWListener?
    private var listenerPort: Int?
    /// Bumped whenever the listener stops, so its late state reports are ignored.
    private var generation = 0
    private var reportedFailure: String?
    private let shared = MCPServerSharedState()
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
    var listeningAddresses: [String] { listener == nil ? [] : [mcpLoopbackAddress] }

    /// The host its listener is bound to, if there's one.
    var listenerHost: String? {
        guard case .hostPort(let host, _)? = listener?.parameters.requiredLocalEndpoint else { return nil }
        return "\(host)"
    }

    /// Starts or stops the listener as `config` asks. A listener already on the right port stays, with its
    /// connections; another port gets a new one, and the old one's connections are closed.
    func apply(_ config: MCPServerConfig) {
        self.config = config
        guard !waitsForAppStart else { return }
        hasToken = readMCPServerToken() != nil
        guard config.enabled else {
            stopListener()
            reportedFailure = nil
            state = .off
            return
        }
        if config.requireToken {
            var token = readMCPServerToken()
            if token == nil, !serverArgs.isReadOnly { token = try? generateMCPServerToken() }
            guard let token else {
                // Never serve without the token it requires.
                stopListener()
                return fail("WinMux couldn't make the MCP server's access token, so the server isn't running.")
            }
            shared.token = token
            hasToken = true
        } else {
            shared.token = nil
        }
        if listener != nil, listenerPort == config.port, state != .off, !state.isFailed { return }
        stopListener()
        startListener(port: config.port)
    }

    func stop() {
        apply(MCPServerConfig(enabled: false, port: config.port))
    }

    /// A new token was saved: requests from now on need it.
    func tokenDidChange() {
        let token = readMCPServerToken()
        hasToken = token != nil
        if config.enabled, config.requireToken, let token { shared.token = token }
    }

    private func startListener(port: Int) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(mcpLoopbackAddress),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return fail(mcpListenFailure(port: port, error))
        }
        let generation = generation
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listener(generation: generation, didChange: state) }
        }
        listener.newConnectionHandler = { [shared] connection in MCPConnectionSession.serve(connection, shared) }
        self.listener = listener
        listenerPort = port
        shared.isListening = true
        state = .starting
        listener.start(queue: mcpServerQueue)
    }

    private func listener(generation: Int, didChange newState: NWListener.State) {
        guard generation == self.generation, let listener else { return }
        switch newState {
            case .ready:
                if let bound = listener.port?.rawValue, bound != 0 { port = Int(bound) }
                reportedFailure = nil
                state = .listening
            case .failed(let error), .waiting(let error):
                let port = config.port
                stopListener()
                fail(mcpListenFailure(port: port, error))
            default:
                break
        }
    }

    /// Stops the listener and closes the connections it let in: a listener's cancellation alone leaves them open.
    private func stopListener() {
        generation += 1
        listener?.cancel()
        listener = nil
        listenerPort = nil
        port = nil
        shared.isListening = false
        shared.closeConnections()
    }

    /// Shown in Settings, and once as a notice.
    private func fail(_ message: String) {
        state = .failed(message)
        guard reportedFailure != message else { return }
        reportedFailure = message
        showWorkspaceSidebarNotice(WinMuxToastNotice(title: "MCP Server", body: message))
    }
}

extension MCPServerState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

private func mcpListenFailure(port: Int, _ error: Error) -> String {
    if case .posix(let code) = error as? NWError {
        switch code {
            case .EADDRINUSE: return "Port \(port) is already in use on 127.0.0.1. Choose another port in Settings."
            case .EACCES: return "macOS didn't allow listening on 127.0.0.1:\(port)."
            default: break
        }
    }
    return "Couldn't listen on 127.0.0.1:\(port): \(error.localizedDescription)"
}

/// What connections read while they're served: the token, and whether the server listens, set on the main actor.
final class MCPServerSharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _token: String?
    private var _isListening = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
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
                // The token as it is now, not as it was when the connection was accepted.
                let context = MCPRequestContext(peer: peer, token: shared.token)
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
