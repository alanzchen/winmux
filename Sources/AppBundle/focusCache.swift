import Common
import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

@MainActor
func resetFocusCacheForTests() {
    lastKnownNativeFocusedWindowId = nil
}

@MainActor var lastKnownNativeFocusedWindowIdForTests: UInt32? {
    get { lastKnownNativeFocusedWindowId }
    set { lastKnownNativeFocusedWindowId = newValue }
}

/// A window set aside as not presentable, or brought back, is never what a cached native focus names: forgotten here, so
/// the native focus read next decides afresh (`setAsideNotPresentableWindow`, `bringBackPresentableWindows`).
@MainActor func forgetCachedNativeFocus(of window: Window) {
    if lastKnownNativeFocusedWindowId == window.windowId { lastKnownNativeFocusedWindowId = nil }
    if let app = window.app as? MacApp, app.lastNativeFocusedWindowId == window.windowId { app.lastNativeFocusedWindowId = nil }
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?, preserveLogicalFocus: Bool = false) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    // Set aside as not presentable, it can't take focus yet: it's brought back first, then this runs again for it
    // (`runHeavyCompleteRefreshSession`). Recorded now, it would never take focus.
    if nativeFocused?.isSetAsideAsNotPresentable == true {
        return
    }
    let lastKnownNativeFocusedWindowIdBefore = lastKnownNativeFocusedWindowId
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        if !preserveLogicalFocus { _ = nativeFocused?.focusWindow() }
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId
    debugFocusLog(
        "updateFocusCache event=\(refreshSessionEvent.prettyDescription) nativeFocused=\(nativeFocused?.windowId.description ?? "nil") lastKnownNative=\(lastKnownNativeFocusedWindowIdBefore?.description ?? "nil") -> \(lastKnownNativeFocusedWindowId?.description ?? "nil") logicalFocus=\(debugDescribe(focus))"
    )
}
