import AppKit
import Common

/// Where WinMux parked a hidden window, and whether the window has been seen there since.
///
/// A park is a queued AX write. The app can fail it (busy right after wake), and macOS can undo
/// it (a display going away, wake from sleep) without any event reaching WinMux. So a park
/// counts as confirmed only once the window's observed frame is at the target. Until then the
/// caller drops the window's cached frame, which makes the next layout pass re-read and re-park
/// it. Unconfirmed parks per target are bounded, so an app that refuses the position can't make
/// every later pass write again; a reassertion (wake, a settled display change) starts over.
struct HiddenWindowParking: Equatable {
    static let maxUnconfirmedParks = 3
    /// How far an observed position may be from the target and still count as parked.
    static let positionTolerance: CGFloat = 1

    enum Outcome: Equatable {
        /// The window was observed at the target.
        case confirmed
        /// The next layout pass must re-read the window and park it again.
        case unconfirmed
        /// Stop re-checking; only a new trigger (event, reassertion, new target) parks again.
        case retriesExhausted
    }

    private(set) var corner: OptimalHideCorner?
    private(set) var monitorVisibleRect: Rect?
    private(set) var target: CGPoint?
    private(set) var unconfirmedParks = 0

    /// Whether the window was last parked in `corner` against this monitor geometry.
    func isParked(in corner: OptimalHideCorner, on monitorVisibleRect: Rect) -> Bool {
        self.corner == corner && self.monitorVisibleRect == monitorVisibleRect
    }

    /// Records a park at `target`. `observed` is the window's frame as last observed before the write.
    mutating func park(
        corner: OptimalHideCorner,
        monitorVisibleRect: Rect,
        target: CGPoint,
        observed: Rect?,
        reasserting: Bool,
    ) -> Outcome {
        if reasserting || self.corner != corner || self.monitorVisibleRect != monitorVisibleRect || self.target != target {
            unconfirmedParks = 0
        }
        self.corner = corner
        self.monitorVisibleRect = monitorVisibleRect
        self.target = target
        if let observed,
           abs(observed.topLeftX - target.x) <= Self.positionTolerance,
           abs(observed.topLeftY - target.y) <= Self.positionTolerance
        {
            unconfirmedParks = 0
            return .confirmed
        }
        unconfirmedParks += 1
        return unconfirmedParks <= Self.maxUnconfirmedParks ? .unconfirmed : .retriesExhausted
    }
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

    var isHiddenInCorner: Bool { prevUnhiddenProportionalPositionInsideWorkspaceRect != nil }
}

extension Window {
    /// Parks the window in a bottom corner of its monitor, so that only a pixel of it is on
    /// screen. MacWindow's implementation; tests run it against fake native windows.
    @MainActor
    func parkInCorner(
        _ corner: OptimalHideCorner,
        _ state: CornerParkingState,
        force: Bool,
        onePixelOffset: Bool,
        ifStillValid: () -> Bool,
    ) async throws {
        guard ifStillValid() else { return }
        // No parking against a placeholder display: the position would be arbitrary.
        guard let nodeMonitor, !nodeMonitor.isFallbackMonitor else { return }
        if !force, state.isHiddenInCorner, state.parking.isParked(in: corner, on: nodeMonitor.visibleRect) {
            return
        }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        var unhiddenPosition: CGPoint?
        if !state.isHiddenInCorner {
            guard let windowRect = try await getAxRect() else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !state.isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                unhiddenPosition =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
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
        guard ifStillValid() else { return }
        if state.prevUnhiddenProportionalPositionInsideWorkspaceRect == nil {
            state.prevUnhiddenProportionalPositionInsideWorkspaceRect = unhiddenPosition
        }
        // The write is only queued: it may fail, or macOS may move the window back. Unless the
        // window was just observed at the target, drop the cached frame so the next layout pass
        // re-reads and, if needed, re-parks it.
        switch state.parking.park(corner: appliedCorner, monitorVisibleRect: nodeMonitor.visibleRect, target: p,
                                  observed: lastKnownActualRect, reasserting: sessionRequiresHiddenWindowsReassertion())
        {
            case .unconfirmed: invalidateLastKnownActualRect()
            case .confirmed, .retriesExhausted: break
        }
        setAxFrame(p, nil)
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
    }
}
