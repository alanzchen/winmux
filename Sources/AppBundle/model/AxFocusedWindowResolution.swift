import AppKit

/// A focused AX reference may be a sheet or an accessory control that reports its
/// owner's CGWindowID. Only an independent window may supply a registry entry.
enum AxFocusedWindowResolution {
    case existing(UInt32)
    case newWindow(UInt32, any AxUiElementMock)
    case transient
    case unavailable
}

func resolveAxFocusedWindow(
    _ focused: any AxUiElementMock,
    isRegistered: (UInt32) -> Bool,
    appWindows: () -> [WindowIdAndAxUiElementMock],
) -> AxFocusedWindowResolution {
    if focused.isAttachedTransientHeuristic() { return .transient }
    guard let windowId = focused.containingWindowId() else { return .unavailable }
    if isRegistered(windowId) { return .existing(windowId) }

    // Prefer the application's canonical AXWindows entry over a focused proxy.
    if let canonical = appWindows().first(where: {
        $0.windowId == windowId && !$0.ax.isAttachedTransientHeuristic()
    }) {
        return .newWindow(windowId, canonical.ax)
    }

    // AXWindows can lag a creation notification. A window directly owned by the
    // application is sufficient evidence while enumeration catches up. Missing
    // ownership information is retried by the next refresh, not guessed.
    if focused.get(Ax.roleAttr) == kAXWindowRole,
       focused.get(Ax.parentAttr)?.get(Ax.roleAttr) == kAXApplicationRole
    {
        return .newWindow(windowId, focused)
    }
    return .unavailable
}

extension AxUiElementMock {
    /// Positive evidence of attached UI takes precedence over focus, window level,
    /// or window buttons. Modal state alone is deliberately insufficient: ordinary
    /// standalone dialogs and utility windows must remain manageable.
    func isAttachedTransientHeuristic() -> Bool {
        if let role = get(Ax.roleAttr), role != kAXWindowRole, role != kAXUnknownRole {
            return true
        }
        var ancestor = get(Ax.parentAttr)
        // ViewBridge may insert groups between a sheet and its owner. Bound the
        // walk because incomplete or cyclic accessibility trees are possible.
        for _ in 0 ..< 8 {
            guard let current = ancestor, let role = current.get(Ax.roleAttr) else { return false }
            if role == kAXWindowRole || role == kAXSheetRole || role == kAXMenuRole { return true }
            if role == kAXApplicationRole { return false }
            ancestor = current.get(Ax.parentAttr)
        }
        return false
    }
}

func debugTransientAxReference(_ element: any AxUiElementMock, appBundleId: String?, source: String) {
    guard isDebug else { return }
    debugFocusLog(
        "transient-ax source=\(source) app=\(appBundleId ?? "nil") windowId=\(element.containingWindowId()?.description ?? "nil") role=\(element.get(Ax.roleAttr) ?? "nil") subrole=\(element.get(Ax.subroleAttr) ?? "nil") parentRole=\(element.get(Ax.parentAttr)?.get(Ax.roleAttr) ?? "nil")"
    )
}
