import AppKit

@MainActor
private var workspaceSidebarItemDragActiveCount = 0
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
    workspaceSidebarItemDragActiveCount > 0
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
