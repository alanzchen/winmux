import AppKit
import SwiftUI

// Temporary drop UI lives in two panels above the sidebar a drag started in: the other displays'
// hints, and the list one of them opens. Both are click-through for their whole life, so the drag
// keeps its gesture and nothing takes focus; the drag finds them by hit testing, as it does the
// sidebars.

@MainActor
class WorkspaceSidebarDropDestinationPanel: NSPanelHud {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    var surfaceRef: WorkspaceSidebarSurfaceRef = .dropDestination(generation: 0)

    override init() {
        super.init()
        hasShadow = false
        isFloatingPanel = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = true
        backgroundColor = .clear
        // Above every sidebar, below the pointer's drag image.
        level = WinMuxPanelLayer.workspaceSidebar.level
        contentView = hostingView
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel at `frame`, in AppKit screen coordinates, above `window`.
    func show(frame: CGRect, above window: NSWindow?) {
        if self.frame != frame { setFrame(frame, display: false) }
        if let window, window.isVisible, window.level == level {
            order(.above, relativeTo: window.windowNumber)
        } else if !isVisible {
            orderFrontRegardless()
        }
    }

    func surfaceRectNormalized(containing point: CGPoint) -> Rect? {
        guard isVisible else { return nil }
        let rect = frame.monitorFrameNormalized()
        return rect.contains(point) ? rect : nil
    }

    /// Hidden hosts can defer SwiftUI teardown; finish it before ordering out.
    func tearDown() {
        hostingView.rootView = AnyView(EmptyView())
        hostingView.layoutSubtreeIfNeeded()
        if isVisible { orderOut(nil) }
    }
}

/// The other displays' rails. They take no drops: pausing on one opens its list.
@MainActor
final class WorkspaceSidebarDropDestinationHintPanel: WorkspaceSidebarDropDestinationPanel, WorkspaceSidebarTemporaryDropSurface {
    let model = WorkspaceSidebarDropDestinationHintsModel()
    let stackingOrder = 2
    var dropDestination: WorkspaceSidebarDropDestinationIdentity? { nil }
    /// The rails, in AppKit screen coordinates. Only they are the surface: the gaps between them
    /// cover nothing, so what's under a gap still takes drops.
    var railFrames: [CGRect] = []

    override func surfaceRectNormalized(containing point: CGPoint) -> Rect? {
        guard isVisible else { return nil }
        return railFrames.lazy.map { $0.monitorFrameNormalized() }.first { $0.contains(point) }
    }

    func mount() {
        hostingView.rootView = AnyView(WorkspaceSidebarDropDestinationHintsView(model: model))
    }

    func dropTarget(atNormalizedPoint _: CGPoint, hitSlop _: NSEdgeInsets, includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        nil
    }
}

/// Another display's list.
@MainActor
final class WorkspaceSidebarDropDestinationColumnPanel: WorkspaceSidebarDropDestinationPanel, WorkspaceSidebarTemporaryDropSurface {
    let model = WorkspaceSidebarDropDestinationColumnModel()
    let scroll = WorkspaceSidebarDropDestinationScrollModel()
    let stackingOrder = 1
    var dropDestination: WorkspaceSidebarDropDestinationIdentity?
    /// In the hosting view's coordinates, as the list reports them, for this opening only.
    private(set) var targets: [WorkspaceSidebarDropTargetFrame] = []

    func mount() {
        hostingView.rootView = AnyView(WorkspaceSidebarDropDestinationView(model: model, scroll: scroll) { [weak self] in
            self?.setTargets($1, reportedFor: $0)
        })
    }

    /// Only targets laid out for the list now open count: a list that just switched displays
    /// takes no drops until its own targets arrive.
    func setTargets(_ targets: [WorkspaceSidebarDropTargetFrame], reportedFor surface: WorkspaceSidebarSurfaceRef) {
        guard surface == surfaceRef, targets != self.targets else { return }
        self.targets = targets
        WorkspaceSidebarDropTargetsRevision.bump()
    }

    func clearTargets() {
        guard !targets.isEmpty else { return }
        targets = []
        WorkspaceSidebarDropTargetsRevision.bump()
    }

    override func tearDown() {
        clearTargets()
        model.set(nil)
        scroll.offset = 0
        super.tearDown()
    }

    func setTargetsForTests(_ targets: [WorkspaceSidebarDropTargetFrame]) { setTargets(targets, reportedFor: surfaceRef) }

    func dropTarget(atNormalizedPoint point: CGPoint, hitSlop: NSEdgeInsets, includesTabGaps: Bool) -> WorkspaceSidebarDropTarget? {
        let screenPoint = CGPoint(x: point.x, y: mainMonitor.height - point.y)
        let localPoint = hostingView.convert(convertPoint(fromScreen: screenPoint), from: nil)
        guard let target = workspaceSidebarLocalDropTarget(at: localPoint, targets: targets, surface: hostingView.bounds,
            hitSlop: hitSlop, includesTabGaps: includesTabGaps) else { return nil }
        let screenRect = convertToScreen(hostingView.convert(target.frame, to: nil))
        return WorkspaceSidebarDropTarget(kind: target.kind, rect: screenRect.monitorFrameNormalized(),
            acceptsSides: target.acceptsSides, tabReorderDestination: target.tabReorderDestination)
    }
}
