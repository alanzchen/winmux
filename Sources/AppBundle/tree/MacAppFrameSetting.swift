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

/// Where a layout writes a window: its display, and what's happened to displays and to the window since.
struct FrameFitTarget: Equatable, Sendable {
    /// The display's place in NSScreen.screens (`monitorAppKitNsScreenScreensId`): an id that holds as long as displays
    /// don't change, which is as long as an epoch lasts. Not its rectangle: two displays may report the same one.
    let monitor: Int
    /// `MonitorConfigurationObserver.frameFitEpoch`: it moves on when displays change, again once they've settled,
    /// and when they wake.
    let epoch: UInt64
    /// `Window.frameFitArming`: it moves on when the user resizes the window, or the window leaves tiling.
    var arming: UInt64 = 0
}

/// What a window's app made of the size layout asked for in a cell. An app may keep a size of its own instead: a minimum
/// size, a fixed aspect ratio, a character grid. WinMux learns that only by asking and reading the size back.
/// Kept with the window on its app's AX thread, for as long as the window lives.
///
/// All of it is for one context: one cell size on one display (`FrameFitTarget`). Another cell size, another display, a
/// new epoch or a rearmed window starts over. A cell that only moves keeps what was learned (an equal tile swap writes no
/// size); only what was refused or reported at the old place is forgotten.
///
/// An attempt moves the window to its cell's corner, writes the size there at most once, places the window for the size
/// it then has, and reads its frame back. Its final size is what the window has once `settleInterval` has passed since:
/// AppKit may still fit a window just moved from another display to that display for a moment, and an app may resize
/// itself after taking a write. Attempts are at least that far apart, whatever asks for them: a layout arriving sooner
/// only places the window, and a follow-up (`followUpAt`) looks again when the interval is up.
/// - The request as a final size: settled.
/// - The same other final size from two attempts, with no request reached between them: learned, the app's own. Never
///   from a write that failed or couldn't be read back.
/// - Bound: `acquisitionWrites` size writes to get there, each charged before it's made, so failed and cancelled ones
///   count. Once settled or learned, one more (the recovery write) for the first time the window leaves that size on its
///   own, such as a call ending. Nothing gives writes back. Out of writes before settling: exhausted, the window placed at
///   the size it has and not resized again. So at most `acquisitionWrites + 1` size writes in one context, whatever the
///   app does, even nothing.
struct WindowFrameFit {
    enum Phase: Equatable {
        /// Asking for the request.
        case probing
        /// The window has the request.
        case settled
        /// The app keeps this size instead of the request.
        case learned(CGSize)
        /// Out of size writes before the window settled: placed at the size it has, when that can be read.
        case exhausted(CGSize?)
    }

    /// How many attempts in a row must end at the same other size for it to be the app's own.
    static let answersToLearn = 2
    /// Size writes for getting the request or the app's own size, in one context.
    static let acquisitionWrites = 3
    /// How long after an attempt its final size is read: no attempt comes sooner.
    static let settleInterval: TimeInterval = 0.06

    private(set) var target: FrameFitTarget?
    /// The size asked for: the cell's.
    private(set) var request: CGSize?
    private(set) var phase = Phase.probing
    private(set) var acquisitionWritesSpent = 0
    private(set) var recoveryWriteSpent = false
    /// When the last size write was charged, on the monotonic clock.
    private(set) var lastAttempt: TimeInterval?
    /// When this window wants another look, whatever else lays it out: when the last attempt's final size is due, or
    /// when the next attempt may be made. Nil when nothing's pending.
    private(set) var followUpAt: TimeInterval?
    /// Whether the last attempt's final size is still to be read.
    private var awaitingFinalSize = false
    /// The last final size that wasn't the request, and how many attempts in a row ended at it.
    private var streak: (size: CGSize, count: Int)?
    /// Settled or learned since this context began: the writes for getting a size are over.
    private var hasSettled = false
    /// A move alone since the last layout write: a follow-up waits for the next one.
    private var suspended = false
    /// The cell's corner, and what's known of placing the window there.
    private(set) var origin: CGPoint?
    private var reported: Rect?
    /// A move the app didn't take: asked to `asked`, the window stayed at (or went to) `got`, at `size`.
    private var refusedMove: (asked: CGPoint, got: CGPoint, size: CGSize?)?

    init() {}

    private init(target: FrameFitTarget, request: CGSize, origin: CGPoint) {
        (self.target, self.request, self.origin) = (target, request, origin)
    }

    /// The size the app keeps instead of the request, once learned.
    var heldSize: CGSize? {
        if case .learned(let size) = phase { size } else { nil }
    }

    var sizeWritesSpent: Int { acquisitionWritesSpent + (recoveryWriteSpent ? 1 : 0) }

    /// A layout's write for `size` at `origin`, with `target`: another context starts over; another place for the same
    /// cell size forgets only what's known of placing the window at the old one.
    mutating func begin(_ size: CGSize, at origin: CGPoint, for target: FrameFitTarget) {
        guard target == self.target, request?.isClose(to: size) == true else {
            self = WindowFrameFit(target: target, request: size, origin: origin)
            return
        }
        suspended = false
        if self.origin?.isClose(to: origin) != true { (self.origin, reported, refusedMove) = (origin, nil, nil) }
    }

    /// Whether a follow-up for `size` at `origin`, with `target`, still has something to do: no other cell, move alone
    /// or frame as asked was written since, and a look is still due.
    func continues(_ size: CGSize, at origin: CGPoint, for target: FrameFitTarget) -> Bool {
        !suspended && followUpAt != nil && target == self.target && request?.isClose(to: size) == true &&
            self.origin?.isClose(to: origin) == true
    }

    /// A move alone, such as a park: what was learned holds for when the window is laid out again; nothing follows up
    /// until then.
    mutating func suspend() {
        suspended = true
        followUpAt = nil
    }

    func settling(at now: TimeInterval) -> Bool {
        lastAttempt.map { now < $0 + Self.settleInterval } ?? false
    }

    var hasWriteLeft: Bool { hasSettled ? !recoveryWriteSpent : acquisitionWritesSpent < Self.acquisitionWrites }

    /// The window is at `current` at `now`. Once the interval after an attempt is up, that's the attempt's final size:
    /// the request settles; another size counts toward learning it if the attempt before ended there too.
    /// With nothing pending, a window at the request is settled, whatever it kept before.
    mutating func observe(_ current: CGSize?, at now: TimeInterval) {
        guard let request else { return }
        if awaitingFinalSize {
            guard let lastAttempt, now >= lastAttempt + Self.settleInterval else { return }
            awaitingFinalSize = false
            guard let current else { return streak = nil }
            guard !current.isClose(to: request) else { return settle() }
            let count = streak.map { $0.size.isClose(to: current) ? $0.count + 1 : 1 } ?? 1
            streak = (current, count)
            if count >= Self.answersToLearn { (phase, hasSettled, streak) = (.learned(current), true, nil) }
            return
        }
        guard current?.isClose(to: request) == true else { return }
        switch phase {
            case .probing, .learned: settle()
            case .settled, .exhausted: break
        }
    }

    private mutating func settle() { (phase, hasSettled, streak) = (.settled, true, nil) }

    /// Whether a window at `current` isn't at a size to keep: then it's asked for the request, if the writes allow.
    func wantsSize(_ current: CGSize?) -> Bool {
        guard let request else { return false }
        switch phase {
            case .probing: return current?.isClose(to: request) != true
            case .settled: return current.map { !$0.isClose(to: request) } ?? false
            case .learned(let size): return current.map { !$0.isClose(to: size) && !$0.isClose(to: request) } ?? false
            case .exhausted: return false
        }
    }

    /// No writes left for a window that wants one: it's left at `current`.
    mutating func exhaust(_ current: CGSize?) {
        (phase, streak, awaitingFinalSize) = (.exhausted(current), nil, false)
    }

    /// Charged before every size write, whatever comes of it: a write that fails or is cancelled right after counts.
    mutating func charge(at now: TimeInterval) {
        if hasSettled { recoveryWriteSpent = true } else { acquisitionWritesSpent += 1 }
        (lastAttempt, phase, awaitingFinalSize) = (now, .probing, false)
    }

    /// The attempt's last write and read are done, at `now`: the settle interval runs from here, not from before AX
    /// reads that may have taken longer than it.
    mutating func endAttempt(at now: TimeInterval) {
        lastAttempt = max(lastAttempt ?? now, now)
    }

    /// The write was `answered` or not, and read back as `readBack`. Only a write the app answered and whose result
    /// could be read has a final size to wait for; any other breaks a run of answers.
    mutating func noteWritten(answered: Bool, readBack: CGSize?) {
        if answered && readBack != nil { awaitingFinalSize = true } else { streak = nil }
    }

    /// When to look again, now that a write for a window that `wantsSize` or not is done.
    mutating func scheduleFollowUp(wantsSize: Bool, at now: TimeInterval) {
        guard let lastAttempt, !suspended else { return followUpAt = nil }
        let due = lastAttempt + Self.settleInterval
        followUpAt = awaitingFinalSize || (wantsSize && hasWriteLeft && now < due) ? due : nil
    }

    /// Whether moving the window at `at` and `size` to `asked` is a move the app refused there already.
    func refused(_ asked: CGPoint, at: CGPoint?, size: CGSize?) -> Bool {
        guard let refusedMove, let at, refusedMove.asked.isClose(to: asked), refusedMove.got.isClose(to: at) else { return false }
        switch (refusedMove.size, size) {
            case (nil, nil): return true
            case (let was?, let now?): return was.isClose(to: now)
            default: return false
        }
    }

    /// The window was moved to `asked` at `size`, and read back at `got`.
    mutating func noteMove(to asked: CGPoint, got: CGPoint?, size: CGSize?) {
        guard let got else { return }
        refusedMove = got.isClose(to: asked) ? nil : (asked, got, size)
    }

    /// `frame`, unless it was the last one reported for this place.
    mutating func news(_ frame: Rect) -> Rect? {
        if let reported, reported.isApproximatelyEqual(to: frame, tolerance: 0.5) { return nil }
        reported = frame
        return frame
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
/// A layout's write (`target`) goes through `fit`, which says when the size is asked for and when the window is only
/// placed where the size it keeps goes in the cell (`frameFitTopLeft`), so repeated layouts don't fight the app, and
/// bounds the size writes. `now` reads the monotonic clock, afresh each time; `continuing`, a follow-up the last write asked for
/// (`fit.followUpAt`), which does nothing unless it still has something to do. A move alone (`size` nil) keeps what was
/// learned. A frame as asked (no `target`) forgets it, and is written as it is.
///
/// Returns the frame as read back after the last write, never where the window was asked to be, since a position write
/// says nothing about where the window went; with no write, only when that's news for this place. Nil when nothing's new
/// or the frame couldn't be read.
@discardableResult
func setFrame<W: AxFrameAccess>(
    _ window: W, _ topLeft: CGPoint?, _ size: CGSize?, fit: inout WindowFrameFit, within bounds: Rect? = nil,
    target: FrameFitTarget? = nil, continuing: Bool = false,
    now: @autoclosure () -> TimeInterval = ProcessInfo.processInfo.systemUptime,
    _ job: RunLoopJob, writing: (() throws -> Void) throws -> Void = { try $0() },
) throws -> Rect? {
    guard let size else {
        // A move alone: parking a window, or one floating window following its display.
        fit.suspend()
        guard let topLeft, window.axTopLeft != topLeft else { return nil }
        try writing { window.setAxTopLeft(topLeft) }
        return nil
    }
    guard let target, let topLeft else {
        fit = WindowFrameFit()
        return try setFrameAsAsked(window, topLeft, size, job, writing: writing)
    }
    if continuing && !fit.continues(size, at: topLeft, for: target) { return nil }
    fit.begin(size, at: topLeft, for: target)
    func frame(_ at: CGPoint?, _ size: CGSize?) -> Rect? {
        at.flatMap { at in size.map { Rect(topLeftX: at.x, topLeftY: at.y, width: $0.width, height: $0.height) } }
    }
    /// Where a window of `kept` size goes in the cell: its corner when it has the size asked for.
    func spot(for kept: CGSize?) -> CGPoint {
        guard let kept, !kept.isClose(to: size) else { return topLeft }
        return frameFitTopLeft(cell: Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height), size: kept,
            bounds: bounds)
    }
    /// Moves the window at `at` to `spot` unless it's there, or the app refused that move already; what it took is noted.
    func move(from at: CGPoint?, to spot: CGPoint, size: CGSize?) -> CGPoint? {
        guard at?.isClose(to: spot) != true, !fit.refused(spot, at: at, size: size) else { return at }
        window.setAxTopLeft(spot)
        let got = window.axTopLeft
        fit.noteMove(to: spot, got: got, size: size)
        return got
    }

    // Before the reads: a size read after this was read at least this late.
    let start = now()
    let currentSize = window.axSize
    let currentTopLeft = window.axTopLeft
    fit.observe(currentSize, at: start)
    let wantsSize = fit.wantsSize(currentSize)
    if wantsSize && !fit.settling(at: start) && !fit.hasWriteLeft { fit.exhaust(currentSize) }
    guard wantsSize && !fit.settling(at: start) && fit.hasWriteLeft else {
        // Nothing to ask for, or not yet: placed for the size it has, as read back after a move.
        let place = spot(for: currentSize)
        var placed = frame(currentTopLeft, currentSize)
        var moved = false
        if currentTopLeft?.isClose(to: place) != true && !fit.refused(place, at: currentTopLeft, size: currentSize) {
            try writing {
                placed = frame(move(from: currentTopLeft, to: place, size: currentSize), window.axSize)
            }
            moved = true
        }
        // From the reading the decision to wait was made on: a read that ran past the interval's end mustn't drop the
        // follow-up the size was left to.
        fit.scheduleFollowUp(wantsSize: fit.wantsSize(placed?.size ?? currentSize), at: start)
        guard let placed else { return nil }
        return moved ? fit.news(placed) ?? placed : fit.news(placed)
    }

    var observed: Rect?
    var attempted = false
    // `writing` can't take a closure that captures `now` as it is: the same clock, as a value it may hold.
    do { try withoutActuallyEscaping(now) { clock in try writing {
        try job.checkCancellation()
        // At its cell's corner first, where the whole cell is on its display: AppKit fits a window being resized to the
        // screen from where it is, so a window asked from anywhere else (centered in its cell, still on its old display)
        // may answer with the screen's limit instead of its own. Seen in a guest with an aspect-ratio window: from its
        // centered place it came back 868 × 520 in a 1002 × 626 cell, from the corner 1001 × 595. A move the app
        // refuses (a window too large for where it's going) doesn't keep it from being asked for its size.
        var at = move(from: currentTopLeft, to: topLeft, size: currentSize)
        try job.checkCancellation()
        // Then the size, once, if the move didn't leave it at one to keep.
        var kept = window.axSize
        if fit.wantsSize(kept) {
            fit.charge(at: clock())
            attempted = true
            let answered = window.setAxSize(size)
            kept = window.axSize
            // Before a cancellation can stop it: a write that failed breaks a run of answers whatever comes next.
            fit.noteWritten(answered: answered, readBack: kept)
            try job.checkCancellation()
        }
        // Then where the size it has goes in the cell, and the frame as the app says after the last write: the move
        // may have been clamped, or have changed its size.
        at = move(from: at, to: spot(for: kept), size: kept)
        observed = frame(window.axTopLeft, window.axSize)
    } } } catch {
        if attempted { fit.endAttempt(at: now()) }
        throw error
    }
    // The settle interval runs from the end of the attempt: AX reads before its write may have taken longer than it.
    if attempted { fit.endAttempt(at: now()) }
    fit.scheduleFollowUp(wantsSize: fit.wantsSize(observed?.size), at: now())
    return observed.map { fit.news($0) ?? $0 }
}

/// A frame as asked, not a layout's (a window put back where it was, a tab strip or drag action): moved, sized if it
/// isn't that size, and moved back if sizing moved it. The frame is read back after.
private func setFrameAsAsked<W: AxFrameAccess>(
    _ window: W, _ topLeft: CGPoint?, _ size: CGSize, _ job: RunLoopJob, writing: (() throws -> Void) throws -> Void,
) throws -> Rect? {
    let currentTopLeft = topLeft == nil ? nil : window.axTopLeft
    let positionMatches = topLeft.map { currentTopLeft?.isClose(to: $0) == true } ?? true
    if positionMatches && window.axSize?.isClose(to: size) == true { return nil }
    var observed: Rect?
    try writing {
        try job.checkCancellation()
        if let topLeft, !positionMatches {
            window.setAxTopLeft(topLeft)
            try job.checkCancellation()
        }
        if window.axSize?.isClose(to: size) != true {
            window.setAxSize(size)
            try job.checkCancellation()
            if let topLeft, window.axTopLeft?.isClose(to: topLeft) == false { window.setAxTopLeft(topLeft) }
        }
        observed = window.axTopLeft.flatMap { at in
            window.axSize.map { Rect(topLeftX: at.x, topLeftY: at.y, width: $0.width, height: $0.height) }
        }
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
