import Foundation

/// Numeric, bounded storage. Never formats strings, writes files or publishes UI state
/// from the animation callback. Times use the CACurrentMediaTime host-time domain.
struct DockPerformanceRing<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var next = 0
    private(set) var count = 0
    private(set) var overwritten = 0

    init(capacity: Int) { storage = Array(repeating: nil, count: max(1, capacity)) }

    mutating func append(_ element: Element) {
        storage[next] = element
        next = (next + 1) % storage.count
        if count == storage.count { overwritten += 1 } else { count += 1 }
    }

    mutating func updateLast(_ update: (inout Element) -> Void) {
        let index = (next + storage.count - 1) % storage.count
        if storage[index] != nil { update(&storage[index]!) }
    }

    var elements: [Element] {
        let start = count == storage.count ? next : 0
        return (0..<count).compactMap { storage[(start + $0) % storage.count] }
    }

    var last: Element? { count == 0 ? nil : storage[(next + storage.count - 1) % storage.count] }
}

struct DockPerformanceSample: Codable, Sendable {
    var sequence = 0
    var arrival = 0.0
    var displayTimestamp = 0.0
    var targetTimestamp = 0.0
    var displayDuration = 0.0
    var interval = 0.0
    var callbackGap = 0.0
    var publishEnd = 0.0
    var beforeWaiting: Double?
    var previousPublishEnd: Double?
    var previousBeforeWaiting: Double?
    var latestInput: Double?
    var inputEvents = 0
    var poseChanged = false
    var baselineReset = true
    var cadenceChanged = false
    var nativeDisplayTiming = true
    var geometryUpdates = 0
    var hoverRechecks = 0
    var iconCount = 0
    var surfaceOriginDelta = 0.0
    var columnOriginUpdates = 0
    var tinyColumnOriginUpdates = 0
    var maximumColumnOriginDelta = 0.0

    // Suspicions, not measured GPU drops. A new cadence or resumed clock gets two
    // baseline frames. Unchanged poses and long idle pauses are not animation hitches.
    var lateCallback: Bool { nativeDisplayTiming && poseChanged && !baselineReset && callbackGap > interval * 1.5 }
    var expensivePublication: Bool { poseChanged && publishEnd - arrival > interval * 0.5 }
    var missedDeadline: Bool { nativeDisplayTiming && poseChanged && !baselineReset && publishEnd > targetTimestamp }
    var isSuspect: Bool { lateCallback || expensivePublication || missedDeadline }
}

struct DockPerformanceSummary: Codable, Sendable {
    var frames = 0
    var changedPoses = 0
    var lateCallbacks = 0
    var expensivePublications = 0
    var missedDeadlines = 0
    var suspectedFrames = 0
    var maximumCallbackGap = 0.0
    var maximumPublication = 0.0
    var maximumRunLoopTail = 0.0
}

/// One per animated panel during a capture; it is not an ObservableObject.
@MainActor
final class DockPerformanceTrace {
    private var recent = DockPerformanceRing<DockPerformanceSample>(capacity: 512)
    private var suspects = DockPerformanceRing<DockPerformanceSample>(capacity: 128)
    private(set) var summary = DockPerformanceSummary()
    private var previousArrival: Double?
    private var previousInterval: Double?
    private var baselineFrames = 2
    private var inputEvents = 0
    private var latestInput: Double?
    private var geometryUpdates = 0
    private var hoverRechecks = 0
    private var iconCount = 0
    private var lastSurfaceY: Double?
    private var surfaceOriginDelta = 0.0
    private var columnOriginUpdates = 0
    private var tinyColumnOriginUpdates = 0
    private var maximumColumnOriginDelta = 0.0
    private var needsRunLoopEnd = false

    func resetBaseline(preservingInput: Bool = false) {
        previousArrival = nil
        previousInterval = nil
        baselineFrames = 2
        if !preservingInput {
            latestInput = nil
            inputEvents = 0
        }
        geometryUpdates = 0
        hoverRechecks = 0
        surfaceOriginDelta = 0
        lastSurfaceY = nil
        columnOriginUpdates = 0
        tinyColumnOriginUpdates = 0
        maximumColumnOriginDelta = 0
    }

    func input(at timestamp: Double) {
        latestInput = timestamp
        inputEvents += 1
    }

    func geometry(surfaceY: Double? = nil, icons: Int? = nil) {
        geometryUpdates += 1
        if let surfaceY {
            if let lastSurfaceY { surfaceOriginDelta += surfaceY - lastSurfaceY }
            lastSurfaceY = surfaceY
        }
        if let icons { iconCount = icons }
    }

    func hoverRecheck() { hoverRechecks += 1 }

    func columnOrigin(delta: Double) {
        columnOriginUpdates += 1
        guard delta.isFinite else { return }
        if delta > 0 && delta < 0.001 { tinyColumnOriginUpdates += 1 }
        maximumColumnOriginDelta = max(maximumColumnOriginDelta, delta)
    }

    func record(arrival: Double, displayTimestamp: Double, targetTimestamp: Double,
                duration: Double, publishEnd: Double, changed: Bool, nativeDisplayTiming: Bool = true) {
        let interval = max(nativeDisplayTiming ? targetTimestamp - displayTimestamp : duration, 0.001)
        let cadenceChanged = previousInterval.map { abs(interval - $0) > $0 * 0.2 } ?? false
        if cadenceChanged { baselineFrames = 2 }
        var sample = DockPerformanceSample()
        sample.sequence = summary.frames + 1
        sample.arrival = arrival
        sample.displayTimestamp = displayTimestamp
        sample.targetTimestamp = targetTimestamp
        sample.displayDuration = duration
        sample.interval = interval
        sample.callbackGap = previousArrival.map { max(arrival - $0, 0) } ?? 0
        sample.publishEnd = publishEnd
        if previousArrival != nil {
            // Preserve the preceding turn around a stall even when it falls out
            // of the rolling buffer before the user ends a two-minute capture.
            sample.previousPublishEnd = recent.last?.publishEnd
            sample.previousBeforeWaiting = recent.last?.beforeWaiting
        }
        sample.latestInput = latestInput
        sample.inputEvents = inputEvents
        sample.poseChanged = changed
        sample.baselineReset = baselineFrames > 0
        sample.cadenceChanged = cadenceChanged
        sample.nativeDisplayTiming = nativeDisplayTiming
        sample.geometryUpdates = geometryUpdates
        sample.hoverRechecks = hoverRechecks
        sample.iconCount = iconCount
        sample.surfaceOriginDelta = surfaceOriginDelta
        sample.columnOriginUpdates = columnOriginUpdates
        sample.tinyColumnOriginUpdates = tinyColumnOriginUpdates
        sample.maximumColumnOriginDelta = maximumColumnOriginDelta
        recent.append(sample)
        needsRunLoopEnd = true
        if sample.isSuspect {
            suspects.append(sample)
            summary.suspectedFrames += 1
        }
        summary.frames += 1
        if changed { summary.changedPoses += 1 }
        if sample.lateCallback { summary.lateCallbacks += 1 }
        if sample.expensivePublication { summary.expensivePublications += 1 }
        if sample.missedDeadline { summary.missedDeadlines += 1 }
        if !sample.baselineReset && changed {
            summary.maximumCallbackGap = max(summary.maximumCallbackGap, sample.callbackGap)
        }
        summary.maximumPublication = max(summary.maximumPublication, publishEnd - arrival)
        previousArrival = arrival
        previousInterval = interval
        baselineFrames = max(baselineFrames - 1, 0)
        inputEvents = 0
        geometryUpdates = 0
        hoverRechecks = 0
        surfaceOriginDelta = 0
        columnOriginUpdates = 0
        tinyColumnOriginUpdates = 0
        maximumColumnOriginDelta = 0
    }

    /// End of this run-loop turn, not a CA commit or GPU presentation timestamp.
    /// SwiftUI can coalesce multiple poses; geometry counts are time-correlated only.
    func beforeWaiting(at timestamp: Double) {
        guard needsRunLoopEnd else { return }
        needsRunLoopEnd = false
        var tail = 0.0
        var sequence = 0
        recent.updateLast { sample in
            guard sample.beforeWaiting == nil else { return }
            sample.beforeWaiting = timestamp
            tail = max(timestamp - sample.publishEnd, 0)
            sequence = sample.sequence
        }
        summary.maximumRunLoopTail = max(summary.maximumRunLoopTail, tail)
        suspects.updateLast { sample in
            if sample.sequence == sequence { sample.beforeWaiting = timestamp }
        }
    }

    func snapshot(panel: Int, maximumFPS: Int, scale: Double, retired: Bool = false) -> DockPerformancePanelReport {
        .init(panel: panel, maximumFPS: maximumFPS, scale: scale, summary: summary,
              recentFrames: Array(recent.elements.suffix(retired ? 32 : 512)),
              suspectedFrames: Array(suspects.elements.suffix(retired ? 16 : 128)),
              overwrittenRecentFrames: recent.overwritten + (retired ? max(recent.count - 32, 0) : 0),
              overwrittenSuspectedFrames: suspects.overwritten + (retired ? max(suspects.count - 16, 0) : 0),
              retired: retired)
    }
}

struct DockPerformancePanelReport: Codable, Sendable {
    var panel: Int
    var maximumFPS: Int
    var scale: Double
    var summary: DockPerformanceSummary
    var recentFrames: [DockPerformanceSample]
    var suspectedFrames: [DockPerformanceSample]
    var overwrittenRecentFrames: Int
    var overwrittenSuspectedFrames: Int
    var retired: Bool
}
