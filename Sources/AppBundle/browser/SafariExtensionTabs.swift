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
    /// The extension session that reported it, which its toolbar button names (`SafariExtensionMarker`).
    var session = ""
    /// From an extension older than protocol 2, which doesn't say when it measured. A newer one's
    /// report without a usable measurement says nothing about when it was measured, either.
    var legacy = false
    /// Where Safari says the window is, in the same top-left screen coordinates WinMux uses.
    var bounds: CGRect? = nil
    var tabs: [SafariExtensionTab]
    /// When WinMux received the report listing this window, and when Safari began measuring its
    /// windows for it, both by system uptime.
    var received: TimeInterval = -.infinity
    var measured: TimeInterval = -.infinity
    /// The report's count of reorderings (`SafariExtensionState.order`).
    var order: Int? = nil
    /// Where WinMux saw Safari's windows, by window number, when that report arrived: only those
    /// that hadn't moved or changed since before Safari began measuring. Bounds are only ever
    /// compared with these, never with where windows are now, which WinMux may have changed since.
    var sighting: [UInt32: CGRect] = [:]

    func tabKey(_ tab: SafariExtensionTab) -> SafariExtensionTabKey? { tab.id.map { .init(source: key.source, id: $0) } }
}

/// A full description of one profile's windows. It replaces that profile's previous one.
struct SafariExtensionState: Equatable, Sendable {
    let profile: String
    let session: String
    let time: Double
    /// When the extension began measuring windows for this report, before it asked Safari for
    /// them, on the same clock as `time` (protocol 2). Without it, the report's bounds say
    /// nothing WinMux can trust about where windows were.
    var measured: Double? = nil
    /// How many tab moves, attachments, openings and closings the extension had heard of this
    /// session, if that didn't change while it measured (protocol 2). Two reports with the same
    /// count saw no reordering in between.
    var order: Int? = nil
    /// Whether Safari lets the extension read every website. Without that, titles are missing.
    let allSites: Bool
    let windows: [SafariExtensionWindow]
    var push: BrowserPushEnvelope? = nil
}

enum SafariExtensionMessage: Equatable, Sendable {
    case state(SafariExtensionState)
    case control(BrowserPushControl)
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
        if message["type"] as? String == "push-control" {
            return BrowserPushControl.decode(message, profile: profile, session: session).map(Self.control)
        }
        switch message["type"] as? String {
            case "state", "events":
                guard let time = (message["time"] as? NSNumber)?.doubleValue, time.isFinite,
                      let rawWindows = message["windows"] as? [[String: Any]], rawWindows.count <= maximumWindows
                else { return nil }
                let push = BrowserPushEnvelope.decode(message["push"])
                if message["push"] != nil && push == nil { return nil }
                if message["type"] as? String == "events", push?.snapshot != false { return nil }
                // A reloaded page can retain session storage. Its new transport epoch must not
                // inherit any old window/tab bindings, even if the browser reuses numeric ids.
                let source = "\(profile):\(session)" + (push.map { ":" + $0.epoch } ?? "")
                var windows: [SafariExtensionWindow] = []
                for raw in rawWindows {
                    guard let window = decodeWindow(raw, source: source, session: session, version: version) else { return nil }
                    windows.append(window)
                }
                // Safari's ids are unique within a session, so a report repeating one is wrong throughout.
                let tabIds = windows.flatMap { $0.tabs.compactMap(\.id) }
                guard Set(windows.map(\.key)).count == windows.count, Set(tabIds).count == tabIds.count else { return nil }
                let measured = version >= 2 ? (message["measured"] as? NSNumber)?.doubleValue : nil
                let order = version >= 2 ? integer(message["order"]).flatMap { $0 >= 0 ? $0 : nil } : nil
                if let push, !Set(push.removed).isDisjoint(with: windows.map { $0.key.id }) { return nil }
                return .state(.init(profile: profile, session: session, time: time,
                    measured: measured.flatMap { $0.isFinite && $0 <= time ? $0 : nil }, order: order,
                    allSites: message["allSites"] as? Bool ?? false, windows: windows, push: push))
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

    private static func decodeWindow(_ raw: [String: Any], source: String, session: String, version: Int) -> SafariExtensionWindow? {
        guard raw["incognito"] as? Bool != true, let id = integer(raw["id"]), id >= 0,
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
            guard tab["incognito"] as? Bool != true else { return nil }
            guard let title = tab["title"] as? String, let active = tab["active"] as? Bool else { return nil }
            let id = version >= 2 ? integer(tab["id"]) : nil
            guard version < 2 || id != nil else { return nil }
            let host = (tab["host"] as? String).flatMap { $0.isEmpty || $0.count > 253 ? nil : $0 }
            let icon = (tab["icon"] as? String).flatMap { isIconKey($0) ? $0 : nil }
            tabs.append(.init(id: id, title: safariExtensionComparableTitle(title), host: host, isActive: active,
                isAudible: tab["audible"] as? Bool ?? false, isMuted: tab["muted"] as? Bool ?? false,
                isPinned: tab["pinned"] as? Bool ?? false, icon: icon))
        }
        return .init(key: .init(source: source, id: id), session: session, legacy: version < 2, bounds: bounds, tabs: tabs)
    }
}

/// What the WinMux Tabs extension's toolbar button is called in one Safari window, as
/// Accessibility reads it: "WinMux Tabs · ", then the first 8 characters of the extension's
/// session, its id for the window and its id for the window's active tab, which is the tab the
/// extension gave that title. Safari shows a tab's own button title only while the tab is active,
/// in its window. Anything else, such as the plain name before the extension titles a new tab,
/// names nothing.
struct SafariExtensionMarker: Hashable, Sendable {
    let session: String
    let window: Int
    let tab: Int

    static let prefix = "WinMux Tabs \u{00B7} "

    init(session: String, window: Int, tab: Int) {
        self.session = session
        self.window = window
        self.tab = tab
    }

    init?(_ title: String?) {
        guard let title, title.hasPrefix(Self.prefix) else { return nil }
        let parts = title.dropFirst(Self.prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        func number(_ part: Substring) -> Int? {
            (1...15).contains(part.utf8.count) && part.utf8.allSatisfy { (0x30...0x39).contains($0) } ? Int(part) : nil
        }
        guard parts.count == 3, parts[0].utf8.count == 8,
              parts[0].utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }),
              let window = number(parts[1]), let tab = number(parts[2]) else { return nil }
        self.init(session: String(parts[0]), window: window, tab: tab)
    }
}

/// Titles as both sides compare them: whitespace collapsed, and cut where the extension cuts.
func safariExtensionComparableTitle(_ title: String) -> String {
    String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(512))
}

/// Whether an extension window lists the same tabs, in the same order, with the same one active,
/// as a window WinMux read through Accessibility. Safari withholds a tab's title and address
/// from the extension when it can't read that site; such a tab may differ, but the window's
/// readable titles must agree and outnumber them. A window whose read didn't list all its tabs
/// (`BrowserWindowTabs.isComplete`) agrees with none.
func safariExtensionTabsAgree(_ tabs: [BrowserTab], _ window: SafariExtensionWindow) -> Bool {
    safariExtensionTabsAgree(SafariExtensionCandidate(snapshot: BrowserWindowTabs(windowId: 0, pid: 0, windowSession: UUID(), tabs: tabs)), window)
}

private func safariExtensionTabsAgree(_ candidate: SafariExtensionCandidate, _ window: SafariExtensionWindow) -> Bool {
    let tabs = candidate.snapshot.tabs
    guard candidate.snapshot.isComplete, tabs.count == window.tabs.count, zip(tabs, window.tabs).allSatisfy({ $0.isSelected == $1.isActive }) else { return false }
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
    /// When that read began: it saw the tabs at some moment between then and `observed`.
    var readStarted: TimeInterval
    /// When WinMux first saw this native window, by system uptime. A report measured before then
    /// saw another window under its number, if any.
    var appeared: TimeInterval = -.infinity
    /// Its tabs' titles as the extension's are compared, worked out once for every window they're compared with.
    let titles: [String]

    init(snapshot: BrowserWindowTabs, observed: TimeInterval = 0, readStarted: TimeInterval? = nil, appeared: TimeInterval = -.infinity) {
        self.snapshot = snapshot
        self.observed = observed
        self.readStarted = readStarted ?? observed
        self.appeared = appeared
        titles = snapshot.tabs.map { safariExtensionComparableTitle($0.title) }
    }

    var native: SafariExtensionNativeWindow { .init(windowId: snapshot.windowId, pid: snapshot.pid, windowSession: snapshot.windowSession) }
}

/// Pairs Safari windows by their extension toolbar buttons (`SafariExtensionMarker`). A window
/// whose button names a window the latest report lists, from that report's session, with the
/// named tab active there and the same tabs as the window's read, is that window, wherever it is.
/// A button naming anything else pairs nothing, nor do buttons that two windows show at once,
/// as one of them hasn't caught up: those windows are paired as if they had none.
func safariExtensionMarkedPairs(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow]) -> [UInt32: SafariExtensionWindowKey] {
    let shown = Dictionary(candidates.compactMap { $0.snapshot.marker.map { ($0, 1) } }, uniquingKeysWith: +)
    var claims: [SafariExtensionWindowKey: [UInt32]] = [:]
    for candidate in candidates {
        guard let marker = candidate.snapshot.marker, shown[marker] == 1 else { continue }
        let named = windows.filter { $0.key.id == marker.window && $0.session.hasPrefix(marker.session) }
        guard named.count == 1, let window = named.first, window.tabs.contains(where: { $0.id == marker.tab && $0.isActive }),
              safariExtensionTabsAgree(candidate, window) else { continue }
        claims[window.key, default: []].append(candidate.snapshot.windowId)
    }
    // A report listing two active tabs in one window would let two buttons name it: neither does.
    return Dictionary(uniqueKeysWithValues: claims.compactMap { key, ids in ids.count == 1 ? (ids[0], key) : nil })
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
/// arrived (`SafariExtensionWindow.sighting`): the one paired must have been where Safari says,
/// and every other that could be must have been seen elsewhere. A window the report's arrival
/// didn't see could have been anywhere, so it stands in the way. If that doesn't settle it,
/// neither is paired. This never guesses: an unpaired window just keeps Safari's app icon.
/// `unread` are Safari windows WinMux hasn't read: any of them could be an extension window's
/// real twin. With one, a pairing also needs the window to have been where the report says and
/// every unread one to have been seen elsewhere.
/// `unreadAppeared` says when each unread window appeared, as for candidates.
func safariExtensionPairs(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow],
                          unread: [UInt32] = [], unreadAppeared: [UInt32: TimeInterval] = [:]) -> [UInt32: SafariExtensionWindowKey] {
    safariExtensionMatches(candidates, windows, unread: unread, unreadAppeared: unreadAppeared).pairs
}

func safariExtensionMatches(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow],
                            unread: [UInt32] = [], unreadAppeared: [UInt32: TimeInterval] = [:]) -> SafariExtensionMatches {
    var forward: [Int: [Int]] = [:]
    var backward: [Int: [Int]] = [:]
    for (index, candidate) in candidates.enumerated() {
        for (windowIndex, window) in windows.enumerated() where safariExtensionTabsAgree(candidate, window) {
            forward[index, default: []].append(windowIndex)
            backward[windowIndex, default: []].append(index)
        }
    }
    /// Where the report listing `window` saw the candidate, if it saw this very native window.
    func frame(_ candidate: Int, in window: Int) -> CGRect? {
        candidates[candidate].appeared <= windows[window].measured ? windows[window].sighting[candidates[candidate].snapshot.windowId] : nil
    }
    func unreadFrame(_ id: UInt32, in window: Int) -> CGRect? {
        (unreadAppeared[id] ?? -.infinity) <= windows[window].measured ? windows[window].sighting[id] : nil
    }
    func placed(_ candidate: Int, in window: Int) -> Bool { safariExtensionFramesAgree(frame(candidate, in: window), windows[window].bounds) }
    /// Seen, and somewhere else than the report says; a report that doesn't say where its window
    /// is rules nothing out.
    func elsewhere(_ frame: CGRect?, in window: Int) -> Bool {
        guard let frame, let bounds = windows[window].bounds else { return false }
        return !safariExtensionFramesAgree(frame, bounds)
    }
    /// Whether the report listing `window` could describe the candidate: not if Safari measured it
    /// before this native window appeared, when it described another, if any (one that closed,
    /// whose number or tabs this one has), nor if it can't be known when it was measured. The
    /// candidate still stands in others' way: the report may be that closed window's. An older
    /// extension's reports never say when they were measured, and pair as before.
    func current(_ candidate: Int, for window: Int) -> Bool {
        windows[window].legacy || windows[window].measured.isFinite && candidates[candidate].appeared <= windows[window].measured
    }
    var result = SafariExtensionMatches()
    for index in candidates.indices {
        guard let agreeing = forward[index] else { continue }
        let id = candidates[index].snapshot.windowId
        // Whether frames the report's arrival didn't record are why this stays undecided.
        let unseen = agreeing.contains { window in
            windows[window].bounds == nil || frame(index, in: window) == nil ||
                (backward[window] ?? []).contains { frame($0, in: window) == nil } || unread.contains { unreadFrame($0, in: window) == nil }
        }
        let possible = agreeing.count > 1 ? agreeing.filter { !elsewhere(frame(index, in: $0), in: $0) } : agreeing
        guard possible.count == 1, let window = possible.first, current(index, for: window), let rivals = backward[window],
              agreeing.count == 1 && rivals.count == 1 ||
                  placed(index, in: window) && rivals.allSatisfy({ $0 == index || elsewhere(frame($0, in: window), in: window) }),
              unread.isEmpty || placed(index, in: window) && unread.allSatisfy({ elsewhere(unreadFrame($0, in: window), in: window) })
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
/// each of its tabs is. A window whose toolbar button names its extension window is paired by
/// that (`safariExtensionMarkedPairs`), once a report from after a read that saw the button still
/// agrees (`MarkerClaim`); the rest are paired among the windows left. A new
/// pairing counts once a later Accessibility read, at least 0.75 s on, still agrees, as the two
/// report at different moments. While some Safari window is unread, a pairing no button named
/// also needs the frames to settle it. Once counted, a pairing holds as long as its
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
    private var pending: [UInt32: (key: SafariExtensionWindowKey, observed: TimeInterval)] = [:]
    private var confirmed: [UInt32: SafariExtensionWindowKey] = [:]
    private var lastAgreement: [UInt32: TimeInterval] = [:]
    private(set) var tabs: [BrowserTabTarget: SafariExtensionTab] = [:]
    /// Which Safari tab each listed tab is, by the extension's id, once a read and a report
    /// agreed on it. An older extension sends no ids; its tabs pair by position.
    private(set) var bound: [BrowserTabTarget: SafariExtensionTabKey] = [:]
    /// Listed tabs among others with the same title, paired by place with a Safari tab by one
    /// read, which ended at `read`. `matched` is a later report and a read begun after it arrived
    /// that still agree: the report's arrival, its count of reorderings and the window's tabs in
    /// it, and when that read ended.
    private struct Proposal {
        let key: SafariExtensionTabKey
        let read: TimeInterval
        var matched: (received: TimeInterval, order: Int, tabs: [SafariExtensionTabKey], read: TimeInterval)? = nil
    }
    private var proposed: [BrowserTabTarget: Proposal] = [:]
    /// A window's toolbar button naming a report's window, at a read begun after that report
    /// arrived, which ended at `read`. The title belongs to a tab and goes with it, so until
    /// Safari reports again it may name the window the tab left: it counts only once a report
    /// Safari measured after that read still agrees, with the same count of reorderings, so the
    /// tab stayed where the title says while the read looked.
    private struct MarkerClaim {
        let marker: SafariExtensionMarker
        let key: SafariExtensionWindowKey
        let received: TimeInterval
        let order: Int
        let read: TimeInterval
    }
    private var markerClaims: [UInt32: MarkerClaim] = [:]
    /// Report windows a window's button named this way, for this window lifetime: each keeps
    /// counting while the window's button names it and the latest report still agrees.
    private var trustedMarkers: [UInt32: SafariExtensionWindowKey] = [:]
    /// Each window's tabs, by Safari's ids, in the latest report it was described by.
    private var reportedTabs: [UInt32: [SafariExtensionTabKey]] = [:]
    /// Windows whose tabs agreed with the extension in the latest observation, and those that
    /// agreed before it but no longer do.
    private(set) var agreeing: Set<UInt32> = []
    private(set) var lapsed: Set<UInt32> = []
    /// Windows to read again at once: those that stopped agreeing, those whose reported tabs were
    /// reordered among themselves (their titles can still agree), and those whose button names a
    /// report's window, so a read after that report can start trusting it.
    private(set) var rereads: Set<UInt32> = []
    /// Whether something can't be settled until Safari reports again: a window, with frames this
    /// report's arrival didn't have or with an unread window settled, or a tab's pairing.
    private(set) var awaitsReport = false

    func resolution(of windowId: UInt32) -> SafariExtensionResolution {
        if let key = confirmed[windowId] { return agreeing.contains(windowId) ? .resolved(key) : .stale(key) }
        return pending[windowId].map { .pending($0.key) } ?? .unresolved
    }

    /// `unreadAppeared` says when each unread window appeared, as `SafariExtensionCandidate.appeared` does.
    /// A window whose read didn't list all its tabs (`BrowserWindowTabs.isComplete`) agrees with no
    /// report, but could be any report's window, as an unread one could: so it's taken for one too.
    mutating func update(_ candidates: [SafariExtensionCandidate], windows: [SafariExtensionWindow], unread: [UInt32] = [],
                         unreadAppeared: [UInt32: TimeInterval] = [:], now: TimeInterval) {
        let incomplete = candidates.filter { !$0.snapshot.isComplete && !unread.contains($0.snapshot.windowId) }
        let unread = unread + incomplete.map(\.snapshot.windowId)
        let unreadAppeared = unreadAppeared.merging(incomplete.map { ($0.snapshot.windowId, $0.appeared) }) { given, _ in given }
        for candidate in candidates {
            let native = candidate.native
            if let known = lifetimes[native.windowId], known != native { reset(native.windowId) }
            lifetimes[native.windowId] = native
        }
        let ids = Set(candidates.map(\.snapshot.windowId))
        let byKey = Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let alive = Set(candidates.flatMap { $0.snapshot.tabs.map(\.target) })
        tabs = tabs.filter { alive.contains($0.key) }
        bound = bound.filter { alive.contains($0.key) }
        proposed = proposed.filter { alive.contains($0.key) }
        lifetimes = lifetimes.filter { ids.contains($0.key) }
        markerClaims = markerClaims.filter { ids.contains($0.key) }
        trustedMarkers = trustedMarkers.filter { ids.contains($0.key) }
        reportedTabs = reportedTabs.filter { ids.contains($0.key) }
        pending = pending.filter { ids.contains($0.key) }
        confirmed = confirmed.filter { ids.contains($0.key) }
        lastAgreement = lastAgreement.filter { ids.contains($0.key) }

        // A window's own toolbar button outweighs everything else, holds included, once trusted.
        var reordered: Set<UInt32> = []
        var untrusted: Set<UInt32> = []
        let marked = trustMarkers(candidates, named: safariExtensionMarkedPairs(candidates, windows), byKey: byKey, untrusted: &untrusted)
        let markedKeys = Set(marked.values)
        let open = candidates.filter { marked[$0.snapshot.windowId] == nil }
        let openWindows = windows.filter { !markedKeys.contains($0.key) }
        let loose = safariExtensionMatches(open, openWindows)
        // A report that pairs the window, or its report, otherwise outweighs the hold.
        let owners = Dictionary(loose.pairs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var held: [UInt32: SafariExtensionWindowKey] = [:]
        for candidate in open {
            let id = candidate.snapshot.windowId
            if let key = confirmed[id], !markedKeys.contains(key), let window = byKey[key], safariExtensionTabsAgree(candidate, window),
               loose.pairs[id].map({ $0 == key }) ?? true, owners[key].map({ $0 == id }) ?? true { held[id] = key }
        }
        // A window still in its grace period can share its key with one paired since.
        let holders = Dictionary(held.values.map { ($0, 1) }, uniquingKeysWith: +)
        held = held.filter { holders[$0.value] == 1 }
        let taken = Set(held.values)
        func holding(_ found: [UInt32: SafariExtensionWindowKey]) -> [UInt32: SafariExtensionWindowKey] {
            found.filter { !taken.contains($0.value) }.merging(held) { _, kept in kept }
        }
        let pairs = holding(loose.pairs).merging(marked) { _, named in named }
        let strictMatches = unread.isEmpty ? loose : safariExtensionMatches(open, openWindows, unread: unread, unreadAppeared: unreadAppeared)
        let strict = unread.isEmpty ? pairs : holding(strictMatches.pairs).merging(marked) { _, named in named }
        awaitsReport = !strictMatches.needsFrames.subtracting(held.keys).isEmpty
        let agreed = agreeing
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
                    awaitsReport = true
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
            let keys = window.tabs.compactMap(window.tabKey)
            if let previous = reportedTabs[id], previous != keys { reordered.insert(id) }
            reportedTabs[id] = keys
            describe(candidate, window)
        }
        if !proposed.isEmpty || !untrusted.isEmpty { awaitsReport = true }
        lapsed = agreed.subtracting(agreeing)
        rereads = lapsed.union(reordered).union(untrusted.filter { markerClaims[$0] == nil })
    }

    /// The windows whose toolbar buttons count (`MarkerClaim`), out of those whose buttons name a
    /// report's window (`named`). `untrusted` gets the rest of those: they need another report.
    private mutating func trustMarkers(_ candidates: [SafariExtensionCandidate], named: [UInt32: SafariExtensionWindowKey],
                                       byKey: [SafariExtensionWindowKey: SafariExtensionWindow],
                                       untrusted: inout Set<UInt32>) -> [UInt32: SafariExtensionWindowKey] {
        var trusted: [UInt32: SafariExtensionWindowKey] = [:]
        for candidate in candidates {
            let id = candidate.snapshot.windowId
            // A button showing just its name (a page loading, or the button out of the toolbar)
            // keeps what it established; one naming anything else, or nothing it can, doesn't.
            guard let marker = candidate.snapshot.marker else { continue }
            guard let key = named[id], let window = byKey[key] else {
                markerClaims[id] = nil
                trustedMarkers[id] = nil
                continue
            }
            if trustedMarkers[id] == key {
                trusted[id] = key
                continue
            }
            trustedMarkers[id] = nil
            if let claim = markerClaims[id], claim.marker == marker, claim.key == key, window.received > claim.received {
                if window.order == claim.order, window.measured >= claim.read {
                    markerClaims[id] = nil
                    trustedMarkers[id] = key
                    trusted[id] = key
                    continue
                }
                // Reordered meanwhile, or not yet a report from after the read: start over, or wait.
                if window.order != claim.order { markerClaims[id] = nil }
            }
            if let claim = markerClaims[id], claim.marker != marker || claim.key != key { markerClaims[id] = nil }
            if markerClaims[id] == nil, candidate.readStarted >= window.received, let order = window.order {
                markerClaims[id] = MarkerClaim(marker: marker, key: key, received: window.received, order: order, read: candidate.observed)
            }
            untrusted.insert(id)
        }
        return trusted
    }

    /// Gives each of a paired window's tabs what the extension says about it. Each listed tab
    /// keeps the Safari tab it's bound to, by id, as long as Safari still lists that tab in this
    /// window and their titles agree, wherever the tab bar puts it: neither a read nor a report
    /// says which of two same-titled tabs moved. A tab without one pairs with the tab in its
    /// place, if no other listed tab has that one, only by a read begun after the report arrived.
    ///
    /// A title says which tab is which. Among tabs with the same title, a read can only propose a
    /// pairing, showing the icon but not the sound: it may have seen a reorder Safari hadn't
    /// reported. The proposal stands once a report Safari began measuring after that read, and a
    /// read begun after that report arrived, still agree, and a later report measured after that
    /// read has the same tabs in the same order and the same count of reorderings: so nothing was
    /// reordered while that read looked. Until a tab is paired, and once its Safari tab is gone,
    /// it shows nothing from the extension.
    private mutating func describe(_ candidate: SafariExtensionCandidate, _ window: SafariExtensionWindow) {
        let listed = candidate.snapshot.tabs
        let keys = window.tabs.compactMap(window.tabKey)
        // An older extension doesn't name tabs: they pair by position.
        guard keys.count == window.tabs.count else {
            for (tab, described) in zip(listed, window.tabs) {
                tabs[tab.target] = described
                bound[tab.target] = nil
                proposed[tab.target] = nil
            }
            return
        }
        let positions = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(candidate.titles.map { ($0, 1) }, uniquingKeysWith: +)
        let comparable = candidate.readStarted >= window.received
        var claimed: Set<SafariExtensionTabKey> = []
        for (index, tab) in listed.enumerated() {
            if let key = bound[tab.target] {
                if positions[key] != nil { claimed.insert(key) } else { bound[tab.target] = nil }
            }
            guard var proposal = proposed[tab.target] else { continue }
            guard positions[proposal.key] != nil, bound[tab.target] == nil else {
                proposed[tab.target] = nil
                continue
            }
            if let matched = proposal.matched, window.received > matched.received {
                // A later report: it vouches for the match if nothing was reordered in between. One
                // measured before the matching read ended can only refute it.
                let unchanged = window.order == matched.order && keys == matched.tabs
                if unchanged, window.measured >= matched.read {
                    proposed[tab.target] = nil
                    bound[tab.target] = proposal.key
                    claimed.insert(proposal.key)
                    continue
                }
                if !unchanged || window.measured >= matched.read { proposal.matched = nil }
            }
            if comparable, window.measured >= proposal.read {
                // A report measured since, and a read begun after it arrived: they agree, or the proposal goes.
                guard positions[proposal.key] == index else {
                    proposed[tab.target] = nil
                    continue
                }
                if proposal.matched == nil, let order = window.order {
                    proposal.matched = (window.received, order, keys, candidate.observed)
                }
            }
            proposed[tab.target] = proposal
            claimed.insert(proposal.key)
        }
        for (index, tab) in listed.enumerated() {
            if bound[tab.target] == nil, proposed[tab.target] == nil, comparable, claimed.insert(keys[index]).inserted {
                let ambiguous = counts[candidate.titles[index], default: 0] > 1 || window.tabs[index].title.isEmpty
                if ambiguous { proposed[tab.target] = Proposal(key: keys[index], read: candidate.observed) } else { bound[tab.target] = keys[index] }
            }
            let key = bound[tab.target] ?? proposed[tab.target]?.key
            guard let key, let position = positions[key],
                  window.tabs[position].title.isEmpty || window.tabs[position].title == candidate.titles[index] else {
                tabs[tab.target] = nil
                continue
            }
            var described = window.tabs[position]
            if bound[tab.target] == nil {
                described.isAudible = false
                described.isMuted = false
            }
            tabs[tab.target] = described
        }
    }

    /// Whether these reports list, in a window paired or about to be, a tab among others with its
    /// title (or whose title Safari withholds) that isn't paired for good: that takes a read after
    /// this report and a report after that, so Safari should report again soon. An older
    /// extension's tabs, which pair by place, never wait.
    func awaitsAnotherReport(_ windows: [SafariExtensionWindow]) -> Bool {
        let paired = Set(confirmed.values).union(pending.values.map(\.key))
        let settled = Set(bound.values)
        return windows.contains { window in
            guard paired.contains(window.key) else { return false }
            let counts = Dictionary(window.tabs.map { ($0.title, 1) }, uniquingKeysWith: +)
            return window.tabs.contains { tab in
                (tab.title.isEmpty || counts[tab.title, default: 0] > 1) && window.tabKey(tab).map { !settled.contains($0) } ?? false
            }
        }
    }

    /// Whether the extension describes all of the window's tabs, each paired for good, and the
    /// window agrees with its latest report: from then on, the reports say when its tabs change.
    func settles(_ snapshot: BrowserWindowTabs) -> Bool {
        agreeing.contains(snapshot.windowId) && confirmed[snapshot.windowId] != nil &&
            snapshot.tabs.allSatisfy { tabs[$0.target] != nil && proposed[$0.target] == nil }
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
        proposed = proposed.filter { $0.key.windowId != id }
    }

    private mutating func reset(_ id: UInt32) {
        forget(id)
        pending[id] = nil
        lifetimes[id] = nil
        markerClaims[id] = nil
        trustedMarkers[id] = nil
        reportedTabs[id] = nil
    }
}

/// What WinMux knows about a Safari window's geometry at one moment.
struct SafariExtensionFrameSample: Equatable, Sendable {
    var frame: CGRect?
    /// Which native window it is: a later one with the same number is another.
    var identity: ObjectIdentifier? = nil
    /// Counts the moves and resizes WinMux heard about (`Window.nativeStateObservationToken`),
    /// and the version of the writes it made itself (`FrameWriteLedger`), so a move and a move back
    /// between two samples still count, whether or not their notifications have arrived.
    var generation: UInt64? = nil
    var writes: UInt64? = nil
    /// Whether one of WinMux's writes is running now: where the window will be is unknown.
    var writing = false
}

/// Where WinMux has seen each Safari window, and since when it has been there, so a report's
/// bounds are only ever compared with frames from the moment Safari measured them.
struct SafariExtensionFrameTrack {
    /// How long before Safari began measuring its windows a frame must already have been in
    /// place: WinMux samples frames a few times a second, and hears of some moves late.
    static let margin: TimeInterval = 0.3
    private struct Entry {
        var sample: SafariExtensionFrameSample
        var frame: CGRect
        var since: TimeInterval
        var appeared: TimeInterval
        /// Not sampled for a while: where it was in between is unknown.
        var paused = false
    }
    private var entries: [UInt32: Entry] = [:]
    /// Whether WinMux has sampled before: windows in the first sample were already open, since
    /// some time WinMux doesn't know. Any seen first later, even after a pause, appeared then, or
    /// at least nothing measured before then can be taken to describe them.
    private var sampledBefore = false

    /// Where Safari's windows are now. A window first seen, moved, resized or replaced starts
    /// counting again; one not listed, or whose frame is unknown, is dropped.
    mutating func observe(_ current: [UInt32: SafariExtensionFrameSample], now: TimeInterval) {
        let starting = !sampledBefore
        sampledBefore = true
        var next: [UInt32: Entry] = [:]
        for (id, sample) in current {
            guard let frame = sample.frame else { continue }
            guard let known = entries[id], known.sample.identity == sample.identity else {
                next[id] = Entry(sample: sample, frame: frame, since: now, appeared: starting ? -.infinity : now)
                continue
            }
            let still = !known.paused && !sample.writing && known.sample.generation == sample.generation &&
                known.sample.writes == sample.writes && safariExtensionFramesAgree(known.frame, frame, tolerance: 1)
            next[id] = Entry(sample: sample, frame: frame, since: still ? known.since : now, appeared: known.appeared)
        }
        entries = next
    }

    /// Stops sampling for now. Windows keep when they appeared, but each starts counting again
    /// from its next sample, as nothing says where it was meanwhile.
    mutating func pause() {
        for id in entries.keys { entries[id]?.paused = true }
    }

    mutating func observe(_ frames: [UInt32: CGRect?], now: TimeInterval) {
        observe(frames.mapValues { SafariExtensionFrameSample(frame: $0) }, now: now)
    }

    /// The windows that have been where they are, unmoved, since before `measured`, when Safari
    /// began measuring its windows for a report.
    func sighting(measured: TimeInterval) -> [UInt32: CGRect] {
        entries.filter { !$0.value.paused && $0.value.since <= measured - Self.margin }.mapValues(\.frame)
    }

    /// When the native window now under this number was first seen, if it has been: -infinity for
    /// one already open when WinMux first sampled.
    func appeared(_ id: UInt32) -> TimeInterval? { entries[id]?.appeared }
}
