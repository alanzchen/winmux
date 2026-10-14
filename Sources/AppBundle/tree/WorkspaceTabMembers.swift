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

/// Of a tab's `members`, its recognized auxiliary windows, in any state, whether listed under their
/// parent, left by it or lent away with it: a Close Tab closes them first and names them, so a draft
/// that asks to be saved stops it before anything else closes.
@MainActor
func workspaceTabAuxiliaryMembers(_ members: [WorkspaceTabMember]) -> [WorkspaceTabMember] {
    members.filter { AuxiliaryWindowRegistry.shared.role(of: $0.window) != nil }
}

/// Whether `window` belongs to `tab` now, in whichever state.
@MainActor
func workspaceTabOwns(_ tab: Workspace, _ window: Window) -> Bool {
    workspaceTabMembers(tab).contains { $0.window === window }
}

/// A tab none of whose windows is shown in it, clicked: the first of them comes back the way its
/// state allows, a hidden app shown again, a minimized window restored, a full-screen window found
/// in its own Space, never taken out of full screen. If one is shown in it by now, the tab is only shown.
/// Restoring takes a moment: the tab is shown only if then it's still the same tab with the same window,
/// still its, and the user hasn't chosen something else meanwhile.
@MainActor
@discardableResult
func showWorkspaceSidebarOffscreenTab(_ name: String, targetMonitorScopeId: String?) -> Task<Void, Never>? {
    let focusedAtClick = focus.workspace
    return runWorkspaceSidebarSession {
        guard let tab = Workspace.existing(byName: name) else { return }
        let members = workspaceTabMembers(tab)
        guard !members.contains(where: { !$0.state.isOffscreen }), let first = members.first else {
            _ = focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId)
            return
        }
        let window = first.window
        let appName = window.app.name ?? "The app"
        /// After the wait: the user's choice stands if it changed, and a window that moved stays where it is.
        @MainActor func mayShow() -> Bool {
            let choiceStands = focus.workspace === focusedAtClick || focus.workspace === tab
            guard choiceStands else { return false }
            guard Workspace.existing(byName: name) === tab, !tab.isArchived,
                  Window.get(byId: window.windowId) === window, workspaceTabOwns(tab, window)
            else {
                workspaceSidebarPinRecallNotice("The window moved meanwhile",
                    "\(appName)'s window is no longer in this tab, so it stayed where it is.")
                return false
            }
            return true
        }
        switch first.state {
            case .hiddenWithApp:
                let shown = await showHiddenWorkspaceSidebarWindow(window)
                guard mayShow() else { return }
                if shown {
                    focusWindowFromSidebarNow(window.windowId, targetMonitorScopeId: targetMonitorScopeId, keepsPointer: false)
                } else {
                    workspaceSidebarPinRecallNotice("Couldn't bring the window back", "\(appName) stayed hidden.")
                }
            case .minimized:
                let restored = await workspaceSidebarRestoreMinimizedWindow(window)
                guard mayShow() else { return }
                if restored {
                    // macOS restores it, and WinMux puts it back in the tab it was minimized from.
                    _ = focusWorkspaceFromSidebar(tab, targetMonitorScopeId: targetMonitorScopeId)
                } else {
                    workspaceSidebarPinRecallNotice("Couldn't bring the window back",
                        "\(appName)'s window stayed minimized. Restore it from the Dock.")
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

/// What closing a window means, by where it is: on screen, or out of sight in one way or another.
/// A window is closed only while this is still what it was when the user agreed.
enum WorkspaceTabCloseConsequence: Equatable {
    case onScreen, hiddenWithApp, minimized, nativeFullscreen

    init(_ state: WorkspaceTabMemberState) {
        self = switch state {
            case .laidOut, .floating: .onScreen
            case .hiddenWithApp: .hiddenWithApp
            case .minimized: .minimized
            case .nativeFullscreen: .nativeFullscreen
        }
    }
}

/// What closing some tabs closes, decided before anything is asked or closed: each tab's windows
/// then, by identity and state. Only these are closed, each only while it's still its tab's and in
/// the state the user agreed to close it in. In each tab, its auxiliary windows
/// (`workspaceTabAuxiliaryMembers`) come first, so a draft that asks to be saved stops the rest while
/// the window it came from is still open.
@MainActor
struct WorkspaceTabClosePlan {
    let tabs: [(tab: Workspace, members: [WorkspaceTabMember])]
    /// Of `tabs`' members, their recognized auxiliary windows, in plan order.
    let auxiliary: [WorkspaceTabMember]

    init(_ tabs: [Workspace]) {
        var auxiliary: [WorkspaceTabMember] = []
        self.tabs = tabs.map { tab in
            let members = workspaceTabMembers(tab)
            let opened = workspaceTabAuxiliaryMembers(members)
            auxiliary += opened
            return (tab, opened + members.filter { member in !opened.contains { $0.window === member.window } })
        }
        self.auxiliary = auxiliary
    }

    var windowCount: Int { tabs.reduce(0) { $0 + $1.members.count } }
    var offscreen: [WorkspaceTabMember] { tabs.flatMap { $0.members.filter(\.state.isOffscreen) } }

    /// "This includes 1 Mail compose window.", by app and kind, never a title.
    private var auxiliaryLine: String? {
        var counts: [(kind: String, count: Int)] = []
        for member in auxiliary {
            guard let role = AuxiliaryWindowRegistry.shared.role(of: member.window) else { continue }
            let kind = workspaceSidebarAuxiliaryWindowKind(role, appName: member.window.app.name ?? "An app")
            if let index = counts.firstIndex(where: { $0.kind == kind }) { counts[index].count += 1 } else { counts.append((kind, 1)) }
        }
        guard !counts.isEmpty else { return nil }
        let parts = counts.map { "\($0.count) \($0.kind)\($0.count == 1 ? "" : "s")" }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "This includes \(list)."
    }

    /// The question to ask first, if any. Whenever a window that isn't on screen would close, always:
    /// how many in each state, in full, then up to eight by app, never a window's title, and, whenever
    /// one is in full screen, that closing it ends its full-screen space. Whenever an auxiliary window
    /// would close, always too, naming how many of which kind. Otherwise, as before,
    /// only when there are more windows than tabs (`multipleWindowsMessage`).
    func confirmation(multipleWindowsMessage: String) -> (message: String, informative: String)? {
        let away = offscreen
        let saves = "Each app may ask you to save changes."
        let opened = auxiliaryLine.map { [$0] } ?? []
        guard away.isEmpty else {
            let count = windowCount
            let message = tabs.count == 1
                ? "Close this tab and its \(count == 1 ? "window" : "\(count) windows")?"
                : "Close \(tabs.count) tabs and their \(count) windows?"
            func number(_ state: WorkspaceTabMemberState) -> Int { away.count { $0.state == state } }
            let counts = [
                (number(.hiddenWithApp), "hidden with its app", "hidden with their app"),
                (number(.minimized), "minimized", "minimized"),
                (number(.nativeFullscreen), "in full screen", "in full screen"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
            let lead = (away.count == 1 ? "This includes a window that isn't on screen: "
                : "This includes \(away.count) windows that aren't on screen: ") + counts.joined(separator: ", ") + "."
            let shown = away.prefix(8).map { member in
                let app = member.window.app.name ?? member.window.app.rawAppBundleId ?? "An app"
                return switch member.state {
                    case .hiddenWithApp: "• \(app): hidden with its app"
                    case .minimized: "• \(app): minimized"
                    case .nativeFullscreen: "• \(app): in full screen"
                    case .laidOut, .floating: "• \(app)"
                }
            }
            let more = away.count > 8 ? ["• and \(away.count - 8) more"] : []
            let fullScreen = number(.nativeFullscreen) > 0
                ? ["Closing a window in full screen also ends its full-screen space."] : []
            return (message, ([lead] + shown + more + fullScreen + opened + [saves]).joined(separator: "\n"))
        }
        guard windowCount > tabs.count || !opened.isEmpty else { return nil }
        return (multipleWindowsMessage, (opened + ["This closes the application windows. \(saves)"]).joined(separator: "\n"))
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

/// A close the user agreed to for one window in one place, carried to the press itself: valid while
/// nothing has moved the window, changed its state or replaced it, checked on the app's own thread
/// right before its close button is pressed.
struct WorkspaceTabCloseAuthorization: Sendable {
    let windowId: UInt32
    let isStillValid: @Sendable () -> Bool
}

/// The authorization to close `member` now, or nil if it's no longer that window, in that tab, in the
/// state the user agreed to close it in.
@MainActor
func workspaceTabCloseAuthorization(_ member: WorkspaceTabMember, in tab: Workspace) -> WorkspaceTabCloseAuthorization? {
    let window = member.window
    guard Window.get(byId: window.windowId) === window, Workspace.existing(byName: tab.name) === tab, !tab.isArchived,
          let now = workspaceTabMembers(tab).first(where: { $0.window === window }),
          WorkspaceTabCloseConsequence(now.state) == WorkspaceTabCloseConsequence(member.state)
    else { return nil }
    let stamp = window.placementStamp
    let expected = stamp.current
    return WorkspaceTabCloseAuthorization(windowId: window.windowId, isStillValid: { stamp.current == expected })
}

enum WindowClosePress: Equatable, Sendable {
    case pressed
    /// No close button, or the press failed: the app didn't take it.
    case notPressed
    /// The window changed since the close was agreed to, so it wasn't pressed.
    case invalidated
}

enum WindowPresence: Equatable, Sendable {
    case present, absent
    /// The app couldn't say.
    case unknown
}

/// How a close went.
enum WindowCloseOutcome: Equatable, Sendable {
    case closed
    /// Pressed, and still open: a save sheet, or the app refused.
    case stillOpen
    /// Not pressed: no close button, or the press failed.
    case notPressed
    /// Not pressed: the window changed since the close was agreed to.
    case invalidated
    /// Pressed, and whether it closed couldn't be told.
    case unknown
}

/// What closing a native window takes: its press, the app's and the window server's word on whether
/// it's still there, and forgetting it once it's gone. Tests replace it with answers of their own.
struct WindowCloseIO {
    var press: @MainActor (_ isStillValid: @escaping @Sendable () -> Bool) async -> WindowClosePress
    var presence: @MainActor () async -> WindowPresence
    /// Whether the window server lists the window; nil when it gave no list.
    var windowServerHasWindow: @MainActor () -> Bool?
    var forget: @MainActor () -> Void
    var timeout: TimeInterval = 1.5
    var pause: @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
}

@MainActor
var workspaceTabCloseIO: @MainActor (Window) -> WindowCloseIO? = { window in
    guard let macWindow = window as? MacWindow else { return nil }
    let windowId = macWindow.windowId
    let app = macWindow.macApp
    return WindowCloseIO(
        press: { isStillValid in (try? await app.pressCloseButton(windowId, ifStillAuthorized: isStillValid)) ?? .notPressed },
        presence: { (try? await app.axWindowPresence(windowId)) ?? .unknown },
        windowServerHasWindow: { windowServerWindowIdsIfListed(pid: app.pid)?.contains(windowId) },
        forget: { macWindow.garbageCollect(skipClosedWindowsCache: true) })
}

/// Presses and watches until the window is gone, proven so by the app's own list of its windows or,
/// when the app can't answer, by the window server's. An answer that can't be read is never taken
/// for a closed window.
@MainActor
func observeWindowClose(_ io: WindowCloseIO, isStillValid: @escaping @Sendable () -> Bool) async -> WindowCloseOutcome {
    switch await io.press(isStillValid) {
        case .invalidated: return .invalidated
        case .notPressed: return .notPressed
        case .pressed: break
    }
    let deadline = ProcessInfo.processInfo.systemUptime + io.timeout
    var lastUnknown = false
    repeat {
        switch await io.presence() {
            case .absent: return .closed
            case .present: lastUnknown = false
            case .unknown:
                if io.windowServerHasWindow() == false { return .closed }
                lastUnknown = true
        }
        await io.pause()
    } while ProcessInfo.processInfo.systemUptime < deadline
    return lastUnknown ? .unknown : .stillOpen
}

/// Closes one window of a tab with what the user agreed to: the press waits for its app's turn and
/// checks the agreement right before it. Forgotten only once it's proven gone.
@MainActor
func workspaceTabCloseMember(_ window: Window, _ authorization: WorkspaceTabCloseAuthorization) async -> WindowCloseOutcome {
    guard let io = workspaceTabCloseIO(window) else {
        guard authorization.isStillValid() else { return .invalidated }
        window.closeAxWindow()
        return .closed
    }
    let outcome = await observeWindowClose(io, isStillValid: authorization.isStillValid)
    if outcome == .closed { io.forget() }
    return outcome
}

/// A close given as whether the window closed, as callers wrote them before: valid only while the
/// agreement holds when it's asked.
@MainActor
func workspaceTabClose(from requestClose: @escaping @MainActor (Window) async -> Bool)
    -> @MainActor (Window, WorkspaceTabCloseAuthorization) async -> WindowCloseOutcome
{
    { window, authorization in
        guard authorization.isStillValid() else { return .invalidated }
        return await requestClose(window) ? .closed : .stillOpen
    }
}

/// Closes `members` of `tab`, in order, each with the user's agreement for that window in that state
/// (`workspaceTabCloseAuthorization`). One that's gone, moved, changed state or been replaced since is
/// left alone and counted. One that doesn't close, or whose close can't be told, stops it all: an on-
/// screen window comes forward, as before, and for one out of sight the notice says what happened.
/// A tab out of sight is shown, and its windows put in their places, before any is pressed
/// (`placeWorkspaceTabMemberForClose`); `viewports` puts back what that replaced once all is done.
/// Gives whether nothing stopped it, and how many were left open because they'd changed.
@MainActor
func closeWorkspaceTabMembers(_ members: [WorkspaceTabMember], in tab: Workspace, viewports: WorkspaceTabCloseViewports,
                              close: @MainActor (Window, WorkspaceTabCloseAuthorization) async -> WindowCloseOutcome)
    async -> (finished: Bool, leftOpen: Int)
{
    // As any close of a tab's windows from the sidebar: what Undo would put back is gone.
    WorkspaceSidebarTabUndo.shared.clear()
    var leftOpen = 0
    for member in members {
        let window = member.window
        guard Window.get(byId: window.windowId) === window else { continue }
        guard let authorization = workspaceTabCloseAuthorization(member, in: tab) else {
            leftOpen += 1
            continue
        }
        switch await placeWorkspaceTabMemberForClose(member, in: tab, viewports: viewports) {
            case .inPlace:
                break
            case .changed:
                leftOpen += 1
                continue
            case .notShown:
                showWorkspaceTabCloseNotShown(window)
                return (false, leftOpen)
        }
        let outcome = await close(window, authorization)
        switch outcome {
            case .closed:
                continue
            case .invalidated:
                leftOpen += 1
                continue
            case .stillOpen, .notPressed, .unknown:
                showWorkspaceTabCloseStopped(window, in: tab, outcome: outcome)
                return (false, leftOpen)
        }
    }
    return (true, leftOpen)
}

/// When the user last pressed a key or a mouse button. Tests replace it.
@MainActor var workspaceTabCloseLastUserInput: @MainActor () -> TimeInterval? = {
    AuxiliaryWindowOriginEnvironment.native.lastUserInput()
}

/// What showing tabs out of sight to close their windows replaced: the tab each display showed, in
/// the project it showed it in, and the window or tab in use. One close of several tabs shares it,
/// and puts it back once, at the end.
@MainActor
final class WorkspaceTabCloseViewports {
    private let closing: [Workspace]
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let focusedWindow: Window?
    private let focusedWorkspace: Workspace
    private var displaced: [(display: CGPoint, workspace: Workspace, projectId: WorkspaceProjectId?)] = []

    init(closing: [Workspace]) {
        self.closing = closing
        focusedWindow = focus.windowOrNil
        focusedWorkspace = focus.workspace
    }

    var hasShownTabs: Bool { !displaced.isEmpty }

    /// Shows `tab` on its display, remembering what that display showed the first time it changes.
    func show(_ tab: Workspace) -> Bool {
        let monitor = tab.workspaceMonitor
        if !displaced.contains(where: { $0.display == monitor.rect.topLeftCorner }) {
            displaced.append((monitor.rect.topLeftCorner, monitor.activeWorkspace,
                winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)]?.contextProjectId))
        }
        return tab.focusWorkspace()
    }

    /// Once every window has closed: back on the window in use, or the tab in use's own window, in
    /// macOS too, since closing focused the next tab there and a refresh would follow that back; and
    /// each display showing the tab it showed, in the project it showed it in, unless that was one of
    /// those closed, whatever closing them chose instead. Nothing is put back when the user has pressed
    /// a key or clicked since the close began, choosing where to be, or when they were on an empty tab:
    /// with no window to focus in macOS, a refresh would undo it. It stays where closing left it then,
    /// as after closing the tab on screen.
    func restore() {
        guard hasShownTabs else { return }
        if let input = workspaceTabCloseLastUserInput(), input > startedAt { return }
        func isClosing(_ workspace: Workspace?) -> Bool { closing.contains { $0 === workspace } }
        func isLive(_ workspace: Workspace) -> Bool {
            Workspace.existing(byName: workspace.name) === workspace && !workspace.isArchived && !isClosing(workspace)
        }
        let window: Window? = if let window = focusedWindow, Window.get(byId: window.windowId) === window,
                                 !isClosing(window.nodeWorkspace) { window }
            else if isLive(focusedWorkspace) { focusedWorkspace.toLiveFocus().windowOrNil } else { nil }
        guard let window else { return }
        for (display, workspace, projectId) in displaced where isLive(workspace) {
            guard let monitor = monitors.first(where: { $0.rect.topLeftCorner == display }) else { continue }
            let shownProjectId = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)]?.contextProjectId
            guard monitor.activeWorkspace !== workspace || projectId.map({ $0 != shownProjectId }) == true else { continue }
            // Shown again, not chosen: no project's remembered tab changes.
            _ = monitor.setActiveWorkspace(workspace, contextProjectId: projectId, isChosen: false)
        }
        if window.focusWindow() { window.nativeFocus() }
    }
}

enum WorkspaceTabMemberPlacement: Equatable {
    case inPlace
    /// It left the tab, or was replaced, meanwhile: left alone, as any window that changed.
    case changed
    /// It couldn't be shown in its tab.
    case notShown
}

/// A window of a tab out of sight waits parked in a corner, and an app that asks to save puts its
/// window back, once answered, where it was when it asked: pressed there, the question and then the
/// window would stay out of sight. So its tab is shown and laid out, and the moves have reached the
/// app, before it's pressed; its frame, read back, has to be on a display. Every parkable window's
/// queued moves are made first, as the press cancels one still waiting.
@MainActor
func placeWorkspaceTabMemberForClose(_ member: WorkspaceTabMember, in tab: Workspace,
                                     viewports: WorkspaceTabCloseViewports) async -> WorkspaceTabMemberPlacement
{
    let window = member.window
    guard !member.state.isOffscreen, window is any WorkspaceWindowVisibility, window.nodeWorkspace === tab,
          !shouldKeepWindowHiddenForVisibleWorkspaceLayout(window) else { return .inPlace }
    if tab.isVisible, !window.isHiddenInCorner, !viewports.hasShownTabs {
        // On screen all along, as any close before; a move still queued is made first, and the
        // window looked at again after it: a move back from the corner may not have taken. One that
        // isn't seen on a display, or can't be seen at all, goes the way a parked one does.
        try? await window.app.waitForPendingFrameWrites()
        let frame = try? await window.getAxRect()
        guard Window.get(byId: window.windowId) === window, window.nodeWorkspace === tab else { return .changed }
        if tab.isVisible, !window.isHiddenInCorner, let frame, isOnADisplay(frame) { return .inPlace }
    }
    if !tab.isVisible { guard viewports.show(tab) else { return .notShown } }
    // A newer layout may take over before reaching the window: once more lets it settle.
    for _ in 0 ..< 2 {
        try? await layoutWorkspaces()
        try? await window.app.waitForPendingFrameWrites()
        // Read after its moves were made, and checked after the read: the last look before the press.
        let frame = try? await window.getAxRect()
        guard Window.get(byId: window.windowId) === window, window.nodeWorkspace === tab else { return .changed }
        if tab.isVisible, !window.isHiddenInCorner, let frame, isOnADisplay(frame) { return .inPlace }
    }
    return .notShown
}

@MainActor
private func isOnADisplay(_ frame: Rect) -> Bool { monitors.contains { $0.rect.contains(frame.center) } }

/// The close stopped before `window`: it couldn't be shown in its tab, and pressed out of sight,
/// a question to save would stay out of sight.
@MainActor
private func showWorkspaceTabCloseNotShown(_ window: Window) {
    let app = window.app.name ?? "The app"
    workspaceSidebarPinRecallNotice("Some windows weren't closed",
        "\(app)'s window couldn't be shown in its tab, so it wasn't closed. Nothing after it was closed.")
}

/// The close stopped at `window`. Still on screen in its tab, it comes forward, as before, with any
/// save sheet; out of sight, nothing is shown or moved, and the notice says what happened.
@MainActor
private func showWorkspaceTabCloseStopped(_ window: Window, in tab: Workspace, outcome: WindowCloseOutcome) {
    guard Window.get(byId: window.windowId) === window,
          let state = workspaceTabMembers(tab).first(where: { $0.window === window })?.state else { return }
    if !state.isOffscreen, outcome != .unknown {
        _ = window.focusWindow()
        return
    }
    let app = window.app.name ?? "The app"
    let place = switch state {
        case .hiddenWithApp: ", hidden with its app,"
        case .minimized: ", minimized,"
        case .nativeFullscreen: ", in full screen,"
        case .laidOut, .floating: ""
    }
    let body = switch outcome {
        case .unknown: "WinMux couldn't tell whether \(app) closed its window\(place) so it stopped there."
        case .notPressed: "\(app)'s window\(place) couldn't be closed from WinMux, so it stopped there."
        default: "\(app)'s window\(place) didn't close. It may be asking to save changes; show \(app) to answer."
    }
    workspaceSidebarPinRecallNotice("Some windows weren't closed", body + " Nothing after it was closed.")
}

@MainActor
func showWorkspaceTabCloseLeftOpen(_ count: Int) {
    guard count > 0 else { return }
    workspaceSidebarPinRecallNotice("Some windows stayed open",
        count == 1 ? "A window moved or changed while the tab was closing, so it wasn't closed."
            : "\(count) windows moved or changed while their tabs were closing, so they weren't closed.")
}
