import Common

/// WinMux's entry points from upstream AeroSpace code. Each upstream call site is one line, or one block, marked
/// `WINMUX-HOOK(<name>)`; docs/upstream-sync.md lists every hook with the argument that it preserves behavior.
///
/// Hooks are static functions: a call site runs exactly the code that stood there before it became a hook, in the
/// same order, so nothing has to be installed at startup or in tests. A *replacement* hook (marked
/// `WINMUX-HOOK-REPLACES`) answers instead of the upstream body below it; the sync report flags upstream changes to
/// such bodies, since they don't take effect until ported.
enum WinMuxHooks {}

// MARK: commands

extension WinMuxHooks {
    /// Replaces `[Command].runCmdSeq(_:_:)`. Differences from upstream's body: Tabs mode records the tabs shown when
    /// the sequence starts; the model is normalized before the closed-windows cache is touched; the cache is synced to
    /// the current world, not cleared, and only after a command that succeeded and can change the tree.
    @MainActor
    static func runCmdSeq(_ commands: [any Command], _ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // Only this sequence's commands see it, through their env; a sequence run within one keeps it.
        var env = env
        if config.usesBrowserTabs, env.tabsListedAtSequenceStart.isEmpty {
            env.tabsListedAtSequenceStart = Set(Workspace.all.filter(workspaceTabIsShown).map(\.id))
        }
        var isSucc = true
        for command in commands {
            let commandSucc = try await command.run(env, io)
            isSucc = commandSucc && isSucc
            refreshModel()
            if commandSucc && syncsClosedWindowsCache(after: command) {
                syncClosedWindowsCacheToCurrentWorld()
            }
        }
        return isSucc
    }

    /// Whether a command can change the tree or which workspace a display shows, so the closed-windows cache follows
    /// it. Upstream's commands declare `shouldResetClosedWindowsCache`; WinMux also counts these, which upstream
    /// declares `false`, because in WinMux they change visible workspace assignment or tree shape.
    static func syncsClosedWindowsCache(after command: any Command) -> Bool {
        command.shouldResetClosedWindowsCache || closedWindowsCacheSyncingUpstreamCommands.contains { $0 == type(of: command) }
    }

    static let closedWindowsCacheSyncingUpstreamCommands: [any Command.Type] = [
        BalanceSizesCommand.self,
        FocusBackAndForthCommand.self,
        FullscreenCommand.self,
        MacosNativeFullscreenCommand.self,
        MacosNativeMinimizeCommand.self,
        WorkspaceBackAndForthCommand.self,
        WorkspaceCommand.self,
    ]
}

/// Upstream's name for the closed-windows cache update after a command. WinMux keeps the cache as a snapshot of the
/// current world rather than clearing it.
@MainActor
func resetClosedWindowsCache() {
    syncClosedWindowsCacheToCurrentWorld()
}

// MARK: lifecycle events

extension WinMuxHooks {
    /// After `enable` changes the enabled state, before upstream re-activates modes. Disabling ends any sidebar
    /// expansion, pending window drop and mouse manipulation; either way the sidebar and tab strips redraw.
    @MainActor
    static func didSetEnabled(_ newState: Bool) {
        if !newState {
            TrayMenuModel.shared.isWorkspaceSidebarExpanded = false
            clearPendingWindowDragIntent()
            cancelManipulatedWithMouseState()
        }
        WorkspaceSidebarPanel.refreshAll()
        WindowTabStripPanelController.shared.refresh()
    }
}
