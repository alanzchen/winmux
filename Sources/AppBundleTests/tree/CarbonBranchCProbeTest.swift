@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class CarbonBranchCProbeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        AuxiliaryWindowRegistry.shared.removeAll()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    func testIconCacheConcurrentReadsAndWritesNeverObserveFalseMisses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("carbon-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let key = BrowserTabIconDiskCache.digest(png)
        let partition = "safari:profile:carbon"
        let cache = BrowserTabIconDiskCache(directory: dir)
        cache.store(partition: partition, icon: key, png: png)

        await withTaskGroup(of: Bool.self) { group in
            for i in 0 ..< 16 {
                group.addTask {
                    if i.isMultiple(of: 4) {
                        cache.prune()
                        return cache.knows(partition: partition, icon: key)
                    } else if i.isMultiple(of: 5) {
                        cache.store(partition: partition, icon: key, png: png)
                        return cache.knows(partition: partition, icon: key)
                    } else {
                        return cache.knows(partition: partition, icon: key)
                    }
                }
            }
            for await hit in group {
                XCTAssertTrue(hit, "Prepared icon must remain known throughout concurrent prunes and stores")
            }
        }
    }

    /// REPRODUCER for CM-C1 (BLOCK):
    /// 1) A single-window pin `P` lends its window (`com.example.ulysses`) to an ordinary unsaved tab `B`.
    ///    `captureSavedWorkspaces` persists `P`'s slot with `membership = .lentFromPin`.
    /// 2) The app quits (`Cmd+Q`) or the Mac reboots: `P`'s `lentWindow` is cleared (`nil`), `B` has no saved slot,
    ///    and `P`'s context menu advertises `"Open Missing Apps (1)"` because `missingSavedWorkspaceApps` includes `.lentFromPin`.
    /// 3) Clicking `"Open Missing Apps (1)"` on `P` (`openSavedWorkspaceAppsFromSidebar(P.name)`) — or launching at
    ///    startup via `openMissingSavedWorkspaceApps(workspaceNames: nil)` (`open-saved-workspace-apps-at-startup = true`) —
    ///    launches `com.example.ulysses`, yet `waitingSavedSlots` skips `P`'s `.lentFromPin` slot because `preferred == nil`,
    ///    stranding `P` empty and leaving the newly launched window in an unpinned tab!
    func testCMC1_Reproducer_OpenMissingAppsOnPinAndStartupAutoLaunchFailToRestorePinAfterLoanEnds() async throws {
        let pin = Workspace.get(byName: "ulysses-pin")
        let borrower = Workspace.get(byName: "ordinary-unsaved-split")
        let otherActive = Workspace.get(byName: "active-tab")
        let ulysses = TestApp(pid: 901, bundleId: "com.example.ulysses", name: "Ulysses")
        let originalWin = TestWindow.new(id: 9011, parent: pin.rootTilingContainer, app: ulysses, title: "Notes")
        _ = TestWindow.new(id: 9012, parent: borrower.rootTilingContainer, app: TestApp(pid: 902, bundleId: "com.example.chat", name: "Chat"))

        try setWorkspaceSidebarTabFavorite(pin, true)
        try ensureSavedWorkspaceRecord(pin)
        // Ordinary tab `borrower` is NOT saved in `savedWorkspaceStore` (default Tabs mode behavior):
        try splitPinnedTabWindowWithTab(pin, borrower.name, placement: .right)
        captureSavedWorkspaces(facts: savedTestFacts(runningApps: [
            "com.example.ulysses": [.init(pid: 901, launchDate: nil)],
            "com.example.chat": [.init(pid: 902, launchDate: nil)],
        ]))
        XCTAssertEqual(savedWorkspaceStore.record(named: pin.name)?.layout.allSlots.first?.membership, .lentFromPin)

        // App quits (or Mac reboots): window closes and `lentWindow` is forgotten (`MacApp.destroy` / startup prune):
        originalWin.closeAxWindow()
        forgetWorkspaceSidebarPinWindows { $0.pid == 901 }
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[pin.name]?.lentWindow, "Loan has ended")
        XCTAssertTrue(otherActive.focusWorkspace())

        var launchedBundles: [String] = []
        savedWorkspaceRuntime.environment.runningApps = { [:] }
        savedWorkspaceRuntime.environment.openApplication = { bundleId, _ in
            launchedBundles.append(bundleId)
            return true
        }

        // Verify pin's context menu advertises "Open Missing Apps (1)":
        let savedState = try XCTUnwrap(workspaceSidebarSavedState(for: pin, runningApps: [:]))
        XCTAssertEqual(savedState.missingAppNames, ["Ulysses"])

        // User right-clicks `pin` and selects "Open Missing Apps (1)" (`openSavedWorkspaceAppsFromSidebar(pin.name)`):
        let launchResult = await openMissingSavedWorkspaceApps(workspaceNames: [pin.name])
        XCTAssertEqual(launchResult.opened, ["Ulysses"])
        XCTAssertEqual(launchedBundles, ["com.example.ulysses"])

        // Ulysses launches and opens its window:
        let relaunchedApp = TestApp(pid: 950, bundleId: "com.example.ulysses", name: "Ulysses", launchDate: savedTestNow)
        savedWorkspaceRuntime.environment.runningApps = { ["com.example.ulysses": [.init(pid: 950, launchDate: savedTestNow)]] }
        let reopenedWin = TestWindow.new(id: 9501, parent: otherActive.rootTilingContainer, app: relaunchedApp, title: "Notes")

        let routed = try await routeNewWindowToSavedWorkspaceIfNeeded(reopenedWin, isRegularWindow: true)
        XCTAssertTrue(routed, "CM-C1: Window launched by 'Open Missing Apps' on pin must route into pin")
        XCTAssertEqual(reopenedWin.nodeWorkspace?.name, pin.name, "CM-C1: Pin must not be stranded empty after launching its missing app")
    }
}
