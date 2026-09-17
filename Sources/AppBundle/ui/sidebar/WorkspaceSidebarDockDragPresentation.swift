import SwiftUI

/// Visual handoff only; window movement and drag eligibility stay in the existing driver.
struct WorkspaceSidebarDockDragPresentation: Equatable {
    let id: UUID
    let windowId: UInt32
    let sourceWorkspaceName: String
    let appId: String
    var destination: WorkspaceSidebarDropPreviewViewModel?

    func hasArrived(in workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> Bool {
        guard let destination else { return false }
        return workspaces.contains { workspace in
            let isDestination = destination.targetsNewWorkspace
                ? workspace.name != sourceWorkspaceName && workspace.projectId == destination.targetProjectId
                : workspace.name == destination.targetWorkspaceName
            guard isDestination else { return false }
            return workspace.items.contains { item in
                switch item.kind {
                    case .window(let window): window.windowId == windowId
                    case .tabGroup(let group): group.tabs.contains { $0.windowId == windowId }
                }
            }
        }
    }

    func hidesIcon(workspaceName: String, appId: String) -> Bool {
        sourceWorkspaceName == workspaceName && self.appId == appId
    }
}

private struct WorkspaceSidebarDockDragKey: EnvironmentKey {
    static let defaultValue: WorkspaceSidebarDockDragPresentation? = nil
}

extension EnvironmentValues {
    var workspaceSidebarDockDrag: WorkspaceSidebarDockDragPresentation? {
        get { self[WorkspaceSidebarDockDragKey.self] }
        set { self[WorkspaceSidebarDockDragKey.self] = newValue }
    }
}

@MainActor
func beginWorkspaceSidebarDockLift(source: Window) {
    guard config.workspaceSidebar.mode == .dock,
          case .appIcon = currentActiveWorkspaceSidebarDrag()?.previewStyle,
          let workspaceName = source.nodeWorkspace?.name else { return }
    if TrayMenuModel.shared.workspaceSidebarDockDrag?.windowId == source.windowId { return }
    let preview = workspaceSidebarSourcePreview(sourceWindow: source, subject: .window)
    let app = WorkspaceSidebarAppViewModel(name: preview.appName,
        bundleId: preview.appBundleIdentifier, bundlePath: preview.appBundlePath)
    TrayMenuModel.shared.workspaceSidebarDockDrag = .init(id: UUID(), windowId: source.windowId,
        sourceWorkspaceName: workspaceName, appId: app.id)
    WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
}

@MainActor
func settleWorkspaceSidebarDockLift() -> UUID? {
    guard var drag = TrayMenuModel.shared.workspaceSidebarDockDrag,
          let preview = TrayMenuModel.shared.workspaceSidebarDropPreview,
          preview.sourceWindowId == drag.windowId else { return nil }
    drag.destination = preview
    TrayMenuModel.shared.workspaceSidebarDockDrag = drag
    WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
    // A cancelled/failed session must never strand an invisible source icon.
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        finishWorkspaceSidebarDockLift(id: drag.id)
    }
    return drag.id
}

@MainActor
func finishWorkspaceSidebarDockLift(id: UUID) {
    guard TrayMenuModel.shared.workspaceSidebarDockDrag?.id == id else { return }
    TrayMenuModel.shared.workspaceSidebarDockDrag = nil
    WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
}

struct WorkspaceSidebarDockLayoutState: Equatable {
    struct WorkspaceIcons: Equatable {
        let name: String
        let apps: [String]
    }
    let workspaces: [WorkspaceIcons]
    let preview: WorkspaceSidebarDropPreviewViewModel?

    init(_ snapshot: WorkspaceSidebarSnapshot) {
        workspaces = snapshot.workspaces.map { .init(name: $0.name, apps: $0.apps.map(\.id)) }
        preview = snapshot.dropPreview
    }
}

let workspaceSidebarDockSettleAnimation = Animation.spring(response: 0.28, dampingFraction: 0.9)
