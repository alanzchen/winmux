import AppKit
@testable import AppBundle
import Combine
import Common
import SwiftUI
import XCTest

/// `share-pinned-tabs`: every display's Tabs sidebar shows its project's pins from every display, in
/// one order, and a pin clicked on a display comes to it. Nothing is stored per display, so the
/// setting only changes what the lists show; with it off, everything is as before.
@MainActor
final class WorkspaceSidebarSharedPinsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: The setting

    func testSharePinnedTabsIsATabsSettingThatDefaultsOff() {
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            mode = 'tabs'
            share-pinned-tabs = true
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.workspaceSidebar.sharePinnedTabs)
        XCTAssertTrue(workspaceSidebarConfiguration(parsed).sharesPinnedTabs)
        var dock = parsed
        dock.workspaceSidebar.mode = .dock
        XCTAssertFalse(workspaceSidebarConfiguration(dock).sharesPinnedTabs, "Pins are Tabs mode's")
        XCTAssertFalse(defaultConfig.workspaceSidebar.sharePinnedTabs)
        XCTAssertFalse(workspaceSidebarConfiguration(defaultConfig).sharesPinnedTabs)

        let field = SettingsCatalog.field("workspace-sidebar.share-pinned-tabs")
        XCTAssertEqual(field.modes, [.tabs])
        XCTAssertEqual(SettingsPanelLayout.sections(.tabs).first { $0.id == SettingsPanelLayout.tabsContentSection }?.fields.first,
            field.id)
        XCTAssertTrue(SettingsCatalog.results("pinned tabs").contains { $0.id == field.id })
        var configuration = defaultConfig
        field.project?(&configuration, .bool(true))
        XCTAssertTrue(configuration.workspaceSidebar.sharePinnedTabs)

        // Saved from Settings, the key reads back from the file.
        let text = updateSettingsScalarConfig(in: "[workspace-sidebar]\nmode = 'tabs'\n", section: "workspace-sidebar",
            key: "share-pinned-tabs", renderedValue: "true")
        XCTAssertTrue(parseConfig(text).config.workspaceSidebar.sharePinnedTabs, text)
    }

    // MARK: What each display lists

    func testEachDisplayShowsOnlyItsOwnPinsWhenSharingIsOff() async throws {
        for count in [2, 3] {
            let (monitors, _) = try resetDisplaysOfTabs(count)
            await updateWorkspaceSidebarModel()
            let scopes: [String?] = [nil, workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId] + monitors.map(scope)
            for (index, monitor) in monitors.enumerated() {
                XCTAssertEqual(pins(snapshot(on: monitor, sharing: false)), ["pin\(index)"])
                for scope in scopes {
                    let off = snapshot(on: monitor, sharing: false, listing: scope)
                    XCTAssertEqual(off.tabsListedWorkspacesByProject.mapValues { $0.map(\.name) }, previousListing(off),
                        "The listing is the one before shared pins: \(count) displays, \(scope ?? "own")")
                }
            }
        }
    }

    func testEveryDisplayShowsTheProjectsPinsInOneOrderWhenSharingIsOn() async throws {
        for count in [2, 3] {
            let (monitors, tabs) = try resetDisplaysOfTabs(count)
            // The last display's pin, arranged first, before the pins it never shared a list with.
            try pinWorkspaceSidebarTab(tabs["pin\(count - 1)"]!, beside: .init(workspaceName: "pin0", isAfter: false))
            await updateWorkspaceSidebarModel()
            let order = workspacePinnedTabs(in: tabs["pin0"]!.projectId).map(\.name)
            XCTAssertEqual(order, ["pin\(count - 1)"] + (0 ..< count - 1).map { "pin\($0)" })
            for (index, monitor) in monitors.enumerated() {
                let shared = snapshot(on: monitor, sharing: true)
                XCTAssertEqual(pins(shared), order, "\(count) displays: display \(index) shows every pin, in the saved order")
                let listed = shared.tabsListedWorkspaces(for: shared.activeProjectId).map(\.name)
                XCTAssertEqual(Array(listed.prefix(order.count)), order, "Pins first")
                XCTAssertEqual(listed.filter { $0.hasPrefix("shown") }, ["shown\(index)"],
                    "Only the pins are shared; the list keeps its own display's tabs")
                XCTAssertEqual(pins(snapshot(on: monitor, sharing: false)), ["pin\(index)"])
            }
        }
    }

    func testSharedPinsFollowTheSavedPinOrderArrangedOrNot() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        try pinWorkspaceSidebarTab(tabs["pin2"]!, beside: .init(workspaceName: "pin0", isAfter: true))
        await updateWorkspaceSidebarModel()
        let order = workspacePinnedTabs(in: tabs["pin0"]!.projectId).map(\.name)
        for monitor in monitors {
            XCTAssertEqual(pins(snapshot(on: monitor, sharing: true)), order)
        }
    }

    func testSharedPinsKeepEachProjectsOwn() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        let other = createWorkspaceProject()
        let q = Workspace.get(byName: "q")
        _ = TestWindow.new(id: 50, parent: q.rootTilingContainer)
        q.assignProject(other.id)
        q.preferredMonitorPoint = monitors[1].rect.topLeftCorner
        XCTAssertTrue(monitors[1].setActiveWorkspace(q))
        try setWorkspaceSidebarTabFavorite(q, true)
        await updateWorkspaceSidebarModel()

        let left = snapshot(on: monitors[0], sharing: true)
        let right = snapshot(on: monitors[1], sharing: true)
        XCTAssertEqual(left.activeProjectId, tabs["pin0"]!.projectId)
        XCTAssertEqual(right.activeProjectId, other.id)
        XCTAssertEqual(pins(left), ["pin0", "pin1"], "The other project's pin isn't shared into this one")
        XCTAssertEqual(pins(right), ["q"])
        XCTAssertEqual(right.tabsPinnedWorkspaces(for: left.activeProjectId).map(\.name), ["pin0", "pin1"])

        // The adjacent destination panel: a projection of the right display, made on the left one,
        // names the right display's project and shows its pins, shared or not.
        for sharing in [true, false] {
            var projection = snapshot(on: monitors[0], sharing: sharing)
            projection.selectedMonitorScopeId = scope(monitors[1])
            projection.targetMonitorScopeId = scope(monitors[1])
            projection.activeProjectId = activeWorkspaceProjectId(for: monitors[1])
            XCTAssertEqual(pins(projection), ["q"])
            XCTAssertEqual(projection.tabsListedWorkspacesByProject.mapValues { $0.map(\.name) },
                snapshot(on: monitors[1], sharing: sharing).tabsListedWorkspacesByProject.mapValues { $0.map(\.name) })
        }
    }

    func testEachTabIsListedOnceAndListsKeepTheirDisplay() async throws {
        let (monitors, _) = try resetDisplaysOfTabs(3)
        await updateWorkspaceSidebarModel()
        for (index, monitor) in monitors.enumerated() {
            let names = snapshot(on: monitor, sharing: true).tabsListedWorkspacesByProject.values.joined().map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "No tab twice")
            XCTAssertEqual(names.filter { $0.hasPrefix("shown") }, ["shown\(index)"], "Other displays' unpinned tabs stay theirs")
        }
    }

    func testAllDisplaysAndFocusedListingsAreUnchanged() async throws {
        let (monitors, _) = try resetDisplaysOfTabs(3)
        await updateWorkspaceSidebarModel()
        for monitor in monitors {
            for scope in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId] {
                XCTAssertEqual(snapshot(on: monitor, sharing: true, listing: scope).tabsListedWorkspacesByProject,
                    snapshot(on: monitor, sharing: false, listing: scope).tabsListedWorkspacesByProject, scope)
            }
        }
    }

    func testLeftEmptyTabsStayUnlisted() {
        var pin = viewModel("empty", on: "monitor:1920.0,0.0", windowId: 1, pinned: true)
        pin.isLeftEmpty = true
        for sharing in [true, false] {
            XCTAssertEqual(workspaceSidebarTabsListedWorkspacesByProject([pin], selectedScopeId: "monitor:0.0,0.0",
                focusedMonitorScopeId: "", collections: [], sharesPinnedTabs: sharing), [:])
        }
    }

    // MARK: Edits, the stores and displays

    func testPinUnpinAndRearrangeOnOneDisplayShowOnEveryPanel() async throws {
        try skipWithoutWindowServer()
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        config.workspaceSidebar.sharePinnedTabs = true
        let panels = try await panelsForDisplays(monitors)
        defer { retirePanels() }
        let projectId = tabs["pin0"]!.projectId
        func everyPanelShowsTheSavedOrder(_ message: String) {
            let order = workspacePinnedTabs(in: projectId).map(\.name)
            for panel in panels { XCTAssertEqual(pins(workspaceSidebarSnapshot(from: panel.viewModel)), order, message) }
        }
        everyPanelShowsTheSavedOrder("At the start")

        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite("shown2", true),
            targetMonitorScopeId: scope(monitors[0]))?.value
        await updateWorkspaceSidebarModel()
        XCTAssertTrue(workspacePinnedTabs(in: projectId).contains { $0.name == "shown2" })
        everyPanelShowsTheSavedOrder("Pinned from the first display's menu")
        XCTAssertTrue(monitors[2].activeWorkspace === tabs["shown2"], "Pinning moves nothing")

        try pinWorkspaceSidebarTab(tabs["pin2"]!, beside: .init(workspaceName: "pin0", isAfter: false))
        await updateWorkspaceSidebarModel()
        XCTAssertEqual(workspacePinnedTabs(in: projectId).first?.name, "pin2")
        everyPanelShowsTheSavedOrder("Rearranged")

        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite("pin1", false),
            targetMonitorScopeId: scope(monitors[2]))?.value
        await updateWorkspaceSidebarModel()
        everyPanelShowsTheSavedOrder("Unpinned from the last display")
        for (index, panel) in panels.enumerated() {
            let listed = workspaceSidebarSnapshot(from: panel.viewModel).tabsListedWorkspaces(for: projectId).map(\.name)
            XCTAssertEqual(listed.contains("pin1"), index == 1, "An unpinned tab goes back to its own display's list")
        }
    }

    func testTogglingSharingWritesNeitherStoreAndLosesNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-pins-\(UUID().uuidString)").appendingPathComponent("sidebar-organization.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (monitors, tabs) = try resetDisplaysOfTabs(2, organizationURL: url)
        try pinWorkspaceSidebarTab(tabs["pin1"]!, beside: .init(workspaceName: "pin0", isAfter: false))
        let bytes = try Data(contentsOf: url)
        let organization = workspaceSidebarOrganizationStore.state
        let saved = savedWorkspaceStore.records
        await updateWorkspaceSidebarModel()
        let before = monitors.map { pins(snapshot(on: $0, sharing: false)) }
        XCTAssertEqual(before, [["pin0"], ["pin1"]])

        for sharing in [true, false, true, false] {
            config.workspaceSidebar.sharePinnedTabs = sharing
            await updateWorkspaceSidebarModel()
            for monitor in monitors { _ = snapshot(on: monitor, sharing: config.workspaceSidebar.sharesPinnedTabs).tabsListedWorkspacesByProject }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes, "The organization file is untouched")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state, organization)
        XCTAssertEqual(savedWorkspaceStore.records, saved, "Saved workspaces are untouched")
        XCTAssertEqual(monitors.map { pins(snapshot(on: $0, sharing: false)) }, before, "Each display gets its own pins back")
    }

    func testUndoingAnEditMadeBeforeTogglingStillWorks() async throws {
        let (monitors, _) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite("shown0", true),
            targetMonitorScopeId: scope(monitors[1]))?.value
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["shown0"]?.isFavorite, true)
        config.workspaceSidebar.sharePinnedTabs = false
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertNotEqual(workspaceSidebarOrganizationStore.state.workspaces["shown0"]?.isFavorite, true, "The pin is undone")
        XCTAssertTrue(monitors[0].activeWorkspace.name == "shown0")
    }

    func testAnOrganizationFileFromBeforeSharedPinsRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-pins-\(UUID().uuidString)").appendingPathComponent("sidebar-organization.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = #"{"collections":[],"version":1,"workspaces":{"pin0":{"isFavorite":true,"pinOrder":1},"pin1":{"isFavorite":true,"pinOrder":0}}}"#
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: url)
        let (monitors, _) = try resetDisplaysOfTabs(2, pinning: false)
        workspaceSidebarOrganizationStore = .load(url: url)
        XCTAssertNil(workspaceSidebarOrganizationStore.readOnlyReason)
        await updateWorkspaceSidebarModel()
        for monitor in monitors { XCTAssertEqual(pins(snapshot(on: monitor, sharing: true)), ["pin1", "pin0"]) }
        XCTAssertEqual(pins(snapshot(on: monitors[0], sharing: false)), ["pin0"])
        XCTAssertEqual(pins(snapshot(on: monitors[1], sharing: false)), ["pin1"])

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.winMuxDefault.encode(workspaceSidebarOrganizationStore.state))
            as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
        XCTAssertEqual(encoded.map { Set($0.keys) }, original.map { Set($0.keys) }, "No new keys: the schema is unchanged")
        XCTAssertEqual(encoded?["version"] as? Int, 1)
    }

    func testSharedPinsSurviveADisplayDisconnectingAndReconnecting() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        let projectId = tabs["pin0"]!.projectId
        await updateWorkspaceSidebarModel()
        let all = workspacePinnedTabs(in: projectId).map(\.name)
        XCTAssertEqual(all, ["pin0", "pin1", "pin2"])

        setMonitorsForTests(Array(monitors.prefix(2)))
        Workspace.reconcileWorkspaceState()
        await updateWorkspaceSidebarModel()
        for monitor in monitors.prefix(2) { XCTAssertEqual(pins(snapshot(on: monitor, sharing: true)), all) }
        let fallback = monitors.prefix(2).filter { pins(snapshot(on: $0, sharing: false)).contains("pin2") }
        XCTAssertEqual(fallback.count, 1, "Unshared, the gone display's pin shows on one display, as before")

        setMonitorsForTests(monitors)
        Workspace.reconcileWorkspaceState()
        await updateWorkspaceSidebarModel()
        for monitor in monitors { XCTAssertEqual(pins(snapshot(on: monitor, sharing: true)), all) }
        XCTAssertEqual(pins(snapshot(on: monitors[2], sharing: false)), ["pin2"], "Its pin goes back to it")
        XCTAssertEqual(workspacePinnedTabs(in: projectId).map(\.name), all, "The order never changed")
    }

    func testPinsAndTheirOrderLoadAgainAfterARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-pins-\(UUID().uuidString)").appendingPathComponent("sidebar-organization.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (monitors, tabs) = try resetDisplaysOfTabs(3, organizationURL: url)
        try pinWorkspaceSidebarTab(tabs["pin2"]!, beside: .init(workspaceName: "pin1", isAfter: false))
        await updateWorkspaceSidebarModel()
        let before = monitors.map { pins(snapshot(on: $0, sharing: true)) }

        workspaceSidebarOrganizationStore = .load(url: url)
        await updateWorkspaceSidebarModel()
        XCTAssertEqual(monitors.map { pins(snapshot(on: $0, sharing: true)) }, before)
        XCTAssertEqual(before.first, ["pin0", "pin2", "pin1"])
    }

    // MARK: Clicking a shared pin

    func testClickingAHiddenSharedPinBringsItToTheDisplayClicked() async throws {
        for count in [2, 3] {
            let (monitors, tabs) = try resetDisplaysOfTabs(count)
            config.workspaceSidebar.sharePinnedTabs = true
            let here = monitors[0]
            let far = monitors[count - 1]
            let pin = tabs["pin\(count - 1)"]!
            let order = workspacePinnedTabs(in: pin.projectId).map(\.name)
            let windows = pin.allLeafWindowsRecursive.map(\.windowId)
            XCTAssertFalse(pin.isVisible)
            XCTAssertEqual(pin.workspaceMonitor.rect, far.rect)

            XCTAssertTrue(workspaceSidebarSharedPinClicked(pin.name, targetMonitorScopeId: scope(here)) === pin)
            await showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: scope(here))?.value
            XCTAssertTrue(here.activeWorkspace === pin, "\(count) displays: it's on the display clicked")
            XCTAssertTrue(focus.workspace === pin, "Focus is there too")
            XCTAssertTrue(far.activeWorkspace === tabs["shown\(count - 1)"], "Its old display keeps what it showed")
            XCTAssertEqual(pin.workspaceMonitor.rect, here.rect)
            XCTAssertEqual(pin.preferredMonitorPoint, here.rect.topLeftCorner, "Its new display is recorded")
            XCTAssertEqual(Workspace.all.filter { $0.name == pin.name }.count, 1, "No second tab")
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), windows, "The same windows")
            XCTAssertEqual(workspacePinnedTabs(in: pin.projectId).map(\.name), order, "Still pinned, in the same place")

            // Once another tab takes its place, it's still listed on the display it came to.
            XCTAssertTrue(here.setActiveWorkspace(tabs["shown0"]!))
            await updateWorkspaceSidebarModel()
            XCTAssertEqual(pins(snapshot(on: here, sharing: false)), ["pin0", pin.name])
        }
    }

    func testClickingASharedPinOnScreenElsewhereBringsItHereWithoutAsking() async throws {
        for count in [2, 3] {
            let (monitors, tabs) = try resetDisplaysOfTabs(count)
            config.workspaceSidebar.sharePinnedTabs = true
            let shown = tabs["shown\(count - 1)"]!
            let from = monitors[count - 1]
            let here = monitors[count - 2]
            try setWorkspaceSidebarTabFavorite(shown, true)
            await updateWorkspaceSidebarModel()
            XCTAssertTrue(from.activeWorkspace === shown)

            let vm = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == shown.name })
            let shared = WorkspaceSidebarView(snapshot: snapshot(on: here, sharing: true))
            XCTAssertFalse(shared.tabActivation(vm, isPinned: false, pageAllowsActivation: true).0.isInUseOnOtherDisplay,
                "No In Use prompt: the click brings it")
            let unshared = WorkspaceSidebarView(snapshot: snapshot(on: here, sharing: false))
            XCTAssertTrue(unshared.tabActivation(vm, isPinned: false, pageAllowsActivation: true).0.isInUseOnOtherDisplay,
                "Unshared, another display's tab asks first, as before")

            XCTAssertTrue(workspaceSidebarSharedPinClicked(shown.name, targetMonitorScopeId: scope(here)) === shown)
            await showSharedPinnedTabFromSidebar(shown, targetMonitorScopeId: scope(here))?.value
            XCTAssertTrue(here.activeWorkspace === shown, "\(count) displays")
            XCTAssertFalse(from.activeWorkspace === shown, "Its old display shows another tab")
            XCTAssertEqual(from.activeWorkspace.projectId, shown.projectId)
            XCTAssertTrue(focus.workspace === shown)
            XCTAssertEqual(focus.workspace.workspaceMonitor.rect, here.rect, "Focus stays on the display clicked")
            XCTAssertEqual(shown.preferredMonitorPoint, here.rect.topLeftCorner)
        }
    }

    func testClickingAWindowOfASharedPinFocusesThatWindowHere() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        let pin = tabs["pin1"]!
        let second = TestWindow.new(id: 60, parent: pin.rootTilingContainer)
        XCTAssertTrue(workspaceSidebarSharedPinClicked(windowId: second.windowId, targetMonitorScopeId: scope(monitors[0])) === pin)
        await showSharedPinnedTabFromSidebar(pin, windowId: second.windowId, targetMonitorScopeId: scope(monitors[0]))?.value
        XCTAssertTrue(monitors[0].activeWorkspace === pin)
        XCTAssertTrue(focus.windowOrNil === second)
    }

    func testSidebarClicksOnASharedPinGoThroughTheBringHerePath() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        let here = scope(monitors[0])
        handleWorkspaceSidebarAction(.selectWorkspace("pin1"), targetMonitorScopeId: here)
        try await waitUntil { monitors[0].activeWorkspace === tabs["pin1"] }
        XCTAssertEqual(tabs["pin1"]!.preferredMonitorPoint, monitors[0].rect.topLeftCorner, "Brought, and its display recorded")
        let window = try XCTUnwrap(tabs["shown1"]!.anyLeafWindowRecursive)
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        handleWorkspaceSidebarAction(.selectWindow(window.windowId), targetMonitorScopeId: here)
        try await waitUntil { monitors[0].activeWorkspace === tabs["shown1"] }
        XCTAssertTrue(focus.windowOrNil === window)
        handleWorkspaceSidebarAction(.openSavedTab("pin1"), targetMonitorScopeId: scope(monitors[1]))
        try await waitUntil { monitors[1].activeWorkspace === tabs["pin1"] }
    }

    func testWithSharingOffClicksDoWhatTheyDidBefore() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        let here = scope(monitors[0])
        XCTAssertNil(workspaceSidebarSharedPinClicked("pin1", targetMonitorScopeId: here))
        XCTAssertNil(workspaceSidebarSharedPinClicked("shown1", targetMonitorScopeId: here))
        // An unpinned tab isn't a shared pin, shared or not.
        config.workspaceSidebar.sharePinnedTabs = true
        XCTAssertNil(workspaceSidebarSharedPinClicked("shown1", targetMonitorScopeId: scope(monitors[1])), "Already there")
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, false)
        XCTAssertNil(workspaceSidebarSharedPinClicked("shown1", targetMonitorScopeId: here))
        config.workspaceSidebar.sharePinnedTabs = false

        // Before: a click on a tab on screen elsewhere, past the prompt, moves nothing.
        XCTAssertFalse(focusWorkspaceFromSidebar(tabs["shown1"]!, targetMonitorScopeId: here))
        XCTAssertTrue(monitors[1].activeWorkspace === tabs["shown1"])
        // And a hidden one opens on the display clicked.
        XCTAssertTrue(focusWorkspaceFromSidebar(tabs["pin1"]!, targetMonitorScopeId: here))
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["pin1"])
    }

    func testAPinHeldToItsDisplayKeepsTodaysBehavior() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        let shown = tabs["shown1"]!
        try setWorkspaceSidebarTabFavorite(shown, true)
        config.workspaceToMonitorForceAssignment[shown.name] = [.secondary]
        config.workspaceToMonitorForceAssignment["pin1"] = [.secondary]
        let here = scope(monitors[0])
        await updateWorkspaceSidebarModel()

        XCTAssertNil(workspaceSidebarSharedPinClicked(shown.name, targetMonitorScopeId: here))
        let vm = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == shown.name })
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot(on: monitors[0], sharing: true))
            .tabActivation(vm, isPinned: false, pageAllowsActivation: true).0.isInUseOnOtherDisplay, "It asks, as before")
        XCTAssertEqual(vm.knownDisplay?.heldMonitorScopeId, scope(monitors[1]))
        let location = try XCTUnwrap(snapshot(on: monitors[0], sharing: true).sharedPinLocation(of: vm))
        XCTAssertEqual(location.help(), "On “Right”", "No promise of a move it won't make")
        XCTAssertThrowsError(try showSharedPinnedTab(shown, on: monitors[0], focusing: nil))
        XCTAssertTrue(monitors[1].activeWorkspace === shown, "Nothing moved")
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown0"])

        // Held without a saved record, which gives no saved state: it still asks.
        var unsaved = vm
        unsaved.savedState = nil
        XCTAssertFalse(workspaceSidebarSharedPinComesToClick(unsaved, representedMonitorScopeId: here, sharesPinnedTabs: true))
        XCTAssertTrue(workspaceSidebarSharedPinComesToClick(unsaved, representedMonitorScopeId: scope(monitors[1]),
            sharesPinnedTabs: true), "Where it's held, it may come")

        // Hidden and held elsewhere: refused, as before (an open question).
        XCTAssertNil(workspaceSidebarSharedPinClicked("pin1", targetMonitorScopeId: here))
        XCTAssertFalse(focusWorkspaceFromSidebar(tabs["pin1"]!, targetMonitorScopeId: here))
        XCTAssertFalse(tabs["pin1"]!.isVisible)
        // A saved tab kept on its display is held the same way, by `workspaceTabCanMove`; its home
        // resolves only from a real display's identity, which these test displays don't have.
    }

    func testAClickWhoseDisplayWentAwayChangesNothing() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        config.workspaceSidebar.sharePinnedTabs = true
        let pin = tabs["pin0"]!
        let focused = focus.workspace
        let task = showSharedPinnedTabFromSidebar(pin, targetMonitorScopeId: scope(monitors[2]))
        setMonitorsForTests(Array(monitors.prefix(2)))
        await task?.value
        XCTAssertFalse(pin.isVisible, "It isn't shown anywhere else instead")
        XCTAssertTrue(focus.workspace === focused, "Focus doesn't go to its old display")
    }

    // MARK: The badge on a pin that's on another display

    func testTheBadgeShowsOnlyOnPinsOnAnotherConnectedDisplay() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        config.workspaceSidebar.sharePinnedTabs = true
        try setWorkspaceSidebarTabFavorite(tabs["shown2"]!, true)
        await updateWorkspaceSidebarModel()
        let left = snapshot(on: monitors[0], sharing: true)
        XCTAssertNil(location("pin0", in: left), "On this display: no badge")
        XCTAssertEqual(location("pin1", in: left), .init(displayName: "Right", isOnScreen: false))
        XCTAssertEqual(location("pin1", in: left)?.help(), "Assigned to “Right” · Click to move to this display",
            "Hidden there, it's assigned there, not on screen")
        XCTAssertEqual(location("shown2", in: left)?.help(), "On “Far” · Click to move to this display")
        let far = snapshot(on: monitors[2], sharing: true)
        XCTAssertNil(location("shown2", in: far))
        XCTAssertEqual(location("pin0", in: far)?.description, "Assigned to “Left”")
        for monitor in monitors {
            for name in ["pin0", "pin1", "pin2", "shown2"] {
                XCTAssertNil(location(name, in: snapshot(on: monitor, sharing: false)), "Unshared, no badge: \(name)")
            }
        }
        XCTAssertNil(workspaceSidebarSharedPinLocation(try vm("shown0"), representedMonitorScopeId: scope(monitors[1]),
            sharesPinnedTabs: true), "Only pins")
    }

    func testNoBadgeWhereAPinsDisplayIsntKnown() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        config.workspaceSidebar.sharePinnedTabs = true
        // Never placed: listed on the focused display, which says nothing about where it is.
        tabs["pin1"]!.preferredMonitorPoint = nil
        // Pinned but with no windows open: it isn't anywhere yet.
        let unopened = Workspace.get(byName: "unopened")
        unopened.preferredMonitorPoint = monitors[1].rect.topLeftCorner
        try setWorkspaceSidebarTabFavorite(unopened, true)
        await updateWorkspaceSidebarModel()
        XCTAssertNil(try vm("pin1").knownDisplay)
        for monitor in monitors {
            XCTAssertNil(location("pin1", in: snapshot(on: monitor, sharing: true)))
            XCTAssertNil(location("unopened", in: snapshot(on: monitor, sharing: true)))
        }

        // Its display gone, a hidden pin's display isn't known either.
        setMonitorsForTests(Array(monitors.prefix(2)))
        Workspace.reconcileWorkspaceState()
        await updateWorkspaceSidebarModel()
        XCTAssertNil(try vm("pin2").knownDisplay)
        XCTAssertNil(location("pin2", in: snapshot(on: monitors[0], sharing: true)))
        XCTAssertEqual(location("pin0", in: snapshot(on: monitors[1], sharing: true))?.displayName, "Left")

        // One display: nothing to tell apart.
        setMonitorsForTests([monitors[0]])
        Workspace.reconcileWorkspaceState()
        await updateWorkspaceSidebarModel()
        XCTAssertTrue(TrayMenuModel.shared.workspaceSidebarWorkspaces.allSatisfy { $0.knownDisplay == nil })
    }

    func testTheBadgeFollowsAPinBroughtHereAndStaysOnAFailure() async throws {
        try skipWithoutWindowServer()
        let (monitors, tabs) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        let panels = try await panelsForDisplays(monitors)
        defer { retirePanels() }
        func badge(_ name: String, on index: Int) throws -> String? {
            let snapshot = workspaceSidebarSnapshot(from: panels[index].viewModel)
            let workspace = try XCTUnwrap(snapshot.workspaces.first { $0.name == name })
            return snapshot.sharedPinLocation(of: workspace)?.description
        }
        XCTAssertEqual(try badge("pin1", on: 0), "Assigned to “Right”")
        XCTAssertNil(try badge("pin1", on: 1))

        await showSharedPinnedTabFromSidebar(tabs["pin1"]!, targetMonitorScopeId: scope(monitors[0]))?.value
        await updateWorkspaceSidebarModel()
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        XCTAssertNil(try badge("pin1", on: 0), "Here now: no badge")
        XCTAssertEqual(try badge("pin1", on: 1), "On “Left”", "The display it left shows where it went")

        // A pin that can't come keeps its badge, and says where it really is.
        let held = tabs["shown1"]!
        try setWorkspaceSidebarTabFavorite(held, true)
        config.workspaceToMonitorForceAssignment[held.name] = [.secondary]
        XCTAssertThrowsError(try showSharedPinnedTab(held, on: monitors[0], focusing: nil))
        await updateWorkspaceSidebarModel()
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        XCTAssertEqual(try badge(held.name, on: 0), "On “Right”")
        XCTAssertNil(try badge(held.name, on: 1))
    }

    func testADestinationPanelBadgesAgainstTheDisplayItStandsFor() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        config.workspaceSidebar.sharePinnedTabs = true
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        await updateWorkspaceSidebarModel()
        // The far display's list, shown on the left one while a drag goes there.
        var projection = snapshot(on: monitors[0], sharing: true)
        projection.selectedMonitorScopeId = scope(monitors[2])
        projection.targetMonitorScopeId = scope(monitors[2])
        projection.activeProjectId = activeWorkspaceProjectId(for: monitors[2])
        XCTAssertNil(location("pin2", in: projection), "The far display's own pin")
        XCTAssertEqual(location("pin0", in: projection)?.description, "Assigned to “Left”", "Even on the left display's screen")
        XCTAssertEqual(location("shown1", in: projection)?.description, "On “Right”")
        XCTAssertEqual(workspaceSidebarSharedPinLocation(try vm("pin0"), representedMonitorScopeId: scope(monitors[2]),
            sharesPinnedTabs: true)?.displayName, "Left", "The represented display is a parameter")
    }

    /// The badge is only a cue: clicks and drags on its corner still reach the pin.
    func testClicksAndDragsOnTheBadgeReachThePin() async throws {
        try skipWithoutWindowServer()
        var clicks: [UInt32?] = []
        var drags: [String] = []
        let actions = WorkspaceSidebarActions(send: { _ in }, pinnedTabDragChanged: { name, _ in drags.append(name) },
            pinnedTabDragEnded: { name, _ in drags.append("end " + name) })
        var pin = viewModel("pin", on: "monitor:1920.0,0.0", windowId: 7, pinned: true)
        pin.knownDisplay = .init(monitorScopeId: "monitor:1920.0,0.0", displayName: "Right")
        let tile = WorkspaceSidebarPinnedTab(workspace: pin, badgeModel: WorkspaceSidebarDockBadgeModel(),
            targetMonitorScopeId: "monitor:0.0,0.0", actions: actions,
            sharedPinLocation: .init(displayName: "Right", isOnScreen: false)) { clicks.append($0) }
            .frame(width: 90, height: 54)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 90, height: 54), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: tile)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        // The badge, in window coordinates (bottom-left origin).
        let badge = CGPoint(x: 11, y: 10)
        try send(.leftMouseDown, at: badge)
        try send(.leftMouseUp, at: badge)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clicks, [7], "A click on the badge selects the pin")

        try send(.leftMouseDown, at: badge)
        try send(.leftMouseDragged, at: CGPoint(x: 30, y: 30))
        try send(.leftMouseUp, at: CGPoint(x: 30, y: 30))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(drags.first, "pin", "A drag from the badge drags the pin")
        XCTAssertEqual(drags.last, "end pin")
    }

    func testShiftClickRangesFollowTheSharedPinsShown() async throws {
        let (monitors, tabs) = try resetDisplaysOfTabs(3)
        try pinWorkspaceSidebarTab(tabs["pin2"]!, beside: .init(workspaceName: "pin0", isAfter: false))
        await updateWorkspaceSidebarModel()
        for (index, monitor) in monitors.enumerated() {
            let shared = snapshot(on: monitor, sharing: true)
            let order = WorkspaceSidebarView(snapshot: shared).workspaceSidebarTabSelectionContext(projectId: shared.activeProjectId).order
            XCTAssertEqual(Array(order.prefix(3)), ["pin2", "pin0", "pin1"], "The tiles as shown, then the list")
            XCTAssertTrue(order.contains("shown\(index)"))
            let unshared = snapshot(on: monitor, sharing: false)
            XCTAssertEqual(WorkspaceSidebarView(snapshot: unshared).workspaceSidebarTabSelectionContext(projectId: unshared.activeProjectId)
                .order.filter { $0.hasPrefix("pin") }, ["pin\(index)"])
        }
    }

    // MARK: Search and browser reads

    func testSharedPinsAreSearchedAndWatchedWhereTheyShow() {
        let here = "monitor:0.0,0.0"
        let there = "monitor:1920.0,0.0"
        var remote = viewModel("remote", on: there, windowId: 2, pinned: true, title: "Notes 2")
        remote.isVisible = true
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.usesTabsList = true
        snapshot.visibleWidth = 280
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Work", colorHex: nil)]
        snapshot.selectedMonitorScopeId = here
        snapshot.targetMonitorScopeId = here
        snapshot.workspaces = [viewModel("local", on: here, windowId: 1, title: "Notes 1"), remote]

        snapshot.configuration.sharesPinnedTabs = true
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot, searchText: "Notes").currentSearchSelections(), [.window(2), .window(1)])
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).watchedBrowserWindowIds.contains(2), "Its sound and icon read here")
        snapshot.configuration.sharesPinnedTabs = false
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot, searchText: "Notes").currentSearchSelections(), [.window(1)])
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).watchedBrowserWindowIds.contains(2), "As before")

        // Searching another project: its shared pins are watched before they match, so a browser
        // tab's title can be found in them.
        let other = WorkspaceProjectId("other")
        var otherPin = viewModel("other-pin", on: there, windowId: 3, pinned: true, projectId: other)
        otherPin.isVisible = true
        snapshot.workspaces.append(otherPin)
        snapshot.configuration.sharesPinnedTabs = true
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot, searchText: "x").watchedBrowserWindowIds.contains(3))
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).watchedBrowserWindowIds.contains(3), "Not while not searching")
    }

    /// Turning sharing off while a remote pin is the selected result: the selection moves to a
    /// result still listed, so Enter opens that one instead of nothing.
    func testTurningSharingOffReselectsAListedSearchResult() async throws {
        _ = NSApplication.shared
        var sent: [WorkspaceSidebarAction] = []
        let actions = WorkspaceSidebarActions(send: { sent.append($0) })
        let relay = WorkspaceSidebarSearchKeyRelay()
        let here = "monitor:0.0,0.0"
        var remote = viewModel("remote", on: "monitor:1920.0,0.0", windowId: 2, pinned: true, title: "Notes 2")
        remote.isVisible = true
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.usesTabsList = true
        snapshot.configuration.sharesPinnedTabs = true
        snapshot.visibleWidth = 280
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Work", colorHex: nil)]
        snapshot.selectedMonitorScopeId = here
        snapshot.targetMonitorScopeId = here
        snapshot.workspaces = [viewModel("local", on: here, windowId: 1, title: "Notes 1"), remote]
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot, actions: actions,
            reduceMotionOverride: true, reduceTransparencyOverride: true, searchKeyRelay: relay))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        relay.send(.text("Notes"))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        snapshot.configuration.sharesPinnedTabs = false
        host.rootView = WorkspaceSidebarView(snapshot: snapshot, actions: actions,
            reduceMotionOverride: true, reduceTransparencyOverride: true, searchKeyRelay: relay)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        relay.send(.commit)
        XCTAssertEqual(sent.filter { if case .selectWindow = $0 { true } else { false } }, [.selectWindow(1)])
    }

    // MARK: Publications

    func testSharedPinsPublishOnlyForRealChanges() async throws {
        try skipWithoutWindowServer()
        let (monitors, _) = try resetDisplaysOfTabs(2)
        config.workspaceSidebar.sharePinnedTabs = true
        let panels = try await panelsForDisplays(monitors)
        defer { retirePanels() }
        let counter = PublicationCounter(panels)

        for _ in 0 ..< 3 {
            WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
            await updateWorkspaceSidebarModel()
        }
        XCTAssertEqual(counter.counts, [0, 0], "Unchanged refreshes publish nothing")

        config.workspaceSidebar.sharePinnedTabs = false
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        XCTAssertEqual(counter.counts, [1, 1], "Toggling publishes the settings once per panel")
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        XCTAssertEqual(counter.counts, [1, 1])

        counter.reset()
        config.workspaceSidebar.sharePinnedTabs = true
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite("shown1", true),
            targetMonitorScopeId: scope(monitors[0]))?.value
        await updateWorkspaceSidebarModel()
        let afterEdit = counter.counts
        XCTAssertTrue(afterEdit.allSatisfy { (2 ... 3).contains($0) }, "The setting, then the pin: \(afterEdit)")
        await updateWorkspaceSidebarModel()
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        XCTAssertEqual(counter.counts, afterEdit, "Nothing more once it's shown")
    }

    // MARK: Fixtures

    /// Displays left to right, each showing `shown<i>`, with `pin<i>` hidden on it and pinned.
    private func resetDisplaysOfTabs(_ count: Int, pinning: Bool = true,
                                     organizationURL: URL? = nil) throws -> ([Monitor], [String: Workspace]) {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init(url: organizationURL)
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let names = ["Left", "Right", "Far"]
        let monitors: [Monitor] = (0 ..< count).map { index in
            let rect = Rect(topLeftX: CGFloat(index) * 1920, topLeftY: 0, width: 1920, height: 1080)
            return WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: index + 1, name: names[index],
                rect: rect, visibleRect: rect, isMain: index == 0)
        }
        setMonitorsForTests(monitors)
        Workspace.reconcileWorkspaceState()
        var tabs: [String: Workspace] = [:]
        var windowId: UInt32 = 1
        for (index, monitor) in monitors.enumerated() {
            for name in ["shown\(index)", "pin\(index)"] {
                let tab = Workspace.get(byName: name)
                _ = TestWindow.new(id: windowId, parent: tab.rootTilingContainer)
                windowId += 1
                // A hidden tab belongs to the display it was first placed on.
                tab.preferredMonitorPoint = monitor.rect.topLeftCorner
                tabs[name] = tab
            }
            XCTAssertTrue(monitor.setActiveWorkspace(tabs["shown\(index)"]!))
        }
        XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
        if pinning { try setWorkspaceSidebarTabsFavorite(monitors.indices.map { tabs["pin\($0)"]! }, true) }
        for (index, monitor) in monitors.enumerated() {
            XCTAssertEqual(tabs["pin\(index)"]!.workspaceMonitor.rect, monitor.rect)
        }
        return (monitors, tabs)
    }

    /// What the display's own panel would show, from the shared model.
    private func snapshot(on monitor: Monitor, sharing: Bool, listing scopeId: String? = nil) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        snapshot.selectedMonitorScopeId = scopeId ?? scope(monitor)
        snapshot.targetMonitorScopeId = scope(monitor)
        snapshot.focusedMonitorScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
        snapshot.activeProjectId = activeWorkspaceProjectId(for: monitor)
        snapshot.visibleWidth = 280
        snapshot.configuration.usesTabsList = true
        snapshot.configuration.tabCollections = workspaceSidebarOrganizationStore.state.collections
        snapshot.configuration.sharesPinnedTabs = sharing
        return snapshot
    }

    /// The Tabs listing as it was computed before shared pins.
    private func previousListing(_ snapshot: WorkspaceSidebarSnapshot) -> [WorkspaceProjectId: [String]] {
        workspaceSidebarVisibleWorkspacesByProject(workspaces: snapshot.workspaces.filter { !$0.isLeftEmpty },
            selectedScopeId: snapshot.selectedMonitorScopeId, focusedMonitorScopeId: snapshot.focusedMonitorScopeId,
            browsedProjectId: nil).mapValues { workspaceSidebarOrderedTabs($0, collections: snapshot.configuration.tabCollections).map(\.name) }
    }

    private func location(_ name: String, in snapshot: WorkspaceSidebarSnapshot) -> WorkspaceSidebarSharedPinLocation? {
        snapshot.workspaces.first { $0.name == name }.flatMap(snapshot.sharedPinLocation(of:))
    }

    private func vm(_ name: String) throws -> WorkspaceSidebarWorkspaceViewModel {
        try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == name }, name)
    }

    private func pins(_ snapshot: WorkspaceSidebarSnapshot) -> [String] {
        snapshot.tabsPinnedWorkspaces(for: snapshot.activeProjectId).map(\.name)
    }

    private func scope(_ monitor: Monitor) -> String { workspaceSidebarMonitorScopeId(for: monitor) }

    private func viewModel(_ name: String, on scopeId: String, windowId: UInt32, pinned: Bool = false, title: String? = nil,
                           projectId: WorkspaceProjectId = workspaceProjectDefaultId) -> WorkspaceSidebarWorkspaceViewModel {
        var workspace = WorkspaceSidebarWorkspaceViewModel(name: name, projectId: projectId, displayName: name, sidebarLabel: name,
            isGeneratedName: false, monitorScopeId: scopeId, monitorName: nil, isFocused: false, isVisible: false,
            items: [.init(kind: .window(.init(windowId: windowId, workspaceName: name, appName: "Notes", appBundleId: nil,
                appBundlePath: nil, title: title ?? name, isFocused: false)))])
        workspace.appearance.isFavorite = pinned
        return workspace
    }

    private func skipWithoutWindowServer() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
    }

    /// The real panels for `monitors`, synced from the shared model.
    private func panelsForDisplays(_ monitors: [Monitor]) async throws -> [WorkspaceSidebarPanel] {
        await updateWorkspaceSidebarModel()
        WorkspaceSidebarPanel.refreshAll()
        WorkspaceSidebarPanel.syncVisiblePanelModelsFromShared()
        return try monitors.map { try XCTUnwrap(WorkspaceSidebarPanel.panel(for: scope($0))) }
    }

    private func retirePanels() {
        setMonitorsForTests(nil)
        WorkspaceSidebarPanel.refreshAll()
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class PublicationCounter {
    private(set) var counts: [Int]
    private var subscriptions: [AnyCancellable] = []

    init(_ panels: [WorkspaceSidebarPanel]) {
        counts = Array(repeating: 0, count: panels.count)
        subscriptions = panels.enumerated().map { index, panel in
            panel.viewModel.objectWillChange.sink { [unowned self] in counts[index] += 1 }
        }
    }

    func reset() { counts = Array(repeating: 0, count: counts.count) }
}
