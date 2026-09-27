import SwiftUI

private struct WorkspaceSidebarBadgeOwnersKey: EnvironmentKey {
    static let defaultValue: [String: UInt32] = [:]
}

extension EnvironmentValues {
    var workspaceSidebarBadgeOwners: [String: UInt32] {
        get { self[WorkspaceSidebarBadgeOwnersKey.self] }
        set { self[WorkspaceSidebarBadgeOwnersKey.self] = newValue }
    }
}

/// The first window in sidebar order owns the app-wide count. Other windows show
/// activity dots, so a shared Dock count does not look like several separate inboxes.
func workspaceSidebarBadgeOwners(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> [String: UInt32] {
    var result: [String: UInt32] = [:]
    for workspace in workspaces {
        for window in workspaceSidebarPinnedTabWindows(workspace) {
            if let path = window.appBundlePath, result[path] == nil { result[path] = window.windowId }
        }
    }
    return result
}

/// The same app-level label mirrored by Dock mode, fitted to a tab's trailing accessory.
struct WorkspaceSidebarTabBadge: View {
    let appName: String
    let bundlePath: String?
    @ObservedObject var model: WorkspaceSidebarDockBadgeModel
    var compact = false
    var windowId: UInt32? = nil
    @Environment(\.workspaceSidebarBadgeOwners) private var owners

    private var showsDot: Bool {
        compact || (windowId != nil && bundlePath.flatMap { owners[$0] }.map { $0 != windowId } == true)
    }

    var body: some View {
        if model.snapshot.showsAppBadges, let label = model.snapshot.label(forPath: bundlePath) {
            Text(showsDot ? "" : (label.count > 4 ? String(label.prefix(3)) + "…" : label))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, showsDot ? 0 : 4)
                .frame(minWidth: showsDot ? 6 : 16, maxWidth: showsDot ? 6 : 32,
                    minHeight: showsDot ? 6 : 16, maxHeight: showsDot ? 6 : 16)
                .fixedSize(horizontal: showsDot, vertical: false)
                .background(Color(red: 0.96, green: 0.20, blue: 0.23), in: Capsule())
                .accessibilityLabel("\(appName) app badge: \(label), shared by all its windows")
                .allowsHitTesting(false)
        }
    }
}

struct WorkspaceSidebarGroupActivity: View {
    let workspaces: [WorkspaceSidebarWorkspaceViewModel]
    @ObservedObject var model: WorkspaceSidebarDockBadgeModel

    var body: some View {
        if model.snapshot.showsAppBadges,
           workspaces.flatMap(workspaceSidebarPinnedTabWindows).contains(where: { model.snapshot.label(forPath: $0.appBundlePath) != nil }) {
            Circle().fill(Color(red: 0.96, green: 0.20, blue: 0.23)).frame(width: 7, height: 7)
                .accessibilityLabel("App activity in this group").allowsHitTesting(false)
        }
    }
}
