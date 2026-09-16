import SwiftUI

/// Keep hit targets aligned with the visible icons, including while they morph into rows.
/// The visual compact header stays noninteractive so it cannot intercept expanded rows.
struct WorkspaceSidebarDockAppButtons: View {
    let anchors: [WorkspaceSidebarMorphElement: Anchor<CGRect>]
    let progress: CGFloat
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let targets: [String: WorkspaceSidebarAppMorphTarget]
    let onSelectApp: (WorkspaceSidebarAppViewModel) -> Void

    var body: some View {
        GeometryReader { geometry in
            ForEach(workspace.apps) { app in
                if let compactAnchor = anchors[.compactApp(app.id)] {
                    let compact = geometry[compactAnchor]
                    let expanded = targets[app.id].flatMap { _ in anchors[.expandedApp(app.id)] }
                    let rect = expanded.map {
                        workspaceSidebarInterpolatedMorphRect(from: compact, to: geometry[$0], progress: progress)
                    } ?? compact
                    Button {
                        onSelectApp(app)
                    } label: {
                        Color.clear
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Focus \(app.name) in workspace \(workspace.displayName)")
                    .help("Focus \(app.name) in workspace \(workspace.displayName)")
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}
