import Common
import Foundation

struct ListProjectsCommand: Command {
    let args: ListProjectsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // The projects the user is in: a pin in All Projects on screen is in its display's.
        let focusedProjectId = workspaceContextProjectId(of: focus.workspace)
        let visibleProjectIds = Set(Workspace.all.filter(\.isVisible).map(workspaceContextProjectId(of:)))
        var result = workspaceProjects().enumerated().map { offset, project in
            ProjectFormatObject(
                index: offset + 1,
                project: project,
                colorHex: config.workspaceSidebar.projectColors[project.id.rawValue]
                    .flatMap(normalizedWorkspaceSidebarColorHex),
                isFocused: project.id == focusedProjectId,
                isVisible: visibleProjectIds.contains(project.id),
                workspaceCount: orderedWorkspaces(in: project.id).count,
                windowCount: windowsInWorkspaceProject(project.id).count,
            )
        }
        if let focused = args.focused {
            result = result.filter { $0.isFocused == focused }
        }
        if let visible = args.visible {
            result = result.filter { $0.isVisible == visible }
        }

        if args.outputOnlyCount {
            return .succ(io.out("\(result.count)"))
        }
        return result.map(AeroObj.project).writeFormattedOutput(
            to: io,
            format: args.format,
            json: args.json,
            ignoreRightPaddingVar: args._format.isEmpty,
        )
    }
}

struct CreateProjectCommand: Command {
    let args: CreateProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let requestedName: String?
        do {
            requestedName = try args.name.map(normalizedWorkspaceProjectDisplayName)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        let requestedColor: String?
        if let color = args.color {
            guard let normalized = normalizedWorkspaceSidebarColorHex(color) else {
                return .fail(io.err(WorkspaceMutationError.invalidProjectColor(color).localizedDescription))
            }
            requestedColor = normalized
        } else {
            requestedColor = nil
        }

        do {
            let project = try createWorkspaceProjectForCommand(
                displayName: requestedName,
                colorHex: requestedColor,
            )
            let currentProject = workspaceProject(id: project.id.rawValue).orDie()
            if args.json {
                return writeProjectMutationJson([
                    "project-color": .string(requestedColor ?? "auto"),
                    "project-id": .string(currentProject.id.rawValue),
                    "project-name": .string(currentProject.name),
                ], to: io)
            }
            return .succ(io.out(currentProject.id.rawValue))
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
    }
}

struct RenameProjectCommand: Command {
    let args: RenameProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let project = workspaceProject(id: args.projectId.val) else {
            return .fail(io.err(WorkspaceMutationError.projectNotFound(args.projectId.val).localizedDescription))
        }
        let name: String
        do {
            name = try normalizedWorkspaceProjectDisplayName(args.displayName.val)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        let changed = project.name != name
        if !changed {
            if args.failIfNoop {
                return .fail(io.err("Project '\(project.id.rawValue)' is already named '\(name)'"))
            }
            io.err("Project '\(project.id.rawValue)' is already named '\(name)'. Tip: use --fail-if-noop to exit with non-zero code")
        } else {
            do {
                try renameWorkspaceProject(project.id, displayName: name)
            } catch {
                return .fail(io.err(error.localizedDescription))
            }
        }
        if args.json {
            return writeProjectMutationJson([
                "changed": .bool(changed),
                "project-id": .string(project.id.rawValue),
                "project-name": .string(name),
            ], to: io)
        }
        return .succ
    }
}

struct SetProjectColorCommand: Command {
    let args: SetProjectColorCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let project = workspaceProject(id: args.projectId.val) else {
            return .fail(io.err(WorkspaceMutationError.projectNotFound(args.projectId.val).localizedDescription))
        }
        let rawColor = args.color.val.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedColor: String?
        if rawColor == "auto" {
            requestedColor = nil
        } else if let normalized = normalizedWorkspaceSidebarColorHex(rawColor) {
            requestedColor = normalized
        } else {
            return .fail(io.err(WorkspaceMutationError.invalidProjectColor(rawColor).localizedDescription))
        }
        let currentColor = config.workspaceSidebar.projectColors[project.id.rawValue]
            .flatMap(normalizedWorkspaceSidebarColorHex)
        let changed = currentColor != requestedColor
        if !changed {
            let colorDescription = requestedColor ?? "auto"
            if args.failIfNoop {
                return .fail(io.err("Project '\(project.id.rawValue)' already uses color '\(colorDescription)'"))
            }
            io.err("Project '\(project.id.rawValue)' already uses color '\(colorDescription)'. Tip: use --fail-if-noop to exit with non-zero code")
        } else {
            do {
                try setWorkspaceProjectColor(project.id, colorHex: requestedColor)
            } catch {
                return .fail(io.err(error.localizedDescription))
            }
        }
        if args.json {
            return writeProjectMutationJson([
                "changed": .bool(changed),
                "project-color": .string(requestedColor ?? "auto"),
                "project-id": .string(project.id.rawValue),
            ], to: io)
        }
        return .succ
    }
}

struct DeleteProjectCommand: Command {
    let args: DeleteProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let project = workspaceProject(id: args.projectId.val) else {
            return .fail(io.err(WorkspaceMutationError.projectNotFound(args.projectId.val).localizedDescription))
        }
        guard canDeleteWorkspaceProject(project.id) else {
            return .fail(io.err(WorkspaceMutationError.projectCannotBeDeleted(project.name).localizedDescription))
        }
        let fallbackId = workspaceProjectFallbackForDeletion(excluding: project.id)
        let windowCount = windowsInWorkspaceProject(project.id).count
        let expectedWindowCount = Int(args.ifWindowCount.orDie())
        guard windowCount == expectedWindowCount else {
            return .fail(io.err(
                "Project '\(project.id.rawValue)' window count changed: expected \(expectedWindowCount), found \(windowCount). Run list-projects again before deleting.",
            ))
        }
        let action = WorkspaceProjectDeletionAction.moveWindowsToFallback
        do {
            try deleteWorkspaceProject(project.id)
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
        if args.json {
            return writeProjectMutationJson([
                "deleted-project-id": .string(project.id.rawValue),
                "fallback-project-id": .string(fallbackId.rawValue),
                "window-action": .string(action.rawValue),
                "window-count": .int(windowCount),
            ], to: io)
        }
        return .succ
    }
}

private func writeProjectMutationJson(_ result: [String: Primitive], to io: CmdIo) -> BinaryExitCode {
    JSONEncoder.aeroSpaceDefault.encodeToString(result).map { .succ(io.out($0)) }
        ?? .fail(io.err("Failed to encode JSON"))
}
