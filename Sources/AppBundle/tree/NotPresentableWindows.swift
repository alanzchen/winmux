import AppKit

// Windows that exist but can't be shown (`Window.isNotPresentable`). Not a verdict on whether a window closed: such a
// window stays registered, with its pin, its pinned split and its auxiliary links, and is let go only on evidence that
// it closed (`windowLivenessVerdict`) or with its app. Meanwhile it's out of its tab, its layout and the sidebar, and
// comes back where it was once it can be shown.

/// Where a window set aside as not presentable was, to come back to: its parent then, while that's still in the same
/// tab, with its weight, between the same neighbours. `order` is the parent's children in order when it left, siblings
/// set aside before it in their places, so siblings set aside and brought back in any order, in one refresh or several,
/// come back in their order. `index` is for when none of them is there any more.
struct NotPresentableReturn {
    weak var parent: NonLeafTreeNodeObject?
    let adaptiveWeight: CGFloat
    let index: Int
    let order: [WeakTreeNode]

    /// Where among `parent`'s children now `window` goes back: after the nearest node that was before it and is there,
    /// else before the nearest that was after it and is there, else at its index.
    @MainActor
    func index(of window: Window, in parent: NonLeafTreeNodeObject) -> Int {
        let children = parent.children
        guard let mine = order.firstIndex(where: { $0.node === window }) else { return min(index, children.count) }
        for earlier in order[..<mine].reversed() {
            if let i = children.firstIndex(where: { $0 === earlier.node }) { return i + 1 }
        }
        for later in order[(mine + 1)...] {
            if let i = children.firstIndex(where: { $0 === later.node }) { return i }
        }
        return min(index, children.count)
    }
}

struct WeakTreeNode {
    weak var node: TreeNode?
}

extension Window {
    /// Not presentable, or still set aside as such: not a window its app has open, lends or keeps elsewhere.
    @MainActor
    var isSetAsideAsNotPresentable: Bool { isNotPresentable || parent === macosNotPresentableWindowsContainer }
}

/// What a committed refresh found of its windows (`RegisteredWindowsRefresh.presentable`) takes effect. A window is not
/// presentable when the refresh says so, unless it's known minimized (minimized windows are ordered out too). Windows
/// the refresh said nothing of (a busy app's, a hidden app's, or with no window list to go by) keep what they had: an
/// app hidden doesn't bring back a window set aside before.
@MainActor
func noteWindowPresentability(_ presentable: [UInt32: Bool]) {
    for (windowId, isPresentable) in presentable {
        guard let window = Window.get(byId: windowId) else { continue }
        let knownMinimized = window.lastKnownNativeMinimized == true || window.parent === macosMinimizedWindowsContainer
        window.isNotPresentable = !isPresentable && !knownMinimized
    }
}

/// A window not presentable leaves its tab for the not-presentable container (`normalizeLayoutReason`): out of the
/// layout, the tab's rows and the tab's count, so a tab it leaves empty isn't listed. The tab is kept for it
/// (`workspaceOwnedNotPresentableWindows`), and so is where it was.
@MainActor
func setAsideNotPresentableWindow(_ window: Window) {
    guard let parent = window.parent, parent.nodeWorkspace != nil else { return }
    window.rememberMacOsLayoutOrigin()
    // A sibling set aside before kept the order from when it left, with this window in it: kept on, so neither's
    // place is lost, with what joined the parent since put in after the child before it.
    let inherited = macosNotPresentableWindowsContainer.children.lazy.compactMap { ($0 as? Window)?.notPresentableReturn }
        .first { $0.parent === parent && $0.order.contains { $0.node === window } }?.order
    var order = inherited ?? []
    var previous: Int?
    for child in parent.children {
        if let i = order.firstIndex(where: { $0.node === child }) {
            previous = i
        } else {
            let at = previous.map { $0 + 1 } ?? 0
            order.insert(WeakTreeNode(node: child), at: at)
            previous = at
        }
    }
    let binding = window.unbindFromParent()
    window.notPresentableReturn = NotPresentableReturn(parent: binding.parent, adaptiveWeight: binding.adaptiveWeight,
        index: binding.index, order: order)
    window.bind(to: macosNotPresentableWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    forgetCachedNativeFocus(of: window)
}

/// How many windows set aside have been brought back, ever: a refresh that brings one back reads macOS's focus again
/// (`runRefreshSessionBlocking`).
@MainActor private(set) var notPresentableWindowsBroughtBack: UInt64 = 0

/// Windows set aside, brought back where a reopen asked, whose focus waits for macOS's focus read after the restore; each
/// with the count of windows brought back once it was (`notPresentableWindowsBroughtBack`).
@MainActor private var reopenedSetAsideFocusRequests: [(window: Window, intent: NewWindowIntent, broughtBack: UInt64)] = []

/// After the restore and macOS's focus read again (`nativeFocusNow`; `nativeFocusBefore`, read at the refresh's start),
/// macOS's focus decides, once per refresh. Each window a reopen asked for that this refresh brought back (after
/// `broughtBackBefore`) takes focus, as the reopen's placement would have, only if macOS's focus is the same window (or
/// none) both times, with no native panel (a sheet, a popover, an Open or Save panel) holding it either time: a newer
/// focus stands. One a refresh cut short left behind is dropped, and a restore under way when it was placed only places
/// it (`DeferredReopenPlacement.takesFocus`).
@MainActor
func focusReopenedSetAsideWindows(broughtBackSince broughtBackBefore: UInt64, nativeFocusBefore: NativeFocusObservation,
                                  nativeFocusNow: NativeFocusObservation) {
    let requests = reopenedSetAsideFocusRequests
    reopenedSetAsideFocusRequests = []
    guard !nativeFocusBefore.isTransient, !nativeFocusNow.isTransient,
          nativeFocusNow.window?.windowId == nativeFocusBefore.window?.windowId else { return }
    for (window, intent, broughtBack) in requests where broughtBack > broughtBackBefore {
        if nativeFocusNow.window === window { continue }
        if newWindowIntentMayTakeFocus(intent, placing: window), window.nodeWorkspace?.isVisible == true, window.focusWindow() {
            window.nativeFocus()
        }
    }
}

/// Windows set aside that can be shown again (ordered in again, or rebound to a fresh element) come back: where a
/// reopen asked for its app's window to go (an empty pin clicked, its app reopened, showing it again); else to the place
/// they left if it's still there in the same tab, or else to their tab as a window back from macOS's own states does.
@MainActor
func bringBackPresentableWindows(fallback workspace: Workspace) async throws {
    for window in macosNotPresentableWindowsContainer.children.filterIsInstance(of: Window.self) where !window.isNotPresentable {
        let back = window.notPresentableReturn
        window.notPresentableReturn = nil
        notPresentableWindowsBroughtBack &+= 1
        forgetCachedNativeFocus(of: window)
        // Shown again just now: for a reopen asked before, it's the window that reopen showed.
        let registry = NewWindowIntentRegistry.shared
        if registry.hasPendingIntents,
           let target = registry.claim(windowId: window.windowId, pid: window.app.pid, bundleId: window.app.rawAppBundleId,
               firstSeenUptime: registry.now()),
           let claim = registry.consumeClaim(windowId: window.windowId)
        {
            window.layoutReason = .standard
            let binding = newWindowIntentBinding(targetWorkspace: target)
            window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
            // Placed now; focus waits for macOS's focus read after the restore (`runRefreshSessionBlocking`).
            finishNewWindowIntentPlacement(window, claim: claim, takesFocus: false)
            reopenedSetAsideFocusRequests.append((window, claim.intent, notPresentableWindowsBroughtBack))
            continue
        }
        guard case .macos(let prevParentKind, let prevWorkspaceName) = window.layoutReason else {
            try await window.relayoutWindow(on: workspace)
            continue
        }
        if let back, let parent = back.parent, parent.nodeWorkspace?.name == prevWorkspaceName,
           parent is TilingContainer || parent is Workspace
        {
            window.layoutReason = .standard
            window.bind(to: parent, adaptiveWeight: back.adaptiveWeight, index: back.index(of: window, in: parent))
        } else {
            try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind,
                prevWorkspaceName: prevWorkspaceName, workspace: workspace)
        }
    }
}

/// The ids of `pid`'s windows set aside as not presentable.
@MainActor
func notPresentableWindowIds(pid: pid_t) -> Set<UInt32> {
    Set(macosNotPresentableWindowsContainer.children.compactMap { ($0 as? Window).flatMap { $0.app.pid == pid ? $0.windowId : nil } })
}

/// The windows set aside as not presentable that belong to `workspace`: it isn't pruned while it has any, though it isn't
/// listed for them.
@MainActor
func workspaceOwnedNotPresentableWindows(_ workspace: Workspace) -> [Window] {
    macosNotPresentableWindowsContainer.children.filterIsInstance(of: Window.self).filter {
        switch $0.layoutReason {
            case .macos(_, let prevWorkspaceName): prevWorkspaceName == workspace.name
            case .standard: false
        }
    }
}

/// Tabs mode: a tab on screen that its last window left by being set aside: not listed, so it gives its display to
/// another tab as a tab left empty does (`leaveTabsLeftEmptyOnScreen`), though it's kept for its window to come back.
@MainActor
func workspaceTabWasLeftEmptyBySetAside(_ tab: Workspace) -> Bool {
    config.usesBrowserTabs && !tab.isArchived && !workspaceTabIsShown(tab) && WorkspaceLauncherPanel.shared.workspace !== tab &&
        !workspaceOwnedNotPresentableWindows(tab).isEmpty
}
