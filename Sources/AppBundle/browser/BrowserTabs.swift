import Foundation
import os

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
    /// What the sidebar asked of it that the browser hasn't yet been seen to do.
    var pending: BrowserTabPendingAction? = nil
    var id: UUID { target.tabId }
}

enum BrowserTabPendingAction: Hashable, Sendable {
    case selecting
    case closing
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
    /// Whether these are all the window's tabs, in its tab bar's order, so they stand one for one
    /// for the Safari extension's. Not while a Safari topic's tabs aren't all accounted for, as in
    /// a closed topic, nor while the tab bar holds a control that can't be told to be a tab or a
    /// topic's own button (`safariTabClustersAccountedFor`).
    var isComplete = true
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

/// The tab just chosen in the sidebar: shown as pending until the browser is seen to select it,
/// then as its window's selected tab. Only reads begun after that count: one that shows the tab
/// selected confirms it, and once the browser has had a moment to redraw its tab strip, any read
/// shows what's really selected. Reads begun sooner can still show a tab from before, even one an
/// earlier click chose, and would flash it back. A choice not sent shows the real selection.
///
/// A press the browser took, but that its tab wasn't seen to carry out in the press's own read-back,
/// stays pending while its window is read again, for `confirmationWindow`: Safari can show the
/// switch only later, as when its window is out of view until WinMux brings it forward. A read
/// begun since that shows the tab selected settles it as done. Otherwise the real selection shows
/// once that's over, and what to tell the user is handed back, for the latest click only. The tab
/// is known only as listed: one the browser lists afresh, even for the same page, isn't it.
struct BrowserTabPendingSelections {
    private struct Entry {
        let target: BrowserTabTarget
        let attempt: Int
        let since: TimeInterval
        var switched: TimeInterval? = nil
        var unconfirmed: Unconfirmed? = nil
    }
    /// A press taken but not yet seen done: when it came back, what to tell if it's never seen done,
    /// and what the reads since said of its tab, for the debug log.
    private struct Unconfirmed {
        let since: TimeInterval
        let notice: BrowserTabActionNotice?
        var reads = 0
        var listed: Bool? = nil
    }
    private var entries: [UInt32: Entry] = [:]
    private var attempts = 0
    static let lifetime: TimeInterval = 3
    static let redraw: TimeInterval = 1
    /// How long after a press came back taken but not seen done its window's reads may still see
    /// it done. The window is read again at once and then at each pass, a few times a second.
    static let confirmationWindow: TimeInterval = 1.5

    /// Each click is its own attempt, so a press it superseded can't settle it, even for the same tab.
    mutating func begin(_ target: BrowserTabTarget, now: TimeInterval) -> Int {
        attempts += 1
        entries[target.windowId] = Entry(target: target, attempt: attempts, since: now)
        return attempts
    }

    /// The press is over: `confirmed` if the browser was seen to select the tab. One that wasn't
    /// shows the real selection at once; otherwise reads decide.
    mutating func settle(attempt: Int, windowId: UInt32, confirmed: Bool, now: TimeInterval) {
        guard entries[windowId]?.attempt == attempt else { return }
        if confirmed { entries[windowId]?.switched = now } else { entries[windowId] = nil }
    }

    /// The press was taken but its tab wasn't seen selected: it stays pending while reads begun from
    /// `now` may still see it so, for `confirmationWindow`. `notice`: what to tell if none does.
    mutating func awaitConfirmation(attempt: Int, windowId: UInt32, now: TimeInterval, notice: BrowserTabActionNotice?) {
        guard entries[windowId]?.attempt == attempt else { return }
        entries[windowId]?.unconfirmed = .init(since: now, notice: notice)
    }

    /// Whether a press taken in this window is still waiting to be seen done.
    func awaitsConfirmation(_ windowId: UInt32) -> Bool { entries[windowId]?.unconfirmed != nil }

    /// Takes in a read. Returns how long after its press came back a read saw a press that its
    /// read-back didn't see done carried out after all; nil otherwise.
    @discardableResult
    mutating func observe(_ snapshot: BrowserWindowTabs, readStarted: TimeInterval) -> TimeInterval? {
        guard let entry = entries[snapshot.windowId] else { return nil }
        let confirmed = snapshot.tabs.contains { $0.target == entry.target && $0.isSelected }
        if var unconfirmed = entry.unconfirmed {
            guard readStarted >= unconfirmed.since else { return nil }
            guard !confirmed else {
                entries[snapshot.windowId] = nil
                return readStarted - unconfirmed.since
            }
            unconfirmed.reads += 1
            unconfirmed.listed = snapshot.tabs.contains { $0.target == entry.target }
            entries[snapshot.windowId]?.unconfirmed = unconfirmed
            return nil
        }
        guard let switched = entry.switched, readStarted >= switched else { return nil }
        if confirmed || readStarted - switched >= Self.redraw { entries[snapshot.windowId] = nil }
        return nil
    }

    /// Lets choices lapse: one unanswered for `lifetime`, and one taken but not seen done within
    /// `confirmationWindow` of its press coming back. Returns each of the latter, with what to tell
    /// only if it's the latest click's: one a later click overtook says nothing more.
    @discardableResult
    mutating func expire(now: TimeInterval) -> [BrowserTabUnconfirmedSelect] {
        var lapsed: [BrowserTabUnconfirmedSelect] = []
        entries = entries.filter { _, entry in
            guard let unconfirmed = entry.unconfirmed else { return now - entry.since < Self.lifetime }
            guard now - unconfirmed.since >= Self.confirmationWindow else { return true }
            lapsed.append(.init(notice: entry.attempt == attempts ? unconfirmed.notice : nil, reads: unconfirmed.reads, listed: unconfirmed.listed))
            return false
        }
        return lapsed
    }

    /// Forgets every choice shown, keeping the count of attempts, so a click from before can't settle one after.
    mutating func clear() { entries = [:] }

    func apply(_ snapshot: BrowserWindowTabs) -> BrowserWindowTabs {
        guard let entry = entries[snapshot.windowId], snapshot.tabs.contains(where: { $0.target == entry.target }) else { return snapshot }
        var snapshot = snapshot
        snapshot.tabs = snapshot.tabs.map { tab in
            var tab = tab
            if entry.switched == nil {
                if tab.target == entry.target { tab.pending = .selecting }
            } else {
                tab.isSelected = tab.target == entry.target
            }
            return tab
        }
        return snapshot
    }
}

/// A select taken but never seen done: what to tell, unless a later click overtook it, and, for the
/// debug log, how many reads looked and whether the last listed its tab.
struct BrowserTabUnconfirmedSelect: Equatable {
    let notice: BrowserTabActionNotice?
    let reads: Int
    let listed: Bool?
}

/// Tabs shown closing in the sidebar, each until its close comes back, a few seconds at most. A
/// tab leaves the list only once it's seen gone, or at the next read that no longer lists it. Only
/// what's shown: whether a close is under way is `BrowserTabCloseRequests`'s, and each close's
/// own attempt ends only its own spinner.
struct BrowserTabPendingCloses {
    private var entries: [BrowserTabTarget: (attempt: Int, since: TimeInterval)] = [:]
    static let lifetime: TimeInterval = 3

    mutating func show(_ target: BrowserTabTarget, attempt: Int, now: TimeInterval) { entries[target] = (attempt, now) }

    mutating func end(_ target: BrowserTabTarget, attempt: Int) {
        if entries[target]?.attempt == attempt { entries[target] = nil }
    }

    mutating func expire(now: TimeInterval) {
        entries = entries.filter { now - $0.value.since < Self.lifetime }
    }

    mutating func clear() { entries = [:] }

    func apply(_ snapshot: BrowserWindowTabs) -> BrowserWindowTabs {
        guard entries.keys.contains(where: { $0.windowId == snapshot.windowId }) else { return snapshot }
        var snapshot = snapshot
        snapshot.tabs = snapshot.tabs.map { tab in
            var tab = tab
            if entries[tab.target] != nil { tab.pending = .closing }
            return tab
        }
        return snapshot
    }
}

/// The sidebar's closes of browser tabs under way. A tab is asked to close once at a time, however
/// often its close is clicked meanwhile, from however stale a row, and however long its close takes
/// to come back: it's claimed until then, though its spinner may lapse sooner.
@MainActor
final class BrowserTabCloseRequests {
    private(set) var pending = BrowserTabPendingCloses()
    /// The closes under way, by tab, each until its own close comes back.
    private var inFlight: [BrowserTabTarget: Int] = [:]
    private var attempts = 0
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// Starts closing `target` with `perform`, then hands its result to `finished`, unless a close
    /// of it is already under way: then nil, and nothing is sent.
    func request(_ target: BrowserTabTarget, perform: @escaping @MainActor () async -> BrowserTabActionResult,
                 finished: @escaping @MainActor (BrowserTabActionResult) async -> Void) -> Task<Void, Never>? {
        guard inFlight[target] == nil else { return nil }
        attempts += 1
        let attempt = attempts
        inFlight[target] = attempt
        pending.show(target, attempt: attempt, now: clock())
        return Task { @MainActor [weak self] in
            let result = await perform()
            if self?.inFlight[target] == attempt { self?.inFlight[target] = nil }
            self?.pending.end(target, attempt: attempt)
            await finished(result)
        }
    }

    func isClosing(_ target: BrowserTabTarget) -> Bool { inFlight[target] != nil }
    func expire() { pending.expire(now: clock()) }
    /// As browser tabs are turned off: nothing is shown closing any more, but a close under way
    /// still holds its tab until it comes back, as nothing calls it off.
    func reset() { pending.clear() }
    func apply(_ snapshot: BrowserWindowTabs) -> BrowserWindowTabs { pending.apply(snapshot) }
}

/// What to tell the user about a browser tab action that didn't go as asked, and which sidebar
/// asked, if one did.
struct BrowserTabActionNotice: Equatable {
    let kind: BrowserTabActionKind
    let message: String
    var monitorScopeId: String? = nil
}

/// The sidebar's selects of browser tabs, as the model runs them. Each click cancels the one before
/// it, which then sends nothing it hasn't yet; the tab shows pending until its own answer comes,
/// and an answer settles only its own click (`BrowserTabPendingSelections`). What a select that
/// didn't go as asked tells the user goes to `notify`; a later click calls that off. A select the
/// browser took but wasn't seen to carry out says so only if the window's reads don't see it done
/// within `BrowserTabPendingSelections.confirmationWindow`; nothing is sent again meanwhile.
@MainActor
final class BrowserTabSelectRequests {
    private(set) var pending = BrowserTabPendingSelections()
    private var task: Task<Void, Never>?
    private let clock: () -> TimeInterval
    private let notify: @MainActor (BrowserTabActionNotice) -> Void
    private let log: (String) -> Void

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         notify: @escaping @MainActor (BrowserTabActionNotice) -> Void = { _ in },
         log: @escaping (String) -> Void = { browserTabActionLog.debug("\($0, privacy: .public)") }) {
        self.clock = clock
        self.notify = notify
        self.log = log
    }

    /// Whether `target` may be selected now: not while it's being closed (`closes`). Another click on
    /// a tab being selected is a new choice, the latest, which cancels the one before.
    func mayRequest(_ target: BrowserTabTarget, unlessClosing closes: BrowserTabCloseRequests) -> Bool {
        !closes.isClosing(target)
    }

    /// Cancels the select under way, if any: one that hasn't sent its press yet sends nothing.
    func cancel() { task?.cancel() }

    /// Selects `target` with `perform`, after cancelling the select before it, and hands the result
    /// to `finished` with whether a later click cancelled this one: nil, and nothing sent, while
    /// `target` may not be selected (`mayRequest`). `browser` names the browser in what the user
    /// is told; `monitorScopeId` is the sidebar that asked.
    @discardableResult
    func request(_ target: BrowserTabTarget, browser: String = "The browser", monitorScopeId: String? = nil,
                 unlessClosing closes: BrowserTabCloseRequests,
                 perform: @escaping @MainActor () async -> BrowserTabActionResult,
                 finished: @escaping @MainActor (_ result: BrowserTabActionResult, _ cancelled: Bool) async -> Void) -> Task<Void, Never>? {
        guard mayRequest(target, unlessClosing: closes) else { return nil }
        task?.cancel()
        let attempt = pending.begin(target, now: clock())
        let next = Task { @MainActor [weak self] in
            let result = await perform()
            let cancelled = Task.isCancelled
            if let self {
                let notice = cancelled ? nil : browserTabActionMessage(result, kind: .select, browser: browser)
                    .map { BrowserTabActionNotice(kind: .select, message: $0, monitorScopeId: monitorScopeId) }
                if result.isDispatched, result != .dispatched(.confirmed) {
                    // Taken, and maybe done: the window's next reads decide.
                    self.pending.awaitConfirmation(attempt: attempt, windowId: target.windowId, now: self.clock(), notice: notice)
                } else {
                    self.pending.settle(attempt: attempt, windowId: target.windowId, confirmed: result == .dispatched(.confirmed), now: self.clock())
                    if let notice { self.notify(notice) }
                }
            }
            await finished(result, cancelled)
        }
        task = next
        return next
    }

    func observe(_ snapshot: BrowserWindowTabs, readStarted: TimeInterval) {
        if let after = pending.observe(snapshot, readStarted: readStarted) {
            log("select followUp=confirmedByRead ms=\(Int((after * 1000).rounded()))")
        }
    }

    /// Whether a select taken in this window waits for its reads to see it done.
    func awaitsConfirmation(_ windowId: UInt32) -> Bool { pending.awaitsConfirmation(windowId) }

    func expire() {
        for lapsed in pending.expire(now: clock()) {
            log("select followUp=unconfirmed reads=\(lapsed.reads) target=\(lapsed.listed.map { $0 ? "listed" : "unlisted" } ?? "unread") " +
                "notice=\(lapsed.notice != nil)")
            if let notice = lapsed.notice { notify(notice) }
        }
    }
    /// As browser tabs are turned off: the select under way is cancelled, and nothing is shown
    /// pending; a select from before that comes back after settles nothing.
    func reset() {
        task?.cancel()
        pending.clear()
    }
    func apply(_ snapshot: BrowserWindowTabs) -> BrowserWindowTabs { pending.apply(snapshot) }
}

/// What the sidebar does once a select or close comes back, by what it did.
struct BrowserTabActionFollowUp: Equatable {
    /// Show the tab selected, or take it off the list, now: only once it's seen done.
    let applies: Bool
    /// Read the window again at once, as what happened isn't known, or the list is out of date.
    let rereads: Bool
    /// One short line to tell the user, never the tab's title; nil when it went as asked or a
    /// later action called it off.
    let message: String?

    init(_ result: BrowserTabActionResult, kind: BrowserTabActionKind, browser: String) {
        applies = result == .dispatched(.confirmed)
        rereads = !applies && result != .notDispatched(.cancelled)
        message = browserTabActionMessage(result, kind: kind, browser: browser)
    }
}

/// The line the sidebar shows when a select or close didn't go as asked, by why. Kept together
/// here, so they can be localized at once. Only what wasn't sent is told as not done, and only
/// that invites another try: what was sent may yet have happened, and the list is read again. A
/// select that was sent is told only once its window's reads have had their chance, so its line
/// doesn't say the list is being refreshed.
func browserTabActionMessage(_ result: BrowserTabActionResult, kind: BrowserTabActionKind, browser: String) -> String? {
    let select = kind == .select
    switch result {
        case .dispatched(.confirmed), .notDispatched(.cancelled):
            return nil
        case .notDispatched(.changed), .notDispatched(.unaccounted):
            return "This tab changed or moved in \(browser). The list is being refreshed; try again."
        case .notDispatched(.collapsedTopic):
            return "This tab is in a collapsed topic. Open the topic in \(browser) to \(select ? "switch to" : "close") it; " +
                "the sidebar can't do that yet."
        case .notDispatched(.noResponse):
            return "\(browser) didn't respond. Try again."
        case .notDispatched(.noAction), .notDispatched(.outOfView):
            return select ? "\(browser) didn't switch to this tab." : "\(browser) didn't offer a way to close this tab."
        case .dispatched(.unknown):
            return select ? "\(browser) couldn't confirm switching to this tab."
                : "\(browser) couldn't confirm closing this tab. The list is being refreshed."
        case .failed(.timedOut):
            return select ? "\(browser) didn't answer in time; the tab may still switch."
                : "\(browser) didn't answer in time; the tab may still close. The list is being refreshed."
        case .failed(.invalidElement), .failed(.unsupported), .failed(.other):
            return select ? "\(browser) reported an error switching to this tab."
                : "\(browser) reported an error closing this tab. The list is being refreshed."
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
    /// When something said each window's tabs changed: only a read begun since counts as reading
    /// them again, not one already under way.
    private var invalidated: [UInt32: TimeInterval] = [:]
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
        invalidated = invalidated.filter { ids.contains($0.key) }
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

    /// Reads the window again at once, and again after any read under way now.
    mutating func invalidate(_ id: UInt32, now: TimeInterval) {
        entries[id] = nil
        invalidated[id] = now
    }

    func lastRead(_ id: UInt32) -> TimeInterval { entries[id]?.lastRead ?? -.infinity }

    func isDue(_ id: UInt32, now: TimeInterval) -> Bool {
        guard watched.contains(id) else { return false }
        guard let entry = entries[id] else { return true }
        let interval: TimeInterval = entry.failures > 0 ? min(30, pow(2, Double(min(entry.failures - 1, 5))))
            : entry.dirty ? 1 : relaxed.contains(id) ? Self.relaxedInterval : id == focused ? 1 : 4
        return now - entry.lastRead >= interval
    }

    mutating func didRead(_ id: UInt32, now: TimeInterval, succeeded: Bool, started: TimeInterval? = nil) {
        entries[id] = Entry(lastRead: now, failures: succeeded ? 0 : min(6, (entries[id]?.failures ?? 0) + 1),
            lastSuccess: succeeded ? now : entries[id]?.lastSuccess)
        guard let since = invalidated[id] else { return }
        if succeeded, (started ?? now) >= since { invalidated[id] = nil } else if succeeded { entries[id]?.dirty = true; entries[id]?.lastRead = -.infinity }
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
