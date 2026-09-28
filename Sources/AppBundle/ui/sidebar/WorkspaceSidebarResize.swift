import AppKit
import Common
import QuartzCore

let workspaceSidebarResizeHandleWidth: CGFloat = 4
/// Shared with the Expanded width setting, so a dragged width always fits its slider.
let workspaceSidebarResizableWidthRange: ClosedRange<Int> = 120...480

/// Only an always-expanded panel beside the tiled windows has an inner edge to drag.
/// A bottom panel's height follows the display, and a collapsible rail opens over windows.
func workspaceSidebarAllowsResize(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    sidebarConfig.pinsSidebarOpen && sidebarConfig.effectiveDockPosition != .bottom
}

func workspaceSidebarResizeWidthBounds(_ sidebarConfig: WorkspaceSidebarConfig) -> ClosedRange<Int> {
    // always-expanded rejects a width that does not exceed collapsed-width.
    let lower = max(workspaceSidebarResizableWidthRange.lowerBound, sidebarConfig.collapsedWidth + 1)
    return lower...max(lower, workspaceSidebarResizableWidthRange.upperBound)
}

/// Two-project browsing shows two panes of the configured width, so each pane moves
/// by half the pointer's travel and the dragged edge stays under the pointer.
func workspaceSidebarResizedWidth(
    startWidth: Int,
    pointerDeltaX: CGFloat,
    position: WorkspaceDockPosition,
    paneCount: Int,
    bounds: ClosedRange<Int>,
) -> Int {
    let direction: CGFloat = position == .right ? -1 : 1
    let proposed = CGFloat(startWidth) + direction * pointerDeltaX / CGFloat(max(paneCount, 1))
    guard proposed.isFinite else { return min(max(startWidth, bounds.lowerBound), bounds.upperBound) }
    return min(max(Int(proposed.rounded()), bounds.lowerBound), bounds.upperBound)
}

/// The strip along the panel's inner edge. It stays inside the visible surface, so it
/// never takes clicks from the tiled windows beside the panel.
func workspaceSidebarResizeHandleFrame(surface: CGRect, position: WorkspaceDockPosition) -> CGRect? {
    guard position != .bottom, surface.width > workspaceSidebarResizeHandleWidth * 2, surface.height > 0 else { return nil }
    let x = position == .right ? surface.minX : surface.maxX - workspaceSidebarResizeHandleWidth
    return CGRect(x: x, y: surface.minY, width: workspaceSidebarResizeHandleWidth, height: surface.height)
}

struct WorkspaceSidebarResizeSession: Equatable {
    let startPointerX: CGFloat
    let startWidth: Int
    let paneCount: Int
    let position: WorkspaceDockPosition
    let target: WorkspaceSidebarWidthTarget
    /// The target's saved width before the drag: nil for a display without its own width.
    let startSavedWidth: Int?
    /// What this drag last put in config. A reload that replaced it wins over the drag.
    var lastAppliedWidth: Int?

    func width(forPointerX pointerX: CGFloat, bounds: ClosedRange<Int>) -> Int {
        workspaceSidebarResizedWidth(startWidth: startWidth, pointerDeltaX: pointerX - startPointerX,
            position: position, paneCount: paneCount, bounds: bounds)
    }

    /// Back at its start width, a display without its own width keeps following the shared one.
    func savedWidth(for width: Int) -> Int? {
        width == startWidth ? startSavedWidth : width
    }
}

extension WorkspaceSidebarPanel {
    /// Widths are remembered by the display menu's name for the panel's display.
    var sidebarDisplayName: String? {
        workspaceSidebarMonitor(forScopeId: monitorScopeId).map { workspaceSidebarMonitorDisplayName($0, among: sortedMonitors) }
    }

    /// The sidebar settings with this display's own width.
    var sidebarSettings: WorkspaceSidebarConfig {
        let settings = config.workspaceSidebar
        // Hover paths read this often. Skip the display lookup while no display has its own width.
        guard settings.usesDisplayWidths, !settings.displayWidths.isEmpty else { return settings }
        return settings.onDisplay(named: sidebarDisplayName)
    }

    var sidebarWidthTarget: WorkspaceSidebarWidthTarget {
        config.workspaceSidebar.widthTarget(forDisplayNamed: sidebarDisplayName)
    }

    @discardableResult
    func beginSidebarResize(atScreenX pointerX: CGFloat) -> Bool {
        let settings = config.workspaceSidebar
        guard sidebarResize == nil, workspaceSidebarAllowsResize(settings), autoHideReason == nil,
              currentSidebarPanelLayout() != nil else { return false }
        let target = sidebarWidthTarget
        sidebarResize = WorkspaceSidebarResizeSession(
            startPointerX: pointerX,
            startWidth: sidebarSettings.width,
            paneCount: isBrowsingSecondProject ? 2 : 1,
            position: settings.effectiveDockPosition,
            target: target,
            startSavedWidth: settings.savedWidth(target),
            lastAppliedWidth: settings.savedWidth(target),
        )
        resizeHandleView.isResizing = true
        installSidebarResizeMouseUpMonitors()
        updateMousePassthrough()
        return true
    }

    func updateSidebarResize(toScreenX pointerX: CGFloat) {
        guard var session = sidebarResize else { return }
        // A config reload during the drag may have turned the setting off, moved the panel,
        // or changed which width the panel's edge sets.
        guard workspaceSidebarAllowsResize(config.workspaceSidebar),
              config.workspaceSidebar.effectiveDockPosition == session.position,
              sidebarWidthTarget == session.target
        else {
            cancelSidebarResize()
            return
        }
        // Bounds follow a reloaded collapsed-width, so the saved width stays valid.
        let width = session.savedWidth(for: session.width(forPointerX: pointerX,
            bounds: workspaceSidebarResizeWidthBounds(config.workspaceSidebar)))
        session.lastAppliedWidth = width
        sidebarResize = session
        applyLiveWorkspaceSidebarWidth(width, for: session.target)
    }

    /// Saves the dragged width. Returns the save, for tests to await.
    @discardableResult
    func endSidebarResize() -> Task<Void, Never>? {
        guard let session = finishSidebarResizeSession(keepingPendingRefresh: true) else { return nil }
        let width = config.workspaceSidebar.savedWidth(session.target)
        guard width == session.lastAppliedWidth, width != session.startSavedWidth else { return nil }
        return commitWorkspaceSidebarWidth(width, for: session.target, previousWidth: session.startSavedWidth)
    }

    /// Double-clicking the edge puts the display back on the shared width. Returns the
    /// save, for tests to await.
    @discardableResult
    func resetSidebarDisplayWidth() -> Task<Void, Never>? {
        let target = sidebarWidthTarget
        guard sidebarResize == nil, case .display = target, workspaceSidebarAllowsResize(config.workspaceSidebar),
              autoHideReason == nil, let previousWidth = config.workspaceSidebar.savedWidth(target)
        else { return nil }
        applyLiveWorkspaceSidebarWidth(nil, for: target)
        workspaceSidebarLiveResizeRefresh.flush()
        return commitWorkspaceSidebarWidth(nil, for: target, previousWidth: previousWidth)
    }

    /// Puts back the width from before the drag, unless a reload has replaced it since.
    /// Cancelling happens inside refresh and hide, so panels and windows catch up on the
    /// next turn of the run loop instead of re-entering them.
    func cancelSidebarResize() {
        // Drop the dragged width's pending refresh rather than running it here.
        guard let session = finishSidebarResizeSession(keepingPendingRefresh: false) else { return }
        if config.workspaceSidebar.savedWidth(session.target) == session.lastAppliedWidth,
           session.lastAppliedWidth != session.startSavedWidth {
            config.workspaceSidebar.setSavedWidth(session.startSavedWidth, for: session.target)
        }
        // Either the restored width or the dropped refresh still has to reach panels and tiles.
        DispatchQueue.main.async {
            WorkspaceSidebarPanel.refreshAll()
            if isWinMuxRuntimeReady { scheduleRefreshSession(.onSidebarResized) }
        }
    }

    private func finishSidebarResizeSession(keepingPendingRefresh: Bool) -> WorkspaceSidebarResizeSession? {
        guard let session = sidebarResize else { return nil }
        sidebarResize = nil
        removeSidebarResizeMouseUpMonitors()
        if keepingPendingRefresh {
            workspaceSidebarLiveResizeRefresh.flush()
        } else {
            workspaceSidebarLiveResizeRefresh.reset()
        }
        resizeHandleView.isResizing = false
        updateMousePassthrough()
        return session
    }

    /// The handle normally receives the mouse-up. If a Space switch or another window takes
    /// it, the drag still ends instead of holding the panel's pointer capture forever.
    private func installSidebarResizeMouseUpMonitors() {
        removeSidebarResizeMouseUpMonitors()
        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.finishSidebarResizeFromMouseUp(atScreenX: NSEvent.mouseLocation.x)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // Where the button went up; another app's event carries screen coordinates.
            let pointerX = event.locationInWindow.x
            Task { @MainActor in self?.finishSidebarResizeFromMouseUp(atScreenX: pointerX) }
        }
        sidebarResizeMouseUpMonitors = [local, global].compactMap { $0 }
    }

    private func removeSidebarResizeMouseUpMonitors() {
        for monitor in sidebarResizeMouseUpMonitors {
            NSEvent.removeMonitor(monitor)
        }
        sidebarResizeMouseUpMonitors = []
    }

    private func finishSidebarResizeFromMouseUp(atScreenX pointerX: CGFloat) {
        guard sidebarResize != nil else { return }
        updateSidebarResize(toScreenX: pointerX)
        endSidebarResize()
    }

    func updateResizeHandle() {
        let frame = sidebarResize != nil || (isVisible && autoHideReason == nil && workspaceSidebarAllowsResize(config.workspaceSidebar))
            ? workspaceSidebarResizeHandleFrame(
                surface: hostingView.convert(visibleSurfaceFrameInHostingView, to: slidingView),
                position: config.workspaceSidebar.effectiveDockPosition)
            : nil
        resizeHandleView.update(frame: frame, position: config.workspaceSidebar.effectiveDockPosition)
    }
}

/// Runs work at most once per interval, finishing with the latest request.
@MainActor
final class WorkspaceSidebarThrottle {
    private let interval: CFTimeInterval
    private var lastRun: CFTimeInterval = -.infinity
    private var pending: (@MainActor () -> Void)?
    private var trailing: DispatchWorkItem?

    init(interval: CFTimeInterval) {
        self.interval = interval
    }

    func run(_ work: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        if trailing == nil, now - lastRun >= interval {
            lastRun = now
            work()
            return
        }
        pending = work
        guard trailing == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        trailing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(interval - (now - lastRun), 0), execute: item)
    }

    func flush() {
        trailing?.cancel()
        trailing = nil
        guard let work = pending else { return }
        pending = nil
        lastRun = CACurrentMediaTime()
        work()
    }

    /// Drops waiting work and lets the next request run at once.
    func reset() {
        trailing?.cancel()
        trailing = nil
        pending = nil
        lastRun = -.infinity
    }
}

/// Panels follow the pointer at up to 60 Hz. Tiled windows retile through coalescing
/// layout-only refresh sessions, which skip windows whose frames did not change.
@MainActor let workspaceSidebarLiveResizeRefresh = WorkspaceSidebarThrottle(interval: 1.0 / 60)

/// Resizes the sidebars and retiles windows while the pointer moves. The Settings
/// file is written once, when the drag ends, so config holds the width only briefly
/// before a reload of the same value replaces it. nil removes a display's own width.
@MainActor
func applyLiveWorkspaceSidebarWidth(_ width: Int?, for target: WorkspaceSidebarWidthTarget = .shared) {
    guard config.workspaceSidebar.savedWidth(target) != width else { return }
    config.workspaceSidebar.setSavedWidth(width, for: target)
    workspaceSidebarLiveResizeRefresh.run {
        WorkspaceSidebarPanel.refreshAll()
        if isWinMuxRuntimeReady { scheduleRefreshSession(.onSidebarResized) }
    }
}

/// Tests replace the file writes; unit tests never touch the real config otherwise.
@MainActor var workspaceSidebarWidthPersistenceForTests: SettingsPersistence?
@MainActor private var workspaceSidebarWidthCommit: Task<Void, Never>?

/// Saves one drag's width through the Expanded width setting's path: validate, write,
/// reload, and roll back on failure. Saves run one at a time, in drag order.
@MainActor
@discardableResult
func commitWorkspaceSidebarWidth(_ width: Int?, for target: WorkspaceSidebarWidthTarget = .shared,
                                 previousWidth: Int?) -> Task<Void, Never>? {
    let persistence: SettingsPersistence
    if let override = workspaceSidebarWidthPersistenceForTests {
        persistence = override
    } else if isUnitTest {
        return nil
    } else {
        persistence = SettingsPersistence()
    }
    let previous = workspaceSidebarWidthCommit
    let task = Task { @MainActor in
        await previous?.value
        do {
            switch target {
                case .shared:
                    guard let width else { return }
                    _ = try await persistence.save([SettingsFileEdit(section: "workspace-sidebar", values: ["width": "\(width)"])])
                case .display(let name):
                    _ = try await persistence.save { text in
                        let updated = updateWorkspaceSidebarDisplayWidthConfig(in: text, display: name, width: width)
                        // The line edit can't rewrite a hand-written inline table, so it would add
                        // a second table or change nothing. Nor may it change any other setting.
                        var expected = parseConfig(text).config.workspaceSidebar
                        expected.displayWidths[name] = width
                        guard parseConfig(updated).config.workspaceSidebar == expected else {
                            throw SettingsEditError("WinMux couldn't update [workspace-sidebar.display-widths] in your configuration. Edit it in Advanced → TOML Editor.")
                        }
                        return updated
                    }
            }
        } catch {
            // A failed reload already restored the file and config. A save that never
            // wrote leaves the dragged width in memory only, so put the old one back.
            if config.workspaceSidebar.savedWidth(target) == width {
                applyLiveWorkspaceSidebarWidth(previousWidth, for: target)
                workspaceSidebarLiveResizeRefresh.flush()
            }
            showWorkspaceSidebarError("The sidebar width could not be saved. \(error.localizedDescription)")
        }
    }
    workspaceSidebarWidthCommit = task
    return task
}

final class WorkspaceSidebarResizeHandleView: NSView {
    weak var panel: WorkspaceSidebarPanel?
    var isResizing = false {
        didSet {
            // A drag that ends over another app, or by cancelling, sends no exit or mouse-up
            // here, so check where the pointer is now.
            if oldValue, !isResizing { isHovered = isPointerInside() }
            if oldValue, !isResizing, !isHovered { releaseResizeCursor() }
            updateIndicator()
        }
    }
    private let resizeCursor = NSCursor.resizeLeftRight
    private var isHovered = false { didSet { updateIndicator() } }
    private var position: WorkspaceDockPosition = .left
    private let indicator = CALayer()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        indicator.cornerRadius = 1
        indicator.opacity = 0
        layer?.addSublayer(indicator)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Sidebar width")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frame nextFrame: CGRect?, position nextPosition: WorkspaceDockPosition) {
        position = nextPosition
        guard let nextFrame else {
            if !isHidden { isHidden = true }
            if isHovered { isHovered = false }
            return
        }
        if frame != nextFrame { frame = nextFrame }
        if isHidden { isHidden = false }
        layoutIndicator()
        updateIndicator()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIndicator()
    }

    override func layout() {
        super.layout()
        layoutIndicator()
    }

    private func layoutIndicator() {
        let width: CGFloat = 2
        // Hug the panel's edge, where the pointer grabs it.
        let x = position == .right ? 0 : bounds.width - width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }

    private func updateIndicator() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        }
        indicator.opacity = isHovered || isResizing ? 1 : 0
        CATransaction.commit()
    }

    private func isPointerInside() -> Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Leaves any cursor the content beside the edge set, such as a text field's I-beam.
    private func releaseResizeCursor() {
        if NSCursor.current === resizeCursor { NSCursor.arrow.set() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        resizeCursor.set()
    }

    override func mouseMoved(with event: NSEvent) { resizeCursor.set() }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isResizing { releaseResizeCursor() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            panel?.resetSidebarDisplayWidth()
            return
        }
        guard panel?.beginSidebarResize(atScreenX: NSEvent.mouseLocation.x) == true else { return }
        resizeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else { return }
        resizeCursor.set()
        panel?.updateSidebarResize(toScreenX: NSEvent.mouseLocation.x)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            // Ending the drag rechecks hover and the cursor.
            panel?.endSidebarResize()
            return
        }
        // A click that never started a drag, or one the panel's mouse-up monitor already ended.
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        if !isHovered { releaseResizeCursor() }
    }
}
