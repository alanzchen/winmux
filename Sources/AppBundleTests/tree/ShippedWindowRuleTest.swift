@testable import AppBundle
import AppKit
import Common
import XCTest

/// WinMux's shipped window rule, read from its own rules file as WinMux reads it: WeChat's image viewer, by its
/// English title "Photos and Videos", opened from a WeChat window in use just after a press, floats at its own
/// size over that window, listed under it. Nothing else changes: other WeChat windows, other apps, a viewer
/// with no clear opener, at startup or placed already. A user's rules file turns it off or replaces it by its
/// id. The app is a stand-in with WeChat's bundle id; windows and frames are synthetic.
@MainActor
final class ShippedWindowRuleTest: XCTestCase {
    private let wechat = TestApp(pid: 71, bundleId: "com.tencent.xinWeChat", name: "WeChat")
    private let other = TestApp(pid: 72, bundleId: "com.example.photos", name: "Photos")
    private let viewerFrame = Rect(topLeftX: 500, topLeftY: 200, width: 825, height: 600)
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var savedRules: [WindowRule] = []
    private var savedUserFile: (@MainActor () -> URL?)?
    private var folder: URL!

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        savedRules = activeWindowRules
        savedUserFile = windowRulesUserFileUrl
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        newWindowAppIsFrontmost = { _ in true }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-shipped-rule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        windowRulesUserFileUrl = { nil }
        // WinMux's rules, as startup and Reload Config read them: no rule is put in by hand.
        activeWindowRules = loadWindowRules().rules
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        activeWindowRules = savedRules
        if let savedUserFile { windowRulesUserFileUrl = savedUserFile }
        AuxiliaryWindowRegistry.shared.removeAll()
        try? FileManager.default.removeItem(at: folder)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    // MARK: - Helpers

    /// A pin of `app`: its main window tiled and in use.
    private func pin(of app: TestApp) throws -> (pin: Workspace, main: TestWindow) {
        let pin = focus.workspace
        let main = TestWindow.new(id: 10, parent: pin.rootTilingContainer, app: app, title: "Weixin")
        try setWorkspaceSidebarTabFavorite(pin, true)
        XCTAssertTrue(main.focusWindow())
        noteAppActivatedForAuxiliaryWindows(pid: app.pid, at: auxiliaryFocusSpan.since - 1)
        return (pin, main)
    }

    private func refocus(_ main: TestWindow) { XCTAssertTrue(main.focusWindow()) }

    /// A regular window first seen as registration sees one, its role from the rules in effect: placed under its
    /// opener when the origin holds and a rule names it, otherwise as any regular new window.
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

    private func tile(_ pin: Workspace) async throws -> (cells: [UInt32], counted: [UInt32]) {
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:], availableMonitors: monitors)
        let model = try XCTUnwrap(models.first { $0.name == pin.name })
        return (workspaceSidebarPinnedTabWindows(model).map(\.windowId), model.associatedWindows.map(\.id))
    }

    private func assertAsBefore(_ window: TestWindow, notIn pin: Workspace, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(window.nodeWorkspace === pin, message, file: file, line: line)
        XCTAssertFalse(window.isFloating, message, file: file, line: line)
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: window), message, file: file, line: line)
    }

    private func writeUserRules(_ text: String) throws {
        let url = folder.appendingPathComponent("window-rules.toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        windowRulesUserFileUrl = { url }
        let loaded = loadWindowRules()
        XCTAssertEqual(loaded.problems, [])
        activeWindowRules = loaded.rules
    }

    // MARK: - On by default

    func testWeChatsPhotosAndVideosOpenedFromItsWindowFloatsUnderItAtItsOwnSize() async throws {
        let (pin, main) = try pin(of: wechat)
        let tabsBefore = Workspace.all.count
        let viewer = try await appear(11, app: wechat, title: "Photos and Videos", order: [11, 10])
        XCTAssertTrue(viewer.nodeWorkspace === pin && viewer.isFloating, "Floating over its window, in its tab")
        XCTAssertTrue(auxiliaryWindowParent(of: viewer) === main)
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: viewer), .windowRule)
        XCTAssertEqual(Workspace.all.count, tabsBefore, "No tab of its own")
        XCTAssertEqual(viewer.lastKnownActualRect, auxiliaryWindowFrame(viewerFrame, in: pin.workspaceMonitor.visibleRectPaddedByOuterGaps))
        XCTAssertEqual(viewer.nativeRect, viewerFrame, "Its own size, as WeChat gave it")
        let tile = try await tile(pin)
        XCTAssertEqual(tile.cells, [10])
        XCTAssertEqual(tile.counted, [11])
    }

    // MARK: - Nothing else

    func testOtherWeChatWindowsOtherAppsAndOtherLanguagesAreAsBefore() async throws {
        let (pin, main) = try pin(of: wechat)
        let chat = try await appear(11, app: wechat, title: "Chat", order: [11, 10])
        assertAsBefore(chat, notIn: pin, "A chat window WeChat opens from its window")
        refocus(main)
        let chinese = try await appear(12, app: wechat, title: "图片和视频", order: [12, 10])
        assertAsBefore(chinese, notIn: pin, "Another language's title isn't covered by the shipped rule")
        refocus(main)
        let dialogKind = try await appear(13, app: wechat, title: "Photos and Videos", subrole: "AXDialog", order: [13, 10])
        assertAsBefore(dialogKind, notIn: pin, "Another subrole")
    }

    func testTheSameTitleInAnotherAppIsAsBefore() async throws {
        let (pin, _) = try pin(of: other)
        let window = try await appear(11, app: other, title: "Photos and Videos", order: [11, 10])
        assertAsBefore(window, notIn: pin, "Not WeChat")
    }

    func testAViewerWithNoClearOpenerIsAsBefore() async throws {
        let (pin, main) = try pin(of: wechat)
        let unprompted = try await appear(11, app: wechat, title: "Photos and Videos", pressed: false, order: [11, 10])
        assertAsBefore(unprompted, notIn: pin, "No press just before it")
        refocus(main)
        let behind = try await appear(12, app: wechat, title: "Photos and Videos", order: [10, 12])
        assertAsBefore(behind, notIn: pin, "Not right above the window in use")
    }

    func testAtStartupNoViewerIsTakenForOne() async throws {
        let (_, _) = try pin(of: wechat)
        let since = auxiliaryFocusSpan.since
        let evidence = $_isStartup.withValue(true) {
            captureAuxiliaryWindowOriginEvidence(newWindowId: 11, pid: wechat.pid, observedAt: since + 0.2,
                environment: AuxiliaryWindowOriginEnvironment(
                    orderedWindows: { [AuxiliaryOrderedWindow(id: 11, pid: 71, layer: 0), AuxiliaryOrderedWindow(id: 10, pid: 71, layer: 0)] },
                    lastUserInput: { since + 0.1 }, appIsActive: { _ in true }))
        }
        XCTAssertNil(evidence, "Windows found at startup have no origin, so no rule is asked")
        var asked = false
        let placement = await auxiliaryWindowPlacement(evidence, type: .window, role: {
            await newWindowAuxiliaryRole(bundleId: wechat.rawAppBundleId, ownRole: { nil },
                facts: { asked = true; return WindowRuleFacts(title: "Photos and Videos", subrole: "AXStandardWindow") })
        })
        XCTAssertNil(placement)
        XCTAssertFalse(asked)
    }

    func testAViewerAlreadyPlacedIsLeftWhereItIsThroughARestart() async throws {
        let (pin, main) = try pin(of: wechat)
        // Tiled by the user, or placed before the rule was there.
        let tiled = TestWindow.new(id: 12, parent: pin.rootTilingContainer, app: wechat, title: "Photos and Videos")
        refocus(main)
        let viewer = try await appear(11, app: wechat, title: "Photos and Videos", order: [11, 10])
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: viewer), .windowRule)
        XCTAssertTrue(tiled.parent === pin.rootTilingContainer, "The tiled one stays tiled")
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: tiled))
        // WinMux starts again: rules aren't asked about windows it finds; nothing kept names the tiled one.
        AuxiliaryWindowRegistry.shared.removeAll()
        loadAuxiliaryWindowLinksForStartup()
        recoverAuxiliaryWindowLinks()
        XCTAssertTrue(tiled.parent === pin.rootTilingContainer)
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: tiled))
    }

    // MARK: - The user's say

    func testAUserFileTurnsItOffOrReplacesIt() async throws {
        let (pin, main) = try pin(of: wechat)
        try writeUserRules("version = 1\n[[rule]]\nid = \"wechat-image-viewer\"\nenabled = false\n")
        let off = try await appear(11, app: wechat, title: "Photos and Videos", order: [11, 10])
        assertAsBefore(off, notIn: pin, "Turned off by its id")

        try writeUserRules("""
            version = 1
            [[rule]]
            id = "wechat-image-viewer"
            app-id = "com.tencent.xinWeChat"
            window-title = ["Photos and Videos", "图片和视频"]
            subrole = "AXStandardWindow"
            opened-from = "focused-window"
            action = "float-under-opener"
            """)
        refocus(main)
        let chinese = try await appear(12, app: wechat, title: "图片和视频", order: [12, 10])
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: chinese), .windowRule, "Replaced with the user's titles")
        XCTAssertTrue(auxiliaryWindowParent(of: chinese) === main)
    }
}
