import AppKit
import Common

let workspaceSidebarResizeHandleWidth: CGFloat = 6
/// Shared with the Expanded width setting, so a dragged width always fits its slider.
let workspaceSidebarResizableWidthRange: ClosedRange<Int> = 120...480

/// Only an always-expanded panel beside the tiled windows has an inner edge to drag.
/// A bottom panel's height follows the display, and a collapsible rail opens over windows.
func workspaceSidebarAllowsResize(_ sidebarConfig: WorkspaceSidebarConfig) -> Bool {
    sidebarConfig.alwaysExpanded && sidebarConfig.effectiveDockPosition != .bottom
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
    let bounds: ClosedRange<Int>

    func width(forPointerX pointerX: CGFloat) -> Int {
        workspaceSidebarResizedWidth(startWidth: startWidth, pointerDeltaX: pointerX - startPointerX,
            position: position, paneCount: paneCount, bounds: bounds)
    }
}

extension WorkspaceSidebarPanel {
    @discardableResult
    func beginSidebarResize(atScreenX pointerX: CGFloat) -> Bool {
        let settings = config.workspaceSidebar
        guard sidebarResize == nil, workspaceSidebarAllowsResize(settings), autoHideReason == nil,
              currentSidebarPanelLayout() != nil else { return false }
        sidebarResize = WorkspaceSidebarResizeSession(
            startPointerX: pointerX,
            startWidth: settings.width,
            paneCount: viewModel.workspaceSidebarVisibleWidth > CGFloat(settings.width) + 0.5 ? 2 : 1,
            position: settings.effectiveDockPosition,
            bounds: workspaceSidebarResizeWidthBounds(settings),
        )
        resizeHandleView.isResizing = true
        updateMousePassthrough()
        return true
    }

    func updateSidebarResize(toScreenX pointerX: CGFloat) {
        guard let session = sidebarResize else { return }
        // A config reload during the drag may have turned the setting off or moved the panel.
        guard workspaceSidebarAllowsResize(config.workspaceSidebar),
              config.workspaceSidebar.effectiveDockPosition == session.position
        else {
            endSidebarResize()
            return
        }
        applyLiveWorkspaceSidebarWidth(session.width(forPointerX: pointerX))
    }

    func endSidebarResize() {
        guard let session = sidebarResize else { return }
        sidebarResize = nil
        resizeHandleView.isResizing = false
        updateMousePassthrough()
        let width = config.workspaceSidebar.width
        guard width != session.startWidth else { return }
        commitWorkspaceSidebarWidth(width, previousWidth: session.startWidth)
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

/// Resizes every sidebar and retiles windows while the pointer moves. The Settings
/// file is written once, when the drag ends, so config holds the width only briefly
/// before a reload of the same value replaces it.
@MainActor
func applyLiveWorkspaceSidebarWidth(_ width: Int) {
    guard config.workspaceSidebar.width != width else { return }
    config.workspaceSidebar.width = width
    WorkspaceSidebarPanel.refreshAll()
    // Refresh sessions coalesce, so fast drags retile as often as layout can keep up.
    if isWinMuxRuntimeReady { scheduleRefreshSession(.configAutoReload) }
}

@MainActor
func commitWorkspaceSidebarWidth(
    _ width: Int,
    previousWidth: Int,
    persistence: SettingsPersistence = SettingsPersistence(),
) {
    if isUnitTest { return }
    Task { @MainActor in
        do {
            // Same path as the Expanded width setting: validate, write, reload, and roll back on failure.
            _ = try await persistence.save([SettingsFileEdit(section: "workspace-sidebar", values: ["width": "\(width)"])])
        } catch {
            if config.workspaceSidebar.width == width { applyLiveWorkspaceSidebarWidth(previousWidth) }
            showWorkspaceSidebarError("The sidebar width could not be saved. \(error.localizedDescription)")
        }
    }
}

final class WorkspaceSidebarResizeHandleView: NSView {
    weak var panel: WorkspaceSidebarPanel?
    var isResizing = false { didSet { updateIndicator() } }
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
        indicator.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        CATransaction.commit()
    }

    private func updateIndicator() {
        indicator.opacity = isHovered || isResizing ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isResizing { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard panel?.beginSidebarResize(atScreenX: NSEvent.mouseLocation.x) == true else { return }
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else { return }
        NSCursor.resizeLeftRight.set()
        panel?.updateSidebarResize(toScreenX: NSEvent.mouseLocation.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizing else { return }
        panel?.endSidebarResize()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHovered = inside
        if !inside { NSCursor.arrow.set() }
    }
}
