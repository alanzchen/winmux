import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabUXTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    func testPinsGroupsKeyboardNumbersAndNextUseTheSameOrder() async throws {
        let tabs = ["first", "between", "last", "pinned"].enumerated().map { index, name in
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: UInt32(index + 100), parent: tab.rootTilingContainer)
            return tab
        }
        XCTAssertTrue(tabs[0].focusWorkspace())
        Workspace.reconcileWorkspaceState()
        _ = try workspaceSidebarOrganizationStore.create(projectId: workspaceProjectDefaultId, workspaceNames: ["first", "last"])
        try workspaceSidebarOrganizationStore.update { $0.workspaces["pinned"] = .init(isFavorite: true) }
        XCTAssertEqual(workspaceNavigationTabs(current: tabs[0]).map(\.name), ["pinned", "first", "last", "between"])
        tabs[2].markAsAutomaticallyNamed()
        XCTAssertEqual(automaticWorkspaceDisplayIndex(tabs[2], focusedWorkspace: tabs[0]), 3,
            "Automatic display numbers also count named and pinned tabs in the rendered order")
        XCTAssertTrue(getNextPrevWorkspace(current: tabs[0], isNext: true, wrapAround: false, stdin: nil) === tabs[2])
        let result = try await WorkspaceCommand(args: WorkspaceCmdArgs(target: .direct(.parse("1").getOrDie())))
            .run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(focus.workspace === tabs[3], "Named tabs also participate in the visible numbering")
        XCTAssertTrue(getNextPrevWorkspace(current: tabs[2], isNext: true, wrapAround: false, stdin: "last\nfirst") === tabs[0],
            "Explicit CLI input keeps its supplied order")
        let moving = try XCTUnwrap(focus.windowOrNil)
        let moved = try await MoveNodeToWorkspaceCommand(args: .init(workspace: "3")).run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(moved.exitCode, 0)
        XCTAssertTrue(moving.nodeWorkspace === tabs[2], "Moving by number uses the same destination as switching by number")
        config.workspaceSidebar.mode = .sidebar
        XCTAssertTrue(getNextPrevWorkspace(current: tabs[0], isNext: true, wrapAround: false, stdin: nil) === tabs[1])
    }

    func testGroupNameSearchAndOtherProjectsHaveTheSameVisibleAndKeyboardResults() {
        var snapshot = fixture()
        snapshot.workspaces = [tab("first", 1), tab("between", 2), tab("last", 3), tab("pin", 4, pinned: true),
            tab("remote", 5, project: "design")]
        snapshot.configuration.tabCollections = [.init(projectId: workspaceProjectDefaultId, name: "Website Eng",
            workspaceNames: ["first", "last"])]
        let view = WorkspaceSidebarView(snapshot: snapshot, searchText: "Website Eng")
        XCTAssertEqual(view.tabsSearchWorkspacesByProject()[workspaceProjectDefaultId]?.map(\.name), ["first", "last"])
        XCTAssertEqual(view.currentSearchSelections(), [.window(1), .window(3)])
        let all = WorkspaceSidebarView(snapshot: snapshot, searchText: "Notes")
        XCTAssertEqual(all.currentSearchSelections(), [.window(4), .window(1), .window(3), .window(2), .window(5)])
        let remote = WorkspaceSidebarView(snapshot: snapshot, searchText: "Design")
        XCTAssertEqual(remote.currentSearchSelections(), [.window(5)])
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).currentSearchSelections(), [.window(4), .window(1), .window(3), .window(2)])
        XCTAssertEqual(WorkspaceSidebarView(snapshot: snapshot).currentFilteredProjectWorkspaces(allProjects: true).map(\.name),
            ["pin", "first", "last", "between"], "Empty search cannot select invisible projects")
    }

    func testSplitArmsAfterABriefPauseAndStaysArmedOverTheSameTab() {
        var hover = WorkspaceSidebarTabSplitHover()
        let p = CGPoint(x: 30, y: 20)
        XCTAssertFalse(hover.update(target: "A", side: .left, point: p, now: 1))
        XCTAssertFalse(hover.update(target: "A", side: .left, point: CGPoint(x: 40, y: 24), now: 1.2),
            "Small drift keeps the pause going")
        XCTAssertFalse(hover.update(target: "A", side: .left, point: CGPoint(x: 40, y: 24), now: 1.26),
            "The drift itself ended only just now")
        XCTAssertTrue(hover.update(target: "A", side: .left, point: CGPoint(x: 40, y: 24), now: 1.34))
        XCTAssertTrue(hover.update(target: "A", side: .right, point: CGPoint(x: 150, y: 20), now: 1.36),
            "Once armed, moving to the other half keeps the split")
        XCTAssertFalse(hover.update(target: "B", side: .right, point: p, now: 2), "Another tab starts over")
        XCTAssertFalse(hover.update(target: "B", side: .right, point: CGPoint(x: 60, y: 20), now: 2.2),
            "Moving on before arming is a reorder")
        XCTAssertFalse(hover.update(target: "B", side: .right, point: CGPoint(x: 60, y: 20), now: 2.4))
        XCTAssertTrue(hover.update(target: "B", side: .right, point: CGPoint(x: 60, y: 20), now: 2.46))
    }

    func testASlowSteadyDragKeepsReorderingButStoppingArmsTheSplit() {
        // Down a row at 40, 30, 20 and 16 pt/s, sampled every 16 ms: never at rest, so never a split.
        for speed in [40.0, 30, 20, 16] as [CGFloat] {
            var hover = WorkspaceSidebarTabSplitHover()
            var now = 1.0, y: CGFloat = 8
            while y < 28 {
                XCTAssertFalse(hover.update(target: "A", side: .left, point: CGPoint(x: 40, y: y), now: now),
                    "Still moving at \(speed) pt/s, y=\(y)")
                now += 0.016
                y += speed * 0.016
            }
        }
        // Drag events every 200 ms, and checks in between, while the pointer keeps moving at 20 pt/s.
        var sparse = WorkspaceSidebarTabSplitHover()
        var reported = CGPoint(x: 40, y: 8)
        for step in 0..<40 {
            let now = 1 + Double(step) * 0.05
            let live = CGPoint(x: 40, y: 8 + 20 * CGFloat(step) * 0.05)
            if step % 4 == 0 { reported = live }
            XCTAssertFalse(sparse.update(target: "A", side: .left, point: reported, now: now, restPoint: live),
                "Between events at t=\(now), the live pointer is still moving")
        }
        var hover = WorkspaceSidebarTabSplitHover()
        let stop = CGPoint(x: 40, y: 18)
        XCTAssertFalse(hover.update(target: "A", side: .left, point: stop, now: 1))
        XCTAssertFalse(hover.update(target: "A", side: .left, point: CGPoint(x: 41, y: 19), now: 1.2))
        XCTAssertTrue(hover.update(target: "A", side: .left, point: CGPoint(x: 41, y: 19), now: 1.26),
            "A pause with hand jitter arms it")
    }

    func testLeavingForTheGapBetweenTabsNeedsAFreshPause() async throws {
        let source = TestWindow.new(id: 120, parent: focus.workspace.rootTilingContainer)
        let target = Workspace.get(byName: "gap-target")
        _ = TestWindow.new(id: 121, parent: target.rootTilingContainer)
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 36)
        let destination = WorkspaceSidebarTabReorderDestination(projectId: target.projectId, monitorScopeId: "display",
            collectionId: nil)
        let tab = WorkspaceSidebarDropTarget(kind: .workspace(target.name), rect: rect, acceptsSides: true,
            tabReorderDestination: destination)
        let gap = WorkspaceSidebarDropTarget(kind: .tabGap(projectId: target.projectId, monitorScopeId: "display",
            gap: .init(workspaceName: target.name, isAfter: true)), rect: rect)
        let point = CGPoint(x: 40, y: 18)
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        _ = workspaceSidebarDeliberateTabDropTarget(tab, sourceWindow: source, point: point)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspaceSidebarDeliberateTabDropTarget(tab, sourceWindow: source, point: point)?.kind, tab.kind)
        _ = workspaceSidebarDeliberateTabDropTarget(gap, sourceWindow: source, point: CGPoint(x: 40, y: 34))
        guard case .tabGap = workspaceSidebarDeliberateTabDropTarget(tab, sourceWindow: source, point: point)?.kind else {
            return XCTFail("Back over the tab, a drag reorders until it pauses again")
        }
    }

    func testLiveDropResolutionReordersFirstThenArmsTheSameSplitThatWillBeCommitted() async throws {
        let first = TestWindow.new(id: 80, parent: focus.workspace.rootTilingContainer)
        let target = Workspace.get(byName: "target")
        _ = TestWindow.new(id: 81, parent: target.rootTilingContainer)
        let drop = WorkspaceSidebarDropTarget(kind: .workspace(target.name),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 36), acceptsSides: true,
            tabReorderDestination: .init(projectId: target.projectId, monitorScopeId: "row-display", collectionId: "row-group"))
        let point = CGPoint(x: 150, y: 24)
        let initial = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: first, point: point))
        guard case .tabGap(_, let scope, let gap) = initial.kind else { return XCTFail("An immediate drop must reorder") }
        XCTAssertEqual(scope, "row-display")
        XCTAssertEqual(gap.collectionId, "row-group")
        XCTAssertEqual(gap.workspaceName, target.name)
        XCTAssertTrue(gap.isAfter)
        let controller = WorkspaceSidebarTabSplitHoverController.shared
        controller.noteDisplayed(source: first.windowId, hitKind: drop.kind, target: initial, placement: nil)
        try await Task.sleep(for: .milliseconds(440))
        XCTAssertEqual(controller.commitTarget(source: first.windowId, hitTarget: drop, point: point)?.kind, initial.kind,
            "Crossing the dwell deadline cannot change a drop before its preview is published")
        let split = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: first, point: point))
        XCTAssertEqual(split.kind, drop.kind)
        controller.noteDisplayed(source: first.windowId, hitKind: drop.kind, target: split, placement: .right)
        XCTAssertEqual(controller.commitTarget(source: first.windowId, hitTarget: drop, point: CGPoint(x: 159, y: 24))?.kind, drop.kind,
            "Mouse-up jitter must not silently change the visible split into a reorder")
        XCTAssertNil(controller.commitTarget(source: first.windowId, hitTarget: drop, point: CGPoint(x: 30, y: 24)))
        controller.reset()
        XCTAssertNotEqual(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: first, point: point)?.kind, drop.kind)
    }

    func testNarrowSplitButtonsSelectTheirOwnWindows() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let workspace = tab("pair", 90, additionalWindowIds: [91, 92], label: "")
        var selected: [WorkspaceSidebarAction] = []
        let card = WorkspaceSidebarTabCardView(workspace: workspace,
            presentation: workspaceSidebarTabPresentation(workspace), isActive: false, isDropTarget: false,
            dragSourceWindowId: nil, selectedSearchTarget: nil,
            activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
            isShowingOverride: false, overrideMinHeight: 36, actions: .init(send: { selected.append($0) }),
            onBeginRename: {}, onCommitOverride: {}, onCancelOverride: {})
        let host = NSHostingView(rootView: card.frame(width: 150, height: 36))
        let native = NSWindow(contentRect: CGRect(x: 300, y: 200, width: 150, height: 36),
            styleMask: [.borderless], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.orderFrontRegardless()
        defer { native.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        native.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for (index, x) in [CGFloat(24), 75, 126].enumerated() {
            let point = host.convert(CGPoint(x: x, y: 18), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(2)
            while selected.count < index + 1, let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: deadline,
                inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        XCTAssertEqual(selected, [.selectWindow(90), .selectWindow(91), .selectWindow(92)])
        XCTAssertEqual(host.fittingSize.width, 150, accuracy: 0.5)
    }

    func testFloatingDropUsesTheRowsOwnPolicyAndCanJoinAfterAHold() async throws {
        let floating = TestWindow.new(id: 83, parent: focus.workspace)
        let target = Workspace.get(byName: "target")
        _ = TestWindow.new(id: 84, parent: target.rootTilingContainer)
        let drop = WorkspaceSidebarDropTarget(kind: .workspace(target.name),
            rect: Rect(topLeftX: 100, topLeftY: 700, width: 200, height: 36), acceptsSides: true)
        let point = CGPoint(x: 150, y: 713)
        XCTAssertNil(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: floating, point: point),
            "Rows with no gap destination cannot synthesize a reorder")
        try await Task.sleep(for: .milliseconds(440))
        let armed = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: floating, point: point))
        XCTAssertEqual(armed.kind, drop.kind)
        XCTAssertFalse(armed.acceptsSides, "A floating window joins without promising a tiled split")
    }

    func testReorderUsesNormalizedScreenCoordinatesAboveAndBelowScreenCenter() throws {
        let source = TestWindow.new(id: 85, parent: focus.workspace.rootTilingContainer)
        let target = Workspace.get(byName: "target")
        _ = TestWindow.new(id: 86, parent: target.rootTilingContainer)
        for y: CGFloat in [100, 700] {
            let screenRect = CGRect(x: 100, y: y, width: 200, height: 36)
            let drop = WorkspaceSidebarDropTarget(kind: .workspace(target.name), rect: screenRect.monitorFrameNormalized(),
                acceptsSides: true, tabReorderDestination: .init(projectId: target.projectId,
                    monitorScopeId: "row-display", collectionId: nil))
            for (distance, after) in [(CGFloat(12), false), (24, true)] {
                WorkspaceSidebarTabSplitHoverController.shared.reset()
                let point = normalizeAppKitScreenPoint(CGPoint(x: screenRect.midX, y: screenRect.maxY - distance))
                let result = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(drop, sourceWindow: source, point: point))
                guard case .tabGap(_, _, let gap) = result.kind else { return XCTFail("Expected reorder") }
                XCTAssertEqual(gap.isAfter, after)
            }
        }
    }

    func testUndoShortcutUsesCharactersRatherThanPhysicalKeyboardPosition() throws {
        for (code, characters, expected) in [(6, "w", false), (7, "z", true), (6, "z", true)] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
            event.flags = .maskCommand
            let units = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            XCTAssertEqual(workspaceSidebarIsUndoShortcut(event), expected)
            event.flags.insert(.maskShift)
            XCTAssertFalse(workspaceSidebarIsUndoShortcut(event), "Redo must not trigger Undo")
        }
    }

    func testSearchResultsCannotAdvertisePartialSplitDropTargets() async throws {
        var snapshot = fixture()
        snapshot.visibleWidth = 280
        snapshot.workspaces = [tab("pair", 93, additionalWindowIds: [94])]
        var targets: [WorkspaceSidebarDropTargetFrame] = []
        let view = WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { targets = $0 }),
            reduceMotionOverride: true, reduceTransparencyOverride: true, searchText: "93")
        let host = NSHostingView(rootView: view.frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(view.currentSearchSelections(), [.window(93)])
        XCTAssertFalse(targets.contains {
            if case .tabGap = $0.kind { return true }
            return $0.kind == .workspace("pair")
        })
    }

    func testUndoRestoresSplitTreeWeightsAndPrunedSourceTab() throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 20, parent: source.rootTilingContainer)
        let target = Workspace.get(byName: "target")
        let second = TestWindow.new(id: 21, parent: target.rootTilingContainer)
        first.setWeight(.h, 0.7)
        second.setWeight(.h, 0.3)
        XCTAssertTrue(first.focusWindow())
        let before = WorkspaceSidebarTabUndoSnapshot()
        applyTabDrop(sourceNode: first, sourceWindow: first, targetWorkspace: target, placement: .right)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: source.name))
        WorkspaceSidebarTabUndo.shared.record("Split Tabs", before: before)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Split Tabs")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(Workspace.existing(byName: source.name) === source)
        XCTAssertTrue(first.nodeWorkspace === source)
        XCTAssertTrue(second.nodeWorkspace === target)
        XCTAssertEqual(first.getWeight(.h), 0.7)
        XCTAssertEqual(second.getWeight(.h), 0.3)
        XCTAssertTrue(focus.windowOrNil === first)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testUndoGroupingRestoresMembershipAndDoesNotReopenClosedWindows() throws {
        let source = focus.workspace
        let first = TestWindow.new(id: 30, parent: source.rootTilingContainer)
        let before = WorkspaceSidebarTabUndoSnapshot()
        let group = try workspaceSidebarOrganizationStore.create(projectId: source.projectId, workspaceNames: [source.name])
        WorkspaceSidebarTabUndo.shared.record("Group", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.collections.isEmpty)
        XCTAssertTrue(first.nodeWorkspace === source)

        let secondBefore = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.collections = [group] }
        WorkspaceSidebarTabUndo.shared.record("Group", before: secondBefore)
        first.closeAxWindow()
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertNil(Window.get(byId: 30))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [group], "A stale undo must not rewrite organization")
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testUndoRejectsWindowsRegisteredDuringTheEditAndNativeContainerMoves() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 35, parent: workspace.rootTilingContainer)
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[workspace.name] = .init(isFavorite: true) }
        let newcomer = TestWindow.new(id: 36, parent: workspace.rootTilingContainer)
        WorkspaceSidebarTabUndo.shared.record("Pin Tab", before: before)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(newcomer.nodeWorkspace === workspace)

        let hidden = TestWindow.new(id: 37, parent: workspace.macOsNativeHiddenAppsWindowsContainer)
        let nativeBefore = WorkspaceSidebarTabUndoSnapshot()
        hidden.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        WorkspaceSidebarTabUndo.shared.record("Separate Tabs", before: nativeBefore)
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, "A native container transition cannot be reconstructed as an ordinary split")
        XCTAssertTrue(hidden.nodeWorkspace === workspace)
    }

    func testUndoPreservesPassiveSavedRecordUpdates() throws {
        let workspace = focus.workspace
        _ = TestWindow.new(id: 38, parent: workspace.rootTilingContainer)
        savedWorkspaceStore.insert(.init(workspaceName: workspace.name, lastVisibleSequence: 1))
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[workspace.name] = .init(colorHex: "#FF0000") }
        savedWorkspaceStore.update(named: workspace.name) { $0.lastVisibleSequence = 2 }
        WorkspaceSidebarTabUndo.shared.record("Change Appearance", before: before)
        savedWorkspaceStore.update(named: workspace.name) { $0.lastVisibleSequence = 3 }
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(savedWorkspaceStore.record(named: workspace.name)?.lastVisibleSequence, 3)
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.workspaces.isEmpty)
    }

    func testUndoSurvivesNormalizedSidebarSessionAndRejectsAnInterleavedSession() async throws {
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let previousApp = appForTests
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        setScheduledRefreshOverrideForTests { _, _, _ in }
        defer {
            TrayMenuModel.shared.isEnabled = wasEnabled
            appForTests = previousApp
            setScheduledRefreshOverrideForTests(nil)
        }
        let original = focus.workspace
        let first = TestWindow.new(id: 39, parent: original.rootTilingContainer)
        let target = Workspace.get(byName: "destination")
        _ = TestWindow.new(id: 49, parent: target.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        first.nativeFocus()
        let split = try XCTUnwrap(runWorkspaceSidebarSession(undoTitle: "Split Tabs") {
            applyTabDrop(sourceNode: first, sourceWindow: first, targetWorkspace: target, placement: .right)
        })
        await split.value
        XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title)
        try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {}
        XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title, "A normal post-layout refresh must not invalidate Undo")
        let undo = try XCTUnwrap(runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() })
        await undo.value
        XCTAssertTrue(first.nodeWorkspace === original)

        let overlapping = try XCTUnwrap(runWorkspaceSidebarSession(undoTitle: "Change Appearance") {
            try workspaceSidebarOrganizationStore.update { $0.workspaces[original.name] = .init(colorHex: "#FF0000") }
            try await runLightSession(.menuBarButton, .forceRun, shouldSchedulePostRefresh: false) {
                try workspaceSidebarOrganizationStore.update { $0.workspaces[original.name]?.emoji = "🌟" }
            }
        })
        await overlapping.value
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, "Undo must not absorb another command that ran while awaiting AX")
    }

    func testUndoAfterFocusChangeStillWorksAndLaterLayoutInvalidatesIt() throws {
        let firstTab = focus.workspace
        let first = TestWindow.new(id: 40, parent: firstTab.rootTilingContainer)
        let secondTab = Workspace.get(byName: "second")
        let second = TestWindow.new(id: 41, parent: secondTab.rootTilingContainer)
        let before = WorkspaceSidebarTabUndoSnapshot()
        winMuxWorkspaceState.moveWorkspace(secondTab.id, relativeTo: firstTab.id, after: false)
        WorkspaceSidebarTabUndo.shared.record("Reorder", before: before)
        XCTAssertTrue(second.focusWindow())
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(orderedWorkspaces(in: firstTab.projectId).map(\.name), [firstTab.name, "second"])

        let next = WorkspaceSidebarTabUndoSnapshot()
        winMuxWorkspaceState.moveWorkspace(secondTab.id, relativeTo: firstTab.id, after: false)
        WorkspaceSidebarTabUndo.shared.record("Reorder", before: next)
        first.bind(to: secondTab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    func testDetachingSplitMemberRetainsItsGroupAndUndoRestoresSplit() throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 50, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 51, parent: workspace.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspace.projectId, workspaceNames: [workspace.name])
        let before = WorkspaceSidebarTabUndoSnapshot()
        try detachWorkspaceTabWindow(second)
        let newTab = try XCTUnwrap(second.nodeWorkspace)
        XCTAssertFalse(newTab === workspace)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: newTab.name)?.id, group.id)
        WorkspaceSidebarTabUndo.shared.record("Separate", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(workspace.allLeafWindowsRecursive, [first, second])
        XCTAssertNil(Workspace.existing(byName: newTab.name))
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections, [group])
    }

    func testUndoPreservesInactiveSplitFocusHistory() throws {
        let current = focus.workspace
        let focused = TestWindow.new(id: 55, parent: current.rootTilingContainer)
        let other = Workspace.get(byName: "inactive")
        let recent = TestWindow.new(id: 56, parent: other.rootTilingContainer)
        _ = TestWindow.new(id: 57, parent: other.rootTilingContainer)
        recent.markAsMostRecentChild()
        XCTAssertTrue(focused.focusWindow())
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[current.name] = .init(isFavorite: true) }
        WorkspaceSidebarTabUndo.shared.record("Pin Tab", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(other.mostRecentWindowRecursive === recent)
        XCTAssertTrue(focus.windowOrNil === focused)
    }

    func testUndoAppearancePreservesLaterNavigationOnBothDisplays() throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        let original = focus.workspace
        let first = TestWindow.new(id: 58, parent: original.rootTilingContainer)
        let other = Workspace.get(byName: "right")
        _ = TestWindow.new(id: 59, parent: other.rootTilingContainer)
        let next = Workspace.get(byName: "right-next")
        let nextWindow = TestWindow.new(id: 60, parent: next.rootTilingContainer)
        XCTAssertTrue(left.setActiveWorkspace(original))
        XCTAssertTrue(right.setActiveWorkspace(other))
        XCTAssertTrue(first.focusWindow())
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[original.name] = .init(colorHex: "#FF0000") }
        WorkspaceSidebarTabUndo.shared.record("Change Appearance", before: before)
        XCTAssertTrue(right.setActiveWorkspace(next))
        XCTAssertTrue(nextWindow.focusWindow())
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceSidebarOrganizationStore.state.workspaces.isEmpty)
        XCTAssertTrue(left.activeWorkspace === original)
        XCTAssertTrue(right.activeWorkspace === next)
        XCTAssertTrue(focus.windowOrNil === nextWindow)
    }

    func testUndoDetachDoesNotRestoreATabAlreadySelectedOnAnotherDisplay() throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        let original = focus.workspace
        let first = TestWindow.new(id: 64, parent: original.rootTilingContainer)
        let second = TestWindow.new(id: 65, parent: original.rootTilingContainer)
        _ = TestWindow.new(id: 66, parent: right.activeWorkspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let before = WorkspaceSidebarTabUndoSnapshot()
        try detachWorkspaceTabWindow(second)
        WorkspaceSidebarTabUndo.shared.record("Move to New Tab", before: before)
        XCTAssertTrue(right.setActiveWorkspace(original))
        XCTAssertTrue(first.focusWindow())
        try WorkspaceSidebarTabUndo.shared.undo()
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(right.activeWorkspace === original)
        XCTAssertFalse(left.activeWorkspace === original)
        XCTAssertTrue(second.nodeWorkspace === original)
        XCTAssertTrue(focus.windowOrNil === first)
    }

    func testUndoResolvesDependentViewportConflictsAcrossThreeDisplays() throws {
        let displays = [
            SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT"),
            SavedWorkspaceTestMonitor(id: 2, name: "Middle", x: 1920, uuid: "MIDDLE"),
            SavedWorkspaceTestMonitor(id: 3, name: "Right", x: 3840, uuid: "RIGHT"),
        ]
        setMonitorsForTests(displays)
        defer { setMonitorsForTests(nil) }
        Workspace.reconcileWorkspaceState()
        let tabs = ["A", "B", "C", "D"].enumerated().map { index, name in
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: UInt32(170 + index), parent: tab.rootTilingContainer)
            return tab
        }
        for (display, tab) in zip(displays, tabs.prefix(3)) {
            XCTAssertTrue(winMuxWorkspaceState.setActiveWorkspace(tab, on: .init(display)))
        }
        XCTAssertTrue(tabs[0].mostRecentWindowRecursive!.focusWindow())
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[tabs[0].name] = .init(colorHex: "#FF0000") }
        for (display, tab) in zip(displays, tabs.dropFirst()) {
            XCTAssertTrue(winMuxWorkspaceState.setActiveWorkspace(tab, on: .init(display)))
        }
        WorkspaceSidebarTabUndo.shared.record("Move Tabs", before: before)
        XCTAssertTrue(winMuxWorkspaceState.setActiveWorkspace(tabs[0], on: .init(displays[2])))
        try WorkspaceSidebarTabUndo.shared.undo()
        let active = displays.map { $0.activeWorkspace.id }
        XCTAssertEqual(active, [tabs[1].id, tabs[2].id, tabs[0].id],
            "Rejecting the first restore must also reject any earlier proposal that depends on it")
        XCTAssertEqual(Set(active).count, 3)
    }

    func testTabMenuClosesTheClickedMemberAndOffersProjectMoveWithoutDeleteWorkspace() throws {
        let workspace = tab("pair", 61, additionalWindowIds: [62])
        let previousProjects = TrayMenuModel.shared.workspaceSidebarProjects
        defer { TrayMenuModel.shared.workspaceSidebarProjects = previousProjects }
        TrayMenuModel.shared.workspaceSidebarProjects = fixture().projects
        var sent: [WorkspaceSidebarAction] = []
        let menu = workspaceSidebarWorkspaceIdentityMenuModel(workspace, windowId: 62, send: { sent.append($0) })
        XCTAssertFalse(menu.entries.contains { $0.title.contains("Workspace") && !$0.title.hasPrefix("Customize") })
        try XCTUnwrap(menu.entries.first { $0.title == "Close Window" }?.perform)()
        try XCTUnwrap(menu.entries.first { $0.title == "Move “Notes 62” to New Tab" }?.perform)()
        try XCTUnwrap(menu.entries.first { $0.title == "Move to Project" }?.children.first?.perform)()
        XCTAssertEqual(sent, [.closeWindow(62), .detachTabWindow(62), .moveWorkspace("pair", toProject: "design")])
        XCTAssertTrue(menu.entries.contains { $0.title == "Close All Windows in Split…" })
    }

    func testNarrowSplitsAndBadgeOwnershipPreserveEveryWindowIdentity() {
        XCTAssertTrue(workspaceSidebarSplitUsesIcons(width: 160, windowCount: 2))
        XCTAssertTrue(workspaceSidebarSplitUsesIcons(width: 260, windowCount: 3))
        XCTAssertFalse(workspaceSidebarSplitUsesIcons(width: 260, windowCount: 2))
        let tabs = [tab("pin", 70, pinned: true), tab("ordinary", 71)]
        XCTAssertEqual(workspaceSidebarBadgeOwners(tabs), ["/Applications/Test.app": 70])
        var active = tabs[0]
        active.isVisible = true
        XCTAssertTrue(workspaceSidebarTabIsActive(active, on: "monitor:0,0"))
        XCTAssertFalse(workspaceSidebarTabIsActive(active, on: "monitor:1920,0"))
    }

    func testCloseSplitStopsAtAnUnsavedWindowAndClearsUndo() async throws {
        let workspace = focus.workspace
        let windows = [101, 102, 103].map { TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }
        let before = WorkspaceSidebarTabUndoSnapshot()
        try workspaceSidebarOrganizationStore.update { $0.workspaces[workspace.name] = .init(isFavorite: true) }
        WorkspaceSidebarTabUndo.shared.record("Pin Tab", before: before)
        XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title)
        var attempted: [UInt32] = []
        await closeWorkspaceSidebarSplitWindows(windows, in: workspace) { window in
            attempted.append(window.windowId)
            if window.windowId == 102 { return false }
            window.closeAxWindow()
            return true
        }
        XCTAssertEqual(attempted, [101, 102])
        XCTAssertNil(Window.get(byId: 101))
        XCTAssertNotNil(Window.get(byId: 103))
        XCTAssertTrue(focus.windowOrNil === windows[1])
        XCTAssertNil(WorkspaceSidebarTabUndo.shared.title)
    }

    private func fixture() -> WorkspaceSidebarSnapshot {
        var result = WorkspaceSidebarSnapshot.empty
        result.configuration.usesTabsList = true
        result.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil),
            .init(id: "design", displayName: "Design", colorHex: nil)]
        result.targetMonitorScopeId = "monitor:0,0"
        return result
    }

    private func window(_ name: String, _ id: UInt32) -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: name, appName: "Notes", appBundleId: nil,
            appBundlePath: "/Applications/Test.app", title: "Notes \(id)", isFocused: false)
    }

    private func tab(_ name: String, _ id: UInt32, pinned: Bool = false,
                     project: WorkspaceProjectId = workspaceProjectDefaultId,
                     additionalWindowIds: [UInt32] = [], label: String? = nil) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: project, displayName: name, sidebarLabel: label ?? name, isGeneratedName: false,
            monitorScopeId: "monitor:0,0", monitorName: "Main", isFocused: false, isVisible: false,
            items: ([id] + additionalWindowIds).map { .init(kind: .window(window(name, $0))) },
            appearance: .init(isFavorite: pinned))
    }
}
