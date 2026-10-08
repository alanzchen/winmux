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
    /// How Safari's Accessibility names the extension's toolbar button, in every window.
    var toolbarIdentifier: String { "WebExtension-\(extensionId) (\(team))" }
    let team: String

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
            "anchor apple generic and identifier \"\(extensionId)\" and certificate leaf[subject.OU] = \"\(team)\"", team: team)
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
    static let shared = SafariExtensionBridge(configuration: isUnitTest ? { nil } : { .load() },
        iconCache: isUnitTest ? nil : .standard)
    let browser: String
    let icons: SafariExtensionIcons
    private(set) var lastContact: TimeInterval? = nil
    /// Counts changes to the reported windows, so pairing runs again only after one.
    private(set) var generation = 0
    private let loadConfiguration: () -> SafariExtensionConfiguration?
    private var loadedConfiguration: SafariExtensionConfiguration??
    private var states: [String: (state: SafariExtensionState, received: TimeInterval, measured: TimeInterval, sighting: [UInt32: CGRect])] = [:]
    private var streams: [String: BrowserPushSequence] = [:]
    private var challenges: [String: (request: String, since: TimeInterval)] = [:]
    private var ready: [String: TimeInterval] = [:]
    var pushSenders: [String: (Data) -> Void] = [:]
    private struct Command {
        var confirmation: BrowserPushConfirmation
        let continuation: CheckedContinuation<BrowserTabActionResult, Never>
        let timeout: Task<Void, Never>
    }
    private var commands: [String: Command] = [:]
    private var failedIcons: [String: TimeInterval] = [:]
    /// Icon images kept across launches (`BrowserTabIconDiskCache`), read and written off the
    /// main thread. None for Chrome, whose connections have no lasting profile.
    private let iconCache: BrowserTabIconDiskCache?
    private let iconQueue = DispatchQueue(label: "WinMux website icons", qos: .utility)
    /// The PNG behind each image in `icons`, to write down; dropped with the image.
    private var thumbnails: [String: Data] = [:]
    /// Icons, by `partition \n key`, recently looked up on the disk, and recently written there.
    /// Bounded, so browsing many sites doesn't grow them.
    private var askedDisk = BrowserTabRecency<String, Bool>(capacity: 1024, lifetime: 60 * 60)
    private var written = BrowserTabRecency<String, Bool>(capacity: 1024, lifetime: 60 * 60)
    private var lastPrune: TimeInterval = -.infinity
    /// Every live report's tabs by key, rebuilt when the reports change.
    private var tabIndex: (generation: Int, tabs: [SafariExtensionTabKey: (tab: SafariExtensionTab, received: TimeInterval)])?
    /// Once icons read from the disk can show.
    var iconsLoaded: () -> Void = {}
    private var enabled = false
    private var server: SafariExtensionServer?
    private var lastResync: TimeInterval = -.infinity
    private let now: () -> TimeInterval
    private let clock: () -> TimeInterval
    /// Where Safari's windows have been, unmoved, since before a moment (by system uptime),
    /// recorded as each report arrives. Bounds in a report are compared only with that record.
    var sightSafariWindows: (_ measured: TimeInterval) -> [UInt32: CGRect] = { _ in [:] }
    /// Takes in a report as it arrives, and says whether pairing still waits on Safari reporting
    /// again. The answer then asks the extension to (`again`, in seconds): Safari 27 doesn't wake
    /// the extension for `requestResync`, but it always reads the answer. The first wait is
    /// `firstAgain`, so windows WinMux just moved settle first; each answer while the wait lasts
    /// doubles it, up to `maximumAgain`, so a wait that never ends costs a report a minute at most.
    var reportArrived: () -> Bool = { false }
    private var againDelay = SafariExtensionBridge.firstAgain
    static let firstAgain = 2
    static let maximumAgain = 60
    /// A report that took longer than this to arrive says too little about where windows are now.
    static let maximumTransit: TimeInterval = 5
    /// A profile that hasn't reported for this long (the extension checks in each minute) is gone.
    static let stateLifetime: TimeInterval = 150
    /// More than the extension keeps, so every icon it reports fits.
    static let maximumImages = 512

    /// `clock` is the wall clock the extension stamps its reports with, in seconds.
    init(browser: String = "safari", configuration: @escaping () -> SafariExtensionConfiguration?, icons: SafariExtensionIcons = .shared,
         iconCache: BrowserTabIconDiskCache? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.browser = browser
        self.loadConfiguration = configuration
        self.icons = icons
        self.iconCache = browser == "safari" ? iconCache : nil
        self.now = now
        self.clock = clock
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

    /// Every live report's windows, each with when its report arrived and where Safari's windows were then.
    var windows: [SafariExtensionWindow] {
        let time = now()
        return states.values.filter { time - $0.received < Self.stateLifetime }
            .sorted { $0.state.profile < $1.state.profile }.flatMap { report in
                report.state.windows.filter { window in
                    time - (report.state.push == nil ? report.received : window.received) < Self.stateLifetime
                }.map { window in
                    var window = window
                    if report.state.push != nil { return window }
                    window.received = report.received
                    window.measured = report.measured
                    window.order = report.state.order
                    window.sighting = report.sighting
                    return window
                }
            }
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
        if let iconCache { iconQueue.async { iconCache.prepare() } }
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
        var live = states.filter { time - $0.value.received < Self.stateLifetime }
        var removed = live.count != states.count
        for (profile, var report) in live where report.state.push != nil {
            let count = report.state.windows.count
            report.state.windows.removeAll { time - $0.received >= Self.stateLifetime }
            if count != report.state.windows.count { live[profile] = report; removed = true }
        }
        if removed {
            states = live
            pruneSiteIndexes()
            streams = streams.filter { live[$0.key] != nil }
            ready = ready.filter { live[$0.key] != nil }
            challenges = challenges.filter { live[$0.key] != nil }
            generation += 1
        }
    }

    func disconnect(_ profile: String) {
        states[profile] = nil
        pruneSiteIndexes()
        streams[profile] = nil
        ready[profile] = nil
        challenges[profile] = nil
        pushSenders[profile] = nil
        for (id, command) in commands where command.confirmation.target.profile == profile {
            finishCommand(id, .dispatched(.unknown))
        }
        generation += 1
    }

    func clear() {
        for id in Array(commands.keys) { finishCommand(id, .dispatched(.unknown)) }
        streams = [:]
        challenges = [:]
        ready = [:]
        pushSenders = [:]
        states = [:]
        failedIcons = [:]
        thumbnails = [:]
        askedDisk.removeAll()
        written.removeAll()
        if !icons.images.isEmpty { icons.images = [:] }
        lastContact = nil
        generation += 1
    }

    /// Icons tabs show: those the live reports name.
    private var referencedIcons: Set<String> {
        Set(states.values.flatMap { $0.state.windows.flatMap { $0.tabs.compactMap(\.icon) } })
    }

    /// The live report's tab for `key`, if a live report still has it: none once its window's
    /// report is older than a report lasts, whether or not anything has pruned it yet.
    func reportedTab(_ key: SafariExtensionTabKey) -> SafariExtensionTab? {
        if tabIndex?.generation != generation {
            var tabs: [SafariExtensionTabKey: (tab: SafariExtensionTab, received: TimeInterval)] = [:]
            for window in windows { for tab in window.tabs { if let key = window.tabKey(tab) { tabs[key] = (tab, window.received) } } }
            tabIndex = (generation, tabs)
        }
        guard let found = tabIndex?.tabs[key], now() - found.received < Self.stateLifetime else { return nil }
        return found.tab
    }

    /// How many entries each index holds: for tests.
    var iconIndexCounts: (asked: Int, written: Int, thumbnails: Int) { (askedDisk.count, written.count, thumbnails.count) }

    /// Waits for icon reads and writes under way: for tests.
    func waitForKeptIcons() { iconQueue.sync {} }

    /// Forgets every icon kept on the disk, as when browser tabs are turned off.
    func removeKeptIcons() {
        guard let iconCache else { return }
        askedDisk.removeAll()
        written.removeAll()
        iconQueue.async { iconCache.remove() }
    }

    /// Keeps the indexes to what the images still need.
    private func pruneSiteIndexes() {
        let images = icons.images
        thumbnails = thumbnails.filter { images[$0.key] != nil }
    }

    /// Starts reading from the disk the icons a report names that WinMux kept before but doesn't
    /// have now, and returns them: the extension needn't send those again.
    private func findKeptIcons(_ state: SafariExtensionState) -> Set<String> {
        pruneSiteIndexes()
        guard let iconCache, let partition = BrowserTabIconDiskCache.partition(browser: browser, profile: state.profile) else { return [] }
        let time = now()
        if time - lastPrune >= 60 * 60 {
            lastPrune = time
            iconQueue.async { iconCache.prune() }
        }
        let wanted = Set(state.windows.flatMap { $0.tabs.compactMap(\.icon) }).filter { icons.images[$0] == nil }
        let kept = wanted.filter { key in
            askedDisk.peek(partition + "\n" + key, now: time) == nil && iconCache.knows(partition: partition, icon: key)
        }
        guard !kept.isEmpty else { return [] }
        for key in kept { askedDisk.set(partition + "\n" + key, true, now: time) }
        iconQueue.async { [weak self] in
            let found = kept.sorted().compactMap { key in iconCache.icon(partition: partition, icon: key).map { (key, $0) } }
            Task { @MainActor [weak self] in self?.receiveKeptIcons(found) }
        }
        return kept
    }

    private func keep(partition: String, icon: String) {
        let time = now()
        let entry = "\(partition)\n\(icon)"
        guard let iconCache, let png = thumbnails[icon], written.peek(entry, now: time) == nil else { return }
        written.set(entry, true, now: time)
        iconQueue.async { iconCache.store(partition: partition, icon: icon, png: png) }
    }

    private func receiveKeptIcons(_ found: [(key: String, png: Data)]) {
        guard enabled, !states.isEmpty else { return }
        let referenced = referencedIcons
        var next = icons.images
        for (key, png) in found where next[key] == nil && referenced.contains(key) {
            if next.count >= Self.maximumImages, let unused = next.keys.first(where: { !referenced.contains($0) }) { next[unused] = nil }
            guard next.count < Self.maximumImages, let image = NSImage(data: png) else { continue }
            next[key] = image
            thumbnails[key] = png
        }
        if next != icons.images { icons.images = next }
        pruneSiteIndexes()
        // One the disk couldn't give is asked of the extension when a report next names it.
        iconsLoaded()
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
            case .control(let control):
                guard control.browser == browser, let stream = streams[control.profile], stream.valid,
                      stream.session == control.session, stream.epoch == control.epoch else { return answer(["ok": false]) }
                if control.kind == "ready", challenges[control.profile]?.request == control.request {
                    ready[control.profile] = time
                    challenges[control.profile] = nil
                } else if var command = commands[control.request] {
                    command.confirmation.receive(control)
                    commands[control.request] = command
                    if let outcome = command.confirmation.outcome { finishCommand(control.request, outcome) }
                }
                return answer(["ok": true])
            case .state(var state):
                if state.push == nil, let previous = states[state.profile]?.state,
                   previous.session == state.session, previous.time > state.time { return answer(["ok": true]) }
                if let push = state.push {
                    guard push.browser == browser else { return answer(["ok": false]) }
                    var stream = streams[state.profile] ?? BrowserPushSequence()
                    let restarted = stream.session != state.session || stream.epoch != push.epoch
                    let acceptance = stream.receive(session: state.session, envelope: push)
                    streams[state.profile] = stream
                    switch acceptance {
                        case .snapshotRequired:
                            states[state.profile] = nil
                            ready[state.profile] = nil
                            challenges[state.profile] = nil
                            generation += 1
                            _ = reportArrived()
                            return answer(["ok": false, "events": 1, "snapshot": true])
                        case .duplicate: return answer(["ok": true, "events": 1])
                        case .accept: break
                    }
                    if restarted { ready[state.profile] = nil; challenges[state.profile] = nil }
                    if !push.snapshot {
                        guard let previous = states[state.profile]?.state, previous.session == state.session else {
                            streams[state.profile] = nil
                            return answer(["ok": false, "events": 1, "snapshot": true])
                        }
                        let changed = Set(state.windows.map { $0.key.id }).union(push.removed)
                        let kept = previous.windows.filter { !changed.contains($0.key.id) && time - $0.received < Self.stateLifetime }
                        state = SafariExtensionState(profile: state.profile, session: state.session, time: state.time,
                            measured: state.measured, order: state.order, allSites: state.allSites,
                            windows: kept + state.windows, push: push)
                    }
                    let ids = state.windows.flatMap { $0.tabs.compactMap(\.id) }
                    guard state.windows.count <= SafariExtensionMessage.maximumWindows, Set(ids).count == ids.count else {
                        streams[state.profile] = nil
                        states[state.profile] = nil
                        ready[state.profile] = nil
                        generation += 1
                        _ = reportArrived()
                        return answer(["ok": false, "events": 1, "snapshot": true])
                    }
                } else {
                    streams[state.profile] = nil
                    ready[state.profile] = nil
                }
                // The extension notes when it began measuring windows, before asking Safari for them.
                // A report without that (an older extension's), one that took too long, or one
                // from a clock that moved, says nothing about where windows were.
                let transit = state.measured.map { clock() - $0 / 1000 }
                let measured = transit.flatMap { (-1...Self.maximumTransit).contains($0) ? time - max(0, $0) : nil }
                let sighting = measured.map(sightSafariWindows) ?? [:]
                if let push = state.push {
                    // Kept windows already carry their original evidence. Never give a delta's
                    // fresh bounds/timestamp to an unchanged window from an earlier report.
                    let windows = state.windows.map { value -> SafariExtensionWindow in
                        guard push.snapshot || value.received == -.infinity else { return value }
                        var value = value
                        value.supportsPush = true
                        value.received = time
                        value.measured = measured ?? -.infinity
                        value.sighting = sighting
                        value.order = state.order
                        return value
                    }
                    state = SafariExtensionState(profile: state.profile, session: state.session, time: state.time,
                        measured: state.measured, order: state.order, allSites: state.allSites, windows: windows, push: push)
                }
                states[state.profile] = (state, time, measured ?? -.infinity, sighting)
                generation += 1
                lastContact = time
                let kept = findKeptIcons(state)
                let referenced = referencedIcons
                let room = Self.maximumImages - icons.images.keys.filter(referenced.contains).count
                let wanted = Set(state.windows.flatMap { $0.tabs.compactMap(\.icon) }).filter { key in
                    icons.images[key] == nil && !kept.contains(key) && time - (failedIcons[key] ?? -.infinity) > 300
                }.sorted()
                var reply: [String: Any] = ["ok": true, "events": 1, "want": Array(wanted.prefix(max(0, min(2 * SafariExtensionMessage.maximumIcons, room))))]
                if reportArrived() {
                    reply["again"] = againDelay
                    againDelay = min(Self.maximumAgain, againDelay * 2)
                } else {
                    againDelay = Self.firstAgain
                }
                // Up to twice what one message carries, so the extension sees that more remain.
                if let push = state.push, ready[state.profile].map({ time - $0 < 90 }) != true,
                   challenges[state.profile].map({ time - $0.since >= 60 }) ?? true {
                    let request = UUID().uuidString
                    challenges[state.profile] = (request, time)
                    sendPush(["protocol": 1, "kind": "probe", "request": request, "browser": browser,
                              "profile": state.profile, "session": state.session, "epoch": push.epoch], profile: state.profile)
                }
                return answer(reply)
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
                    if let image = NSImage(data: data) {
                        next[key] = image
                        thumbnails[key] = data
                    } else { failedIcons[key] = time }
                }
                if failedIcons.count > 256 { failedIcons.removeAll() }
                if next != icons.images { icons.images = next }
                pruneSiteIndexes()
                // Now that their images are here, keep those this profile's tabs show.
                if let state = states[profile]?.state, let partition = BrowserTabIconDiskCache.partition(browser: browser, profile: profile) {
                    for icon in Set(state.windows.flatMap { $0.tabs.compactMap(\.icon) }) where received[icon] != nil && next[icon] != nil {
                        keep(partition: partition, icon: icon)
                    }
                }
                return answer(["ok": true])
        }
    }

    /// Available only after a round trip through the app-to-extension transport, for this stream.
    func pushTarget(window: SafariExtensionWindowKey, tab: SafariExtensionTabKey) -> BrowserPushTarget? {
        guard window.source == tab.source,
              let report = states.values.first(where: { $0.state.windows.contains { $0.key == window } }),
              let stream = streams[report.state.profile], stream.valid,
              let readyAt = ready[report.state.profile], now() - readyAt < 90,
              let described = report.state.windows.first(where: { $0.key == window }), now() - described.received < 90,
              described.tabs.contains(where: { $0.id == tab.id })
        else { return nil }
        return .init(browser: browser, profile: report.state.profile, session: stream.session, epoch: stream.epoch,
                     window: window.id, tab: tab.id, sequence: stream.sequence)
    }

    func select(_ target: BrowserPushTarget) async -> BrowserTabActionResult {
        guard !Task.isCancelled, target.browser == browser, streams[target.profile]?.session == target.session,
              streams[target.profile]?.sequence == target.sequence, streams[target.profile]?.epoch == target.epoch,
              streams[target.profile]?.valid == true, ready[target.profile].map({ now() - $0 < 90 }) == true,
              let window = states[target.profile]?.state.windows.first(where: { $0.key.id == target.window }),
              now() - window.received < 90, window.tabs.contains(where: { $0.id == target.tab }) else {
            return .notDispatched(.changed)
        }
        let request = UUID().uuidString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self?.finishCommand(request, .dispatched(.unknown))
                }
                commands[request] = Command(confirmation: .init(request: request, target: target),
                    continuation: continuation, timeout: timeout)
                sendPush(["protocol": 1, "kind": "select", "request": request, "browser": browser,
                          "profile": target.profile, "session": target.session, "epoch": target.epoch,
                          "window": target.window, "tab": target.tab, "seq": target.sequence,
                          "expires": Date().timeIntervalSince1970 * 1000 + 1500], profile: target.profile)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.commands[request] != nil else { return }
                self.sendPush(["protocol": 1, "kind": "cancel", "request": request, "browser": self.browser,
                    "profile": target.profile, "session": target.session, "epoch": target.epoch], profile: target.profile)
                self.finishCommand(request, .dispatched(.unknown))
            }
        }
    }

    private func finishCommand(_ request: String, _ result: BrowserTabActionResult) {
        guard let command = commands.removeValue(forKey: request) else { return }
        command.timeout.cancel()
        command.continuation.resume(returning: result)
    }

    private func sendPush(_ message: [String: Any], profile: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        if let send = pushSenders[profile] { send(data) }
        else if browser == "safari", let configuration { dispatchSafariPush(configuration.extensionId, data) }
    }

    /// Asks the extension to report now rather than at its next once-a-minute check-in. Best
    /// effort: Safari may have unloaded the extension's page, and in testing Safari 27.0 never
    /// delivered it to an idle one; an answer's `again` reaches it. Never while Safari isn't
    /// running, so starting WinMux can't open Safari.
    func requestResync(atMostEvery interval: TimeInterval = 0) {
        let time = now()
        guard enabled, time - lastResync >= interval else { return }
        if browser == "chrome" {
            let connected = streams.filter { $0.value.valid && pushSenders[$0.key] != nil }
            guard !connected.isEmpty else { return }
            lastResync = time
            for (profile, stream) in connected {
                sendPush(["protocol": 1, "kind": "snapshot", "request": UUID().uuidString, "browser": browser,
                    "profile": profile, "session": stream.session, "epoch": stream.epoch], profile: profile)
            }
            return
        }
        guard let configuration,
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

private func dispatchSafariPush(_ extensionId: String, _ data: Data) {
    guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    SFSafariApplication.dispatchMessage(withName: "winmux-push", toExtensionWithIdentifier: extensionId, userInfo: message) { _ in }
}
