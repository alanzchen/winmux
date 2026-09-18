import AppKit
@testable import AppBundle
import Combine
import XCTest

@MainActor
final class WorkspaceSidebarMonitorDefaultTest: XCTestCase {
    private let displays = ["monitor:0.0,0.0", "monitor:1920.0,0.0", "monitor:3840.0,0.0"]

    func testEachDockDefaultsToItsOwnDisplayAndFiltersItsWorkspaces() {
        let models = displays.map { model(target: $0) }
        for (index, model) in models.enumerated() {
            model.workspaceSidebarWorkspaces = displays.enumerated().map { offset, scope in
                .init(name: "\(offset + 1)", projectId: workspaceProjectDefaultId,
                    displayName: "\(offset + 1)", sidebarLabel: "", isGeneratedName: false,
                    monitorScopeId: scope, monitorName: nil, isFocused: offset == 0,
                    isVisible: true, items: [])
            }
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[index])
            XCTAssertEqual(model.visibleWorkspaceSidebarWorkspaces.map(\.name), ["\(index + 1)"])
            XCTAssertTrue(WorkspaceSidebarView(snapshot: workspaceSidebarSnapshot(from: model))
                .allowsWorkspaceActivation(projectId: workspaceProjectDefaultId))
        }

        selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: models[0])
        models.forEach { $0.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(models[0].visibleWorkspaceSidebarWorkspaces.count, 3)
        XCTAssertEqual(models[1].workspaceSidebarSelectedMonitorScopeId, displays[1])
        XCTAssertEqual(models[2].workspaceSidebarSelectedMonitorScopeId, displays[2])
    }

    func testAutomaticSelectionWaitsForScopesAndFollowsLiveModeChanges() {
        let model = model(target: displays[1])
        model.workspaceSidebarMonitorScopes = []
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)

        // A single connected display still gets its own filter once discovery completes.
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, displays[1]])
        for isDock in [true, false, true] {
            model.workspaceSidebarAppearance.showAppIcons = isDock
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId,
                isDock ? displays[1] : workspaceSidebarDefaultScopeId)
        }
    }

    func testManualFiltersSurviveFocusChangesExpansionAndModeChanges() {
        for selection in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0], displays[1]] {
            let model = model(target: displays[1])
            model.refreshWorkspaceSidebarMonitorScope()
            let actions = makeWorkspaceSidebarActionsAdapter(viewModel: model, targetMonitorScopeId: displays[1])
            actions.send(.selectMonitorScope(selection))
            for isDock in [true, false, true] {
                model.workspaceSidebarAppearance.showAppIcons = isDock
                model.workspaceSidebarFocusedMonitorScopeId = displays[2]
                model.isWorkspaceSidebarExpanded.toggle()
                model.refreshWorkspaceSidebarMonitorScope()
                XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, selection)
            }
        }
    }

    func testChoosingAlreadySelectedDefaultInSidebarSurvivesSwitchToDock() {
        let model = model(target: displays[1])
        model.workspaceSidebarAppearance.showAppIcons = false
        model.refreshWorkspaceSidebarMonitorScope()
        selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: model)
        model.workspaceSidebarAppearance.showAppIcons = true
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
    }

    func testDisconnectedManualDisplayFallsBackToDefaultWithoutReapplyingAutomaticChoice() {
        let model = model(target: displays[0])
        model.refreshWorkspaceSidebarMonitorScope()
        selectWorkspaceSidebarMonitorScope(displays[1], viewModel: model)
        model.workspaceSidebarMonitorScopes.removeAll { $0.id == displays[1] }
        for _ in 0..<3 { model.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId] + displays)
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
    }

    func testTemporaryModelClearPreservesManualSelectionUntilDiscoveryReturns() {
        for selection in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0], displays[1]] {
            let model = model(target: displays[0])
            selectWorkspaceSidebarMonitorScope(selection, viewModel: model)
            let available = model.workspaceSidebarMonitorScopes
            model.workspaceSidebarMonitorScopes = []
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, selection)
            model.workspaceSidebarMonitorScopes = available
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, selection)
        }
    }

    func testUnavailableFocusFallsBackAndInvalidSelectionDoesNotOverrideAutomaticDefault() {
        let model = model(target: displays[0])
        selectWorkspaceSidebarMonitorScope("disconnected", viewModel: model)
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])

        selectWorkspaceSidebarMonitorScope(workspaceSidebarFocusedScopeId, viewModel: model)
        model.workspaceSidebarMonitorScopes.removeAll { $0.id == workspaceSidebarFocusedScopeId }
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
    }

    func testUnchangedScopeRefreshDoesNotPublishExtraViewUpdates() {
        let model = model(target: displays[0])
        model.refreshWorkspaceSidebarMonitorScope()
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        for _ in 0..<5 { model.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(updates, 0)
        selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: model)
        XCTAssertEqual(updates, 1)
        for _ in 0..<5 { model.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(updates, 1)
    }

    func testOwnDisplayDockIsInteractiveWithoutEnablingOtherDisplayOrSidebarSummaries() {
        let model = model(target: displays[0])
        for isDock in [true, false] {
            model.workspaceSidebarAppearance.showAppIcons = isDock
            for selection in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0], displays[1]] {
                selectWorkspaceSidebarMonitorScope(selection, viewModel: model)
                let view = WorkspaceSidebarView(snapshot: workspaceSidebarSnapshot(from: model))
                XCTAssertEqual(view.allowsWorkspaceActivation(projectId: workspaceProjectDefaultId),
                    selection == workspaceSidebarDefaultScopeId || (isDock && selection == displays[0]))
            }
        }
    }

    func testPanelSyncAppliesDockDefaultAfterCopyingItsTargetAndAvailableScopes() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let panel = WorkspaceSidebarPanel.shared
        let model = panel.viewModel
        let previousConfig = config
        let previousSharedScopes = TrayMenuModel.shared.workspaceSidebarMonitorScopes
        let previousScopes = model.workspaceSidebarMonitorScopes
        let previousTarget = model.workspaceSidebarTargetMonitorScopeId
        let previousSelection = model.workspaceSidebarSelectedMonitorScopeId
        let previousExplicit = model.workspaceSidebarHasExplicitMonitorScopeSelection
        let previousAppearance = model.workspaceSidebarAppearance
        defer {
            config = previousConfig
            TrayMenuModel.shared.workspaceSidebarMonitorScopes = previousSharedScopes
            model.workspaceSidebarMonitorScopes = previousScopes
            model.workspaceSidebarTargetMonitorScopeId = previousTarget
            model.workspaceSidebarSelectedMonitorScopeId = previousSelection
            model.workspaceSidebarHasExplicitMonitorScopeSelection = previousExplicit
            model.workspaceSidebarAppearance = previousAppearance
        }
        config.workspaceSidebar.mode = .dock
        model.workspaceSidebarHasExplicitMonitorScopeSelection = false
        model.workspaceSidebarSelectedMonitorScopeId = workspaceSidebarDefaultScopeId
        model.workspaceSidebarTargetMonitorScopeId = workspaceSidebarDefaultScopeId
        TrayMenuModel.shared.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, panel.monitorScopeId])

        panel.syncModelFromShared()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, panel.monitorScopeId)
        selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: model)
        panel.syncModelFromShared()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
    }

    private func model(target: String) -> TrayMenuModel {
        let model = TrayMenuModel()
        model.workspaceSidebarAppearance.showAppIcons = true
        model.workspaceSidebarTargetMonitorScopeId = target
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId] + displays)
        model.workspaceSidebarFocusedMonitorScopeId = displays[0]
        return model
    }

    private func scopes(_ ids: [String]) -> [WorkspaceSidebarMonitorScopeViewModel] {
        ids.map { .init(id: $0, displayName: $0, subtitle: nil, systemImageName: "display", isFocusedMonitor: false) }
    }
}
