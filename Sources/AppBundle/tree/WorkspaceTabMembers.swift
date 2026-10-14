import AppKit

/// Where a window that belongs to a tab is now. Laid out and floating windows are on screen; the
/// others still belong to the tab, which keeps its place for them, but aren't shown in it.
enum WorkspaceTabMemberState: String, Equatable, Sendable {
    case laidOut
    case floating
    case hiddenWithApp
    case nativeFullscreen
    case minimized

    var isOffscreen: Bool {
        switch self {
            case .laidOut, .floating: false
            case .hiddenWithApp, .nativeFullscreen, .minimized: true
        }
    }
}

struct WorkspaceTabMember {
    let window: Window
    let state: WorkspaceTabMemberState
}

/// Every window that belongs to `tab`, each once, in a stable order: laid out, floating, hidden with
/// its app, in native full screen, then minimized from it. The one answer to "which windows are
/// this tab's" for what lists a tab, shows it and closes it: a tab is listed while it has any
/// (`workspaceHasLifecycleWindows`), and closing it means all of them.
@MainActor
func workspaceTabMembers(_ tab: Workspace) -> [WorkspaceTabMember] {
    var seen: Set<UInt32> = []
    var members: [WorkspaceTabMember] = []
    func add(_ windows: [Window], _ state: WorkspaceTabMemberState) {
        for window in windows where window.isBound && seen.insert(window.windowId).inserted {
            members.append(WorkspaceTabMember(window: window, state: state))
        }
    }
    add(tab.rootTilingContainer.allLeafWindowsRecursive, .laidOut)
    add(tab.floatingWindows, .floating)
    add(tab.existingMacOsNativeHiddenAppsWindowsContainer?.allLeafWindowsRecursive ?? [], .hiddenWithApp)
    add(tab.existingMacOsNativeFullscreenWindowsContainer?.allLeafWindowsRecursive ?? [], .nativeFullscreen)
    add(workspaceOwnedMinimizedWindows(tab), .minimized)
    return members
}

/// Whether `window` belongs to `tab` now, in whichever state.
@MainActor
func workspaceTabOwns(_ tab: Workspace, _ window: Window) -> Bool {
    workspaceTabMembers(tab).contains { $0.window === window }
}

/// A tab none of whose windows is shown in it, clicked: the first of them comes back the way its
/// state allows, a hidden app shown again, a minimized window restored, a full-screen window found
/// in its own Space, never taken out of full screen. If one is shown in it by now, the tab is only shown.
@MainActor
func showWorkspaceSidebarOffscreenTab(_ name: String, targetMonitorScopeId: String?) {
    runWorkspaceSidebarSession {
        guard let tab = Workspace.existing(byName: name) else { return }
        let members = workspaceTabMembers(tab)
        guard !members.contains(where: { !$0.state.isOffscreen }), let first = members.first else {
            _ = focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId)
            return
        }
        let window = first.window
        switch first.state {
            case .hiddenWithApp:
                if await showHiddenWorkspaceSidebarWindow(window), workspaceTabOwns(tab, window) {
                    focusWindowFromSidebarNow(window.windowId, targetMonitorScopeId: targetMonitorScopeId, keepsPointer: false)
                } else {
                    workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                        "\(window.app.name ?? "The app") stayed hidden, or its window moved meanwhile.")
                }
            case .minimized:
                if await workspaceSidebarRestoreMinimizedWindow(window) {
                    // macOS restores it, and WinMux puts it back in the tab it was minimized from.
                    _ = focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId)
                } else {
                    workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                        "\(window.app.name ?? "The window") stayed minimized. Restore it from the Dock.")
                }
            case .nativeFullscreen:
                if !window.focusWindow() { _ = tab.focusWorkspace() }
            case .laidOut, .floating:
                break
        }
        await updateWorkspaceSidebarModel()
    }
}

// MARK: - Closing a tab means all its windows

/// What closing some tabs closes, decided before anything is asked or closed: each tab's windows
/// then, by identity and state. Only these are closed, and only while each still belongs to its tab.
@MainActor
struct WorkspaceTabClosePlan {
    let tabs: [(tab: Workspace, members: [WorkspaceTabMember])]

    init(_ tabs: [Workspace]) {
        self.tabs = tabs.map { ($0, workspaceTabMembers($0)) }
    }

    var windowCount: Int { tabs.reduce(0) { $0 + $1.members.count } }
    var offscreen: [WorkspaceTabMember] { tabs.flatMap { $0.members.filter(\.state.isOffscreen) } }

    /// The question to ask first, if any. Whenever a window that isn't on screen would close, always,
    /// listing them: an app's name and its state, never a window's title. Otherwise, as before, only
    /// when there are more windows than tabs (`multipleWindowsMessage`).
    func confirmation(multipleWindowsMessage: String) -> (message: String, informative: String)? {
        let away = offscreen
        let saves = "Each app may ask you to save changes."
        guard away.isEmpty else {
            let count = windowCount
            let message = tabs.count == 1
                ? "Close this tab and its \(count == 1 ? "window" : "\(count) windows")?"
                : "Close \(tabs.count) tabs and their \(count) windows?"
            let shown = away.prefix(8).map { member in
                let app = member.window.app.name ?? member.window.app.rawAppBundleId ?? "An app"
                return switch member.state {
                    case .hiddenWithApp: "• \(app): hidden with its app"
                    case .minimized: "• \(app): minimized"
                    case .nativeFullscreen: "• \(app): in full screen. Closing it also ends its full-screen space."
                    case .laidOut, .floating: "• \(app)"
                }
            }
            let more = away.count > 8 ? ["• and \(away.count - 8) more"] : []
            let lead = away.count == 1 ? "This includes a window that isn't on screen:" : "This includes \(away.count) windows that aren't on screen:"
            return (message, ([lead] + shown + more + [saves]).joined(separator: "\n"))
        }
        guard windowCount > tabs.count else { return nil }
        return (multipleWindowsMessage, "This closes the application windows. \(saves)")
    }
}

/// Asks before a Close, with Cancel first; gives whether to go on. Tests replace it.
@MainActor
var workspaceTabCloseConfirm: @MainActor (_ message: String, _ informative: String) -> Bool = { message, informative in
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informative
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Close Windows")
    NSApp.activate(ignoringOtherApps: true)
    alert.window.level = .popUpMenu
    return alert.runModal() == .alertSecondButtonReturn
}

/// Closes `members` of `tab`, each only if it's still the same window and still the tab's. A window
/// that left its screen since without the user having agreed to close windows off screen is left
/// open. A save sheet or a refused close stops it, and that window comes forward. Gives whether
/// nothing stopped it, and how many were left open because they'd changed.
@MainActor
func closeWorkspaceTabMembers(_ members: [WorkspaceTabMember], in tab: Workspace, offscreenAgreed: Bool,
                              requestClose: @MainActor (Window) async -> Bool) async -> (finished: Bool, leftOpen: Int) {
    // As any close of a tab's windows from the sidebar: what Undo would put back is gone.
    WorkspaceSidebarTabUndo.shared.clear()
    var leftOpen = 0
    for member in members {
        let window = member.window
        guard Window.get(byId: window.windowId) === window,
              let now = workspaceTabMembers(tab).first(where: { $0.window === window }) else { continue }
        if now.state.isOffscreen, !offscreenAgreed {
            leftOpen += 1
            continue
        }
        if !(await requestClose(window)) {
            if Window.get(byId: window.windowId) === window { _ = window.focusWindow() }
            return (false, leftOpen)
        }
    }
    return (true, leftOpen)
}

@MainActor
func showWorkspaceTabCloseLeftOpen(_ count: Int) {
    guard count > 0 else { return }
    workspaceSidebarPinRecallNotice("Some windows stayed open",
        count == 1 ? "A window left the screen while the tab was closing, so it wasn't closed."
            : "\(count) windows left the screen while their tabs were closing, so they weren't closed.")
}
