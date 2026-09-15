import AppKit
import Common

@TaskLocal
var newFloatingWindowPresentation: NewFloatingWindowPresentation? = nil

/// New-window presentation belongs to the refresh that discovered the window. A cancelled
/// refresh, a restore, or a later focus choice must not leave a raise request for another session.
@MainActor
final class NewFloatingWindowPresentation {
    private let isStartup: Bool
    private let frontmostAppPid: Int32?
    private var candidates: [UInt32: Window] = [:]
    private var detectedWindowIds: Set<UInt32> = []
    private var nativeWindowIdBeforeLayout: UInt32?
    private var focusGenerationBeforeLayout: UInt64?
    private(set) var callbacksChangedFocus = false
    private var wasConsumed = false
    private(set) var suppressFocusSync = false

    init(isStartup: Bool, frontmostAppPid: Int32?) {
        self.isStartup = isStartup
        self.frontmostAppPid = frontmostAppPid
    }

    func recordDetection(_ window: Window, wasRestored: Bool, focusGenerationBeforeCallbacks: UInt64) {
        guard !isStartup, !wasRestored, !wasConsumed else { return }
        if focusChangeGeneration != focusGenerationBeforeCallbacks {
            callbacksChangedFocus = true
            return
        }
        guard window.app.pid == frontmostAppPid else { return }
        detectedWindowIds.insert(window.windowId)
        guard isEligible(window) else { return }
        candidates[window.windowId] = window
    }

    /// Native focus synchronization is expected to change logical focus at session entry;
    /// only changes after this point (or inside detection callbacks) supersede presentation.
    func recordNativeFocusBeforeLayout(_ window: Window?) {
        nativeWindowIdBeforeLayout = window?.windowId
        focusGenerationBeforeLayout = focusChangeGeneration
    }

    func consumeCandidate(frontmostAppPid currentAppPid: Int32?, nativeObservation: NativeFocusedWindowObservation) -> Window? {
        guard !wasConsumed else { return nil }
        wasConsumed = true
        defer {
            candidates.removeAll()
            detectedWindowIds.removeAll()
        }
        guard !Task.isCancelled, !callbacksChangedFocus,
              focusGenerationBeforeLayout == focusChangeGeneration
        else { return nil }
        guard frontmostAppPid == currentAppPid,
              case .window(let nativeWindowId) = nativeObservation
        else {
            suppressFocusSync = true
            return nil
        }

        let eligible = candidates.values.filter { window in
            Window.get(byId: window.windowId) === window && isEligible(window)
        }
        if let nativeCandidate = eligible.first(where: { $0.windowId == nativeWindowId }) {
            return nativeCandidate
        }
        // A newer native focus choice wins. If several floats appeared together, only the
        // app's focused window can disambiguate them; dictionary/enumeration order cannot.
        guard nativeWindowId == nativeWindowIdBeforeLayout, !detectedWindowIds.contains(nativeWindowId) else {
            suppressFocusSync = true
            return nil
        }
        guard eligible.count == 1 else { return nil }
        return eligible.first
    }

    func presentAfterLayout() async throws -> Bool {
        guard let app = candidates.values.first?.app as? MacApp else { return false }
        let observation = try await app.observeFocusedWindowId()
        try checkCancellation()
        let currentApp = NSWorkspace.shared.frontmostApplication
        guard !app.nsApp.isHidden, !app.hasActiveTransientNativeFocus else {
            suppressFocusSync = true
            return false
        }
        guard let window = consumeCandidate(frontmostAppPid: currentApp?.processIdentifier, nativeObservation: observation) as? MacWindow,
              case .window(let expectedNativeWindowId) = observation
        else { return false }
        let focusGenerationBeforeRequest = focusChangeGeneration
        let wasAccepted = try await app.presentNewFloatingWindow(window.windowId, expectedNativeFocusedWindowId: expectedNativeWindowId)
        return finishPresentation(
            window, wasAccepted: wasAccepted, focusGenerationBeforeRequest: focusGenerationBeforeRequest,
            frontmostAppPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        )
    }

    func finishPresentation(_ window: Window, wasAccepted: Bool, focusGenerationBeforeRequest: UInt64, frontmostAppPid currentAppPid: Int32?) -> Bool {
        guard wasAccepted, !Task.isCancelled, focusChangeGeneration == focusGenerationBeforeRequest,
              window.app.pid == currentAppPid, Window.get(byId: window.windowId) === window,
              isEligible(window), window.focusWindow()
        else {
            suppressFocusSync = true
            return false
        }
        debugFocusLog("newFloatingWindow.present window=\(window.windowId) app=\(window.app.pid)")
        return true
    }

    private func isEligible(_ window: Window) -> Bool {
        window.isFloating && window.nodeWorkspace?.isVisible == true &&
            !window.isHiddenInCorner && window.lastKnownNativeMinimized != true &&
            window.lastKnownNativeFullscreen != true
    }
}
