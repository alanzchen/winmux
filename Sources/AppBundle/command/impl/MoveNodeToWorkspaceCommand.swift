import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return io.err(noWindowIsFocused) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .newWorkspace:
                guard let subjectWs else { return io.err("Window \(window.windowId) doesn't belong to any workspace") }
                targetWorkspace = getOrCreateAdjacentBlankWorkspace(
                    projectId: workspaceContextProjectId(of: subjectWs),
                    monitor: window.nodeMonitor ?? target.workspace.workspaceMonitor,
                )
            case .relative(let nextPrev):
                guard let subjectWs else { return io.err("Window \(window.windowId) doesn't belong to any workspace") }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                )
                    ?? createNextTransientBlankWorkspaceForMoveIfAllowed(
                        from: subjectWs,
                        isNext: nextPrev == .next,
                        wrapAround: args.wrapAround,
                        usesStdin: args.useStdin,
                        listedAtSequenceStart: env.tabsListedAtSequenceStart,
                    )
                guard let ws else { return io.err("Can't resolve next or prev workspace") }
                targetWorkspace = ws
            case .direct(let name):
                guard let ws = resolveMoveTargetWorkspace(
                    named: name.raw,
                    sourceWorkspace: subjectWs ?? target.workspace,
                    sourceMonitor: window.nodeMonitor ?? target.workspace.workspaceMonitor,
                    listedAtSequenceStart: env.tabsListedAtSequenceStart,
                ) else {
                    return io.err("Workspace '\(name.raw)' doesn't exist")
                }
                targetWorkspace = ws
        }
        // A pin whose one window is hidden with its app shows it first; one in full screen isn't split.
        if window.nodeWorkspace !== targetWorkspace, let notShown = await showWorkspaceSidebarPinsForSplit([targetWorkspace]) {
            return io.err(notShown.message)
        }
        // Into or out of a pin with one window, as the pins' policy says: it keeps its window as its own.
        return moveWindowToWorkspaceKeepingPins(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow,
            failIfNoop: args.failIfNoop)
    }
}

@MainActor
private func createNextTransientBlankWorkspaceForMoveIfAllowed(
    from current: Workspace,
    isNext: Bool,
    wrapAround: Bool,
    usesStdin: Bool,
    listedAtSequenceStart: Set<WorkspaceId>,
) -> Workspace? {
    guard isNext, !wrapAround, !usesStdin else { return nil }
    let nextWorkspaceIndex = numberedWorkspaceNavigationTabs(current: current, listedAtSequenceStart: listedAtSequenceStart).count + 1
    return createAdjacentTransientBlankWorkspaceIfAllowed(named: String(nextWorkspaceIndex), from: current,
        listedAtSequenceStart: listedAtSequenceStart)
}

@MainActor
private func resolveMoveTargetWorkspace(
    named workspaceName: String,
    sourceWorkspace: Workspace,
    sourceMonitor: Monitor,
    listedAtSequenceStart: Set<WorkspaceId>,
) -> Workspace? {
    if let targetIndex = parsePositiveWorkspaceDisplayIndex(workspaceName) {
        if let workspace = numberedWorkspaceNavigationTabs(current: sourceWorkspace, listedAtSequenceStart: listedAtSequenceStart)
            .getOrNil(atIndex: targetIndex - 1) {
            return workspace
        }
        return createAdjacentTransientBlankWorkspaceIfAllowed(named: workspaceName, from: sourceWorkspace,
            listedAtSequenceStart: listedAtSequenceStart)
    }

    let existedBefore = Workspace.existing(byName: workspaceName) != nil
    let workspace = Workspace.get(byName: workspaceName)
    if !existedBefore {
        workspace.assignProject(workspaceContextProjectId(of: sourceWorkspace))
    }
    workspace.seedMonitorIfNeeded(sourceMonitor)
    return workspace
}

@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> Bool {
    if window.nodeWorkspace == targetWorkspace {
        if !failIfNoop {
            io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code")
        }
        return !failIfNoop
    }
    if window.isFloating {
        window.bind(to: targetWorkspace, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else {
        let binding = workspaceAppendBindingData(targetWorkspace: targetWorkspace, index: index)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    }
    return focusFollowsWindow ? window.focusWindow() : true
}
