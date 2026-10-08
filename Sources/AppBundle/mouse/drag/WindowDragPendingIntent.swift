import AppKit
import Common

@MainActor
func updatePendingWindowDragIntent(sourceWindow: Window, mouseLocation: CGPoint) -> Bool {
    updatePendingWindowDragIntent(sourceWindow: sourceWindow, mouseLocation: mouseLocation, subject: .window, detachOrigin: .window)
}

@MainActor
func updatePendingWindowDragIntent(
    sourceWindow: Window,
    mouseLocation: CGPoint,
    subject: WindowDragSubject,
    detachOrigin: TabDetachOrigin,
) -> Bool {
    if detachOrigin != .tabStrip, !getCurrentMouseDragStartedInSidebar() {
        WindowDragCursorProxyPanel.shared.hide()
    }

    let surface = workspaceSidebarSurface(at: mouseLocation)?.surface
    if workspaceSidebarOwnsDrag(usesBrowserTabs: config.usesBrowserTabs,
        startedInSidebar: getCurrentMouseDragStartedInSidebar(),
        hasActiveSidebarDrag: currentActiveWorkspaceSidebarDrag() != nil,
        isPointerInSidebar: surface != nil, isPointerOnTemporarySurface: surface?.isTemporary == true,
        carriesBatch: workspaceSidebarDragCarriesBatch())
    {
        // The sidebar already previewed this drag and will drop it where the preview shows;
        // a window-drag destination here would replace its gap line with a whole-row highlight.
        let hadPinnedWindow = hasPinnedDraggedWindow()
        clearPendingWindowDragIntent()
        showWorkspaceSidebarDragCursorPreview(sourceWindow: sourceWindow, subject: subject, point: mouseLocation)
        if hadPinnedWindow {
            scheduleRefreshSession(.globalObserver("sidebarGhostExit"), optimisticallyPreLayoutWorkspaces: true)
        }
        return false
    }

    guard let destination = currentWindowDragIntentDestination(
        sourceWindow: sourceWindow,
        mouseLocation: mouseLocation,
        subject: subject,
        detachOrigin: detachOrigin,
    ) else {
        logWindowDragIntentIfNeeded(
            signature: "drag-live:no-destination:source=\(sourceWindow.windowId):subject=\(debugDescribe(subject)):origin=\(detachOrigin):bucket=\(debugDescribeDragPointBucket(mouseLocation))",
            "[drag-live] destination none source=\(sourceWindow.windowId) subject=\(debugDescribe(subject)) origin=\(detachOrigin) mouse=\(debugDescribe(mouseLocation)) bucket=\(debugDescribeDragPointBucket(mouseLocation)); clearing previews"
        )
        updateSidebarDragFeedback(sourceWindow: sourceWindow, subject: subject, destination: nil)
        clearPendingWindowDragIntent()
        if detachOrigin == .tabStrip || getCurrentMouseDragStartedInSidebar() {
            showWorkspaceSidebarDragCursorPreview(sourceWindow: sourceWindow, subject: subject, point: mouseLocation)
        }
        return false
    }
    updateSidebarDragFeedback(sourceWindow: sourceWindow, subject: subject, destination: destination)
    if detachOrigin == .tabStrip || getCurrentMouseDragStartedInSidebar() {
        showWorkspaceSidebarDragCursorPreview(sourceWindow: sourceWindow, subject: subject, point: mouseLocation)
    }
    return setPendingWindowDragIntent(
        sourceWindowId: sourceWindow.windowId,
        sourceSubject: subject,
        detachOrigin: detachOrigin,
        destination: destination,
    )
}

/// While a drag that started in the sidebar is over a sidebar in Tabs mode, the sidebar alone
/// previews and drops it, with the gaps between tabs and the halves of a tab. Over temporary drop
/// UI it does so in every mode. Elsewhere, the window drag's own destinations apply.
func workspaceSidebarOwnsDrag(usesBrowserTabs: Bool, startedInSidebar: Bool, hasActiveSidebarDrag: Bool,
                              isPointerInSidebar: Bool, isPointerOnTemporarySurface: Bool = false,
                              carriesBatch: Bool = false) -> Bool {
    // Chosen tabs dragged together go only where all of them can, never onto the screen.
    startedInSidebar && hasActiveSidebarDrag
        && (usesBrowserTabs && isPointerInSidebar || isPointerOnTemporarySurface || carriesBatch)
}

/// Whether the sidebar's drag carries chosen tabs together, which the screen takes no drop of.
@MainActor
func workspaceSidebarDragCarriesBatch() -> Bool {
    currentActiveWorkspaceSidebarDrag()?.batch != nil && !workspaceSidebarBatchScreenReleaseMovesDraggedWindow
}

@MainActor
func refreshPendingWindowDragIntentFromGlobalMouseDrag() {
    WorkspaceSidebarPanel.refreshAll()
    guard isLeftMouseButtonDown, getCurrentMouseManipulationKind() == .move else {
        clearPendingWindowDragIntent()
        return
    }
    guard let windowId = currentlyManipulatedWithMouseWindowId,
          Window.get(byId: windowId) != nil
    else {
        clearPendingWindowDragIntent()
        cancelManipulatedWithMouseState()
        return
    }
    WindowMouseInteractionDriver.shared.noteGlobalDragActivity()
}

@MainActor
func setPendingWindowDragIntent(
    sourceWindowId: UInt32,
    sourceSubject: WindowDragSubject,
    detachOrigin: TabDetachOrigin,
    destination: WindowDragIntentDestination,
) -> Bool {
    let isPointerSettled = WindowDragFrameGate.shared.state(for: sourceWindowId)?.isSettled ?? false
    WindowTabStripPanelController.shared.clearHiddenPassiveTabGroupChrome()
    updateWindowTabReentryPreview(sourceWindowId: sourceWindowId, destination: destination)
    if let pendingWindowDragIntent,
       pendingWindowDragIntent.sourceWindowId == sourceWindowId,
       pendingWindowDragIntent.sourceSubject == sourceSubject,
       pendingWindowDragIntent.kind == destination.kind,
       pendingWindowDragIntent.title == destination.title,
       pendingWindowDragIntent.subtitle == destination.subtitle,
       pendingWindowDragIntent.previewStyle == destination.previewStyle,
       pendingWindowDragIntent.previewGeometry == destination.previewGeometry,
       pendingWindowDragIntent.isGroup == destination.isGroup,
       pendingWindowDragIntent.previewRect.isEqual(to: destination.previewRect),
       pendingWindowDragIntent.interactionRect.isEqual(to: destination.interactionRect)
    {
        return true
    }

    let previousIntent = pendingWindowDragIntent
    pendingWindowDragIntent = PendingWindowDragIntent(
        sourceWindowId: sourceWindowId,
        sourceSubject: sourceSubject,
        kind: destination.kind,
        previewRect: destination.previewRect,
        interactionRect: destination.interactionRect,
        title: destination.title,
        subtitle: destination.subtitle,
        previewStyle: destination.previewStyle,
        previewGeometry: destination.previewGeometry,
        isGroup: destination.isGroup,
        isPointerSettled: isPointerSettled,
    )
    let signature =
        "intent:source=\(sourceWindowId):subject=\(debugDescribe(sourceSubject)):kind=\(debugDescribe(destination.kind)):preview=\(debugDescribe(destination.previewRect)):interaction=\(debugDescribe(destination.interactionRect))"
    logWindowDragIntentIfNeeded(
        signature: signature,
        "windowDragIntent.update mouse=\(debugDescribe(mouseLocation)) source=\(debugDescribe(Window.get(byId: sourceWindowId))) subject=\(debugDescribe(sourceSubject)) prevKind=\(previousIntent.map { debugDescribe($0.kind) } ?? "nil") prevPreview=\(debugDescribe(previousIntent?.previewRect)) newKind=\(debugDescribe(destination.kind)) newPreview=\(debugDescribe(destination.previewRect)) newInteraction=\(debugDescribe(destination.interactionRect)) style=\(destination.previewStyle) geometry=\(destination.previewGeometry)"
    )
    if let overlay = destination.dropIntentOverlay {
        let activeZone = overlay.activeZone?.rawValue ?? "nil"
        logWindowDragIntentIfNeeded(
            signature: "drag-live:overlay-show:source=\(sourceWindowId):kind=\(debugDescribe(destination.kind)):bucket=\(debugDescribeDragPointBucket(mouseLocation)):zone=\(activeZone)",
            "[drag-live] overlay show request source=\(sourceWindowId) kind=\(debugDescribe(destination.kind)) zone=\(activeZone) target=\(debugDescribe(overlay.targetFrame)) mouse=\(debugDescribe(mouseLocation)) bucket=\(debugDescribeDragPointBucket(mouseLocation))"
        )
        WindowDropIntentOverlayPanelController.shared.show(overlay)
    } else {
        logWindowDragIntentIfNeeded(
            signature: "drag-live:overlay-hide:source=\(sourceWindowId):kind=\(debugDescribe(destination.kind)):bucket=\(debugDescribeDragPointBucket(mouseLocation))",
            "[drag-live] overlay hide request source=\(sourceWindowId) kind=\(debugDescribe(destination.kind)) reason=destination-has-no-overlay mouse=\(debugDescribe(mouseLocation)) bucket=\(debugDescribeDragPointBucket(mouseLocation))"
        )
        WindowDropIntentOverlayPanelController.shared.hide()
    }
    return true
}

@MainActor
func clearPendingWindowDragIntent() {
    let preservesSidebarDragUI = currentActiveWorkspaceSidebarDrag() != nil
    if let pendingWindowDragIntent {
        logWindowDragIntentIfNeeded(
            signature: "intent-cleared:source=\(pendingWindowDragIntent.sourceWindowId):kind=\(debugDescribe(pendingWindowDragIntent.kind))",
            "windowDragIntent.clear mouse=\(debugDescribe(mouseLocation)) source=\(debugDescribe(Window.get(byId: pendingWindowDragIntent.sourceWindowId))) kind=\(debugDescribe(pendingWindowDragIntent.kind)) preview=\(debugDescribe(pendingWindowDragIntent.previewRect))"
        )
    }
    pendingWindowDragIntent = nil
    WindowTabReentryPreviewModel.shared.set(nil)
    lastWindowDragIntentLogSignature = nil
    setPinnedDraggedWindowId(nil)
    if !preservesSidebarDragUI {
        setWorkspaceSidebarDropPreviewIfChanged(nil)
    }
    WindowDropIntentOverlayPanelController.shared.hide()
    WindowTabStripPanelController.shared.clearHiddenPassiveTabGroupChrome()
    if !preservesSidebarDragUI {
        WindowDragCursorProxyPanel.shared.hide()
    }
    if getCurrentMouseManipulationKind() == .resize, isLeftMouseButtonDown {
        logWindowDragLive("dragIntent.clear preserving resizePreview during active resize manipulated=\(currentlyManipulatedWithMouseWindowId?.description ?? "nil")")
    } else {
        WindowResizePreviewPanel.shared.endStableFrame()
        WindowResizePreviewPanel.shared.hide(reason: "dragIntent.clear")
    }
}

@MainActor
private func updateWindowTabReentryPreview(sourceWindowId: UInt32, destination: WindowDragIntentDestination) {
    guard case .reorderTab(let windowId, let targetIndex) = destination.kind,
          windowId == sourceWindowId,
          let sourceWindow = Window.get(byId: sourceWindowId),
          let parent = sourceWindow.parent as? TilingContainer,
          parent.layout == .tabGroup,
          let sourceIndex = sourceWindow.ownIndex
    else {
        WindowTabReentryPreviewModel.shared.set(nil)
        return
    }
    WindowTabReentryPreviewModel.shared.set(WindowTabPendingReorderDrop(
        stripId: ObjectIdentifier(parent),
        windowId: windowId,
        sourceIndex: sourceIndex,
        targetIndex: max(0, min(targetIndex, parent.children.count - 1)),
        orderBeforeDrop: parent.children.compactMap { ($0 as? Window)?.windowId },
        sourceVisualOffset: parent.windowTabDropZoneRect.map {
            tabReentrySourceVisualOffset(
                mouseLocation: MousePointerTracker.shared.currentSample.point,
                tabStripRect: $0,
                tabCount: parent.children.count,
                sourceIndex: sourceIndex
            )
        }
    ))
}

@MainActor
func applyPendingWindowDragIntentIfPossible() -> Bool {
    defer { clearPendingWindowDragIntent() }
    let currentMouseLocation = MousePointerTracker.shared.currentSample.point
    guard let pendingWindowDragIntent,
          let sourceWindow = Window.get(byId: pendingWindowDragIntent.sourceWindowId),
          pendingWindowDragIntent.interactionRect.contains(currentMouseLocation),
          isWindowDragIntentKindEnabled(pendingWindowDragIntent.kind)
    else { return false }
    let sourceNode = dragSubjectNode(for: sourceWindow, subject: pendingWindowDragIntent.sourceSubject)
    switch pendingWindowDragIntent.kind {
        case .reorderTab(let windowId, let targetIndex):
            guard pendingWindowDragIntent.sourceSubject == .window,
                  sourceWindow.windowId == windowId
            else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId])
            return reorderWindowTabInCurrentGroup(sourceWindow, toIndex: targetIndex)
        case .tabStack(let targetWindowId):
            guard pendingWindowDragIntent.sourceSubject == .window else { return false }
            guard let targetWindow = Window.get(byId: targetWindowId),
                  sourceWindow != targetWindow
            else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId, targetWindow.windowId])
            createOrAppendWindowTabStack(sourceWindow: sourceWindow, onto: targetWindow)
            return true
        case .detachTab(let windowId):
            guard sourceWindow.windowId == windowId else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId])
            return removeWindowFromTabStack(sourceWindow)
        case .stackSplit(let targetWindowId, let position):
            guard let targetWindow = Window.get(byId: targetWindowId)
            else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId, targetWindow.windowId])
            let split = {
                applyWindowStackSplitDragIntent(sourceWindow: sourceWindow, sourceSubject: pendingWindowDragIntent.sourceSubject,
                    targetWindow: targetWindow, position: position)
            }
            // Within its own tab, as before. Into another, as the pins' policy says: beside a pin's one
            // window, both go to an ordinary tab, on that display, and the split is made there.
            guard let targetWorkspace = targetWindow.nodeWorkspace, targetWorkspace !== sourceNode.nodeWorkspace else { return split() }
            return applyWindowDragKeepingPins(sourceNode, onto: targetWorkspace) { _ in
                guard split() else { throw WorkspaceSidebarMoveDidNotHappen() }
            }
        case .swap(let targetWindowId):
            guard let targetWindow = Window.get(byId: targetWindowId),
                  // Never swapped across tabs with a pin, whose window would change.
                  workspaceSidebarPinPolicyAllowsSwap(sourceNode.nodeWorkspace, targetWindow.nodeWorkspace)
            else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId, targetWindow.windowId])
            return applyWindowSwapDragIntent(
                sourceWindow: sourceWindow,
                sourceSubject: pendingWindowDragIntent.sourceSubject,
                targetWindow: targetWindow,
            )
        case .moveToWorkspace(let workspaceName):
            guard let targetWorkspace = Workspace.existing(byName: workspaceName) else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId])
            // A pin with one window keeps it as its own: the window goes to an ordinary tab with it.
            let isSidebarMove = pendingWindowDragIntent.previewStyle == .sidebarWorkspaceMove
            return applyWindowDragKeepingPins(sourceNode, onto: targetWorkspace) { destination in
                if isSidebarMove {
                    applySidebarWorkspaceMove(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: destination)
                } else {
                    applyWorkspaceMove(sourceNode: sourceNode, sourceWindow: sourceWindow, mouseLocation: mouseLocation,
                        targetWorkspace: destination)
                }
                // The split it went to instead comes forward with it.
                if destination !== targetWorkspace { _ = sourceWindow.focusWindow() }
            }
        case .moveToWorkspaceZone(let workspaceName, let zone):
            guard let targetWorkspace = Workspace.existing(byName: workspaceName) else { return false }
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId])
            return applyWindowDragKeepingPins(sourceNode, onto: targetWorkspace) { destination in
                applyWorkspaceZoneMove(sourceNode: sourceNode, sourceWindow: sourceWindow, targetWorkspace: destination, zone: zone)
            }
        case .createWorkspace(let projectId, let monitorScopeId):
            syncClosedWindowsCacheToCurrentWorld()
            suppressPostDragAxObserverEvents(for: [sourceWindow.windowId])
            // A pin whose one window gets the new tab lends it there.
            do {
                return try moveWorkspaceSidebarNodeOutKeepingPins(sourceNode) {
                    createWorkspaceFromSidebarDrag(sourceNode: sourceNode, sourceWindow: sourceWindow, projectId: projectId,
                        monitorScopeId: monitorScopeId)
                }
            } catch {
                showWorkspaceSidebarError(error.localizedDescription)
                return false
            }
        case .sidebarHover:
            return false
    }
}

/// A window drag on screen into another tab, made by `apply`, which is given the tab it goes to, as the
/// pins' policy says. Gives false where the policy refuses, or a change can't be saved.
@MainActor
private func applyWindowDragKeepingPins(_ sourceNode: TreeNode, onto target: Workspace, _ apply: (Workspace) throws -> Void) -> Bool {
    do {
        return try moveWorkspaceSidebarNodeKeepingPins(sourceNode, onto: target, newTabMonitor: target.workspaceMonitor, apply)
    } catch is WorkspaceSidebarMoveDidNotHappen {
        return false
    } catch {
        showWorkspaceSidebarError(error.localizedDescription)
        return false
    }
}
