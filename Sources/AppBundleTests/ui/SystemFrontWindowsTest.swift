import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class SystemFrontWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws {
        resetSystemFrontStateForTests()
        WorkspaceSidebarPanel.shared.applyWorkspaceSidebarLayer(stayOnTop: config.workspaceSidebar.stayOnTop)
        setMonitorsForTests(nil)
    }

    private func window(_ id: UInt32, pid: pid_t, layer: Int = 0, _ frame: CGRect) -> OrderedOnScreenWindow {
        OrderedOnScreenWindow(id: id, pid: pid, layer: layer, frame: frame)
    }

    private let prompt = OrderedOnScreenWindow(id: 3, pid: 12, layer: 0, frame: CGRect(x: 280, y: 170, width: 460, height: 180))
    private let editor = OrderedOnScreenWindow(id: 4, pid: 13, layer: 0, frame: CGRect(x: 80, y: 50, width: 600, height: 500))

    func testOnlySystemSettingsAndPromptsBelowWinMuxChromeAreListed() {
        let windows = [
            window(1, pid: 10, layer: 1000, CGRect(x: 380, y: 130, width: 260, height: 310)), // authorization dialog
            window(2, pid: 11, layer: 8, CGRect(x: 380, y: 130, width: 260, height: 280)),
            prompt, editor,
            window(5, pid: 14, CGRect(x: 150, y: 60, width: 720, height: 620)),
            window(6, pid: 14, CGRect(x: 0, y: 0, width: 20, height: 20)),
            window(7, pid: 14, CGRect(x: 2000, y: 1400, width: 720, height: 620)),
            window(8, pid: 11, layer: -2147483601, CGRect(x: 0, y: 0, width: 360, height: 180)),
        ]
        let bundles: [pid_t: String] = [10: "com.apple.SecurityAgent", 11: SystemFrontApp.notificationPrompt,
                                        12: SystemFrontApp.accessPrompt, 13: "com.apple.TextEdit", 14: SystemFrontApp.systemSettings]
        XCTAssertEqual(selectSystemFrontWindows(in: windows, bundleIdsByPid: bundles, isHiddenByWinMux: { $0 == 7 }).map(\.id),
            [2, 3, 5], "Front to back, without dialogs already above WinMux, other apps, tiny or hidden windows")
    }

    func testAPromptComesBackOnlyWhenTheFrontmostAppsWindowCoversIt() {
        let own = window(9, pid: 99, CGRect(x: 280, y: 170, width: 460, height: 30))
        let floating = window(8, pid: 13, layer: 3, CGRect(x: 280, y: 170, width: 460, height: 180))
        let tracking = window(10, pid: 13, CGRect(x: 300, y: 200, width: 1, height: 1))
        let background = window(11, pid: 15, CGRect(x: 80, y: 50, width: 600, height: 500))
        XCTAssertEqual(coveredAccessPrompt(in: [editor, prompt], promptPids: [12], frontmostPid: 13, ownPid: 99), prompt)
        XCTAssertNil(coveredAccessPrompt(in: [prompt, editor], promptPids: [12], frontmostPid: 13, ownPid: 99),
            "A prompt in front needs nothing")
        XCTAssertNil(coveredAccessPrompt(in: [own, floating, tracking, prompt], promptPids: [12], frontmostPid: 13, ownPid: 99),
            "WinMux's chrome, higher levels, and tiny tracking windows do not count")
        XCTAssertNil(coveredAccessPrompt(in: [background, prompt], promptPids: [12], frontmostPid: 13, ownPid: 99),
            "A window of a background app cannot be beaten by activation; it must not cause a loop")
        XCTAssertNil(coveredAccessPrompt(in: [editor, prompt], promptPids: [12], frontmostPid: 12, ownPid: 99),
            "Once the prompt is frontmost, it is not activated again")
        XCTAssertNil(coveredAccessPrompt(in: [editor, prompt], promptPids: [12], frontmostPid: 99, ownPid: 99))
    }

    func testTheDecisionCombinesListingActivationAndPromptState() {
        let settings = window(5, pid: 14, CGRect(x: 150, y: 60, width: 720, height: 620))
        let running = [RunningSystemApp(pid: 12, bundleId: SystemFrontApp.accessPrompt, isActive: false),
                       RunningSystemApp(pid: 14, bundleId: SystemFrontApp.systemSettings, isActive: false)]
        let covered = decideSystemFront(windows: [editor, prompt, settings], running: running, frontmostPid: 13, ownPid: 99)
        XCTAssertEqual(covered.front.map(\.id), [3, 5])
        XCTAssertEqual(covered.activatePid, 12)
        XCTAssertTrue(covered.showsPrompt)
        let settingsOnly = decideSystemFront(windows: [editor, settings], running: running, frontmostPid: 13, ownPid: 99)
        XCTAssertEqual(settingsOnly, SystemFrontDecision(front: [SystemFrontWindow(id: 5, bundleId: SystemFrontApp.systemSettings,
            layer: 0, frame: settings.frame)], activatePid: nil, showsPrompt: false), "System Settings is never forced to the front")
    }

    func testSystemSettingsKeepsFocusOnlyWhileItOpens() {
        XCTAssertFalse(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: .regular,
            systemSettingsIsOpening: true), "Focusing the previous window would bury System Settings")
        XCTAssertTrue(shouldSyncFocusBackToMacOs(nativeFocused: nil, frontmostActivationPolicy: .regular))
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        noteSystemSettingsActivation(now: start)
        XCTAssertTrue(isSystemSettingsOpening(now: start.addingTimeInterval(1)))
        XCTAssertFalse(isSystemSettingsOpening(now: start.addingTimeInterval(4)),
            "A windowless System Settings left frontmost later gets focus handed back as usual")
    }

    func testSystemSettingsJoinsTheFocusedWorkspaceOnlyFromAHiddenOne() {
        let hidden = Workspace.get(byName: "hidden")
        let current = Workspace.get(byName: "current")
        XCTAssertTrue(current.focusWorkspace())
        let floating = TestWindow.new(id: 1, parent: hidden)
        let tiled = TestWindow.new(id: 2, parent: hidden.rootTilingContainer)
        bringSystemSettingsToFocusedWorkspace(floating)
        XCTAssertTrue(floating.nodeWorkspace === hidden, "Only System Settings moves")
        XCTAssertTrue(moveFloatingWindowToFocusedWorkspace(floating))
        XCTAssertTrue(floating.nodeWorkspace === current)
        XCTAssertTrue(floating.isFloating)
        XCTAssertFalse(moveFloatingWindowToFocusedWorkspace(tiled), "A window the user tiled keeps its place")
        XCTAssertFalse(moveFloatingWindowToFocusedWorkspace(floating), "Already here")
    }

    func testSystemSettingsVisibleOnAnotherDisplayStaysThere() {
        let main = WorkspaceNamingTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let secondary = WorkspaceNamingTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Secondary",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([main, secondary])
        let elsewhere = Workspace.get(byName: "elsewhere")
        XCTAssertTrue(secondary.setActiveWorkspace(elsewhere))
        let current = Workspace.get(byName: "current")
        XCTAssertTrue(main.setActiveWorkspace(current))
        XCTAssertTrue(current.focusWorkspace())
        let floating = TestWindow.new(id: 1, parent: elsewhere)
        XCTAssertTrue(elsewhere.isVisible)
        XCTAssertFalse(moveFloatingWindowToFocusedWorkspace(floating), "Activating it must not pull it across displays")
        XCTAssertTrue(floating.nodeWorkspace === elsewhere)
    }

    func testTheSidebarTakesTheHighestLevelBelowSystemWindowsThatShareItsArea() {
        let sidebar = WinMuxPanelLayer.workspaceSidebar.level
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: true, yieldingToLayer: 0), .normal)
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: true, yieldingToLayer: 8), .floating,
            "Beneath an Automation prompt, the Dock stays above ordinary windows")
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: false, yieldingToLayer: 8), .floating)
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: false, yieldingToLayer: 0), .normal)
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: true), sidebar)
        XCTAssertEqual(workspaceSidebarPanelLevel(stayOnTop: true, yieldingToLayer: 1000), sidebar)

        let panelArea = CGRect(x: 0, y: 0, width: 600, height: 400)
        let automation = SystemFrontWindow(id: 1, bundleId: SystemFrontApp.notificationPrompt, layer: 8, frame: panelArea)
        let settings = SystemFrontWindow(id: 2, bundleId: SystemFrontApp.systemSettings, layer: 0, frame: panelArea)
        let access = SystemFrontWindow(id: 3, bundleId: SystemFrontApp.accessPrompt, layer: 0, frame: panelArea)
        XCTAssertEqual(workspaceSidebarPanelYieldTarget([automation, access, settings], panelFrame: panelArea), settings,
            "Beneath an Automation prompt over System Settings, the panel stays beneath System Settings too")
        XCTAssertNil(workspaceSidebarPanelYieldTarget([automation], panelFrame: panelArea.offsetBy(dx: 2000, dy: 0)))

        let panel = WorkspaceSidebarPanel.shared
        let panelFrame = CGRect(x: panel.frame.minX, y: mainMonitor.height - panel.frame.maxY,
            width: max(panel.frame.width, 1), height: max(panel.frame.height, 1))
        // Layer 8 needs no ordering relative to a window that does not exist in tests.
        let prompt = SystemFrontWindow(id: 1, bundleId: SystemFrontApp.notificationPrompt, layer: 8, frame: panelFrame)
        setSystemFrontWindowsForTests([prompt])
        panel.applyWorkspaceSidebarLayer(stayOnTop: true)
        XCTAssertEqual(panel.level, .floating)
        panel.applyWorkspaceSidebarLayer(stayOnTop: true, yieldsToSystemWindows: false)
        XCTAssertEqual(panel.level, sidebar, "A Dock opened for use stays usable")
        setSystemFrontWindowsForTests([SystemFrontWindow(id: 1, bundleId: SystemFrontApp.notificationPrompt, layer: 8,
            frame: panelFrame.offsetBy(dx: panelFrame.width + 5000, dy: 0))])
        panel.applyWorkspaceSidebarLayer(stayOnTop: true)
        XCTAssertEqual(panel.level, sidebar, "A prompt elsewhere leaves the panel above windows")

        let wasExpanded = panel.viewModel.isWorkspaceSidebarExpanded
        defer { panel.viewModel.isWorkspaceSidebarExpanded = wasExpanded }
        panel.viewModel.isWorkspaceSidebarExpanded = true
        XCTAssertEqual(panel.isAtRest, config.workspaceSidebar.alwaysExpanded)
        panel.viewModel.isWorkspaceSidebarExpanded = false
        XCTAssertTrue(panel.isAtRest)
    }
}
