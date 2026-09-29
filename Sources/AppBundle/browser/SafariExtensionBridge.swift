import AppKit
import Common
import SafariServices
import Security

let safariBundleId = "com.apple.Safari"

/// Where the WinMux Tabs extension reaches this app. Only an Xcode-built, team-signed WinMux
/// that embeds the extension has one; development builds run without it.
struct SafariExtensionConfiguration: Sendable {
    let extensionId: String
    let socketPath: String
    /// A running process must meet this to be heard: the embedded extension, signed by WinMux's team.
    let peerRequirement: String

    static func load(bundle: Bundle = .main) -> SafariExtensionConfiguration? {
        guard let group = bundle.object(forInfoDictionaryKey: "WinMuxAppGroup") as? String,
              let plugins = bundle.builtInPlugInsURL,
              let extensionId = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil))?
                  .lazy.compactMap(Bundle.init(url:)).first(where: { plugin in
                      (plugin.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String
                          == "com.apple.Safari.web-extension"
                  })?.bundleIdentifier,
              let team = signingTeam(), group.hasPrefix(team + "."),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let socketPath = container.appendingPathComponent("tabs.sock").path
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return nil }
        return .init(extensionId: extensionId, socketPath: socketPath, peerRequirement:
            "anchor apple generic and identifier \"\(extensionId)\" and certificate leaf[subject.OU] = \"\(team)\"")
    }

    private static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// What Settings says about the extension.
enum SafariExtensionConnection: Equatable {
    case unavailable
    case off
    case waiting
    case connected(allSites: Bool)
}

/// Website icons the extension sent, by the SHA-256 of their PNG. Tab rows observe only these,
/// so a report that changes no icon doesn't redraw them.
@MainActor
final class SafariExtensionIcons: ObservableObject {
    static let shared = SafariExtensionIcons()
    @Published var images: [String: NSImage] = [:]
}

/// Receives what the WinMux Tabs extension reports from each Safari profile: its windows' tabs,
/// with their host names, sound, and website icons. The icons stay in memory, and everything
/// is dropped when browser tabs are turned off or Safari quits.
@MainActor
final class SafariExtensionBridge {
    static let shared = SafariExtensionBridge(configuration: isUnitTest ? { nil } : { .load() })
    let icons: SafariExtensionIcons
    private(set) var lastContact: TimeInterval? = nil
    /// Counts changes to the reported windows, so pairing runs again only after one.
    private(set) var generation = 0
    private let loadConfiguration: () -> SafariExtensionConfiguration?
    private var loadedConfiguration: SafariExtensionConfiguration??
    private var states: [String: (state: SafariExtensionState, received: TimeInterval)] = [:]
    private var failedIcons: [String: TimeInterval] = [:]
    private var enabled = false
    private var server: SafariExtensionServer?
    private var lastResync: TimeInterval = -.infinity
    private let now: () -> TimeInterval
    /// A profile that hasn't reported for this long (the extension checks in each minute) is gone.
    static let stateLifetime: TimeInterval = 150
    /// More than the extension keeps, so every icon it reports fits.
    static let maximumImages = 512

    init(configuration: @escaping () -> SafariExtensionConfiguration?, icons: SafariExtensionIcons = .shared,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.loadConfiguration = configuration
        self.icons = icons
        self.now = now
    }

    /// Looked up when first needed, so a WinMux that never shows browser tabs never touches the
    /// app group's folder.
    var configuration: SafariExtensionConfiguration? {
        if let loadedConfiguration { return loadedConfiguration }
        let configuration = loadConfiguration()
        loadedConfiguration = .some(configuration)
        return configuration
    }

    var isAvailable: Bool { configuration != nil }

    /// Whether every Safari profile reporting lets the extension read every website.
    var allSites: Bool {
        let time = now()
        let live = states.values.filter { time - $0.received < Self.stateLifetime }
        return !live.isEmpty && live.allSatisfy(\.state.allSites)
    }

    var windows: [SafariExtensionWindow] {
        let time = now()
        return states.values.filter { time - $0.received < Self.stateLifetime }
            .sorted { $0.state.profile < $1.state.profile }.flatMap(\.state.windows)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        guard enabled else {
            // The extension finds nothing to connect to and waits for its next check-in.
            server?.stop()
            server = nil
            clear()
            return
        }
        if let configuration {
            server = SafariExtensionServer(configuration: configuration) { [weak self] message in
                await self?.receive(message) ?? Data()
            }
        }
        requestResync()
    }

    /// Drops profiles that stopped reporting, and everything once Safari quits.
    func retain(safariIsRunning: Bool) {
        guard safariIsRunning else {
            if !states.isEmpty || !icons.images.isEmpty { clear() }
            return
        }
        let time = now()
        let live = states.filter { time - $0.value.received < Self.stateLifetime }
        if live.count != states.count {
            states = live
            generation += 1
        }
    }

    func clear() {
        states = [:]
        failedIcons = [:]
        if !icons.images.isEmpty { icons.images = [:] }
        lastContact = nil
        generation += 1
    }

    private var referencedIcons: Set<String> {
        Set(states.values.flatMap { $0.state.windows.flatMap { $0.tabs.compactMap(\.icon) } })
    }

    /// Answers one message. A state asks for the icons WinMux doesn't have yet, as many as fit.
    func receive(_ message: SafariExtensionMessage?) -> Data {
        func answer(_ value: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: value.merging(["v": SafariExtensionMessage.protocolVersion]) { first, _ in first })) ?? Data()
        }
        guard enabled else { return answer(["ok": false, "reason": "off"]) }
        guard let message else { return answer(["ok": false, "reason": "invalid"]) }
        let time = now()
        switch message {
            case .state(let state):
                if let previous = states[state.profile]?.state, previous.session == state.session, previous.time > state.time {
                    return answer(["ok": true])
                }
                states[state.profile] = (state, time)
                generation += 1
                lastContact = time
                let referenced = referencedIcons
                let room = Self.maximumImages - icons.images.keys.filter(referenced.contains).count
                let wanted = Set(state.windows.flatMap { $0.tabs.compactMap(\.icon) }).filter { key in
                    icons.images[key] == nil && time - (failedIcons[key] ?? -.infinity) > 300
                }.sorted()
                // Up to twice what one message carries, so the extension sees that more remain.
                return answer(["ok": true, "want": Array(wanted.prefix(max(0, min(2 * SafariExtensionMessage.maximumIcons, room))))])
            case .icons(let profile, let session, let received):
                guard states[profile]?.state.session == session else { return answer(["ok": true]) }
                let referenced = referencedIcons
                var next = icons.images
                for (key, data) in received.sorted(by: { $0.key < $1.key }) where referenced.contains(key) && next[key] == nil {
                    // Make room from icons no tab shows; never drop one a tab shows.
                    if next.count >= Self.maximumImages, let unused = next.keys.first(where: { !referenced.contains($0) }) {
                        next[unused] = nil
                    }
                    guard next.count < Self.maximumImages else { break }
                    if let image = NSImage(data: data) { next[key] = image } else { failedIcons[key] = time }
                }
                if failedIcons.count > 256 { failedIcons.removeAll() }
                if next != icons.images { icons.images = next }
                return answer(["ok": true])
        }
    }

    /// Asks the extension to report now rather than at its next once-a-minute check-in. Best
    /// effort: Safari may have unloaded the extension's page. Never while Safari isn't running,
    /// so starting WinMux can't open Safari.
    func requestResync(atMostEvery interval: TimeInterval = 0) {
        let time = now()
        guard enabled, time - lastResync >= interval, let configuration,
              !NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleId).isEmpty else { return }
        lastResync = time
        dispatchSafariExtensionResync(configuration.extensionId)
    }

    /// Settings' view of the connection; Safari answers whether the extension is turned on.
    func connection() async -> SafariExtensionConnection {
        guard let configuration else { return .unavailable }
        guard await safariExtensionIsOn(configuration.extensionId) else { return .off }
        if let lastContact, now() - lastContact < Self.stateLifetime { return .connected(allSites: allSites) }
        return .waiting
    }

    func showInSafari() {
        guard let configuration else { return }
        showSafariExtensionPreferences(configuration.extensionId)
    }
}

// SafariServices answers on its own queue, so its callbacks must not belong to the main actor: a
// closure written in a main-actor method would trap there. These wrappers are nonisolated.
private func dispatchSafariExtensionResync(_ extensionId: String) {
    SFSafariApplication.dispatchMessage(withName: "resync", toExtensionWithIdentifier: extensionId, userInfo: nil) { _ in }
}

private func showSafariExtensionPreferences(_ extensionId: String) {
    SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionId) { _ in }
}

/// The SDK marks this call's callback as the main actor's, yet Safari calls it on its own queue,
/// where any closure passed in traps. The async form resumes without running one.
func safariExtensionIsOn(_ extensionId: String) async -> Bool {
    (try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: extensionId))?.isEnabled ?? false
}

/// One request and one answer per connection, each a 4-byte big-endian length and JSON, within
/// two seconds each. A peer must be the embedded extension, signed by WinMux's team, before
/// anything it sends is read. Each connection has its own exchange off the main thread, where
/// its message is read, parsed and its icons checked, so one slow peer never holds up another.
final class SafariExtensionServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WinMux Safari extension", qos: .utility)
    private let exchanges = DispatchQueue(label: "WinMux Safari extension exchanges", qos: .utility, attributes: .concurrent)
    private let path: String
    private let requirement: SecRequirement
    private let handle: @Sendable (SafariExtensionMessage?) async -> Data
    private let listener: Int32
    private let source: DispatchSourceRead
    /// The socket file this server made. A later server may have replaced it at the same path.
    private let socketFile: ino_t

    init?(configuration: SafariExtensionConfiguration, handle: @escaping @Sendable (SafariExtensionMessage?) async -> Data) {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(configuration.peerRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        unlink(configuration.socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(configuration.socketPath.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(configuration.socketPath, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var file = stat()
        guard stat(configuration.socketPath, &file) == 0 else {
            close(descriptor)
            return nil
        }
        socketFile = file.st_ino
        self.path = configuration.socketPath
        self.requirement = requirement
        self.handle = handle
        self.listener = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        // Closed only once the source is cancelled, so no accept can reach a reused descriptor.
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
    }

    deinit { stop() }

    /// Stops listening and removes the socket, unless another server has since taken its path.
    /// Exchanges already under way still answer.
    func stop() {
        guard !source.isCancelled else { return }
        source.cancel()
        var file = stat()
        if stat(path, &file) == 0, file.st_ino == socketFile { unlink(path) }
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            exchanges.async { [self] in exchange(client) }
        }
    }

    private func exchange(_ client: Int32) {
        guard peerMeetsRequirement(client),
              let request = readSafariExtensionFrame(client, until: ProcessInfo.processInfo.systemUptime + 2)
        else {
            close(client)
            return
        }
        let message = SafariExtensionMessage.decode(request)
        let handle = handle
        let exchanges = exchanges
        _ = Task {
            let answer = await handle(message)
            exchanges.async {
                _ = writeSafariExtensionFrame(client, answer, until: ProcessInfo.processInfo.systemUptime + 2)
                close(client)
            }
        }
    }

    private func peerMeetsRequirement(_ descriptor: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// A 4-byte big-endian length, then that many bytes, all before `deadline`.
func readSafariExtensionFrame(_ descriptor: Int32, until deadline: TimeInterval) -> Data? {
    guard let header = safariExtensionTransfer(descriptor, count: 4, until: deadline, reading: true, from: nil) else { return nil }
    let count = header.reduce(0) { $0 << 8 | Int($1) }
    guard count <= SafariExtensionMessage.maximumBytes else { return nil }
    return safariExtensionTransfer(descriptor, count: count, until: deadline, reading: true, from: nil)
}

func writeSafariExtensionFrame(_ descriptor: Int32, _ data: Data, until deadline: TimeInterval) -> Bool {
    var length = UInt32(data.count).bigEndian
    let frame = Data(bytes: &length, count: 4) + data
    return safariExtensionTransfer(descriptor, count: frame.count, until: deadline, reading: false, from: frame) != nil
}

/// Reads or writes exactly `count` bytes, waiting with poll so the whole transfer has one deadline
/// however the peer trickles it. The descriptor doesn't block, so no single write outlasts it.
private func safariExtensionTransfer(_ descriptor: Int32, count: Int, until deadline: TimeInterval, reading: Bool,
                                     from source: Data?) -> Data? {
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    var data = source ?? Data(count: count)
    let complete = data.withUnsafeMutableBytes { buffer -> Bool in
        var offset = 0
        while offset < count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(reading ? POLLIN : POLLOUT), revents: 0)
            let ready = poll(&descriptorPoll, 1, Int32(min(remaining, 10) * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return false }
            let moved = reading ? read(descriptor, buffer.baseAddress! + offset, count - offset)
                : write(descriptor, buffer.baseAddress! + offset, count - offset)
            if moved < 0, errno == EINTR || errno == EAGAIN { continue }
            guard moved > 0 else { return false }
            offset += moved
        }
        return true
    }
    return complete ? data : nil
}
