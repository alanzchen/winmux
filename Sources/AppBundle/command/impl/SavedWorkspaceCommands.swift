import Common
import Foundation

struct SaveWorkspaceCommand: Command {
    let args: SaveWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail}
        let workspace = target.workspace
        let requestedName: String?
        do {
            requestedName = try args.displayName.map(normalizedWorkspaceProjectDisplayName)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        let isPinned = savedWorkspaceStore.record(named: workspace.name)?.isPinnedToDisplay == true
        // Checked before saving, so a pin that can't happen leaves the workspace unchanged.
        if args.pinToDisplay == true, !isPinned {
            if resolvedForceAssignedMonitor(forWorkspaceName: workspace.name) != nil {
                return .fail(io.err(
                    "Workspace '\(workspaceDisplayName(workspace.name))' (\(workspace.name)) can't be kept on a display: " +
                        "workspace-to-monitor-force-assignment in the config assigns it to a monitor",
                ))
            }
            let monitor = workspace.visibleMonitor ?? workspace.workspaceMonitor
            if SavedDisplayAffinity(monitor: monitor) == nil {
                return .fail(io.err(WorkspaceMutationError.displayHasNoIdentity(monitor.name).localizedDescription))
            }
        }

        let wasSaved = workspace.isSaved
        let previousDisplayName = workspaceDisplayName(workspace.name)
        let pinChanged: Bool
        do {
            // Save and pin before naming: the name is also written to the TOML config, which can
            // fail after the saved-workspace changes are already made.
            try saveWorkspaceForSidebar(workspaceName: workspace.name, displayName: nil)
            pinChanged = try args.pinToDisplay.map { try setSavedWorkspacePinned(workspace, $0) } ?? false
            if let requestedName {
                try saveWorkspaceForSidebar(workspaceName: workspace.name, displayName: requestedName)
            }
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        let changed = !wasSaved || pinChanged || workspaceDisplayName(workspace.name) != previousDisplayName
        if !changed {
            let pinState = switch args.pinToDisplay {
                case true?: " and kept on display '\(savedPinnedDisplayName(workspace) ?? "its display")'"
                case false?: " and not kept on a display"
                case nil: ""
            }
            let message = "Workspace '\(previousDisplayName)' is already saved\(pinState)"
            if args.failIfNoop {
                return .fail(io.err(message))
            }
            io.err("\(message). Tip: use --fail-if-noop to exit with non-zero code")
        }
        if args.json {
            return writeSavedWorkspaceJson(workspace, changed: changed, to: io)
        }
        return .succ
    }
}

struct ForgetWorkspaceCommand: Command {
    let args: ForgetWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail}
        let workspace = target.workspace
        let displayName = workspaceDisplayName(workspace.name)
        let changed: Bool
        do {
            changed = try forgetSavedWorkspace(workspace)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        if !changed {
            let message = "Workspace '\(displayName)' is not saved"
            if args.failIfNoop {
                return .fail(io.err(message))
            }
            io.err("\(message). Tip: use --fail-if-noop to exit with non-zero code")
        }
        if args.json {
            return writeSavedWorkspaceJson(workspace, changed: changed, to: io)
        }
        return .succ
    }
}

/// `saved-id` and `display` (the home display's name) are omitted while unknown.
@MainActor
private func writeSavedWorkspaceJson(_ workspace: Workspace, changed: Bool, to io: CmdIo) -> BinaryExitCode {
    let record = savedWorkspaceStore.record(named: workspace.name)
    var result: [String: Primitive] = [
        "changed": .bool(changed),
        "display-name": .string(workspaceDisplayName(workspace.name)),
        "pinned": .bool(record?.isPinnedToDisplay ?? false),
        "saved": .bool(record != nil),
        "workspace": .string(workspace.name),
    ]
    if let record {
        result["saved-id"] = .string(record.id)
    }
    if let display = record?.display?.name, !display.isEmpty {
        result["display"] = .string(display)
    }
    return JSONEncoder.aeroSpaceDefault.encodeToString(result).map { .succ(io.out($0)) }
        ?? .fail(io.err("Failed to encode JSON"))
}
