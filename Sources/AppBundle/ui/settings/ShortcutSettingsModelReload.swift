import Common
import Foundation

extension ShortcutSettingsModel {
    func reload() {
        let workspaceNumbers = shortcutSettingsWorkspaceNumbers()
        let sections = buildShortcutSections()
        self.sections = sections
        self.workspaceNumbers = workspaceNumbers
        let actions = sections.flatMap(\.actions)
        self.actionsById = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        self.actionIdByCommand = Dictionary(uniqueKeysWithValues: actions.map { ($0.canonicalCommand, $0.id) })

        var nextAssignments: [String: String] = [:]
        let mainBindingEntries = config.modes[mainModeId]?.bindings.values.map {
            (notation: $0.descriptionWithKeyNotation, command: $0.commands.prettyDescription)
        } ?? []
        let workspaceState = inferWorkspaceShortcutState(
            from: Dictionary(uniqueKeysWithValues: mainBindingEntries.map { ($0.notation, $0.command) }),
            workspaceNumbers: workspaceNumbers,
            defaultSwitchModifiers: defaultWorkspaceSwitchModifiers,
            defaultMoveModifiers: defaultWorkspaceMoveModifiers,
        )
        collectMainBindings(workspaceNumbers: workspaceNumbers, assignments: &nextAssignments)

        self.assignments = nextAssignments
        self.workspaceSwitchModifiers = workspaceState.switchModifiers
        self.workspaceMoveModifiers = workspaceState.moveModifiers
        self.workspaceOverrides = workspaceNumbers.map {
            WorkspaceOverride(
                workspaceName: $0,
                switchNotation: workspaceState.switchOverrides[$0],
                moveNotation: workspaceState.moveOverrides[$0],
            )
        }
        settingsRevision += 1
    }

    func requestWindowOpen() {
        reload()
        openRequestId += 1
    }

    private func collectMainBindings(
        workspaceNumbers: [String],
        assignments nextAssignments: inout [String: String],
    ) {
        let mainBindings = config.modes[mainModeId]?.bindings.values.sorted {
            $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation
        } ?? []
        for binding in mainBindings {
            let command = binding.commands.prettyDescription
            if parseWorkspaceCommandTarget(command, kind: .switchTo).flatMap({ workspaceNumbers.contains($0) ? $0 : nil }) != nil {
                continue
            }
            if parseWorkspaceCommandTarget(command, kind: .moveTo).flatMap({ workspaceNumbers.contains($0) ? $0 : nil }) != nil {
                continue
            }
            if let actionId = actionIdByCommand[command] {
                nextAssignments[actionId] = binding.descriptionWithKeyNotation
            }
        }
    }
}
