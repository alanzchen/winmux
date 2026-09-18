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
    fileprivate weak var view: WorkspaceSidebarDockDisplayLinkView?

    func receive(_ point: CGPoint?) { view?.receive(point) }
    func reset() { view?.reset() }
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
    let onFrame: (WorkspaceSidebarDockMotionFrame) -> Void

    func makeNSView(context: Context) -> WorkspaceSidebarDockDisplayLinkView {
        let view = WorkspaceSidebarDockDisplayLinkView()
        controller.view = view
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ view: WorkspaceSidebarDockDisplayLinkView, context: Context) {
        controller.view = view
        view.onFrame = onFrame
    }

    static func dismantleNSView(_ view: WorkspaceSidebarDockDisplayLinkView, coordinator: ()) {
        view.stop()
        view.onFrame = nil
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if window != nil { DockPerformanceRecorder.shared.register(self) }
        if window != nil, !motion.isSettled { start() }
    }

    func receive(_ point: CGPoint?) {
        // The vertical lens depends only on Y. Native hit testing validates X
        // before this call, and still sends nil when the pointer leaves the Dock.
        guard point?.y != motion.target?.y else { return }
        if let performanceTrace { performanceTrace.input(at: CACurrentMediaTime()) }
        motion.receive(point)
        if !motion.isSettled { start() }
    }

    func reset() {
        motion.reset()
        stop()
        publish(motion.frame)
    }

    static func preferredRate(maximumFramesPerSecond: Int) -> Float {
        Float(maximumFramesPerSecond > 0 ? maximumFramesPerSecond : 60)
    }

    private func start() {
        guard !isRunning, window != nil else { return }
        isRunning = true
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
        if motion.isSettled { pause() }
        frameObserver?(timestamp)
    }

    @discardableResult
    private func publish(_ frame: WorkspaceSidebarDockMotionFrame) -> Bool {
        guard frame != lastFrame else { return false }
        lastFrame = frame
        // Do not inherit a workspace/hover spring and retarget it at every vsync.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { onFrame?(frame) }
        return true
    }

    private func pause() {
        isRunning = false
        performanceTrace?.resetBaseline()
        if #available(macOS 14.0, *), let link = modernDisplayLink as? CADisplayLink {
            link.isPaused = true
        } else {
            DisplayRefreshDriver.shared.remove(owner: self)
        }
    }

    func stop() {
        pause()
        if #available(macOS 14.0, *), let link = modernDisplayLink as? CADisplayLink {
            link.invalidate()
        }
        modernDisplayLink = nil
        requestedRate = 0
    }
}
