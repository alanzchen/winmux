import AppKit
import Common

struct WorkspaceTopicCommitGroup: Equatable, Sendable {
    let name: String
    let members: [WorkspaceTopicToken]
}

enum WorkspaceTopicCommitOutcome: Equatable, Sendable {
    case applied(groups: Int)
    case notApplied(String)
}

let workspaceTopicUndoTitle = "Group by Topic"
let workspaceTopicOutOfDateMessage = "These suggestions are out of date. Suggest again to see what fits the tabs now."

/// Applies suggested groups in one sidebar session. Everything is checked again inside it, right
/// before the write, against the live tabs. One stale member rejects the whole batch.
@MainActor
func applyWorkspaceTopicGroups(_ groups: [WorkspaceTopicCommitGroup], request: WorkspaceTopicRequestState,
                               isCurrent: @escaping @MainActor () -> Bool) -> Task<WorkspaceTopicCommitOutcome, Never>? {
    if let reason = workspaceTopicReadOnlyReason() { return Task { .notApplied(reason) } }
    guard let token: RunSessionGuard = .isServerEnabled else { return nil }
    return Task { @MainActor in
        var outcome = WorkspaceTopicCommitOutcome.notApplied(workspaceTopicOutOfDateMessage)
        do {
            try await runLightSession(.menuBarButton, token) {
                outcome = commitWorkspaceTopicGroups(groups, request: request, isCurrent: isCurrent())
                if case .applied = outcome { await updateWorkspaceSidebarModel() }
            }
        } catch {
            // Once committed, a refresh that fails or is cancelled afterwards doesn't undo it.
            if case .applied = outcome { return outcome }
            return .notApplied(error.localizedDescription)
        }
        return outcome
    }
}

/// Why nothing can be saved now, if so: --read-only, or a store that can't be written.
@MainActor
func workspaceTopicReadOnlyReason() -> String? {
    if serverArgs.isReadOnly { return "WinMux is running with --read-only." }
    return workspaceSidebarOrganizationStore.readOnlyReason ?? savedWorkspaceStore.readOnlyReason
}

/// The commit itself: synchronous, so nothing can change between the checks and the write.
@MainActor
func commitWorkspaceTopicGroups(_ groups: [WorkspaceTopicCommitGroup], request: WorkspaceTopicRequestState,
                                isCurrent: Bool) -> WorkspaceTopicCommitOutcome {
    if let reason = workspaceTopicReadOnlyReason() { return .notApplied(reason) }
    guard let workspaces = workspaceTopicValidatedMembers(groups, request: request, isCurrent: isCurrent) else {
        return .notApplied(workspaceTopicOutOfDateMessage)
    }
    let scope = request.scope
    let savedBefore = savedWorkspaceStore.file
    let runtimeBefore = SavedWorkspaceRuntimeIdentityState()
    let lifecycles = workspaces.map { ($0, $0.lifecycle) }
    let undoBefore = WorkspaceSidebarTabUndoSnapshot()
    var identities = WorkspaceSidebarOrganizationIdentityDelta()
    do {
        // Identities first, so a name in a group can never be recycled for another tab after a
        // relaunch. Their write must succeed before the groups are written.
        for workspace in workspaces {
            let previous = savedWorkspaceStore.record(named: workspace.name)
            let lifecycle = workspace.lifecycle
            let result = try ensureSavedWorkspaceRecord(workspace, flush: false, keepWhenEmpty: true)
            if result.created {
                identities.created.append(.init(name: workspace.name, workspace: workspace, lifecycle: lifecycle))
            } else if previous?.keepWhenEmpty == false {
                identities.promoted.append(workspace.name)
            }
        }
        try savedWorkspaceStore.flushNowReportingFailure()
        workspaceTopicBeforeOrganizationWriteForTests?()
        // Every group in one write: all or none. Plain groups, as if made by hand.
        try workspaceSidebarOrganizationStore.update { state in
            for group in groups {
                state.collections.append(WorkspaceTabCollection(projectId: scope.projectId, name: group.name,
                    workspaceNames: group.members.compactMap { request.prepared.bindings[$0]?.name }))
            }
        }
    } catch {
        // Nothing has used the new identities yet: this is the same main-actor turn.
        savedWorkspaceStore.restoreForRollback(savedBefore)
        runtimeBefore.restore()
        for (workspace, lifecycle) in lifecycles { workspace.lifecycle = lifecycle }
        var message = "Couldn't apply the groups: \(error.localizedDescription)"
        do { try savedWorkspaceStore.flushNowReportingFailure() } catch {
            message += " WinMux also couldn't remove the saved tab identities it had just added; they stay saved."
        }
        return .notApplied(message)
    }
    // The edit's own boundary, before any refresh can absorb a later change into it.
    WorkspaceSidebarTabUndo.shared.recordOrganizationEdit(workspaceTopicUndoTitle, before: undoBefore,
        after: WorkspaceSidebarTabUndoSnapshot(), identities: identities)
    return .applied(groups: groups.count)
}

/// The live tabs a batch would group, or nil if anything about any of them changed: the
/// feature, the settings, the sidebar's scope, or a member's identity, windows, titles, label, pin or group.
@MainActor
func workspaceTopicValidatedMembers(_ groups: [WorkspaceTopicCommitGroup], request: WorkspaceTopicRequestState,
                                    isCurrent: Bool) -> [Workspace]? {
    let prepared = request.prepared
    guard isCurrent, config.suggestsTopicGroups, config.workspaceSidebar.intelligence == prepared.privacy,
          winMuxWorkspaceState.projectsById[prepared.scope.projectId] != nil,
          workspaceTopicPanelStillShows(prepared.scope), !groups.isEmpty else { return nil }
    var seen: Set<WorkspaceTopicToken> = []
    for group in groups {
        guard group.members.count >= 2, group.members.allSatisfy({ seen.insert($0).inserted }),
              let name = workspaceTopicValidatedEditedName(group.name), name == group.name else { return nil }
    }
    // Each member must still be in the list that sidebar shows now, as the user sees it.
    guard let snapshot = workspaceTopicPanelSnapshot(for: prepared.scope) else { return nil }
    let listed = Dictionary(snapshot.tabsListedWorkspaces(for: prepared.scope.projectId).map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first })
    let analyzed = Set(request.analyzed.map(\.token))
    let store = workspaceSidebarOrganizationStore
    var workspaces: [Workspace] = []
    for token in groups.flatMap(\.members) {
        guard analyzed.contains(token), let binding = prepared.bindings[token], let workspace = binding.liveWorkspace,
              workspace.projectId == binding.projectId, workspace.projectId == prepared.scope.projectId,
              store.state.workspaces[binding.name]?.isFavorite != true, store.collection(containing: binding.name) == nil,
              binding.windows.allSatisfy(\.isLive),
              workspaceTopicLiveWindows(workspace).map(\.windowId).sorted() == binding.windows.map(\.windowId),
              let tab = listed[binding.name],
              workspaceTopicEvidence(for: tab, token: token, liveWindowCount: binding.windows.count).promptText == binding.evidenceText
        else { return nil }
        workspaces.append(workspace)
    }
    return workspaces
}

/// Lets a test break a store between the identity write and the organization write.
@MainActor var workspaceTopicBeforeOrganizationWriteForTests: (() -> Void)?

/// An edited group name, cleaned, or nil when it can't be used.
nonisolated func workspaceTopicValidatedEditedName(_ raw: String) -> String? {
    let cleaned = workspaceTopicSanitizedText(raw)
    guard !cleaned.isEmpty, cleaned.count <= workspaceTopicMaximumEditedNameLength else { return nil }
    return cleaned
}
