@testable import AppBundle
import AppKit
import Common
import XCTest

// The frame-fit tests' calls into it, as layout, its follow-ups and the display observer make them.

/// A layout's write of `window` into `cell`, on display `monitor` (`display` is its rectangle, kept for the record) in
/// frame-fit epoch `epoch`, at `now` on the monotonic clock. `continuing`: the follow-up an earlier write asked for.
@discardableResult
func layFrame<W: AxFrameAccess>(_ window: W, cell: Rect, bounds: Rect, display: Rect, monitor: Int, epoch: UInt64, now: TimeInterval,
                                continuing: Bool = false, fit: inout WindowFrameFit, job: RunLoopJob = RunLoopJob()) throws -> Rect? {
    try setFrame(window, cell.topLeftCorner, cell.size, fit: &fit, within: bounds, target: FrameFitTarget(monitor: monitor, epoch: epoch),
        continuing: continuing, now: now, job)
}

/// A write that isn't a layout's: a move alone (`size` nil), or a frame as asked.
@discardableResult
func writeFrame<W: AxFrameAccess>(_ window: W, _ topLeft: CGPoint?, _ size: CGSize?, fit: inout WindowFrameFit) throws -> Rect? {
    try setFrame(window, topLeft, size, fit: &fit, RunLoopJob())
}

func learnedSize(_ fit: WindowFrameFit) -> CGSize? { fit.heldSize }
func followUpTime(_ fit: WindowFrameFit) -> TimeInterval? { fit.followUpAt }

@MainActor func startFrameFitTestClock() { FrameFitFollowUps.shared.startManualClockForTests(at: 1000) }
@MainActor func stopFrameFitTestClock() { FrameFitFollowUps.shared.stopManualClockForTests() }
/// Time passes: follow-ups due by then run.
@MainActor func advanceFrameFitTestClock(by delay: TimeInterval) { FrameFitFollowUps.shared.advanceManualClockForTests(by: delay) }
/// NSWorkspace.screensDidWake / didWake.
@MainActor func noteScreensWokeForFrameFit() { MonitorConfigurationObserver.shared.noteScreensWoke() }

struct FitTestMonitor: Monitor {
    let monitorAppKitNsScreenScreensId = 1
    let name = "Fit"
    let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1440, height: 900)
    let visibleRect = Rect(topLeftX: 0, topLeftY: 25, width: 1440, height: 875)
    let isMain = true
    let displayIdentity: MonitorDisplayIdentity? = MonitorDisplayIdentity(uuid: "FIT", isBuiltin: true)
    let isFallbackMonitor = false
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}

/// A window whose app is simulated, laid out by the real layout and written through the real
/// `setFrame`, with its fit kept as MacApp keeps it with the AX window.
final class FrameFitTestWindow: Window {
    let native: SimulatedAppWindow
    private var fit = WindowFrameFit()
    fileprivate let cornerParking = CornerParkingState()
    /// Run as the window's frame is read, before it's returned: time passing while a park waits on AX, say.
    var onGetAxRect: () -> Void = {}

    @MainActor init(id: UInt32, parent: NonLeafTreeNodeObject, native: SimulatedAppWindow) {
        self.native = native
        super.init(id: id, TestApp.shared, lastFloatingSize: native.frame.size, parent: parent, adaptiveWeight: 1,
            index: INDEX_BIND_LAST)
        recordAuthoritativeActualRect(native.frame)
    }

    @MainActor override var title: String { get async { "Fit \(windowId)" } }
    override var isHiddenInCorner: Bool { cornerParking.isHiddenInCorner }

    @MainActor override func getAxRect() async throws -> Rect? {
        onGetAxRect()
        let token = nativeStateObservationToken()
        recordObservedActualRect(native.frame, token: token)
        return native.frame
    }

    @MainActor override func getAxSize() async throws -> CGSize? { native.frame.size }

    override func writeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        _ = try? setFrame(native, topLeft, size, fit: &fit, RunLoopJob())
    }

    /// As MacApp does it, minus the thread hop: the token taken before the write, what was read back and when to look
    /// again handed back after, on the follow-ups' clock.
    @MainActor override func writeLayoutFrame(_ cell: Rect, within bounds: Rect, target: FrameFitTarget, continuing: Bool) {
        let token = nativeStateObservationToken()
        let frame = (try? setFrame(native, cell.topLeftCorner, cell.size, fit: &fit, within: bounds, target: target, continuing: continuing,
            now: FrameFitFollowUps.shared.now(), RunLoopJob())) ?? nil
        didWriteLayoutFrame(frame, in: cell, target: target, token: token, followUpAt: fit.followUpAt)
    }
}

extension FrameFitTestWindow: WorkspaceWindowVisibility {
    func hideInCorner(_ corner: OptimalHideCorner, reassert: Bool, ifStillValid: () -> Bool) async throws {
        try await parkInCorner(corner, cornerParking, reassert: reassert, onePixelOffset: true, ifStillValid: ifStillValid)
    }

    func unhideFromCorner() { restoreFromCorner(cornerParking) }
}
