import AppKit
import SwiftUI

// Tabs mode: the footer's Move Tabs button moves the tabs of a display's list, in the project it
// shows, to another display, as one edit with one Undo. Only the tabs actually on that display go:
// not the pins shared from other displays, nor tabs held to their display, nor tabs with a window
// in native full screen or with no windows to move. Those stay, and the notice says so. The tab on
// screen there goes on screen on the other display, and focus goes with it; the others stay
// hidden and only change display, as a tab dropped on another display's list does. Nothing is
// activated on the way, nothing is opened, and no window is taken out of full screen.

/// Why a tab stays on its display when the tabs there move to another.
enum WorkspaceSidebarTabStays: Equatable, Sendable {
    /// No windows to move: a pin that isn't open or has lent its window, or a tab whose windows are
    /// all minimized.
    case noWindows
    /// A window in native full screen, which moving the tab would take out of full screen.
    case fullScreen
    /// Held to its display, by `workspace-to-monitor-force-assignment` or Keep on display.
    case kept
    /// The move couldn't place it on the other display.
    case failed
}

struct WorkspaceSidebarStayingTab: Equatable {
    let name: String
    let displayName: String
    let reason: WorkspaceSidebarTabStays
}

/// Whether one of `tab`'s windows is in native full screen.
@MainActor
func workspaceTabHasNativeFullscreenWindow(_ tab: Workspace) -> Bool {
    tab.existingMacOsNativeFullscreenWindowsContainer?.children.isEmpty == false
}

/// Why moving `tab` to another display leaves it where it is, whichever display that is.
@MainActor
func workspaceSidebarTabDisplayMoveBlock(_ tab: Workspace) -> WorkspaceSidebarTabStays? {
    if workspaceTabHasNativeFullscreenWindow(tab) { return .fullScreen }
    return tab.anyLeafWindowRecursive == nil ? .noWindows : nil
}

// MARK: The button

/// The tabs of a list that a move to one display takes, in the list's order, and those that stay.
struct WorkspaceSidebarDisplayMoveSelection: Equatable {
    var moving: [String] = []
    var staying: [WorkspaceSidebarStayingTab] = []
}

/// What moving the tabs of `source`'s list to `target` takes: those `listed` that are on `source`,
/// as the move itself decides when it runs.
func workspaceSidebarDisplayMoveSelection(_ listed: [WorkspaceSidebarWorkspaceViewModel], source: String,
                                          target: String) -> WorkspaceSidebarDisplayMoveSelection {
    var result = WorkspaceSidebarDisplayMoveSelection()
    var seen: Set<String> = []
    for tab in listed where tab.monitorScopeId == source && !tab.isLeftEmpty && seen.insert(tab.name).inserted {
        if let reason = tab.displayMoveBlock ?? tab.heldMonitorScopeId.flatMap({ $0 == target ? nil : .kept }) {
            result.staying.append(.init(name: tab.name, displayName: tab.displayName, reason: reason))
        } else {
            result.moving.append(tab.name)
        }
    }
    return result
}

/// A display the footer's Move Tabs button can move a list's tabs to.
struct WorkspaceSidebarDisplayMoveTarget: Equatable, Identifiable {
    let id: String
    let displayName: String
    let selection: WorkspaceSidebarDisplayMoveSelection

    var count: Int { selection.moving.count }
    var title: String { "Move \(count) \(count == 1 ? "Tab" : "Tabs") to “\(displayName)”" }
}

/// The footer's Move Tabs button for a list of one display's tabs: that display, the list's
/// project, and every other connected display.
struct WorkspaceSidebarDisplayMove: Equatable {
    let projectId: WorkspaceProjectId
    let source: String
    let targets: [WorkspaceSidebarDisplayMoveTarget]

    /// Some display would take some tab; else the button is shown dimmed.
    var isEnabled: Bool { targets.contains { $0.count > 0 } }

    /// Its tooltip and accessibility label: the display and the count, with two displays.
    var help: String {
        guard isEnabled else { return "No tabs to move to another display" }
        if targets.count == 1, let target = targets.first { return target.title }
        return "Move Tabs to Another Display"
    }
}

extension WorkspaceSidebarSnapshot {
    /// The footer's Move Tabs button, for a list of one connected display's tabs while another is
    /// connected. Nil for All Displays or Focused, and with one display.
    var displayMove: WorkspaceSidebarDisplayMove? {
        let source = selectedMonitorScopeId
        let displays = monitorScopes.filter { workspaceSidebarMonitorScopePoint($0.id) != nil }
        guard displays.contains(where: { $0.id == source }) else { return nil }
        let others = displays.filter { $0.id != source }
        guard !others.isEmpty else { return nil }
        let listed = tabsListedWorkspaces(for: activeProjectId)
        return .init(projectId: activeProjectId, source: source, targets: others.map { display in
            .init(id: display.id, displayName: display.displayName,
                selection: workspaceSidebarDisplayMoveSelection(listed, source: source, target: display.id))
        })
    }
}

/// The footer's Move Tabs button: with two displays, one click moves the tabs; with more, a menu
/// asks which display, every time. Dimmed when no tab would go.
struct WorkspaceSidebarDisplayMoveButton: View {
    let move: WorkspaceSidebarDisplayMove
    let send: (String) -> Void

    var body: some View {
        Group {
            if move.targets.count == 1, let target = move.targets.first {
                Button { send(target.id) } label: { icon }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(move.targets) { target in
                        Button(target.title) { send(target.id) }.disabled(target.count == 0)
                    }
                } label: { icon }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .disabled(!move.isEnabled)
        .help(move.help)
        .accessibilityLabel(move.help)
    }

    /// A 28-point target that takes no more height in the footer than its text.
    private var icon: some View {
        Image(systemName: "display.2")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .padding(.vertical, -7)
    }
}

// MARK: The move

/// What a move did, for its notice.
struct WorkspaceSidebarDisplayMoveOutcome: Equatable {
    /// The display the tabs went to; nil when it was gone before anything moved.
    var targetName: String?
    /// The display they were on was gone before anything moved.
    var sourceIsGone = false
    var moved: [String] = []
    var staying: [WorkspaceSidebarStayingTab] = []
    /// A display went away during the move: the tabs after it stayed.
    var stoppedEarly = false
}

/// The tabs of `projectId` on `source` that a move to `target` takes, in the list's order, and
/// those that stay. `foreground`, among `tabs`, is the one on screen on `source`, when it goes.
struct WorkspaceSidebarDisplayMovePlan {
    var tabs: [Workspace] = []
    var foreground: Workspace?
    var staying: [WorkspaceSidebarStayingTab] = []

    var background: [Workspace] { tabs.filter { $0 !== foreground } }
}

/// The tabs listed for `projectId` on `source` now, as its list shows them: its pins in All
/// Projects and its own, then its other tabs, in the project's order. Only those on `source`:
/// a pin shared from another display isn't.
@MainActor
func workspaceSidebarDisplayMovePlan(projectId: WorkspaceProjectId, source: Monitor, target: Monitor) -> WorkspaceSidebarDisplayMovePlan {
    let sourceScopeId = workspaceSidebarMonitorScopeId(for: source)
    let organization = workspaceSidebarOrganizationStore.state
    let pins = config.usesBrowserTabs ? workspacePinnedTabsInAllProjects() + workspacePinnedTabs(in: projectId) : []
    let ordinary = orderedWorkspaces(in: projectId).filter { organization.workspaces[$0.name]?.isFavorite != true }
    var plan = WorkspaceSidebarDisplayMovePlan()
    var seen: Set<WorkspaceId> = []
    for tab in pins + ordinary where seen.insert(tab.id).inserted && !tab.isArchived && workspaceTabIsShown(tab)
        && workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor) == sourceScopeId {
        if let reason = workspaceSidebarTabDisplayMoveBlock(tab) ?? (workspaceTabCanMove(tab, to: target) ? nil : .kept) {
            plan.staying.append(.init(name: tab.name, displayName: workspaceDisplayName(tab.name), reason: reason))
        } else {
            plan.tabs.append(tab)
            if tab.isVisible { plan.foreground = tab }
        }
    }
    return plan
}

/// Moves the tabs of `projectId` on the display `sourceScopeId` to the display `targetScopeId`, as
/// `workspaceSidebarDisplayMovePlan` finds them when it runs. Hidden tabs only change display; the
/// tab on screen goes on screen there, focused. They go after the tabs already listed there, in
/// their order; pins keep theirs. A tab that can't be placed stays as it was.
@MainActor
func moveWorkspaceTabsToDisplay(projectId: WorkspaceProjectId, from sourceScopeId: String,
                                to targetScopeId: String) -> WorkspaceSidebarDisplayMoveOutcome {
    guard sourceScopeId != targetScopeId, let target = workspaceSidebarMonitor(forScopeId: targetScopeId) else {
        return .init(targetName: nil)
    }
    var outcome = WorkspaceSidebarDisplayMoveOutcome(targetName: workspaceSidebarMonitorDisplayName(target, among: sortedMonitors))
    guard let source = workspaceSidebarMonitor(forScopeId: sourceScopeId),
          winMuxWorkspaceState.projectsById[projectId] != nil else {
        outcome.sourceIsGone = true
        return outcome
    }
    let plan = workspaceSidebarDisplayMovePlan(projectId: projectId, source: source, target: target)
    outcome.staying = plan.staying
    let organization = workspaceSidebarOrganizationStore.state
    func isListedOnTarget(_ tab: Workspace) -> Bool {
        organization.workspaces[tab.name]?.isFavorite != true && workspaceTabIsShown(tab)
            && workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor) == targetScopeId
    }
    // Chosen before anything moves: the last tab the other display lists of the project, pins aside.
    var anchor = orderedWorkspaces(in: projectId).last(where: isListedOnTarget)
    func displaysAreConnected() -> Bool {
        workspaceSidebarMonitor(forScopeId: sourceScopeId) != nil && workspaceSidebarMonitor(forScopeId: targetScopeId) != nil
    }
    var moved: [Workspace] = []
    for tab in plan.background {
        guard displaysAreConnected() else { outcome.stoppedEarly = true; break }
        let preferred = tab.preferredMonitorPoint
        tab.preferredMonitorPoint = target.rect.topLeftCorner
        noteSavedWorkspacePlacedByUser(tab, on: target)
        if workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor) == targetScopeId {
            moved.append(tab)
        } else {
            // Its saved display didn't change, while displays settle: it stays, as it was.
            tab.preferredMonitorPoint = preferred
            outcome.staying.append(.init(name: tab.name, displayName: workspaceDisplayName(tab.name), reason: .failed))
        }
    }
    if let foreground = plan.foreground {
        if !outcome.stoppedEarly, displaysAreConnected() {
            let before = WorkspaceSidebarTabUndoSnapshot()
            let focusedDisplay = focus.workspace.workspaceMonitor.rect
            if placeWorkspaceTabOnDisplay(foreground, target) {
                moved.append(foreground)
                // Focus goes with it; the pointer stays where it is, by the button.
                skipsNextFocusedMonitorChangedCommands = focusedDisplay != target.rect
                _ = foreground.focusWorkspace()
            } else {
                before.restore(replacing: WorkspaceSidebarTabUndoSnapshot())
                outcome.staying.append(.init(name: foreground.name, displayName: workspaceDisplayName(foreground.name),
                    reason: .failed))
            }
        } else {
            outcome.stoppedEarly = true
        }
    }
    guard !moved.isEmpty else { return outcome }
    // After the tabs already there, in the project's order. Pins keep the pins' order.
    let movedIds = Set(moved.map(\.id))
    if anchor != nil {
        for tab in orderedWorkspaces(in: projectId) where movedIds.contains(tab.id) && organization.workspaces[tab.name]?.isFavorite != true {
            if let previous = anchor { winMuxWorkspaceState.moveWorkspace(tab.id, relativeTo: previous.id, after: true) }
            anchor = tab
        }
    }
    syncSavedWorkspaceRecords(moved)
    outcome.moved = plan.tabs.filter { movedIds.contains($0.id) }.map(\.name)
    return outcome
}

/// The footer's Move Tabs: one edit, with one Undo, and a notice of what moved and what stayed, on
/// the display whose sidebar was clicked.
@MainActor
func moveTabsToDisplayFromSidebar(projectId: WorkspaceProjectId, from sourceScopeId: String, to targetScopeId: String,
                                  noticeMonitorScopeId: String) {
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    var outcome: WorkspaceSidebarDisplayMoveOutcome?
    runWorkspaceSidebarSession(afterLayout: {
        guard let notice = outcome?.notice else { return }
        showWorkspaceSidebarNotice(.init(title: "Move Tabs", body: notice, monitorScopeId: noticeMonitorScopeId))
    }, undoTitle: "Move Tabs") {
        outcome = moveWorkspaceTabsToDisplay(projectId: projectId, from: sourceScopeId, to: targetScopeId)
    }
}

/// Shows a sidebar action's notice. Tests replace it, so no panel comes on screen.
@MainActor
var showWorkspaceSidebarNotice: @MainActor (WinMuxToastNotice) -> Void = { WinMuxToastPanel.shared.show($0) }

extension WorkspaceSidebarDisplayMoveOutcome {
    /// What the notice says: what moved and what stayed, and why. Nil when there was nothing to move.
    var notice: String? {
        guard let targetName else { return "That display is no longer connected. No tabs moved." }
        if sourceIsGone { return "The tabs’ display is no longer connected. No tabs moved." }
        guard !moved.isEmpty || !staying.isEmpty else { return nil }
        var sentences = [moved.isEmpty ? "No tabs moved to “\(targetName)”."
            : "Moved \(moved.count) \(moved.count == 1 ? "tab" : "tabs") to “\(targetName)”."]
        if stoppedEarly { sentences.append("A display was disconnected, so the other tabs stayed.") }
        let reasons: [(WorkspaceSidebarTabStays, one: String, many: String)] = [
            (.kept, "stayed: it’s kept on its display", "stayed: they’re kept on their displays"),
            (.fullScreen, "stayed: it’s in full screen", "stayed: they’re in full screen"),
            (.failed, "couldn’t be moved", "couldn’t be moved"),
        ]
        for (reason, one, many) in reasons {
            let names = staying.filter { $0.reason == reason }.map(\.displayName)
            guard !names.isEmpty else { continue }
            sentences.append("\(workspaceSidebarNoticeNameList(names)) \(names.count == 1 ? one : many).")
        }
        let empty = staying.filter { $0.reason == .noWindows }.count
        if empty > 0 { sentences.append("\(empty) \(empty == 1 ? "tab" : "tabs") with no windows to move stayed.") }
        return sentences.joined(separator: " ")
    }
}

/// “A”, “A” and “B”, or “A”, “B” and 3 more.
func workspaceSidebarNoticeNameList(_ names: [String]) -> String {
    let quoted = names.map { "“\($0)”" }
    switch quoted.count {
        case 0: return ""
        case 1: return quoted[0]
        case 2, 3: return quoted.dropLast().joined(separator: ", ") + " and " + quoted.last!
        default: return quoted.prefix(2).joined(separator: ", ") + " and \(quoted.count - 2) more"
    }
}
