import Foundation

enum BrowserTabAdapter: Sendable {
    case safari
    case chromium

    init?(bundleId: String?) {
        switch bundleId {
            case "com.apple.Safari": self = .safari
            case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                 "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
                 "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary":
                self = .chromium
            default: return nil
        }
    }
}

/// Session-scoped references never stand in for macOS windows or layout nodes.
struct BrowserTabTarget: Hashable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let windowSession: UUID
    let tabId: UUID

    var rowId: String { "browser-tab:\(windowId):\(tabId)" }
}

enum BrowserTabAudio: Hashable, Sendable {
    case playing
    case muted
}

struct BrowserTab: Hashable, Identifiable, Sendable {
    let target: BrowserTabTarget
    var title: String
    var isSelected: Bool
    var iconOrigin: URL? = nil
    /// From the WinMux Tabs Safari extension: the tab's website icon, by key, and its host name.
    var siteIcon: String? = nil
    var host: String? = nil
    /// Which Safari tab the extension says this is. Selecting and closing never go by it: they
    /// act on the tab WinMux read through Accessibility.
    var extensionTab: SafariExtensionTabKey? = nil
    /// Whether it's playing sound or muted, as the Safari extension or a Chromium tab's
    /// accessible name says.
    var audio: BrowserTabAudio? = nil
    var id: UUID { target.tabId }
}

struct BrowserWindowTabs: Equatable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let windowSession: UUID
    var tabs: [BrowserTab]
    var iconCandidate: BrowserTabIconCandidate? = nil
    /// Whether every tab's sound is known, so a window with none playing is silent. Only the
    /// Safari extension says that. A Chromium tab's name says it plays sound, but one without
    /// that may still play: another alert, such as a camera recording, takes its place.
    var knowsSound = false
    /// What the WinMux Tabs extension's toolbar button in a Safari window named at the read, if
    /// anything: which extension window this is.
    var marker: SafariExtensionMarker? = nil

    var isGroup: Bool { tabs.count > 1 }
}

/// One read of a window's tab strip: its tabs, or none. A Safari window whose one tab hides the
/// tab bar is read as that tab, named by the window.
struct BrowserTabRead: Sendable {
    var tabs: BrowserWindowTabs?
    var loneTab: BrowserWindowTabs? = nil
}

/// Last complete reads survive short browser transitions, but not indefinite failures.
struct BrowserTabSnapshotCache {
    private(set) var snapshots: [UInt32: BrowserWindowTabs] = [:]
    /// When each window's snapshot was last read, and when that read began. Only a new read is new
    /// evidence about its tabs.
    private(set) var observed: [UInt32: TimeInterval] = [:]
    private(set) var readStarted: [UInt32: TimeInterval] = [:]
    private var failedSince: [UInt32: TimeInterval] = [:]
    static let maximumAge: TimeInterval = 10

    mutating func receive(_ snapshot: BrowserWindowTabs, now: TimeInterval, started: TimeInterval? = nil) {
        snapshots[snapshot.windowId] = snapshot
        observed[snapshot.windowId] = now
        readStarted[snapshot.windowId] = started ?? now
        failedSince[snapshot.windowId] = nil
    }

    mutating func recordFailure(windowId: UInt32, now: TimeInterval) {
        if failedSince[windowId] == nil { failedSince[windowId] = now }
    }

    mutating func reconcile(owners: [UInt32: Int32], now: TimeInterval) {
        snapshots = snapshots.filter { id, value in
            owners[id] == value.pid && now - (failedSince[id] ?? now) < Self.maximumAge
        }
        failedSince = failedSince.filter { snapshots[$0.key] != nil }
        observed = observed.filter { snapshots[$0.key] != nil }
        readStarted = readStarted.filter { snapshots[$0.key] != nil }
    }

    /// A tab the user just closed leaves the list before the next read confirms it.
    mutating func removeTab(_ target: BrowserTabTarget) {
        guard var snapshot = snapshots[target.windowId], snapshot.windowSession == target.windowSession else { return }
        snapshot.tabs.removeAll { $0.target == target }
        snapshots[target.windowId] = snapshot
    }

    mutating func clearIconMetadata() {
        for id in snapshots.keys {
            snapshots[id]?.iconCandidate = nil
            if let tabs = snapshots[id]?.tabs { snapshots[id]?.tabs = tabs.map { var tab = $0; tab.iconOrigin = nil; return tab } }
        }
    }
}

/// The tab just chosen in the sidebar, shown as its window's selected tab at once. Only reads begun
/// after its press count: one that shows the tab selected confirms it, and once the browser has
/// had a moment to redraw its tab strip, any read shows what's really selected. Reads begun sooner
/// can still show a tab from before, even one an earlier click chose, and would flash it back.
struct BrowserTabPendingSelections {
    private struct Entry {
        let target: BrowserTabTarget
        let attempt: Int
        let since: TimeInterval
        var switched: TimeInterval? = nil
    }
    private var entries: [UInt32: Entry] = [:]
    private var attempts = 0
    static let lifetime: TimeInterval = 3
    static let redraw: TimeInterval = 1

    /// Each click is its own attempt, so a press it superseded can't settle it, even for the same tab.
    mutating func begin(_ target: BrowserTabTarget, now: TimeInterval) -> Int {
        attempts += 1
        entries[target.windowId] = Entry(target: target, attempt: attempts, since: now)
        return attempts
    }

    /// The press is over. A refused one shows the real selection at once; otherwise reads decide.
    mutating func settle(attempt: Int, windowId: UInt32, refused: Bool, now: TimeInterval) {
        guard entries[windowId]?.attempt == attempt else { return }
        if refused { entries[windowId] = nil } else { entries[windowId]?.switched = now }
    }

    mutating func observe(_ snapshot: BrowserWindowTabs, readStarted: TimeInterval) {
        guard let entry = entries[snapshot.windowId], let switched = entry.switched, readStarted >= switched else { return }
        let confirmed = snapshot.tabs.contains { $0.target == entry.target && $0.isSelected }
        if confirmed || readStarted - switched >= Self.redraw { entries[snapshot.windowId] = nil }
    }

    mutating func expire(now: TimeInterval) {
        entries = entries.filter { now - $0.value.since < Self.lifetime }
    }

    func apply(_ snapshot: BrowserWindowTabs) -> BrowserWindowTabs {
        guard let entry = entries[snapshot.windowId], snapshot.tabs.contains(where: { $0.target == entry.target }) else { return snapshot }
        var snapshot = snapshot
        snapshot.tabs = snapshot.tabs.map { tab in
            var tab = tab
            tab.isSelected = tab.target == entry.target
            return tab
        }
        return snapshot
    }
}

/// Scheduling is independent of AX so hidden panels, retry backoff and noisy
/// notifications can be verified without querying any live browser.
struct BrowserTabReadSchedule {
    private struct Entry {
        var lastRead: TimeInterval
        var failures: Int
        var lastSuccess: TimeInterval?
        var dirty = false
    }
    private var entries: [UInt32: Entry] = [:]
    private(set) var watched: Set<UInt32> = []
    private var focused: UInt32?
    /// Windows something else says, at once, when their tabs change: read only now and then.
    private var relaxed: Set<UInt32> = []
    static let relaxedInterval: TimeInterval = 15

    mutating func watch(_ ids: Set<UInt32>) {
        for id in ids.subtracting(watched) { entries[id] = nil }
        watched = ids
    }

    mutating func focus(_ id: UInt32?) {
        guard id != focused else { return }
        focused = id
        if let id { entries[id] = nil }
    }

    mutating func relax(_ ids: Set<UInt32>) { relaxed = ids }

    mutating func retain(_ ids: Set<UInt32>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    mutating func markDirty(_ id: UInt32) {
        guard entries[id] != nil else { return }
        entries[id]?.dirty = true
        // A noisy unsupported window must not defeat exponential backoff. Recent
        // complete readers still react quickly to tab/selection notifications.
        if let entry = entries[id], let success = entry.lastSuccess, entry.lastRead - success < 10 {
            entries[id]?.failures = 0
        }
    }

    mutating func reset(_ id: UInt32) { entries[id] = nil }

    func lastRead(_ id: UInt32) -> TimeInterval { entries[id]?.lastRead ?? -.infinity }

    func isDue(_ id: UInt32, now: TimeInterval) -> Bool {
        guard watched.contains(id) else { return false }
        guard let entry = entries[id] else { return true }
        let interval: TimeInterval = entry.failures > 0 ? min(30, pow(2, Double(min(entry.failures - 1, 5))))
            : entry.dirty ? 1 : relaxed.contains(id) ? Self.relaxedInterval : id == focused ? 1 : 4
        return now - entry.lastRead >= interval
    }

    mutating func didRead(_ id: UInt32, now: TimeInterval, succeeded: Bool) {
        entries[id] = Entry(lastRead: now, failures: succeeded ? 0 : min(6, (entries[id]?.failures ?? 0) + 1),
            lastSuccess: succeeded ? now : entries[id]?.lastSuccess)
    }
}

/// A tab's title from the name the browser's tab strip gives it. Chromium adds the tab's sound to
/// the name, which this returns, and after that sometimes its memory use, in the browser's own
/// language; both come off. Safari names a tab by its title alone.
func browserTabLabel(_ label: String, adapter: BrowserTabAdapter) -> (title: String, audio: BrowserTabAudio?) {
    guard adapter == .chromium else { return (label.isEmpty ? "Untitled tab" : label, nil) }
    // Compared byte for byte: Chromium builds the name from exactly these strings, and this runs
    // for every tab at every read.
    var bytes = Array(label.utf8)[...]
    // The memory label wraps everything before it, so its marker is the last in the name.
    var memory: Range<Int>?
    for (prefix, marker, suffix) in chromiumMemoryLabelBytes where bytes.count > prefix.count + marker.count + suffix.count &&
        bytes.starts(with: prefix) && bytes.reversed().starts(with: suffix.reversed()) {
        let body = bytes[(bytes.startIndex + prefix.count)..<(bytes.endIndex - suffix.count)]
        guard let found = lastRange(of: marker, in: body), found.lowerBound > body.startIndex, found.upperBound < body.endIndex,
              found.lowerBound > memory?.upperBound ?? -1 else { continue }
        memory = body.startIndex..<found.lowerBound
    }
    if let memory { bytes = bytes[memory] }
    for (prefix, suffix, audio) in chromiumSoundLabelBytes where bytes.count > prefix.count + suffix.count &&
        bytes.reversed().starts(with: suffix.reversed()) && bytes.starts(with: prefix) {
        return (String(decoding: bytes.dropFirst(prefix.count).dropLast(suffix.count), as: UTF8.self), audio)
    }
    return (bytes.isEmpty ? "Untitled tab" : String(decoding: bytes, as: UTF8.self), nil)
}

private let chromiumSoundLabelBytes = chromiumTabMutedLabels.map { (Array($0.prefix.utf8), Array($0.suffix.utf8), BrowserTabAudio.muted) } +
    chromiumTabPlayingLabels.map { (Array($0.prefix.utf8), Array($0.suffix.utf8), BrowserTabAudio.playing) }
/// Also an older Chrome's German marker.
private let chromiumMemoryLabelBytes = (chromiumTabMemoryLabels + [.init(prefix: "", marker: " - Speichernutzung - ", suffix: "")])
    .map { (Array($0.prefix.utf8), Array($0.marker.utf8), Array($0.suffix.utf8)) }

private func lastRange(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Range<Int>? {
    guard let first = needle.first, haystack.count >= needle.count else { return nil }
    var start = haystack.endIndex - needle.count
    while start >= haystack.startIndex {
        if haystack[start] == first, haystack[start..<start + needle.count].elementsEqual(needle) { return start..<start + needle.count }
        start -= 1
    }
    return nil
}
