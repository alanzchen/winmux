import SwiftUI

struct WorkspaceSidebarCompactMonitorSelector: View {
    let scopes: [WorkspaceSidebarMonitorScopeViewModel]
    let selectedScopeId: String
    let sectionWidth: CGFloat
    /// The panel's own display, listed first as This Display.
    var targetScopeId: String = ""
    let onSelectScope: (String) -> Void

    private var menuScopes: [WorkspaceSidebarMonitorScopeViewModel] {
        workspaceSidebarMonitorScopeMenu(scopes, targetScopeId: targetScopeId)
    }

    var selectedScope: WorkspaceSidebarMonitorScopeViewModel? {
        menuScopes.first { $0.id == selectedScopeId }
            ?? menuScopes.first { $0.id == workspaceSidebarDefaultScopeId }
    }

    private var selectedDisplayNumber: Int? {
        guard let index = scopes.filter({ workspaceSidebarMonitorScopePoint($0.id) != nil })
            .firstIndex(where: { $0.id == selectedScope?.id }) else { return nil }
        return index + 1
    }

    private var selectedScopeImageName: String {
        if selectedScope?.id == targetScopeId { return "display" }
        if let number = selectedDisplayNumber { return "\(number).square" }
        return selectedScope?.id == workspaceSidebarDefaultScopeId
            ? "display.2"
            : selectedScope?.systemImageName ?? "display.2"
    }

    var body: some View {
        Menu {
            Picker("Show workspaces from", selection: Binding(
                get: { selectedScope?.id ?? workspaceSidebarDefaultScopeId },
                set: { scopeId in onSelectScope(scopeId) },
            )) {
                ForEach(menuScopes) { scope in
                    Label(scope.id == workspaceSidebarFocusedScopeId ? "Focus" : scope.displayName, systemImage: scope.systemImageName)
                        .tag(scope.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: selectedScopeImageName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: workspaceSidebarDropdownHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: sectionWidth, height: workspaceSidebarDropdownHeight)
        .accessibilityLabel("Show workspaces from: \(selectedScope?.displayName ?? "All Displays")")
        .help("Show workspaces from: \(selectedScope?.displayName ?? "All Displays")")
    }
}

extension WorkspaceSidebarView {
    var shouldShowCompactMonitorSelector: Bool {
        snapshot.monitorScopes.count { workspaceSidebarMonitorScopePoint($0.id) != nil } > 1
    }

    /// Tabs shows its display menu once there's a choice to make: another display, or Focused.
    var showsTabsDisplayMenu: Bool {
        shouldShowCompactMonitorSelector || snapshot.monitorScopes.contains { $0.id == workspaceSidebarFocusedScopeId }
    }

    func compactMonitorSelectorSection(
        layout: WorkspaceSidebarConfiguration,
        expansionProgress: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat,
    ) -> some View {
        WorkspaceSidebarCompactMonitorSelector(
            scopes: snapshot.monitorScopes,
            selectedScopeId: snapshot.selectedMonitorScopeId,
            sectionWidth: max(fittedVisibleWidth(layout: layout) - leadingInset - trailingInset, 0),
            targetScopeId: snapshot.targetMonitorScopeId,
            onSelectScope: { scopeId in
                browseMode = .activeProject
                activeInUseOverrideWorkspaceName = nil
                actions.send(.selectMonitorScope(scopeId))
            },
        )
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, snapshot.configuration.topPadding)
        .padding(.bottom, workspaceSidebarSectionGap)
    }
}
