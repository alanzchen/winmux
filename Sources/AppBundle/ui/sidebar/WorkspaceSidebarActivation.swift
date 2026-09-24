import AppKit

@MainActor
private var workspaceSidebarItemDragActiveCount = 0
@MainActor
private var workspaceSidebarNativeWorkspaceDragActiveCount = 0
@MainActor
private var activeWorkspaceSidebarDrag: ActiveWorkspaceSidebarDrag?

struct ActiveWorkspaceSidebarDrag: Equatable {
    let windowId: UInt32
    let subject: WindowDragSubject
    let previewStyle: WorkspaceSidebarDragPreviewStyle
}

@MainActor
func beginWorkspaceSidebarItemDrag() {
    workspaceSidebarItemDragActiveCount += 1
}

@MainActor
func endWorkspaceSidebarItemDrag() {
    workspaceSidebarItemDragActiveCount = max(workspaceSidebarItemDragActiveCount - 1, 0)
}

@MainActor
func resetWorkspaceSidebarItemDrag() {
    workspaceSidebarItemDragActiveCount = 0
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
}

@MainActor
func endWorkspaceSidebarNativeWorkspaceDrag() {
    workspaceSidebarNativeWorkspaceDragActiveCount = max(workspaceSidebarNativeWorkspaceDragActiveCount - 1, 0)
    WorkspaceSidebarNativeDragState.shared.isActive = workspaceSidebarNativeWorkspaceDragActiveCount > 0
}

/// A click can only reach the drop overlay when no drag session is running. Clear any claim
/// that outlived its session so the overlay stops covering the rows.
@MainActor
func recoverStaleWorkspaceSidebarNativeWorkspaceDrag() {
    workspaceSidebarNativeWorkspaceDragActiveCount = 0
    workspaceSidebarDraggedProject = nil
    WorkspaceSidebarNativeDragState.shared.isActive = false
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
    if let previous = TrayMenuModel.shared.workspaceSidebarDockDrag {
        finishWorkspaceSidebarDockLift(id: previous.id)
    }
    activeWorkspaceSidebarDrag = ActiveWorkspaceSidebarDrag(windowId: windowId, subject: subject, previewStyle: previewStyle)
}

@MainActor
func currentActiveWorkspaceSidebarDrag() -> ActiveWorkspaceSidebarDrag? {
    activeWorkspaceSidebarDrag
}

@MainActor
func clearActiveWorkspaceSidebarDrag() {
    activeWorkspaceSidebarDrag = nil
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
