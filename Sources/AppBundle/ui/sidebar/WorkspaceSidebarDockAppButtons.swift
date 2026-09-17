import SwiftUI

/// Keep hit targets aligned with the visible icons, including while they morph into rows.
/// The visual compact header stays noninteractive so it cannot intercept expanded rows.
struct WorkspaceSidebarDockAppButtons: View {
    let anchors: [WorkspaceSidebarMorphElement: Anchor<CGRect>]
    let progress: CGFloat
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let targets: [String: WorkspaceSidebarAppMorphTarget]
    let actions: WorkspaceSidebarActions
    let onSelectApp: (WorkspaceSidebarAppViewModel) -> Void
    var onSelectWorkspace: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            if let title = anchors[.compactTitle] {
                let compact = geometry[title]
                let rect = anchors[.expandedTitle].map {
                    workspaceSidebarInterpolatedMorphRect(from: compact, to: geometry[$0], progress: progress)
                } ?? compact
                Button(action: onSelectWorkspace) {
                    Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch to workspace \(workspace.displayName)")
                .position(x: rect.midX, y: rect.midY)
            }
            ForEach(workspace.apps) { app in
                if let compactAnchor = anchors[.compactApp(app.id)] {
                    let compact = geometry[compactAnchor]
                    let expanded = targets[app.id].flatMap { _ in anchors[.expandedApp(app.id)] }
                    let rect = expanded.map {
                        workspaceSidebarInterpolatedMorphRect(from: compact, to: geometry[$0], progress: progress)
                    } ?? compact
                    WorkspaceSidebarDockAppButton(
                        app: app,
                        workspaceName: workspace.name,
                        workspaceDisplayName: workspace.displayName,
                        size: rect.size,
                        iconSize: compact.width,
                        actions: actions,
                        onSelect: { onSelectApp(app) }
                    )
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct WorkspaceSidebarDockAppButton: View {
    let app: WorkspaceSidebarAppViewModel
    let workspaceName: String
    let workspaceDisplayName: String
    let size: CGSize
    let iconSize: CGFloat
    let actions: WorkspaceSidebarActions
    let onSelect: () -> Void
    @State private var drag = WorkspaceSidebarAppDragSession()

    var body: some View {
        Button(action: onSelect) {
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { point in
                drag.update(workspaceName: workspaceName, appId: app.id, pointer: point, iconSize: iconSize, actions: actions)
            },
            onEnded: { point in drag.finish(pointer: point, actions: actions) }
        ))
        .accessibilityLabel("Focus \(app.name) in workspace \(workspaceDisplayName)")
        .help("Click to focus \(app.name); drag to move its window to another workspace")
    }
}

/// Resolve once per gesture so changes to focus or tree recency cannot switch the dragged window.
struct WorkspaceSidebarAppDragSession {
    private(set) var windowId: UInt32?
    private var hasResolvedWindow = false

    @MainActor
    mutating func update(workspaceName: String, appId: String, pointer: CGPoint, iconSize: CGFloat = WorkspaceSidebarAppIconLayout.iconSize, actions: WorkspaceSidebarActions) {
        if !hasResolvedWindow {
            hasResolvedWindow = true
            windowId = actions.resolveAppDragWindow(workspaceName, appId)
        }
        if let windowId { actions.appIconDragChanged(windowId, pointer, iconSize) }
    }

    @MainActor
    mutating func finish(pointer: CGPoint, actions: WorkspaceSidebarActions) {
        if let windowId { actions.windowDragEnded(windowId, pointer) }
        windowId = nil
        hasResolvedWindow = false
    }
}
