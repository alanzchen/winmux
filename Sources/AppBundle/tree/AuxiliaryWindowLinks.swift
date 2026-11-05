import Foundation

// RED skeleton: the entry points the restart tests call. Not implemented yet.

/// Where the links are kept between WinMux's runs. Nil in unit tests unless a test sets it.
@MainActor var auxiliaryWindowLinksURL: @MainActor () -> URL? = { nil }

@MainActor
func loadAuxiliaryWindowLinksForStartup() {}

@MainActor
func recoverAuxiliaryWindowLinks() {}
