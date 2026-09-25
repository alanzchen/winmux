@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class NewWindowIntentTest: XCTestCase {
    private var registry: NewWindowIntentRegistry { .shared }
    private var clock: TimeInterval = 1000

    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        registry.resetForTests()
        clock = 1000
        registry.now = { [unowned self] in self.clock }
    }

    override func tearDown() async throws {
        registry.resetForTests()
        config = defaultConfig
    }

    private let appId = "bobko.WinMux.test-app"

    func testTheRequestedWindowIsClaimedOnceForItsWorkspace() {
        let target = Workspace.get(byName: "launched")
        var outcomes: [NewWindowRequestOutcome] = []
        let intent = registry.register(bundleId: appId, pid: 7, targetWorkspaceName: target.name,
            preexistingWindowIds: [10], focusGeneration: 0) { outcomes.append($0) }
        XCTAssertNotNil(intent)

        XCTAssertNil(registry.claim(windowId: 10, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "A window the app already had is never the new one")
        XCTAssertNil(registry.claim(windowId: 11, pid: 8, bundleId: appId, firstSeenUptime: clock),
            "Another process of the same app isn't the one asked")
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: "com.other.app", firstSeenUptime: clock))
        XCTAssertNil(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: clock - 1),
            "A window first seen before the request, promoted from a popup now, isn't it")

        XCTAssertTrue(registry.claim(windowId: 11, pid: 7, bundleId: appId, firstSeenUptime: clock) === target)
        XCTAssertEqual(outcomes, [.placed(windowId: 11)])
        XCTAssertNil(registry.claim(windowId: 12, pid: 7, bundleId: appId, firstSeenUptime: clock),
            "The app's next window is placed normally")
        XCTAssertEqual(registry.consumeClaim(windowId: 11)?.targetWorkspaceName, target.name)
        XCTAssertNil(registry.consumeClaim(windowId: 11))
    }

    func testAnAppThatWasntRunningMatchesByBundleUntilItsPidIsKnown() {
        let target = Workspace.get(byName: "launched")
        let intent = registry.register(bundleId: appId, pid: nil, targetWorkspaceName: target.name,
            preexistingWindowIds: [], focusGeneration: 0)
        XCTAssertTrue(registry.claim(windowId: 20, pid: 99, bundleId: appId, firstSeenUptime: clock) === target)

        let second = registry.register(bundleId: appId, pid: nil, targetWorkspaceName: target.name,
            preexistingWindowIds: [], focusGeneration: 0)
        registry.setPid(5, forIntent: try! XCTUnwrap(second).id)
        XCTAssertNil(registry.claim(windowId: 21, pid: 6, bundleId: appId, firstSeenUptime: clock))
        XCTAssertNotNil(registry.claim(windowId: 21, pid: 5, bundleId: appId, firstSeenUptime: clock))
        _ = intent
    }

    func testOneRequestPerAppAndRequestsExpire() {
        var outcomes: [NewWindowRequestOutcome] = []
        XCTAssertNotNil(registry.register(bundleId: appId, pid: 1, targetWorkspaceName: "a",
            preexistingWindowIds: [], focusGeneration: 0) { outcomes.append($0) })
        XCTAssertNil(registry.register(bundleId: appId, pid: 1, targetWorkspaceName: "b",
            preexistingWindowIds: [], focusGeneration: 0), "Two requests couldn't tell their windows apart")

        clock += newWindowIntentTimeout + 1
        registry.expireOverdueIntents()
        XCTAssertEqual(outcomes, [.timedOut])
        XCTAssertFalse(registry.hasPendingIntents)
        XCTAssertNil(registry.claim(windowId: 30, pid: 1, bundleId: appId, firstSeenUptime: clock),
            "A window arriving after the deadline follows the usual rules")
    }

    func testAMissingDestinationIsNeverRecreated() {
        var outcomes: [NewWindowRequestOutcome] = []
        registry.register(bundleId: appId, pid: 1, targetWorkspaceName: "deleted-meanwhile",
            preexistingWindowIds: [], focusGeneration: 0) { outcomes.append($0) }
        XCTAssertNil(registry.claim(windowId: 40, pid: 1, bundleId: appId, firstSeenUptime: clock))
        XCTAssertNil(Workspace.existing(byName: "deleted-meanwhile"))
        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testAClaimedWindowKeepsItsDestinationOverOtherPlacementRules() async throws {
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        run = ['move-node-to-workspace mail']
        """)
        XCTAssertEqual(errors.descriptions, [])
        config.onWindowDetected = parsed.onWindowDetected
        config.openNewWindowsInNewWorkspace = true
        let origin = focus.workspace
        _ = TestWindow.new(id: 1, parent: origin.rootTilingContainer)
        let target = Workspace.get(byName: "launched")

        registry.register(bundleId: appId, pid: TestApp.shared.pid, targetWorkspaceName: target.name,
            preexistingWindowIds: [], focusGeneration: focusChangeGeneration)
        let claimed = try XCTUnwrap(registry.claim(windowId: 2, pid: TestApp.shared.pid, bundleId: appId,
            firstSeenUptime: clock))
        let binding = newWindowIntentBinding(targetWorkspace: claimed)
        let window = TestWindow.new(id: 2, parent: binding.parent)

        let restored = try await restoreOrDetectNewWindow(window, isRegularWindow: true)

        XCTAssertFalse(restored)
        XCTAssertTrue(window.nodeWorkspace === target,
            "Neither on-window-detected rules nor the new-workspace option move a window the launcher placed")
        XCTAssertNil(Workspace.existing(byName: "mail"))
    }

    func testUnclaimedWindowsStillFollowTheUsualRules() async throws {
        config.openNewWindowsInNewWorkspace = true
        let origin = focus.workspace
        _ = TestWindow.new(id: 1, parent: origin.rootTilingContainer)
        let window = TestWindow.new(id: 2, parent: origin.rootTilingContainer)
        _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
        XCTAssertFalse(window.nodeWorkspace === origin, "Without an intent the new-workspace option still applies")
    }
}
