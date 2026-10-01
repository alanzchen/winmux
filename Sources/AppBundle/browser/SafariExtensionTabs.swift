import CryptoKit
import Foundation

/// A Safari tab as the WinMux Tabs extension describes it. Only its title, host name, sound and
/// pin state, and icon come across; never its address.
struct SafariExtensionTab: Equatable, Sendable {
    /// Safari's id for the tab, unique within its extension session (protocol 2). An older
    /// extension doesn't send it.
    var id: Int? = nil
    var title: String
    var host: String? = nil
    var isActive: Bool
    var isAudible: Bool = false
    var isMuted: Bool = false
    var isPinned: Bool = false
    /// The SHA-256 of the tab's 32-pixel PNG icon, in hex.
    var icon: String? = nil
}

/// Safari window ids are only unique within one extension session of one Safari profile.
struct SafariExtensionWindowKey: Hashable, Sendable {
    let source: String
    let id: Int
}

/// A Safari tab across reports, wherever it moves: its id within one extension session of one
/// Safari profile, as for windows.
struct SafariExtensionTabKey: Hashable, Sendable {
    let source: String
    let id: Int
}

struct SafariExtensionWindow: Equatable, Sendable {
    let key: SafariExtensionWindowKey
    /// Where Safari says the window is, in the same top-left screen coordinates WinMux uses.
    var bounds: CGRect? = nil
    var tabs: [SafariExtensionTab]
    /// When WinMux received the report listing this window, by system uptime.
    var received: TimeInterval = -.infinity
    /// Where WinMux saw Safari's windows, by window number, when that report arrived: only those
    /// that had held still since before Safari measured `bounds`. Bounds are only ever compared
    /// with these, never with where windows are now, which WinMux may have changed since.
    var sighting: [UInt32: CGRect] = [:]

    func tabKey(_ tab: SafariExtensionTab) -> SafariExtensionTabKey? { tab.id.map { .init(source: key.source, id: $0) } }
}

/// A full description of one profile's windows. It replaces that profile's previous one.
struct SafariExtensionState: Equatable, Sendable {
    let profile: String
    let session: String
    let time: Double
    /// Whether Safari lets the extension read every website. Without that, titles are missing.
    let allSites: Bool
    let windows: [SafariExtensionWindow]
}

enum SafariExtensionMessage: Equatable, Sendable {
    case state(SafariExtensionState)
    /// Validated PNGs by the SHA-256 the extension sent them under.
    case icons(profile: String, session: String, [String: Data])

    /// Version 2 adds each tab's id. Reports from an older extension still count, without them.
    static let protocolVersion = 2
    static let supportedVersions = 1...protocolVersion
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumWindows = 64
    static let maximumTabs = 500
    static let maximumIcons = 32

    /// Parses and checks one relayed message before anything on the main thread sees it. The
    /// extension's limits are enforced again here; anything outside them is dropped whole.
    static func decode(_ data: Data) -> SafariExtensionMessage? {
        guard data.count <= maximumBytes,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = envelope["message"] as? [String: Any],
              let version = (message["v"] as? NSNumber)?.intValue, supportedVersions.contains(version),
              let session = message["session"] as? String, (1...64).contains(session.count)
        else { return nil }
        // Each report replaces its profile's last one. Before Safari names profiles (macOS 13),
        // each extension session stands alone, so two profiles never replace each other.
        let profile = (envelope["profile"] as? String).flatMap { name in
            UUID(uuidString: name)?.uuidString ?? ((1...64).contains(name.count) ? "profile:\(name)" : nil)
        } ?? "session:\(session)"
        switch message["type"] as? String {
            case "state":
                guard let time = (message["time"] as? NSNumber)?.doubleValue, time.isFinite,
                      let rawWindows = message["windows"] as? [[String: Any]], rawWindows.count <= maximumWindows
                else { return nil }
                let source = "\(profile):\(session)"
                var windows: [SafariExtensionWindow] = []
                for raw in rawWindows {
                    guard let window = decodeWindow(raw, source: source, version: version) else { return nil }
                    windows.append(window)
                }
                // Safari's ids are unique within a session, so a report repeating one is wrong throughout.
                let tabIds = windows.flatMap { $0.tabs.compactMap(\.id) }
                guard Set(windows.map(\.key)).count == windows.count, Set(tabIds).count == tabIds.count else { return nil }
                return .state(.init(profile: profile, session: session, time: time,
                    allSites: message["allSites"] as? Bool ?? false, windows: windows))
            case "icons":
                guard let raw = message["icons"] as? [String: String], raw.count <= maximumIcons else { return nil }
                var icons: [String: Data] = [:]
                for (key, encoded) in raw {
                    // An icon must be what its key says, so one site's key never shows another's icon.
                    guard isIconKey(key), encoded.count <= 96 * 1024, let png = Data(base64Encoded: encoded),
                          SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == key,
                          let thumbnail = BrowserTabIconDownload.thumbnail(png)
                    else { continue }
                    icons[key] = thumbnail
                }
                return .icons(profile: profile, session: session, icons)
            default:
                return nil
        }
    }

    static func isIconKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A JSON integer, not a fraction or a boolean.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func decodeWindow(_ raw: [String: Any], source: String, version: Int) -> SafariExtensionWindow? {
        guard let id = (raw["id"] as? NSNumber)?.intValue,
              let rawTabs = raw["tabs"] as? [[String: Any]], rawTabs.count <= maximumTabs
        else { return nil }
        var bounds: CGRect? = nil
        if let values = raw["bounds"] as? [NSNumber], values.count == 4 {
            let numbers = values.map(\.doubleValue)
            if numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 {
                bounds = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
        }
        var tabs: [SafariExtensionTab] = []
        for tab in rawTabs {
            guard let title = tab["title"] as? String, let active = tab["active"] as? Bool else { return nil }
            let id = version >= 2 ? integer(tab["id"]) : nil
            guard version < 2 || id != nil else { return nil }
            let host = (tab["host"] as? String).flatMap { $0.isEmpty || $0.count > 253 ? nil : $0 }
            let icon = (tab["icon"] as? String).flatMap { isIconKey($0) ? $0 : nil }
            tabs.append(.init(id: id, title: safariExtensionComparableTitle(title), host: host, isActive: active,
                isAudible: tab["audible"] as? Bool ?? false, isMuted: tab["muted"] as? Bool ?? false,
                isPinned: tab["pinned"] as? Bool ?? false, icon: icon))
        }
        return .init(key: .init(source: source, id: id), bounds: bounds, tabs: tabs)
    }
}

/// Titles as both sides compare them: whitespace collapsed, and cut where the extension cuts.
func safariExtensionComparableTitle(_ title: String) -> String {
    String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(512))
}

/// Whether an extension window lists the same tabs, in the same order, with the same one active,
/// as a window WinMux read through Accessibility. Safari withholds a tab's title and address
/// from the extension when it can't read that site; such a tab may differ, but the window's
/// readable titles must agree and outnumber them.
func safariExtensionTabsAgree(_ tabs: [BrowserTab], _ window: SafariExtensionWindow) -> Bool {
    safariExtensionTabsAgree(SafariExtensionCandidate(snapshot: BrowserWindowTabs(windowId: 0, pid: 0, windowSession: UUID(), tabs: tabs)), window)
}

private func safariExtensionTabsAgree(_ candidate: SafariExtensionCandidate, _ window: SafariExtensionWindow) -> Bool {
    let tabs = candidate.snapshot.tabs
    guard tabs.count == window.tabs.count, zip(tabs, window.tabs).allSatisfy({ $0.isSelected == $1.isActive }) else { return false }
    var agreeing = 0
    var withheld = 0
    for (title, other) in zip(candidate.titles, window.tabs) {
        if other.title.isEmpty {
            guard other.host == nil else { return false }
            withheld += 1
        } else {
            guard other.title == title else { return false }
            agreeing += 1
        }
    }
    return agreeing > 0 && agreeing >= withheld
}

/// Safari windows WinMux has no tabs for, any of which could be a read window's twin: ones the
/// sidebar doesn't list, and ones whose read failed or hasn't finished. A window without a tab
/// strip is read as its one tab, so until then it could be a one-tab twin too; Safari's Settings,
/// read that way, is a candidate that pairs with nothing.
func safariExtensionUnreadWindows(live: [UInt32], read: Set<UInt32>) -> [UInt32] {
    live.filter { !read.contains($0) }.sorted()
}

/// What the pairings were last worked out from.
struct SafariExtensionEvidence: Equatable {
    let observed: [UInt32: TimeInterval]
    let reports: Int
    let unread: [UInt32]
}

/// A Safari window's lifetime as WinMux knows it. A later window can get the same number; it
/// gets a new scanner session, so nothing WinMux learned about one window passes to the next.
struct SafariExtensionNativeWindow: Hashable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let windowSession: UUID
}

/// A Safari window WinMux read through Accessibility, and when it read those tabs.
struct SafariExtensionCandidate {
    let snapshot: BrowserWindowTabs
    var observed: TimeInterval = 0
    /// Its tabs' titles as the extension's are compared, worked out once for every window they're compared with.
    let titles: [String]

    init(snapshot: BrowserWindowTabs, observed: TimeInterval = 0) {
        self.snapshot = snapshot
        self.observed = observed
        titles = snapshot.tabs.map { safariExtensionComparableTitle($0.title) }
    }

    var native: SafariExtensionNativeWindow { .init(windowId: snapshot.windowId, pid: snapshot.pid, windowSession: snapshot.windowSession) }
}

/// Frames within this of each other are the same; WinMux reads them two ways, which can round apart.
private func safariExtensionFramesAgree(_ frame: CGRect?, _ other: CGRect?, tolerance: CGFloat = 4) -> Bool {
    guard let frame, let other else { return false }
    return abs(frame.minX - other.minX) <= tolerance && abs(frame.minY - other.minY) <= tolerance &&
        abs(frame.width - other.width) <= tolerance && abs(frame.height - other.height) <= tolerance
}

/// What matching read windows against reported ones found.
struct SafariExtensionMatches {
    var pairs: [UInt32: SafariExtensionWindowKey] = [:]
    /// Windows whose tabs agree with a report, unpaired because frames the report's arrival
    /// didn't record could have settled it: Safari's next report may.
    var needsFrames: Set<UInt32> = []
}

/// Pairs Safari windows with extension windows only where each is the other's one candidate.
/// Two windows with the same tabs are told apart by where WinMux saw them when the report
/// arrived (`SafariExtensionWindow.sighting`); if that doesn't settle it, neither is paired. This
/// never guesses: an unpaired window just keeps Safari's app icon. `unread` are Safari windows
/// WinMux hasn't read: any of them could be an extension window's real twin. With one, a pairing
/// also needs the window, and no unread one, to have been where the report says; a window the
/// report's arrival didn't see in place could have been anywhere, so nothing pairs.
func safariExtensionPairs(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow],
                          unread: [UInt32] = []) -> [UInt32: SafariExtensionWindowKey] {
    safariExtensionMatches(candidates, windows, unread: unread).pairs
}

func safariExtensionMatches(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow],
                            unread: [UInt32] = []) -> SafariExtensionMatches {
    var forward: [UInt32: [Int]] = [:]
    var backward: [Int: [Int]] = [:]
    for (index, candidate) in candidates.enumerated() {
        for (windowIndex, window) in windows.enumerated() where safariExtensionTabsAgree(candidate, window) {
            forward[candidate.snapshot.windowId, default: []].append(windowIndex)
            backward[windowIndex, default: []].append(index)
        }
    }
    func seen(_ id: UInt32, in window: Int) -> Bool { windows[window].sighting[id] != nil }
    func placed(_ id: UInt32, in window: Int) -> Bool { safariExtensionFramesAgree(windows[window].sighting[id], windows[window].bounds) }
    var result = SafariExtensionMatches()
    for (index, candidate) in candidates.enumerated() {
        let id = candidate.snapshot.windowId
        guard let agreeing = forward[id] else { continue }
        // Whether frames the report's arrival didn't record are why this is undecided.
        let unseen = agreeing.contains { window in
            !seen(id, in: window) || (backward[window] ?? []).contains { !seen(candidates[$0].snapshot.windowId, in: window) } ||
                unread.contains { !seen($0, in: window) }
        }
        var mine = agreeing
        if mine.count > 1 { mine = mine.filter { placed(id, in: $0) } }
        guard mine.count == 1, var theirs = backward[mine[0]] else {
            if unseen { result.needsFrames.insert(id) }
            continue
        }
        let window = mine[0]
        if theirs.count > 1 { theirs = theirs.filter { placed(candidates[$0].snapshot.windowId, in: window) } }
        guard theirs == [index], unread.isEmpty || placed(id, in: window) &&
            unread.allSatisfy({ seen($0, in: window) && !safariExtensionFramesAgree(windows[window].sighting[$0], windows[window].bounds) })
        else {
            if unseen { result.needsFrames.insert(id) }
            continue
        }
        result.pairs[id] = windows[window].key
    }
    return result
}

/// How sure WinMux is which extension window a Safari window is.
enum SafariExtensionResolution: Equatable, Sendable {
    /// No report describes it, or several could and nothing settles which.
    case unresolved
    /// One report describes it; a later read must still agree before it counts.
    case pending(SafariExtensionWindowKey)
    case resolved(SafariExtensionWindowKey)
    /// It was resolved, then its tabs stopped agreeing: it keeps its icons for a few seconds,
    /// but not its sound.
    case stale(SafariExtensionWindowKey)
}

/// Which extension window describes each Safari window WinMux lists, and which extension tab
/// each of its tabs is. A new pairing counts once a later Accessibility read, at least 0.75 s
/// on, still agrees, as the two report at different moments. While some Safari window is
/// unread, it also needs the frames to settle it. Once counted, a pairing holds as long as its
/// extension window is reported and their tabs agree, unless a later report's frames pair it
/// with another: frames that don't settle it, or a report from while windows moved, leave it be.
/// No other window takes a held one's report; a report two windows held is held by neither. A
/// paired window that briefly stops agreeing, such as while a title changes, keeps
/// its icons for a few seconds, but not its sound; a pairing with another window replaces it
/// at once. Everything is kept per window lifetime, never only by number. Call this only with
/// new evidence: time passing without a read or report changes nothing.
struct SafariExtensionAssociations {
    static let confirmation: TimeInterval = 0.75
    static let grace: TimeInterval = 10
    private var lifetimes: [UInt32: SafariExtensionNativeWindow] = [:]
    /// When a window number started belonging to another window. Reports that arrived before
    /// then saw the earlier window there.
    private var replaced: [UInt32: TimeInterval] = [:]
    private var pending: [UInt32: (key: SafariExtensionWindowKey, observed: TimeInterval)] = [:]
    private var confirmed: [UInt32: SafariExtensionWindowKey] = [:]
    private var lastAgreement: [UInt32: TimeInterval] = [:]
    private(set) var tabs: [BrowserTabTarget: SafariExtensionTab] = [:]
    /// Which Safari tab each listed tab is, by the extension's id, once a read and a report
    /// agreed on it. An older extension sends no ids; its tabs pair by position.
    private(set) var bound: [BrowserTabTarget: SafariExtensionTabKey] = [:]
    /// Windows whose tabs agreed with the extension in the latest observation.
    private(set) var agreeing: Set<UInt32> = []
    /// Whether a window can't pair until Safari reports again, with frames this report's arrival
    /// didn't have, or with an unread window settled.
    private(set) var awaitsFrames = false

    func resolution(of windowId: UInt32) -> SafariExtensionResolution {
        if let key = confirmed[windowId] { return agreeing.contains(windowId) ? .resolved(key) : .stale(key) }
        return pending[windowId].map { .pending($0.key) } ?? .unresolved
    }

    mutating func update(_ candidates: [SafariExtensionCandidate], windows: [SafariExtensionWindow], unread: [UInt32] = [],
                         now: TimeInterval) {
        for candidate in candidates {
            let native = candidate.native
            if let known = lifetimes[native.windowId], known != native {
                reset(native.windowId)
                replaced[native.windowId] = now
            }
            lifetimes[native.windowId] = native
        }
        let ids = Set(candidates.map(\.snapshot.windowId))
        replaced = replaced.filter { ids.contains($0.key) }
        let windows = replaced.isEmpty ? windows : windows.map { window in
            var window = window
            window.sighting = window.sighting.filter { id, _ in replaced[id].map { window.received >= $0 } ?? true }
            return window
        }
        let byKey = Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let alive = Set(candidates.flatMap { $0.snapshot.tabs.map(\.target) })
        tabs = tabs.filter { alive.contains($0.key) }
        bound = bound.filter { alive.contains($0.key) }
        lifetimes = lifetimes.filter { ids.contains($0.key) }
        pending = pending.filter { ids.contains($0.key) }
        confirmed = confirmed.filter { ids.contains($0.key) }
        lastAgreement = lastAgreement.filter { ids.contains($0.key) }

        let loose = safariExtensionMatches(candidates, windows)
        var held: [UInt32: SafariExtensionWindowKey] = [:]
        for candidate in candidates {
            let id = candidate.snapshot.windowId
            if let key = confirmed[id], let window = byKey[key], safariExtensionTabsAgree(candidate, window),
               loose.pairs[id].map({ $0 == key }) ?? true { held[id] = key }
        }
        // A window still in its grace period can share its key with one paired since.
        let holders = Dictionary(held.values.map { ($0, 1) }, uniquingKeysWith: +)
        held = held.filter { holders[$0.value] == 1 }
        let taken = Set(held.values)
        func holding(_ found: [UInt32: SafariExtensionWindowKey]) -> [UInt32: SafariExtensionWindowKey] {
            found.filter { !taken.contains($0.value) }.merging(held) { _, kept in kept }
        }
        let pairs = holding(loose.pairs)
        let strictMatches = unread.isEmpty ? loose : safariExtensionMatches(candidates, windows, unread: unread)
        let strict = unread.isEmpty ? pairs : holding(strictMatches.pairs)
        awaitsFrames = !strictMatches.needsFrames.subtracting(held.keys).isEmpty
        agreeing = []
        for candidate in candidates {
            let id = candidate.snapshot.windowId
            guard let key = pairs[id], let window = byKey[key] else {
                pending[id] = nil
                if let last = lastAgreement[id], now - last > Self.grace { forget(id) }
                continue
            }
            if confirmed[id] != key {
                if confirmed[id] != nil { forget(id) }
                guard strict[id] == key else {
                    pending[id] = nil
                    awaitsFrames = true
                    continue
                }
                if let waiting = pending[id], waiting.key == key {
                    guard candidate.observed - waiting.observed >= Self.confirmation else { continue }
                    pending[id] = nil
                    confirmed[id] = key
                } else {
                    pending[id] = (key, candidate.observed)
                    continue
                }
            }
            lastAgreement[id] = now
            agreeing.insert(id)
            describe(candidate, window)
        }
    }

    /// Gives each of a paired window's tabs what the extension says about it. A read made after
    /// the report saw the tabs the report lists, so they pair by position, and each keeps the id
    /// it paired with. Before that read, tabs may have moved since the read: each keeps the
    /// Safari tab it was, wherever that is now in the window, and one whose tab left takes its
    /// place's, unless another listed tab is that one. Titles and places never say which tab is
    /// which once ids do.
    private mutating func describe(_ candidate: SafariExtensionCandidate, _ window: SafariExtensionWindow) {
        let targets = candidate.snapshot.tabs.map(\.target)
        let keys = window.tabs.compactMap(window.tabKey)
        guard keys.count == window.tabs.count else {
            for (target, tab) in zip(targets, window.tabs) {
                tabs[target] = tab
                bound[target] = nil
            }
            return
        }
        if candidate.observed >= window.received {
            for (index, target) in targets.enumerated() {
                bound[target] = keys[index]
                tabs[target] = window.tabs[index]
            }
            return
        }
        let positions = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let claimed = Set(targets.compactMap { bound[$0] }.filter { positions[$0] != nil })
        for (index, target) in targets.enumerated() {
            if let key = bound[target], let position = positions[key] {
                tabs[target] = window.tabs[position]
            } else if !claimed.contains(keys[index]) {
                bound[target] = keys[index]
                tabs[target] = window.tabs[index]
            }
        }
    }

    /// The tab with what the extension says about it. Sound shows only while the window agrees
    /// with the extension, as it goes stale fastest; a window the extension doesn't describe
    /// keeps the sound its read found.
    func described(_ tab: BrowserTab) -> BrowserTab {
        var tab = tab
        let described = tabs[tab.target]
        tab.siteIcon = described?.icon
        tab.host = described?.host
        tab.extensionTab = bound[tab.target]
        if agreeing.contains(tab.target.windowId) {
            tab.audio = described.flatMap { $0.isMuted ? .muted : $0.isAudible ? .playing : nil }
        }
        return tab
    }

    private mutating func forget(_ id: UInt32) {
        confirmed[id] = nil
        lastAgreement[id] = nil
        tabs = tabs.filter { $0.key.windowId != id }
        bound = bound.filter { $0.key.windowId != id }
    }

    private mutating func reset(_ id: UInt32) {
        forget(id)
        pending[id] = nil
        lifetimes[id] = nil
    }
}

/// Where WinMux has seen each Safari window, and since when it has been there, so a report's
/// bounds are only ever compared with frames from the moment Safari measured them.
struct SafariExtensionFrameTrack {
    /// How long before Safari measured its windows a frame must already have been in place:
    /// WinMux samples frames a few times a second, and could have missed a move just before.
    static let margin: TimeInterval = 0.3
    private var frames: [UInt32: (frame: CGRect, since: TimeInterval)] = [:]

    /// Where Safari's windows are now. A window first seen, moved or resized starts counting
    /// again; one not listed, or whose frame is unknown, is dropped.
    mutating func observe(_ current: [UInt32: CGRect?], now: TimeInterval) {
        var next: [UInt32: (frame: CGRect, since: TimeInterval)] = [:]
        for (id, frame) in current {
            guard let frame else { continue }
            if let known = frames[id], safariExtensionFramesAgree(known.frame, frame, tolerance: 1) {
                next[id] = known
            } else {
                next[id] = (frame, now)
            }
        }
        frames = next
    }

    /// The windows that have been where they are since before `measured`, when Safari measured
    /// its windows for a report.
    func sighting(measured: TimeInterval) -> [UInt32: CGRect] {
        frames.filter { $0.value.since <= measured - Self.margin }.mapValues(\.frame)
    }
}
