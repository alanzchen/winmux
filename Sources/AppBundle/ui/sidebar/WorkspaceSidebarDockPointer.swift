import AppKit
import QuartzCore

/// Stable bit values used by performance captures. No cursor coordinates are exported.
struct WorkspaceSidebarDockPointerBlockers: OptionSet, Sendable {
    let rawValue: Int
    static let disabled = Self(rawValue: 1 << 0)
    static let expanded = Self(rawValue: 1 << 1)
    static let reduceMotion = Self(rawValue: 1 << 2)
    static let menu = Self(rawValue: 1 << 3)
    static let editing = Self(rawValue: 1 << 4)
    static let drop = Self(rawValue: 1 << 5)
    static let swipe = Self(rawValue: 1 << 6)
    static let drag = Self(rawValue: 1 << 7)
    static let hidden = Self(rawValue: 1 << 8)
    static let detached = Self(rawValue: 1 << 9)
}

extension WorkspaceSidebarDockDisplayLinkView {
    var currentPointerBlockers: WorkspaceSidebarDockPointerBlockers {
        var blockers = pointerBlockers
        if window == nil || !isPointerAttached { blockers.insert(.detached) }
        if window?.isVisible != true || isHiddenOrHasHiddenAncestor { blockers.insert(.hidden) }
        if isWorkspaceSidebarDragInProgress() { blockers.insert(.drag) }
        if pointerPanel?.menuTrackingDepth ?? 0 > 0 { blockers.insert(.menu) }
        return blockers
    }

    func configurePointer(blockers: WorkspaceSidebarDockPointerBlockers, horizontal: Bool = false,
                          contains: @escaping (CGPoint) -> Bool) {
        containsPointer = contains
        let changedAxis = self.horizontal != horizontal
        guard pointerBlockers != blockers || changedAxis else { return }
        self.horizontal = horizontal
        if changedAxis { reset(publishFrame: false) }
        pointerBlockers = blockers
        recordInputState(.policy)
        // NSViewRepresentable updates must not synchronously publish SwiftUI state.
        schedulePointerRecheck()
    }

    func attachPointer() {
        guard window != nil else { return }
        isPointerAttached = true
        pointerPanel = window as? WorkspaceSidebarPanel
        pointerPanel?.dockPointerView = self
        recordInputState(.attached)
        schedulePointerRecheck()
    }

    func detachPointer() {
        if pointerPanel?.dockPointerView === self { pointerPanel?.dockPointerView = nil }
        pointerPanel = nil
        isPointerAttached = false
        // AppKit can detach a representable during SwiftUI reconciliation. Reset
        // native state now, and publish only from a later recheck after reattachment.
        reset(reason: .detached, publishFrame: false)
    }

    func schedulePointerRecheck() {
        guard !hasPendingPointerRecheck, isPointerAttached else { return }
        hasPendingPointerRecheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingPointerRecheck = false
            guard self.isPointerAttached else { return }
            self.publishRestingFrameIfNeeded()
            self.recheckPointer()
        }
    }

    func recheckPointer() {
        receiveNativePointer(currentScreenPoint(), source: .recheck)
    }

    /// One authoritative input path. A native packet only replaces the target;
    /// the display link coalesces bursts into one publication per display refresh.
    func receiveNativePointer(_ screenPoint: CGPoint, eventTimestamp: Double? = nil,
                              source: DockPointerEventKind = .nativePointer) {
        let blockers = currentPointerBlockers
        if !blockers.isEmpty {
            recordInputState(source, eventTimestamp: eventTimestamp, blockers: blockers,
                accepted: false, targetChanged: motion.target != nil)
            // Menus/drag/editing/hidden windows must not retain an exit animation.
            if motion.frame.pointer != nil || motion.target != nil || isRunning { reset() }
            return
        }
        // Most system-wide packets belong elsewhere. Avoid conversions and icon
        // scans for other displays or the rest of the desktop.
        let localPoint = window.flatMap { window -> CGPoint? in
            guard window.frame.contains(screenPoint) else { return nil }
            return convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        }
        let inside = localPoint.map { containsPointer?($0) == true } ?? false
        let accepted = inside ? localPoint : nil
        recordInputState(source, eventTimestamp: eventTimestamp, blockers: blockers,
            inside: inside, accepted: accepted != nil, targetChanged: lensCoordinate(accepted) != lensCoordinate(motion.target))
        receive(accepted)
    }

    func recordInputState(_ kind: DockPointerEventKind, eventTimestamp: Double? = nil,
                          blockers: WorkspaceSidebarDockPointerBlockers? = nil,
                          inside: Bool? = nil, accepted: Bool? = nil, targetChanged: Bool = false) {
        guard let performanceTrace else { return }
        performanceTrace.pointerEvent(kind, at: CACurrentMediaTime(), nativeTimestamp: eventTimestamp,
            blockers: (blockers ?? currentPointerBlockers).rawValue, inside: inside, accepted: accepted,
            targetChanged: targetChanged, running: isRunning, hasTarget: motion.target != nil,
            passthrough: window?.ignoresMouseEvents ?? true)
    }
}
