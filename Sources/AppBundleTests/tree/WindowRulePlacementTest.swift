@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a window a window rule names, opened from a window of its app in use just after a press,
/// floats at its own size over that window, in its tab, listed under it. Every other window, of that app
/// or another, opened any other way, or placed already, is placed as before. Apps, titles and frames are
/// synthetic.
@MainActor
final class WindowRulePlacementTest: XCTestCase {
    private let messenger = TestApp(pid: 61, bundleId: "com.example.messenger", name: "Messenger")
    private let other = TestApp(pid: 62, bundleId: "com.example.other", name: "Other")
    private let viewerFrame = Rect(topLeftX: 500, topLeftY: 200, width: 825, height: 600)
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var savedRules: [WindowRule] = []

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        savedRules = activeWindowRules
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        newWindowAppIsFrontmost = { _ in true }
        activeWindowRules = [WindowRule(id: "viewer", appId: "com.example.messenger", windowTitles: ["Photo Viewer", "照片查看器"],
            subrole: "AXStandardWindow")]
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        activeWindowRules = savedRules
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    // MARK: - Helpers

    /// The messenger's pin: its window tiled and in use.
    private func messengerPin(app: TestApp? = nil) throws -> (pin: Workspace, main: TestWindow) {
        let pin = focus.workspace
        let main = TestWindow.new(id: 10, parent: pin.rootTilingContainer, app: app ?? messenger, title: "Messenger")
        try setWorkspaceSidebarTabFavorite(pin, true)
        XCTAssertTrue(main.focusWindow())
        noteAppActivatedForAuxiliaryWindows(pid: (app ?? messenger).pid, at: auxiliaryFocusSpan.since - 1)
        return (pin, main)
    }

    /// A regular window first seen as registration sees one: its origin read at once; its role, from its app's
    /// own fields and then the window rules, read once the origin holds; then placed under its opener when it
    /// has one, otherwise as any regular new window, in the focused tab and then a tab of its own.
    private func appear(_ id: UInt32, app: TestApp, title: String?, subrole: String? = "AXStandardWindow",
                        pressed: Bool = true, order: [UInt32]) async throws -> TestWindow {
        let since = auxiliaryFocusSpan.since
        let environment = AuxiliaryWindowOriginEnvironment(
            orderedWindows: { order.map { AuxiliaryOrderedWindow(id: $0, pid: app.pid, layer: 0) } },
            lastUserInput: { pressed ? since + 0.1 : since - 30 }, appIsActive: { _ in true })
        let evidence = captureAuxiliaryWindowOriginEvidence(newWindowId: id, pid: app.pid, observedAt: since + 0.2,
            environment: environment)
        let placement = await auxiliaryWindowPlacement(evidence, type: .window, role: {
            await newWindowAuxiliaryRole(bundleId: app.rawAppBundleId, ownRole: { nil },
                facts: { WindowRuleFacts(title: title, subrole: subrole) })
        })
        if let placement {
            let window = TestWindow.new(id: id, parent: placement.workspace, rect: viewerFrame, app: app, title: title)
            recordAuxiliaryWindow(window, placement: placement, initialRect: viewerFrame)
            _ = try await restoreOrDetectNewWindow(window, isRegularWindow: false)
            return window
        }
        let window = TestWindow.new(id: id, parent: focus.workspace.rootTilingContainer, rect: viewerFrame, app: app, title: title)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        return window
    }

    /// The user back in the main window, a press just after: the origin holds again for the next one.
    private func refocus(_ main: TestWindow) {
        XCTAssertTrue(main.focusWindow())
        XCTAssertTrue(focus.windowOrNil === main)
    }

    private func tile(_ pin: Workspace) async throws -> (cells: [UInt32], counted: [UInt32]) {
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        let model = try XCTUnwrap(models.first { $0.name == pin.name })
        return (workspaceSidebarPinnedTabWindows(model).map(\.windowId), model.associatedWindows.map(\.id))
    }

    /// Where any regular new window goes: in Tabs mode, a tab of its own, tiled.
    private func assertPlacedAsBefore(_ window: TestWindow, notIn pin: Workspace, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(window.nodeWorkspace === pin, message, file: file, line: line)
        XCTAssertFalse(window.isFloating, message, file: file, line: line)
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: window), message, file: file, line: line)
    }

    // MARK: - Named by a rule

    func testAWindowARuleNamesOpenedFromItsAppsWindowFloatsUnderItAtItsOwnSize() async throws {
        let (pin, main) = try messengerPin()
        let tabsBefore = Workspace.all.count
        let viewer = try await appear(11, app: messenger, title: "Photo Viewer", order: [11, 10])

        XCTAssertTrue(viewer.nodeWorkspace === pin, "Over the window it was opened from, in its tab")
        XCTAssertTrue(viewer.isFloating, "Floating, not tiled to fill the tab")
        XCTAssertTrue(auxiliaryWindowParent(of: viewer) === main)
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: viewer), .windowRule)
        XCTAssertEqual(Workspace.all.count, tabsBefore, "No tab of its own")
        let expected = auxiliaryWindowFrame(viewerFrame, in: pin.workspaceMonitor.visibleRectPaddedByOuterGaps)
        XCTAssertEqual(viewer.lastKnownActualRect, expected, "The app's own size and place, moved only into the tab's area")
        XCTAssertEqual(expected.size, viewerFrame.size, "Fits: its size is kept as the app gave it")
        XCTAssertEqual(viewer.nativeRect, viewerFrame, "Nothing was written to a window that already fits")
        let tile = try await tile(pin)
        XCTAssertEqual(tile.cells, [10], "The pin's cell is its main window")
        XCTAssertEqual(tile.counted, [11], "The viewer is counted under it")
        XCTAssertEqual(main.parent === pin.rootTilingContainer, true, "The main window stays tiled where it was")
    }

    func testALocalizedTitleOnlyMatchesWhenTheRuleListsIt() async throws {
        let (pin, main) = try messengerPin()
        let listed = try await appear(11, app: messenger, title: "照片查看器", order: [11, 10])
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: listed), .windowRule, "A translation the rule lists")
        refocus(main)
        let unlisted = try await appear(12, app: messenger, title: "Fotobetrachter", order: [12, 10])
        assertPlacedAsBefore(unlisted, notIn: pin, "A translation the rule doesn't list: as before")
        refocus(main)
        let cased = try await appear(13, app: messenger, title: "photo viewer", order: [13, 10])
        assertPlacedAsBefore(cased, notIn: pin, "Titles match exactly, as the rule writes them")
    }

    // MARK: - Not named, or not opened from its app's window: as before

    func testOtherWindowsOfTheAppAreAsBefore() async throws {
        let (pin, main) = try messengerPin()
        let chat = try await appear(11, app: messenger, title: "Chat", order: [11, 10])
        assertPlacedAsBefore(chat, notIn: pin, "A chat window, opened the same way, isn't named by the rule")
        refocus(main)
        let untitled = try await appear(12, app: messenger, title: nil, order: [12, 10])
        assertPlacedAsBefore(untitled, notIn: pin, "No title read: nothing to match")
    }

    func testTheSameTitleInAnotherAppIsAsBefore() async throws {
        let (pin, _) = try messengerPin(app: other)
        let window = try await appear(11, app: other, title: "Photo Viewer", order: [11, 10])
        assertPlacedAsBefore(window, notIn: pin, "Another app's window of that name")
    }

    func testANamedWindowWithNoClearOpenerIsAsBefore() async throws {
        let (pin, main) = try messengerPin()
        let unprompted = try await appear(11, app: messenger, title: "Photo Viewer", pressed: false, order: [11, 10])
        assertPlacedAsBefore(unprompted, notIn: pin, "Opened by the app with no press: its own window")
        refocus(main)
        let notAbove = try await appear(12, app: messenger, title: "Photo Viewer", order: [10, 12])
        assertPlacedAsBefore(notAbove, notIn: pin, "Made behind the app's window: no opener")
    }

    func testASubroleTheRuleNamesMustMatch() async throws {
        let (pin, _) = try messengerPin()
        let window = try await appear(11, app: messenger, title: "Photo Viewer", subrole: "AXFloatingWindow", order: [11, 10])
        assertPlacedAsBefore(window, notIn: pin, "Another kind of window with that name")
    }

    func testAWindowAlreadyPlacedIsLeftWhereItIs() async throws {
        let (pin, main) = try messengerPin()
        // Placed before the rule was there, or tiled by the user: a rule changes nothing about it.
        let existing = TestWindow.new(id: 12, parent: pin.rootTilingContainer, app: messenger, title: "Photo Viewer")
        XCTAssertTrue(main.focusWindow())
        let viewer = try await appear(11, app: messenger, title: "Photo Viewer", order: [11, 10])
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: viewer), .windowRule)
        XCTAssertTrue(existing.parent === pin.rootTilingContainer, "The tiled one stays tiled")
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: existing))
    }

    func testNoRulesMeansNothingChanges() async throws {
        activeWindowRules = []
        let (pin, _) = try messengerPin()
        let window = try await appear(11, app: messenger, title: "Photo Viewer", order: [11, 10])
        assertPlacedAsBefore(window, notIn: pin, "Without a rule, as before")
    }

    func testMovedToATabOfItsOwnItStaysItsOwn() async throws {
        let (pin, _) = try messengerPin()
        let viewer = try await appear(11, app: messenger, title: "Photo Viewer", order: [11, 10])
        AuxiliaryWindowRegistry.shared.detach(viewer)
        XCTAssertNil(auxiliaryWindowParent(of: viewer))
        let tile = try await tile(pin)
        XCTAssertEqual(tile.cells, [10, 11], "Detached on purpose: a window of its own")
    }
}
