import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceLauncherTest: XCTestCase {
    override func tearDown() {
        config = defaultConfig
        super.tearDown()
    }

    func testOnlyTestedAppsGetANewWindowAndOthersAreLabeled() {
        XCTAssertEqual(newWindowMethod(bundleId: "com.apple.Safari", isRunning: true, menuFallbackEnabled: false),
            .script("tell application id \"com.apple.Safari\" to make new document"))
        XCTAssertEqual(newWindowMethod(bundleId: "com.apple.Safari", isRunning: false, menuFallbackEnabled: false), .launch,
            "An app that isn't running opens its first window on launch")
        XCTAssertEqual(newWindowMethod(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: false), .unsupported)
        XCTAssertEqual(newWindowMethod(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: true), .menuItem)
        for (bundleId, command) in newWindowScriptCommands {
            XCTAssertFalse(command.contains("activate"), "\(bundleId) must not bring its other windows forward")
        }

        XCTAssertEqual(launcherAppAction(bundleId: "com.apple.Terminal", isRunning: true, menuFallbackEnabled: false), .newWindow)
        XCTAssertEqual(launcherAppAction(bundleId: "com.example.Editor", isRunning: false, menuFallbackEnabled: false), .open)
        XCTAssertEqual(launcherAppAction(bundleId: "com.example.Editor", isRunning: true, menuFallbackEnabled: false).label,
            "Switch to app", "An app without new-window support says so instead of silently switching")
    }

    func testTheMenuFallbackPressesOnlyANewWindowItem() {
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Tab", "New Window", "New Private Window"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["New Folder", "New Finder Window"]), 1)
        XCTAssertEqual(bestNewWindowMenuItemIndex(["Neuer Tab", "Neues Fenster"]), 1)
        XCTAssertNil(bestNewWindowMenuItemIndex(["New Document", "New Tab", "New Message"]),
            "A document, tab, or message is not a window")
        XCTAssertNil(bestNewWindowMenuItemIndex(["New Private Window", "New Incognito Window"]))
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

        let apps = scanLauncherApps(in: [root]).sorted { $0.name < $1.name }
        XCTAssertEqual(apps.map(\.name), ["Editor", "Writer Pro"])
        XCTAssertEqual(apps.map(\.bundleId), ["com.example.editor", "com.example.writer"])
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
        model.installed = [
            LauncherApp(bundleId: "com.apple.Terminal", name: "Terminal", url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")),
            LauncherApp(bundleId: "com.apple.TextEdit", name: "TextEdit", url: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
            LauncherApp(bundleId: "com.apple.Preview", name: "Preview", url: URL(fileURLWithPath: "/System/Applications/Preview.app")),
        ]
        let host = NSHostingView(rootView: WorkspaceLauncherView(model: model).frame(width: workspaceLauncherWidth)
            .padding(20).background(Color(white: 0.12)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.results.map(\.name), ["Safari", "Preview", "Terminal", "TextEdit", "Notes"],
            "Apps that can open a new window come first; Notes can only be switched to")
        XCTAssertEqual(model.action(for: model.results[0]), .newWindow)
        XCTAssertEqual(model.action(for: model.results[1]), .open)
        XCTAssertEqual(model.action(for: model.results[4]), .switchTo, "Notes has no adapter and the fallback is off")
        let maybeBitmap: NSBitmapImageRep? = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        let bitmap: NSBitmapImageRep = try XCTUnwrap(maybeBitmap)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/launcher-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png: Data = try XCTUnwrap(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("launcher.png"))
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
