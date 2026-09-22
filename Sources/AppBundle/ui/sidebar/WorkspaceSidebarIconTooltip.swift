import SwiftUI

enum WorkspaceSidebarTooltipKind {
    case workspace, app
}

struct WorkspaceSidebarTooltipVisibility: Equatable {
    var workspace = true
    var app = true

    func shows(_ kind: WorkspaceSidebarTooltipKind) -> Bool {
        switch kind {
            case .workspace: workspace
            case .app: app
        }
    }
}

private struct WorkspaceSidebarTooltipVisibilityKey: EnvironmentKey {
    static let defaultValue = WorkspaceSidebarTooltipVisibility()
}

extension EnvironmentValues {
    var workspaceSidebarTooltipVisibility: WorkspaceSidebarTooltipVisibility {
        get { self[WorkspaceSidebarTooltipVisibilityKey.self] }
        set { self[WorkspaceSidebarTooltipVisibilityKey.self] = newValue }
    }
}

/// Remove native help entirely when disabled; keep the explicit accessibility label.
struct WorkspaceSidebarIconTooltip: ViewModifier {
    let text: String
    let kind: WorkspaceSidebarTooltipKind
    @Environment(\.workspaceSidebarTooltipVisibility) private var visibility

    func body(content: Content) -> some View {
        if visibility.shows(kind) { content.help(text) }
        else { content }
    }
}
