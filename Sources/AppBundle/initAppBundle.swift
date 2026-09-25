import AppKit
import Common
import Foundation

@MainActor public func initAppBundle() {
    _ = Task {
        initTerminationHandler()
        isCli = false
        initServerArgs()
        var bootstrappedConfigUrl: URL? = nil
        if isDebug {
            await toggleReleaseServerIfDebug(.off)
            interceptTermination(SIGINT)
            interceptTermination(SIGKILL)
        }
        // Saved names must exist before anything (config reload, sidebar refresh, focus) can
        // hand them out as automatic workspace names.
        isDeferringOrphanedWorkspaceLabelCleanup = true
        // Also after a failed startup: otherwise every saved app would stay armed for routing,
        // nothing would be captured, and labels would never be cleaned up.
        defer { finishSavedWorkspaceStartup() }
        loadSavedWorkspaceStoreForStartup()
        materializeSavedWorkspaceNames()
        do {
            bootstrappedConfigUrl = try ensureBootstrapConfigExistsIfNeeded()
        } catch {
            MessageModel.shared.message = Message(
                description: "Config Bootstrap Error",
                body: error.localizedDescription,
            )
        }
        if try await !reloadConfig(forceConfigUrl: bootstrappedConfigUrl) {
            var out = ""
            check(
                try await reloadConfig(forceConfigUrl: defaultConfigUrl, stdout: &out),
                """
                Can't load default config. Your installation is probably corrupted.
                Please don't modify '\(defaultConfigUrl)'

                \(out)
                """,
            )
        }
        materializePersistedWorkspaceProjects()
        MonitorConfigurationObserver.shared.prepareForStartup()

        checkAccessibilityPermissions()
        // Screen Recording is optional. Request it only from the explicit Settings action,
        // never on launch, config reload, or restoration after an update.
        startUnixSocketServer()
        GlobalObserver.initObserver()
        MonitorConfigurationObserver.shared.startObserving()
        installSavedWorkspaceObservers()
        Workspace.reconcileWorkspaceState() // init workspaces
        // Not Workspace.all.first: that can be a hidden saved workspace, and focusing it would
        // pull it onto a display in place of the one restored there.
        _ = mainMonitor.activeWorkspace.focusWorkspace()
        let didLoadPersistedFrozenWorld = loadPersistedFrozenWorldForStartupIfPresent()
        try await runRefreshSessionBlocking(.startup, layoutWorkspaces: false)
        try await runLightSession(.startup, .forceRun) {
            if shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: didLoadPersistedFrozenWorld) {
                smartLayoutAtStartup()
            }
            _ = try await config.afterStartupCommand.runCmdSeq(.defaultEnv, .emptyStdin)
        }
        isWinMuxRuntimeReady = true
        finishSavedWorkspaceStartup()
        if config.workspaceSidebar.openSavedWorkspaceAppsAtStartup {
            Task { @MainActor in _ = await openMissingSavedWorkspaceApps(workspaceNames: nil) }
        }
        if bootstrappedConfigUrl != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ShortcutSettingsModel.shared.requestWindowOpen()
            }
        }
    }
}

@MainActor
private func finishSavedWorkspaceStartup() {
    guard savedWorkspaceRuntime.runtimeReadyAt == nil else { return }
    isDeferringOrphanedWorkspaceLabelCleanup = false
    // After a failed startup the config may never have loaded; don't prune labels against it.
    if savedWorkspaceRuntime.isConfigLoaded {
        clearOrphanedWorkspaceSidebarLabels()
    }
    savedWorkspaceRuntime.runtimeReadyAt = savedWorkspaceRuntime.now
    scheduleSavedWorkspaceCheckpoint()
}

/// A saved workspace already has its own layout.
@MainActor
func shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: Bool) -> Bool {
    !didLoadPersistedFrozenWorld && !focus.workspace.isSaved
}

@MainActor
private func smartLayoutAtStartup() {
    let workspace = focus.workspace
    let root = workspace.rootTilingContainer
    if root.children.count <= 3 {
        root.layout = .tiles
    } else {
        root.layout = .tabGroup
    }
}

@TaskLocal
var _isStartup: Bool? = false
var isStartup: Bool { _isStartup ?? dieT("isStartup is not initialized") }

struct ServerArgs: Sendable {
    var configLocation: String? = nil
    var isReadOnly: Bool = false
}

private let serverHelp = """
    USAGE: \(CommandLine.arguments.first ?? "WinMux.app/Contents/MacOS/WinMux") [<options>]

    OPTIONS:
      -h, --help              Print help
      -v, --version           Print WinMux.app version
      --config-path <path>    Config path. It will take priority over ~/.config/winmux/winmux.toml,
                              ~/.winmux.toml and ${XDG_CONFIG_HOME}/winmux/winmux.toml
      --read-only             Run without mutating macOS windows.
                              Useful if you want to use only debug-windows or other query commands.
    """

nonisolated(unsafe) private var _serverArgs = ServerArgs()
var serverArgs: ServerArgs { _serverArgs }
private func initServerArgs() {
    let args = CommandLine.arguments.slice(1...) ?? []
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        exit(0, out: serverHelp)
    }
    var index = 0
    while index < args.count {
        let current = args[index]
        index += 1
        switch current {
            case "--version", "-v":
                exit(0, out: "\(winMuxAppVersion) \(gitHash)")
            case "--config-path":
                if let arg = args.getOrNil(atIndex: index) {
                    _serverArgs.configLocation = arg
                } else {
                    exit(1, err: "Missing <path> in --config-path flag")
                }
                index += 1
            case "--read-only": // todo rename to '--disabled' and unite with disabled feature
                _serverArgs.isReadOnly = true
            case "-NSDocumentRevisionsDebugMode" where isDebug:
                // Skip Xcode CLI args.
                // Usually it's '-NSDocumentRevisionsDebugMode NO'/'-NSDocumentRevisionsDebugMode YES'
                while args.getOrNil(atIndex: index)?.starts(with: "-") == false { index += 1 }
            default:
                exit(1, err: "Unrecognized flag '\(args.first.orDie())'")
        }
    }
    if let path = serverArgs.configLocation, !FileManager.default.fileExists(atPath: path) {
        exit(1, err: "\(path) doesn't exist")
    }
}
