import AppKit
import Common

/// Becomes true once the initial workspace model exists. Config parsing happens earlier during
/// launch, when scheduling a live layout pass would race app initialization.
@MainActor var isWinMuxRuntimeReady = false

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        let result = try await reloadConfig(args: args)
        if !result.stdout.isEmpty {
            io.out(result.stdout)
        }
        if !result.stderr.isEmpty {
            io.err(result.stderr)
        }
        return .from(bool: result.isOk)
    }
}

struct ReloadConfigResult {
    let isOk: Bool
    /// The config was applied: it had no severe error and this wasn't a dry run.
    let appliedConfig: Bool
    /// The file read.
    let configUrl: URL
    let stdout: String
    let stderr: String
}

/// `standingInFor`: the file read stands in for this config, which couldn't be applied. Its values are
/// applied, and this one stays `configUrl`: the config WinMux watches, reloads and edits.
@MainActor func reloadConfig(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
    standingInFor requestedConfigUrl: URL? = nil,
) async throws -> ReloadConfigResult {
    let result = readConfig(forceConfigUrl: forceConfigUrl)
    let parseResult = result.parseConfigResult
    let warningsAsErrors = args.warningsAsErrors

    var errors = parseResult.errors.map { $0.description(.error) }
    var warnings = parseResult.warnings.map { $0.description(.warning) }
    let containsWarnings = !parseResult.warnings.isEmpty

    // The CLI prints what the dialog shows: the file, the counts, then each diagnostic.
    let lines = errors + warnings
    let errorMsg = errors.isEmpty ? nil
        : failedToParseMsg(configUrl: result.configUrl, errorsCount: parseResult.errors.count, warningsCount: parseResult.warnings.count, lines: lines)
    let warningMsg = warningsAsErrors && errors.isEmpty && !warnings.isEmpty
        ? parsedWithWarningsMsg(configUrl: result.configUrl, warningsCount: parseResult.warnings.count, lines: lines) : nil
    if !args.noGui {
        switch true {
            case errorMsg != nil: showConfigMessage("WinMux Config Error", errorMsg.orDie(), containsWarnings: containsWarnings)
            case warningMsg != nil: showConfigMessage("WinMux Config Warnings", warningMsg.orDie(), containsWarnings: containsWarnings)
            default: MessageModel.shared.closeConfigErrorDetails()
        }
    }
    // D-S3-1: a config with any error keeps the live config once a config without errors has been applied in this
    // run; until then (startup) what parses is applied, as upstream 61f0eac9 does. A severe error (TOML syntax, an
    // unreadable or ambiguous file) is never applied.
    let hasErrors = !parseResult.errors.isEmpty
    let applied = !args.dryRun && parseResult.allowReloadConfig && (!hasErrors || !hasAppliedConfigWithoutErrors)
    if !args.dryRun {
        configErrorsPending = hasErrors
        TrayMenuModel.shared.configErrorDetails = errorMsg.map {
            Message(type: .config, description: "WinMux Config Error", body: $0)
        }
        // Also set for errors: the menu keeps an item until a clean reload.
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = containsWarnings || hasErrors
    }
    if applied {
        if !hasErrors { hasAppliedConfigWithoutErrors = true }
        resetHotKeys()
        config = parseResult.config
        configUrl = requestedConfigUrl ?? result.configUrl
        noteSavedWorkspaceConfigLoaded()
        try await activateMode(activeMode)
        syncStartAtLogin()
        applyReloadedConfigurationToRunningApp()
    }

    // Window rules are their own file: one that can't be used never stops the config, nor the config them.
    let windowRules = loadWindowRules()
    if !args.dryRun {
        activeWindowRules = windowRules.rules
        if errors.isEmpty, !windowRules.problems.isEmpty, !args.noGui {
            showConfigMessage("Window Rules", windowRules.problems.joined(separator: "\n"), containsWarnings: false)
        }
        syncConfigFileWatcher()
    }

    if warningsAsErrors {
        errors += warnings
        warnings = []
    }
    return ReloadConfigResult(
        isOk: errors.isEmpty,
        appliedConfig: applied,
        configUrl: result.configUrl,
        stdout: ([errorMsg ?? warningMsg].compactMap { $0 } + windowRules.problems).joined(separator: "\n"),
        stderr: warnings.joined(separator: "\n\n"),
    )
}

/// After the current main-actor turn, as before: startup's fallback to the default config runs first.
@MainActor private func showConfigMessage(_ description: String, _ body: String, containsWarnings: Bool) {
    Task { @MainActor in
        MessageModel.shared.message = Message(type: .config, description: description, body: body, containsWarnings: containsWarnings)
    }
}

private func failedToParseMsg(configUrl: URL, errorsCount: Int, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Failed to parse \(path). \(errorsCount) error(s). \(warningsCount) warning(s)"
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}

private func parsedWithWarningsMsg(configUrl: URL, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Parsed \(path) with \(warningsCount) warning(s). Feel free to close this window."
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}

/// Apply a newly loaded config to all running surfaces. This is intentionally part of config
/// reload rather than individual Settings controls, so GUI edits, config-editor saves, and
/// filesystem auto-reloads share the same live-update behavior.
@MainActor private func applyReloadedConfigurationToRunningApp() {
    WorkspaceSidebarPanel.refreshAll()
    WindowTabStripPanelController.shared.refresh()
    SecureInputPanel.shared.refresh()
    NotificationCenter.default.post(name: settingsConfigurationDidReload, object: nil)
    MCPServer.shared.apply(config.mcpServer)

    guard isWinMuxRuntimeReady else { return }
    scheduleCancellableCompleteRefreshSession(.configAutoReload)
}
