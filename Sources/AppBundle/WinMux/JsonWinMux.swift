import Common

extension Json {
    /// TOML floats in WinMux's config (opacities, magnification); upstream's config has none.
    var asDoubleOrNil: Double? {
        if case .double(let value) = self { value } else { nil }
    }
}
