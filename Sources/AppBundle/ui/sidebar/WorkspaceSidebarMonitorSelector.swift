import AppKit
import Common
import SwiftUI

// MARK: - Monitor Selector

/// The least of Other Projects' label that the filter row keeps beside the display pills.
let workspaceSidebarMonitorSelectorMinimumProjectWidth: CGFloat = 64

/// How far the project popup, hanging from its button's trailing edge, moves right so it doesn't
/// start before the row does. `buttonMaxX` is measured from the row's leading edge.
func workspaceSidebarProjectPopupShift(buttonMaxX: CGFloat, popupWidth: CGFloat) -> CGFloat {
    max(0, popupWidth - buttonMaxX)
}

private let workspaceSidebarMonitorSelectorRowSpace = "workspaceSidebarMonitorSelectorRow"

struct WorkspaceSidebarMonitorSelector: View {
    let scopes: [WorkspaceSidebarMonitorScopeViewModel]
    let projects: [WorkspaceSidebarProjectViewModel]
    let selectedScopeId: String
    let activeProjectId: WorkspaceProjectId
    let browsedProjectId: WorkspaceProjectId?
    let expansionProgress: CGFloat
    let sectionWidth: CGFloat
    /// The panel's own display and the filter it shows until the menu is used.
    var targetScopeId: String = ""
    var automaticScopeId: String = workspaceSidebarDefaultScopeId
    var onSelectScope: (String) -> Void = { selectWorkspaceSidebarMonitorScope($0) }
    var onSelectProject: (WorkspaceProjectId?) -> Void = { _ in }
    var onRenameProject: (WorkspaceSidebarProjectViewModel) -> Void = { _ in }
    @Binding var renamingProjectId: WorkspaceProjectId?
    @Binding var renamingProjectText: String
    var onCommitRenameProject: @MainActor @Sendable () -> Void = {}
    var onCancelRenameProject: @MainActor @Sendable () -> Void = {}
    var onSetProjectColor: (WorkspaceSidebarProjectViewModel, String?) -> Void = { _, _ in }
    var onDeleteProject: (WorkspaceSidebarProjectViewModel) -> Void = { _ in }
    var showsProjectSelector = true

    @State private var isProjectMenuOpen = false
    private var projectPopupWidth: CGFloat {
        let names = browsableProjects.map(\.displayName) + ["Other Projects"]
        let maxTextWidth = names.map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        }.max() ?? 0
        return max(ceil(maxTextWidth) + 50, 116)
    }
    /// The popup fits the row, whose width the panel shows.
    private var projectPopupMenuWidth: CGFloat { min(projectPopupWidth, sectionWidth) }
    private var hasMultipleMonitors: Bool {
        scopes.count { workspaceSidebarMonitorScopePoint($0.id) != nil } > 1
    }

    /// The first pill returns to the panel's default filter: This Display or All Displays.
    private var quickScopes: [WorkspaceSidebarMonitorScopeViewModel] {
        let menuScopes = workspaceSidebarMonitorScopeMenu(scopes, targetScopeId: targetScopeId)
        var result = [
            menuScopes.first { $0.id == automaticScopeId }
                ?? menuScopes.first { $0.id == workspaceSidebarDefaultScopeId }
                ?? WorkspaceSidebarMonitorScopeViewModel(
                    id: workspaceSidebarDefaultScopeId,
                    displayName: "All Displays",
                    subtitle: nil,
                    systemImageName: "display.2",
                    isFocusedMonitor: false
                ),
        ]
        if let focusedScope = scopes.first(where: { $0.id == workspaceSidebarFocusedScopeId }) {
            result.append(focusedScope)
        }
        return result
    }

    private var selectedProject: WorkspaceSidebarProjectViewModel? {
        guard let browsedProjectId else { return nil }
        return projects.first { $0.id == browsedProjectId }
    }

    private var browsableProjects: [WorkspaceSidebarProjectViewModel] {
        projects.filter { $0.id != activeProjectId }
    }

    /// Beside Other Projects, the display pills keep their full names. A sidebar too narrow for
    /// both folds the pills into the display menu's icon, which offers the same choices.
    var foldsScopePillsIntoMenu: Bool {
        func pillWidth(_ scope: WorkspaceSidebarMonitorScopeViewModel) -> CGFloat {
            let title = scope.id == workspaceSidebarFocusedScopeId ? "Focus" : scope.displayName
            return ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width)
                + workspaceSidebarDropdownPadding * 2
        }
        let pills = quickScopes.enumerated().map { index, scope in
            hasMultipleMonitors && index == 0 ? workspaceSidebarDropdownHeight : pillWidth(scope)
        }
        guard pills.count > 1 || !hasMultipleMonitors else { return false }
        let selector = showsProjectSelector && !browsableProjects.isEmpty
            ? [workspaceSidebarMonitorSelectorMinimumProjectWidth] : []
        let widths = pills + selector
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * 3 > sectionWidth
    }

    var body: some View {
        HStack(spacing: 3) {
            if foldsScopePillsIntoMenu {
                scopeMenu
                if showsProjectSelector, !browsableProjects.isEmpty {
                    projectSelector
                }
            } else {
                scopePills
            }
            Spacer(minLength: 0)
        }
        .coordinateSpace(name: workspaceSidebarMonitorSelectorRowSpace)
        .frame(width: sectionWidth, alignment: .leading)
        .frame(height: workspaceSidebarDropdownHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(expansionProgress)
        .zIndex(isProjectMenuOpen ? 200 : 0)
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarWillCollapseNotification)) { _ in
            if isProjectMenuOpen {
                withAnimation(.easeOut(duration: 0.08)) {
                    isProjectMenuOpen = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: workspaceSidebarDismissProjectMenusNotification)) { _ in
            if isProjectMenuOpen {
                withAnimation(.easeOut(duration: 0.10)) {
                    isProjectMenuOpen = false
                }
            }
        }
    }

    /// The display menu's icon. Like a pill, choosing from it closes the project popup.
    private var scopeMenu: some View {
        WorkspaceSidebarCompactMonitorSelector(
            scopes: scopes,
            selectedScopeId: selectedScopeId,
            sectionWidth: workspaceSidebarDropdownHeight,
            targetScopeId: targetScopeId,
            onSelectScope: { scopeId in
                isProjectMenuOpen = false
                onSelectScope(scopeId)
            },
        )
    }

    private var scopePills: some View {
        ForEach(Array(quickScopes.enumerated()), id: \.element.id) { index, scope in
            if hasMultipleMonitors && index == 0 {
                scopeMenu
            } else {
                monitorScopePill(scope)
            }
            if showsProjectSelector, index == quickScopes.count - 1, !browsableProjects.isEmpty {
                projectSelector
            }
        }
    }

    private func monitorScopePill(_ scope: WorkspaceSidebarMonitorScopeViewModel) -> some View {
        let isActive = scope.id == selectedScopeId && browsedProjectId == nil
        return Button {
            isProjectMenuOpen = false
            onSelectScope(scope.id)
        } label: {
            Text(scope.id == workspaceSidebarFocusedScopeId ? "Focus" : scope.displayName)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.68))
                .modifier(WorkspaceSidebarDropdownControlStyle(isActive: isActive))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(scopeAccessibilityLabel(scope))
        .background {
            if workspaceSidebarMonitorScopePoint(scope.id) != nil {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WorkspaceSidebarDropTargetPreferenceKey.self,
                        value: [WorkspaceSidebarDropTargetFrame(
                            kind: .monitor(scope.id),
                            frame: geometry.frame(in: .named("workspaceSidebarContent")),
                        )],
                    )
                }
            }
        }
    }

    private var projectSelector: some View {
        let isActive = selectedProject != nil || isProjectMenuOpen
        if let selectedProject, renamingProjectId == selectedProject.id {
            return AnyView(
                WorkspaceSidebarProjectRenameField(
                    project: selectedProject,
                    text: $renamingProjectText,
                    onCommit: onCommitRenameProject,
                    onCancel: onCancelRenameProject,
                )
                // Beside the display pills, a narrow sidebar narrows it instead of pushing it past the edge.
                .frame(maxWidth: projectPopupWidth)
                .frame(height: workspaceSidebarDropdownHeight)
                .layoutPriority(1)
            )
        }
        return AnyView(Button {
            guard !browsableProjects.isEmpty else { return }
            isProjectMenuOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(selectedProject?.displayName ?? "Other Projects")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(isActive ? 0.86 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isActive ? 0.86 : 0.72))
                    .rotationEffect(.degrees(isProjectMenuOpen ? 180 : 0))
            }
            .modifier(WorkspaceSidebarDropdownControlStyle(isActive: isActive))
        }
        .buttonStyle(.plain)
        // Its natural width where there's room; a narrow sidebar shortens the name instead.
        .layoutPriority(1)
        .overlay(alignment: .topTrailing) {
            // Hung from the button's trailing edge, but never past the row's leading edge, where
            // the panel would cut it off.
            GeometryReader { button in
                projectPopup
                    .offset(x: workspaceSidebarProjectPopupShift(
                        buttonMaxX: button.frame(in: .named(workspaceSidebarMonitorSelectorRowSpace)).maxX,
                        popupWidth: projectPopupMenuWidth),
                    y: workspaceSidebarDropdownHeight + workspaceSidebarSectionGap)
                    .frame(width: button.size.width, height: button.size.height, alignment: .topTrailing)
            }
        }
        .zIndex(isProjectMenuOpen ? 200 : 0)
        .help("Browse another project")
        )
    }

    private var projectPopup: some View {
        Group {
            if isProjectMenuOpen {
                WorkspaceSidebarProjectPopup(
                    projects: browsableProjects,
                    selectedProjectId: browsedProjectId ?? activeProjectId,
                    onSelect: { projectId in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            onSelectProject(projectId == browsedProjectId ? nil : projectId)
                            isProjectMenuOpen = false
                        }
                    },
                    onCreate: {},
                    onRename: { project in
                        onRenameProject(project)
                        isProjectMenuOpen = false
                    },
                    onSetColor: onSetProjectColor,
                    onDelete: { project in
                        onDeleteProject(project)
                        isProjectMenuOpen = false
                    },
                    showsCreateAction: false,
                    menuWidth: projectPopupMenuWidth
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)),
                    removal: .opacity
                ))
                .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.88), value: isProjectMenuOpen)
                .zIndex(200)
            }
        }
    }

    private func scopeAccessibilityLabel(_ scope: WorkspaceSidebarMonitorScopeViewModel) -> String {
        if let subtitle = scope.subtitle {
            return "\(scope.displayName), \(subtitle)"
        }
        return scope.displayName
    }
}
