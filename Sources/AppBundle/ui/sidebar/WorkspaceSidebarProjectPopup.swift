import SwiftUI

struct WorkspaceSidebarProjectPopup: View {
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedProjectId: WorkspaceProjectId
    let onSelect: (WorkspaceProjectId) -> Void
    var menuWidth: CGFloat? = nil
    private var contentHeight: CGFloat {
        let rowsHeight = CGFloat(projects.count) * workspaceSidebarDropdownHeight
        let rowSpacing = CGFloat(max(projects.count - 1, 0)) * workspaceSidebarMenuRowSpacing
        let verticalPadding = (workspaceSidebarMenuRowSpacing + 1) * 2
        return rowsHeight + rowSpacing + CGFloat(verticalPadding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: workspaceSidebarMenuRowSpacing) {
            ForEach(projects) { project in
                projectRow(project)
            }
        }
        .padding(workspaceSidebarMenuRowSpacing + 1)
        .frame(minWidth: menuWidth, idealWidth: menuWidth, maxWidth: menuWidth, alignment: .leading)
        .frame(height: contentHeight, alignment: .top)
        .fixedSize(horizontal: menuWidth != nil, vertical: false)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .compositingGroup()
        }
        .shadow(color: .black.opacity(0.50), radius: 18, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func projectRow(_ project: WorkspaceSidebarProjectViewModel) -> some View {
        Button {
            onSelect(project.id)
        } label: {
            HStack(spacing: 8) {
                Text(project.displayName)
                    .font(.system(size: 12, weight: project.id == selectedProjectId ? .semibold : .medium))
                    .foregroundStyle(Color.white.opacity(project.id == selectedProjectId ? 0.90 : 0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
                checkmark(isVisible: project.id == selectedProjectId)
            }
            .modifier(WorkspaceSidebarDropdownMenuRowStyle(isSelected: project.id == selectedProjectId))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarIdentityMenu(.project(project.id))
    }
}
