@testable import AppBundle
import AppKit
import Common
import XCTest

/// A pinned app whose own helper processes (a background helper inside its bundle, a system XPC
/// service such as Quick Look's) showed windows in the pin while it was used. Once the app's window
/// is closed, the pin is that app's: it shows and opens that app alone, not each process that ever
/// had a window there. Bundles here are synthetic, made in a temporary folder.
@MainActor
final class SavedWorkspaceHelperWindowTest: XCTestCase {
    private var folder: URL!
    private let messenger = "com.example.messenger"
    private let helper = "com.example.messenger.helper"
    private let service = "com.example.QuickPreviewService"
    private let editor = "com.example.editor"
    private var messengerPath: String { folder.appendingPathComponent("Messenger.app").path }
    private var helperPath: String { folder.appendingPathComponent("Messenger.app/Contents/MacOS/Messenger Helper.app").path }
    private var servicePath: String {
        folder.appendingPathComponent("Preview.framework/Versions/A/XPCServices/QuickPreviewService.xpc").path
    }
    private var editorPath: String { folder.appendingPathComponent("Editor.app").path }
    private let longAgo = savedTestNow.addingTimeInterval(-86400)

    private lazy var messengerApp = TestApp(pid: 501, bundleId: messenger, name: "Messenger", bundlePath: messengerPath, launchDate: longAgo)
    private lazy var helperApp = TestApp(pid: 502, bundleId: helper, name: "Messenger Helper", bundlePath: helperPath, launchDate: longAgo)
    private lazy var serviceApp = TestApp(pid: 503, bundleId: service, name: "QuickPreviewService", bundlePath: servicePath, launchDate: longAgo)
    private lazy var editorApp = TestApp(pid: 504, bundleId: editor, name: "Editor", bundlePath: editorPath, launchDate: longAgo)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetWorkspaceTabsForTests()
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        NewWindowIntentRegistry.shared.resetForTests()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-helper-\(UUID().uuidString)")
        try makeBundle(messengerPath, bundleId: messenger, packageType: "APPL")
        try makeBundle(helperPath, bundleId: helper, packageType: "APPL", extra: ["LSUIElement": true])
        try makeBundle(servicePath, bundleId: service, packageType: "XPC!")
        try makeBundle(editorPath, bundleId: editor, packageType: "APPL")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    private func makeBundle(_ path: String, bundleId: String, packageType: String, extra: [String: Any] = [:]) throws {
        let contents = URL(fileURLWithPath: path).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundlePackageType": packageType,
                                   "CFBundleName": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent]
        info.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func running(_ apps: [TestApp]) -> [String: [SavedRunningApp]] {
        Dictionary(apps.map { ($0.rawAppBundleId!, [SavedRunningApp(pid: $0.pid, launchDate: longAgo)]) }, uniquingKeysWith: { a, _ in a })
    }

    /// A pin holding the messenger's window, with the helper's and the service's windows beside it.
    private func pinWithHelperWindows() throws -> (Workspace, [TestWindow]) {
        let pin = try makeSavedTestWorkspace("chat", displayName: "Messenger")
        try setWorkspaceSidebarTabFavorite(pin, true)
        let main = TestWindow.new(id: 701, parent: pin.rootTilingContainer, app: messengerApp, title: "Messenger")
        let helperWindow = TestWindow.new(id: 702, parent: pin.rootTilingContainer, app: helperApp, title: "Mini program")
        let serviceWindow = TestWindow.new(id: 703, parent: pin.rootTilingContainer, app: serviceApp, title: "photo.jpg")
        let everyone = running([messengerApp, helperApp, serviceApp])
        setSavedWorkspaceTestEnvironment(runningApps: everyone)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: everyone))
        return (pin, [main, helperWindow, serviceWindow])
    }

    /// Every window closes. The messenger keeps running, as such apps do; its helper and the service
    /// exit with their windows. Checkpoints run until a closed window's grace is over.
    private func closeEverything(_ windows: [TestWindow]) {
        for window in windows { window.unbindFromParent() }
        let messengerOnly = running([messengerApp])
        setSavedWorkspaceTestEnvironment(runningApps: messengerOnly)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: messengerOnly))
        let later = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        setSavedWorkspaceTestEnvironment(now: later, runningApps: messengerOnly)
        captureSavedWorkspaces(facts: savedTestFacts(now: later, runningApps: messengerOnly))
    }

    func testAClosedPinShowsItsAppNotTheHelpersThatHadWindowsInIt() throws {
        let (pin, windows) = try pinWithHelperWindows()
        closeEverything(windows)

        XCTAssertEqual(workspaceSidebarSavedApps(for: pin).map(\.bundleId), [messenger],
            "One icon: the messenger's, not its helper's or a system service's")
    }

    func testClickingTheClosedPinOpensOnlyItsApp() async throws {
        let (pin, windows) = try pinWithHelperWindows()
        closeEverything(windows)
        var asked: [String] = []
        var launched: [String] = []
        savedWorkspaceRuntime.environment.openApplication = { bundleId, _ in
            launched.append(bundleId)
            return true
        }

        openSavedTabApps(pin) { target, _ in asked.append(target.bundleId) }
        _ = await openMissingSavedWorkspaceApps(workspaceNames: [pin.name])

        XCTAssertEqual(asked, [messenger], "The messenger, still running, is asked for a window")
        XCTAssertEqual(launched, [], "Nothing launches a helper or a service by itself")
        XCTAssertEqual(missingSavedWorkspaceApps(workspaceNames: [pin.name]).map(\.bundleId), [],
            "Neither is an app the pin is missing")
    }

    func testAPinThatReallyHadTwoAppsKeepsBoth() throws {
        let pin = try makeSavedTestWorkspace("work", displayName: "Work")
        try setWorkspaceSidebarTabFavorite(pin, true)
        let a = TestWindow.new(id: 801, parent: pin.rootTilingContainer, app: messengerApp, title: "Messenger")
        let b = TestWindow.new(id: 802, parent: pin.rootTilingContainer, app: editorApp, title: "notes.txt")
        let both = running([messengerApp, editorApp])
        setSavedWorkspaceTestEnvironment(runningApps: both)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: both))
        a.unbindFromParent()
        b.unbindFromParent()
        let later = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        setSavedWorkspaceTestEnvironment(now: later, runningApps: both)
        captureSavedWorkspaces(facts: savedTestFacts(now: later, runningApps: both))

        XCTAssertEqual(workspaceSidebarSavedApps(for: pin).map(\.bundleId), [messenger, editor])
    }
}
