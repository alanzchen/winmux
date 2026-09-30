import AppKit

/// Within this distance of the list's top or bottom, a drag scrolls it.
let workspaceSidebarDropDestinationAutoscrollBand: CGFloat = 28
/// Its fastest scroll, at the very edge.
let workspaceSidebarDropDestinationAutoscrollSpeed: CGFloat = 600

/// How fast a drag at `point` scrolls a list spanning `top` to `bottom`, in AppKit coordinates
/// (y up): negative towards the top, positive towards the end, faster nearer the edge.
func workspaceSidebarDropDestinationAutoscrollVelocity(pointY: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
    let band = workspaceSidebarDropDestinationAutoscrollBand
    guard top - bottom > 2 * band, pointY <= top, pointY >= bottom else { return 0 }
    if pointY > top - band { return -workspaceSidebarDropDestinationAutoscrollSpeed * (pointY - (top - band)) / band }
    if pointY < bottom + band { return workspaceSidebarDropDestinationAutoscrollSpeed * ((bottom + band) - pointY) / band }
    return 0
}

/// One sidebar drag's hints and other-display list: from the drag's first update with two or more
/// displays to its release or cancellation. A display refresh subscription for the whole drag
/// samples the real pointer, so a pause, a close or an edge scroll happens with the pointer still,
/// and a drop preview over the list or another display's sidebar stays live between the gesture's
/// own events. A frame where nothing it depends on changed does nothing.
@MainActor
final class WorkspaceSidebarDropDestinationController {
    static let shared = WorkspaceSidebarDropDestinationController()

    private struct FrameSignature: Equatable {
        let point: CGPoint
        let modelRevision: UInt64
        let modifiers: UInt
        let sourceSurface: CGRect
    }

    private struct Settings: Equatable {
        let enabled: Bool
        let mode: WorkspaceSidebarMode
        let position: WorkspaceDockPosition

        @MainActor init() {
            enabled = TrayMenuModel.shared.isEnabled && config.workspaceSidebar.enabled
            mode = config.workspaceSidebar.mode
            position = config.workspaceSidebar.effectiveDockPosition
        }
    }

    private(set) var sessionGeneration: UInt64?
    /// A drag whose destinations went away mid-gesture, which the same gesture can't reopen.
    private var disabledGeneration: UInt64?
    private(set) var sourceScopeId: String?
    private weak var sourcePanel: WorkspaceSidebarPanel?
    private(set) var hints: [WorkspaceSidebarDropDestinationHint] = []
    private(set) var state = WorkspaceSidebarDropDestinationState()
    private(set) var layout: WorkspaceSidebarDropDestinationLayout?
    private var topologyGeneration: UInt64 = 0
    private var settings: Settings?
    private var lastSignature: FrameSignature?
    private var lastTimestamp: CFTimeInterval?
    private(set) var modelRevision: UInt64 = 0
    private var surfaceGeneration: UInt64 = 0
    private var hintOffset: CGFloat = 0
    /// Frames that ran past the gate, for tests.
    private(set) var processedFrames = 0

    private(set) lazy var hintPanel = WorkspaceSidebarDropDestinationHintPanel()
    private(set) lazy var columnPanel = WorkspaceSidebarDropDestinationColumnPanel()

    var isActive: Bool { sessionGeneration != nil }
    var openId: String? { state.openId }

    /// Called by each accepted update of a supported drag.
    func noteDragUpdate() {
        guard let session = WorkspaceSidebarDragSessions.shared.active else { return }
        if sessionGeneration == session.generation { return }
        if sessionGeneration != nil { end() }
        guard disabledGeneration != session.generation else { return }
        start(generation: session.generation)
    }

    private func start(generation: UInt64) {
        let settings = Settings()
        // A single display, or a sidebar that's off, does nothing at all.
        guard settings.enabled, sortedMonitors.count >= 2, let panel = dragSourcePanel(),
              let monitor = workspaceSidebarMonitor(forScopeId: panel.monitorScopeId) else { return }
        let hints = workspaceSidebarDropDestinationHints(source: monitor, monitors: sortedMonitors)
        guard !hints.isEmpty else { return }
        sessionGeneration = generation
        sourcePanel = panel
        sourceScopeId = panel.monitorScopeId
        self.hints = hints
        self.settings = settings
        topologyGeneration = MonitorConfigurationObserver.shared.topologyGeneration
        state = .init()
        hintOffset = 0
        surfaceGeneration &+= 1
        hintPanel.surfaceRef = .dropDestination(generation: surfaceGeneration)
        hintPanel.mount()
        relayout()
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(hintPanel)
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] timestamp in self?.frame(timestamp: timestamp) }
    }

    /// The panel the drag began in, else the one under the pointer.
    private func dragSourcePanel() -> WorkspaceSidebarPanel? {
        if let scope = currentWorkspaceSidebarDragSourceScopeId(), let panel = WorkspaceSidebarPanel.panel(for: scope),
           panel.isVisible { return panel }
        return WorkspaceSidebarPanel.panel(containing: MousePointerTracker.shared.currentSample.point)
    }

    /// Ends the drag's destinations: its release was captured, or it was cancelled. Drops nothing
    /// and leaves the window drag's own pending drop to the release.
    func end() {
        guard sessionGeneration != nil else { return }
        // Surfaces go first, so nothing finds them; then everything that could reach them.
        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(hintPanel)
        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(columnPanel)
        surfaceGeneration &+= 1
        DisplayRefreshDriver.shared.remove(owner: self)
        hintPanel.tearDown()
        columnPanel.tearDown()
        columnPanel.dropDestination = nil
        hintPanel.model.set(.init())
        sessionGeneration = nil
        sourcePanel = nil
        sourceScopeId = nil
        hints = []
        state = .init()
        layout = nil
        settings = nil
        lastSignature = nil
        lastTimestamp = nil
        hintOffset = 0
    }

    /// Something made the destinations meaningless mid-drag: a display change, the source sidebar
    /// going, the sidebar turned off. They go for the rest of this drag, and its preview is made
    /// again without them.
    private func disable() {
        disabledGeneration = sessionGeneration
        end()
        refreshDragPreview()
    }

    /// The shared model changed: the open list shows it, and its targets are checked again.
    func syncFromShared() {
        guard isActive, let hint = openHint else { return }
        if columnPanel.model.set(snapshot(for: hint)) { modelRevision &+= 1 }
    }

    private var openHint: WorkspaceSidebarDropDestinationHint? {
        state.openId.flatMap { id in hints.first { $0.id == id } }
    }

    private var isRow: Bool { settings?.position == .bottom }

    private func frame(timestamp: CFTimeInterval) {
        let elapsed = lastTimestamp.map { max(timestamp - $0, 0) } ?? 0
        lastTimestamp = timestamp
        tick(pointer: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime, elapsed: elapsed)
    }

    /// One frame with the pointer at `pointer`, in AppKit screen coordinates.
    func tick(pointer: CGPoint, now: TimeInterval, elapsed: TimeInterval) {
        guard let generation = sessionGeneration else { return }
        guard WorkspaceSidebarDragSessions.shared.active?.generation == generation else {
            end()
            return
        }
        guard isStillValid() else {
            disable()
            return
        }
        MousePointerTracker.shared.note(point: normalizeAppKitScreenPoint(pointer))
        process(pointer: pointer, now: now, elapsed: elapsed)
    }

    private func process(pointer: CGPoint, now: TimeInterval, elapsed: TimeInterval) {
        guard let sourcePanel else { return }
        let signature = FrameSignature(point: pointer, modelRevision: modelRevision,
            modifiers: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
            sourceSurface: sourcePanel.visibleSurfaceFrameOnScreen)
        let isTimed = state.nextWake.map { now >= $0 } == true || scrollVelocity(at: pointer) != nil
        guard signature != lastSignature || isTimed else { return }
        let geometryChanged = signature.sourceSurface != lastSignature?.sourceSurface
        lastSignature = signature
        processedFrames += 1
        if geometryChanged { relayout() }
        guard let layout else { return }

        let visible = workspaceSidebarDropDestinationVisibleHints(layout, ids: hints.map(\.id), offset: hintOffset, isRow: isRow)
        let keepOpen = state.openId == nil ? nil : layout.column.map { layout.hintArea.union($0) }
        let previous = state.openId
        // With no room for a list, a pause opens nothing.
        state = workspaceSidebarDropDestinationStep(state, pointer: pointer, now: now,
            hints: layout.columnFits ? visible : [], keepOpen: keepOpen)
        if state.openId != previous { openColumn() }
        autoscroll(pointer: pointer, elapsed: elapsed)
        publishHints()
        refreshPreviewIfNeeded(pointer: pointer, force: state.openId != previous)
    }

    private func isStillValid() -> Bool {
        guard MonitorConfigurationObserver.shared.topologyGeneration == topologyGeneration,
              Settings() == settings,
              let sourcePanel, sourcePanel.isVisible,
              let sourceScopeId, WorkspaceSidebarPanel.panel(for: sourceScopeId) === sourcePanel,
              currentActiveWorkspaceSidebarDrag() != nil || isSidebarPinnedTabDragActive()
        else { return false }
        return true
    }

    private func relayout() {
        guard let sourcePanel else { return }
        let surface = sourcePanel.visibleSurfaceFrameOnScreen
        let visibleFrame = NSScreen.screens.first { $0.frame.intersects(surface) }?.visibleFrame
            ?? sourcePanel.screen?.visibleFrame ?? surface
        let width = openHint.map { CGFloat(config.workspaceSidebar.width(onDisplayNamed: $0.name)) }
            ?? CGFloat(config.workspaceSidebar.width)
        let next = workspaceSidebarDropDestinationLayout(sourceSurface: surface, visibleFrame: visibleFrame,
            position: settings?.position ?? .left, hintCount: hints.count, preferredColumnWidth: width,
            opensColumn: state.openId != nil)
        layout = next
        hintOffset = min(hintOffset, workspaceSidebarDropDestinationHintScrollRange(next, isRow: isRow))
        if let column = next.column, state.openId != nil {
            columnPanel.show(frame: column, above: sourcePanel)
            hintPanel.show(frame: next.hintArea, above: columnPanel)
        } else {
            hintPanel.show(frame: next.hintArea, above: sourcePanel)
        }
        publishHints()
    }

    /// Opens, switches or closes the list to match the state. Each opening is a new surface, so a
    /// drop captured on the list before can never be taken for one on this.
    private func openColumn() {
        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(columnPanel)
        surfaceGeneration &+= 1
        let surface = WorkspaceSidebarSurfaceRef.dropDestination(generation: surfaceGeneration)
        hintPanel.surfaceRef = surface
        columnPanel.surfaceRef = surface
        columnPanel.scroll.offset = 0
        func close() {
            state.openId = nil
            columnPanel.tearDown()
            columnPanel.dropDestination = nil
            relayout()
        }
        guard let hint = openHint, let destination = WorkspaceSidebarDropDestinationIdentity(monitorScopeId: hint.id)
        else { return close() }
        // Placed first: the list is drawn at the width it gets.
        relayout()
        guard let snapshot = snapshot(for: hint) else { return close() }
        columnPanel.dropDestination = destination
        if columnPanel.model.snapshot == nil { columnPanel.mount() }
        columnPanel.model.set(snapshot)
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(columnPanel)
    }

    private func snapshot(for hint: WorkspaceSidebarDropDestinationHint) -> WorkspaceSidebarDropDestinationSnapshot? {
        workspaceSidebarDropDestinationSnapshot(for: hint, surface: columnPanel.surfaceRef,
            width: layout?.column?.width ?? workspaceSidebarDropDestinationMinColumnWidth)
    }

    private func publishHints() {
        guard let layout else { return }
        let area = layout.hintArea
        hintPanel.model.set(.init(hints: hints,
            frames: layout.hints.map { CGRect(x: $0.minX - area.minX, y: area.maxY - $0.maxY, width: $0.width, height: $0.height) },
            armingId: state.arming?.id, openId: state.openId, columnFits: layout.columnFits, isRow: isRow,
            offset: hintOffset))
    }

    /// The scroll the pointer is asking for: the list's, or the hints' when they overflow.
    private func scrollVelocity(at pointer: CGPoint) -> (list: Bool, velocity: CGFloat)? {
        guard let layout else { return nil }
        if let column = layout.column, state.openId != nil, pointer.x >= column.minX, pointer.x <= column.maxX {
            let velocity = workspaceSidebarDropDestinationAutoscrollVelocity(pointY: pointer.y,
                top: column.maxY - workspaceSidebarDropDestinationHeaderHeight, bottom: column.minY)
            let offset = columnPanel.scroll.offset
            if velocity < 0 && offset > 0 || velocity > 0 && offset < columnPanel.scroll.maxOffset { return (true, velocity) }
        }
        if layout.hintsOverflow, !isRow, pointer.x >= layout.hintArea.minX, pointer.x <= layout.hintArea.maxX {
            let velocity = workspaceSidebarDropDestinationAutoscrollVelocity(pointY: pointer.y,
                top: layout.hintArea.maxY, bottom: layout.hintArea.minY)
            let range = workspaceSidebarDropDestinationHintScrollRange(layout, isRow: false)
            if velocity < 0 && hintOffset > 0 || velocity > 0 && hintOffset < range { return (false, velocity) }
        }
        return nil
    }

    private func autoscroll(pointer: CGPoint, elapsed: TimeInterval) {
        guard let scrolling = scrollVelocity(at: pointer), let layout else { return }
        let step = scrolling.velocity * CGFloat(min(elapsed, 0.1))
        if scrolling.list {
            let scroll = columnPanel.scroll
            let next = min(max(scroll.offset + step, 0), scroll.maxOffset)
            if next != scroll.offset { scroll.offset = next }
        } else {
            hintOffset = min(max(hintOffset + step, 0), workspaceSidebarDropDestinationHintScrollRange(layout, isRow: false))
        }
    }

    /// Over the list or another display's sidebar, only this keeps the drag's preview live; over
    /// its own sidebar, the gesture does.
    private func refreshPreviewIfNeeded(pointer: CGPoint, force: Bool) {
        let surface = workspaceSidebarSurface(at: normalizeAppKitScreenPoint(pointer))?.surface
        let isOffSource = surface.map { $0 != .panel(monitorScopeId: sourceScopeId ?? "") } ?? false
        let ownsPreview = workspaceSidebarDropPreviewOwnerIsTemporary(currentWorkspaceSidebarDropPreviewOwnerScopeId())
        if force || isOffSource || ownsPreview { refreshDragPreview() }
    }

    private func refreshDragPreview() {
        if currentActiveWorkspaceSidebarDrag() != nil {
            refreshActiveWorkspaceSidebarDragPreviewIfNeeded()
        } else {
            refreshActiveSidebarPinnedTabDragPreview()
        }
    }

    func resetForTests() {
        end()
        disabledGeneration = nil
        processedFrames = 0
        modelRevision = 0
    }
}
