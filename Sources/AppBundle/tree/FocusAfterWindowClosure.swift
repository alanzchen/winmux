import Foundation

extension Window {
    /// A window that closed leaves the tree, and focus moves on as closing it should.
    @MainActor
    func removeClosedWindowFromTree() {
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let currentFocus = focus
        let previousFocus = prevFocus
        let previousPreviousFocus = prevPrevFocus
        let refreshSnapshot = refreshSessionFocusSnapshot
        let refreshSnapshotCloseFallback = refreshSnapshot?.fallbackWhenFocusedWindowCloses?.liveOrNil
        let refreshSnapshotPreviousFocus = refreshSessionFocusSnapshot?.prevFocus?.liveOrNil
        let refreshSnapshotPreviousPreviousFocus = refreshSessionFocusSnapshot?.prevPrevFocus?.liveOrNil
        debugFocusLog(
            "MacWindow.garbageCollect closing=\(windowId) currentFocus=\(debugDescribe(currentFocus)) prev=\(debugDescribe(previousFocus)) prevPrev=\(debugDescribe(previousPreviousFocus)) snapshot=\(debugDescribe(refreshSnapshot))"
        )
        if let replacementFocus = focusAfterWindowClosure(
            closingWindow: self,
            deadWindowWorkspace: deadWindowWorkspace,
            currentFocus: currentFocus,
            previousFocus: previousFocus,
            previousPreviousFocus: previousPreviousFocus,
            refreshSnapshotCloseFallback: refreshSnapshotCloseFallback,
            refreshSnapshotPreviousFocus: refreshSnapshotPreviousFocus,
            refreshSnapshotPreviousPreviousFocus: refreshSnapshotPreviousPreviousFocus,
            previousFocusedWorkspace: prevFocusedWorkspace,
            previousFocusedWorkspaceDate: prevFocusedWorkspaceDate,
        ) {
            switch parent.cases {
                case .tilingContainer, .workspace, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    debugFocusLog("MacWindow.garbageCollect replacement closing=\(windowId) replacement=\(debugDescribe(replacementFocus))")
                    _ = setFocus(to: replacementFocus)
                    if replacementFocus.windowOrNil != currentFocus.windowOrNil {
                        replacementFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer:
                    break // Don't switch back on popup destruction
            }
        }
    }
}

@MainActor
func focusAfterWindowClosure(
    closingWindow: Window,
    deadWindowWorkspace: Workspace?,
    currentFocus: LiveFocus,
    previousFocus: LiveFocus?,
    previousPreviousFocus: LiveFocus?,
    refreshSnapshotCloseFallback: LiveFocus?,
    refreshSnapshotPreviousFocus: LiveFocus?,
    refreshSnapshotPreviousPreviousFocus: LiveFocus?,
    previousFocusedWorkspace: Workspace?,
    previousFocusedWorkspaceDate: Date,
    now: Date = .now,
) -> LiveFocus? {
    guard let deadWindowWorkspace else { return nil }
    guard deadWindowWorkspace == currentFocus.workspace ||
        deadWindowWorkspace == previousFocusedWorkspace && previousFocusedWorkspaceDate.distance(to: now) < 1
    else {
        debugFocusLog("focusAfterWindowClosure closing=\(closingWindow.windowId) skipped currentFocus=\(debugDescribe(currentFocus)) previousFocusedWorkspace=\(previousFocusedWorkspace?.name ?? "nil")")
        return nil
    }

    // In Tabs mode the tab closes with its last window and the next tab takes over. The tab
    // was the one in use if focus was on it when this refresh began, even if focus has left
    // since: macOS focuses the app's other window, or another app's once the app quits, and
    // syncing focus from macOS has already brought that window's tab forward.
    let wasTabInUse = deadWindowWorkspace == currentFocus.workspace ||
        refreshSnapshotCloseFallback?.workspace == deadWindowWorkspace
    if wasTabInUse, let nextTab = workspaceTabAfterLastWindowClosed(deadWindowWorkspace) {
        debugFocusLog("focusAfterWindowClosure closing=\(closingWindow.windowId) lastWindowOfTab next=\(nextTab.name)")
        return nextTab.toLiveFocus()
    }

    let replacement = FocusAfterWindowClosureReplacement(closingWindow: closingWindow, deadWindowWorkspace: deadWindowWorkspace)
    if let snapshotTabFocus = replacement.snapshotTabGroupFocus(
        closeFallback: refreshSnapshotCloseFallback,
        previousFocus: refreshSnapshotPreviousFocus,
        previousPreviousFocus: refreshSnapshotPreviousPreviousFocus,
        currentFocus: currentFocus,
    ) {
        return snapshotTabFocus
    }

    if replacement.shouldPreferSnapshotCloseFallback(
        closeFallback: refreshSnapshotCloseFallback,
        currentFocus: currentFocus,
        previousFocus: refreshSnapshotPreviousFocus,
    ) {
        debugFocusLog(
            "focusAfterWindowClosure closing=\(closingWindow.windowId) preferSnapshotCloseFallback=\(debugDescribe(refreshSnapshotCloseFallback)) current=\(debugDescribe(currentFocus)) snapshotPrev=\(debugDescribe(refreshSnapshotPreviousFocus))"
        )
        return refreshSnapshotCloseFallback
    }

    let fallbackHistory: [LiveFocus?] = [
        refreshSnapshotCloseFallback,
        refreshSnapshotPreviousFocus,
        previousFocus,
        (refreshSnapshotPreviousFocus?.windowOrNil == closingWindow) ? refreshSnapshotPreviousPreviousFocus : nil,
        (previousFocus?.windowOrNil == closingWindow) ? previousPreviousFocus : nil,
    ]
    for candidate in fallbackHistory where replacement.isValid(candidate) {
        debugFocusLog(
            "focusAfterWindowClosure closing=\(closingWindow.windowId) choseCandidate=\(debugDescribe(candidate)) current=\(debugDescribe(currentFocus)) snapshotCloseFallback=\(debugDescribe(refreshSnapshotCloseFallback)) snapshotPrev=\(debugDescribe(refreshSnapshotPreviousFocus)) snapshotPrevPrev=\(debugDescribe(refreshSnapshotPreviousPreviousFocus)) prev=\(debugDescribe(previousFocus)) prevPrev=\(debugDescribe(previousPreviousFocus))"
        )
        return candidate
    }

    let fallback = deadWindowWorkspace.toLiveFocus()
    debugFocusLog("focusAfterWindowClosure closing=\(closingWindow.windowId) defaultFallback=\(debugDescribe(fallback))")
    return fallback
}
