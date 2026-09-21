import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceSidebarDockMotionFrame: Equatable {
    var pointer: CGPoint?
    var strength: Double = 0
}

/// Pointer events replace a target; only a display refresh produces a new frame.
/// Time-based interpolation gives 60, 120 and 144 Hz displays the same response.
struct WorkspaceSidebarDockMotion {
    private(set) var frame = WorkspaceSidebarDockMotionFrame()
    private(set) var target: CGPoint?
    private var previousTimestamp: TimeInterval?
    private var strengthVelocity = 0.0

    var isSettled: Bool {
        guard let target else { return frame.pointer == nil }
        return frame.pointer == target && frame.strength == 1
    }

    mutating func receive(_ point: CGPoint?) {
        target = point
        if frame.pointer == nil { frame.pointer = point }
    }

    mutating func reset() { self = .init() }

    mutating func advance(to timestamp: TimeInterval, initialInterval: TimeInterval) -> WorkspaceSidebarDockMotionFrame {
        // A missed deadline should slow entry, not jump across most of the spring
        // in a single displayed frame. Normal cadence remains time-based.
        let maximumStep = min(2 * initialInterval, 1.0 / 30)
        let dt = min(max(previousTimestamp.map { timestamp - $0 } ?? initialInterval, 0), maximumStep)
        previousTimestamp = timestamp
        let strengthTarget = target == nil ? 0.0 : 1.0
        // Analytical critically damped spring: enter from zero velocity instead of
        // jumping through a large fraction of the enlargement on the first frame.
        // Keeping velocity when the target reverses also avoids an exit/re-entry jerk.
        let frequency = 40.0
        let displacement = frame.strength - strengthTarget
        let adjustment = strengthVelocity + frequency * displacement
        let decay = exp(-frequency * dt)
        frame.strength = strengthTarget + (displacement + adjustment * dt) * decay
        strengthVelocity = (strengthVelocity - frequency * adjustment * dt) * decay
        if abs(strengthTarget - frame.strength) < 0.002, abs(strengthVelocity) < 0.15 {
            frame.strength = strengthTarget
            strengthVelocity = 0
        }
        if let target, let pointer = frame.pointer {
            let fraction = 1 - exp(-dt / 0.010)
            let next = CGPoint(x: pointer.x + (target.x - pointer.x) * fraction,
                               y: pointer.y + (target.y - pointer.y) * fraction)
            frame.pointer = hypot(next.x - target.x, next.y - target.y) < 0.05 ? target : next
        }
        if frame.strength == 0, target == nil { frame.pointer = nil }
        if isSettled { previousTimestamp = nil }
        return frame
    }
}

@MainActor
final class WorkspaceSidebarDockMotionController {
    private weak var view: WorkspaceSidebarDockDisplayLinkView?

    func attach(to view: WorkspaceSidebarDockDisplayLinkView) {
        guard self.view !== view else { return }
        // SwiftUI can retain an outgoing renderer through its transition. Stop
        // its input and display link before the new renderer owns hit geometry.
        self.view?.detachPointer()
        self.view = view
        if view.window != nil { view.attachPointer() }
    }

    func owns(_ view: WorkspaceSidebarDockDisplayLinkView) -> Bool { self.view === view }

    func receive(_ point: CGPoint?) { view?.receive(point) }
    func reset(publishFrame: Bool = true) { view?.reset(publishFrame: publishFrame) }
    func recordGeometry(surfaceY: Double? = nil, icons: Int? = nil) {
        view?.performanceTrace?.geometry(surfaceY: surfaceY, icons: icons)
    }
    func recordColumnOrigins(_ measured: [WorkspaceProjectId: CGFloat], previous: [WorkspaceProjectId: CGFloat]) {
        guard let trace = view?.performanceTrace else { return }
        var delta = 0.0
        for (project, value) in measured where value.isFinite {
            delta = max(delta, abs(value - (previous[project] ?? value)))
        }
        trace.columnOrigin(delta: delta)
    }
}

/// This bridge owns no observable app state, and sleeps when the pointer settles.
struct WorkspaceSidebarDockDisplayLink: NSViewRepresentable {
    let controller: WorkspaceSidebarDockMotionController
    let blockers: WorkspaceSidebarDockPointerBlockers
    var horizontal = false
    let containsPointer: (CGPoint) -> Bool
    let onFrame: (WorkspaceSidebarDockMotionFrame) -> Void

    func makeNSView(context: Context) -> WorkspaceSidebarDockDisplayLinkView {
        let view = WorkspaceSidebarDockDisplayLinkView()
        controller.attach(to: view)
        view.onFrame = publish
        view.configurePointer(blockers: blockers, horizontal: horizontal, contains: containsPointer)
        return view
    }

    func updateNSView(_ view: WorkspaceSidebarDockDisplayLinkView, context: Context) {
        controller.attach(to: view)
        view.onFrame = publish
        view.configurePointer(blockers: blockers, horizontal: horizontal, contains: containsPointer)
    }

    static func dismantleNSView(_ view: WorkspaceSidebarDockDisplayLinkView, coordinator: ()) {
        view.onFrame = nil
        view.detachPointer()
    }

    private func publish(_ frame: WorkspaceSidebarDockMotionFrame) {
        // Only the SwiftUI renderer needs a SwiftUI transaction. Native layer
        // updates have their own Core Animation transaction.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { onFrame(frame) }
    }
}

@MainActor
final class WorkspaceSidebarDockDisplayLinkView: NSView {
    var onFrame: ((WorkspaceSidebarDockMotionFrame) -> Void)?
    /// Opt-in profiling hook; normal rendering does not collect timing samples.
    var frameObserver: ((TimeInterval) -> Void)?
    var performanceTrace: DockPerformanceTrace?
    private(set) var motion = WorkspaceSidebarDockMotion()
    private(set) var isRunning = false
    private var modernDisplayLink: AnyObject?
    private var requestedRate = 0
    private var lastFrame = WorkspaceSidebarDockMotionFrame()
    var pointerBlockers: WorkspaceSidebarDockPointerBlockers = .disabled
    var horizontal = false

    func lensCoordinate(_ point: CGPoint?) -> CGFloat? {
        point.map { horizontal ? $0.x : $0.y }
    }
    var containsPointer: ((CGPoint) -> Bool)?
    weak var pointerPanel: WorkspaceSidebarPanel?
    var isPointerAttached = false
    var hasPendingPointerRecheck = false
    var currentScreenPoint: () -> CGPoint = { NSEvent.mouseLocation }
    private var pointerTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows bounds automatically; never rebuild tracking at vsync.
        guard window != nil, pointerTrackingArea == nil else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        // Real panels receive movement from the app's local/global input bridge.
        // Keep boundary recovery, without asking AppKit to dispatch a duplicate
        // mouseMoved callback. Standalone previews still need their own movement.
        if !(window is WorkspaceSidebarPanel) { options.insert(.mouseMoved) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        pointerTrackingArea = area
        addTrackingArea(area)
    }

    // Keep native tracking active even when another WinMux window is key. Every
    // event uses current geometry/position; an exit notification never blindly clears it.
    override func mouseMoved(with event: NSEvent) { receiveTrackingEvent(event) }
    override func mouseEntered(with event: NSEvent) { receiveTrackingEvent(event) }
    override func mouseExited(with event: NSEvent) { receiveTrackingEvent(event) }

    private func receiveTrackingEvent(_ event: NSEvent) {
        receiveNativePointer(currentScreenPoint(), eventTimestamp: event.timestamp, source: .tracking)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        detachPointer()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DockPerformanceRecorder.shared.register(self) }
        attachPointer()
    }

    func receive(_ point: CGPoint?) {
        // Only movement along the shelf changes the lens. Native hit testing still
        // validates the other axis and sends nil when the pointer leaves the Dock.
        guard lensCoordinate(point) != lensCoordinate(motion.target) else {
            // Recover after attachment or an explicit stop even when the next
            // packet repeats the last target. A settled pointer still sleeps.
            if !motion.isSettled { start() }
            return
        }
        if let performanceTrace { performanceTrace.input(at: CACurrentMediaTime()) }
        motion.receive(point)
        if !motion.isSettled { start() }
    }

    func reset(reason: DockPointerEventKind = .reset, publishFrame: Bool = true) {
        motion.reset()
        let wasRunning = isRunning
        pause(reason: reason)
        if !wasRunning { recordInputState(reason) }
        if publishFrame { publish(motion.frame) }
    }

    func publishRestingFrameIfNeeded() {
        if motion.isSettled { publish(motion.frame) }
    }

    static func preferredRate(maximumFramesPerSecond: Int) -> Float {
        Float(maximumFramesPerSecond > 0 ? maximumFramesPerSecond : 60)
    }

    private func start() {
        guard !isRunning, window != nil else { return }
        isRunning = true
        recordInputState(.resume)
        if #available(macOS 14.0, *) {
            let link: CADisplayLink
            if let existing = modernDisplayLink as? CADisplayLink {
                link = existing
            } else {
                link = displayLink(target: self, selector: #selector(displayFrame(_:)))
                modernDisplayLink = link
                configureRate(link)
                link.add(to: .main, forMode: .common)
            }
            link.isPaused = false
        } else {
            requestedRate = Int(Self.preferredRate(maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60))
            DisplayRefreshDriver.shared.add(owner: self) { [weak self] timestamp in
                self?.advance(to: timestamp)
            }
        }
    }

    @available(macOS 14.0, *)
    private func configureRate(_ link: CADisplayLink) {
        let maximum = Int(Self.preferredRate(maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60))
        guard maximum != requestedRate else { return }
        performanceTrace?.resetBaseline(preservingInput: true)
        requestedRate = maximum
        let rate = Self.preferredRate(maximumFramesPerSecond: maximum)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(120, rate), maximum: rate, preferred: rate)
    }

    @available(macOS 14.0, *)
    @objc private func displayFrame(_ link: CADisplayLink) {
        configureRate(link)
        advance(to: link.targetTimestamp, displayTimestamp: link.timestamp, displayDuration: link.duration)
    }

    func advance(to timestamp: TimeInterval, displayTimestamp: TimeInterval? = nil, displayDuration: TimeInterval? = nil) {
        let trace = performanceTrace
        let arrival = trace.map { _ in CACurrentMediaTime() }
        let interval = 1 / Double(requestedRate > 0 ? requestedRate : 60)
        let signpost = trace.map { _ in signposter.beginInterval("DockMotionPublish") }
        let frame = motion.advance(to: timestamp, initialInterval: 1 / Double(requestedRate > 0 ? requestedRate : 60))
        let changed = publish(frame)
        if let signpost { signposter.endInterval("DockMotionPublish", signpost) }
        if let trace, let arrival {
            trace.record(arrival: arrival, displayTimestamp: displayTimestamp ?? timestamp,
                targetTimestamp: displayTimestamp == nil ? 0 : timestamp, duration: displayDuration ?? interval,
                publishEnd: CACurrentMediaTime(), changed: changed, nativeDisplayTiming: displayTimestamp != nil)
        }
        if motion.isSettled { pause(reason: motion.target == nil ? .settledOutside : .settledPoint) }
        frameObserver?(timestamp)
    }

    @discardableResult
    private func publish(_ frame: WorkspaceSidebarDockMotionFrame) -> Bool {
        guard frame != lastFrame else { return false }
        lastFrame = frame
        onFrame?(frame)
        return true
    }

    private func pause(reason: DockPointerEventKind) {
        guard isRunning else { return }
        isRunning = false
        recordInputState(reason)
        performanceTrace?.resetBaseline()
        if #available(macOS 14.0, *), let link = modernDisplayLink as? CADisplayLink {
            link.isPaused = true
        } else {
            DisplayRefreshDriver.shared.remove(owner: self)
        }
    }

    func stop() {
        pause(reason: .stopped)
        if #available(macOS 14.0, *), let link = modernDisplayLink as? CADisplayLink {
            link.invalidate()
        }
        modernDisplayLink = nil
        requestedRate = 0
    }
}
