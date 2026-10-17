import Common

func automaticWorkspaceIndex(_ name: String) -> Int? {
    Int(name)
}

@MainActor
func nextAutomaticWorkspaceName(projectId _: WorkspaceProjectId = workspaceProjectDefaultId, monitor: Monitor = mainMonitor) -> String {
    var candidate = 1
    while true {
        let name = String(candidate)
        if winMuxWorkspaceState.workspaceIdByName[name] == nil,
           !savedWorkspaceStore.contains(workspaceName: name),
           isValidAssignment(workspaceName: name, screen: monitor.rect.topLeftCorner)
        {
            return name
        }
        candidate += 1
    }
}

func parsePositiveWorkspaceDisplayIndex(_ workspaceName: String) -> Int? {
    guard let targetIndex = Int(workspaceName),
          targetIndex > 0,
          String(targetIndex) == workspaceName
    else {
        return nil
    }
    return targetIndex
}
