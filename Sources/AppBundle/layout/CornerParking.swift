import AppKit
import Common

/// Where WinMux parked a hidden window, and whether the window has been seen there since.
///
/// A park is a queued AX write. The app can fail it (busy right after wake), and macOS can undo
/// it (a display going away, wake from sleep) without any event reaching WinMux. So a park
/// counts as confirmed only once the window's observed frame is at the target; until then each
/// layout pass looks at the window again and re-parks it. That state lives here, not in the
/// window's frame cache, which other code refills. Unconfirmed parks per target are bounded:
/// once they run out the park is blocked, and no further write is issued for it. A reassertion
/// (wake, a settled display change) or a new target earns more parks. A new native event for the
/// window (not a failed read) earns a look, and what the look sees decides: still where it was
/// last seen (where the app keeps it, or the echo of WinMux's own last write) is no news, so no
/// write; somewhere else (the app or the user moved it, so the app is answering again) is, and
/// earns the park a fresh budget.
struct HiddenWindowParking: Equatable {
    static let maxUnconfirmedParks = 3
    /// How far an observed position may be from the target and still count as parked.
    static let positionTolerance: CGFloat = 1

    enum Outcome: Equatable {
        /// The window was observed at the target.
        case confirmed
        /// The next layout pass must look at the window again and park it again.
        case unconfirmed
        /// Stop re-checking until a reassertion, a new target or a new native event.
        case retriesExhausted
    }

    private(set) var corner: OptimalHideCorner?
    private(set) var monitorVisibleRect: Rect?
    private(set) var target: CGPoint?
    private(set) var unconfirmedParks = 0
    private(set) var isConfirmed = false
    /// The window's native-state generation when retries ran out.
    private(set) var exhaustedAtNativeGeneration: UInt64?
    /// Where the window's top-left corner was last seen while not at the target; nil if it couldn't be read.
    private(set) var lastSeenAwayFromTarget: CGPoint?

    /// What the parking has come to; nil before any park.
    var outcome: CornerParkOutcome? {
        guard target != nil else { return nil }
        if isConfirmed { return .confirmed }
        if exhaustedAtNativeGeneration != nil {
            return .blocked(.notSeenAtTarget(lastSeen: lastSeenAwayFromTarget))
        }
        return .pending
    }

    /// Whether the window was last parked in `corner` against this monitor geometry.
    func isParked(in corner: OptimalHideCorner, on monitorVisibleRect: Rect) -> Bool {
        self.corner == corner && self.monitorVisibleRect == monitorVisibleRect
    }

    /// A park was issued but not yet seen to take effect: the next pass must look again.
    var awaitsConfirmation: Bool { target != nil && !isConfirmed && exhaustedAtNativeGeneration == nil }

    /// Whether a dropped frame cache justifies another look. Once retries ran out, only a native
    /// event since then does; a read that keeps failing doesn't.
    func mayRetry(atNativeGeneration generation: UInt64) -> Bool {
        exhaustedAtNativeGeneration.map { $0 != generation } ?? true
    }

    /// Whether `observed` shows the window somewhere it wasn't last seen, or seen for the first time.
    private func hasMovedSinceLastSeen(_ observed: Rect) -> Bool {
        guard let lastSeen = lastSeenAwayFromTarget else { return true }
        return abs(observed.topLeftX - lastSeen.x) > Self.positionTolerance ||
            abs(observed.topLeftY - lastSeen.y) > Self.positionTolerance
    }

    /// Records a park at `target`. `observed` is the window's frame as last observed before the write.
    mutating func park(
        corner: OptimalHideCorner,
        monitorVisibleRect: Rect,
        target: CGPoint,
        observed: Rect?,
        reasserting: Bool,
        nativeGeneration: UInt64,
    ) -> Outcome {
        if reasserting || self.corner != corner || self.monitorVisibleRect != monitorVisibleRect || self.target != target ||
            exhaustedAtNativeGeneration != nil && observed.map(hasMovedSinceLastSeen) == true
        {
            unconfirmedParks = 0
            exhaustedAtNativeGeneration = nil
        }
        self.corner = corner
        self.monitorVisibleRect = monitorVisibleRect
        self.target = target
        if let observed,
           abs(observed.topLeftX - target.x) <= Self.positionTolerance,
           abs(observed.topLeftY - target.y) <= Self.positionTolerance
        {
            unconfirmedParks = 0
            isConfirmed = true
            exhaustedAtNativeGeneration = nil
            lastSeenAwayFromTarget = nil
            return .confirmed
        }
        isConfirmed = false
        // A failed read says nothing about where it is: the last position seen stays. While the park is blocked, a
        // look that found no move leaves it too, so steps each within the tolerance can't walk it along (Carbon
        // ASD-R2-N1): a move is measured from where the park was blocked.
        if exhaustedAtNativeGeneration == nil, let observed { lastSeenAwayFromTarget = observed.topLeftCorner }
        unconfirmedParks += 1
        if unconfirmedParks <= Self.maxUnconfirmedParks { return .unconfirmed }
        exhaustedAtNativeGeneration = nativeGeneration
        return .retriesExhausted
    }
}

/// Whether a window WinMux hides is hidden, as far as WinMux has seen.
enum CornerParkOutcome: Equatable {
    /// Seen at its corner target.
    case confirmed
    /// Parked, not yet seen at the target: the next layout pass looks again.
    case pending
    /// Not hidden, and WinMux won't move it again until something changes.
    case blocked(CornerParkBlock)
}

enum CornerParkBlock: Equatable {
    /// Every park allowed for this target (`HiddenWindowParking.maxUnconfirmedParks`) was issued and
    /// the window was never seen there. `lastSeen` is its top-left corner where the park was blocked,
    /// nil if no read worked. A reassertion, a new target, or a look that finds it moved more than the
    /// tolerance away from `lastSeen` earns new parks.
    case notSeenAtTarget(lastSeen: CGPoint?)
    /// Its display is a placeholder for one that went away, so there is no corner to park in.
    case placeholderDisplay
    /// Its frame couldn't be read, so where to put it back couldn't be recorded. The next pass tries again.
    case frameUnreadable
}

/// A window's corner-parking state.
final class CornerParkingState {
    /// Where to put a floating window back, relative to its monitor. Set while hidden.
    var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?
    /// The corner the window is parked in, together with the monitor rect it was parked
    /// against: when the monitor's geometry changes (or the workspace moves to another
    /// monitor), the old corner position is wrong and the window must be re-parked even
    /// though the corner still matches. Also whether the park has been seen to take effect.
    var parking = HiddenWindowParking()
    /// Why the window couldn't even be parked, on the last attempt.
    fileprivate(set) var notParkedBecause: CornerParkBlock?

    var isHiddenInCorner: Bool { prevUnhiddenProportionalPositionInsideWorkspaceRect != nil }

    /// What the last attempt to hide the window came to; nil while WinMux isn't hiding it.
    var outcome: CornerParkOutcome? { notParkedBecause.map(CornerParkOutcome.blocked) ?? parking.outcome }
}

extension Window {
    /// Parks the window in a bottom corner of its monitor, so that only a pixel of it is on
    /// screen. MacWindow's implementation; tests run it against fake native windows.
    ///
    /// A window already parked here costs nothing unless something says it may have moved: the
    /// session reasserts (macOS may have moved it without an event), the last park isn't
    /// confirmed yet, or its frame cache was dropped by a geometry event.
    ///
    /// Returns what hiding the window came to, or nil when `ifStillValid` says a newer layout took over.
    @MainActor
    @discardableResult
    func parkInCorner(
        _ corner: OptimalHideCorner,
        _ state: CornerParkingState,
        reassert: Bool,
        onePixelOffset: Bool,
        ifStillValid: () -> Bool,
    ) async throws -> CornerParkOutcome? {
        guard ifStillValid() else { return nil }
        // Hidden now: before any AX read below can suspend, a follow-up for the cell it had mustn't write it back there.
        relinquishFrameFit()
        // No parking against a placeholder display: the position would be arbitrary.
        guard let nodeMonitor, !nodeMonitor.isFallbackMonitor else { return state.notParked(.placeholderDisplay, windowId) }
        if state.notParkedBecause == .placeholderDisplay { state.notParkedBecause = nil }
        var observedJustNow = false
        if state.isHiddenInCorner, state.parking.isParked(in: corner, on: nodeMonitor.visibleRect) {
            let cacheDropped = lastKnownActualRect == nil
            guard reassert || state.parking.awaitsConfirmation ||
                cacheDropped && state.parking.mayRetry(atNativeGeneration: nativeStateObservationToken())
            else { return state.outcome }
            // The cache can't be trusted when reasserting; otherwise a refilled cache is fresh.
            if reassert || cacheDropped {
                _ = try? await getAxRect()
                observedJustNow = true
                try checkCancellation()
                guard ifStillValid() else { return nil }
            }
        }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        var unhiddenPosition: CGPoint?
        if !state.isHiddenInCorner {
            guard let windowRect = try await getAxRect() else { return state.notParked(.frameUnreadable, windowId) }
            observedJustNow = true
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !state.isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                unhiddenPosition =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                // Parking drops the actual-frame cache. Keep the freshly observed floating
                // size for restore's clamp when that cache is unavailable (upstream 649301b2).
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        // Record the corner actually used, so a failed size read is retried on the next layout
        var appliedCorner = corner
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize() else {
                    appliedCorner = .bottomRightCorner
                    fallthrough
                }
                let offset = onePixelOffset ? CGPoint(x: 1, y: -1) : .zero
                p = nodeMonitor.visibleRect.bottomLeftCorner + offset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                let offset = onePixelOffset ? CGPoint(x: 1, y: 1) : .zero
                p = nodeMonitor.visibleRect.bottomRightCorner - offset
        }
        // AX reads above can suspend while another tab is selected. Do not let the old
        // layout park that tab or mark it hidden after a newer presentation has started.
        try checkCancellation()
        guard ifStillValid() else { return nil }
        if state.prevUnhiddenProportionalPositionInsideWorkspaceRect == nil {
            state.prevUnhiddenProportionalPositionInsideWorkspaceRect = unhiddenPosition
        }
        // The write is only queued: it may fail, or macOS may move the window back. Unless the
        // window was just observed at the target, look again on the next pass.
        let before = state.outcome
        state.notParkedBecause = nil
        let outcome = state.parking.park(corner: appliedCorner, monitorVisibleRect: nodeMonitor.visibleRect, target: p,
                                         observed: lastKnownActualRect, reasserting: reassert,
                                         nativeGeneration: nativeStateObservationToken())
        switch outcome {
            // In place, as just observed. Even a no-op frame submission would hold off the
            // app's browser-tab reads.
            case .confirmed where observedJustNow: return state.outcome
            // Also drops observations in flight from before the write.
            case .unconfirmed: invalidateLastKnownActualRect()
            case .confirmed: break
            // Every park this target allows has been issued: another write would be one more
            // the window has already ignored. Say so once, then leave it where it is.
            case .retriesExhausted:
                if state.outcome != before { state.recordBlocked(windowId, workspace: nodeWorkspace?.name) }
                return state.outcome
        }
        WindowLifecycleLog.shared.record(.parked, windowId: windowId, [
            "corner": "\(appliedCorner)", "outcome": "\(outcome)", "reassert": "\(reassert)", "workspace": nodeWorkspace?.name ?? "",
        ])
        setAxFrame(p, nil)
        return state.outcome
    }

    /// Ends a park. Floating windows go back to where they were, relative to their monitor;
    /// tiling windows are placed by the layout.
    @MainActor
    func restoreFromCorner(_ state: CornerParkingState) {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect = state.prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        func restoreToSavedWorkspacePosition() {
            let workspaceRect = nodeWorkspace.workspaceMonitor.rect
            var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
            var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
            let windowWidth = lastKnownActualRect?.width ?? lastFloatingSize?.width ?? 0
            let windowHeight = lastKnownActualRect?.height ?? lastFloatingSize?.height ?? 0
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))
            // The cached rect may be the parked one, and the move's events may be suppressed
            // after a drag.
            invalidateLastKnownActualRect()
            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                restoreToSavedWorkspacePosition()
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        state.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
        state.parking = HiddenWindowParking()
        state.notParkedBecause = nil
        WindowLifecycleLog.shared.record(.unparked, windowId: windowId, ["workspace": nodeWorkspace.name])
    }
}

extension CornerParkingState {
    /// Records that the window couldn't be parked at all this time, and logs it when that's news.
    @MainActor
    fileprivate func notParked(_ reason: CornerParkBlock, _ windowId: UInt32) -> CornerParkOutcome? {
        if notParkedBecause != reason {
            notParkedBecause = reason
            WindowLifecycleLog.shared.record(.parkBlocked, windowId: windowId, ["reason": reason.logText])
        }
        return outcome
    }

    @MainActor
    fileprivate func recordBlocked(_ windowId: UInt32, workspace: String?) {
        guard case .blocked(let reason)? = outcome else { return }
        WindowLifecycleLog.shared.record(.parkBlocked, windowId: windowId, [
            "reason": reason.logText, "target": parking.target.map { "\(Int($0.x)),\(Int($0.y))" } ?? "",
            "workspace": workspace ?? "",
        ])
    }
}

extension CornerParkBlock {
    var logText: String {
        switch self {
            case .notSeenAtTarget(let lastSeen):
                "notSeenAtTarget lastSeen=" + (lastSeen.map { "\(Int($0.x)),\(Int($0.y))" } ?? "unread")
            case .placeholderDisplay: "placeholderDisplay"
            case .frameUnreadable: "frameUnreadable"
        }
    }
}
