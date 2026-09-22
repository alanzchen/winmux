import Foundation

struct WorkspaceSidebarAppViewModel: Hashable, Identifiable {
    let name: String
    let bundleId: String?
    let bundlePath: String?
    var contextTitle: String? = nil
    var identityLabel: String? = nil

    var id: String {
        if let bundleId, !bundleId.isEmpty { return "bundle:\(bundleId)" }
        if let bundlePath, !bundlePath.isEmpty { return "path:\(bundlePath)" }
        return "name:\(name)"
    }
}

func uniqueWorkspaceSidebarApps(_ apps: [WorkspaceSidebarAppViewModel]) -> [WorkspaceSidebarAppViewModel] {
    var seen: Set<String> = []
    return apps.filter { seen.insert($0.id).inserted }.sorted {
        let comparison = $0.name.localizedStandardCompare($1.name)
        return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
}

func workspaceSidebarAppSummaryLabel(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> String {
    let apps = workspace.apps.map(\.name).joined(separator: ", ")
    return apps.isEmpty ? "\(workspace.displayName), no apps" : "\(workspace.displayName), \(apps)"
}

func workspaceSidebarAppSummaryIdentifier(_ workspace: WorkspaceSidebarWorkspaceViewModel) -> String {
    let label = workspace.displayName
    if !label.isEmpty, label.allSatisfy(\.isNumber) { return label }
    if workspace.isGeneratedName, workspace.sidebarLabel.isEmpty, label.hasPrefix("Workspace ") {
        let number = String(label.dropFirst("Workspace ".count))
        if !number.isEmpty { return number }
    }
    return label.first.map { String($0).uppercased() } ?? "W"
}

func workspaceSidebarAppContextDescription(_ app: WorkspaceSidebarAppViewModel, workspaceDisplayName: String) -> String {
    let title = app.contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    return [app.name, title?.takeIf { !$0.isEmpty && $0 != app.name && $0 != workspaceDisplayName },
        "Workspace \(workspaceDisplayName)"].compactMap { $0 }.joined(separator: " · ")
}
