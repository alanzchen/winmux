@testable import AppBundle
import AppKit
import XCTest

// The liveness tests' calls into the decision a refresh makes for each registered window, and into what refresh does
// with a window that's gone.

/// A registered window as a refresh probes it: what its own AX query answers, and how often it was asked.
final class FakeLivenessWindow: RegisteredWindowLiveness {
    var answer: (windowId: CGWindowID?, error: AXError)
    var windowServerAbsences = 0
    let livenessStamp = nextWindowLivenessStamp()
    private(set) var probes = 0
    init(_ answer: (windowId: CGWindowID?, error: AXError)) { self.answer = answer }
    func containingWindowIdWithError() -> (windowId: CGWindowID?, error: AXError) {
        probes += 1
        return answer
    }
}

/// The window server listing `listed` (nil: it gave no list), the windows in `shown` on screen, those in `orderedOut`
/// ordered out and the rest ordered in; with `orderingUnknown`, whether any is ordered in isn't known (the private call
/// unavailable).
func livenessWindowServer(listed: Set<UInt32>?, shown: Set<UInt32> = [], orderedOut: Set<UInt32> = [],
                          orderingUnknown: Bool = false) -> WindowServerWindowList
{
    WindowServerWindowList(orderedIn: { orderingUnknown ? nil : !orderedOut.contains($0) },
        readWindows: { listed.map { Dictionary(uniqueKeysWithValues: $0.map { ($0, shown.contains($0)) }) } })
}

/// One committed refresh of `windows`, as an app's refresh makes it (`refreshRegisteredAxWindows`): the window server
/// listing `listed` (nil: it gave no list) with `shown` on screen, the app's AXWindows naming `appLists` (other windows,
/// not followed here; nil when it couldn't be read), and `frontmost` in front. The ids kept, whether it asked for a
/// confirming refresh, the ids kept unbound, and those left waiting on the window server.
@discardableResult
func refreshWindowLiveness(_ windows: inout [UInt32: FakeLivenessWindow], listed: Set<UInt32>?, shown: Set<UInt32> = [],
                           frontmost: String? = nil, appLists: [UInt32]? = [])
    -> (kept: Set<UInt32>, confirming: Bool, unbound: Set<UInt32>, awaiting: Set<UInt32>)
{
    let list = livenessWindowServer(listed: listed, shown: shown)
    let named = appLists?.map { ($0, FakeLivenessWindow(($0, .success))) }
    guard let refreshed = try? refreshRegisteredAxWindows(windows, frontmostAppBundleId: frontmost, windowServer: list,
        listed: { named }, rebind: { _, fresh in fresh }, register: { _, _, _ in }, RunLoopJob())
    else { return (Set(windows.keys), false, [], []) }
    refreshed.commit()
    windows = refreshed.alive
    return (Set(refreshed.alive.keys), refreshed.asksForConfirmation, refreshed.unbound, refreshed.awaitsWindowServer)
}

/// The window list a refresh would go by, from the session's state and the window server's answer.
func livenessWindowList(session: [String: Any]?, windows: [[String: Any]]?) -> Set<UInt32>? {
    windowServerWindowIdsForLiveness(session: session, windows: windows)
}

/// What a window that's gone leaves, as refresh's garbage collection does it for a real window (`MacWindow.garbageCollect`),
/// minus the closed-windows cache: window ids repeat across tests.
@MainActor
func letGoOfGoneWindow(_ window: Window) {
    syncWorkspaceSidebarPinCompositions()
    window.forgetClosedWindow(skipClosedWindowsCache: true)
}

// One app's refresh of its registered windows, as MacApp.refreshAndGetAliveWindowIds runs it
// (`refreshRegisteredAxWindows`): a new window is registered through the same guarded path as a real one, refused while
// the mouse button is down; a stale one is rebound to its fresh element.

/// One app's refresh of `registered`: the window server listing `listed` with `shown` on screen, the app's AXWindows
/// listing `appLists` (window id and the element it has now; nil when it couldn't be read), with the mouse button
/// `mouseDown`. The windows kept, the ids reported dead (whose pending frame jobs MacApp cancels), and those kept unbound.
@discardableResult
func refreshAppWindowRegistry(_ registered: inout [UInt32: FakeLivenessWindow], listed: Set<UInt32>?, shown: Set<UInt32> = [],
                              appLists: [(UInt32, FakeLivenessWindow)]?, mouseDown: Bool = false, freshElementTaken: Bool = true)
    -> (kept: [UInt32: FakeLivenessWindow], dead: Set<UInt32>, unbound: Set<UInt32>)
{
    let list = livenessWindowServer(listed: listed, shown: shown)
    guard let refreshed = try? refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil, windowServer: list,
        listed: { appLists }, rebind: { _, fresh in freshElementTaken ? fresh : nil },
        register: { alive, id, element in if alive[id] == nil && !mouseDown { alive[id] = element } }, RunLoopJob())
    else { return (registered, [], []) }
    refreshed.commit()
    registered = refreshed.alive
    return (refreshed.alive, Set(refreshed.dead.keys), refreshed.unbound)
}

/// One app's committed refresh as refresh() makes it, then normalizeLayoutReason as the session runs it next: windows'
/// presentability noted, those not presentable set aside, those presentable again brought back.
@MainActor
@discardableResult
func refreshPresentability(_ registered: inout [UInt32: FakeLivenessWindow], listed: Set<UInt32>?, shown: Set<UInt32> = [],
                           orderedOut: Set<UInt32> = [], orderingUnknown: Bool = false,
                           appLists: [(UInt32, FakeLivenessWindow)]? = [], appHidden: Bool = false) async throws
    -> RegisteredWindowsRefresh<FakeLivenessWindow>
{
    let list = livenessWindowServer(listed: listed, shown: shown, orderedOut: orderedOut, orderingUnknown: orderingUnknown)
    let setAside = Set(macosNotPresentableWindowsContainer.children.compactMap { ($0 as? Window)?.windowId })
    let refreshed = try refreshRegisteredAxWindows(registered, frontmostAppBundleId: nil, windowServer: list, listed: { appLists },
        rebind: { _, fresh in fresh }, register: { alive, id, element in if alive[id] == nil { alive[id] = element } },
        appHidden: appHidden, setAside: setAside, RunLoopJob())
    refreshed.commit()
    registered = refreshed.applied(to: registered)
    noteWindowPresentability(refreshed.presentable)
    try await normalizeLayoutReason()
    return refreshed
}
