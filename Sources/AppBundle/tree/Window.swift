import AppKit
import Common

let windowRecentlyOpenedLimit: TimeInterval = 5

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    /// Which tab a minimized or hidden window still belongs to, among others: a change is a change of
    /// its place, which `placementStamp` counts.
    var layoutReason: LayoutReason = .standard {
        didSet { if layoutReason != oldValue { placementStamp.bump() } }
    }
    /// Counts every change of where the window is: bound elsewhere, unbound, or its layout reason
    /// changed. Read from an app's AX thread, where a close agreed to for one place must not press
    /// once the window is in another.
    nonisolated let placementStamp = WindowPlacementStamp()
    /// Event-invalidated caches of the native window state (frame, fullscreen, minimized),
    /// read on hot paths instead of polling every window over AX. Entering/exiting native
    /// fullscreen always resizes the window (invalidated via moved/resized events); minimize
    /// state changes emit miniaturized/deminiaturized events. nil means "no observation since
    /// the last event" and readers must fetch live.
    ///
    /// Writes go through the record methods below: an async AX observation races the very
    /// events that invalidate these caches, and a stale value written back after the
    /// transition's events were consumed would look valid forever (nothing would invalidate
    /// it again). Observed values are therefore discarded unless the generation captured
    /// before the fetch is still current.
    @MainActor private(set) var lastKnownActualRect: Rect? = nil
    @MainActor private(set) var lastKnownNativeFullscreen: Bool? = nil
    @MainActor private(set) var lastKnownNativeMinimized: Bool? = nil
    @MainActor private var lastKnownNativeStateGeneration: UInt64 = 0

    @MainActor
    func invalidateLastKnownNativeState() {
        lastKnownNativeStateGeneration += 1
        lastKnownActualRect = nil
        lastKnownNativeFullscreen = nil
        lastKnownNativeMinimized = nil
    }

    /// Capture before starting an async AX observation and pass to the matching record method.
    @MainActor
    func nativeStateObservationToken() -> UInt64 { lastKnownNativeStateGeneration }

    @MainActor
    func recordObservedActualRect(_ rect: Rect?, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            lastKnownActualRect = rect
        }
    }

    @MainActor
    func recordObservedNativeState(fullscreen: Bool, minimized: Bool, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            lastKnownNativeFullscreen = fullscreen
            lastKnownNativeMinimized = minimized
        }
    }

    @MainActor
    func recordObservedNativeFullscreen(_ fullscreen: Bool, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            lastKnownNativeFullscreen = fullscreen
        }
    }

    /// For writers that know the current frame because they just set or saved it themselves
    /// (interaction-opacity parking/restore, initial registration). Supersedes any in-flight
    /// observation so a slow fetch can't clobber the deliberately written value.
    @MainActor
    func recordAuthoritativeActualRect(_ rect: Rect?) {
        lastKnownNativeStateGeneration += 1
        lastKnownActualRect = rect
    }

    /// Where layout last placed the window when the app keeps a size of its own in its cell: the
    /// cell, and the frame the window has there. Not an observation: AX events don't drop it, a new
    /// cell makes it stale (`layoutPlacedRect`).
    @MainActor private(set) var layoutFrameFit: (cell: Rect, frame: Rect)? = nil

    /// The frame a layout write left the window at in `cell`, as its app's thread read it back. A report
    /// for a cell layout has since replaced says nothing about where the window is placed now.
    @MainActor
    func recordLayoutFrame(_ frame: Rect, in cell: Rect, token: UInt64) {
        recordObservedActualRect(frame, token: token)
        guard let current = lastAppliedLayoutPhysicalRect, current.isApproximatelyEqual(to: cell, tolerance: 0.5) else { return }
        layoutFrameFit = frame.isApproximatelyEqual(to: cell, tolerance: 1) ? nil : (cell, frame)
    }

    /// Where layout put the window: its cell, or where in the cell the app keeps it at a size of its
    /// own. Nil when the window isn't laid out in a cell.
    @MainActor
    var layoutPlacedRect: Rect? {
        guard let cell = lastAppliedLayoutPhysicalRect else { return nil }
        guard let fit = layoutFrameFit, fit.cell.isApproximatelyEqual(to: cell, tolerance: 0.5) else { return cell }
        return fit.frame
    }

    /// For writers that move the window without learning the resulting frame (layout: an app
    /// may clamp it). The move's own AX events are suppressed right after a drag, so they can't
    /// be relied on to invalidate. Also discards observations in flight from before the move.
    /// A move doesn't change the fullscreen or minimized state, so those cached values stay.
    @MainActor
    func invalidateLastKnownActualRect() {
        lastKnownNativeStateGeneration += 1
        lastKnownActualRect = nil
    }

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? (Workspace.all.flatMap { $0.allLeafWindowsRecursive } + macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self) +
                macosPopupWindowsContainer.children.filterIsInstance(of: Window.self)).first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    /// When WinMux first saw the window, on the monotonic clock so a clock change can't age
    /// it. Time asleep doesn't count. Tests set it to model an older window.
    @MainActor var firstSeenUptime = ProcessInfo.processInfo.systemUptime
    /// A window already open at startup or put back by a restore.
    @MainActor var wasFirstSeenDuringStartupOrRestored: Bool { false }
    /// A window opened moments ago. One first seen as a popup and promoted later only
    /// counts while it is this new, so a window already in use is never moved as new.
    @MainActor var wasOpenedRecently: Bool {
        !wasFirstSeenDuringStartupOrRestored &&
            ProcessInfo.processInfo.systemUptime - firstSeenUptime < windowRecentlyOpenedLimit
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize() async throws -> CGSize? { die("Not implemented") }
    var title: String { get async throws { die("Not implemented") } }
    var isMacosFullscreen: Bool { get async throws { false } }
    var isMacosMinimized: Bool { get async throws { false } } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    /// Where it's parked, for a debug snapshot: nil for a window WinMux doesn't park.
    var cornerParkingForDebug: CornerParkingState? { nil }
    @MainActor
    func nativeFocus() { die("Not implemented") }
    func getAxRect() async throws -> Rect? { die("Not implemented") }
    func getCenter() async throws -> CGPoint? { try await getAxRect()?.center }

    /// Every frame write that isn't a layout's own (a move alone or a park, a frame put back, a tab strip or drag
    /// action): layout no longer owns where the window goes, so a follow-up pending for its last cell, which would undo
    /// this, is dropped first, here on the main actor before the write reaches the app (`relinquishFrameFit`).
    @MainActor
    final func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        relinquishFrameFit()
        writeAxFrame(topLeft, size)
    }

    /// The write itself: a real window's on its app's AX thread.
    func writeAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }

    /// The cell layout last wrote the window into, the area around it, and where: what a follow-up continues.
    @MainActor private(set) var frameFitLayout: (cell: Rect, bounds: Rect, target: FrameFitTarget)? = nil
    /// Moves on when the user resizes the window or it leaves tiling: what its app made of a cell before is asked again.
    @MainActor private(set) var frameFitArming: UInt64 = 0
    /// Laid out in a cell since it was last rearmed: leaving tiling then starts its fit over. A park or a frame write drops
    /// `frameFitLayout` with its follow-up, but not this, so a window parked before it's minimized is asked anew when
    /// it's back. Until it's laid out again, layout doesn't reuse a frame it wrote before (`canReuseLastAppliedWindowFrame`).
    @MainActor private(set) var frameFitLaidOut = false

    /// Lays the window out in `cell`, on the display `monitor`, in frame-fit epoch `epoch`. An app that keeps a size of
    /// its own there isn't asked again for a cell that size: its window is centered in it, or kept inside `bounds` where
    /// it's larger (`layoutPlacedRect`). How often a size is asked for is bounded (`WindowFrameFit`).
    @MainActor
    final func setAxLayoutFrame(_ cell: Rect, within bounds: Rect, monitor: Int, epoch: UInt64) {
        let target = FrameFitTarget(monitor: monitor, epoch: epoch, arming: frameFitArming)
        frameFitLayout = (cell, bounds, target)
        frameFitLaidOut = true
        FrameFitFollowUps.shared.cancel(windowId)
        writeLayoutFrame(cell, within: bounds, target: target, continuing: false)
    }

    /// The write itself: a real window's on its app's AX thread, which hands back what it read
    /// (`didWriteLayoutFrame`). `continuing`: a follow-up.
    @MainActor
    func writeLayoutFrame(_ cell: Rect, within bounds: Rect, target: FrameFitTarget, continuing: Bool) {
        if !continuing { writeAxFrame(cell.topLeftCorner, cell.size) }
    }

    /// A layout write into `cell` with `target` left the window at `frame` (when that's news), and wants another look at
    /// `followUpAt`: scheduled, unless layout has written the window elsewhere since.
    @MainActor
    func didWriteLayoutFrame(_ frame: Rect?, in cell: Rect, target: FrameFitTarget, token: UInt64, followUpAt: TimeInterval?) {
        if let frame { recordLayoutFrame(frame, in: cell, token: token) }
        guard let followUpAt, let layout = frameFitLayout, layout.cell == cell, layout.target == target else { return }
        FrameFitFollowUps.shared.schedule(windowId, at: followUpAt, cell: cell, target: target)
    }

    /// A follow-up: the same write again, as long as layout still has the window in that cell on that display, in that
    /// epoch, shown, and not in the user's hands. Whatever layout passes reuse, and whatever AX events are suppressed.
    /// Checked right before the write: layout hiding the window (an inactive tab, a window behind a full-screen one)
    /// takes its cell away first.
    @MainActor
    func continueLayoutFrame(_ cell: Rect, target: FrameFitTarget) {
        let inCell = lastAppliedLayoutPhysicalRect.map { $0 == cell } ?? isFullscreen
        guard inCell, let layout = frameFitLayout, layout.cell == cell, layout.target == target,
              target.epoch == MonitorConfigurationObserver.shared.frameFitEpoch, target.arming == frameFitArming,
              let workspace = nodeWorkspace, workspace.isVisible,
              workspace.workspaceMonitor.monitorAppKitNsScreenScreensId == target.monitor,
              !isHiddenInCorner, currentlyManipulatedWithMouseWindowId != windowId
        else { return }
        writeLayoutFrame(cell, within: layout.bounds, target: target, continuing: true)
    }

    /// The user resized the window, or it left tiling: its app is asked anew about the next cell it's laid out in,
    /// whatever it kept before. A raw kAXResized never does this: it can't tell the user from the app.
    @MainActor
    func rearmFrameFit() {
        frameFitArming &+= 1
        frameFitLaidOut = false
        relinquishFrameFit()
    }

    /// Something other than this layout's own follow-up now decides where the window goes: a frame write, a park, the
    /// window closing. Its pending follow-up is dropped, and none can be scheduled for the cell it had until layout
    /// writes it into one again. What its app was found to keep stays: that's per cell size, on the app's thread.
    @MainActor
    func relinquishFrameFit() {
        frameFitLayout = nil
        FrameFitFollowUps.shared.cancel(windowId)
    }

    /// Bound with `relation` to its new parent: floating, minimized, full screen or hidden, it has left tiling. The cell
    /// it had is no longer where layout puts it: a return to a cell of the same place is written anew, not taken for one
    /// written already. (Not on a rearm itself: a mouse resize reads the cell after rearming.)
    @MainActor
    func noteFrameFitRelation(_ relation: ChildParentRelation) {
        switch relation {
            case .tiling, .rootTilingContainer, .shimContainerRelation: break
            case .floatingWindow, .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow, .macosPopupWindow:
                lastAppliedLayoutPhysicalRect = nil
                lastAppliedLayoutVirtualRect = nil
                layoutFrameFit = nil
                if frameFitLaidOut { rearmFrameFit() }
        }
    }
}

enum LayoutReason: Codable, Equatable, Sendable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind, prevWorkspaceName: String?)
}

extension Window {
    var isFloating: Bool { parent is Workspace } // todo drop. It will be a source of bugs when sticky is introduced

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    @MainActor
    func rememberMacOsLayoutOrigin(detachFromWorkspace: Bool = false) {
        guard let parent else { return }
        layoutReason = .macos(
            prevParentKind: parent.kind,
            prevWorkspaceName: detachFromWorkspace ? nil : nodeWorkspace?.name,
        )
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}

/// A count of a window's moves, readable from any thread.
final class WindowPlacementStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func bump() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
