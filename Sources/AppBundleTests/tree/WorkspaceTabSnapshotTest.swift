@testable import AppBundle
import AppKit
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceTabSnapshotTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testTiledAndFloatingWindowsKeepTheirRolesThroughSidebarProjection() async throws {
        let tab = Workspace.get(byName: "mixed")
        let tiled = TestWindow.new(id: 7101, parent: tab.rootTilingContainer, title: "Chat")
        let floating = TestWindow.new(id: 7102, parent: tab, title: "Ulysses")
        let content = WorkspaceTabSnapshot(tab)
        XCTAssertEqual(content.members.map(\.state), [.laidOut, .floating])
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
        let model = try XCTUnwrap(models.first { $0.name == tab.name })
        guard case .mixed(let tiles, let floats) = workspaceSidebarTabPresentation(model) else {
            return XCTFail("A floating Ulysses window must not become half of a tiled split")
        }
        XCTAssertEqual(tiles.map(\.windowId), [tiled.windowId])
        XCTAssertEqual(floats.map(\.windowId), [floating.windowId])
        XCTAssertEqual(workspaceSidebarPinnedTabWindows(model).map(\.state), [.laidOut, .floating])
        XCTAssertEqual([tiled.axRectFetchCount, floating.axRectFetchCount], [0, 0])
    }

    func testTwoTilesKeepTheirSplitWhenAFloatingWindowIsAdded() async throws {
        let tab = Workspace.get(byName: "split-and-float")
        TestWindow.new(id: 7111, parent: tab.rootTilingContainer)
        TestWindow.new(id: 7112, parent: tab.rootTilingContainer)
        TestWindow.new(id: 7113, parent: tab)
        let built = await buildWorkspaceSidebarItems(for: WorkspaceTabSnapshot(tab), currentFocus: focus)
        let model = WorkspaceSidebarWorkspaceViewModel(name: tab.name, projectId: tab.projectId, displayName: tab.name,
            sidebarLabel: "", isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil, isFocused: false, isVisible: false, items: built.items)
        guard case .mixed(let tiled, let floating) = workspaceSidebarTabPresentation(model) else { return XCTFail() }
        XCTAssertEqual(tiled.map(\.windowId), [7111, 7112])
        XCTAssertEqual(floating.map(\.windowId), [7113])
    }

    func testMixedPinnedThumbnailFitsTheExistingTileHeight() async throws {
        let tab = Workspace.get(byName: "mixed-pin")
        TestWindow.new(id: 7114, parent: tab.rootTilingContainer)
        TestWindow.new(id: 7115, parent: tab)
        let built = await buildWorkspaceSidebarItems(for: WorkspaceTabSnapshot(tab), currentFocus: focus)
        let model = WorkspaceSidebarWorkspaceViewModel(name: tab.name, projectId: tab.projectId, displayName: tab.name,
            sidebarLabel: "", isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId,
            monitorName: nil, isFocused: false, isVisible: false, items: built.items, appearance: .init(isFavorite: true))
        XCTAssertEqual(WorkspaceSidebarPinnedGridLayout(workspaces: [model], width: 180).columns, 2,
            "A floating overlay must not reserve the width of a second tiled pane")
        for compact in [false, true] {
            let height: CGFloat = compact ? 34 : 54
            let host = NSHostingView(rootView: WorkspaceSidebarPinnedTab(workspace: model,
                badgeModel: WorkspaceSidebarDockBadgeModel(), compact: compact, onSelect: { _ in }).frame(width: compact ? 34 : 90))
            host.frame = CGRect(x: 0, y: 0, width: compact ? 34 : 90, height: height)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, height, "A float overlays the tile, not another grid row")
            XCTAssertNil(host.window)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = projectRoot.appendingPathComponent(".local/reviews/mixed-pin-\(compact).png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
        }
    }

    private func loan() throws -> (Workspace, Workspace, TestWindow) {
        let pin = Workspace.get(byName: "pin")
        let borrower = Workspace.get(byName: "borrower")
        let app = TestApp(pid: 712, bundleId: "com.example.editor", name: "Editor")
        let window = TestWindow.new(id: 7121, parent: pin.rootTilingContainer, app: app, title: "Document")
        TestWindow.new(id: 7122, parent: borrower.rootTilingContainer, app: app)
        try setWorkspaceSidebarTabFavorite(pin, true)
        try ensureSavedWorkspaceRecord(pin)
        try splitPinnedTabWindowWithTab(pin, borrower.name, placement: .right)
        return (pin, borrower, window)
    }

    func testLentPinKeepsItsSavedSlotBeyondGraceWithoutOwningBorrowersWindow() throws {
        let (pin, borrower, window) = try loan()
        let original = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first)
        XCTAssertEqual(original.lastWindowId, window.windowId)
        let content = WorkspaceTabSnapshot(pin)
        XCTAssertTrue(content.lifecycleMembers.isEmpty)
        XCTAssertEqual(content.lentMember?.window.windowId, window.windowId)
        XCTAssertEqual(content.lentMember?.membership, .lentFromPin)
        XCTAssertEqual(WorkspaceTabSnapshot(borrower).lifecycleMembers.map(\.window.windowId), [7122, 7121])
        XCTAssertEqual(WorkspaceTabClosePlan([pin]).windowCount, 0)
        XCTAssertTrue(collectAllWindowIds(workspace: pin).isEmpty, "Frozen ownership does not duplicate the loan")
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600),
            runningApps: ["com.example.editor": [SavedRunningApp(pid: 712, launchDate: nil)]]))
        let saved = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.lastWindowId, window.windowId)
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.count, 1)
        XCTAssertEqual(snapshotSavedWorkspaceLayoutNow(pin).allSlots.map(\.lastWindowId), [window.windowId],
            "A first capture with no previous layout must also save the loan")
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(pin), .returned(window))
        XCTAssertNil(WorkspaceTabSnapshot(pin).lentMember)
        XCTAssertEqual(snapshotSavedWorkspaceLayoutNow(pin).allSlots.map(\.lastWindowId), [window.windowId])
    }

    func testSavedBorrowerKeepsRestoreOwnershipAcrossWindowAndAppRelaunch() async throws {
        let (pin, borrower, window) = try loan()
        try ensureSavedWorkspaceRecord(borrower)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: ["com.example.editor": [.init(pid: 712, launchDate: nil)]]))
        let saved = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first)
        XCTAssertEqual(saved.membership, .lentFromPin)
        let retained = snapshotLiveSavedLayout(pin, previous: try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)).layout,
            titleByWindowId: [:])
        XCTAssertTrue(retained.liveTiled.isEmpty)
        XCTAssertEqual(retained.detached, [saved.id])
        XCTAssertTrue(retained.layout.allSlots.isEmpty, "An existing retained slot is not appended to the live tree again")
        let routedSame = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertTrue(routedSame)
        XCTAssertTrue(window.nodeWorkspace === borrower)

        window.closeAxWindow()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[pin.name]?.lentWindow = nil }
        let app = TestApp(pid: 721, bundleId: "com.example.editor", name: "Editor", launchDate: savedTestNow.addingTimeInterval(-5))
        let reopened = TestWindow.new(id: 7211, parent: focus.workspace.rootTilingContainer, app: app, title: "Document")
        let routedNew = try await routeNewWindowToSavedWorkspaceIfNeeded(reopened, isRegularWindow: true, wasAdmitted: true)
        XCTAssertTrue(routedNew)
        XCTAssertTrue(reopened.nodeWorkspace === borrower, "Registry cleanup must not let the retained pin steal restore")
        let extra = TestWindow.new(id: 7212, parent: focus.workspace.rootTilingContainer, app: app, title: "Extra")
        XCTAssertFalse(waitingSavedSlots(bundleId: "com.example.editor", routingWindow: extra).contains { $0.workspaceName == pin.name },
            "Updating the borrower's claimed identity must not expose the pin to a second window")
    }

    func testRetainedLoanWithNoSavedBorrowerRoutesOnlyForExplicitPinReopen() async throws {
        let (pin, borrower, window) = try loan()
        savedWorkspaceStore.remove(named: borrower.name)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: ["com.example.editor": [.init(pid: 712, launchDate: nil)]]))
        XCTAssertFalse(waitingSavedSlots(bundleId: "com.example.editor", routingWindow: window).contains { $0.workspaceName == pin.name })
        let automatic = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true, wasAdmitted: true)
        XCTAssertFalse(automatic)
        XCTAssertTrue(window.nodeWorkspace === borrower)
        savedWorkspaceRuntime.preferRestoring(bundleId: "com.example.editor", into: pin.name)
        let explicit = try await routeNewWindowToSavedWorkspaceIfNeeded(window, isRegularWindow: true)
        XCTAssertTrue(explicit)
        XCTAssertTrue(window.nodeWorkspace === pin)
        XCTAssertNil(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first?.membership)
    }

    func testAbsentLoanRetainsItsSlotIdentityAndReturnsWithoutALiveClaim() throws {
        let (pin, borrower, window) = try loan()
        let original = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first)
        window.bind(to: macosNotPresentableWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: borrower.name)
        let content = WorkspaceTabSnapshot(pin)
        XCTAssertEqual(content.loanedMember?.state, .notPresentable)
        XCTAssertNil(content.lentMember, "An absent loan is not advertised as available for recall")
        captureSavedWorkspaces(facts: savedTestFacts(now: savedTestNow.addingTimeInterval(3600),
            runningApps: ["com.example.editor": [.init(pid: 712, launchDate: nil)]]))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.map(\.id), [original.id])
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first?.membership, .lentFromPin)
        window.bind(to: borrower.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(pin), .returned(window))
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: ["com.example.editor": [.init(pid: 712, launchDate: nil)]]))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.map(\.id), [original.id])
        XCTAssertNil(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first?.membership)
    }

    func testLoanWhoseLastCheckpointWasFloatingIsRetainedWithoutARestoreClaim() throws {
        let (pin, _, window) = try loan()
        let original = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first)
        savedWorkspaceStore.update(named: pin.name) { record in
            record.layout.floating = record.layout.root.allSlots
            record.layout.root.children = []
        }
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: ["com.example.editor": [.init(pid: 712, launchDate: nil)]]))
        let layout = try XCTUnwrap(savedWorkspaceStore.record(named: pin.name)).layout
        XCTAssertTrue(layout.root.allSlots.isEmpty)
        XCTAssertEqual(layout.floating.map(\.id), [original.id])
        XCTAssertEqual(layout.floating.first?.membership, .lentFromPin)
        XCTAssertFalse(waitingSavedSlots(bundleId: "com.example.editor", routingWindow: window).contains { $0.workspaceName == pin.name })
    }

    func testLoanMembershipRoundTripsAndOlderSlotsRemainResident() throws {
        let old = Data(#"{"id":"old","bundleId":"com.example.editor"}"#.utf8)
        var slot = try JSONDecoder().decode(SavedWindowSlot.self, from: old)
        XCTAssertNil(slot.membership)
        slot.membership = .lentFromPin
        let data = try JSONEncoder().encode(slot)
        XCTAssertEqual(try JSONDecoder().decode(SavedWindowSlot.self, from: data), slot)
    }

    func testMixedCardsKeepNamedAndEmojiIdentityWithAndWithoutATiledWindow() async throws {
        for tiledCount in [0, 1] {
            let windows = (0 ..< 2).map { index in
                WorkspaceSidebarWindowViewModel(windowId: UInt32(7221 + index), workspaceName: "named", appName: "Editor",
                    appBundleId: nil, appBundlePath: nil, title: "Window \(index)", isFocused: false,
                    state: index < tiledCount ? .laidOut : .floating)
            }
            func render(label: String, emoji: String?) async throws -> Data {
                let model = WorkspaceSidebarWorkspaceViewModel(name: "named", projectId: workspaceProjectDefaultId,
                    displayName: "Named Research", sidebarLabel: label, isGeneratedName: false,
                    monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil, isFocused: false, isVisible: false,
                    items: windows.map { .init(kind: .window($0)) }, appearance: .init(emoji: emoji))
                let card = WorkspaceSidebarTabCardView(workspace: model, presentation: workspaceSidebarTabPresentation(model),
                    isActive: false, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
                    activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
                    isShowingOverride: false, overrideMinHeight: 0, actions: .init(), onCommitOverride: {}, onCancelOverride: {})
                let mounted = expectation(description: "Native-backed card mounted")
                let host = NSHostingView(rootView: card.frame(width: 280).padding(8).background(Color.white)
                    .environment(\.colorScheme, .light).onAppear { mounted.fulfill() })
                host.frame = CGRect(x: 0, y: 0, width: 296, height: 100)
                host.layoutSubtreeIfNeeded()
                await fulfillment(of: [mounted], timeout: 5)
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let output = projectRoot.appendingPathComponent(".local/reviews/mixed-card-\(tiledCount)-\(label.isEmpty)-\(emoji == nil).png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output)
                return data
            }
            let unnamed = try await render(label: "", emoji: nil)
            let named = try await render(label: "Named Research", emoji: nil)
            let emoji = try await render(label: "Named Research", emoji: "🔬")
            XCTAssertNotEqual(unnamed, named)
            XCTAssertNotEqual(named, emoji)
        }
    }

    func testDebugSnapshotExposesTheSameLoanAndFloatingRoles() async throws {
        let (pin, borrower, window) = try loan()
        let floating = TestWindow.new(id: 7123, parent: borrower)
        let previousReads = debugSnapshotNativeReads
        let previousRows = TrayMenuModel.shared.workspaceSidebarWorkspaces
        debugSnapshotNativeReads = { _, _ in [:] }
        defer {
            debugSnapshotNativeReads = previousReads
            TrayMenuModel.shared.workspaceSidebarWorkspaces = previousRows
        }
        TrayMenuModel.shared.workspaceSidebarWorkspaces = await buildWorkspaceSidebarWorkspaceViewModels(
            currentFocus: focus, workspaceLabels: [:], availableMonitors: sortedMonitors)
        let document = await mcpDebugSnapshot(.init())
        let rows = try XCTUnwrap(document["sidebar"]?["rows"]?.array)
        let pinRow = try XCTUnwrap(rows.first { $0["workspace"] == .string(pin.name) })
        XCTAssertEqual(pinRow["contentMembers"]?.array?.first?["membership"], .string("lentFromPin"))
        XCTAssertEqual(pinRow["contentMembers"]?.array?.first?["windowId"], .int(Int(window.windowId)))
        let borrowed = try XCTUnwrap(rows.first { $0["workspace"] == .string(borrower.name) })
        let member = try XCTUnwrap(borrowed["contentMembers"]?.array?.first { $0["windowId"] == .int(Int(floating.windowId)) })
        XCTAssertEqual(member["membership"], .string("resident"))
        XCTAssertEqual(member["placement"], .string("floating"))
        XCTAssertEqual(member["parkOutcome"], .null)
    }

    func testAClosedLoanOrAPinWithItsOwnResourceDoesNotSaveAStaleLoan() throws {
        let (pin, _, window) = try loan()
        let replacement = TestWindow.new(id: 7131, parent: pin.rootTilingContainer, app: TestApp(pid: 713, bundleId: "com.example.replacement"))
        XCTAssertNil(WorkspaceTabSnapshot(pin).lentMember)
        XCTAssertEqual(snapshotSavedWorkspaceLayoutNow(pin).allSlots.map(\.lastWindowId), [replacement.windowId])
        replacement.unbindFromParent()
        window.unbindFromParent()
        XCTAssertNil(WorkspaceTabSnapshot(pin).lentMember)
        XCTAssertTrue(snapshotSavedWorkspaceLayoutNow(pin).allSlots.isEmpty)
    }

    func testAuxiliaryFactsAreCapturedOnceAndDoNotChangeWithTheRegistry() throws {
        let tab = Workspace.get(byName: "auxiliary")
        let opener = TestWindow.new(id: 7141, parent: tab.rootTilingContainer)
        let helper = TestWindow.new(id: 7142, parent: tab)
        AuxiliaryWindowRegistry.shared.restore(helper.windowId, pid: helper.app.pid, role: .mailCompose, parentWindowId: opener.windowId)
        let content = WorkspaceTabSnapshot(tab)
        let member = try XCTUnwrap(content.member(helper.windowId))
        XCTAssertEqual(member.state, .floating)
        XCTAssertEqual(member.attachment?.role, .mailCompose)
        XCTAssertEqual(member.attachment?.listedUnderWindowId, opener.windowId)
        XCTAssertTrue(member.isEphemeral)
        XCTAssertEqual(content.pinResources.map(\.window.windowId), [opener.windowId])
        AuxiliaryWindowRegistry.shared.removeAll()
        helper.bind(to: tab.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertEqual(content.member(helper.windowId)?.state, .floating)
        XCTAssertEqual(content.member(helper.windowId)?.attachment?.role, .mailCompose)
        XCTAssertEqual(WorkspaceTabSnapshot(tab).member(helper.windowId)?.state, .laidOut)
        XCTAssertNil(WorkspaceTabSnapshot(tab).member(helper.windowId)?.attachment)
        XCTAssertEqual(helper.axRectFetchCount, 0)
    }

    func testAbsentAndOffscreenMembersKeepDistinctLifecyclePolicies() {
        let tab = Workspace.get(byName: "offscreen")
        TestWindow.new(id: 7151, parent: tab.macOsNativeHiddenAppsWindowsContainer)
        TestWindow.new(id: 7152, parent: tab.macOsNativeFullscreenWindowsContainer)
        let minimized = TestWindow.new(id: 7153, parent: macosMinimizedWindowsContainer)
        minimized.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: tab.name)
        let absent = TestWindow.new(id: 7154, parent: macosNotPresentableWindowsContainer)
        absent.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: tab.name)
        let content = WorkspaceTabSnapshot(tab)
        XCTAssertEqual(content.members.map(\.state), [.hiddenWithApp, .nativeFullscreen, .minimized, .notPresentable])
        XCTAssertEqual(content.lifecycleMembers.map(\.window.windowId), [7151, 7152, 7153])
        XCTAssertEqual(content.treeMembers.map(\.window.windowId), [7151, 7152], "CLI preserves native-container inclusion")
        XCTAssertTrue(content.presentMembers.isEmpty)
        XCTAssertEqual(WorkspaceTabClosePlan([tab]).windowCount, 3)
    }

    func testPinnedSplitMemberInAnOrdinaryTabRemainsAnAwayMember() throws {
        let split = Workspace.get(byName: "pinned-split")
        let one = TestWindow.new(id: 7171, parent: split.rootTilingContainer)
        TestWindow.new(id: 7172, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(split, true)
        let other = Workspace.get(byName: "ordinary")
        one.bind(to: other.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.workspaces[split.name]?.composition?.away.isEmpty == true)
        let content = WorkspaceTabSnapshot(split)
        XCTAssertEqual(content.member(one.windowId)?.membership, .awayFromComposition)
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(split))
        XCTAssertFalse(content.lifecycleMembers.contains { $0.window === one })
    }

    func testEmptyLeadingContainerDoesNotHideANonemptyTabGroup() async throws {
        let tab = Workspace.get(byName: "sparse-stack")
        let stack = TilingContainer(parent: tab.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let empty = TilingContainer(parent: stack, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let nested = TilingContainer(parent: stack, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let window = TestWindow.new(id: 7181, parent: nested)
        empty.markAsMostRecentChild()
        let captured = WorkspaceTabSnapshot.layout(of: stack)
        XCTAssertEqual(captured.representative?.windowId, window.windowId)
        let built = await makeWorkspaceSidebarTabGroupViewModel(for: stack, workspaceName: tab.name, currentFocus: focus)
        XCTAssertEqual(built?.allWindows.map(\.windowId), [window.windowId])
    }

    func testNestedEmptyRecentChildKeepsSidebarAndAgentTabRepresentativesConsistent() async throws {
        let tab = Workspace.get(byName: "nested-sparse-stack")
        let stack = TilingContainer(parent: tab.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: INDEX_BIND_LAST)
        let child = TilingContainer(parent: stack, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 7191, parent: child)
        let recent = TilingContainer(parent: child, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let other = TestWindow.new(id: 7192, parent: recent)
        let empty = TilingContainer(parent: recent, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        let sibling = TestWindow.new(id: 7193, parent: stack)
        empty.markAsMostRecentChild()
        recent.markAsMostRecentChild()
        child.markAsMostRecentChild()
        XCTAssertEqual(child.tabActiveWindow?.windowId, other.windowId)
        XCTAssertEqual(child.tabRepresentativeWindow?.windowId, first.windowId)
        let content = WorkspaceTabSnapshot.layout(of: stack)
        let expected = [first.windowId, sibling.windowId]
        XCTAssertEqual(content.tabRepresentatives.map(\.windowId), expected)
        XCTAssertEqual(stack.agentTabWindows.map(\.windowId), expected)
        guard case .tabGroup(_, _, let tabs, _) = content.agentRawLayoutNode() else { return XCTFail() }
        XCTAssertEqual(tabs, expected)
        let sidebar = await makeWorkspaceSidebarTabGroupViewModel(for: stack, workspaceName: tab.name, currentFocus: focus)
        XCTAssertEqual(sidebar?.tabs.map(\.windowId), expected)
        let inventory = try await AgentSnapshot.query().inventory
        XCTAssertEqual(inventory.tabGroups.first { $0.tabGroupId == agentTabGroupId(stack) }?.tabs, expected)
    }

    func testSnapshotRetainsParkingOutcomeAtCapture() throws {
        let tab = Workspace.get(byName: "parked")
        let frame = Rect(topLeftX: 20, topLeftY: 20, width: 300, height: 200)
        let window = SnapshotTestWindow(id: 7161, parent: tab.rootTilingContainer, app: TestApp.shared, title: "Synthetic", frame: frame)
        let state = try XCTUnwrap(window.cornerParkingForDebug)
        let target = CGPoint(x: 999, y: 799)
        let area = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 800)
        _ = state.parking.park(corner: .bottomRightCorner, monitorVisibleRect: area, target: target,
            observed: frame, reasserting: false, nativeGeneration: 1)
        let pending = WorkspaceTabSnapshot(tab)
        XCTAssertEqual(pending.member(window.windowId)?.parking, .pending)
        for _ in 0 ... HiddenWindowParking.maxUnconfirmedParks {
            _ = state.parking.park(corner: .bottomRightCorner, monitorVisibleRect: area, target: target,
                observed: frame, reasserting: false, nativeGeneration: 1)
        }
        XCTAssertEqual(WorkspaceTabSnapshot(tab).member(window.windowId)?.parking, .blocked(.notSeenAtTarget(lastSeen: frame.topLeftCorner)))
        XCTAssertEqual(pending.member(window.windowId)?.parking, .pending)
        _ = state.parking.park(corner: .bottomRightCorner, monitorVisibleRect: area, target: target,
            observed: Rect(topLeftX: target.x, topLeftY: target.y, width: 300, height: 200), reasserting: false, nativeGeneration: 2)
        XCTAssertEqual(WorkspaceTabSnapshot(tab).member(window.windowId)?.parking, .confirmed)
        XCTAssertEqual(window.frameWrites, 0)
    }
}
