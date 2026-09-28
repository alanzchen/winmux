import AppKit
@testable import AppBundle
import Combine
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarMonitorDefaultTest: XCTestCase {
    private let displays = ["monitor:0.0,0.0", "monitor:1920.0,0.0", "monitor:3840.0,0.0"]
    private let modes: [WorkspaceSidebarMode] = [.dock, .sidebar, .tabs]

    func testEachPanelDefaultsToItsOwnDisplayInEveryMode() {
        for mode in modes {
            let models = displays.map { model(target: $0, mode: mode) }
            for (index, model) in models.enumerated() {
                model.workspaceSidebarWorkspaces = displays.enumerated().map { offset, scope in
                    .init(name: "\(offset + 1)", projectId: workspaceProjectDefaultId,
                        displayName: "\(offset + 1)", sidebarLabel: "", isGeneratedName: false,
                        monitorScopeId: scope, monitorName: nil, isFocused: offset == 0,
                        isVisible: true, items: [])
                }
                model.refreshWorkspaceSidebarMonitorScope()
                XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[index], "\(mode)")
                XCTAssertEqual(model.visibleWorkspaceSidebarWorkspaces.map(\.name), ["\(index + 1)"], "\(mode)")
                XCTAssertTrue(WorkspaceSidebarView(snapshot: workspaceSidebarSnapshot(from: model))
                    .allowsWorkspaceActivation(projectId: workspaceProjectDefaultId), "\(mode)")
            }

            selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: models[0])
            models.forEach { $0.refreshWorkspaceSidebarMonitorScope() }
            XCTAssertEqual(models[0].visibleWorkspaceSidebarWorkspaces.count, 3, "\(mode)")
            XCTAssertEqual(models[1].workspaceSidebarSelectedMonitorScopeId, displays[1], "\(mode)")
            XCTAssertEqual(models[2].workspaceSidebarSelectedMonitorScopeId, displays[2], "\(mode)")
        }
    }

    func testAllDisplaysSettingListsEveryDisplayInEveryMode() {
        for mode in modes {
            let model = model(target: displays[1], mode: mode)
            model.workspaceSidebarWorkspaces = displays.enumerated().map { workspace("\($0.offset + 1)", on: $0.element) }
            model.workspaceSidebarAppearance.displayFilter = .allDisplays
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId, "\(mode)")
            XCTAssertEqual(model.visibleWorkspaceSidebarWorkspaces.map(\.name), ["1", "2", "3"], "\(mode)")
            XCTAssertTrue(WorkspaceSidebarView(snapshot: workspaceSidebarSnapshot(from: model))
                .allowsWorkspaceActivation(projectId: workspaceProjectDefaultId), "\(mode)")
        }
    }

    func testAutomaticSelectionWaitsForScopesAndIgnoresModeChanges() {
        let model = model(target: displays[1])
        model.workspaceSidebarMonitorScopes = []
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)

        // A single connected display still gets its own filter once discovery completes.
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, displays[1]])
        for mode in modes + [.dock] {
            setMode(mode, on: model)
            model.refreshWorkspaceSidebarMonitorScope()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[1], "\(mode)")
        }
    }

    func testDisplayWithoutItsOwnPanelMakesPanelsListEveryDisplay() {
        let model = model(target: displays[0])
        model.workspaceSidebarAppearance.panelsCoverEveryDisplay = false
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
        model.workspaceSidebarAppearance.panelsCoverEveryDisplay = true
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
    }

    func testMenuChoiceOutlastsCoverageChanges() {
        let model = model(target: displays[0])
        model.refreshWorkspaceSidebarMonitorScope()
        selectWorkspaceSidebarMonitorScope(displays[0], viewModel: model)
        model.workspaceSidebarAppearance.panelsCoverEveryDisplay = false
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
    }

    func testPanelsCoverEveryDisplayFollowsTheMonitorSetting() {
        let previousConfig = config
        defer {
            config = previousConfig
            setMonitorsForTests(nil)
        }
        setMonitorsForTests([
            monitor(1, "Studio Display", x: 0, isMain: true),
            monitor(2, "Built-in Retina Display", x: 1920, isMain: false),
        ])
        for (descriptions, covers) in [
            ([], true),
            ([MonitorDescription.sequenceNumber(1)], false),
            ([.sequenceNumber(1), .sequenceNumber(2)], true),
            // Legacy 'main' means every display; an unmatched list falls back to the main display.
            ([.main], true),
            ([.sequenceNumber(9)], false),
        ] as [([MonitorDescription], Bool)] {
            config.workspaceSidebar.monitor = descriptions
            XCTAssertEqual(workspaceSidebarPanelsCoverEveryDisplay(), covers, "\(descriptions)")
            XCTAssertEqual(workspaceSidebarConfiguration().defaultsToOwnDisplay, covers, "\(descriptions)")
        }
    }

    func testManualFiltersSurviveFocusChangesExpansionAndModeChanges() {
        for selection in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0], displays[1]] {
            let model = model(target: displays[1])
            model.refreshWorkspaceSidebarMonitorScope()
            let actions = makeWorkspaceSidebarActionsAdapter(viewModel: model, targetMonitorScopeId: displays[1])
            actions.send(.selectMonitorScope(selection))
            for mode in modes + [.dock] {
                setMode(mode, on: model)
                model.workspaceSidebarFocusedMonitorScopeId = displays[2]
                model.isWorkspaceSidebarExpanded.toggle()
                model.refreshWorkspaceSidebarMonitorScope()
                XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, selection)
            }
        }
    }

    func testChangingTheSettingReplacesEarlierMenuChoices() {
        let model = model(target: displays[1])
        model.refreshWorkspaceSidebarMonitorScope()
        selectWorkspaceSidebarMonitorScope(displays[2], viewModel: model)
        model.workspaceSidebarAppearance.displayFilter = .allDisplays
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)

        // A choice made under the new setting lasts until the setting changes again.
        selectWorkspaceSidebarMonitorScope(displays[0], viewModel: model)
        for _ in 0..<3 { model.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
        model.workspaceSidebarAppearance.displayFilter = .thisDisplay
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[1])
    }

    func testDisconnectedManualDisplayReturnsToTheDefaultAndStaysThere() {
        let model = model(target: displays[0])
        model.refreshWorkspaceSidebarMonitorScope()
        selectWorkspaceSidebarMonitorScope(displays[1], viewModel: model)
        model.workspaceSidebarMonitorScopes.removeAll { $0.id == displays[1] }
        for _ in 0..<3 { model.refreshWorkspaceSidebarMonitorScope() }
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId] + displays)
        model.refreshWorkspaceSidebarMonitorScope()
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
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
        XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, displays[0])
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

    func testOwnDisplayIsInteractiveInEveryModeWithoutEnablingOtherDisplaysOrFocus() {
        let model = model(target: displays[0])
        for mode in modes {
            setMode(mode, on: model)
            for selection in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0], displays[1]] {
                selectWorkspaceSidebarMonitorScope(selection, viewModel: model)
                let view = WorkspaceSidebarView(snapshot: workspaceSidebarSnapshot(from: model))
                XCTAssertEqual(view.allowsWorkspaceActivation(projectId: workspaceProjectDefaultId),
                    selection == workspaceSidebarDefaultScopeId || selection == displays[0], "\(mode) \(selection)")
            }
        }
    }

    func testDisplayMenuNamesEveryDisplayAndListsThisDisplayFirst() {
        let previousConfig = config
        defer { config = previousConfig }
        config.workspaceSidebar.enableFocus = true
        let catalog = buildWorkspaceSidebarMonitorScopes(sortedMonitors: [
            monitor(1, "Studio Display", x: 0, isMain: true),
            monitor(2, "Built-in Retina Display", x: 1920, isMain: false),
            monitor(3, "DELL U2723QE", x: 3840, isMain: false),
            monitor(4, "DELL U2723QE", x: 5760, isMain: false),
            monitor(5, " ", x: 7680, isMain: false),
            monitor(6, "", x: 9600, isMain: false),
        ], focusedMonitorScopeId: displays[0])
        XCTAssertEqual(catalog.map(\.displayName), ["All Displays", "Focused", "Studio Display",
            "Built-in Retina Display", "DELL U2723QE 1", "DELL U2723QE 2", "Display 5", "Display 6"])

        let menu = workspaceSidebarMonitorScopeMenu(catalog, targetScopeId: displays[1])
        XCTAssertEqual(menu.map(\.displayName), ["This Display", "All Displays", "Focused", "Studio Display",
            "DELL U2723QE 1", "DELL U2723QE 2", "Display 5", "Display 6"])
        XCTAssertEqual(menu.first?.id, displays[1])
        XCTAssertEqual(menu.first?.subtitle, "Built-in Retina Display")
        XCTAssertEqual(workspaceSidebarMonitorScopeMenu(catalog, targetScopeId: workspaceSidebarDefaultScopeId), catalog)
    }

    func testSearchResultHiddenByADisplayFilterChangeIsNotOpened() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.usesTabsList = true
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Work", colorHex: nil)]
        snapshot.targetMonitorScopeId = displays[0]
        snapshot.monitorScopes = scopes([workspaceSidebarDefaultScopeId] + displays)
        snapshot.workspaces = [workspace("here", on: displays[0], windowId: 1), workspace("there", on: displays[1], windowId: 2)]
        snapshot.selectedMonitorScopeId = workspaceSidebarDefaultScopeId
        let allDisplays = WorkspaceSidebarView(snapshot: snapshot, searchText: "Notes").currentSearchSelections()
        XCTAssertEqual(allDisplays, [.window(1), .window(2)])

        snapshot.selectedMonitorScopeId = displays[0]
        let thisDisplay = WorkspaceSidebarView(snapshot: snapshot, searchText: "Notes").currentSearchSelections()
        XCTAssertEqual(thisDisplay, [.window(1)])
        XCTAssertNil(workspaceSidebarListedSearchTarget(.window(2), in: thisDisplay))
        XCTAssertEqual(workspaceSidebarListedSearchTarget(.window(1), in: thisDisplay), .window(1))
        XCTAssertNil(workspaceSidebarListedSearchTarget(nil, in: thisDisplay))
    }

    func testSearchKeysReadTheCurrentFilterAfterAScopeChange() async throws {
        _ = NSApplication.shared
        let cases: [([String], [WorkspaceSidebarAction])] = [(["Notes 1", "Notes 2"], [.selectWindow(1)]), (["Mail 1", "Notes 2"], [])]
        for mode in modes {
            for (titles, expected) in cases {
            var sent: [WorkspaceSidebarAction] = []
            let actions = WorkspaceSidebarActions(send: { sent.append($0) })
            let relay = WorkspaceSidebarSearchKeyRelay()
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = mode == .tabs
            snapshot.configuration.showAppIcons = mode == .dock
            snapshot.visibleWidth = 280
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Work", colorHex: nil)]
            snapshot.targetMonitorScopeId = displays[0]
            snapshot.monitorScopes = scopes([workspaceSidebarDefaultScopeId] + displays)
            snapshot.workspaces = [workspace("here", on: displays[0], windowId: 1, title: titles[0]),
                workspace("there", on: displays[1], windowId: 2, title: titles[1])]
            snapshot.selectedMonitorScopeId = workspaceSidebarDefaultScopeId
            let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot, actions: actions,
                reduceMotionOverride: true, reduceTransparencyOverride: true, searchKeyRelay: relay))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            relay.send(.text("Notes"))

            // Reloading to This Display hides the other display's match while the search stays open.
            snapshot.selectedMonitorScopeId = displays[0]
            host.rootView = WorkspaceSidebarView(snapshot: snapshot, actions: actions,
                reduceMotionOverride: true, reduceTransparencyOverride: true, searchKeyRelay: relay)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            relay.send(.moveDown)
            relay.send(.commit)
            relay.send(.commit)
            XCTAssertEqual(sent.filter { if case .selectWindow = $0 { true } else { false } }, expected, "\(mode) \(titles)")
            }
        }
    }

    func testTabsDisplayMenuAppearsOnlyWhenThereIsAChoice() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.monitorScopes = scopes([workspaceSidebarDefaultScopeId, displays[0]])
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).showsTabsDisplayMenu)
        snapshot.monitorScopes = scopes([workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId, displays[0]])
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).showsTabsDisplayMenu)
        snapshot.monitorScopes = scopes([workspaceSidebarDefaultScopeId, displays[0], displays[1]])
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).showsTabsDisplayMenu)
    }

    func testPanelSyncAppliesOwnDisplayDefaultAfterCopyingItsTargetAndAvailableScopes() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let panel = WorkspaceSidebarPanel.shared
        let model = panel.viewModel
        let previousConfig = config
        let previousSharedScopes = TrayMenuModel.shared.workspaceSidebarMonitorScopes
        let previousScopes = model.workspaceSidebarMonitorScopes
        let previousTarget = model.workspaceSidebarTargetMonitorScopeId
        let previousSelection = model.workspaceSidebarSelectedMonitorScopeId
        let previousChoice = model.workspaceSidebarMonitorScopeChoiceFilter
        let previousAppearance = model.workspaceSidebarAppearance
        defer {
            config = previousConfig
            TrayMenuModel.shared.workspaceSidebarMonitorScopes = previousSharedScopes
            model.workspaceSidebarMonitorScopes = previousScopes
            model.workspaceSidebarTargetMonitorScopeId = previousTarget
            model.workspaceSidebarSelectedMonitorScopeId = previousSelection
            model.workspaceSidebarMonitorScopeChoiceFilter = previousChoice
            model.workspaceSidebarAppearance = previousAppearance
        }
        config.workspaceSidebar.monitor = []
        TrayMenuModel.shared.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, panel.monitorScopeId])
        for mode in modes {
            config.workspaceSidebar.mode = mode
            config.workspaceSidebar.displayFilter = .thisDisplay
            model.workspaceSidebarMonitorScopeChoiceFilter = nil
            model.workspaceSidebarSelectedMonitorScopeId = workspaceSidebarDefaultScopeId
            model.workspaceSidebarTargetMonitorScopeId = workspaceSidebarDefaultScopeId

            panel.syncModelFromShared()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, panel.monitorScopeId, "\(mode)")
            selectWorkspaceSidebarMonitorScope(workspaceSidebarDefaultScopeId, viewModel: model)
            panel.syncModelFromShared()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId, "\(mode)")

            // Changing the setting in Settings replaces the menu choice with the new default.
            config.workspaceSidebar.displayFilter = .allDisplays
            panel.syncModelFromShared()
            config.workspaceSidebar.displayFilter = .thisDisplay
            panel.syncModelFromShared()
            XCTAssertEqual(model.workspaceSidebarSelectedMonitorScopeId, panel.monitorScopeId, "\(mode)")
        }
    }

    private func model(target: String, mode: WorkspaceSidebarMode = .dock) -> TrayMenuModel {
        let model = TrayMenuModel()
        setMode(mode, on: model)
        model.workspaceSidebarTargetMonitorScopeId = target
        model.workspaceSidebarMonitorScopes = scopes([workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId] + displays)
        model.workspaceSidebarFocusedMonitorScopeId = displays[0]
        return model
    }

    private func setMode(_ mode: WorkspaceSidebarMode, on model: TrayMenuModel) {
        model.workspaceSidebarAppearance.showAppIcons = mode == .dock
        model.workspaceSidebarAppearance.usesTabsList = mode == .tabs
    }

    private func workspace(_ name: String, on scopeId: String, windowId: UInt32? = nil,
                           title: String? = nil) -> WorkspaceSidebarWorkspaceViewModel {
        let items: [WorkspaceSidebarItemViewModel] = windowId.map { id in
            [.init(kind: .window(.init(windowId: id, workspaceName: name, appName: title ?? "Notes", appBundleId: nil,
                appBundlePath: nil, title: title ?? "Notes \(id)", isFocused: false)))]
        } ?? []
        return .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: name,
            isGeneratedName: false, monitorScopeId: scopeId, monitorName: nil, isFocused: false, isVisible: false, items: items)
    }

    private func monitor(_ id: Int, _ name: String, x: CGFloat, isMain: Bool) -> TestMonitor {
        let rect = Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080)
        return TestMonitor(monitorAppKitNsScreenScreensId: id, name: name, rect: rect, visibleRect: rect, isMain: isMain)
    }

    private func scopes(_ ids: [String]) -> [WorkspaceSidebarMonitorScopeViewModel] {
        ids.map { .init(id: $0, displayName: $0, subtitle: nil, systemImageName: "display", isFocusedMonitor: false) }
    }
}
