import Foundation

enum DockPointerEventKind: String, Codable, Sendable {
    case nativePointer, tracking, recheck, passthrough, policy, attached, detached, hidden
    case capture, resume, settledPoint, settledOutside, reset, stopped
}

struct DockPointerPerformanceEvent: Codable, Sendable {
    var sequence = 0
    let kind: DockPointerEventKind
    let receivedAt: Double
    let nativeTimestamp: Double?
    let blockers: Int
    let inside: Bool?
    let accepted: Bool?
    let targetChanged: Bool
    let running: Bool
    let hasTarget: Bool
    let passthrough: Bool
    let callbackSequence: Int
    let lastCallbackAt: Double?
}

struct DockPointerPerformanceReport: Codable, Sendable {
    let nativeEvents: Int
    let acceptedNativeEvents: Int
    let changedNativeTargets: Int
    let recentEvents: [DockPointerPerformanceEvent]
    let transitions: [DockPointerPerformanceEvent]
    let overwrittenRecentEvents: Int
    let overwrittenTransitions: Int
}

/// Events continue while the animation sleeps. A separate transition ring keeps
/// gate/exit/recovery context from being evicted by ordinary high-rate movement.
struct DockPointerPerformanceBuffer {
    private var recent = DockPerformanceRing<DockPointerPerformanceEvent>(capacity: 256)
    private var transitions = DockPerformanceRing<DockPointerPerformanceEvent>(capacity: 128)
    private var lastPointerEvent: DockPointerPerformanceEvent?
    private var sequence = 0
    private var nativeEvents = 0
    private var acceptedNativeEvents = 0
    private var changedNativeTargets = 0

    mutating func append(_ event: DockPointerPerformanceEvent) {
        var event = event
        sequence += 1
        event.sequence = sequence
        if event.kind == .nativePointer {
            nativeEvents += 1
            if event.accepted == true { acceptedNativeEvents += 1 }
            if event.targetChanged { changedNativeTargets += 1 }
        }
        recent.append(event)
        if event.kind == .nativePointer || event.kind == .tracking || event.kind == .recheck {
            if lastPointerEvent?.blockers != event.blockers || lastPointerEvent?.inside != event.inside ||
                lastPointerEvent?.accepted != event.accepted || lastPointerEvent?.running != event.running ||
                lastPointerEvent?.passthrough != event.passthrough {
                transitions.append(event)
            }
            lastPointerEvent = event
        } else {
            transitions.append(event)
        }
    }

    func snapshot(retired: Bool) -> DockPointerPerformanceReport {
        .init(nativeEvents: nativeEvents, acceptedNativeEvents: acceptedNativeEvents,
            changedNativeTargets: changedNativeTargets,
            recentEvents: Array(recent.elements.suffix(retired ? 32 : 256)),
            transitions: Array(transitions.elements.suffix(retired ? 16 : 128)),
            overwrittenRecentEvents: recent.overwritten + (retired ? max(recent.count - 32, 0) : 0),
            overwrittenTransitions: transitions.overwritten + (retired ? max(transitions.count - 16, 0) : 0))
    }
}
