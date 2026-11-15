@testable import AppBundle
import AppKit

// Tombstones were removed on 2026-11-15, by the coordinator's decision: `confirmedClosed`, the off-screen transition that
// lifted one and the 15 s bound. A window let go is registered again, as a new window, whenever its app lists it, so no
// live window is ever shut out; a ghost an element brings back for a window that did close goes once the window server
// lets it go (row 1b). Reviewers' round-3, round-4 and round-5 reproducers still name that API. These keep their files
// compiling byte-identical, giving the new rule's answers: nothing is confirmed closed, and nothing is shut out.

extension WindowLivenessLedger {
    var confirmedClosed: Set<UInt32> { [] }
    var closedSeenOffScreen: Set<UInt32> { [] }
    func mayReturn(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Set<UInt32> { [] }
    func closedLingering(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Set<UInt32> { [] }

    func mayRegister(_ windowId: UInt32, windowServer: @autoclosure () -> WindowServerWindowList,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool { true }

    mutating func commit(_ refresh: WindowServerWindowList, now: TimeInterval) -> RegisteredWindowsRefresh<W>? {
        commit(refresh)
    }
}

/// The refresh as reviewers' reproducers call it, with the tombstone sets they pass, which nothing reads any more.
func refreshRegisteredAxWindows<W: RegisteredWindowLiveness, Element>(
    _ registered: [UInt32: W], frontmostAppBundleId: String?, windowServer: WindowServerWindowList,
    listed: () -> [(UInt32, Element)]?, rebind: (_ stale: W, _ fresh: Element) throws -> W?,
    register: (_ alive: inout [UInt32: W], _ windowId: UInt32, _ element: Element) throws -> Void,
    confirmedClosed: Set<UInt32>, closedSeenOffScreen: Set<UInt32> = [], closedLingering: Set<UInt32> = [],
    appHidden: Bool = false, setAside: Set<UInt32> = [], _ job: RunLoopJob,
) throws -> RegisteredWindowsRefresh<W> {
    try refreshRegisteredAxWindows(registered, frontmostAppBundleId: frontmostAppBundleId, windowServer: windowServer,
        listed: listed, rebind: rebind, register: register, appHidden: appHidden, setAside: setAside, job)
}
