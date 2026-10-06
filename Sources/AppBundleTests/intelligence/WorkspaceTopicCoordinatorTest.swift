@testable import AppBundle
import Common
import XCTest

/// The suggestion run: never the model while off, one model call at a time even when a call
/// ignores cancellation, stale results dropped, everything forgotten when it's turned off.
/// The provider here is a fake; these tests never run the on-device model.
@MainActor
final class WorkspaceTopicCoordinatorTest: XCTestCase {
    private var provider: FakeWorkspaceTopicProvider!
    private var coordinator: WorkspaceTopicCoordinator!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
        provider = FakeWorkspaceTopicProvider(script: ["ECON 4310": ["ECON 4310"], "tiling-app": ["tiling-app"]])
        coordinator = WorkspaceTopicTestEnvironment.setUp(provider: provider)
    }

    override func tearDown() async throws {
        await provider.release()
        WorkspaceTopicTestEnvironment.tearDown()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    private func makeTabs() {
        let titles: [(String, TestApp, String)] = [
            ("deck", TopicTestApps.keynote, "ECON 4310 week 3"),
            ("grades", TopicTestApps.numbers, "ECON 4310 grades"),
            ("code", TopicTestApps.xcode, "Config.swift — tiling-app"),
            ("shell", TopicTestApps.terminal, "tiling-app — build"),
        ]
        for (index, (name, app, title)) in titles.enumerated() {
            TestWindow.new(id: UInt32(200 + index), parent: Workspace.get(byName: name).rootTilingContainer, app: app, title: title)
        }
    }

    private func suggest(selection: [String]? = nil) async {
        await updateWorkspaceSidebarModel()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(selection: selection), snapshot: WorkspaceTopicTestEnvironment.snapshot)
    }

    private func groupNames() -> [String] { coordinator.groups.map(\.name).sorted() }

    func testOffNeverMakesTheProviderOrAsksTheModel() async throws {
        config.workspaceSidebar.intelligence.mode = .off
        var made = 0
        coordinator.makeProvider = { made += 1; return self.provider }
        makeTabs()
        for _ in 0 ..< 3 { await updateWorkspaceSidebarModel() }
        openWorkspaceTopicSuggestions(projectId: TrayMenuModel.shared.workspaceSidebarActiveProjectId, tabs: nil,
            panelScopeId: WorkspaceTopicTestEnvironment.scopeId)
        XCTAssertFalse(workspaceTopicSuggestionsOffered(projectId: TrayMenuModel.shared.workspaceSidebarActiveProjectId,
            panelScopeId: WorkspaceTopicTestEnvironment.scopeId))
        XCTAssertEqual(made, 0)
        XCTAssertFalse(coordinator.isActive)
        let checks = await provider.availabilityChecks
        let prompts = await provider.prompts
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(prompts, [])
    }

    func testARunQueuedJustBeforeOffNeverMakesTheProvider() async throws {
        var made = 0
        coordinator.makeProvider = { made += 1; return self.provider }
        makeTabs()
        await updateWorkspaceSidebarModel()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        // Off before the queued run gets a turn.
        config.workspaceSidebar.intelligence.mode = .off
        syncWorkspaceTopicSuggestions()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(made, 0, "No model object after Off")
        let checks = await provider.availabilityChecks
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(coordinator.cachedTagCount, 0)
    }

    func testANewExclusionStopsTheRunBeforeTheNextCall() async throws {
        makeTabs()
        await provider.hold()
        await suggest()
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        // Excluded while the first call runs: no later tab of that app may be sent.
        config.workspaceSidebar.intelligence.excludedApps = ["com.apple.Terminal"]
        await provider.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 1, "The run stopped at the change")
        XCTAssertFalse(prompts.joined().contains("Terminal"))
        await updateWorkspaceSidebarModel()
        XCTAssertFalse(coordinator.isActive, "And the preview closes")
        XCTAssertEqual(coordinator.cachedTagCount, 0, "Tags made under the old settings are forgotten")
    }

    func testANewRequestStartsWithoutTheLastOnesConsent() async throws {
        makeTabs()
        TestWindow.new(id: 270, parent: Workspace.get(byName: "web").rootTilingContainer, app: TopicTestApps.safari,
            title: "ECON 4310 syllabus")
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        let token = try XCTUnwrap(coordinator.request?.prepared.skipped.first { $0.reason == .browser(appName: "Safari") }?.token)
        coordinator.setBrowserTab(token, included: true)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        var prompts = await provider.prompts
        XCTAssertEqual(prompts.filter { $0.contains("syllabus") }.count, 1)
        // Without cancelling the open preview, ask again from a menu.
        openWorkspaceTopicSuggestions(projectId: TrayMenuModel.shared.workspaceSidebarActiveProjectId, tabs: nil,
            panelScopeId: WorkspaceTopicTestEnvironment.scopeId)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        prompts = await provider.prompts
        XCTAssertEqual(prompts.filter { $0.contains("syllabus") }.count, 1, "Cached tags aren't asked for, and the browser tab is out again")
        XCTAssertEqual(coordinator.includedBrowserTabs, [])
        XCTAssertTrue(coordinator.request?.prepared.skipped.contains { $0.reason == .browser(appName: "Safari") } == true)
        WorkspaceTopicSuggestionPanel.shared.close()
    }

    func testOnlyTabsModeOffersSuggestions() async {
        makeTabs()
        await updateWorkspaceSidebarModel()
        let project = TrayMenuModel.shared.workspaceSidebarActiveProjectId
        let scope = WorkspaceTopicTestEnvironment.scopeId
        XCTAssertTrue(workspaceTopicSuggestionsOffered(projectId: project, panelScopeId: scope))
        XCTAssertFalse(workspaceTopicSuggestionsOffered(projectId: "another", panelScopeId: scope), "Only the project shown")
        config.workspaceSidebar.mode = .sidebar
        XCTAssertFalse(workspaceTopicSuggestionsOffered(projectId: project, panelScopeId: scope))
        XCTAssertEqual(config.workspaceSidebar.mode, .sidebar, "Nothing switches the mode")
    }

    func testASuggestionGroupsByTheModelsTags() async throws {
        makeTabs()
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(groupNames(), ["ECON 4310", "tiling-app"])
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 4, "One request per tab; the empty tab wasn't sent")
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("setUpWorkspacesForTests") })
        XCTAssertEqual(coordinator.request?.prepared.skipped.map(\.reason), [], "The empty tab isn't listed, so it's left out")
    }

    func testUnavailableSaysWhyAndSendsNothing() async throws {
        provider = FakeWorkspaceTopicProvider(availability: .unavailable(.appleIntelligenceNotEnabled))
        coordinator.makeProvider = { self.provider }
        coordinator.reset()
        makeTabs()
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .unavailable(.appleIntelligenceNotEnabled))
        let prompts = await provider.prompts
        XCTAssertEqual(prompts, [])
        coordinator.makeProvider = { nil }
        coordinator.reset()
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .unavailable(.requiresNewerMacOS), "No model before macOS 26")
    }

    func testAReplacedSuggestionWaitsForTheCallItLeftRunning() async throws {
        makeTabs()
        await provider.hold()
        await suggest()
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        // A second request replaces the first while its model call ignores cancellation.
        await suggest(selection: ["deck", "grades"])
        try await Task.sleep(nanoseconds: 50_000_000)
        var running = await provider.running
        XCTAssertEqual(running, 1, "The new run waits instead of starting a second call")
        await provider.release()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        running = await provider.maximumRunning
        XCTAssertEqual(running, 1)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(groupNames(), ["ECON 4310"], "The late result of the replaced run isn't published")
        XCTAssertEqual(coordinator.request?.scope.selection, ["deck", "grades"])
    }

    func testCancelDropsALateResult() async throws {
        makeTabs()
        await provider.hold()
        await suggest()
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        coordinator.cancel()
        await provider.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.request)
        XCTAssertEqual(coordinator.groups, [])
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 1, "Nothing else was asked after Cancel")
    }

    func testATabThatTimesOutIsLeftOutAndTheDeadlineEndsTheRun() async throws {
        let clock = ManualWorkspaceTopicClock()
        coordinator.clock = clock
        coordinator.itemTimeout = 10
        coordinator.totalTimeout = 25
        makeTabs()
        await provider.hold()
        await suggest()
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        try await WorkspaceTopicTestEnvironment.waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: 10)
        // The first tab gave up; the next waits for the model call that's still running.
        try await WorkspaceTopicTestEnvironment.waitUntil {
            clock.sleeperCount == 1 && self.coordinator.phase == .analyzing(done: 1, total: 4)
        }
        var prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 1, "Never two calls at once, even after a timeout")
        clock.advance(by: 20)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.timedOut))
        await provider.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.phase, .failed(.timedOut), "The late answer changes nothing")
        prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 1)
    }

    func testTagsAreCachedInMemoryUntilTurnedOff() async throws {
        makeTabs()
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        var prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 4, "The same titles aren't asked about again")
        XCTAssertEqual(groupNames(), ["ECON 4310", "tiling-app"])
        XCTAssertEqual(coordinator.cachedTagCount, 4)
        config.workspaceSidebar.intelligence.mode = .off
        syncWorkspaceTopicSuggestions()
        XCTAssertEqual(coordinator.cachedTagCount, 0)
        config.workspaceSidebar.intelligence.mode = .manual
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 8)
    }

    func testTurningOffMidRunStopsAndForgetsEverything() async throws {
        makeTabs()
        await provider.hold()
        await suggest()
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        config.workspaceSidebar.intelligence.mode = .off
        await updateWorkspaceSidebarModel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.request)
        await provider.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.groups, [])
        XCTAssertEqual(coordinator.cachedTagCount, 0)
    }

    func testOneTabsRefusalLeavesItOutButABusyModelEndsTheRun() async throws {
        makeTabs()
        await provider.fail("week 3", with: .refused)
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(groupNames(), ["tiling-app"])
        XCTAssertEqual(coordinator.request?.untagged.count, 1, "The refused tab is listed as left out, with its own reason")
        XCTAssertEqual(coordinator.request?.thin, [])
        coordinator.reset()
        await provider.fail("grades", with: .busy)
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.busy))
        XCTAssertEqual(coordinator.groups, [])
    }

    func testBrowserConsentIsForThisSuggestionAndTheTextShown() async throws {
        makeTabs()
        let web = Workspace.get(byName: "web")
        let page = TestWindow.new(id: 260, parent: web.rootTilingContainer, app: TopicTestApps.safari, title: "ECON 4310 syllabus")
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        var prompts = await provider.prompts
        XCTAssertFalse(prompts.joined().contains("syllabus"), "Browser titles stay out by default: \(prompts)")
        let token = try XCTUnwrap(coordinator.request?.prepared.skipped.first { $0.reason == .browser(appName: "Safari") }?.token)
        coordinator.setBrowserTab(token, included: true)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        prompts = await provider.prompts
        XCTAssertTrue(prompts.contains { $0.contains("Safari: ECON 4310 syllabus") })
        XCTAssertEqual(coordinator.groups.first { $0.name == "ECON 4310" }?.members.count, 3)

        page.customTitle = "Lab results"
        resetCachedWindowTitles()
        await updateWorkspaceSidebarModel()
        coordinator.suggestAgain()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        prompts = await provider.prompts
        XCTAssertFalse(prompts.joined().contains("Lab results"), "A changed title isn't covered by the old consent")
        XCTAssertEqual(coordinator.includedBrowserTabs, [])

        let labResults = coordinator.request?.prepared.skipped.first { $0.reason == .browser(appName: "Safari") }?.token
        coordinator.setBrowserTab(try XCTUnwrap(labResults), included: true)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        coordinator.cancel()
        XCTAssertEqual(coordinator.includedBrowserTabs, [], "Consent ends with the preview")
        let sentBefore = await provider.prompts.count
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        let sentAfter = await provider.prompts.dropFirst(sentBefore)
        XCTAssertFalse(sentAfter.joined().contains("Lab results"))
    }

    func testAnotherProjectOrDisplayListClosesThePreview() async throws {
        makeTabs()
        await suggest()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertTrue(coordinator.isActive)
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = "monitor:9999,9999"
        syncWorkspaceTopicSuggestions()
        XCTAssertFalse(coordinator.isActive, "Not applied to a list the user no longer sees")
        TrayMenuModel.shared.workspaceSidebarSelectedMonitorScopeId = workspaceSidebarDefaultScopeId
    }
}
