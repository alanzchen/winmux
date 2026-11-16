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
    static func runCmdSeq(_ commands: [any Command], _ env: CmdEnv, _ io: CmdIo) async throws -> Int32ExitCode {
        try await runCmdSeq(commands, env, io) { _, _ in }
    }

    /// `runCmdSeq`, reporting each command's own exit code to `onResult` (`trigger-binding` aggregates them).
    @MainActor
    static func runCmdSeq(
        _ commands: [any Command],
        _ env: CmdEnv,
        _ io: CmdIo,
        onResult: (any Command, Int32ExitCode) -> Void,
    ) async throws -> Int32ExitCode {
        // Only this sequence's commands see it, through their env; a sequence run within one keeps it.
        var env = env
        if config.usesBrowserTabs, env.tabsListedAtSequenceStart.isEmpty {
            env.tabsListedAtSequenceStart = Set(Workspace.all.filter(workspaceTabIsShown).map(\.id))
        }
        // As upstream (beb67f4a): the sequence exits with its last command's code.
        var exitCode = Int32ExitCode(rawValue: EXIT_CODE_ZERO)
        for command in commands {
            exitCode = Int32ExitCode(rawValue: (try await command.run(env, io)).rawValue)
            onResult(command, exitCode)
            refreshModel()
            if exitCode.rawValue == EXIT_CODE_ZERO && syncsClosedWindowsCache(after: command) {
                syncClosedWindowsCacheToCurrentWorld()
            }
        }
        return exitCode
    }

    /// `trigger-binding`'s exit code, in the CLI's terms (docs/upstream-sync.md, S3 review fixes). 2 is only a
    /// conditional command's error (`test`, `test-not`, or a nested `trigger-binding` that ended so). Every other
    /// failure is 1, as v0.6.422 reported: a failed command, a false condition, a missing mode or binding. 0 when every
    /// command succeeded. Upstream reports only the last command's code; that waits for S5, where `&&` and `||` arrive.
    @MainActor
    static func runBindingForCli(_ commands: [any Command], _ env: CmdEnv, _ io: CmdIo) async throws -> Int32ExitCode {
        var anyFailed = false
        var conditionalError = false
        _ = try await runCmdSeq(commands, env, io) { command, code in
            let cliCode = winMuxCliExitCode(command, code)
            if cliCode != EXIT_CODE_ZERO { anyFailed = true }
            if cliCode == EXIT_CODE_TWO { conditionalError = true }
        }
        if conditionalError { return Int32ExitCode(rawValue: EXIT_CODE_TWO) }
        return anyFailed ? bindingFailed : Int32ExitCode(rawValue: EXIT_CODE_ZERO)
    }

    /// A failed `trigger-binding` that isn't a conditional error: 1. Upstream's `.fail` is 2, which the CLI would report
    /// as is, since `trigger-binding` already answers in the CLI's terms.
    private static let bindingFailed = Int32ExitCode(rawValue: 1)

    /// Replaces `TriggerBindingCommand.run`: the same lookup, with `runBindingForCli` for the result.
    @MainActor
    static func triggerBinding(_ args: TriggerBindingCmdArgs, _ env: CmdEnv, _ io: CmdIo) async throws -> Int32ExitCode {
        guard let mode = config.modes[args.mode] else {
            _ = io.err("Mode '\(args.mode)' doesn't exist. " +
                "Available modes: \(config.modes.keys.joined(separator: ","))")
            return bindingFailed
        }
        if let binding = mode.bindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) {
            // refreshSession is not needed since commands are already run in refreshSession
            return try await runBindingForCli(binding.commands, env, io)
        }
        if let binding = mode.sequenceBindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) {
            return try await runBindingForCli(binding.commands, env, io)
        }
        _ = io.err("Binding '\(args.binding.val)' is not presented in mode '\(args.mode)'")
        return bindingFailed
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
