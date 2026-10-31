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
        resetSavedWorkspaceHelperCacheForTests()
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
        resetSavedWorkspaceHelperCacheForTests()
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

    /// A pin saved before WinMux told helpers apart: its record still holds their places and lists them
    /// among its apps.
    private func pinSavedBeforeTheFix() throws -> Workspace {
        var record = SavedWorkspaceRecord(workspaceName: "legacy", displayName: "Messenger", layout: SavedWorkspaceLayout(root: savedRoot(.tiles, .h, [
            .slot(SavedWindowSlot(id: "main", bundleId: messenger, appName: "Messenger", bundlePath: messengerPath, lastWindowId: 901, lastPid: 501)),
            .slot(SavedWindowSlot(id: "helper", bundleId: helper, appName: "Messenger Helper", bundlePath: helperPath, lastWindowId: 902, lastPid: 502)),
            .slot(SavedWindowSlot(id: "service", bundleId: service, appName: "QuickPreviewService", bundlePath: servicePath, lastWindowId: 903, lastPid: 503)),
        ])))
        record.launchApps = [
            SavedLaunchApp(bundleId: messenger, bundlePath: messengerPath, appName: "Messenger"),
            SavedLaunchApp(bundleId: helper, bundlePath: helperPath, appName: "Messenger Helper"),
            SavedLaunchApp(bundleId: service, bundlePath: servicePath, appName: "QuickPreviewService"),
        ]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "legacy"))
        try setWorkspaceSidebarTabFavorite(pin, true)
        return pin
    }

    func testAPinSavedBeforeTheFixShowsAndOpensOnlyItsAppAndForgetsTheHelpersAtTheNextCheckpoint() async throws {
        let pin = try pinSavedBeforeTheFix()
        // The messenger quit: its place keeps waiting for it, as before.
        setSavedWorkspaceTestEnvironment(runningApps: [:])
        XCTAssertEqual(workspaceSidebarSavedApps(for: pin).map(\.bundleId), [messenger], "Shown right away, without a checkpoint")
        var launched: [String] = []
        savedWorkspaceRuntime.environment.openApplication = { bundleId, _ in
            launched.append(bundleId)
            return true
        }
        _ = await openMissingSavedWorkspaceApps(workspaceNames: [pin.name])
        XCTAssertEqual(launched, [messenger], "Only the messenger relaunches")

        captureSavedWorkspaces(facts: savedTestFacts(runningApps: [:]))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.map(\.id), ["main"],
            "The helpers' places are dropped; the quit messenger's keeps waiting")
    }

    func testRightAfterAStartTheHelpersPlacesAreDroppedButTheAppsKeepWaiting() throws {
        let pin = try pinSavedBeforeTheFix()
        setSavedWorkspaceTestEnvironment(runningApps: [:])
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: [:], startupRestoreActive: true))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.map(\.id), ["main"])
    }

    func testAMinimizedWindowOfTheAppKeepsItsPlace() throws {
        let (pin, windows) = try pinWithHelperWindows()
        windows[0].unbindFromParent()
        windows[0].bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        windows[0].layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: pin.name)
        windows[1].unbindFromParent()
        windows[2].unbindFromParent()
        let messengerOnly = running([messengerApp])
        let later = savedTestNow.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace + 1)
        setSavedWorkspaceTestEnvironment(now: later, runningApps: messengerOnly)
        captureSavedWorkspaces(facts: savedTestFacts(now: later, runningApps: messengerOnly))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.map(\.bundleId), [messenger],
            "Minimized, the messenger's window still belongs to the pin; the helpers' places are gone")
    }

    func testWhatCountsAsAHelper() {
        let nestedAgent = "/Applications/Messenger.app/Contents/MacOS/Messenger Helper.app"
        XCTAssertTrue(savedWorkspaceBundleIsHelper(nestedAgent, info: ["CFBundlePackageType": "APPL", "LSUIElement": true]))
        XCTAssertTrue(savedWorkspaceBundleIsHelper(nestedAgent, info: ["LSBackgroundOnly": "1"]))
        XCTAssertTrue(savedWorkspaceBundleIsHelper("/System/Library/Frameworks/X.framework/Versions/A/XPCServices/S.xpc", info: nil),
            "An XPC service by where it lives, even unread")
        XCTAssertTrue(savedWorkspaceBundleIsHelper("/Library/Services/S.bundle", info: ["CFBundlePackageType": "XPC!"]))
        XCTAssertFalse(savedWorkspaceBundleIsHelper("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app",
            info: ["CFBundlePackageType": "APPL"]), "A regular app inside another is an app")
        XCTAssertFalse(savedWorkspaceBundleIsHelper("/Applications/MenuBarTool.app", info: ["LSUIElement": true]),
            "A menu bar app of its own is an app")
        XCTAssertFalse(savedWorkspaceBundleIsHelper(nestedAgent, info: nil), "Unreadable and not a service: no telling")
        XCTAssertFalse(savedWorkspaceAppIsHelper(bundlePath: nil))
    }
}
