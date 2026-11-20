import AppKit
import Common
import Foundation

@MainActor public func initAppBundle() {
    Task.startUnstructured {
        initTerminationHandler()
        unsafe _isCli = false
        initServerArgs()
        var bootstrappedConfigUrl: URL? = nil
        if isDebug {
            await toggleReleaseServerIfDebug(.off)
            interceptTermination(SIGINT)
            interceptTermination(SIGKILL)
        }
        // Acquire permission before config reload registers hotkeys or starts live surfaces.
        // The menu remains available while waiting; approval resumes this same startup task.
        try await waitForAccessibilityPermission()
        // Saved names must exist before anything (config reload, sidebar refresh, focus) can
        // hand them out as automatic workspace names.
        // Also after a failed startup: otherwise every saved app would stay armed for routing
        // and nothing would be captured.
        defer { finishSavedWorkspaceStartup() }
        loadSavedWorkspaceStoreForStartup()
        loadWorkspaceSidebarOrganization()
        // Before the startup refresh registers the windows they're about.
        loadAuxiliaryWindowLinksForStartup()
        loadLinkIntegrations()
        materializeSavedWorkspaceNames()
        do {
            bootstrappedConfigUrl = try ensureBootstrapConfigExistsIfNeeded()
        } catch {
            MessageModel.shared.message = Message(
                type: .config,
                description: "Config Bootstrap Error",
                body: error.localizedDescription,
            )
        }
        try await loadConfigAtStartup(bootstrappedConfigUrl: bootstrappedConfigUrl)
        materializePersistedWorkspaceProjects()
        MonitorConfigurationObserver.shared.prepareForStartup()

        // Screen Recording is optional. Request it only from the explicit Settings action,
        // never on launch, config reload, or restoration after an update.
        startUnixSocketServer()
        MCPServer.shared.appDidStart()
        GlobalObserver.initObserver()
        MonitorConfigurationObserver.shared.startObserving()
        installSavedWorkspaceObservers()
        Workspace.reconcileWorkspaceState() // init workspaces
        // Not Workspace.all.first: that can be a hidden saved workspace, and focusing it would
        // pull it onto a display in place of the one restored there.
        _ = mainMonitor.activeWorkspace.focusWorkspace()
        let didLoadPersistedFrozenWorld = loadPersistedFrozenWorldForStartupIfPresent()
        try await runHeavyCompleteRefreshSession(.startup, layoutWorkspaces: false)
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
    savedWorkspaceRuntime.runtimeReadyAt = savedWorkspaceRuntime.now
    scheduleSavedWorkspaceCheckpoint()
}

/// Restored workspaces and browser tabs already have their own layouts.
@MainActor
func shouldApplySmartLayoutAtStartup(didLoadPersistedFrozenWorld: Bool) -> Bool {
    !config.usesBrowserTabs && !didLoadPersistedFrozenWorld && !focus.workspace.isSaved
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
func setServerReadOnlyForTests(_ readOnly: Bool) { _serverArgs.isReadOnly = readOnly }
func setServerConfigLocationForTests(_ path: String?) { _serverArgs.configLocation = path }
private func initServerArgs() {
    let args = CommandLine.arguments.slice(1...) ?? []
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        exit(EXIT_CODE_ZERO, out: serverHelp)
    }
    var index = 0
    while index < args.count {
        let current = args[index]
        index += 1
        switch current {
            case "--version", "-v":
                exit(EXIT_CODE_ZERO, out: "\(aeroSpaceAppVersion) \(gitHash)")
            case "--config-path":
                switch args.getOrNil(atIndex: index) {
                    case let arg?: unsafe _serverArgs.configLocation = arg
                    case nil: exit(EXIT_CODE_TWO, err: "Missing <path> in --config-path flag")
                }
                index += 1
            case "--read-only": // todo rename to '--disabled' and unite with disabled feature
                unsafe _serverArgs.isReadOnly = true
            case "-NSDocumentRevisionsDebugMode" where isDebug:
                // Skip Xcode CLI args.
                // Usually it's '-NSDocumentRevisionsDebugMode NO'/'-NSDocumentRevisionsDebugMode YES'
                while args.getOrNil(atIndex: index)?.starts(with: "-") == false { index += 1 }
            default:
                exit(EXIT_CODE_TWO, err: "Unrecognized flag \(args.first.orDie().singleQuoted)")
        }
    }
    if let path = serverArgs.configLocation, !FileManager.default.fileExists(atPath: path) {
        exit(EXIT_CODE_TWO, err: "\(path) doesn't exist")
    }
}
