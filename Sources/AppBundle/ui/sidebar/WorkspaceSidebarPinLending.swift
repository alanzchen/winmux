import AppKit
import Common

// Tabs mode: a pin with one window is the entry to that window alone. A move that would put another
// window in with it, from the sidebar, the screen, a command or the agent API, puts the two in an
// ordinary tab instead, and the pin lends its window there, showing grey until a click on it brings
// that same window back. A pinned split is made only from a split tab's menu, with Pin. It keeps the
// windows it was made with in their places, as far as they're still there. Alan, October 8: it takes
// more windows and stays a pinned split; a window of it dragged out stays its own, and comes back to
// its place when it's clicked; a window hidden with its app is shown first, and one in full screen is
// only found, never split or taken out of full screen.

// MARK: Window identity

/// The boot WinMux runs in. A window number and process seen in another boot are another window.
@MainActor var workspaceSidebarBootTime: () -> Date? = { workspaceSidebarCurrentBoot }

/// Read once: it doesn't change while WinMux runs.
private let workspaceSidebarCurrentBoot = workspaceSidebarSystemBootTime()

/// A process's app and launch, while it runs: what tells it from a later process given the same number.
@MainActor var workspaceSidebarRunningProcess: (Int32) -> (bundleId: String?, launch: Date?)? = { pid in
    NSRunningApplication(processIdentifier: pid).map { ($0.bundleIdentifier, $0.launchDate) }
}

private func workspaceSidebarSystemBootTime() -> Date? {
    var mib = [CTL_KERN, KERN_BOOTTIME]
    var time = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
}

private func workspaceSidebarSameInstant(_ a: Date?, _ b: Date?) -> Bool {
    switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): abs(a.timeIntervalSince(b)) < 0.001
        default: false
    }
}

extension WorkspaceSidebarPinWindow {
    @MainActor
    init(_ window: Window) {
        self.init(windowId: window.windowId, pid: window.app.pid, bundleId: window.app.rawAppBundleId,
            processLaunch: window.app.launchDate, boot: workspaceSidebarBootTime())
    }

    /// The window, if it's still this one: open, in the same process of the same app, launched when
    /// it was, in the same boot.
    @MainActor
    var live: Window? {
        guard let window = Window.get(byId: windowId), window.app.pid == pid, window.app.rawAppBundleId == bundleId,
              workspaceSidebarSameInstant(window.app.launchDate, processLaunch),
              workspaceSidebarSameInstant(workspaceSidebarBootTime(), boot) else { return nil }
        return window
    }

    /// Whether it may still be open as WinMux starts again: the same boot, and its process still
    /// running, the same app, launched when it was. Its window may not be seen yet.
    @MainActor
    var mayStillBeOpen: Bool {
        guard workspaceSidebarSameInstant(workspaceSidebarBootTime(), boot),
              let process = workspaceSidebarRunningProcess(pid) else { return false }
        return process.bundleId == bundleId && workspaceSidebarSameInstant(process.launch, processLaunch)
    }
}

extension WorkspaceSidebarItemAppearance {
    /// Forgets the windows `gone` names: lent, away from a pinned split, or in its layout.
    mutating func forgetPinWindows(where gone: (WorkspaceSidebarPinWindow) -> Bool) {
        if let lent = lentWindow, gone(lent) { lentWindow = nil }
        guard var composition else { return }
        composition.away.removeAll { gone($0.window) }
        // Its last window gone, it's still a pinned split, with none.
        composition.layout = composition.layout.removing(where: gone) ?? .empty
        self.composition = composition
    }

    fileprivate func mentionsPinWindow(where gone: (WorkspaceSidebarPinWindow) -> Bool) -> Bool {
        lentWindow.map(gone) == true || composition.map { $0.away.contains { gone($0.window) } || $0.layout.contains(where: gone) } == true
    }
}

/// A window closed, or every window of a process that ended: no pin lends it, and no pinned split
/// brings it back, ever again.
@MainActor
func forgetWorkspaceSidebarPinWindows(where gone: (WorkspaceSidebarPinWindow) -> Bool) {
    let store = workspaceSidebarOrganizationStore
    guard store.readOnlyReason == nil, store.state.workspaces.values.contains(where: { $0.mentionsPinWindow(where: gone) })
    else { return }
    try? store.update { state in
        for name in Array(state.workspaces.keys) { state.workspaces[name]?.forgetPinWindows(where: gone) }
    }
}

/// As WinMux starts: the windows pins lent, and pinned splits' windows, whose process isn't the one
/// that had them any more, after a reboot or the app quitting, are forgotten. Those that may still be
/// open stay, until their window is seen or closes.
@MainActor
func forgetWorkspaceSidebarPinWindowsNoLongerOpen() {
    forgetWorkspaceSidebarPinWindows { !$0.mayStillBeOpen }
}

// MARK: Pins' part in a move

@MainActor
func workspaceSidebarIsPinned(_ workspace: Workspace) -> Bool {
    workspaceSidebarOrganizationStore.state.workspaces[workspace.name]?.isFavorite == true
}

/// The window `pin` lent to another tab's split, while it's there: not closed, and not back in the pin.
@MainActor
func workspaceSidebarLentWindow(of pin: Workspace) -> Window? {
    guard config.usesBrowserTabs, let appearance = workspaceSidebarOrganizationStore.state.workspaces[pin.name],
          appearance.isFavorite, let window = appearance.lentWindow?.live, window.nodeWorkspace !== pin else { return nil }
    return window
}

/// What a move does with a pin it's made with.
enum WorkspaceSidebarPinSplitRole: Equatable {
    /// No window, and none lent: it takes one dropped window in, as it always has.
    case empty
    /// One window, laid out: a split with it goes to an ordinary tab with that window, which the pin lends.
    case single(Window)
    /// One window, hidden with its app: shown again first, it's a pin with one window (Alan, October 8).
    case hidden(Window)
    /// One window, in macOS full screen: found where it is, never split, and never taken out of full
    /// screen; the user leaves full screen first (Alan, October 8).
    case fullscreen(Window)
    /// A pinned split, whatever windows it has now: windows dropped on it go into it, and it stays a
    /// pinned split (Alan, October 8).
    case composition
    /// Its window lent to another tab, or windows it wasn't pinned with: no window in, and no split.
    case refuses

    /// The one window of a pin that has one, laid out.
    var window: Window? { if case .single(let window) = self { window } else { nil } }

    /// The one window of a pin that has one, laid out or hidden with its app: what a split shown with the
    /// pin is made with, the window shown again first.
    var oneWindow: Window? {
        switch self {
            case .single(let window), .hidden(let window): window
            default: nil
        }
    }
}

@MainActor
func workspaceSidebarPinSplitRole(_ pin: Workspace) -> WorkspaceSidebarPinSplitRole {
    let state = workspaceSidebarOrganizationStore.state
    if state.workspaces[pin.name]?.composition != nil { return .composition }
    let windows = pin.allLeafWindowsRecursive
    if windows.isEmpty { return workspaceSidebarLentWindow(of: pin) == nil ? .empty : .refuses }
    let tiled = windows.filter { $0.parent is TilingContainer }
    // A pinned split from before they were recorded, until it is: then only the record says.
    if state.pinnedSplitsRecorded != true, tiled.count > 1 { return .composition }
    guard windows.count == 1, let window = windows.first else { return .refuses }
    return switch window.parent {
        case is TilingContainer: .single(window)
        case is MacosHiddenAppsWindowsContainer: .hidden(window)
        case is MacosFullscreenWindowsContainer: .fullscreen(window)
        default: .refuses
    }
}

/// A tab's part in a move as it was at a release: what a drop on it did then, with which window.
enum WorkspaceSidebarPinRoleSnapshot: Hashable {
    /// Not a pin: a drop goes into it, as into any tab.
    case ordinary
    case empty
    /// A pin with one window, laid out or hidden with its app, which one.
    case single(WorkspaceSidebarPinWindow)
    case composition
    case refuses
}

@MainActor
func workspaceSidebarPinRoleSnapshot(_ workspace: Workspace) -> WorkspaceSidebarPinRoleSnapshot {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(workspace) else { return .ordinary }
    return switch workspaceSidebarPinSplitRole(workspace) {
        case .empty: .empty
        // Shown again before the drop is made, it's still the same pin with the same window.
        case .single(let window), .hidden(let window): .single(.init(window))
        case .composition: .composition
        case .fullscreen, .refuses: .refuses
    }
}

/// Whether a split may be armed over `workspace`: any tab, an empty pin, a pin with one window, laid out
/// or hidden, or a pinned split.
@MainActor
func workspaceSidebarTakesSplit(_ workspace: Workspace) -> Bool {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(workspace) else { return true }
    return switch workspaceSidebarPinSplitRole(workspace) {
        case .empty, .single, .hidden, .composition: true
        case .fullscreen, .refuses: false
    }
}

/// Whether the user may move `node` into `target`, from the sidebar, the screen, a command or the agent
/// API: into any tab but a pin that takes no window, and into an empty pin only one window. A pinned
/// split takes any. A pin whose one window is hidden takes one only `showingHidden`: where the move
/// shows that window again first (`showWorkspaceSidebarPinsForSplit`). Previews offer exactly this; the
/// move checks it again.
@MainActor
func workspaceSidebarPinPolicyAllows(_ node: TreeNode, into target: Workspace, showingHidden: Bool = false) -> Bool {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(target), node.nodeWorkspace !== target else { return true }
    return switch workspaceSidebarPinSplitRole(target) {
        case .single, .composition: true
        case .hidden: showingHidden
        case .empty: node.allLeafWindowsRecursive.count == 1
        case .fullscreen, .refuses: false
    }
}

/// Windows swapped between two tabs: never with a pin with one window, whose window it stands for would
/// change; a pinned split's windows may be swapped, as it may be changed.
@MainActor
func workspaceSidebarPinPolicyAllowsSwap(_ a: Workspace?, _ b: Workspace?) -> Bool {
    guard config.usesBrowserTabs, let a, let b, a !== b else { return true }
    return [a, b].allSatisfy { !workspaceSidebarIsPinned($0) || workspaceSidebarPinSplitRole($0) == .composition }
}

/// Thrown by a move that didn't happen after all, so everything before it in its transaction goes back.
struct WorkspaceSidebarMoveDidNotHappen: Error {}

/// A move the pins' policy refuses, from the command line or the agent API, said plainly.
struct WorkspaceSidebarPinPolicyRefusal: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A pin with one window whose window a user's move takes out of it, as it was before the move.
struct WorkspaceSidebarPinLoan {
    let pin: Workspace
    let window: Window
}

/// Before the user moves `node` out of its tab, to `target` if it's known: the pin with one window it
/// takes that window from.
@MainActor
func workspaceSidebarPinLoan(taking node: TreeNode, to target: Workspace? = nil) -> WorkspaceSidebarPinLoan? {
    guard config.usesBrowserTabs, let pin = node.nodeWorkspace, pin !== target, workspaceSidebarIsPinned(pin),
          let window = workspaceSidebarPinSplitRole(pin).window, node.allLeafWindowsRecursive.contains(where: { $0 === window })
    else { return nil }
    return .init(pin: pin, window: window)
}

/// After the move: the pin lends its window, if it went to an ordinary tab or a pinned split. A window
/// moved into an empty pin is that pin's now.
@MainActor
func completeWorkspaceSidebarPinLoan(_ loan: WorkspaceSidebarPinLoan?) throws {
    guard let loan, let now = loan.window.nodeWorkspace, now !== loan.pin,
          !workspaceSidebarIsPinned(now) || workspaceSidebarPinSplitRole(now) == .composition else { return }
    try lendWorkspaceSidebarPinWindow(loan.window, from: loan.pin)
}

@MainActor
private func lendWorkspaceSidebarPinWindow(_ window: Window, from pin: Workspace) throws {
    try workspaceSidebarOrganizationStore.update { $0.workspaces[pin.name, default: .init()].lentWindow = .init(window) }
}

/// The tab `node` goes to, moved into `target`: `target`, unless it's a pin with one window. Then its
/// window and `node` go to an ordinary tab: the one `node` is the whole of, else a new one after it,
/// or after the pin when `node` isn't from an ordinary tab, on `newTabMonitor` if given; and the pin
/// lends its window there. Runs inside a drop transaction.
@MainActor
private func workspaceSidebarSplitDestination(for node: TreeNode, onto target: Workspace, newTabMonitor: Monitor?) throws -> Workspace {
    guard workspaceSidebarIsPinned(target), let targetWindow = workspaceSidebarPinSplitRole(target).window else { return target }
    let source = node.nodeWorkspace
    let ordinarySource = source.flatMap { workspaceSidebarIsPinned($0) ? nil : $0 }
    let destination: Workspace
    if let ordinarySource, !workspaceTabDragLeavesWindowsBehind(node) {
        destination = ordinarySource
    } else {
        let anchor = ordinarySource ?? target
        destination = createWorkspace(after: anchor, projectId: workspaceContextProjectId(of: anchor),
            monitor: newTabMonitor ?? anchor.workspaceMonitor)
    }
    targetWindow.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    try lendWorkspaceSidebarPinWindow(targetWindow, from: target)
    return destination
}

/// Moves `node` into `target` by `move`, which is given the tab it goes to, keeping every pin with one
/// window the entry to that window alone, as `workspaceSidebarSplitDestination` and the pin loans say.
/// Gives false, changing nothing, where the policy refuses. If any of it can't be done, nothing changes.
@MainActor
@discardableResult
func moveWorkspaceSidebarNodeKeepingPins(_ node: TreeNode, onto target: Workspace, newTabMonitor: Monitor? = nil,
                                        _ move: (Workspace) throws -> Void) throws -> Bool {
    guard config.usesBrowserTabs else {
        try move(target)
        return true
    }
    // The pinned splits it's moved out of or into keep track of their windows, saved first.
    try saveWorkspaceSidebarPinCompositions(of: [node.nodeWorkspace, target].compactMap { $0 })
    guard workspaceSidebarPinPolicyAllows(node, into: target) else { return false }
    let loan = workspaceSidebarPinLoan(taking: node, to: target)
    return try withWorkspaceSidebarDropTransaction {
        let destination = try workspaceSidebarSplitDestination(for: node, onto: target, newTabMonitor: newTabMonitor)
        try move(destination)
        // A pinned split it went into knows it as its own, with the move.
        try saveWorkspaceSidebarPinCompositions(of: [destination])
        try completeWorkspaceSidebarPinLoan(loan)
        return true
    }
}

/// A user's move of `node` to a tab `move` makes for it, a new one: a pin whose one window it takes
/// lends it there. If any of it can't be done, nothing changes.
@MainActor
func moveWorkspaceSidebarNodeOutKeepingPins(_ node: TreeNode, _ move: () -> Bool) throws -> Bool {
    if config.usesBrowserTabs { try saveWorkspaceSidebarPinCompositions(of: [node.nodeWorkspace].compactMap { $0 }) }
    guard config.usesBrowserTabs, let loan = workspaceSidebarPinLoan(taking: node) else { return move() }
    return try withWorkspaceSidebarDropTransaction {
        guard move() else { return false }
        try completeWorkspaceSidebarPinLoan(loan)
        return true
    }
}

/// A command's move of `window` into `target`, as `moveWindowToWorkspace` makes it, under the pins'
/// policy: a pin with one window keeps it, the two going to an ordinary tab, which comes forward; a
/// pin that takes no window, or an empty pin given more than one, takes nothing, and says so.
@MainActor
func moveWindowToWorkspaceKeepingPins(_ window: Window, _ target: Workspace, _ io: CmdIo, focusFollowsWindow: Bool,
                                      failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> Bool {
    do {
        return try moveWindowToWorkspaceUnderPinPolicy(window, target, io, focusFollowsWindow: focusFollowsWindow,
            failIfNoop: failIfNoop, index: index)
    } catch {
        return io.err(error.localizedDescription)
    }
}

/// `moveWindowToWorkspaceKeepingPins`, throwing the policy's refusal, or an error saving the pins, for
/// a caller that reports them itself.
@MainActor
func moveWindowToWorkspaceUnderPinPolicy(_ window: Window, _ target: Workspace, _ io: CmdIo, focusFollowsWindow: Bool,
                                         failIfNoop: Bool, index: Int = INDEX_BIND_LAST) throws -> Bool {
    guard config.usesBrowserTabs, window.nodeWorkspace != target else {
        return moveWindowToWorkspace(window, target, io, focusFollowsWindow: focusFollowsWindow, failIfNoop: failIfNoop, index: index)
    }
    var moved = false
    let allowed = try moveWorkspaceSidebarNodeKeepingPins(window, onto: target) { destination in
        // The pin's window came to the window's own tab, which it was the whole of: it stays.
        if destination === window.nodeWorkspace, destination !== target {
            moved = window.focusWindow()
            return
        }
        moved = moveWindowToWorkspace(window, destination, io, focusFollowsWindow: focusFollowsWindow || destination !== target,
            failIfNoop: failIfNoop, index: destination === target ? index : INDEX_BIND_LAST)
    }
    guard allowed else { throw workspaceSidebarPinRefusal(target, taking: 1) }
    return moved
}

/// Why the pins' policy refuses `node` into `target`, said plainly; nil where it allows it.
@MainActor
func workspaceSidebarPinPolicyRefusal(_ node: TreeNode, into target: Workspace) -> WorkspaceSidebarPinPolicyRefusal? {
    workspaceSidebarPinPolicyAllows(node, into: target)
        ? nil : workspaceSidebarPinRefusal(target, taking: node.allLeafWindowsRecursive.count)
}

@MainActor
private func workspaceSidebarPinRefusal(_ pin: Workspace, taking count: Int) -> WorkspaceSidebarPinPolicyRefusal {
    switch workspaceSidebarPinSplitRole(pin) {
        case .composition: .init("Workspace '\(pin.name)' is a pinned split, which can't take this")
        case .empty: .init("Workspace '\(pin.name)' is an empty pin: it takes one window, not \(count)")
        case .single: .init("Workspace '\(pin.name)' is a pin with one window: a split with it goes to an ordinary tab, "
            + "which a layout for the pin can't make; move the window to it instead")
        case .hidden: .init("Workspace '\(pin.name)' is a pin whose window is hidden with its app: show it, then try again")
        case .fullscreen: .init("Workspace '\(pin.name)' is a pin whose window is in full screen: exit full screen, then split")
        case .refuses: .init("Workspace '\(pin.name)' is a pin whose window is in another tab, or isn't laid out: it takes no window")
    }
}

/// An agent's layout of a whole tab, `target`, with `windows` in it, under the pins' policy: a pin with
/// one window takes no window it hasn't got, an empty pin one, and a pinned split any. A layout for a pin
/// with one window can't make the ordinary split the pins' rule makes instead, so it's refused, before
/// anything changes. Nil where it may be made.
@MainActor
func workspaceSidebarPinLayoutRefusal(_ windows: [Window], for target: Workspace) -> WorkspaceSidebarPinPolicyRefusal? {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(target) else { return nil }
    let own = Set(target.allLeafWindowsRecursive.map(\.windowId))
    guard windows.contains(where: { !own.contains($0.windowId) }) else { return nil }
    switch workspaceSidebarPinSplitRole(target) {
        // A pinned split may be laid out with other windows, and stays one.
        case .composition: return nil
        case .empty where windows.count == 1: return nil
        default: return workspaceSidebarPinRefusal(target, taking: windows.count)
    }
}

/// Records several pins' loans at once, before the move they're for, which is made all at once.
@MainActor
func lendWorkspaceSidebarPinWindows(_ loans: [WorkspaceSidebarPinLoan]) throws {
    guard !loans.isEmpty else { return }
    try workspaceSidebarOrganizationStore.update { state in
        for loan in loans { state.workspaces[loan.pin.name, default: .init()].lentWindow = .init(loan.window) }
    }
}

// MARK: Pinned splits

/// A tab pinned now from its menu: a pinned split if it has two laid-out windows or more, keeping them
/// in their places.
@MainActor
func workspaceSidebarNewComposition(for workspace: Workspace) -> WorkspaceSidebarPinComposition? {
    guard config.usesBrowserTabs else { return nil }
    return workspaceSidebarCompositionOfTree(workspace)
}

@MainActor
private func workspaceSidebarCompositionOfTree(_ workspace: Workspace) -> WorkspaceSidebarPinComposition? {
    guard workspace.rootTilingContainer.allLeafWindowsRecursive.count > 1 else { return nil }
    return .init(layout: workspaceSidebarCompositionLayout(of: workspace.rootTilingContainer, weight: 1))
}

/// A pinned split from before they were recorded, as it's recorded: a pin with two laid-out windows or
/// more, now or as its tab was last saved. One whose windows aren't back yet is recorded with none, and
/// takes them in as they come back. Nil for any other pin, and once that's been done for all of them.
@MainActor
private func workspaceSidebarLegacyComposition(of name: String) -> WorkspaceSidebarPinComposition? {
    let state = workspaceSidebarOrganizationStore.state
    guard state.pinnedSplitsRecorded != true, let appearance = state.workspaces[name], appearance.isFavorite,
          appearance.composition == nil else { return nil }
    if let workspace = Workspace.existing(byName: name), let now = workspaceSidebarCompositionOfTree(workspace) { return now }
    return (savedWorkspaceStore.record(named: name)?.layout.root.allSlots.count ?? 0) > 1 ? .init(layout: .empty) : nil
}

/// Pinned splits from before they were recorded are recorded, all of them, once. After that, a pin with
/// more windows that wasn't pinned as a split, an app's own new window in it, isn't one. Best effort: a
/// change that needs one of them recorded first records it itself (`saveWorkspaceSidebarPinCompositions`).
@MainActor
func recordLegacyWorkspaceSidebarPinnedSplits() {
    let store = workspaceSidebarOrganizationStore
    guard store.readOnlyReason == nil, store.state.pinnedSplitsRecorded != true else { return }
    let recorded = store.state.workspaces.keys.compactMap { name in workspaceSidebarLegacyComposition(of: name).map { (name, $0) } }
    try? store.update { state in
        for (name, composition) in recorded { state.workspaces[name]?.composition = composition }
        state.pinnedSplitsRecorded = true
    }
}

/// The records `pins` need now to be whole: a pinned split from before they were recorded, recorded; and
/// windows that came into a pinned split, as its tab was reopened or restored, or opened there by their
/// app, taken in as its own.
@MainActor
private func workspaceSidebarPinCompositionUpdates(for pins: [Workspace]) -> [String: WorkspaceSidebarPinComposition] {
    var updates: [String: WorkspaceSidebarPinComposition] = [:]
    for pin in pins where updates[pin.name] == nil {
        guard let appearance = workspaceSidebarOrganizationStore.state.workspaces[pin.name], appearance.isFavorite else { continue }
        if let composition = appearance.composition {
            let newcomers = workspaceSidebarCompositionNewcomers(composition, in: pin)
            if !newcomers.isEmpty { updates[pin.name] = workspaceSidebarComposition(composition, enrolling: newcomers, in: pin) }
        } else if let legacy = workspaceSidebarLegacyComposition(of: pin.name) {
            updates[pin.name] = legacy
        }
    }
    return updates
}

/// Keeps every pinned split's record whole, as `workspaceSidebarPinCompositionUpdates` says, after a
/// change to the windows. Best effort: what a change needs, it saves first itself, and fails if it can't.
@MainActor
func syncWorkspaceSidebarPinCompositions() {
    recordLegacyWorkspaceSidebarPinnedSplits()
    let store = workspaceSidebarOrganizationStore
    guard store.readOnlyReason == nil else { return }
    let pins = store.state.workspaces.filter(\.value.isFavorite).keys.compactMap { Workspace.existing(byName: $0) }
    let updates = workspaceSidebarPinCompositionUpdates(for: pins)
    guard !updates.isEmpty else { return }
    try? store.update { state in
        for (name, composition) in updates { state.workspaces[name]?.composition = composition }
    }
}

/// Before a change to which windows the tabs `workspaces` hold: the records of those of them that are
/// pins made whole and saved first. Throws, saying so, where that can't be done: then the change mustn't
/// be made, or a pinned split could lose track of a window of its own. Other pins aren't touched.
@MainActor
func saveWorkspaceSidebarPinCompositions(of workspaces: [Workspace]) throws {
    let updates = workspaceSidebarPinCompositionUpdates(for: workspaces)
    guard !updates.isEmpty else { return }
    do {
        try workspaceSidebarOrganizationStore.update { state in
            for (name, composition) in updates { state.workspaces[name]?.composition = composition }
        }
    } catch {
        let names = updates.keys.sorted().map { "'\($0)'" }.joined(separator: ", ")
        throw WorkspaceSidebarPinPolicyRefusal("Couldn't save the pinned split \(names) before changing its windows, so nothing "
            + "was changed: \(error.localizedDescription)")
    }
}

/// Windows `split` holds, laid out, that its record doesn't know: come into it since it was recorded.
@MainActor
private func workspaceSidebarCompositionNewcomers(_ composition: WorkspaceSidebarPinComposition, in split: Workspace) -> [Window] {
    let known = composition.layout.windows + composition.away.map(\.window)
    return split.rootTilingContainer.allLeafWindowsRecursive.filter { window in !known.contains { $0.live === window } }
}

/// `composition` taking `newcomers`, windows in `split` it doesn't know, in as its own. Its record stays
/// as it is: each window in its place, those away too. Each newcomer goes beside the piece of it that
/// is its nearest neighbour in `split`, at that piece's level, as long as the pieces beside it are; with
/// none of its windows in `split`, after them all. With no window recorded, it's `split` as laid out.
@MainActor
private func workspaceSidebarComposition(_ composition: WorkspaceSidebarPinComposition, enrolling newcomers: [Window],
                                         in split: Workspace) -> WorkspaceSidebarPinComposition {
    var result = composition
    guard !composition.layout.windows.isEmpty else {
        result.layout = workspaceSidebarCompositionLayout(of: split.rootTilingContainer, weight: 1)
        return result
    }
    let present = split.rootTilingContainer.allLeafWindowsRecursive
    for window in newcomers {
        let link = WorkspaceSidebarPinWindow(window)
        let orientation = (window.parent as? TilingContainer)?.orientation ?? .h
        var placed: WorkspaceSidebarCompositionNode? = nil
        for (group, after) in workspaceSidebarEnrollmentNeighbours(of: window) where placed == nil {
            // A recorded window is in the neighbour, out of it, or not here at all.
            let side: (WorkspaceSidebarPinWindow) -> Bool? = { recorded in
                guard let live = recorded.live, present.contains(where: { $0 === live }) else { return nil }
                return group.contains { $0 === live }
            }
            placed = result.layout.inserting(.window(link, weight: 1), besidePieceWhere: side, after: after, orientation: orientation)
        }
        result.layout = placed ?? result.layout.appending(.window(link, weight: 1), orientation: orientation)
    }
    return result
}

/// The pieces laid out beside `window`, nearest first, each with whether `window` comes after it: in its
/// own split, those before it and after it, then those beside each split around it.
@MainActor
private func workspaceSidebarEnrollmentNeighbours(of window: Window) -> [(windows: [Window], after: Bool)] {
    var neighbours: [(windows: [Window], after: Bool)] = []
    var node: TreeNode = window
    while let parent = node.parent as? TilingContainer {
        let siblings = Array(parent.children)
        guard let index = siblings.firstIndex(where: { $0 === node }) else { break }
        for offset in 1 ..< max(siblings.count, 1) {
            if index - offset >= 0 { neighbours.append((siblings[index - offset].allLeafWindowsRecursive, true)) }
            if index + offset < siblings.count { neighbours.append((siblings[index + offset].allLeafWindowsRecursive, false)) }
        }
        node = parent
    }
    return neighbours
}

@MainActor
func workspaceSidebarNewCompositions(for workspaces: [Workspace]) -> [String: WorkspaceSidebarPinComposition] {
    Dictionary(workspaces.compactMap { workspace in workspaceSidebarNewComposition(for: workspace).map { (workspace.name, $0) } },
        uniquingKeysWith: { first, _ in first })
}

@MainActor
private func workspaceSidebarCompositionLayout(of node: TreeNode, weight: CGFloat) -> WorkspaceSidebarCompositionNode {
    if let window = node as? Window { return .window(.init(window), weight: weight) }
    let container = node as? TilingContainer
    let orientation = container?.orientation ?? .h
    return .split(orientation, weight: weight, children: node.children.map {
        workspaceSidebarCompositionLayout(of: $0, weight: $0.getWeight(orientation))
    })
}

extension WorkspaceSidebarCompositionNode {
    /// A pinned split's layout with no window in it.
    static var empty: Self { .split(.h, weight: 1, children: []) }

    var weight: CGFloat {
        switch self {
            case .window(_, let weight), .split(_, let weight, _): weight
        }
    }

    /// `self` with `piece` beside its largest piece below the top whose windows here, `side` says, are
    /// all in a neighbour, at least one: after it, or before it, with the average length of the pieces
    /// beside it. A top that's one window takes it beside, side by side as `orientation` says, both of
    /// one length: the top's own weight is no length among others. Nil where there's no such piece.
    func inserting(_ piece: Self, besidePieceWhere side: (WorkspaceSidebarPinWindow) -> Bool?, after: Bool,
                   orientation: Orientation) -> Self? {
        switch self {
            case .window(let window, _):
                guard side(window) == true else { return nil }
                return .split(orientation, weight: 1, children: after ? [.window(window, weight: 1), piece.withWeight(1)]
                    : [piece.withWeight(1), .window(window, weight: 1)])
            case .split:
                return insertingBelowTop(piece, besidePieceWhere: side, after: after)
        }
    }

    private func insertingBelowTop(_ piece: Self, besidePieceWhere side: (WorkspaceSidebarPinWindow) -> Bool?, after: Bool) -> Self? {
        guard case .split(let orientation, let weight, var children) = self else { return nil }
        for (index, child) in children.enumerated() {
            let sides = child.windows.compactMap(side)
            if !sides.isEmpty, sides.allSatisfy({ $0 }) {
                let length = children.map(\.weight).reduce(0, +) / CGFloat(children.count)
                children.insert(piece.withWeight(length), at: after ? index + 1 : index)
                return .split(orientation, weight: weight, children: children)
            }
            if sides.contains(true), let inner = child.insertingBelowTop(piece, besidePieceWhere: side, after: after) {
                children[index] = inner
                return .split(orientation, weight: weight, children: children)
            }
        }
        return nil
    }

    /// `self` with `piece` after all of it: last among the top's pieces, with their average length; or,
    /// a top that's one window, beside it, as `orientation` says, both of one length.
    func appending(_ piece: Self, orientation: Orientation) -> Self {
        switch self {
            case .window:
                return .split(orientation, weight: 1, children: [withWeight(1), piece.withWeight(1)])
            case .split(let topOrientation, let weight, let children):
                let length = children.isEmpty ? 1 : children.map(\.weight).reduce(0, +) / CGFloat(children.count)
                return .split(topOrientation, weight: weight, children: children + [piece.withWeight(length)])
        }
    }

    var windows: [WorkspaceSidebarPinWindow] {
        switch self {
            case .window(let window, _): [window]
            case .split(_, _, let children): children.flatMap(\.windows)
        }
    }

    func contains(where match: (WorkspaceSidebarPinWindow) -> Bool) -> Bool { windows.contains(where: match) }

    /// Without the windows `gone` names: a split left one piece is that piece, and one left none goes.
    func removing(where gone: (WorkspaceSidebarPinWindow) -> Bool) -> WorkspaceSidebarCompositionNode? {
        switch self {
            case .window(let window, _): return gone(window) ? nil : self
            case .split(let orientation, let weight, let children):
                let kept = children.compactMap { $0.removing(where: gone) }
                if kept.isEmpty { return nil }
                if kept.count == 1 { return kept[0].withWeight(weight) }
                return .split(orientation, weight: weight, children: kept)
        }
    }

    func withWeight(_ weight: CGFloat) -> Self {
        switch self {
            case .window(let window, _): .window(window, weight: weight)
            case .split(let orientation, _, let children): .split(orientation, weight: weight, children: children)
        }
    }
}

/// A pinned split's record, made now from its windows in their places if it has none yet: a split
/// pinned before it was kept as one.
@MainActor
private func workspaceSidebarComposition(of split: Workspace) -> WorkspaceSidebarPinComposition? {
    workspaceSidebarOrganizationStore.state.workspaces[split.name]?.composition ?? workspaceSidebarNewComposition(for: split)
}

/// A pinned split's windows that aren't in it, still open, and where they are. A window of it dragged out
/// stays its own (Alan, October 8). A click brings back those alone in their own pin, laid out, or in
/// an ordinary tab, each with its own pin if it has one; it first shows those hidden with their app
/// there; and it leaves the rest, minimized, in full screen or in another pin, where they are, and
/// never opens another for them.
@MainActor
private func workspaceSidebarAwayWindows(of composition: WorkspaceSidebarPinComposition, from split: Workspace)
    -> (recallable: [(window: Window, pin: Workspace?)], hidden: [Window], elsewhere: [Window])
{
    var recallable: [(Window, Workspace?)] = []
    var hidden: [Window] = []
    var elsewhere: [Window] = []
    var seen: Set<UInt32> = []
    let homes = Dictionary(composition.away.map { ($0.window, $0.pinName) }, uniquingKeysWith: { first, _ in first })
    for link in composition.away.map(\.window) + composition.layout.windows {
        guard let window = link.live, window.nodeWorkspace !== split, seen.insert(window.windowId).inserted else { continue }
        let home = homes[link].flatMap { Workspace.existing(byName: $0) }.flatMap { workspaceSidebarIsPinned($0) ? $0 : nil }
        let tab = window.nodeWorkspace
        let inHome = tab != nil && tab === home && home?.allLeafWindowsRecursive.count == 1
        let inOrdinaryTab = tab.map { !workspaceSidebarIsPinned($0) } ?? false
        if inHome && window.parent is TilingContainer || inOrdinaryTab && (window.parent is TilingContainer || window.isFloating) {
            recallable.append((window, home))
        } else if inHome || inOrdinaryTab, window.parent is MacosHiddenAppsWindowsContainer {
            hidden.append(window)
        } else {
            elsewhere.append(window)
        }
    }
    return (recallable, hidden, elsewhere)
}

/// Whether a click on `pin` brings a window back, or must not open one: the window it lent is open; or,
/// a pinned split, a window of it it can bring back is out of it, or, with none in it, one is open
/// elsewhere, where its saved apps mustn't open others.
@MainActor
func workspaceSidebarPinRecallsWindows(_ pin: Workspace) -> Bool {
    if workspaceSidebarLentWindow(of: pin) != nil { return true }
    guard let composition = workspaceSidebarOrganizationStore.state.workspaces[pin.name]?.composition else { return false }
    let away = workspaceSidebarAwayWindows(of: composition, from: pin)
    return !away.recallable.isEmpty || !away.hidden.isEmpty || (!away.elsewhere.isEmpty && pin.allLeafWindowsRecursive.isEmpty)
}

/// Rebuilds `split`'s laid-out windows as `layout` places them, as far as `windows` are there: each
/// in its place, in its order, side by side or stacked as it was. Windows `layout` doesn't place go
/// last. Floating windows stay as they are.
@MainActor
private func rebuildWorkspaceSidebarComposition(_ split: Workspace, layout: WorkspaceSidebarCompositionNode, windows: [Window]) {
    let byId = Dictionary(windows.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first })
    let placed = layout.removing { byId[$0.windowId] == nil }
    let root = split.rootTilingContainer
    for window in windows { window.unbindFromParent() }
    for child in Array(root.children) { child.unbindFromParent() }
    var bound: Set<UInt32> = []
    func build(_ node: WorkspaceSidebarCompositionNode, into parent: NonLeafTreeNodeObject) {
        switch node {
            case .window(let pinWindow, let weight):
                guard let window = byId[pinWindow.windowId], bound.insert(window.windowId).inserted else { return }
                window.bind(to: parent, adaptiveWeight: weight, index: INDEX_BIND_LAST)
            case .split(let orientation, let weight, let children):
                let container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, .tiles, index: INDEX_BIND_LAST)
                for child in children { build(child, into: container) }
        }
    }
    switch placed {
        case .split(let orientation, _, let children)?:
            root.changeOrientation(orientation)
            for child in children { build(child, into: root) }
        case let node?: build(node, into: root)
        case nil: break
    }
    for window in windows where !bound.contains(window.windowId) {
        window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

// MARK: A click on a pin that recalls windows

/// What a click on a pin that recalls windows did.
enum WorkspaceSidebarPinRecall: Equatable {
    /// The lent window is back in its pin, alone.
    case returned(Window)
    /// The lent window is minimized: it's restored first, then comes back.
    case minimized(Window)
    /// The lent window is hidden with its app: it's shown first, then comes back (Alan, October 8).
    case hidden(Window)
    /// The lent window is in full screen: it's found where it is, and stays there (Alan, October 8).
    case elsewhere(Window)
    /// The pinned split has these windows back; `elsewhere` are its windows open in other tabs.
    case recalled([Window], elsewhere: [Window])
    case nothing
}

/// A click on `pin`: brings back the same window it lent, from wherever it is now, leaving the rest of
/// that split in its tab; or, for a pinned split, its windows back alone in their own pins, to their
/// places. It never opens a window. An ordinary tab the lent window leaves empty closes. A pinned split
/// the lent window leaves keeps its place, to bring it back when that split is clicked.
@MainActor
func recallWorkspaceSidebarPinWindows(_ pin: Workspace) throws -> WorkspaceSidebarPinRecall {
    guard config.usesBrowserTabs, workspaceSidebarIsPinned(pin) else { return .nothing }
    try saveWorkspaceSidebarPinCompositions(of: [pin, workspaceSidebarLentWindow(of: pin)?.nodeWorkspace].compactMap { $0 })
    if workspaceSidebarPinSplitRole(pin) == .composition { return try recallWorkspaceSidebarComposition(pin) }
    guard pin.allLeafWindowsRecursive.isEmpty, let window = workspaceSidebarLentWindow(of: pin) else { return .nothing }
    if window.parent is MacosMinimizedWindowsContainer { return .minimized(window) }
    if window.parent is MacosHiddenAppsWindowsContainer { return .hidden(window) }
    let isFloating = window.parent is Workspace
    guard window.parent is TilingContainer || isFloating else { return .elsewhere(window) }
    let from = window.nodeWorkspace
    // A pinned split it leaves keeps its layout from when all its windows were there.
    let fromComposition = from.flatMap { split -> WorkspaceSidebarPinComposition? in
        guard workspaceSidebarIsPinned(split), workspaceSidebarPinSplitRole(split) == .composition,
              var composition = workspaceSidebarComposition(of: split) else { return nil }
        composition.away = composition.away.filter { $0.window.live != nil && $0.window.windowId != window.windowId }
            + [.init(window: .init(window), pinName: pin.name)]
        return composition
    }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: [window.windowId])
    _ = try withWorkspaceSidebarDropTransaction {
        window.bind(to: isFloating ? pin : pin.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try workspaceSidebarOrganizationStore.update { state in
            state.workspaces[pin.name]?.lentWindow = nil
            if let from, let fromComposition { state.workspaces[from.name]?.composition = fromComposition }
        }
        return true
    }
    // No empty ordinary tab stays behind.
    if let from, !workspaceSidebarIsPinned(from), !workspaceHasLifecycleWindows(from) { closeEmptyTab(from) }
    return .returned(window)
}

@MainActor
private func recallWorkspaceSidebarComposition(_ split: Workspace) throws -> WorkspaceSidebarPinRecall {
    guard var composition = workspaceSidebarComposition(of: split) else { return .nothing }
    let away = workspaceSidebarAwayWindows(of: composition, from: split)
    let elsewhere = away.hidden + away.elsewhere
    guard !away.recallable.isEmpty else { return elsewhere.isEmpty ? .nothing : .recalled([], elsewhere: elsewhere) }
    let present = split.rootTilingContainer.allLeafWindowsRecursive
    let back = away.recallable.map(\.window)
    // The ordinary tabs they come from, which mustn't stay behind empty.
    let froms = back.compactMap(\.nodeWorkspace).filter { !workspaceSidebarIsPinned($0) }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: (present + back).map(\.windowId))
    let backIds = Set(back.map(\.windowId))
    composition.away = composition.away.filter { $0.window.live != nil && !backIds.contains($0.window.windowId) }
    let recorded = composition
    _ = try withWorkspaceSidebarDropTransaction {
        rebuildWorkspaceSidebarComposition(split, layout: recorded.layout, windows: present + back)
        try workspaceSidebarOrganizationStore.update { state in
            for case let (window, pin?) in away.recallable { state.workspaces[pin.name]?.lentWindow = .init(window) }
            state.workspaces[split.name]?.composition = recorded
        }
        return true
    }
    for from in froms where Workspace.existing(byName: from.name) === from && !workspaceHasLifecycleWindows(from) {
        closeEmptyTab(from)
    }
    return .recalled(back, elsewhere: elsewhere)
}

/// Restores a minimized window from macOS, and says when it's back. Tests replace it.
@MainActor var workspaceSidebarRestoreMinimizedWindow: @MainActor (Window) async -> Bool = { window in
    guard let macWindow = window as? MacWindow else { return false }
    macWindow.setNativeMinimized(false)
    for _ in 0 ..< 20 {
        if (try? await macWindow.isMacosMinimized) == false { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// Says what a click did when it couldn't bring a window back here. Tests replace it.
@MainActor var workspaceSidebarPinRecallNotice: @MainActor (String, String) -> Void = { title, body in
    WinMuxToastPanel.shared.show(.init(title: title, body: body))
}

/// What became of a minimized lent window a click asked macOS to restore.
enum WorkspaceSidebarMinimizedRecall: Equatable {
    case returned
    case stayedMinimized
    /// Restored, but the pin or the window changed meanwhile: it stays where macOS put it.
    case changed
}

/// The same lent window, restored from minimized, comes back to `pin`, if it's still the one the pin
/// lent once macOS has restored it.
@MainActor
func recallMinimizedWorkspaceSidebarPinWindow(_ pin: Workspace, _ window: Window) async throws -> WorkspaceSidebarMinimizedRecall {
    let lent = WorkspaceSidebarPinWindow(window)
    guard await workspaceSidebarRestoreMinimizedWindow(window) else { return .stayedMinimized }
    // Across the wait, the pin may have been unpinned or given its window back, and the window closed.
    guard workspaceSidebarIsPinned(pin), pin.allLeafWindowsRecursive.isEmpty, let now = lent.live, now === window,
          workspaceSidebarOrganizationStore.state.workspaces[pin.name]?.lentWindow.flatMap({ $0.live }) === window
    else { return .changed }
    syncClosedWindowsCacheToCurrentWorld()
    suppressPostDragAxObserverEvents(for: [window.windowId])
    _ = try withWorkspaceSidebarDropTransaction {
        window.layoutReason = .standard
        window.bind(to: pin.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try workspaceSidebarOrganizationStore.update { $0.workspaces[pin.name]?.lentWindow = nil }
        return true
    }
    return .returned
}

// MARK: Hidden and full-screen windows (Alan, October 8)

/// Shows a window's app again, hidden, and says when it's shown. Tests replace it.
@MainActor var workspaceSidebarUnhideWindow: @MainActor (Window) async -> Bool = { window in
    guard let app = window.app as? MacApp else { return false }
    app.nsApp.unhide()
    for _ in 0 ..< 20 {
        if !app.nsApp.isHidden { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// `window`, hidden with its app, shown again where it is: back among its tab's windows, laid out or
/// floating as it was. Gives whether it's back there, still the same window in the same tab.
@MainActor
func showHiddenWorkspaceSidebarWindow(_ window: Window) async -> Bool {
    guard let tab = window.nodeWorkspace, window.parent is MacosHiddenAppsWindowsContainer else { return false }
    let link = WorkspaceSidebarPinWindow(window)
    guard await workspaceSidebarUnhideWindow(window) else { return false }
    // Across the wait, it may have closed or moved; WinMux may have put it back itself.
    guard link.live === window, window.nodeWorkspace === tab else { return false }
    if window.parent is MacosHiddenAppsWindowsContainer {
        let wasFloating = if case .macos(.workspace, _) = window.layoutReason { true } else { false }
        window.layoutReason = .standard
        if wasFloating {
            window.bindAsFloatingWindow(to: tab)
        } else {
            window.bind(to: tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }
    return window.parent is TilingContainer || window.isFloating
}

/// A pin's window a split with it can't use now, and why.
struct WorkspaceSidebarPinNotShown {
    let window: Window
    let isFullscreen: Bool
    let message: String
}

/// Before a user's split with `pins`: a pin whose one window is hidden with its app has it shown again,
/// the same window, back in the pin, so it's a pin with one window. One in full screen is left as it
/// is, never split, never taken out of full screen; nor is one that stays hidden. Gives the first such
/// pin's window, or nil when the split may go ahead.
@MainActor
func showWorkspaceSidebarPinsForSplit(_ pins: [Workspace]) async -> WorkspaceSidebarPinNotShown? {
    guard config.usesBrowserTabs else { return nil }
    for pin in pins where workspaceSidebarIsPinned(pin) {
        switch workspaceSidebarPinSplitRole(pin) {
            case .fullscreen(let window):
                return .init(window: window, isFullscreen: true, message: "\(workspaceSidebarAppName(window)) is in full screen, "
                    + "so it wasn't split. Exit full screen, then try again.")
            case .hidden(let window):
                guard await showHiddenWorkspaceSidebarWindow(window), workspaceSidebarPinSplitRole(pin) == .single(window) else {
                    return .init(window: window, isFullscreen: false,
                        message: "\(workspaceSidebarAppName(window)) stayed hidden, or changed meanwhile, so it wasn't split.")
                }
            default: continue
        }
    }
    return nil
}

/// Says why a split wasn't made, finding a full-screen window where it is.
@MainActor
func noteWorkspaceSidebarPinNotShown(_ notShown: WorkspaceSidebarPinNotShown) {
    if notShown.isFullscreen, !notShown.window.focusWindow() { _ = notShown.window.nodeWorkspace?.focusWorkspace() }
    workspaceSidebarPinRecallNotice(notShown.isFullscreen ? "Exit full screen first" : "Couldn't show the window", notShown.message)
}

/// A pinned split's windows hidden with their app where a click on it would take them from, shown
/// again first.
@MainActor
private func showHiddenWorkspaceSidebarCompositionWindows(_ split: Workspace) async {
    guard let composition = workspaceSidebarOrganizationStore.state.workspaces[split.name]?.composition else { return }
    for window in workspaceSidebarAwayWindows(of: composition, from: split).hidden {
        _ = await showHiddenWorkspaceSidebarWindow(window)
    }
}

/// A click on a pin that recalls windows: they come back as `recallWorkspaceSidebarPinWindows` says,
/// then the pin shows as any clicked pin does, on the display it was clicked on. A window it can't
/// bring back is shown where it is, and a notice says so; nothing is ever opened instead.
@MainActor
func recallPinWindowsFromSidebar(_ name: String, focusing windowId: UInt32?, targetMonitorScopeId: String?) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    var shown: (pin: String, window: UInt32?)?
    runWorkspaceSidebarSession(afterLayout: {
        guard let shown else { return }
        if let windowId = shown.window {
            if let pin = workspaceSidebarSharedPinClicked(windowId: windowId, targetMonitorScopeId: targetMonitorScopeId) {
                showSharedPinnedTabFromSidebar(pin, windowId: windowId, targetMonitorScopeId: targetMonitorScopeId)
            } else {
                focusWindowFromSidebar(windowId, targetMonitorScopeId: targetMonitorScopeId)
            }
        } else if let pin = workspaceSidebarSharedPinClicked(shown.pin, targetMonitorScopeId: targetMonitorScopeId) {
            showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: targetMonitorScopeId)
        } else {
            focusWorkspaceFromSidebar(shown.pin, targetMonitorScopeId: targetMonitorScopeId)
        }
    }) {
        guard let pin = Workspace.existing(byName: name) else { return }
        if workspaceSidebarPinSplitRole(pin) == .composition { await showHiddenWorkspaceSidebarCompositionWindows(pin) }
        var recall = try recallWorkspaceSidebarPinWindows(pin)
        // Hidden with its app: shown again, then, still the same window the pin lent, brought back.
        if case .hidden(let window) = recall, await showHiddenWorkspaceSidebarWindow(window),
           workspaceSidebarLentWindow(of: pin) === window {
            recall = try recallWorkspaceSidebarPinWindows(pin)
        }
        switch recall {
            case .returned(let window): shown = (name, window.windowId)
            case .minimized(let window):
                switch try await recallMinimizedWorkspaceSidebarPinWindow(pin, window) {
                    case .returned: shown = (name, window.windowId)
                    case .stayedMinimized:
                        workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                            "\(workspaceSidebarAppName(window)) stayed minimized. Restore it from the Dock, then click the pin again.")
                    case .changed:
                        workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                            "\(workspaceSidebarAppName(window)) or its pin changed while it was restored, so it stayed where it is.")
                }
            case .hidden(let window):
                workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                    "\(workspaceSidebarAppName(window)) stayed hidden, or it or its pin changed meanwhile, so it stayed where it is.")
            case .elsewhere(let window):
                // In full screen: found where it is, never taken out of full screen, nor opened again.
                if !window.focusWindow() { _ = window.nodeWorkspace?.focusWorkspace() }
                workspaceSidebarPinRecallNotice("Exit full screen first",
                    "\(workspaceSidebarAppName(window)) is in full screen in another tab, so it stayed there. "
                        + "Exit full screen, then click the pin again.")
            case .recalled(let windows, let elsewhere):
                // Nothing to bring back to an empty pinned split, and a window of it in full screen: that
                // window is found where it is, not the empty split shown instead.
                if windows.isEmpty, pin.allLeafWindowsRecursive.isEmpty,
                   let window = elsewhere.first(where: { $0.parent is MacosFullscreenWindowsContainer }) {
                    if !window.focusWindow() { _ = window.nodeWorkspace?.focusWorkspace() }
                    workspaceSidebarPinRecallNotice("Exit full screen first",
                        "\(workspaceSidebarAppName(window)) is in full screen in another tab, so it stayed there. "
                            + "Exit full screen, then click the pinned split again.")
                    break
                }
                shown = (name, windowId ?? windows.first?.windowId)
                if !elsewhere.isEmpty {
                    let names = elsewhere.map(workspaceSidebarAppName).joined(separator: ", ")
                    let one = elsewhere.count == 1
                    workspaceSidebarPinRecallNotice("Some windows are elsewhere",
                        "\(names) \(one ? "is" : "are") open elsewhere, so \(one ? "it" : "they") stayed there.")
                }
            case .nothing: shown = (name, windowId)
        }
        await updateWorkspaceSidebarModel()
    }
}

@MainActor
private func workspaceSidebarAppName(_ window: Window) -> String {
    window.app.name ?? window.app.rawAppBundleId ?? "The window"
}
