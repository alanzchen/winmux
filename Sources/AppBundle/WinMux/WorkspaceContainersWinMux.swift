import Common

/// Lookups that don't create what they look for, for snapshots that mustn't change the tree.
@MainActor
func resolvedForceAssignedMonitor(forWorkspaceName name: String) -> Monitor? {
    config.workspaceToMonitorForceAssignment[name]?
        .lazy
        .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
        .first
}

extension Workspace {
    private func existingContainer<T: TreeNode>(_ type: T.Type) -> T? {
        let containers = children.filterIsInstance(of: T.self)
        return switch containers.count {
            case 0: nil
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one \(T.self)")
        }
    }

    var existingMacOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer? {
        existingContainer(MacosFullscreenWindowsContainer.self)
    }

    var existingMacOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer? {
        existingContainer(MacosHiddenAppsWindowsContainer.self)
    }
}
