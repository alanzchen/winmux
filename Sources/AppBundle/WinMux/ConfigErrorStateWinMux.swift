import Common
import Foundation

/// Config error state (docs/upstream-sync.md, S3 review fixes, D-S3-1).
///
/// - A reload whose config has any error keeps the live config once a config without errors has been applied in this
///   run. Until then (startup) it applies what parses, as upstream does.
/// - While the last reload found errors, the menu shows a persistent item with the details, and no automatic config
///   write-back runs: those writers assume the live config is the file's complete reading. Explicit user edits still go
///   through the validated writer.
@MainActor var hasAppliedConfigWithoutErrors = false
@MainActor var configErrorsPending = false

/// Automatic writers (orphaned-label cleanup, a new project's default label, project-order pruning) skip their write.
@MainActor var configWriteBackSuspended: Bool { configErrorsPending }

/// Loads the user's config as WinMux starts. A config with minor errors is applied (upstream 61f0eac9); one that
/// isn't is replaced by the defaults, while the user's config stays the one watched and edited, so fixing it
/// reloads it and clears this error state.
@MainActor func loadConfigAtStartup(bootstrappedConfigUrl: URL?) async throws {
    let userConfig = try await reloadConfig(forceConfigUrl: bootstrappedConfigUrl)
    if userConfig.appliedConfig { return }
    let userConfigErrors = TrayMenuModel.shared.configErrorDetails
    let fallback = try await reloadConfig(forceConfigUrl: defaultConfigUrl, standingInFor: userConfig.configUrl)
    // The defaults stand in for the user's config: its errors stay in the menu, automatic write-back stays
    // suspended, and the user's next config that parses still loads (D-S3-1).
    hasAppliedConfigWithoutErrors = false
    configErrorsPending = true
    TrayMenuModel.shared.configErrorDetails = userConfigErrors
    TrayMenuModel.shared.lastReloadConfigContainedWarnings = true
    check(
        fallback.appliedConfig && fallback.isOk,
        """
        Can't load default config. Your installation is probably corrupted.
        Please don't modify '\(defaultConfigUrl)'

        \(fallback.stdout)
        """,
    )
}

/// A fresh process's state, for tests.
@MainActor func resetConfigErrorStateForTests() {
    hasAppliedConfigWithoutErrors = false
    configErrorsPending = false
    TrayMenuModel.shared.configErrorDetails = nil
}

/// The persistent menu item's title: in Chinese when the user's language is, as the coordinator specified.
let configHasErrorsMenuTitle = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "配置有错误" : "Config Has Errors"
