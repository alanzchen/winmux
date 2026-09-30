import AppKit

@MainActor
private var workspaceSidebarItemDragActiveCount = 0
@MainActor
private var workspaceSidebarNativeWorkspaceDragActiveCount = 0
@MainActor
private var activeWorkspaceSidebarDrag: ActiveWorkspaceSidebarDrag?
@MainActor
private var workspaceSidebarDragSourceScopeId: String?

struct ActiveWorkspaceSidebarDrag: Equatable {
    let windowId: UInt32
    let subject: WindowDragSubject
    let previewStyle: WorkspaceSidebarDragPreviewStyle
}

/// `sourceWindow` is the window the drag started in. Without one, it's the window the current
/// event went to: a drag's events all go to the panel its mouse-down went to.
@MainActor
func beginWorkspaceSidebarItemDrag(sourceWindow: NSWindow? = nil) {
    workspaceSidebarItemDragActiveCount += 1
    noteWorkspaceSidebarDragSource(sourceWindow)
}

@MainActor
func endWorkspaceSidebarItemDrag() {
    workspaceSidebarItemDragActiveCount = max(workspaceSidebarItemDragActiveCount - 1, 0)
    clearWorkspaceSidebarDragSourceIfIdle()
}

@MainActor
func resetWorkspaceSidebarItemDrag() {
    workspaceSidebarItemDragActiveCount = 0
    clearWorkspaceSidebarDragSourceIfIdle()
}

/// Whether the panel for `scopeId` is the one the current sidebar drag started in. Only that
/// panel holds back hover expansion: another display's panel opens for the drag, as it does for
/// a window dragged from the screen. While no drag's source is known, every panel counts as the
/// source, so a sidebar drag holds back expansion everywhere, as it did before sources were kept.
@MainActor
func isWorkspaceSidebarDragSource(_ scopeId: String) -> Bool {
    workspaceSidebarDragSourceScopeId.map { $0 == scopeId } ?? true
}

@MainActor
func currentWorkspaceSidebarDragSourceScopeId() -> String? {
    workspaceSidebarDragSourceScopeId
}

@MainActor
func setWorkspaceSidebarDragSourceScopeIdForTests(_ scopeId: String?) {
    workspaceSidebarDragSourceScopeId = scopeId
}

/// The first drag to begin names the source; nested begins of the same gesture keep it.
@MainActor
private func noteWorkspaceSidebarDragSource(_ sourceWindow: NSWindow?) {
    guard workspaceSidebarDragSourceScopeId == nil else { return }
    let window = sourceWindow ?? (NSApp as NSApplication?)?.currentEvent?.window
    let panel = (window as? WorkspaceSidebarPanel)
        ?? WorkspaceSidebarPanel.panel(containing: MousePointerTracker.shared.currentSample.point)
    workspaceSidebarDragSourceScopeId = panel?.monitorScopeId
}

@MainActor
private func clearWorkspaceSidebarDragSourceIfIdle() {
    guard workspaceSidebarItemDragActiveCount == 0, workspaceSidebarNativeWorkspaceDragActiveCount == 0,
          workspaceSidebarDragSourceScopeId != nil else { return }
    workspaceSidebarDragSourceScopeId = nil
    // Another display's panel may have opened for the drag. The drag no longer holds it open,
    // and a pointer at rest sends no event to let it close.
    WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
}

@MainActor
func isWorkspaceSidebarItemDragActive() -> Bool {
    workspaceSidebarItemDragActiveCount > 0 || workspaceSidebarNativeWorkspaceDragActiveCount > 0
}

@MainActor
func isWorkspaceSidebarNativeWorkspaceDragActive() -> Bool {
    workspaceSidebarNativeWorkspaceDragActiveCount > 0
}

@MainActor
private var workspaceSidebarDraggedProject: WorkspaceProjectId?

/// The project whose column header is being dragged to reorder projects.
@MainActor
func workspaceSidebarDraggedProjectId() -> WorkspaceProjectId? {
    workspaceSidebarDraggedProject
}

@MainActor
func setWorkspaceSidebarDraggedProjectId(_ projectId: WorkspaceProjectId?) {
    workspaceSidebarDraggedProject = projectId
}

// Native drag sessions release their own claim in the source's end callback.
// The global mouse-up cleanup for window drags must not clear it first.
@MainActor
func beginWorkspaceSidebarNativeWorkspaceDrag() {
    workspaceSidebarNativeWorkspaceDragActiveCount += 1
    WorkspaceSidebarNativeDragState.shared.isActive = true
    noteWorkspaceSidebarDragSource(nil)
}

@MainActor
func endWorkspaceSidebarNativeWorkspaceDrag() {
    workspaceSidebarNativeWorkspaceDragActiveCount = max(workspaceSidebarNativeWorkspaceDragActiveCount - 1, 0)
    WorkspaceSidebarNativeDragState.shared.isActive = workspaceSidebarNativeWorkspaceDragActiveCount > 0
    clearWorkspaceSidebarDragSourceIfIdle()
}

/// A click can only reach the drop overlay when no drag session is running. Clear any claim
/// that outlived its session so the overlay stops covering the rows.
@MainActor
func recoverStaleWorkspaceSidebarNativeWorkspaceDrag() {
    workspaceSidebarNativeWorkspaceDragActiveCount = 0
    workspaceSidebarDraggedProject = nil
    WorkspaceSidebarNativeDragState.shared.isActive = false
    clearWorkspaceSidebarDragSourceIfIdle()
    WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
}

/// Publishes whether a workspace or project header is being dragged, so project drop targets
/// can cover the workspace rows whose own drop targets accept only windows.
@MainActor
final class WorkspaceSidebarNativeDragState: ObservableObject {
    static let shared = WorkspaceSidebarNativeDragState()
    @Published fileprivate(set) var isActive = false
}

@MainActor
func beginActiveWorkspaceSidebarDrag(windowId: UInt32, subject: WindowDragSubject, previewStyle: WorkspaceSidebarDragPreviewStyle = .row) {
    // Refreshes and destination changes must not replace the gesture's original appearance.
    if let activeWorkspaceSidebarDrag,
       activeWorkspaceSidebarDrag.windowId == windowId,
       activeWorkspaceSidebarDrag.subject == subject { return }
    WorkspaceSidebarTabSplitHoverController.shared.reset()
    if let previous = TrayMenuModel.shared.workspaceSidebarDockDrag {
        finishWorkspaceSidebarDockLift(id: previous.id)
    }
    activeWorkspaceSidebarDrag = ActiveWorkspaceSidebarDrag(windowId: windowId, subject: subject, previewStyle: previewStyle)
    WorkspaceSidebarTabDragState.shared.set(config.usesBrowserTabs)
}

@MainActor
func currentActiveWorkspaceSidebarDrag() -> ActiveWorkspaceSidebarDrag? {
    activeWorkspaceSidebarDrag
}

@MainActor
func clearActiveWorkspaceSidebarDrag() {
    WorkspaceSidebarTabSplitHoverController.shared.reset()
    activeWorkspaceSidebarDrag = nil
    WorkspaceSidebarTabDragState.shared.set(false)
    // Live hover feedback ends with the gesture. A committed visual handoff has
    // its own destination in workspaceSidebarDockDrag and remains until arrival.
    clearWorkspaceSidebarDropPreview()
    if let drag = TrayMenuModel.shared.workspaceSidebarDockDrag, drag.destination == nil {
        finishWorkspaceSidebarDockLift(id: drag.id)
    }
}

func shouldLockWorkspaceSidebarExpansion(
    hasDropPreview: Bool,
    hasPinnedDraggedWindow: Bool,
    isSidebarDragInProgress: Bool,
    hasActiveEditor: Bool,
) -> Bool {
    hasDropPreview || hasPinnedDraggedWindow || isSidebarDragInProgress || hasActiveEditor
}

func isWorkspaceSidebarDragInProgress(kind: MouseManipulationKind, startedInSidebar: Bool) -> Bool {
    kind == .move && startedInSidebar
}

@MainActor
func isWorkspaceSidebarDragInProgress() -> Bool {
    isWorkspaceSidebarItemDragActive() || isWorkspaceSidebarDragInProgress(
        kind: getCurrentMouseManipulationKind(),
        startedInSidebar: getCurrentMouseDragStartedInSidebar(),
    )
}

func shouldHandleWorkspaceSidebarActivation(isEditing: Bool, isSidebarDragInProgress: Bool) -> Bool {
    !isEditing && !isSidebarDragInProgress
}

func shouldHandleWorkspaceSidebarActivation(editingWorkspaceName: String?, isSidebarDragInProgress: Bool) -> Bool {
    shouldHandleWorkspaceSidebarActivation(
        isEditing: editingWorkspaceName != nil,
        isSidebarDragInProgress: isSidebarDragInProgress,
    )
}
