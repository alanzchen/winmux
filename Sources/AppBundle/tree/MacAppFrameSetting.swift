import AppKit

/// A window's frame as WinMux reads and writes it over AX. Tests stand in a simulated app window.
protocol AxFrameAccess {
    var axTopLeft: CGPoint? { get }
    var axSize: CGSize? { get }
    func setAxTopLeft(_ topLeft: CGPoint)
    /// Whether the app answered the write: false when the attribute couldn't be set at all.
    @discardableResult func setAxSize(_ size: CGSize) -> Bool
}

extension AXUIElement: AxFrameAccess {
    var axTopLeft: CGPoint? { self.get(Ax.topLeftCornerAttr) }
    var axSize: CGSize? { self.get(Ax.sizeAttr) }
    func setAxTopLeft(_ topLeft: CGPoint) { set(Ax.topLeftCornerAttr, topLeft) }
    @discardableResult func setAxSize(_ size: CGSize) -> Bool { set(Ax.sizeAttr, size) }
}

/// What a window's app made of the size WinMux last asked it for. An app may keep a size of its own
/// instead: a minimum size, a fixed aspect ratio, a character grid. WinMux learns that only by asking
/// and reading the size back, for that size alone: one answer says nothing about another size.
/// Kept with the window on its app's AX thread, for as long as the window lives.
struct WindowFrameFit {
    /// The size last asked for.
    private(set) var request: CGSize?
    /// The size the app keeps instead of `request`: read back right after asking, or gone back to
    /// again after WinMux asked again. Nil while the app has taken the size it was asked for.
    private(set) var heldSize: CGSize?
    /// The size the app went to on its own after taking `request`. Going back to it once WinMux has
    /// asked again shows the app keeps it, even if it answered the request at first.
    private(set) var drift: CGSize?
    /// Whether `request` was written to the app since it became the request.
    private(set) var asked = false
    /// The frame last reported for this request, and the cell corner it was in.
    private var reported: (frame: Rect, cell: CGPoint)?

    /// A new request starts over: nothing the app made of another size applies to it.
    mutating func begin(_ size: CGSize) {
        if let request, request.isClose(to: size) { return }
        self = WindowFrameFit(request: size)
    }

    /// Whether the window is at the size the app keeps for this request.
    func holds(_ current: CGSize?) -> Bool {
        guard let heldSize, let current else { return false }
        return current.isClose(to: heldSize)
    }

    /// The window is at `current`, neither the request nor the size the app holds. Back at the size it
    /// went to after the request was asked again, it's the app's own; otherwise it's asked again.
    mutating func returnsToDrift(_ current: CGSize?) -> Bool {
        guard asked, let current else { return false }
        if let drift, current.isClose(to: drift) {
            heldSize = current
            return true
        }
        drift = current
        return false
    }

    /// `frame`, unless it was the last one reported for this cell.
    mutating func news(_ frame: Rect, in cell: CGPoint) -> Rect? {
        if let reported, reported.cell.isClose(to: cell), reported.frame.isApproximatelyEqual(to: frame, tolerance: 0.5) { return nil }
        reported = (frame, cell)
        return frame
    }

    /// The window is at the size asked for: whatever the app kept before, it has the request now.
    /// Whether that's news.
    mutating func reachedRequest() -> Bool {
        guard heldSize != nil else { return false }
        heldSize = nil
        return true
    }

    /// What the app answered right after asking. Nothing is learned from a write the app didn't take
    /// in, or a size that couldn't be read: the next layout asks again, as before.
    mutating func record(answered: Bool, readBack: CGSize?) {
        guard let request, answered, let readBack else { return }
        asked = true
        heldSize = readBack.isClose(to: request) ? nil : readBack
    }
}

extension CGSize {
    /// Within a point on each side: AX reports frames in whole points, and layout cells needn't be.
    func isClose(to other: CGSize) -> Bool { abs(width - other.width) < 1 && abs(height - other.height) < 1 }
}

extension CGPoint {
    func isClose(to other: CGPoint) -> Bool { abs(x - other.x) < 1 && abs(y - other.y) < 1 }
}

/// Where a window the app keeps at `size` goes in `cell`: centered on each side where it fits. Where
/// it's larger than the cell it starts at the cell's edge, as before, moved back inside `bounds` as far
/// as `bounds` allows, so a window that can't shrink to its cell overlaps a neighbour rather than leave
/// its display.
func frameFitTopLeft(cell: Rect, size: CGSize, bounds: Rect?) -> CGPoint {
    func place(_ origin: CGFloat, _ length: CGFloat, _ held: CGFloat, _ min: CGFloat?, _ max: CGFloat?) -> CGFloat {
        if held <= length { return (origin + (length - held) / 2).rounded() }
        guard let min, let max else { return origin }
        return Swift.max(min, Swift.min(origin, max - held))
    }
    return CGPoint(
        x: place(cell.topLeftX, cell.width, size.width, bounds?.minX, bounds?.maxX),
        y: place(cell.topLeftY, cell.height, size.height, bounds?.minY, bounds?.maxY),
    )
}

/// Reads the current frame first and returns before the AXEnhancedUserInterface round-trip when
/// the frame already matches: layout re-asserts frames constantly and the vast majority of these
/// calls are no-ops, so the no-op path must not pay the disableAnimations read. `writing` wraps
/// the writes when there are any: MacApp counts them in `FrameWriteLedger` and turns animations off.
///
/// A size is asked for once per request: written, then read back, and the window placed once where
/// that size goes in the cell (`frameFitTopLeft`). When the app keeps a size of its own (`fit`), later
/// calls for the same request leave the size alone and only place the window, so repeated layouts
/// don't fight the app. Returns the window's frame when a size was asked for, or it's at a size the
/// app keeps, or it just got the size it was asked for after keeping another: always as read back after
/// the last write, never where it was asked to be, since a position write says nothing about where the
/// window went. Nil when nothing about its fit is new, or the frame couldn't be read.
@discardableResult
func setFrame<W: AxFrameAccess>(
    _ window: W, _ topLeft: CGPoint?, _ size: CGSize?, fit: inout WindowFrameFit, within bounds: Rect? = nil, _ job: RunLoopJob,
    writing: (() throws -> Void) throws -> Void = { try $0() },
) throws -> Rect? {
    guard let size else {
        // A move alone: parking a window, or one floating window following its display.
        guard let topLeft, window.axTopLeft != topLeft else { return nil }
        try writing { window.setAxTopLeft(topLeft) }
        return nil
    }
    let currentSize = window.axSize
    let currentTopLeft: CGPoint? = topLeft == nil ? nil : window.axTopLeft
    fit.begin(size)
    /// Where a window of `kept` size goes: the cell's corner when it has the size asked for.
    func target(_ topLeft: CGPoint, _ kept: CGSize?) -> CGPoint {
        guard let kept, !kept.isClose(to: size) else { return topLeft }
        return frameFitTopLeft(cell: Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height),
            size: kept, bounds: bounds)
    }

    // The app keeps a size of its own for this request: place the window, don't ask again. The app may
    // clamp or refuse the move, and a move may change the size (a display's edge): what's reported is
    // read back after it, and nothing when it can't be read.
    func place(_ held: CGSize) throws -> Rect? {
        guard let topLeft else { return nil }
        let placed = target(topLeft, held)
        var frame = currentTopLeft.flatMap { at in currentSize.map { Rect(topLeftX: at.x, topLeftY: at.y, width: $0.width, height: $0.height) } }
        if currentTopLeft?.isClose(to: placed) != true {
            try writing {
                window.setAxTopLeft(placed)
                frame = window.axTopLeft.flatMap { at in window.axSize.map { Rect(topLeftX: at.x, topLeftY: at.y, width: $0.width, height: $0.height) } }
            }
        }
        return frame.flatMap { fit.news($0, in: topLeft) }
    }
    if fit.holds(currentSize), let held = fit.heldSize { return try place(held) }
    let sizeMatches = currentSize?.isClose(to: size) == true
    let positionMatches = topLeft.map { topLeft in currentTopLeft?.isClose(to: topLeft) == true } ?? true
    if sizeMatches && positionMatches {
        guard fit.reachedRequest(), let currentSize, let at = currentTopLeft ?? window.axTopLeft else { return nil }
        let frame = Rect(topLeftX: at.x, topLeftY: at.y, width: currentSize.width, height: currentSize.height)
        return topLeft.map { fit.news(frame, in: $0) } ?? frame
    }
    if !sizeMatches, fit.returnsToDrift(currentSize), let held = fit.heldSize { return try place(held) }

    var observed: Rect?
    try writing {
        var answered = window.setAxSize(size)
        try job.checkCancellation()
        var readBack = window.axSize
        if let topLeft {
            // The size is asked for with the window at its cell's corner, where the whole cell is on its
            // display: AppKit fits a window being resized to the screen from where it is, so a window
            // asked from anywhere else (centered in its cell, still on its old display) may answer with
            // the screen's limit instead of its own. Seen in a guest with an aspect-ratio window: from its
            // centered place it came back 868 × 520 in a 1002 × 626 cell, from the corner 1001 × 595.
            window.setAxTopLeft(topLeft)
            try job.checkCancellation()
            // Moving a window can make macOS clamp its size (e.g. crossing monitors), so the size may
            // need re-asserting once. Only re-set when it's not the request: an AX read is much cheaper
            // than an unconditional write, which forces a second layout pass in the target app every time.
            readBack = window.axSize
            if let moved = readBack, !moved.isClose(to: size) {
                answered = window.setAxSize(size) || answered
                readBack = window.axSize
            }
            // Then where the size it keeps goes in the cell, once.
            let placed = target(topLeft, readBack)
            if !placed.isClose(to: topLeft) { window.setAxTopLeft(placed) }
        }
        fit.record(answered: answered, readBack: readBack)
        // Where the window is and its size, as the app says after the last write, not as asked: the move
        // to its place may have been clamped, or have changed its size.
        guard readBack != nil, let at = window.axTopLeft, let now = window.axSize else { return }
        let frame = Rect(topLeftX: at.x, topLeftY: at.y, width: now.width, height: now.height)
        observed = topLeft.map { fit.news(frame, in: $0) ?? frame } ?? frame
    }
    return observed
}

func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}
