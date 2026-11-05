@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a window placed under the window it was opened from stays under it when WinMux starts again,
/// while both are still the same windows of the same process in the same boot. Nothing else is linked:
/// no window gets a parent it didn't have, and one moved to a tab of its own, or whose parent closed, stays
/// its own.
@MainActor
final class AuxiliaryWindowLinksTest: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_793_000_000)
    private let boot = Date(timeIntervalSince1970: 1_792_900_000)
    private lazy var messenger = TestApp(pid: 61, bundleId: "com.example.messenger", name: "Messenger", launchDate: launch)
    private var folder: URL!
    private var savedURL: (@MainActor () -> URL?)?
    private var savedBoot: (() -> Date?)?
    private var savedProcess: ((Int32) -> (bundleId: String?, launch: Date?)?)?
    private var running: [Int32: (bundleId: String?, launch: Date?)] = [:]
    private var currentBoot: Date?

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-aux-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedURL = auxiliaryWindowLinksURL
        savedBoot = workspaceSidebarBootTime
        savedProcess = workspaceSidebarRunningProcess
        let url = folder.appendingPathComponent("auxiliary-window-links.json")
        auxiliaryWindowLinksURL = { url }
        currentBoot = boot
        workspaceSidebarBootTime = { [unowned self] in currentBoot }
        running = [messenger.pid: (messenger.rawAppBundleId, launch)]
        workspaceSidebarRunningProcess = { [unowned self] pid in running[pid] }
    }

    override func tearDown() async throws {
        if let savedURL { auxiliaryWindowLinksURL = savedURL }
        if let savedBoot { workspaceSidebarBootTime = savedBoot }
        if let savedProcess { workspaceSidebarRunningProcess = savedProcess }
        AuxiliaryWindowRegistry.shared.removeAll()
        try? FileManager.default.removeItem(at: folder)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    // MARK: - Helpers

    /// The messenger's pin, its window tiled and in use, and a dialog opened from it, placed under it as
    /// registration places it.
    private func pinWithLinkedDialog() async throws -> (pin: Workspace, main: TestWindow, dialog: TestWindow) {
        let pin = focus.workspace
        let main = TestWindow.new(id: 10, parent: pin.rootTilingContainer, app: messenger, title: "Messenger")
        try setWorkspaceSidebarTabFavorite(pin, true)
        XCTAssertTrue(main.focusWindow())
        let dialog = try await openAuxiliaryTestWindow(11, app: messenger, role: .dialog, from: main, title: "Moments")
        XCTAssertTrue(auxiliaryWindowParent(of: dialog) === main)
        return (pin, main, dialog)
    }

    /// WinMux quits and starts again: what it knew of the links in memory is gone, its windows are
    /// registered again where they are, and what it kept is read and recovered after the refresh.
    private func restart() {
        AuxiliaryWindowRegistry.shared.removeAll()
        loadAuxiliaryWindowLinksForStartup()
        recoverAuxiliaryWindowLinks()
    }

    private func pinCells(_ pin: Workspace) async throws -> (cells: [UInt32], counted: [UInt32]) {
        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:],
            availableMonitors: monitors)
        let model = try XCTUnwrap(models.first { $0.name == pin.name })
        return (workspaceSidebarPinnedTabWindows(model).map(\.windowId), model.associatedWindows.map(\.id))
    }

    // MARK: - Recovered

    func testALinkMadeBeforeARestartIsTheSameAfterIt() async throws {
        let (pin, main, dialog) = try await pinWithLinkedDialog()
        restart()
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: dialog), .dialog)
        XCTAssertTrue(auxiliaryWindowParent(of: dialog) === main, "Under the window it was opened from, as before")
        let tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [10], "The pin's cell is its own window")
        XCTAssertEqual(tile.counted, [11], "The dialog is counted under it, as before WinMux started again")
        XCTAssertTrue(dialog.isFloating && dialog.nodeWorkspace === pin, "Nothing moved")
    }

    // MARK: - Not recovered

    func testNothingIsLinkedForAnotherProcessOrBoot() async throws {
        let (pin, _, dialog) = try await pinWithLinkedDialog()
        running[messenger.pid] = (messenger.rawAppBundleId, launch.addingTimeInterval(60))
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog), "The app relaunched with the same number: another process")
        var tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [10, 11])

        let (_, _, again) = try await relink(dialog)
        running[messenger.pid] = (messenger.rawAppBundleId, launch)
        currentBoot = boot.addingTimeInterval(3600)
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: again), "Another boot: the numbers are another windows'")
        tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [10, 13])
    }

    func testAWindowNumberNowOfAnotherProcessIsNotLinked() async throws {
        let (pin, main, dialog) = try await pinWithLinkedDialog()
        // WinMux quits; the messenger's dialog closes meanwhile and another app's window gets its number.
        let other = TestApp(pid: 77, bundleId: "com.example.other", name: "Other", launchDate: launch)
        running[other.pid] = (other.rawAppBundleId, launch)
        _ = dialog.unbindFromParent()
        let stranger = TestWindow.new(id: 11, parent: pin, app: other, title: "")
        var now: TimeInterval = 1000
        let savedNow = auxiliaryWindowLinksNow
        defer { auxiliaryWindowLinksNow = savedNow }
        auxiliaryWindowLinksNow = { now }
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: stranger))
        XCTAssertNil(auxiliaryWindowParent(of: stranger))
        now += auxiliaryWindowLinksRecoveryWindow
        recoverAuxiliaryWindowLinks()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: stranger), "Nor once the wait is over: it's another window")
        XCTAssertEqual(pendingAuxiliaryWindowLinks, [])
        _ = main
    }

    func testAWindowMovedToATabOfItsOwnStaysItsOwnAfterARestart() async throws {
        let (pin, _, dialog) = try await pinWithLinkedDialog()
        AuxiliaryWindowRegistry.shared.detach(dialog)
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog), "Made a window of its own on purpose: for good")
        let tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [10, 11])
    }

    func testAWindowWhoseParentClosedIsItsOwnAfterARestart() async throws {
        let (pin, main, dialog) = try await pinWithLinkedDialog()
        AuxiliaryWindowRegistry.shared.forget(windowId: main.windowId, pid: messenger.pid)
        _ = main.unbindFromParent()
        restart()
        XCTAssertNil(auxiliaryWindowParent(of: dialog), "Its parent closed before WinMux quit: no parent after")
        let tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [11])
    }

    func testAWindowMovedToATabOfItsOwnWhileWinMuxStartsIsNotLinkedAgain() async throws {
        let (_, _, dialog) = try await pinWithLinkedDialog()
        AuxiliaryWindowRegistry.shared.removeAll()
        loadAuxiliaryWindowLinksForStartup()
        // Moved to a tab of its own before the refresh that would recover its link.
        AuxiliaryWindowRegistry.shared.detach(dialog)
        recoverAuxiliaryWindowLinks()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog))
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog), "Nor at the start after")
    }

    func testAParentClosedWhileWinMuxWasOffLeavesTheWindowItsOwnOnceItsWaitIsOver() async throws {
        let (pin, main, dialog) = try await pinWithLinkedDialog()
        var now: TimeInterval = 1000
        let savedNow = auxiliaryWindowLinksNow
        defer { auxiliaryWindowLinksNow = savedNow }
        auxiliaryWindowLinksNow = { now }
        // WinMux quits; the parent closes meanwhile. Its link was kept with that parent.
        _ = main.unbindFromParent()
        AuxiliaryWindowRegistry.shared.removeAll()
        loadAuxiliaryWindowLinksForStartup()
        recoverAuxiliaryWindowLinks()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog), "Waiting for its parent to be registered")
        XCTAssertEqual(pendingAuxiliaryWindowLinks.map(\.window.windowId), [11])
        now += auxiliaryWindowLinksRecoveryWindow
        recoverAuxiliaryWindowLinks()
        XCTAssertEqual(AuxiliaryWindowRegistry.shared.role(of: dialog), .dialog, "Its own role, as when a parent closes")
        XCTAssertNil(auxiliaryWindowParent(of: dialog))
        XCTAssertEqual(pendingAuxiliaryWindowLinks, [])
        let tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [11], "A window of its own")
    }

    func testNoSameAppWindowGetsALinkItNeverHad() async throws {
        let (pin, _, _) = try await pinWithLinkedDialog()
        let unlinked = TestWindow.new(id: 12, parent: pin, app: messenger, title: "")
        restart()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: unlinked))
        let tile = try await pinCells(pin)
        XCTAssertEqual(tile.cells, [10, 12], "Floating, of the same app, in the same pin, and still its own cell")
        XCTAssertEqual(tile.counted, [11])
    }

    func testAWindowTiledSinceIsNotLinkedBack() async throws {
        let (pin, _, dialog) = try await pinWithLinkedDialog()
        AuxiliaryWindowRegistry.shared.removeAll()
        _ = dialog.unbindFromParent()
        dialog.bind(to: pin.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        loadAuxiliaryWindowLinksForStartup()
        recoverAuxiliaryWindowLinks()
        XCTAssertNil(AuxiliaryWindowRegistry.shared.role(of: dialog), "Only a floating window is listed under another")
    }

    /// Links `dialog` again as it is, after a test's restart dropped it.
    private func relink(_ dialog: TestWindow) async throws -> (Workspace, TestWindow, TestWindow) {
        let pin = try XCTUnwrap(dialog.nodeWorkspace)
        let main = try XCTUnwrap(Window.get(byId: 10) as? TestWindow)
        _ = dialog.unbindFromParent()
        let again = try await openAuxiliaryTestWindow(13, app: messenger, role: .dialog, from: main, title: "Moments")
        XCTAssertTrue(auxiliaryWindowParent(of: again) === main)
        return (pin, main, again)
    }
}
