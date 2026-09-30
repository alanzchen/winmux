import CryptoKit
import Foundation

/// A Safari tab as the WinMux Tabs extension describes it. Only its title, host name, sound and
/// pin state, and icon come across; never its address.
struct SafariExtensionTab: Equatable, Sendable {
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

struct SafariExtensionWindow: Equatable, Sendable {
    let key: SafariExtensionWindowKey
    /// Where Safari says the window is, in the same top-left screen coordinates WinMux uses.
    var bounds: CGRect? = nil
    var tabs: [SafariExtensionTab]
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

    static let protocolVersion = 1
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
              (message["v"] as? NSNumber)?.intValue == protocolVersion,
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
                    guard let window = decodeWindow(raw, source: source) else { return nil }
                    windows.append(window)
                }
                guard Set(windows.map(\.key)).count == windows.count else { return nil }
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

    private static func decodeWindow(_ raw: [String: Any], source: String) -> SafariExtensionWindow? {
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
            let host = (tab["host"] as? String).flatMap { $0.isEmpty || $0.count > 253 ? nil : $0 }
            let icon = (tab["icon"] as? String).flatMap { isIconKey($0) ? $0 : nil }
            tabs.append(.init(title: safariExtensionComparableTitle(title), host: host, isActive: active,
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
    let unreadFrames: [CGRect?]
}

/// A Safari window WinMux read through Accessibility, where it last saw that window, and when it
/// read those tabs.
struct SafariExtensionCandidate {
    let snapshot: BrowserWindowTabs
    var frame: CGRect? = nil
    var observed: TimeInterval = 0
    /// Its tabs' titles as the extension's are compared, worked out once for every window they're compared with.
    let titles: [String]

    init(snapshot: BrowserWindowTabs, frame: CGRect? = nil, observed: TimeInterval = 0) {
        self.snapshot = snapshot
        self.frame = frame
        self.observed = observed
        titles = snapshot.tabs.map { safariExtensionComparableTitle($0.title) }
    }
}

private func safariExtensionBoundsAgree(_ frame: CGRect?, _ bounds: CGRect?) -> Bool {
    guard let frame, let bounds else { return false }
    return abs(frame.minX - bounds.minX) <= 4 && abs(frame.minY - bounds.minY) <= 4 &&
        abs(frame.width - bounds.width) <= 4 && abs(frame.height - bounds.height) <= 4
}

/// Pairs Safari windows with extension windows only where each is the other's one candidate.
/// Two windows with the same tabs are told apart by their frames; if the frames don't settle it,
/// neither is paired. This never guesses: an unpaired window just keeps Safari's app icon.
/// `unreadFrames` are where Safari windows WinMux hasn't read are: any of them could be an
/// extension window's real twin. With one, a pairing also needs the candidate's frame, and no
/// unread window's, to agree with the extension window's; a window with no known frame could be
/// anywhere, so nothing pairs.
func safariExtensionPairs(_ candidates: [SafariExtensionCandidate], _ windows: [SafariExtensionWindow],
                          unreadFrames: [CGRect?] = []) -> [UInt32: SafariExtensionWindowKey] {
    var forward: [UInt32: [Int]] = [:]
    var backward: [Int: [Int]] = [:]
    for (index, candidate) in candidates.enumerated() {
        for (windowIndex, window) in windows.enumerated() where safariExtensionTabsAgree(candidate, window) {
            forward[candidate.snapshot.windowId, default: []].append(windowIndex)
            backward[windowIndex, default: []].append(index)
        }
    }
    var pairs: [UInt32: SafariExtensionWindowKey] = [:]
    for (index, candidate) in candidates.enumerated() {
        guard var mine = forward[candidate.snapshot.windowId] else { continue }
        if mine.count > 1 { mine = mine.filter { safariExtensionBoundsAgree(candidate.frame, windows[$0].bounds) } }
        guard mine.count == 1, var theirs = backward[mine[0]] else { continue }
        if theirs.count > 1 { theirs = theirs.filter { safariExtensionBoundsAgree(candidates[$0].frame, windows[mine[0]].bounds) } }
        let bounds = windows[mine[0]].bounds
        guard theirs == [index], unreadFrames.isEmpty || safariExtensionBoundsAgree(candidate.frame, bounds) &&
            unreadFrames.allSatisfy({ $0 != nil && !safariExtensionBoundsAgree($0, bounds) }) else { continue }
        pairs[candidate.snapshot.windowId] = windows[mine[0]].key
    }
    return pairs
}

/// Which extension tab describes each tab WinMux lists. A new pairing counts once a later
/// Accessibility read, at least 0.75 s on, still agrees, as the two report at different moments.
/// While some Safari window is unread, it also needs the frames to settle it; once counted,
/// a pairing holds on its tabs alone, as Safari's frames go stale when WinMux moves a window. A
/// paired window that briefly stops agreeing, such as while a title changes, keeps its icons for
/// a few seconds, but not its sound; a pairing with another window replaces it at once. Call
/// this only with new evidence: time passing without a read or report changes nothing.
struct SafariExtensionAssociations {
    static let confirmation: TimeInterval = 0.75
    static let grace: TimeInterval = 10
    private var pending: [UInt32: (key: SafariExtensionWindowKey, observed: TimeInterval)] = [:]
    private var confirmed: [UInt32: SafariExtensionWindowKey] = [:]
    private var lastAgreement: [UInt32: TimeInterval] = [:]
    private(set) var tabs: [BrowserTabTarget: SafariExtensionTab] = [:]
    /// Windows whose tabs agreed with the extension in the latest observation.
    private(set) var agreeing: Set<UInt32> = []
    /// Whether a window's tabs agree but it can't pair until Safari reports where its windows are now.
    private(set) var awaitsFrames = false

    mutating func update(_ candidates: [SafariExtensionCandidate], windows: [SafariExtensionWindow], unreadFrames: [CGRect?] = [],
                         now: TimeInterval) {
        let pairs = safariExtensionPairs(candidates, windows)
        let strict = unreadFrames.isEmpty ? pairs : safariExtensionPairs(candidates, windows, unreadFrames: unreadFrames)
        awaitsFrames = false
        let byKey = Dictionary(windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(candidates.map(\.snapshot.windowId))
        let alive = Set(candidates.flatMap { $0.snapshot.tabs.map(\.target) })
        tabs = tabs.filter { alive.contains($0.key) }
        pending = pending.filter { ids.contains($0.key) }
        confirmed = confirmed.filter { ids.contains($0.key) }
        lastAgreement = lastAgreement.filter { ids.contains($0.key) }
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
            for (tab, described) in zip(candidate.snapshot.tabs, window.tabs) { tabs[tab.target] = described }
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
        if agreeing.contains(tab.target.windowId) {
            tab.audio = described.flatMap { $0.isMuted ? .muted : $0.isAudible ? .playing : nil }
        }
        return tab
    }

    private mutating func forget(_ id: UInt32) {
        confirmed[id] = nil
        lastAgreement[id] = nil
        tabs = tabs.filter { $0.key.windowId != id }
    }
}
