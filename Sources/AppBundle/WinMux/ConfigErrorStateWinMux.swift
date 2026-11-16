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

/// A fresh process's state, for tests.
@MainActor func resetConfigErrorStateForTests() {
    hasAppliedConfigWithoutErrors = false
    configErrorsPending = false
    TrayMenuModel.shared.configErrorDetails = nil
}

/// The persistent menu item's title: in Chinese when the user's language is, as the coordinator specified.
let configHasErrorsMenuTitle = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "配置有错误" : "Config Has Errors"
