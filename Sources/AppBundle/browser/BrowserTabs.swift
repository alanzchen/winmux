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
    /// From the WinMux Tabs Safari extension: the tab's website icon, by key, its host name,
    /// and whether it's playing sound or muted.
    var siteIcon: String? = nil
    var host: String? = nil
    var audio: BrowserTabAudio? = nil
    var id: UUID { target.tabId }
}

struct BrowserWindowTabs: Equatable, Sendable {
    let windowId: UInt32
    let pid: Int32
    let windowSession: UUID
    var tabs: [BrowserTab]
    var iconCandidate: BrowserTabIconCandidate? = nil

    var isGroup: Bool { tabs.count > 1 }
}

/// One read of a window's tab strip: its tabs, or none, and then whether it has no strip at all.
struct BrowserTabRead: Sendable {
    var tabs: BrowserWindowTabs?
    var hasNoTabStrip = false
}

/// Last complete reads survive short browser transitions, but not indefinite failures.
struct BrowserTabSnapshotCache {
    private(set) var snapshots: [UInt32: BrowserWindowTabs] = [:]
    /// When each window's snapshot was last read. Only a new read is new evidence about its tabs.
    private(set) var observed: [UInt32: TimeInterval] = [:]
    private var failedSince: [UInt32: TimeInterval] = [:]
    static let maximumAge: TimeInterval = 10

    mutating func receive(_ snapshot: BrowserWindowTabs, now: TimeInterval) {
        snapshots[snapshot.windowId] = snapshot
        observed[snapshot.windowId] = now
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

    mutating func watch(_ ids: Set<UInt32>) {
        for id in ids.subtracting(watched) { entries[id] = nil }
        watched = ids
    }

    mutating func focus(_ id: UInt32?) {
        guard id != focused else { return }
        focused = id
        if let id { entries[id] = nil }
    }

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
            : entry.dirty || id == focused ? 1 : 4
        return now - entry.lastRead >= interval
    }

    mutating func didRead(_ id: UInt32, now: TimeInterval, succeeded: Bool) {
        entries[id] = Entry(lastRead: now, failures: succeeded ? 0 : min(6, (entries[id]?.failures ?? 0) + 1),
            lastSuccess: succeeded ? now : entries[id]?.lastSuccess)
    }
}

func browserTabDisplayTitle(_ label: String) -> String {
    // Chrome adds localized resource diagnostics to the accessible name. Limit
    // cleanup to known suffix markers; punctuation in the actual title is kept.
    let markers = [" - Memory usage - ", " - 内存用量 - ", " - 記憶體用量 - ", " - Speichernutzung - "]
    for marker in markers {
        if let range = label.range(of: marker, options: .backwards), !label[range.upperBound...].isEmpty {
            return String(label[..<range.lowerBound])
        }
    }
    return label.isEmpty ? "Untitled tab" : label
}
