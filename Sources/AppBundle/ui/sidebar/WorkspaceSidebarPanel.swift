import AppKit
import Common
import CoreGraphics
import SwiftUI

let workspaceSidebarPanelId = "WinMux.workspaceSidebar"
let workspaceSidebarContentLeadingInset: CGFloat = 12
let workspaceSidebarContentTrailingInset: CGFloat = 12
let workspaceSidebarCompactRailHorizontalInset: CGFloat = 7
let workspaceSidebarSectionInnerHorizontalInset: CGFloat = 5
let workspaceSidebarSectionGap: CGFloat = 5
let workspaceSidebarBadgeWidth: CGFloat = 22
let workspaceSidebarHeaderSpacing: CGFloat = 10
let workspaceSidebarHeaderRowLeadingPadding: CGFloat = 6
let workspaceSidebarRowsRevealProgress: CGFloat = 0.58
let workspaceSidebarPanelRightCornerRadius: CGFloat = RadiusToken.panel
let workspaceSidebarPlateCornerRadius: CGFloat = RadiusToken.section
let workspaceSidebarSectionCornerRadius: CGFloat = workspaceSidebarPlateCornerRadius
let workspaceSidebarRowCornerRadius: CGFloat = RadiusToken.row
let workspaceSidebarRowHorizontalPadding: CGFloat = 4
let workspaceSidebarWindowRowsLeadingIndent: CGFloat = 8
let workspaceSidebarAppIconSize: CGFloat = 14
let workspaceSidebarAppIconTextSpacing: CGFloat = 6
let workspaceSidebarTabGroupChildLeadingIndent: CGFloat = workspaceSidebarAppIconSize + workspaceSidebarAppIconTextSpacing - 2
let workspaceSidebarControlHeight: CGFloat = 30
let workspaceSidebarDropdownHeight: CGFloat = 28
let workspaceSidebarSearchHeight: CGFloat = 28
let workspaceSidebarDropdownCornerRadius: CGFloat = RadiusToken.card
let workspaceSidebarDropdownPadding: CGFloat = 7
let workspaceSidebarDropdownLabelSize: CGFloat = 11.5
let workspaceSidebarDropdownSymbolSize: CGFloat = 10.5
let workspaceSidebarPagerHeight: CGFloat = 32
let workspaceSidebarWorkspaceSectionHeaderHeight: CGFloat = 32
let workspaceSidebarWorkspaceRowHeight: CGFloat = 24
let workspaceSidebarWorkspaceSectionHeightCompact: CGFloat = 32
let workspaceSidebarWorkspaceSectionHeightExpanded: CGFloat = 32
let workspaceSidebarInUseOverrideEmptySectionMinHeight: CGFloat = 76
let workspaceSidebarProjectDotFrameHeight: CGFloat = 32
let workspaceSidebarMenuRowHeight: CGFloat = 28
let workspaceSidebarMenuRowSpacing: CGFloat = 3
let workspaceSidebarMenuRowHorizontalPadding: CGFloat = 10
let workspaceSidebarHoverAnimation: Animation = MotionToken.hover
let workspaceSidebarReducedMotionHoverAnimation: Animation = MotionToken.quick
let workspaceSidebarProjectSwipeIntentThreshold: CGFloat = 5
let workspaceSidebarProjectSwipeNavigateThreshold: CGFloat = 44
let workspaceSidebarProjectSwipeCreateThreshold: CGFloat = 104
let workspaceSidebarProjectSwipeFormationStart: CGFloat = 22
let workspaceSidebarHoverOpenThresholdFraction: CGFloat = 0.75
let workspaceSidebarDisplayEdgeCompactionMargin: CGFloat = 12

struct WorkspaceSidebarProjectColorPreset: Hashable, Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
}

let workspaceSidebarProjectColorPresets: [WorkspaceSidebarProjectColorPreset] = [
    WorkspaceSidebarProjectColorPreset(name: "Blue", hex: "#7BA3C9"),
    WorkspaceSidebarProjectColorPreset(name: "Cyan", hex: "#6FBAB4"),
    WorkspaceSidebarProjectColorPreset(name: "Green", hex: "#7DBF8E"),
    WorkspaceSidebarProjectColorPreset(name: "Yellow", hex: "#C9B97A"),
    WorkspaceSidebarProjectColorPreset(name: "Orange", hex: "#C4956E"),
    WorkspaceSidebarProjectColorPreset(name: "Red", hex: "#C48181"),
    WorkspaceSidebarProjectColorPreset(name: "Pink", hex: "#BF8AAE"),
    WorkspaceSidebarProjectColorPreset(name: "Violet", hex: "#9B8FC4"),
]
extension WorkspaceSidebarPanel {
    func animateVisibleSidebarWidth(_ width: CGFloat, animation: Animation) {
        // Only refresh, after checking native visibility, can reveal a suppressed
        // panel. A reentrant search-cancellation callback cannot override it.
        guard autoHideReason != .systemChrome else { return }
        debugWorkspaceSidebarHoverLog("animateWidth panel=\(monitorScopeId) from=\(viewModel.workspaceSidebarVisibleWidth) to=\(width) frame=\(frame) mouse=\(NSEvent.mouseLocation) ignores=\(ignoresMouseEvents) expanded=\(viewModel.isWorkspaceSidebarExpanded)")
        if width <= 0 {
            hideSidebar(.pointerExit)
        } else if autoHideReason != nil || viewModel.workspaceSidebarVisibleWidth == 0 {
            revealSidebar(width: width)
        } else {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation) {
                viewModel.workspaceSidebarVisibleWidth = width
            }
        }
        updateMousePassthrough()
        // The hover region just changed size under a possibly stationary cursor.
        scheduleHoverRecheckSoon()
    }

    func expandSidebar(to expandedWidth: CGFloat, reason: WorkspaceSidebarExpansionReason = .passive) {
        guard currentSidebarPanelLayout() != nil else { return }
        guard reason != .hover || NSApp.modalWindow == nil else { return }
        debugWorkspaceSidebarHoverLog("expandSidebar panel=\(monitorScopeId) target=\(expandedWidth) visible=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
        pendingExpand?.cancel()
        pendingExpand = nil
        NotificationCenter.default.post(
            name: workspaceSidebarWillExpandNotification,
            object: self,
            userInfo: [workspaceSidebarExpansionStartsSearchKey: reason.startsSearch(
                alwaysExpanded: config.workspaceSidebar.alwaysExpanded,
                isDragging: isMouseWindowDragInProgress() || isWorkspaceSidebarItemDragActive(),
                isTrackingMenu: menuTrackingDepth > 0 || Date() < menuTrackingGraceUntil,
            )],
        )
        viewModel.isWorkspaceSidebarExpanded = true
        if !isVisible {
            refresh()
        }
        // Opening search or a rename must keep room for an existing second project.
        // Browse-mode and configuration changes resize the surface explicitly.
        let targetWidth = max(expandedWidth, viewModel.workspaceSidebarVisibleWidth)
        guard viewModel.workspaceSidebarVisibleWidth != targetWidth || autoHideReason != nil else {
            updateMousePassthrough()
            return
        }
        animateVisibleSidebarWidth(targetWidth, animation: .easeInOut(duration: animationDuration))
    }

    func cancelExpansionWork() {
        debugWorkspaceSidebarHoverLog("cancelExpansionWork panel=\(monitorScopeId) pendingExpand=\(pendingExpand != nil) pendingCollapse=\(pendingCollapse != nil) pendingFinalize=\(pendingCollapseFinalize != nil)")
        pendingExpand?.cancel()
        pendingExpand = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
    }
}
extension WorkspaceSidebarPanel {
    func updateDropTargets(_ targets: [WorkspaceSidebarDropTargetFrame]) {
        guard targets != localDropTargetFrames else { return }
        localDropTargetFrames = targets
    }

    func updateSurfaceFrame(_ nextFrame: CGRect) {
        guard nextFrame != visibleSurfaceFrame else { return }
        visibleSurfaceFrame = nextFrame
        // This cache is native state, not an observed SwiftUI model. Updating hit regions
        // from the rendered frame therefore cannot create a layout measurement loop.
        // Surface and icon preferences arrive separately in one layout pass.
        // Recheck once with both current values, avoiding an intermediate exit.
        scheduleHoverRecheckSoon()
    }

    func updateDockIconFrames(_ frames: [CGRect]) {
        guard dockIconFrames != frames else { return }
        dockIconFrames = frames
        scheduleHoverRecheckSoon()
    }

    func updateDockRestingWidth(_ width: CGFloat?) {
        guard fittedDockRestingWidth != width else { return }
        // Keep the resting fit through hide/reveal; the animated surface can approach
        // zero width. This native cache never feeds back into SwiftUI layout.
        fittedDockRestingWidth = width
        scheduleHoverRecheckSoon()
    }

    func isScreenPointInsideDockIcon(_ point: CGPoint) -> Bool {
        let localPoint = hostingView.convert(convertPoint(fromScreen: point), from: nil)
        return dockIconFrames.contains { $0.contains(localPoint) }
    }

    var visibleSurfaceFrameInHostingView: CGRect {
        if let visibleSurfaceFrame { return visibleSurfaceFrame }
        // The compact Dock's length is content-dependent. Before its first layout,
        // do not invent a full-display hit region that could steal hover/clicks.
        guard !config.workspaceSidebar.showAppIcons else { return .zero }
        let settings = config.workspaceSidebar
        let startWidth = settings.effectiveCollapsedWidth
        let progress = (viewModel.workspaceSidebarVisibleWidth - startWidth) / max(CGFloat(settings.width) - startWidth, 1)
        return workspaceSidebarSurfaceFrame(
            availableSize: hostingView.bounds.size,
            visibleWidth: viewModel.workspaceSidebarVisibleWidth,
            compactHeight: hostingView.bounds.height,
            expansionProgress: progress,
            fitsDockContent: settings.showAppIcons,
            compactLeftGap: CGFloat(settings.effectiveLeftGap), position: settings.effectiveDockPosition
        )
    }

    var visibleSurfaceFrameOnScreen: CGRect {
        convertToScreen(hostingView.convert(visibleSurfaceFrameInHostingView, to: nil))
    }

    func dropTarget(atScreenPoint point: CGPoint, hitSlop: NSEdgeInsets) -> WorkspaceSidebarDropTarget? {
        guard sidebarAcceptsPointer else { return nil }
        let localPoint = hostingView.convert(convertPoint(fromScreen: point), from: nil)
        guard let target = workspaceSidebarLocalDropTarget(at: localPoint,
            targets: localDropTargetFrames, surface: visibleSurfaceFrameInHostingView, hitSlop: hitSlop)
        else { return nil }
        // Convert only the winning target, on demand. Hover animation never needs
        // to project every workspace on every display into screen coordinates.
        let screenRect = convertToScreen(hostingView.convert(target.frame, to: nil))
        return WorkspaceSidebarDropTarget(kind: target.kind, rect: screenRect.monitorFrameNormalized())
    }

    func visibleScreenRectNormalized() -> Rect? {
        guard isVisible, sidebarAcceptsPointer else { return nil }
        let surface = visibleSurfaceFrameOnScreen
        return surface.isEmpty ? nil : surface.monitorFrameNormalized()
    }
}
extension WorkspaceSidebarPanel {
    static func suppressEdgeTrapForWorkspaceActivation(duration: TimeInterval = 0.75) {
        let until = ProcessInfo.processInfo.systemUptime + duration
        for panel in visiblePanels {
            debugWorkspaceSidebarEdgeTrapLog("suppress panel=\(panel.monitorScopeId) until=\(until) sample=\(MousePointerTracker.shared.currentSample)")
            panel.edgeTrapStartedAt = nil
            panel.edgeTrapSuppressedUntil = max(panel.edgeTrapSuppressedUntil, until)
            panel.lastEdgeTrapSample = MousePointerTracker.shared.currentSample
        }
    }

    static func trapCursorForVisiblePanelsIfNeeded() {
        for panel in visiblePanels {
            panel.trapCursorForSidebarActivationIfNeeded()
        }
    }

    func trapCursorForSidebarActivationIfNeeded() {
        let sample = MousePointerTracker.shared.currentSample
        let collapsedWidth = workspaceSidebarRestingWidth(config.workspaceSidebar)
        debugWorkspaceSidebarEdgeTrapLog(
            "entry panel=\(monitorScopeId) visible=\(isVisible) enabled=\(config.workspaceSidebar.enabled) shift=\(currentSessionModifierFlags().contains(.maskShift)) mouseDrag=\(isMouseWindowDragInProgress()) sidebarDrag=\(isWorkspaceSidebarItemDragActive()) width=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) sample=\(sample) previous=\(String(describing: lastEdgeTrapSample)) suppressUntil=\(edgeTrapSuppressedUntil) startedAt=\(String(describing: edgeTrapStartedAt))"
        )
        guard isVisible,
              config.workspaceSidebar.enabled,
              workspaceSidebarAllowsEdgeTrap(config.workspaceSidebar),
              !currentSessionModifierFlags().contains(.maskShift),
              !isMouseWindowDragInProgress(),
              !isWorkspaceSidebarItemDragActive(),
              viewModel.workspaceSidebarVisibleWidth <= collapsedWidth + 0.5
        else {
            debugWorkspaceSidebarEdgeTrapLog("skipPreconditions panel=\(monitorScopeId)")
            edgeTrapStartedAt = nil
            lastEdgeTrapSample = sample
            return
        }

        let position = config.workspaceSidebar.effectiveDockPosition
        let point = workspaceSidebarEdgePoint(sample.point, position: position)
        let surface = workspaceSidebarEdgeRect(visibleSurfaceFrameOnScreen.monitorFrameNormalized(), position: position)
        guard point.y >= surface.minY, point.y < surface.maxY else {
            edgeTrapStartedAt = nil
            lastEdgeTrapSample = sample
            return
        }

        defer { lastEdgeTrapSample = sample }
        let previous = lastEdgeTrapSample
        guard sample.timestamp >= edgeTrapSuppressedUntil,
              let layoutMonitor = sortedMonitors.first(where: { workspaceSidebarMonitorScopeId(for: $0) == monitorScopeId })
        else {
            debugWorkspaceSidebarEdgeTrapLog("skipSuppressedOrNoMonitor panel=\(monitorScopeId) sampleTime=\(sample.timestamp) suppressUntil=\(edgeTrapSuppressedUntil)")
            edgeTrapStartedAt = nil
            return
        }
        let monitorFrame = workspaceSidebarEdgeRect(layoutMonitor.rect, position: position)
        let hasLeftMonitor = workspaceSidebarHasAdjacentEdgeMonitor(frame: monitorFrame,
            otherFrames: sortedMonitors.map { workspaceSidebarEdgeRect($0.rect, position: position) })
        let previousPoint = previous.map { workspaceSidebarEdgePoint($0.point, position: position) }
        let crossesTrapRegion = workspaceSidebarCrossesEdge(point: point, previous: previousPoint,
            frame: monitorFrame, band: edgeTrapBandWidth)
        guard hasLeftMonitor, crossesTrapRegion else {
            debugWorkspaceSidebarEdgeTrapLog("skipRegion panel=\(monitorScopeId) hasLeftMonitor=\(hasLeftMonitor) crosses=\(crossesTrapRegion) monitorFrame=\(layoutMonitor.rect) samplePoint=\(sample.point) previousPoint=\(String(describing: previous?.point))")
            edgeTrapStartedAt = nil
            return
        }

        let deltaX = previousPoint.map { point.x - $0.x } ?? 0
        let isLeftwardFlick = deltaX <= -edgeTrapReleaseVelocityThreshold
        let isContinuingTrap = edgeTrapStartedAt != nil && point.x <= monitorFrame.minX + edgeTrapBandWidth
        let shouldTrap = isContinuingTrap || isLeftwardFlick || isMouseWindowDragInProgress()
        guard shouldTrap else {
            debugWorkspaceSidebarEdgeTrapLog("skipVelocity panel=\(monitorScopeId) deltaX=\(deltaX) isLeftwardFlick=\(isLeftwardFlick) isContinuingTrap=\(isContinuingTrap)")
            edgeTrapStartedAt = nil
            return
        }

        let startedAt = edgeTrapStartedAt ?? sample.timestamp
        edgeTrapStartedAt = startedAt
        guard sample.timestamp - startedAt < edgeTrapReleaseDelay else {
            debugWorkspaceSidebarEdgeTrapLog("release panel=\(monitorScopeId) elapsed=\(sample.timestamp - startedAt) grace=\(edgeTrapCrossingGrace)")
            edgeTrapStartedAt = nil
            edgeTrapSuppressedUntil = sample.timestamp + edgeTrapCrossingGrace
            return
        }

        let trappedPoint = workspaceSidebarEdgePoint(CGPoint(
            x: monitorFrame.minX + 1,
            y: point.y.coerce(in: monitorFrame.minY ... max(monitorFrame.minY, monitorFrame.maxY - 1))
        ), position: position, inverse: true)
        debugWorkspaceSidebarEdgeTrapLog("warp panel=\(monitorScopeId) from=\(sample.point) to=\(trappedPoint) deltaX=\(deltaX) isLeftwardFlick=\(isLeftwardFlick) isContinuingTrap=\(isContinuingTrap) elapsed=\(sample.timestamp - startedAt) monitorFrame=\(layoutMonitor.rect)")
        CGWarpMouseCursorPosition(trappedPoint)
        MousePointerTracker.shared.note(point: trappedPoint, timestamp: sample.timestamp)
    }


}
enum WorkspaceSidebarInlineTextKey {
    case text(String)
    case deleteBackward
    case deleteForward
    case deleteWordBackward
    case deleteToBeginningOfLine
    case moveUp
    case moveDown
    case commit
    case cancel
    case ignored
}

private let workspaceSidebarInlineTextEventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let key = workspaceSidebarInlineTextKey(from: event)
    if case .ignored = key {
        return Unmanaged.passUnretained(event)
    }
    // Installed on the main run loop: decide before swallowing the event, not in
    // a deferred task that may run after the user has switched applications.
    let handled = MainActor.assumeIsolated { WorkspaceSidebarPanel.inputSession.handle(key) }
    return handled ? nil : Unmanaged.passUnretained(event)
}

private func workspaceSidebarInlineTextKey(from event: CGEvent) -> WorkspaceSidebarInlineTextKey {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let usesCommand = flags.contains(.maskCommand)
    let usesOption = flags.contains(.maskAlternate)
    let usesControl = flags.contains(.maskControl)
    switch keyCode {
        case 36, 76:
            return .commit
        case 53:
            return .cancel
        case 51:
            if usesCommand {
                return .deleteToBeginningOfLine
            }
            if usesOption {
                return .deleteWordBackward
            }
            return .deleteBackward
        case 117:
            return .deleteForward
        case 126:
            return .moveUp
        case 125:
            return .moveDown
        default:
            break
    }

    guard !usesCommand, !usesOption, !usesControl else {
        return .ignored
    }

    var length = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return .ignored }
    let text = String(utf16CodeUnits: chars, count: length)
    guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        return .ignored
    }
    return text.isEmpty ? .ignored : .text(text)
}

extension WorkspaceSidebarPanel {
    func inlineTextKey(from event: NSEvent) -> WorkspaceSidebarInlineTextKey {
        let usesCommand = event.modifierFlags.contains(.command)
        let usesOption = event.modifierFlags.contains(.option)
        let usesControl = event.modifierFlags.contains(.control)
        switch event.keyCode {
            case 36, 76:
                return .commit
            case 53:
                return .cancel
            case 51:
                if usesCommand {
                    return .deleteToBeginningOfLine
                }
                if usesOption {
                    return .deleteWordBackward
                }
                return .deleteBackward
            case 117:
                return .deleteForward
            case 126:
                return .moveUp
            case 125:
                return .moveDown
            default:
                break
        }

        guard !usesCommand, !usesOption, !usesControl,
              let text = event.characters,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return .ignored
        }
        return text.isEmpty ? .ignored : .text(text)
    }

    func beginInlineTextEditing(
        locksExpansion: Bool = true,
        cancelsOnPointerExit: Bool = true,
        onCancel: (@MainActor () -> Void)? = nil,
        onKeyDown: (@MainActor (WorkspaceSidebarInlineTextKey) -> Void)? = nil
    ) {
        guard NSApp.modalWindow == nil else { return }
        debugWorkspaceSidebarRenameLog("beginInlineTextEditing isKeyBefore=\(isKeyWindow) firstResponder=\(String(describing: firstResponder)) mouseInside=\(isMouseInsideVisibleRegion())")
        guard currentSidebarPanelLayout() != nil else { return }
        WorkspaceSidebarPanel.inputSession.acquire(self)
        if !inlineTextEditingActive {
            let frontmost = NSWorkspace.shared.frontmostApplication
            inlineTextEditingPreviousApplication = frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier
                ? frontmost : (focus.windowOrNil?.app as? MacApp)?.nsApp
        }
        inlineTextEditingActive = true
        inlineTextEditingGeneration += 1
        inlineTextEditingLocksExpansion = locksExpansion
        inlineTextEditingCancelsOnPointerExit = cancelsOnPointerExit
        inlineTextEditingCancel = onCancel
        inlineTextEditingKeyDown = onKeyDown
        inlineTextEditingStartedAt = .now
        inlineTextEditingPointerEnteredVisibleRegion = isMouseInsideVisibleRegion()
        prepareForInlineTextEditing()
        installInlineTextEditingEventMonitors()
        installInlineTextEditingKeyEventTap()
    }

    func endInlineTextEditing() {
        guard inlineTextEditingActive else { return }
        debugWorkspaceSidebarRenameLog("endInlineTextEditing isKey=\(isKeyWindow) firstResponder=\(String(describing: firstResponder))")
        inlineTextEditingActive = false
        inlineTextEditingLocksExpansion = true
        inlineTextEditingCancelsOnPointerExit = true
        WorkspaceSidebarPanel.inputSession.release(self)
        inlineTextEditingCancel = nil
        inlineTextEditingKeyDown = nil
        inlineTextEditingPointerEnteredVisibleRegion = false
        inlineTextEditingPreviousApplication = nil
        removeInlineTextEditingEventMonitors()
        removeInlineTextEditingKeyEventTap()
        clearWorkspaceSidebarCommandInputState(self)
        NotificationCenter.default.post(name: workspaceSidebarInputDidEndNotification, object: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.updateHoverStateFromMousePosition()
        }
    }

    func prepareForInlineTextEditing() {
        guard NSApp.modalWindow == nil else { return }
        guard currentSidebarPanelLayout() != nil else { return }
        debugWorkspaceSidebarRenameLog("prepareForInlineTextEditing before visible=\(isVisible) isKey=\(isKeyWindow) ignoresMouse=\(ignoresMouseEvents) firstResponder=\(String(describing: firstResponder))")
        cancelExpansionWork()
        expandSidebar(to: CGFloat(config.workspaceSidebar.width))
        ignoresMouseEvents = false
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeKey()
        NSApp.activate(ignoringOtherApps: true)
        debugWorkspaceSidebarRenameLog("prepareForInlineTextEditing after visible=\(isVisible) isKey=\(isKeyWindow) ignoresMouse=\(ignoresMouseEvents) firstResponder=\(String(describing: firstResponder)) activeApp=\(NSApp.isActive)")
    }

    func cancelInlineTextEditing() {
        guard inlineTextEditingActive else { return }
        debugWorkspaceSidebarRenameLog("cancelInlineTextEditing isKey=\(isKeyWindow) firstResponder=\(String(describing: firstResponder))")
        let cancel = inlineTextEditingCancel
        endInlineTextEditing()
        cancel?()
    }

    func handleInlineTextEditingKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        guard inlineTextEditingActive, let inlineTextEditingKeyDown else { return false }
        debugWorkspaceSidebarRenameLog("handleInlineTextEditingKey key=\(key)")
        inlineTextEditingKeyDown(key)
        if case .ignored = key {
            return false
        }
        return true
    }

    func shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: Bool) -> Bool {
        let inside = isMouseInsideVisibleRegion()
        if inside { inlineTextEditingPointerEnteredVisibleRegion = true }
        return shouldCancelWorkspaceSidebarInputForPointer(
            isInside: inside,
            isMouseDown: isMouseDown,
            cancelsOnPointerExit: inlineTextEditingCancelsOnPointerExit,
            pointerHasEntered: inlineTextEditingPointerEnteredVisibleRegion,
        )
    }

    func installInlineTextEditingEventMonitors() {
        removeInlineTextEditingEventMonitors()
        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let localMouseDown = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            guard let self else { return event }
            if !self.isEventInsideVisibleRegion(event),
               self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: true)
            {
                Task { @MainActor in self.cancelInlineTextEditing() }
            }
            return event
        }
        let localMouseMove = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            guard let self else { return event }
            if self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: false) {
                Task { @MainActor in self.cancelInlineTextEditing() }
            }
            return event
        }
        let globalMouseDown = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if !self.isScreenPointInsideVisibleRegion(event.locationInWindow),
                   self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: true)
                {
                    self.cancelInlineTextEditing()
                }
            }
        }
        let globalMouseMove = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: false) {
                    self.cancelInlineTextEditing()
                }
            }
        }
        inlineTextEditingEventMonitors = [localMouseDown, localMouseMove, globalMouseDown, globalMouseMove].compactMap { $0 }
        inlineTextEditingActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.cancelInlineTextEditing() }
        }
    }

    func removeInlineTextEditingEventMonitors() {
        for monitor in inlineTextEditingEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        inlineTextEditingEventMonitors = []
        if let observer = inlineTextEditingActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            inlineTextEditingActivationObserver = nil
        }
    }

    func installInlineTextEditingKeyEventTap() {
        removeInlineTextEditingKeyEventTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: workspaceSidebarInlineTextEventTapCallback,
            userInfo: nil
        ) else {
            debugWorkspaceSidebarRenameLog("installKeyEventTap failed")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            debugWorkspaceSidebarRenameLog("installKeyEventTap source failed")
            return
        }
        inlineTextEditingKeyEventTap = tap
        inlineTextEditingKeyEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugWorkspaceSidebarRenameLog("installKeyEventTap ok")
    }

    func removeInlineTextEditingKeyEventTap() {
        if let source = inlineTextEditingKeyEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = inlineTextEditingKeyEventTap {
            CFMachPortInvalidate(tap)
        }
        inlineTextEditingKeyEventTap = nil
        inlineTextEditingKeyEventTapRunLoopSource = nil
    }

    func isEventInsideVisibleRegion(_ event: NSEvent) -> Bool {
        guard event.window === self else { return false }
        let point = convertPoint(toScreen: event.locationInWindow)
        return isScreenPointInsideVisibleRegion(point)
    }

    func isScreenPointInsideVisibleRegion(_ point: CGPoint) -> Bool {
        guard isVisible, sidebarAcceptsPointer else { return false }
        return visibleSurfaceFrameOnScreen.contains(point) || isScreenPointInsideDockIcon(point)
    }
}
struct WorkspaceSidebarPanelLayout {
    let frame: NSRect
    let expandedWidth: CGFloat
    let collapsedWidth: CGFloat
}

func workspaceSidebarPanelLayout(screenFrame: CGRect, sidebarConfig: WorkspaceSidebarConfig) -> WorkspaceSidebarPanelLayout? {
    let expandedWidth = CGFloat(sidebarConfig.width)
    let collapsedWidth = workspaceSidebarRestingWidth(sidebarConfig)
    guard expandedWidth > 0, collapsedWidth >= 0 else { return nil }
    let menuBarReserveHeight = min(CGFloat(sidebarConfig.menuBarReserveHeight), max(screenFrame.height - 1, 0))
    let position = sidebarConfig.effectiveDockPosition
    let panelWidth = position == .bottom ? screenFrame.width : min(expandedWidth * 2, screenFrame.width)
    return WorkspaceSidebarPanelLayout(
        frame: NSRect(
            x: position == .right ? screenFrame.maxX - panelWidth : screenFrame.minX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height - menuBarReserveHeight
        ),
        expandedWidth: expandedWidth,
        collapsedWidth: collapsedWidth
    )
}

extension WorkspaceSidebarPanel {
    func currentSidebarPanelLayout() -> WorkspaceSidebarPanelLayout? {
        guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else { return nil }
        return currentSidebarPanelLayout(on: monitor)
    }

    func currentSidebarPanelLayout(on monitor: Monitor) -> WorkspaceSidebarPanelLayout? {
        guard TrayMenuModel.shared.isEnabled,
              config.workspaceSidebar.enabled,
              let screen = workspaceSidebarPanelScreen(for: monitor)
        else { return nil }
        guard !sidebarIsSuppressed(on: monitor) else { return nil }

        return workspaceSidebarPanelLayout(screenFrame: screen.frame, sidebarConfig: config.workspaceSidebar)
    }

    func sidebarIsSuppressed(on monitor: Monitor) -> Bool {
        shouldSuppressChromeForFullscreenContent(on: monitor) ||
            (config.workspaceSidebar.showAppIcons && SystemDockCoordinator.shared.hidesDock(on: monitor))
    }

    func workspaceSidebarPanelScreen() -> NSScreen? {
        guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else { return nil }
        return workspaceSidebarPanelScreen(for: monitor)
    }

    func workspaceSidebarPanelScreen(for monitor: Monitor) -> NSScreen? {
        NSScreen.screens.getOrNil(
            atIndex: monitor.monitorAppKitNsScreenScreensId - 1
        ) ?? NSScreen.screens.first
    }
}
extension WorkspaceSidebarPanel {
    func setHovering(_ isHovering: Bool) {
        guard currentSidebarPanelLayout() != nil else { return }
        guard menuTrackingDepth == 0, NSApp.modalWindow == nil else { return }
        let expandedWidth = CGFloat(config.workspaceSidebar.width)
        let collapsedWidth = workspaceSidebarRestingWidth(config.workspaceSidebar)
        if viewModel.workspaceSidebarVisibleWidth > collapsedWidth + 0.5 || pendingCollapse != nil {
            debugWorkspaceSidebarHoverLog("setHovering panel=\(monitorScopeId) isHovering=\(isHovering) visible=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
        }
        if isHovering {
            handleHoverEnter(
                expandedWidth: max(expandedWidth, viewModel.workspaceSidebarVisibleWidth),
                collapsedWidth: collapsedWidth
            )
        } else {
            handleHoverExit(collapsedWidth: collapsedWidth)
        }
    }

    func shouldLockExpansionForSidebarDrag() -> Bool {
        shouldLockWorkspaceSidebarExpansion(
            hasDropPreview: TrayMenuModel.shared.workspaceSidebarDropPreview != nil,
            hasPinnedDraggedWindow: hasPinnedDraggedWindow(),
            isSidebarDragInProgress: getCurrentMouseManipulationKind() == .move && getCurrentMouseDragStartedInSidebar(),
            hasActiveEditor: isMenuTrackingOrInGracePeriod() || shouldKeepSidebarOpenForInlineTextEditing(),
        ) || isMouseWindowDragInProgress()
    }

    func shouldKeepSidebarOpenForInlineTextEditing() -> Bool {
        commandExpansionLocksCollapse || (inlineTextEditingActive && inlineTextEditingLocksExpansion)
    }
}
extension WorkspaceSidebarPanel {
    func showHoverCue(cueWidth: CGFloat, expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth < cueWidth || autoHideReason != nil {
            animateVisibleSidebarWidth(
                cueWidth,
                animation: .spring(response: hoverCueAnimationResponse, dampingFraction: 0.72),
            )
        } else {
            updateMousePassthrough()
        }

        guard isMouseDeepEnoughToExpand() else {
            pendingExpand?.cancel()
            pendingExpand = nil
            return
        }
        scheduleHoverExpansion(expandedWidth: expandedWidth, collapsedWidth: collapsedWidth)
    }

    func scheduleHoverExpansion(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        guard !config.workspaceSidebar.usesDockMagnification else {
            pendingExpand?.cancel()
            pendingExpand = nil
            return
        }
        guard pendingExpand == nil else { return }
        let expand = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingExpand = nil
            guard !config.workspaceSidebar.usesDockMagnification,
                  self.isMouseInsideHoverRegion(),
                  self.isMouseDeepEnoughToExpand()
            else { return }
            self.expandSidebar(to: expandedWidth, reason: .hover)
        }
        pendingExpand = expand
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: expand)
    }
}
extension WorkspaceSidebarPanel {
    func handleHoverEnter(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        let cueWidth = workspaceSidebarHoverCueWidth(collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let isExpansionLocked = shouldLockExpansionForSidebarDrag()
        let isExternalWindowDrag = isMouseWindowDragInProgress()
        let isSidebarOriginatedDrag = getCurrentMouseDragStartedInSidebar()
        let shouldSuppressDragExpansion = shouldSuppressWorkspaceSidebarHoverExpansionForDrag(
            isSidebarItemDragActive: isWorkspaceSidebarItemDragActive(),
            isSidebarOriginatedDrag: isSidebarOriginatedDrag,
        )
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
        if shouldSuppressDragExpansion {
            pendingExpand?.cancel()
            pendingExpand = nil
            updateMousePassthrough()
            return
        }

        if config.workspaceSidebar.usesDockMagnification, !viewModel.isWorkspaceSidebarExpanded,
           !shouldKeepSidebarOpenForInlineTextEditing() {
            showCollapsedSidebarDuringExternalDrag(collapsedWidth: workspaceSidebarHoverActivationWidth(config.workspaceSidebar))
            return
        }

        if isExternalWindowDrag && !isSidebarOriginatedDrag && isMousePushedAgainstDisplayEdge() {
            showCollapsedSidebarDuringExternalDrag(
                collapsedWidth: workspaceSidebarHoverActivationWidth(config.workspaceSidebar)
            )
            return
        }
        if !shouldDelayWorkspaceSidebarExpansion(
            isExpanded: viewModel.isWorkspaceSidebarExpanded,
            isExpansionLocked: isExpansionLocked,
            isMouseWindowDragInProgress: isExternalWindowDrag,
        ) {
            expandSidebar(to: expandedWidth)
            return
        }
        showHoverCue(cueWidth: cueWidth, expandedWidth: expandedWidth, collapsedWidth: collapsedWidth)
    }

    func showCollapsedSidebarDuringExternalDrag(collapsedWidth: CGFloat) {
        pendingExpand?.cancel()
        pendingExpand = nil
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth != collapsedWidth || autoHideReason != nil {
            animateVisibleSidebarWidth(collapsedWidth, animation: .easeInOut(duration: animationDuration))
        } else {
            updateMousePassthrough()
        }
    }
}
extension WorkspaceSidebarPanel {
    func handleHoverExit(collapsedWidth: CGFloat) {
        debugWorkspaceSidebarHoverLog("handleHoverExit panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) expanded=\(viewModel.isWorkspaceSidebarExpanded) suppressActive=\(Date() < splitBrowseCollapseSuppressedUntil) mouse=\(NSEvent.mouseLocation)")
        pendingExpand?.cancel()
        pendingExpand = nil
        guard !config.workspaceSidebar.alwaysExpanded else {
            cancelExpansionWork()
            expandSidebar(to: CGFloat(config.workspaceSidebar.width))
            return
        }
        guard autoHideReason == nil else { return }
        guard Date() >= splitBrowseCollapseSuppressedUntil else {
            debugWorkspaceSidebarHoverLog("handleHoverExit suppressed panel=\(monitorScopeId)")
            return
        }
        guard !shouldLockExpansionForSidebarDrag() else {
            debugWorkspaceSidebarHoverLog("handleHoverExit locked panel=\(monitorScopeId)")
            return
        }
        let needsCollapse =
            viewModel.isWorkspaceSidebarExpanded ||
            viewModel.workspaceSidebarVisibleWidth != collapsedWidth
        guard needsCollapse, pendingCollapse == nil else {
            debugWorkspaceSidebarHoverLog("handleHoverExit noop panel=\(monitorScopeId) needsCollapse=\(needsCollapse) pendingCollapse=\(pendingCollapse != nil)")
            return
        }
        scheduleCollapse(collapsedWidth: collapsedWidth)
    }

    func scheduleCollapse(collapsedWidth: CGFloat) {
        guard !config.workspaceSidebar.alwaysExpanded else { return }
        debugWorkspaceSidebarHoverLog("scheduleCollapse panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) mouse=\(NSEvent.mouseLocation)")
        NotificationCenter.default.post(name: workspaceSidebarWillCollapseNotification, object: self)
        let collapse = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapse = nil
            guard !config.workspaceSidebar.alwaysExpanded else { return }
            debugWorkspaceSidebarHoverLog("collapseFire panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.splitBrowseCollapseSuppressedUntil)")
            guard Date() >= self.splitBrowseCollapseSuppressedUntil else {
                debugWorkspaceSidebarHoverLog("collapseFire suppressed panel=\(self.monitorScopeId)")
                return
            }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFire cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            self.animateVisibleSidebarWidth(collapsedWidth, animation: .easeInOut(duration: self.animationDuration))
            // Auto-hide owns its completion; do not mutate the outgoing layout early.
            if collapsedWidth > 0 { self.scheduleCollapseFinalize() }
        }
        pendingCollapse = collapse
        let collapseDelay: TimeInterval = viewModel.isWorkspaceSidebarExpanded ? 0.08 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: collapse)
    }

    func scheduleCollapseFinalize() {
        let finalize = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapseFinalize = nil
            guard !config.workspaceSidebar.alwaysExpanded else { return }
            debugWorkspaceSidebarHoverLog("collapseFinalize panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.splitBrowseCollapseSuppressedUntil)")
            guard Date() >= self.splitBrowseCollapseSuppressedUntil else { return }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFinalize cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            viewModel.isWorkspaceSidebarExpanded = false
            self.updateMousePassthrough()
        }
        pendingCollapseFinalize = finalize
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration, execute: finalize)
    }
}
extension WorkspaceSidebarPanel {
    func installMenuTrackingObservers() {
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginMenuTrackingIfNeeded() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endMenuTrackingIfNeeded() }
            },
        ]
    }

    func beginMenuTrackingIfNeeded() {
        guard isVisible,
              viewModel.workspaceSidebarVisibleWidth > 0,
              isMouseInsideVisibleRegion()
        else { return }
        menuTrackingDepth += 1
        menuTrackingGraceUntil = .distantFuture
        // Keep the compact Menu mounted while AppKit tracks its popup.
        cancelExpansionWork()
    }

    func endMenuTrackingIfNeeded() {
        guard menuTrackingDepth > 0 else { return }
        menuTrackingDepth -= 1
        guard menuTrackingDepth == 0 else { return }
        menuTrackingGraceUntil = Date().addingTimeInterval(menuTrackingEndGrace)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.updateHoverStateFromMousePosition()
        }
        // The 0.08s recheck lands inside the grace period, whose expansion lock swallows a
        // hover exit. With a stationary cursor no pointer event re-evaluates after the grace
        // expires, so schedule one recheck just past it.
        DispatchQueue.main.asyncAfter(deadline: .now() + menuTrackingEndGrace + 0.05) { [weak self] in
            self?.updateHoverStateFromMousePosition()
        }
    }

    func isMenuTrackingOrInGracePeriod(now: Date = .now) -> Bool {
        menuTrackingDepth > 0 || now < menuTrackingGraceUntil
    }
}
extension WorkspaceSidebarPanel {
    /// Hover state is a pure function of the mouse position and the panel geometry, so it is
    /// driven by the global/local pointer-event monitors (mouse position changes) plus explicit
    /// rechecks at the points where the panel itself appears or resizes (geometry changes).
    /// This used to be a permanent CVDisplayLink subscription polling at 30Hz, which kept the
    /// display link running and woke the main actor every vsync even when the machine was idle.
    static func noteHoverPointerActivityForVisiblePanels(timestamp: TimeInterval, screenPoint: CGPoint = NSEvent.mouseLocation) {
        SystemDockCoordinator.shared.notePointerActivity(screenPoint)
        for panel in visiblePanels {
            // Magnification receives every native packet, even while click-through is
            // enabled or SwiftUI's tracking area is being rebuilt. Only expansion is 30 Hz.
            panel.dockPointerView?.receiveNativePointer(screenPoint, eventTimestamp: timestamp)
            panel.noteHoverPointerActivity(timestamp: timestamp)
        }
    }

    /// For lock-release points that arrive without pointer movement (drag ends on mouse-up
    /// with a stationary cursor): the expansion locks cleared, so hover must be re-evaluated
    /// even though no pointer event will fire.
    static func scheduleHoverRecheckForVisiblePanels() {
        for panel in visiblePanels {
            panel.scheduleHoverRecheckSoon()
        }
    }

    /// Rate-limited to `hoverPollInterval`, with a trailing recheck so the final position of an
    /// event burst is always evaluated (a leading-edge-only throttle could drop the last event
    /// and leave hover state stale until the next mouse move).
    private func noteHoverPointerActivity(timestamp: TimeInterval) {
        if timestamp - lastHoverMonitorTimestamp >= hoverPollInterval {
            lastHoverMonitorTimestamp = timestamp
            updateHoverStateFromMousePosition()
        } else if !hasPendingHoverRecheck {
            hasPendingHoverRecheck = true
            let delay = max(hoverPollInterval - (timestamp - lastHoverMonitorTimestamp), 0.001)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.hasPendingHoverRecheck = false
                self.lastHoverMonitorTimestamp = ProcessInfo.processInfo.systemUptime
                self.updateHoverStateFromMousePosition()
            }
        }
    }

    /// Deferred (not inline) so hover reevaluation can be requested from inside
    /// expansion/collapse/refresh paths without re-entering them synchronously.
    func scheduleHoverRecheckSoon() {
        guard !hasPendingHoverRecheck else { return }
        hasPendingHoverRecheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingHoverRecheck = false
            self.updateHoverStateFromMousePosition()
        }
    }

    func updateHoverStateFromMousePosition() {
        guard isVisible else { return }
        DockPerformanceRecorder.shared.hoverRecheck(in: self)
        updateMousePassthrough()
        setHovering(isMouseInsideHoverRegion())
    }
}
extension WorkspaceSidebarPanel {
    func updateMousePassthrough() {
        let inside = isMouseInsideVisibleRegion()
        let shouldIgnoreMouseEvents = !inside
        if ignoresMouseEvents != shouldIgnoreMouseEvents {
            debugWorkspaceSidebarHoverLog("mousePassthrough panel=\(monitorScopeId) ignores \(ignoresMouseEvents)->\(shouldIgnoreMouseEvents) insideVisible=\(inside) visibleWidth=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
            ignoresMouseEvents = shouldIgnoreMouseEvents
            dockPointerView?.recordInputState(.passthrough)
        }
        // Geometry and menu changes also need to recover a stationary pointer.
        // Use the same acceptance test as native movement, never a separate exit stream.
        dockPointerView?.recheckPointer()
    }

    func isMouseInsideHoverRegion() -> Bool {
        isScreenPointInsideHoverRegion(NSEvent.mouseLocation)
    }

    func isScreenPointInsideHoverRegion(_ point: CGPoint) -> Bool {
        guard isVisible else { return false }
        var surface = visibleSurfaceFrameOnScreen
        if autoHideReason == .pointerExit {
            // Retain the long axis for edge re-entry, but never let an outgoing
            // expanded/search view leave a wide invisible hover target behind.
            let gap = CGFloat(config.workspaceSidebar.effectiveLeftGap)
            switch config.workspaceSidebar.effectiveDockPosition {
                case .left, .right:
                    // Cold launch has no SwiftUI preference yet. Keep edge reveal
                    // available until the first real compact extent arrives.
                    if surface.height <= 0 {
                        surface.origin.y = frame.minY
                        surface.size.height = frame.height
                    }
                    surface.origin.x = config.workspaceSidebar.effectiveDockPosition == .left
                        ? frame.minX + gap : frame.maxX - gap
                    surface.size.width = 0
                case .bottom:
                    if surface.width <= 0 {
                        surface.origin.x = frame.minX
                        surface.size.width = frame.width
                    }
                    surface.origin.y = frame.minY + gap
                    surface.size.height = 0
            }
        }
        let hoverRegion = workspaceSidebarHoverRegion(surface: surface, displayFrame: frame, sidebarConfig: config.workspaceSidebar,
            exitTolerance: hoverExitTolerance, fittedDockWidth: fittedDockRestingWidth)
        let inside = hoverRegion.contains(point) || (autoHideReason == nil && isScreenPointInsideDockIcon(point))
        if viewModel.workspaceSidebarVisibleWidth > workspaceSidebarRestingWidth(config.workspaceSidebar) + 0.5 || pendingCollapse != nil {
            debugWorkspaceSidebarHoverLog("hoverRegion panel=\(monitorScopeId) inside=\(inside) hoverWidth=\(hoverRegion.width) visibleWidth=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation) suppressUntil=\(splitBrowseCollapseSuppressedUntil)")
        }
        return inside
    }

    func isMouseInsideVisibleRegion() -> Bool {
        isScreenPointInsideVisibleRegion(NSEvent.mouseLocation)
    }

    func isMouseDeepEnoughToExpand() -> Bool {
        guard isVisible else { return false }
        return workspaceSidebarHoverDepth(
            point: NSEvent.mouseLocation, displayFrame: frame, sidebarConfig: config.workspaceSidebar,
            thickness: config.workspaceSidebar.showAppIcons && !config.workspaceSidebar.alwaysExpanded
                ? fittedDockRestingWidth ?? workspaceSidebarHoverActivationWidth(config.workspaceSidebar)
                : workspaceSidebarHoverActivationWidth(config.workspaceSidebar),
        )
    }
}
extension WorkspaceSidebarPanel {
    func refresh() {
        guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else {
            resetHiddenSidebarState()
            return
        }
        refresh(on: monitor)
    }

    func refresh(on monitor: Monitor, mouseLocation: CGPoint = NSEvent.mouseLocation) {
        applyWorkspaceSidebarLayer(stayOnTop: config.workspaceSidebar.stayOnTop)
        guard let layout = currentSidebarPanelLayout(on: monitor) else {
            if config.workspaceSidebar.enabled, TrayMenuModel.shared.isEnabled,
               workspaceSidebarPanelScreen(for: monitor) != nil, sidebarIsSuppressed(on: monitor) {
                hideSidebar(.systemChrome)
            } else {
                resetHiddenSidebarState()
            }
            return
        }

        if frame != layout.frame {
            if slideTransition.isAnimating {
                let reason = autoHideReason
                slideTransition.reset()
                autoHideReason = nil
                if let reason { hideSidebar(reason, animated: false) }
            }
            setFrame(layout.frame, display: true, animate: false)
        }
        let previousExpandedWidth = lastConfiguredExpandedWidth
        lastConfiguredExpandedWidth = layout.expandedWidth
        if config.workspaceSidebar.alwaysExpanded {
            cancelExpansionWork()
            let targetWidth = workspaceSidebarPersistentVisibleWidth(
                currentWidth: viewModel.workspaceSidebarVisibleWidth,
                previousExpandedWidth: previousExpandedWidth,
                expandedWidth: layout.expandedWidth,
            )
            persistentExpansionWidth = layout.expandedWidth
            viewModel.isWorkspaceSidebarExpanded = true
            if viewModel.workspaceSidebarVisibleWidth != targetWidth {
                viewModel.workspaceSidebarVisibleWidth = targetWidth
            }
        } else if persistentExpansionWidth != nil {
            cancelExpansionWork()
            persistentExpansionWidth = nil
            viewModel.isWorkspaceSidebarExpanded = false
            if layout.collapsedWidth == 0 {
                if isScreenPointInsideHoverRegion(mouseLocation) {
                    viewModel.workspaceSidebarVisibleWidth = workspaceSidebarHoverActivationWidth(config.workspaceSidebar)
                } else { hideSidebar(.pointerExit) }
            } else { viewModel.workspaceSidebarVisibleWidth = layout.collapsedWidth }
        } else if viewModel.workspaceSidebarVisibleWidth == 0 {
            viewModel.workspaceSidebarVisibleWidth = viewModel.isWorkspaceSidebarExpanded
                ? layout.expandedWidth
                : layout.collapsedWidth
        } else if viewModel.isWorkspaceSidebarExpanded,
                  previousExpandedWidth != layout.expandedWidth {
            // Only a configuration change resizes an open sidebar. Routine refreshes
            // must retain the extra width requested by two-project browsing.
            viewModel.workspaceSidebarVisibleWidth = workspaceSidebarPersistentVisibleWidth(
                currentWidth: viewModel.workspaceSidebarVisibleWidth,
                previousExpandedWidth: previousExpandedWidth,
                expandedWidth: layout.expandedWidth,
            )
        } else if !viewModel.isWorkspaceSidebarExpanded,
                  pendingExpand == nil,
                  pendingCollapse == nil,
                  autoHideReason != .pointerExit,
                  !(config.workspaceSidebar.autoHide && isScreenPointInsideHoverRegion(mouseLocation)),
                  viewModel.workspaceSidebarVisibleWidth != layout.collapsedWidth
        {
            // A config reload must use the same slide as a pointer-driven hide.
            if layout.collapsedWidth == 0 { hideSidebar(.pointerExit) }
            else { viewModel.workspaceSidebarVisibleWidth = layout.collapsedWidth }
        }
        if viewModel.workspaceSidebarVisibleWidth == 0 {
            autoHideReason = .pointerExit
            slideTransition.reset(hidden: true, offset: slideOffset)
        } else if autoHideReason == .systemChrome ||
                    (autoHideReason == .pointerExit && (!config.workspaceSidebar.autoHide || config.workspaceSidebar.alwaysExpanded)) {
            revealSidebar(width: viewModel.workspaceSidebarVisibleWidth)
        }
        updateMousePassthrough()
        orderFrontRegardless()
        // Panel geometry may have just changed under a stationary cursor; hover is otherwise
        // event-driven from the pointer monitors.
        scheduleHoverRecheckSoon()
    }

    func refreshForCurrentDragIfNeeded() {
        guard isMouseWindowDragInProgress() else { return }
        WorkspaceSidebarPanel.refreshAll()
    }

    func resetHiddenSidebarState() {
        dockPointerView?.reset(reason: .hidden)
        cancelInlineTextEditing()
        // onCancel may have synchronously attempted a close/reveal animation.
        autoHideReason = nil
        slideTransition.reset()
        clearWorkspaceSidebarCommandInputState(self)
        cancelExpansionWork()
        ignoresMouseEvents = true
        clearHiddenSidebarContent()
        if isVisible { orderOut(nil) }
    }

    func clearHiddenSidebarContent(preserveSurface: Bool = false) {
        // Runs for every inactive panel on every refreshAll — guard the shared-model writes so
        // they don't invalidate every observer each session.
        localDropTargetFrames = []
        if !preserveSurface { visibleSurfaceFrame = nil }
        dockIconFrames = []
        if let preview = TrayMenuModel.shared.workspaceSidebarDropPreview,
           preview.targetMonitorScopeId == nil || preview.targetMonitorScopeId == monitorScopeId {
            setWorkspaceSidebarDropPreviewIfChanged(nil)
        }
        if !WorkspaceSidebarPanel.visiblePanels.contains(where: { $0 !== self && $0.isMouseInsideVisibleRegion() }) {
            TrayMenuModel.shared.setIfChanged(\.workspaceSidebarHoveredWorkspaceName, nil)
        }
        viewModel.setIfChanged(\.workspaceSidebarVisibleWidth, 0)
    }
}
