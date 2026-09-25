import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceLauncherTest: XCTestCase {
    override func tearDown() {
        WorkspaceLauncherPanel.shared.dismiss()
        NewWindowIntentRegistry.shared.resetForTests()
        MessageModel.shared.message = nil
        config = defaultConfig
        super.tearDown()
    }

    func testOnlyTestedAppsGetANewWindowAndOthersAreLabeled() {
        let safariScript = "tell application id \"com.apple.Safari\" to make new document"
        XCTAssertEqual(newWindowMethod(bundleId: "com.apple.Safari", isRunning: true, menuFallbackEnabled: false),
            .script(safariScript))
        XCTAssertEqual(newWindowMethod(bundleId: "com.apple.Safari", isRunning: false, menuFallbackEnabled: false),
            .launchThenScript(safariScript), "A tested app that isn't running restores its session, then makes the window")
        XCTAssertEqual(newWindowMethod(bundleId: "com.example.Editor", isRunning: false, menuFallbackEnabled: false), .open)
        XCTAssertEqual(newWindowMethod(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: false), .unsupported)
        XCTAssertEqual(newWindowMethod(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: true), .menuItem)
        for (bundleId, command) in newWindowScriptCommands {
            XCTAssertFalse(command.contains("activate"), "\(bundleId) must not bring its other windows forward")
        }

        XCTAssertEqual(launcherAppAction(bundleId: "com.apple.Terminal", isRunning: true, menuFallbackEnabled: false), .newWindow)
        XCTAssertEqual(launcherAppAction(bundleId: "com.apple.Terminal", isRunning: false, menuFallbackEnabled: false), .newWindow)
        XCTAssertEqual(launcherAppAction(bundleId: "com.example.Editor", isRunning: false, menuFallbackEnabled: false), .open)
        XCTAssertEqual(launcherAppAction(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: false).label,
            "No new window", "An app without new-window support says so instead of switching to it")
    }

    func testTheMenuFallbackPressesOnlyANewWindowItem() {
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Tab", "New Window", "New Private Window"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Folder", "New Finder Window"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Finder Window", "New Window"]), 1, "An exact match wins")
        XCTAssertEqual(bestNewWindowMenuItemIndex(["Neuer Tab", "Neues Fenster"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Tab", "New Window…"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Window…", "New Window"]), 1, "One that asks nothing first wins")
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Tab", "New\u{00A0}Window "]), 1)
        XCTAssertNil(bestNewWindowMenuItemIndex(["New Document", "New Tab", "New Message"]),
            "A document, tab, or message is not a window")
        XCTAssertNil(bestNewWindowMenuItemIndex(["New Private Window", "New Incognito Window…"]))
    }

    func testScriptFailuresExplainMissingPermission() {
        XCTAssertEqual(newWindowScriptResult(exitStatus: 0, stderr: ""), .success)
        XCTAssertEqual(newWindowScriptResult(exitStatus: 1,
            stderr: "execution error: Not authorized to send Apple events to Safari. (-1743)"), .notAuthorized)
        XCTAssertEqual(newWindowScriptResult(exitStatus: 1, stderr: "execution error: Safari got an error. (-10000)\n"),
            .failed("execution error: Safari got an error. (-10000)"))
        XCTAssertEqual(newWindowScriptResult(exitStatus: 2, stderr: ""), .failed("AppleScript exited with status 2"))
    }

    func testResultsOfferRunningAppsFirstAndMatchNamesBeforeScatteredLetters() {
        let safari = LauncherApp(bundleId: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let slack = LauncherApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"))
        let notes = LauncherApp(bundleId: "com.apple.Notes", name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"))
        let code = LauncherApp(bundleId: "com.microsoft.VSCode", name: "Code", url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
        let winMux = LauncherApp(bundleId: winMuxAppId, name: "WinMux", url: nil)

        XCTAssertEqual(launcherResults(installed: [safari, slack, notes, winMux], running: [notes], query: "").map(\.name),
            ["Notes", "Safari", "Slack"], "Running apps first, then alphabetical; never WinMux")
        XCTAssertEqual(launcherResults(installed: [slack, safari], running: [], query: "sa").first?.name, "Safari")
        XCTAssertEqual(launcherResults(installed: [code], running: [], query: "visual").map(\.name), ["Code"],
            "An app is found by its bundle's name too")
        XCTAssertEqual(launcherResults(installed: [safari, notes], running: [safari], query: "").filter { $0 == safari }.count, 1,
            "A running app appears once")
    }

    func testScanningFindsAppsInFoldersAndSkipsMenuBarHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ path: String, bundleId: String, name: String, extra: [String: Any] = [:]) throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            info.merge(extra) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Editor.app", bundleId: "com.example.editor", name: "Editor")
        try makeApp("Suite/Writer.app", bundleId: "com.example.writer", name: "Writer", extra: ["CFBundleDisplayName": "Writer Pro"])
        try makeApp("Helper.app", bundleId: "com.example.helper", name: "Helper", extra: ["LSUIElement": true])
        try makeApp("OldHelper.app", bundleId: "com.example.old-helper", name: "Old Helper", extra: ["LSUIElement": "1"])
        try makeApp("Daemon.app", bundleId: "com.example.daemon", name: "Daemon", extra: ["LSBackgroundOnly": "YES"])
        try makeApp("Agent.app", bundleId: "com.example.agent", name: "Agent", extra: ["LSUIElement": 1])
        try makeApp("Visible.app", bundleId: "com.example.visible", name: "Visible", extra: ["LSUIElement": "NO"])

        let apps = scanLauncherApps(in: [root]).sorted { $0.name < $1.name }
        XCTAssertEqual(apps.map(\.name), ["Editor", "Visible", "Writer Pro"])
        XCTAssertEqual(apps.map(\.bundleId), ["com.example.editor", "com.example.visible", "com.example.writer"])
    }

    func testOptionsAreOffByDefaultAndParse() {
        XCTAssertFalse(defaultConfig.workspaceSidebar.newWorkspaceLauncher)
        XCTAssertFalse(defaultConfig.workspaceSidebar.launcherMenuFallback)
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            new-workspace-launcher = true
            launcher-menu-fallback = true
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertTrue(parsed.workspaceSidebar.newWorkspaceLauncher)
        XCTAssertTrue(parsed.workspaceSidebar.launcherMenuFallback)
    }

    func testOpenLauncherCommandParses() throws {
        let plain = try XCTUnwrap(parseCommand("open-launcher").cmdOrNil as? OpenLauncherCommand)
        XCTAssertFalse(plain.args.newWorkspace)
        let newWorkspace = try XCTUnwrap(parseCommand("open-launcher --new-workspace").cmdOrNil as? OpenLauncherCommand)
        XCTAssertTrue(newWorkspace.args.newWorkspace)
    }

    func testLauncherSitsInsideTheWorkspaceArea() {
        let frame = workspaceLauncherFrame(in: mainMonitor)
        let area = mainMonitor.visibleRectPaddedByOuterGaps
        XCTAssertLessThanOrEqual(frame.width, workspaceLauncherWidth)
        XCTAssertGreaterThanOrEqual(frame.minX, area.topLeftX)
        XCTAssertLessThanOrEqual(frame.maxX, area.topLeftX + area.width)
    }

    func testLauncherRendersResultsWithTheirActions() throws {
        let model = WorkspaceLauncherModel()
        model.workspaceTitle = "Workspace 4"
        model.running = [
            LauncherApp(bundleId: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            LauncherApp(bundleId: "com.apple.Notes", name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app")),
        ]
        model.setInstalled([
            LauncherApp(bundleId: "com.apple.Terminal", name: "Terminal", url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")),
            LauncherApp(bundleId: "com.apple.TextEdit", name: "TextEdit", url: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
            LauncherApp(bundleId: "com.apple.Preview", name: "Preview", url: URL(fileURLWithPath: "/System/Applications/Preview.app")),
        ])
        let host = NSHostingView(rootView: WorkspaceLauncherView(model: model).frame(width: workspaceLauncherWidth)
            .padding(20).background(Color(white: 0.12)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.results.map(\.name), ["Safari", "Preview", "Terminal", "TextEdit", "Notes"],
            "Apps that can open a new window come first; running Notes can't")
        XCTAssertEqual(model.action(for: model.results[0]), .newWindow)
        XCTAssertEqual(model.action(for: model.results[1]), .open)
        XCTAssertEqual(model.action(for: model.results[2]), .newWindow, "Terminal isn't running but has an adapter")
        XCTAssertEqual(model.action(for: model.results[4]), .unsupported, "Notes has no adapter and the fallback is off")
        let maybeBitmap: NSBitmapImageRep? = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        let bitmap: NSBitmapImageRep = try XCTUnwrap(maybeBitmap)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/launcher-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png: Data = try XCTUnwrap(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("launcher.png"))

        model.state = .opening(appName: "Safari")
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let openingBitmap: NSBitmapImageRep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: openingBitmap)
        let openingPng: Data = try XCTUnwrap(openingBitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        try openingPng.write(to: directory.appendingPathComponent("launcher-opening.png"))
    }

    func testTheSelectedAppStaysSelectedWhenInstalledAppsArrive() {
        let safari = LauncherApp(bundleId: "com.apple.Safari", name: "Safari", url: nil)
        let notes = LauncherApp(bundleId: "com.apple.Notes", name: "Notes", url: nil)
        let model = WorkspaceLauncherModel()
        model.running = [safari, notes]
        model.moveSelection(1)
        XCTAssertEqual(model.results[model.selection], notes)

        model.setInstalled([
            LauncherApp(bundleId: "com.apple.Terminal", name: "Terminal", url: nil),
            LauncherApp(bundleId: "com.apple.TextEdit", name: "TextEdit", url: nil),
        ])

        XCTAssertEqual(model.results.map(\.name), ["Safari", "Terminal", "TextEdit", "Notes"])
        XCTAssertEqual(model.results[model.selection], notes, "Return still chooses what the user selected")
        model.moveSelection(10)
        XCTAssertEqual(model.selection, 3)

        model.notice = "Notes can't open a new window from WinMux."
        model.setInstalled([LauncherApp(bundleId: "com.apple.Preview", name: "Preview", url: nil)])
        XCTAssertEqual(model.results[model.selection], notes)
        XCTAssertNotNil(model.notice, "The notice is about the app still selected")
    }

    func testChoosingAnAppWithoutNewWindowSupportExplainsInsteadOfSwitching() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        let panel = WorkspaceLauncherPanel.shared
        XCTAssertTrue(panel.show(forWorkspaceNamed: focus.workspace.name))
        let notes = LauncherApp(bundleId: "com.example.running-notes", name: "Notes", url: nil)
        // A second result to move to, whether or not the installed-app catalog has loaded yet.
        let other = LauncherApp(bundleId: "com.example.running-other", name: "Other", url: nil)
        panel.model.running = [notes, other]

        panel.model.onChoose?(notes)

        XCTAssertTrue(panel.isShowing, "The user stays in the launcher to pick something else")
        XCTAssertEqual(panel.model.state, .choosing)
        XCTAssertEqual(panel.model.notice,
            "Notes can't open a new window from WinMux. Turn on “Use an app's New Window menu” in Settings to try its menu.")
        panel.model.moveSelection(1)
        panel.model.moveSelection(-1)
        XCTAssertNil(panel.model.notice, "Moving on clears it")

        panel.model.moveSelection(3)
        panel.dismiss()
        XCTAssertTrue(panel.show(forWorkspaceNamed: focus.workspace.name))
        XCTAssertEqual(panel.model.selection, 0, "Each time it opens, the top result is selected")
    }

    func testAnEarlierLauncherSessionsRequestNeverChangesTheCurrentOne() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        let panel = WorkspaceLauncherPanel.shared
        let name = focus.workspace.name
        let missing = LauncherApp(bundleId: "com.example.not-installed-\(UUID().uuidString)", name: "Ghost", url: nil)

        XCTAssertTrue(panel.show(forWorkspaceNamed: name))
        panel.model.onChoose?(missing)
        XCTAssertEqual(panel.model.state, .opening(appName: "Ghost"))
        panel.dismiss()
        XCTAssertTrue(panel.show(forWorkspaceNamed: name))
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(panel.model.state, .choosing, "The dismissed session's failure doesn't reach the new one")
        XCTAssertNil(MessageModel.shared.message)

        panel.model.onChoose?(missing)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        let failure = "Ghost isn't installed"
        XCTAssertTrue(panel.model.state == .failed(failure) || MessageModel.shared.message?.body == failure,
            "The current session reports why nothing opened")
    }

    func testCancelWhileOpeningClosesTheLauncherAndWithdrawsTheRequest() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        let panel = WorkspaceLauncherPanel.shared
        let missing = LauncherApp(bundleId: "com.example.not-installed-\(UUID().uuidString)", name: "Ghost", url: nil)
        XCTAssertTrue(panel.show(forWorkspaceNamed: focus.workspace.name))
        panel.model.onChoose?(missing)
        XCTAssertEqual(panel.model.state, .opening(appName: "Ghost"))

        panel.model.onDismiss?() // Cancel

        XCTAssertFalse(panel.isShowing)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(MessageModel.shared.message, "A withdrawn request doesn't report a failure afterwards")
    }

    func testLauncherOnlyOpensForAVisibleWorkspace() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        let panel = WorkspaceLauncherPanel.shared
        panel.show(forWorkspaceNamed: "never-created")
        XCTAssertFalse(panel.isShowing)
        let hidden = Workspace.get(byName: "hidden-launcher-workspace")
        panel.show(forWorkspaceNamed: hidden.name)
        XCTAssertFalse(panel.isShowing, "The launcher belongs to a workspace on screen")

        panel.show(forWorkspaceNamed: focus.workspace.name)
        XCTAssertTrue(panel.isShowing)
        _ = hidden.focusWorkspace()
        panel.revalidate()
        XCTAssertFalse(panel.isShowing, "Switching away closes it")
    }
}
