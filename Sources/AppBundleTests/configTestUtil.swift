@testable import AppBundle

/// `parseConfig` as WinMux's tests read it before upstream S3: the config and its errors as `key: message` strings,
/// without the `[ERROR]` prefix the user sees (the golden fixtures pin that).
@MainActor
func parseConfigForTests(_ toml: String) -> (config: Config, errors: [String]) {
    let result = parseConfig(toml)
    return (result.config, result.errors.map { error in
        error.backtrace.description.isEmpty ? error.message : "\(error.backtrace): \(error.message)"
    })
}

extension ParseConfigResult {
    var strErrors: [String] { errors.map { $0.description(.error) } }
    var strWarnings: [String] { warnings.map { $0.description(.warning) } }
}
