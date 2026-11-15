import AppKit

// A registered window is let go only on positive evidence that it closed. Failing to observe it is never evidence.
// `windowLivenessVerdict` is the whole decision, row by row; `refreshRegisteredAxWindows` gathers what it goes by, once
// per app and refresh; `WindowLivenessLedger` holds the result until the main actor accepts the refresh it came from.

/// A registered window as a refresh probes it: what its own AX query answers, and how many refreshes in a row the window
/// server hasn't listed it while its app was too busy to answer.
protocol RegisteredWindowLiveness: AnyObject {
    func containingWindowIdWithError() -> (windowId: CGWindowID?, error: AXError)
    var windowServerAbsences: Int { get set }
    /// When it was registered (`nextWindowLivenessStamp`): a window-server list taken before then says nothing of its
    /// absence (`WindowServerWindowList.evidence(for:registeredAt:)`).
    var livenessStamp: UInt64 { get }
}

extension RegisteredWindowLiveness {
    var livenessStamp: UInt64 { 0 }
}

private let windowLivenessStampLock = NSLock()
nonisolated(unsafe) private var windowLivenessStampValue: UInt64 = 0

/// The next of an ever-increasing count, for ordering a window's registration against a window-server list's reading,
/// on whichever threads they happen.
nonisolated func nextWindowLivenessStamp() -> UInt64 {
    windowLivenessStampLock.withLock {
        windowLivenessStampValue += 1
        return windowLivenessStampValue
    }
}

/// A busy app's window (its AX query timed out), missing from the window server's list on this many refreshes in a row,
/// is gone. One could be a list taken mid-change; a closed window's id doesn't come back. A first absence asks for the
/// refresh that confirms it (`RegisteredWindowsRefresh.asksForConfirmation`), so the second look doesn't wait on another
/// event.
let windowServerAbsencesToLetGo = 2

/// What the window server's snapshot says of one window.
enum WindowServerEvidence: Equatable {
    /// No snapshot to go by: none, an empty one, or one taken while the session is suspended (locked, switched away,
    /// asleep) or off the console (`WindowServerWindowList`, `windowServerWindowsForLiveness`).
    case unusable
    /// The snapshot doesn't list it.
    case absent
    /// Listed. `onShownSpace`: where the app's AXWindows covers it. On screen (so on a Space shown now, not minimized,
    /// not ordered out) in the refresh's list and again once the app's AXWindows was read, its app not hidden, and no
    /// Space switch under way. False when it's off screen (another Space, a full-screen Space not shown, minimized,
    /// hidden, ordered out) or when that isn't known.
    case listed(onShownSpace: Bool)
}

/// What the app's AXWindows says of one window, read in this refresh.
enum AppListingEvidence: Equatable {
    /// Not read: the read failed or timed out, or was skipped because the app was busy.
    case unread
    /// Read in full, and it doesn't name the window.
    case omits
    /// Read, and it names the window (one or more elements with its id).
    case names
}

enum WindowLivenessVerdict: Equatable {
    /// Still there, as it's registered.
    case keep
    /// Still there, but its element answers for nothing: no frame writes until a fresh one is taken (asked every refresh).
    case keepUnbound
    /// Its app lists it afresh: take a canonical fresh element; kept unbound if none can be taken.
    case rebind
    /// Closed.
    case drop
}

/// The decision for one registered window, from its own AX answer, its app's AXWindows, the window server's snapshot
/// (read only when it matters) and its busy absences so far. Returns the verdict and the absences to commit with it.
///
/// | Row | Own AX answer | App's AXWindows | Window server | Verdict | Absences |
/// |---|---|---|---|---|---|
/// | 1a | its id | any | listed or unusable | keep | 0 |
/// | 1b | its id | any | absent | **drop** (closed: evidence a, whatever element AX hands out for it) | 0 |
/// | 2a | busy | names it | not read | keep | 0 |
/// | 2b | gone | names it | not read | rebind | 0 |
/// | 3a | busy | omits or unread | unusable | keep | unchanged |
/// | 3b | gone | omits or unread | unusable | keep unbound | unchanged |
/// | 4 | gone | omits or unread | absent | **drop** (closed: evidence a) | 0 |
/// | 5 | busy | omits or unread | absent | **drop** at the 2nd absence in a row, else keep | +1 |
/// | 6 | busy | omits or unread | listed | keep | 0 |
/// | 7 | gone | omits | listed, covered (`onShownSpace`) | **drop** (closed: evidence b) | 0 |
/// | 8 | gone | unread | listed, covered | keep unbound | 0 |
/// | 9 | gone | omits or unread | listed, not covered | keep unbound | 0 |
///
/// "Gone" is any failure but a timeout (`registeredAxWindowAnswer`): a zero id, no value, an unsupported attribute, an
/// illegal argument, an invalid element. Behind the lock screen nothing is decided at all (`refreshRegisteredAxWindows`).
func windowLivenessVerdict(ax: RegisteredAxWindowAnswer, app: AppListingEvidence,
                           windowServer: @autoclosure () -> WindowServerEvidence, absences: Int)
    -> (verdict: WindowLivenessVerdict, absences: Int)
{
    if ax == .alive { return (windowServer() == .absent ? .drop : .keep, 0) }
    switch (ax, app) {
        case (.busy, .names): return (.keep, 0)
        case (.gone, .names): return (.rebind, 0)
        default: break
    }
    switch (ax, windowServer()) {
        case (.busy, .unusable): return (.keep, absences)
        case (_, .unusable): return (.keepUnbound, absences)
        case (.busy, .absent):
            let absences = absences + 1
            return (absences >= windowServerAbsencesToLetGo ? .drop : .keep, absences)
        case (_, .absent): return (.drop, 0)
        case (.busy, .listed): return (.keep, 0)
        case (_, .listed(onShownSpace: true)) where app == .omits: return (.drop, 0)
        case (_, .listed): return (.keepUnbound, 0)
    }
}

/// The window server's list of every window that exists in this session, with whether each is on screen, taken once per
/// refresh, shared by every app (and, for a window that may have closed on screen or one an app lists that it lacks,
/// read again: `readAgain`). It speaks only for windows registered before it was taken (`evidence(for:registeredAt:)`).
/// `.optionAll` lists windows that aren't on screen too: minimized ones, a hidden app's, ones on another Space or in a
/// full-screen Space, ordered-out ones. Its identity is the refresh's: what an app decided commits only with the refresh
/// that took this list (`WindowLivenessLedger`).
final class WindowServerWindowList: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    private var takenStamp: UInt64 = 0
    private var listed: [UInt32: Bool]?
    private let read: @Sendable () -> [UInt32: Bool]?
    private let sessionSuspended: Bool
    private let spaceSwitching: Bool
    private let orderedIn: @Sendable (UInt32) -> Bool?

    /// Window ids only: whether any is on screen, or ordered in, isn't known.
    init(read: @escaping @Sendable () -> Set<UInt32>?) {
        self.read = { read().map { Dictionary(uniqueKeysWithValues: $0.map { ($0, false) }) } }
        (sessionSuspended, spaceSwitching, orderedIn) = (false, false, { _ in nil })
    }

    /// Window ids, each with whether it's on screen. `sessionSuspended`: the session WinMux tracks as locked, switched
    /// away or asleep (`SavedWorkspaceRuntime.suspensions`): no list to go by at all. `spaceSwitching`: a Space switch is
    /// under way: no window counts as covered by its app's AXWindows. `orderedIn`: whether the window server has a
    /// window it lists ordered in (`windowServerIsOrderedIn`), nil when that isn't known.
    init(sessionSuspended: Bool = false, spaceSwitching: Bool = false,
         orderedIn: @escaping @Sendable (UInt32) -> Bool? = { windowServerIsOrderedIn($0) },
         readWindows: @escaping @Sendable () -> [UInt32: Bool]? = { windowServerWindowsForLiveness() })
    {
        self.read = readWindows
        (self.sessionSuspended, self.spaceSwitching, self.orderedIn) = (sessionSuspended, spaceSwitching, orderedIn)
    }

    /// Whether the window server lists `windowId` and has it ordered out: closed by an app that keeps it, minimized, or
    /// a hidden app's. False when it doesn't list it, or that isn't known (the private call unavailable).
    func listsOrderedOut(_ windowId: UInt32) -> Bool {
        guard case .listed = evidence(for: windowId) else { return false }
        return orderedIn(windowId) == false
    }

    private func snapshot() -> [UInt32: Bool]? {
        if sessionSuspended { return nil }
        lock.lock()
        defer { lock.unlock() }
        if !taken {
            takenStamp = nextWindowLivenessStamp()
            (listed, taken) = (read(), true)
        }
        guard let listed, !listed.isEmpty else { return nil }
        return listed
    }

    /// Whether the window server lists `windowId`; nil when there's no list to go by (none, or an empty one).
    func lists(_ windowId: UInt32) -> Bool? {
        snapshot().map { $0[windowId] != nil }
    }

    /// Takes the refresh's list now, if it isn't taken yet: before an app's AXWindows is read.
    func take() { _ = snapshot() }

    /// What the refresh's list says of `windowId`.
    func evidence(for windowId: UInt32) -> WindowServerEvidence {
        guard let snapshot = snapshot() else { return .unusable }
        return snapshot[windowId].map { .listed(onShownSpace: $0 && !spaceSwitching) } ?? .absent
    }

    /// What the refresh's list says of a window registered at `stamp`: its absence from a list taken before the window
    /// was registered says nothing (another app's refresh may have taken it before the window opened).
    func evidence(for windowId: UInt32, registeredAt stamp: UInt64) -> WindowServerEvidence {
        let evidence = evidence(for: windowId)
        guard evidence == .absent else { return evidence }
        lock.lock()
        defer { lock.unlock() }
        return stamp > takenStamp ? .unusable : .absent
    }

    /// Whether the refresh's list was taken after `stamp`. For a window an app listed at `stamp`, its listing in one taken
    /// before says nothing: the window may have closed since (the mirror of `evidence(for:registeredAt:)`).
    func wasTaken(after stamp: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return taken && takenStamp > stamp
    }

    /// A list taken now, for this caller alone; nil when there's none to go by.
    func readAgain() -> [UInt32: Bool]? {
        if sessionSuspended { return nil }
        guard let listed = read(), !listed.isEmpty else { return nil }
        return listed
    }
}

/// Every window the window server lists, of every app, with whether it's on screen (`kCGWindowIsOnscreen`: on a Space
/// shown now, and not ordered out). Nil when there's no list, or it isn't this user's to go by at the moment it's read:
/// the session isn't on the console (another user switched in), or its screen is locked. (`SavedWorkspaceRuntime` tracks
/// the same from notifications, which reach the main actor later than an app's thread reads this.)
nonisolated func windowServerWindowsForLiveness(
    session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any],
    windows: [[String: Any]]? = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
) -> [UInt32: Bool]? {
    guard let session, session[kCGSessionOnConsoleKey as String] as? Bool == true,
          session["CGSSessionScreenIsLocked"] as? Bool != true,
          let windows
    else { return nil }
    var listed: [UInt32: Bool] = [:]
    for window in windows {
        guard let windowId = window[kCGWindowNumber as String] as? UInt32 else { continue }
        listed[windowId] = window[kCGWindowIsOnscreen as String] as? Bool == true
    }
    return listed
}

/// The same, window ids only.
nonisolated func windowServerWindowIdsForLiveness(
    session: [String: Any]? = CGSessionCopyCurrentDictionary() as? [String: Any],
    windows: [[String: Any]]? = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
) -> Set<UInt32>? {
    windowServerWindowsForLiveness(session: session, windows: windows).map { Set($0.keys) }
}

/// One app's refresh of its registered windows, decided and not yet committed.
struct RegisteredWindowsRefresh<W: RegisteredWindowLiveness> {
    /// The windows kept (unbound ones too), under the elements they're kept with, and those registered new.
    let alive: [UInt32: W]
    /// The windows that closed.
    let dead: [UInt32: W]
    /// Kept, with an element that answers for nothing: no frame writes until a fresh one is taken.
    let unbound: Set<UInt32>
    /// A busy app's window the window server missed for the first time: a refresh to confirm it is due.
    let asksForConfirmation: Bool
    /// Kept, unbound, while the window server still lists it: its element answers for nothing and its app's list doesn't
    /// show it. A window closing (the window server goes on listing a closed window for a while), one hidden on close,
    /// or one on a Space its app's list doesn't cover. Looked at again (`WindowLivenessRecheck`).
    let awaitsWindowServer: Set<UInt32>
    /// A window was let go while the window server still listed it: a new series of looks again starts, whatever ran
    /// before (`WindowLivenessRecheck`).
    let startsRecheckSeries: Bool
    /// Whether windows can be shown, for those it could tell (`noteWindowPresentability`): not one the window server has
    /// ordered out while its element answers for nothing and no fresh one was taken. Shown: one AX resolves, one
    /// rebound, one its app lists, or with no ordering known. Not said (each stays as it was): a busy app's window, a
    /// hidden app's, one with no window list to go by, or one the list read after its app's lost.
    let presentable: [UInt32: Bool]
    /// The registered windows it decided on, as they were registered.
    fileprivate let seen: [UInt32: W]
    fileprivate let absences: [(window: W, absences: Int)]

    /// What it counted takes effect: the busy absences.
    func commit() {
        for (window, count) in absences { window.windowServerAbsences = count }
    }

    /// `registry` as it is when the refresh commits, with what it decided: only windows it saw change. One registered
    /// since (on focus) stays; one unregistered since (closed from WinMux) stays out.
    func applied(to registry: [UInt32: W]) -> [UInt32: W] {
        var next = registry
        for (windowId, window) in seen where next[windowId] === window {
            next[windowId] = alive[windowId]
        }
        for (windowId, window) in alive where seen[windowId] == nil && next[windowId] == nil {
            next[windowId] = window
        }
        return next
    }
}

/// The verdicts for an app's registered windows without reading its AXWindows (every window's app evidence unread).
func reconcileRegisteredWindows<W: RegisteredWindowLiveness>(
    _ windows: [UInt32: W], frontmostAppBundleId: String?, windowServer: WindowServerWindowList, _ job: RunLoopJob,
) throws -> (alive: [UInt32: W], dead: [UInt32: W]) {
    let refreshed = try refreshRegisteredAxWindows(windows, frontmostAppBundleId: frontmostAppBundleId, windowServer: windowServer,
        listed: { nil as [(UInt32, W)]? }, rebind: { _, _ in nil }, register: { _, _, _ in }, job)
    return (refreshed.alive, refreshed.dead)
}

/// One app's refresh of its registered windows, on its AX thread. Each window's own AX answer; then the windows the app
/// lists now (`listed`: nil when it couldn't be read in full, and not read at all once the app proved busy); then
/// `windowLivenessVerdict` for each. A window to rebind takes the first fresh element its app lists that `rebind`
/// accepts (a canonical window, not a sheet or proxy with its id); none accepted, it's kept unbound. Listed windows not
/// registered are registered as new (`register`) if the window server had them after their app listed them (`admits`):
/// a window let go earlier that its app lists again comes back as a new window, so no live window is ever shut out. An element an app hands out for a window that did close (Slack can,
/// while the window server lags the close) makes a short-lived ghost: row 1b lets it go once the window server no
/// longer lists it, and a window let go while still listed asks for looks again soon (`startsRecheckSeries`).
/// `appHidden`: its windows aren't covered by its AXWindows, nor is it told whether they can be shown. `setAside`: its windows
/// set aside as not presentable; one found back on screen isn't taken as covered either, as an app that shows a window
/// again may list it only a moment later: it comes back, and is judged with the rest from the next refresh. Decides
/// only: nothing is committed (`RegisteredWindowsRefresh.commit`, `WindowLivenessLedger`), and cancelled at any point,
/// it throws.
func refreshRegisteredAxWindows<W: RegisteredWindowLiveness, Element>(
    _ registered: [UInt32: W], frontmostAppBundleId: String?, windowServer: WindowServerWindowList,
    listed: () -> [(UInt32, Element)]?, rebind: (_ stale: W, _ fresh: Element) throws -> W?,
    register: (_ alive: inout [UInt32: W], _ windowId: UInt32, _ element: Element) throws -> Void,
    appHidden: Bool = false, setAside: Set<UInt32> = [], _ job: RunLoopJob,
) throws -> RegisteredWindowsRefresh<W> {
    // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
    // Second and third lines of defence are technically needed only to avoid potential flickering
    let lockScreenInFront = frontmostAppBundleId == lockScreenAppBundleId

    // Each window's own answer. Once one times out the app is busy: the rest aren't asked (each could take the whole
    // timeout, and two exceed the app's refresh deadline), nor is its AXWindows.
    var answers: [UInt32: RegisteredAxWindowAnswer] = [:]
    var busy = false
    if !lockScreenInFront {
        for (windowId, window) in registered {
            try job.checkCancellation()
            if busy {
                answers[windowId] = .busy
                continue
            }
            let (resolvedId, error) = window.containingWindowIdWithError()
            if error != .success { AxWindowErrorLog.shared.record(windowId: windowId, error: error) }
            let answer = registeredAxWindowAnswer(windowId: resolvedId, error: error)
            answers[windowId] = answer
            busy = answer == .busy
        }
    }
    // A window AX can't resolve and its app doesn't list may have closed on screen: the window server is asked whether
    // it's on screen before the app's AXWindows is read, and again after, so neither a Space switch nor a lock in
    // between makes the list look like it left the window out.
    if answers.values.contains(.gone) { windowServer.take() }
    let listing: [(UInt32, Element)]? = busy ? nil : listed()
    let listedAt = nextWindowLivenessStamp()
    try job.checkCancellation()
    var named: [UInt32: [Element]] = [:]
    for (windowId, element) in listing ?? [] { named[windowId, default: []].append(element) }
    var listedAfter: [UInt32: Bool]?
    var readAfter = false
    func windowServerEvidence(_ windowId: UInt32, _ answer: RegisteredAxWindowAnswer, _ stamp: UInt64) -> WindowServerEvidence {
        let before = windowServer.evidence(for: windowId, registeredAt: stamp)
        guard answer == .gone, listing != nil, before == .listed(onShownSpace: true) else { return before }
        if appHidden || setAside.contains(windowId) { return .listed(onShownSpace: false) }
        if !readAfter { (listedAfter, readAfter) = (windowServer.readAgain(), true) }
        return .listed(onShownSpace: listedAfter?[windowId] == true)
    }

    var alive: [UInt32: W] = [:]
    var dead: [UInt32: W] = [:]
    var unbound: Set<UInt32> = []
    var awaitsWindowServer: Set<UInt32> = []
    var startsRecheckSeries = false
    var presentable: [UInt32: Bool] = [:]
    var absences: [(window: W, absences: Int)] = []
    var firstAbsence = false
    for (windowId, window) in registered {
        try job.checkCancellation()
        guard let answer = answers[windowId] else {
            alive[windowId] = window
            continue
        }
        let app: AppListingEvidence = listing == nil ? .unread : named[windowId] == nil ? .omits : .names
        let decided = windowLivenessVerdict(ax: answer, app: app,
            windowServer: windowServerEvidence(windowId, answer, window.livenessStamp), absences: window.windowServerAbsences)
        if decided.absences != window.windowServerAbsences {
            absences.append((window, decided.absences))
            if window.windowServerAbsences == 0 && decided.absences == 1 { firstAbsence = true }
        }
        switch decided.verdict {
            case .keep:
                alive[windowId] = window
                if answer == .alive { presentable[windowId] = true }
            case .keepUnbound:
                alive[windowId] = window
                unbound.insert(windowId)
                if case .listed = windowServer.evidence(for: windowId) {
                    awaitsWindowServer.insert(windowId)
                    // Whether it can be shown isn't told while its app is hidden (all its windows are ordered out
                    // then), nor when the list read after its app's went (locked) or lost it: it stays as it was.
                    let lostAfterTheList = readAfter && listedAfter?[windowId] == nil
                    if !appHidden && !lostAfterTheList { presentable[windowId] = !windowServer.listsOrderedOut(windowId) }
                }
            case .drop:
                dead[windowId] = window
                // Let go while the window server lists it (row 7, while it lags the close): looked at again soon, so a
                // ghost an element for it might bring back goes as soon as the window server lets it go too.
                if case .listed = windowServer.evidence(for: windowId) {
                    awaitsWindowServer.insert(windowId)
                    startsRecheckSeries = true
                }
            case .rebind:
                presentable[windowId] = true
                var rebound: W?
                for candidate in named[windowId] ?? [] {
                    if let fresh = try rebind(window, candidate) {
                        rebound = fresh
                        break
                    }
                }
                if let rebound {
                    alive[windowId] = rebound
                } else {
                    alive[windowId] = window
                    unbound.insert(windowId)
                }
        }
    }
    // One the window server didn't have after its app's AXWindows was read isn't a window: an element handed out for one
    // that closed, perhaps after the refresh's list was taken (by another app's refresh) while it still had it. The list
    // read after it for this app decides; else the refresh's if taken since and it has the window (it may be older than
    // a window just opened, so absent from it, one read now decides); else one read now. With none to go by, it's taken.
    func admits(_ windowId: UInt32) -> Bool {
        if !readAfter {
            switch windowServer.evidence(for: windowId) {
                case .unusable: return true
                case .listed where windowServer.wasTaken(after: listedAt): return true
                case .listed, .absent: (listedAfter, readAfter) = (windowServer.readAgain(), true)
            }
        }
        return listedAfter.map { $0[windowId] != nil } ?? true
    }
    for (windowId, element) in listing ?? [] where registered[windowId] == nil {
        try job.checkCancellation()
        if !admits(windowId) { continue }
        try register(&alive, windowId, element)
    }

    try job.checkCancellation()
    return RegisteredWindowsRefresh(alive: alive, dead: dead, unbound: unbound, asksForConfirmation: firstAbsence,
        awaitsWindowServer: awaitsWindowServer, startsRecheckSeries: startsRecheckSeries, presentable: presentable,
        seen: registered, absences: absences)
}

/// One app's liveness decision on its AX thread, held (`hold`) until the main actor accepts the refresh it came from as
/// still current (`commit`): a refresh cancelled, superseded or past its app's deadline commits nothing, neither the
/// windows it let go nor the absences it counted.
struct WindowLivenessLedger<W: RegisteredWindowLiveness> {
    private var held: (refresh: WindowServerWindowList, decided: RegisteredWindowsRefresh<W>)?

    mutating func hold(_ decided: RegisteredWindowsRefresh<W>, of refresh: WindowServerWindowList) {
        held = (refresh, decided)
    }

    /// What `refresh` decided, now in effect, if it's the refresh held; nil (nothing changes) for any other.
    mutating func commit(_ refresh: WindowServerWindowList) -> RegisteredWindowsRefresh<W>? {
        guard let held, held.refresh === refresh else { return nil }
        self.held = nil
        held.decided.commit()
        return held.decided
    }
}

/// Looks again, to see a close sooner (nothing depends on them otherwise): at 0.5, 1, 2, 4 and 8 s. A window let go
/// while the window server still listed it starts a new series (`RegisteredWindowsRefresh.startsRecheckSeries`), run to
/// its end, so a ghost an element brought back goes soon after the window server lets it go. Windows kept while the
/// window server lists them (`awaitsWindowServer`) are looked at the same way while they wait, a newly waiting one
/// starting the series over; not forever, as a window hidden on close stays listed. A refresh between looks doesn't
/// spend one: the next is scheduled only once the last is due.
struct WindowLivenessRecheck {
    static let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    private(set) var awaiting: Set<UInt32> = []
    private(set) var attempt = 0
    /// When the look scheduled last is due (system uptime).
    private var dueAt: TimeInterval?
    private var followsDrop = false

    /// After a committed refresh at `time`, with the windows it left waiting and whether it let a listed window go: how
    /// long until the next look, if one is due now.
    mutating func next(awaiting now: Set<UInt32>, startsSeries: Bool = false,
                       at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Duration?
    {
        if startsSeries || !now.isSubset(of: awaiting) {
            (attempt, dueAt) = (0, nil)
            followsDrop = followsDrop || startsSeries
        }
        awaiting = now
        if let dueAt, time + 0.05 < dueAt { return nil }
        guard followsDrop || !now.isEmpty, attempt < Self.delays.count else {
            (dueAt, followsDrop) = (nil, false)
            return nil
        }
        let delay = Self.delays[attempt]
        attempt += 1
        dueAt = time + Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        return delay
    }
}
