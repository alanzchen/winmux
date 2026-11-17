@testable import AppBundle
import AppKit
import Common
import XCTest

/// A window listed under the one it was opened from (a Mail draft, WeChat's image viewer, a Telegram window a rule
/// named for having no title) that the user moves to another tab on purpose: dropped between tabs or on New Tab, or
/// moved by a command. It's a window of its own from then on, saved with that tab, as one moved with Move to New Tab
/// is. A move the user made of its opener, not of it, leaves it with its opener's record. Apps and windows are
/// synthetic.
@MainActor
final class AuxiliaryWindowUserMoveTest: XCTestCase {
    private let mail = TestApp(pid: 81, bundleId: "com.apple.mail", name: "Mail")
    private let wechat = TestApp(pid: 82, bundleId: "com.tencent.xinWeChat", name: "WeChat")
    private let telegram = TestApp(pid: 83, bundleId: "ru.keepcoder.Telegram", name: "Telegram")
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        newWindowAppIsFrontmost = { _ in true }
        TrayMenuModel.shared.isEnabled = true
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// Mail's draft, by its own fields; a window a rule names by its title; one a rule names for having none.
    private var kinds: [(app: TestApp, name: String, role: AuxiliaryWindowRole, title: String)] {
        [(mail, "Mail", .mailCompose, "New Message"), (wechat, "WeChat", .windowRule, "Photos and Videos"),
         (telegram, "Telegram", .windowRule, "")]
    }

    /// `app`'s window in its tab, another tab beside it, and a window opened from it, listed under it.
    private func helperUnderItsOpener(_ app: TestApp, role: AuxiliaryWindowRole, title: String) async throws
        -> (tab: Workspace, other: Workspace, opener: TestWindow, helper: TestWindow)
    {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        let tab = focus.workspace
        let opener = TestWindow.new(id: 10, parent: tab.rootTilingContainer, app: app, title: "Main")
        let other = Workspace.get(byName: "elsewhere") // Named: in Tabs mode a number names a tab by its place.
        _ = TestWindow.new(id: 20, parent: other.rootTilingContainer, title: "Other")
        XCTAssertTrue(opener.focusWindow())
        let helper = try await openAuxiliaryTestWindow(11, app: app, role: role, from: opener, title: title)
        XCTAssertTrue(auxiliaryWindowParent(of: helper) === opener)
        XCTAssertTrue(isEphemeralAuxiliaryWindow(helper), "Not saved while it's listed under its opener")
        return (tab, other, opener, helper)
    }

    private func savedIds(_ window: TestWindow) throws -> [UInt32] {
        let saved = snapshotLiveSavedLayout(try XCTUnwrap(window.nodeWorkspace), previous: .init(), titleByWindowId: [window.windowId: "Chat"])
        return saved.layout.root.allSlots.compactMap(\.lastWindowId) + saved.layout.floating.compactMap(\.lastWindowId)
    }

    private func assertOwnWindow(_ helper: TestWindow, notIn tab: Workspace, _ kind: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(helper.nodeWorkspace === tab, "\(kind): moved", file: file, line: line)
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: helper), "\(kind): a window of its own", file: file, line: line)
        XCTAssertFalse(isEphemeralAuxiliaryWindow(helper), "\(kind)", file: file, line: line)
        XCTAssertTrue(try savedIds(helper).contains(helper.windowId), "\(kind): saved with its tab", file: file, line: line)
    }

    func testDroppedBetweenTabsItsAWindowOfItsOwn() async throws {
        for kind in kinds {
            let (tab, other, _, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            XCTAssertTrue(applyTabGapDrop(sourceNode: helper, sourceWindow: helper, projectId: tab.projectId,
                monitor: tab.workspaceMonitor, gap: WorkspaceSidebarTabGap(workspaceName: other.name, isAfter: true)))
            try assertOwnWindow(helper, notIn: tab, kind.name)
        }
    }

    func testDroppedOnNewTabItsAWindowOfItsOwn() async throws {
        for kind in kinds {
            let (tab, _, _, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            XCTAssertTrue(createWorkspaceFromSidebarDrag(sourceNode: helper, sourceWindow: helper, projectId: nil, monitorScopeId: nil))
            try assertOwnWindow(helper, notIn: tab, kind.name)
        }
    }

    func testDroppedOnTheSidebarsNewTabItsAWindowOfItsOwn() async throws {
        for kind in kinds {
            let (tab, _, _, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            moveWindowToNewWorkspaceFromSidebar(helper.windowId, projectId: tab.projectId,
                monitorScopeId: workspaceSidebarMonitorScopeId(for: tab.workspaceMonitor))
            for _ in 0 ..< 200 where helper.nodeWorkspace === tab { try await Task.sleep(for: .milliseconds(10)) }
            try assertOwnWindow(helper, notIn: tab, kind.name)
        }
    }

    func testMovedByMoveNodeToWorkspaceItsAWindowOfItsOwn() async throws {
        for kind in kinds {
            let (tab, other, _, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            let result = try await parseCommand("move-node-to-workspace --window-id 11 \(other.name)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode.rawValue, 0, "\(result.stderr)")
            XCTAssertTrue(helper.nodeWorkspace === other)
            try assertOwnWindow(helper, notIn: tab, kind.name)
        }
    }

    func testAMoveCommandWinMuxRunsAsItStartsOrThatMovesNothingLeavesItUnderItsOpener() async throws {
        for kind in kinds {
            let (tab, other, opener, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            let stay = try await parseCommand("move-node-to-workspace --window-id 11 \(tab.name)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(stay.exitCode.rawValue, 0)
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: helper), kind.role, "\(kind.name): already in that tab, not moved")
            // As WinMux starts, an on-window-detected rule applied again to a window it finds.
            let result = try await $_isStartup.withValue(true) {
                try await parseCommand("move-node-to-workspace --window-id 11 \(other.name)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            }
            XCTAssertEqual(result.exitCode.rawValue, 0)
            XCTAssertTrue(helper.nodeWorkspace === other)
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: helper), kind.role, "\(kind.name): not the user's move")
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: helper), opener.windowId)
        }
    }

    func testAMoveOfItsOpenerLeavesItWithItsOpenersRecord() async throws {
        for kind in kinds {
            let (tab, other, opener, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            let result = try await parseCommand("move-node-to-workspace --window-id 10 \(other.name)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertEqual(result.exitCode.rawValue, 0, "\(result.stderr)")
            XCTAssertTrue(opener.nodeWorkspace === other && helper.nodeWorkspace === tab)
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: helper), kind.role, "\(kind.name): not the window the user moved")
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.parentWindowId(of: helper), opener.windowId)
        }
    }

    func testAPinLendingItsWindowLeavesItsHelperUnderIt() async throws {
        for kind in kinds {
            let (tab, other, opener, helper) = try await helperUnderItsOpener(kind.app, role: kind.role, title: kind.title)
            try setWorkspaceSidebarTabFavorite(tab, true)
            let article = try XCTUnwrap(other.allLeafWindowsRecursive.first)
            XCTAssertTrue(moveWindowToWorkspaceKeepingPins(article, tab, CmdIo(stdin: .emptyStdin), focusFollowsWindow: true, failIfNoop: true))
            XCTAssertFalse(opener.nodeWorkspace === tab, "\(kind.name): the pin lent its window")
            XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: helper), kind.role)
            XCTAssertTrue(workspaceSidebarLentWindow(of: tab) === opener)
            XCTAssertEqual(try recallWorkspaceSidebarPinWindows(tab), .returned(opener), "\(kind.name): clicking the pin brings it back")
            XCTAssertTrue(auxiliaryWindowParent(of: helper) === opener)
        }
    }
}
