import Common
import Foundation

@MainActor
func currentAgentWorldId() -> String {
    let workspaces = userFacingWorkspaces(Workspace.all).sortedBy(\.name)
    var lines: [String] = []
    for workspace in workspaces {
        lines += agentWorldLines(for: workspace)
    }
    for member in WorkspaceTabSnapshot.minimizedMembers.sortedBy({ $0.window.windowId }) {
        lines.append(agentMinimizedWorldLine(for: member))
    }
    return stableAgentHash(lines.joined(separator: "\n"))
}

@MainActor
private func agentWorldLines(for workspace: Workspace) -> [String] {
    let content = WorkspaceTabSnapshot(workspace)
    var lines = ["workspace|\(workspace.name)|visible:\(workspace.isVisible)|monitor:\(workspace.workspaceMonitor.monitorId_oneBased?.description ?? "nil")"]
    lines.append(contentsOf: content.root.agentWorldLines(prefix: "tree|\(workspace.name)"))
    for member in content.treeMembers.sortedBy({ $0.window.windowId }) {
        lines.append(agentWorldLine(for: member))
    }
    for group in content.root.agentTabGroups.map(\.source).sortedBy({ agentTabGroupId($0) }) {
        lines.append(agentWorldLine(for: group))
    }
    return lines
}

@MainActor
private func agentWorldLine(for member: WorkspaceTabMember) -> String {
    let window = member.window
    return [
        "window",
        window.windowId.description,
        window.nodeWorkspace?.name ?? "nil",
        window.agentPaneId ?? "nil",
        window.nearestWindowTabGroup.map(agentTabGroupId) ?? "nil",
        member.agentLayoutDescription,
        "fullscreen:\(window.isFullscreen)",
        "noOuterGaps:\(window.noOuterGapsInFullscreen)",
    ].joined(separator: "|")
}

@MainActor
private func agentMinimizedWorldLine(for member: WorkspaceTabMember) -> String {
    let window = member.window
    let origin = switch window.layoutReason {
        case .standard: "standard"
        case .macos(let previousParentKind, let previousWorkspaceName):
            "\(previousParentKind.rawValue):\(previousWorkspaceName ?? "nil")"
    }
    return agentWorldLine(for: member) + "|origin:\(origin)"
}

@MainActor
private func agentWorldLine(for group: TilingContainer) -> String {
    [
        "tabGroup",
        agentTabGroupId(group),
        group.nodeWorkspace?.name ?? "nil",
        "active:\(group.tabActiveWindow?.windowId.description ?? "nil")",
        "tabs:\(group.agentTabWindows.map(\.windowId).map(String.init).joined(separator: ","))",
    ].joined(separator: "|")
}

func stableAgentHash(_ input: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in input.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

func duplicateAgentWindowIds(in ids: [UInt32]) -> [UInt32] {
    var seen: Set<UInt32> = []
    var duplicates: Set<UInt32> = []
    for id in ids where !seen.insert(id).inserted {
        duplicates.insert(id)
    }
    return duplicates.sorted()
}
