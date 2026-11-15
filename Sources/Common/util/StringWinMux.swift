/// WinMux wording for `String.interpolate` (hook `appName` in StringEx.swift).
func winMuxMissingEnvVariableMessage(_ name: String) -> String {
    "Env variable '\(name)' isn't presented in WinMux.app env vars, "
        + "or not available for interpolation (because it's mutated)"
}
