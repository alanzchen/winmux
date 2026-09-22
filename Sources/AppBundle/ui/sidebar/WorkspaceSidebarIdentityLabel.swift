import Foundation
import SwiftUI

/// Derive labels from stable workspace contents, never the currently focused window.
func workspaceSidebarIdentityLabels(
    _ workspaces: [WorkspaceSidebarWorkspaceViewModel], mode: DockIdentityLabels
) -> [WorkspaceSidebarWorkspaceViewModel] {
    var result = workspaces.map { workspace in
        var workspace = workspace
        workspace.apps = workspace.apps.map { app in
            var app = app
            app.identityLabel = nil
            return app
        }
        return workspace
    }
    let appIds = Set(workspaces.flatMap { $0.apps.map(\.id) })
    for appId in appIds {
        let indices = workspaces.indices.filter { index in workspaces[index].apps.contains { $0.id == appId } }
        guard mode != .off, mode == .always || indices.count > 1 else { continue }
        var used = Set<String>()
        for index in indices.sorted(by: { workspaces[$0].name < workspaces[$1].name }) {
            guard let appIndex = result[index].apps.firstIndex(where: { $0.id == appId }) else { continue }
            let app = result[index].apps[appIndex]
            let title = workspaceSidebarIdentityTitle(app.contextTitle, appName: app.name)
            let source = title.isEmpty ? result[index].displayName : title
            let base = String(source.prefix(4)).lowercased()
            var label = base.isEmpty ? "app" : base
            var suffix = 2
            while !used.insert(label).inserted {
                let number = String(suffix)
                label = String(base.prefix(max(0, 4 - number.count))) + number
                suffix += 1
            }
            result[index].apps[appIndex].identityLabel = label
        }
    }
    return result
}

func workspaceSidebarIdentityTitle(_ title: String?, appName: String) -> String {
    var value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if value.localizedCaseInsensitiveCompare(appName) == .orderedSame { return "" }
    for separator in [" — ", " – ", " - "] {
        let suffix = separator + appName
        if let range = value.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
            value.removeSubrange(range)
        }
        let prefix = appName + separator
        if let range = value.range(of: prefix, options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
    }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.localizedCaseInsensitiveCompare(appName) == .orderedSame ? "" : value
}

struct WorkspaceSidebarIdentityLabel: View {
    let label: String
    let size: CGFloat

    var body: some View {
        Text(label)
            .font(.system(size: max(8, size * 0.22), weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(white: 0.12).opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size, alignment: .bottom)
            .allowsHitTesting(false)
    }
}
