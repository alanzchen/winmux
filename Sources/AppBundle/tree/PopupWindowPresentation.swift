/// Preserve the first observation across refreshes: delayed classification must
/// not turn a startup/restored window into a newly opened window.
struct PopupWindowPresentationState {
    let firstSeenDuringStartup: Bool
    let firstSeenInActiveApp: Bool
    var wasRestored = false
    private var hasPendingPromotion: Bool

    init(firstSeenDuringStartup: Bool, firstSeenInActiveApp: Bool, wasInitiallyPopup: Bool) {
        self.firstSeenDuringStartup = firstSeenDuringStartup
        self.firstSeenInActiveApp = firstSeenInActiveApp
        self.hasPendingPromotion = wasInitiallyPopup
    }

    mutating func consume() -> Bool {
        defer { hasPendingPromotion = false }
        return hasPendingPromotion && !firstSeenDuringStartup && firstSeenInActiveApp && !wasRestored
    }
}

@MainActor
func runCallbacksAfterPopupPromotion(_ window: Window, mayPresent: Bool) async throws {
    let focusBeforeCallbacks = focusChangeGeneration
    let detectedIn = window.nodeWorkspace
    try await tryOnWindowDetected(window)
    moveNewWindowToNewWorkspaceIfNeeded(window, detectedIn: detectedIn, isNewRegularWindow: window.wasOpenedRecently)
    if mayPresent {
        newFloatingWindowPresentation?.recordDetection(
            window,
            wasRestored: false,
            focusGenerationBeforeCallbacks: focusBeforeCallbacks,
        )
    }
}
