@testable import AppBundle
import Common
import XCTest

/// What a suggestion may read: the sidebar's own list, whole splits only, no browser titles by
/// default, and nothing the sidebar didn't already publish.
@MainActor
final class WorkspaceTopicSnapshotTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
        _ = WorkspaceTopicTestEnvironment.setUp(provider: FakeWorkspaceTopicProvider())
    }

    override func tearDown() async throws {
        WorkspaceTopicTestEnvironment.tearDown()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    private func tab(_ name: String, _ windows: [(UInt32, TestApp, String)]) -> Workspace {
        let workspace = Workspace.get(byName: name)
        for (id, app, title) in windows { TestWindow.new(id: id, parent: workspace.rootTilingContainer, app: app, title: title) }
        return workspace
    }

    private func prepare(selection: [String]? = nil, consents: [WorkspaceTopicBrowserConsent] = [],
                         privacy: WorkspaceIntelligenceConfig? = nil) async -> WorkspaceTopicPreparedRequest {
        await updateWorkspaceSidebarModel()
        return prepareWorkspaceTopicRequest(scope: WorkspaceTopicTestEnvironment.scope(selection: selection),
            snapshot: WorkspaceTopicTestEnvironment.snapshot, privacy: privacy ?? config.workspaceSidebar.intelligence,
            consents: consents)
    }

    private func name(_ request: WorkspaceTopicPreparedRequest, _ token: WorkspaceTopicToken) -> String? {
        request.bindings[token]?.name
    }

    func testBrowserAndExcludedAppsSkipTheirWholeSplit() async {
        config.workspaceSidebar.intelligence.excludedApps = ["com.example.Secret"]
        _ = tab("code", [(1, TopicTestApps.xcode, "Config.swift — tiling-app")])
        _ = tab("web", [(2, TopicTestApps.xcode, "Model.swift — tiling-app"), (3, TopicTestApps.safari, "Bank statement")])
        _ = tab("private", [(4, TopicTestApps.terminal, "tiling-app — build"), (5, TopicTestApps.secret, "Diary")])
        let request = await prepare()
        XCTAssertEqual(request.candidates.compactMap { name(request, $0.token) }.filter { $0 != "setUpWorkspacesForTests" }, ["code"])
        let skipped = Dictionary(uniqueKeysWithValues: request.skipped.map { (name(request, $0.token) ?? "", $0) })
        XCTAssertEqual(skipped["web"]?.reason, .browser(appName: "Safari"))
        XCTAssertEqual(skipped["web"]?.preview, "Tab: web\nXcode: Model.swift — tiling-app\nSafari: Bank statement",
            "The preview is exactly what including it would send")
        XCTAssertEqual(skipped["private"]?.reason, .excludedApp(appName: "Secret"))
        XCTAssertNil(skipped["private"]?.preview, "An excluded app's titles are never shown for consent")
        XCTAssertFalse(request.candidates.map(\.promptText).joined().contains("Bank"))
        XCTAssertFalse(request.candidates.map(\.promptText).joined().contains("Diary"))
    }

    func testAMinimizedBrowserWindowStillSkipsItsSplit() async {
        let split = tab("split", [(10, TopicTestApps.xcode, "Config.swift — tiling-app")])
        let hidden = TestWindow.new(id: 11, parent: split.rootTilingContainer, app: TopicTestApps.safari, title: "Private search")
        hidden.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        hidden.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: split.name)
        let request = await prepare()
        XCTAssertFalse(request.candidates.contains { name(request, $0.token) == "split" },
            "The sidebar doesn't list the minimized window, but it's still the tab's")
        let skipped = request.skipped.first { name(request, $0.token) == "split" }
        XCTAssertEqual(skipped?.reason, .partlyHidden)
        XCTAssertNil(skipped?.preview, "Its whole text can't be shown, so it can't be included either")
        XCTAssertEqual(request.bindings.values.first { $0.name == "split" }?.windows.map(\.windowId), [10, 11])
    }

    func testASplitWithAWindowItCantReadIsLeftWhole() async {
        // The minimized window could be about something else: the split must not join the
        // visible window's topic.
        let split = tab("split", [(12, TopicTestApps.xcode, "Config.swift — tiling-app")])
        let hidden = TestWindow.new(id: 13, parent: split.rootTilingContainer, app: TopicTestApps.terminal, title: "Divorce papers")
        hidden.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        hidden.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: split.name)
        _ = tab("peer", [(14, TopicTestApps.terminal, "tiling-app — build")])
        let request = await prepare()
        XCTAssertFalse(request.candidates.contains { name(request, $0.token) == "split" })
        XCTAssertEqual(request.skipped.first { name(request, $0.token) == "split" }?.reason, .partlyHidden)
        XCTAssertFalse(request.candidates.map(\.promptText).joined().contains("Divorce"), "Never read")
        let many = tab("many", (0 ..< 7).map { (UInt32(20 + $0), TopicTestApps.xcode, "tiling-app part \($0)") })
        _ = many
        let crowded = await prepare()
        XCTAssertEqual(crowded.skipped.first { name(crowded, $0.token) == "many" }?.reason, .partlyHidden,
            "A seventh window the request can't take could be about something else")
    }

    func testPinnedAndGroupedTabsAreLeftAsTheyAre() async throws {
        _ = tab("pinned", [(20, TopicTestApps.xcode, "tiling-app")])
        _ = tab("grouped", [(21, TopicTestApps.terminal, "tiling-app")])
        _ = tab("free", [(22, TopicTestApps.keynote, "tiling-app talk")])
        try workspaceSidebarOrganizationStore.update { $0.workspaces["pinned", default: .init()].setFavorite(true) }
        _ = try workspaceSidebarOrganizationStore.create(projectId: focus.workspace.projectId, workspaceNames: ["grouped"])
        let request = await prepare()
        let names = Set(request.bindings.values.map(\.name))
        XCTAssertFalse(names.contains("pinned"))
        XCTAssertFalse(names.contains("grouped"))
        XCTAssertTrue(names.contains("free"))
        XCTAssertEqual(request.unchangedCount, 2)
    }

    func testAChosenSetLimitsTheRequest() async {
        _ = tab("one", [(30, TopicTestApps.xcode, "tiling-app")])
        _ = tab("two", [(31, TopicTestApps.terminal, "tiling-app")])
        _ = tab("three", [(32, TopicTestApps.keynote, "tiling-app")])
        let request = await prepare(selection: ["one", "three"])
        XCTAssertEqual(Set(request.candidates.compactMap { name(request, $0.token) }), ["one", "three"])
    }

    func testOnlyTheListedDisplaysTabsAreRead() {
        let here = tab("here", [(40, TopicTestApps.xcode, "tiling-app")])
        let there = tab("there", [(41, TopicTestApps.terminal, "tiling-app")])
        func model(_ workspace: Workspace, scope: String, window: UInt32, app: String) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: workspace.name, projectId: workspace.projectId, displayName: workspace.name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: scope, monitorName: nil, isFocused: false, isVisible: false,
                items: [.init(kind: .window(.init(windowId: window, workspaceName: workspace.name, appName: app, appBundleId: nil,
                    appBundlePath: nil, title: "tiling-app", isFocused: false)))])
        }
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = [model(here, scope: "monitor:0,0", window: 40, app: "Xcode"),
                               model(there, scope: "monitor:2000,0", window: 41, app: "Terminal")]
        snapshot.selectedMonitorScopeId = "monitor:0,0"
        let scope = WorkspaceTopicScope(projectId: here.projectId, panelScopeId: "monitor:0,0", listedScopeId: "monitor:0,0", selection: nil)
        let request = prepareWorkspaceTopicRequest(scope: scope, snapshot: snapshot)
        XCTAssertEqual(request.bindings.values.map(\.name), ["here"], "Another display's tab isn't in this list")
    }

    func testTitlesAreSanitizedAndOnlyUserLabelsAreUsed() async throws {
        let workspace = tab("w", [(50, TopicTestApps.terminal, "\(NSHomeDirectory())/Developer/tiling-app\u{7} — /Users/someone/x")])
        _ = workspace
        let request = await prepare()
        let evidence = try XCTUnwrap(request.candidates.first { name(request, $0.token) == "w" })
        XCTAssertEqual(evidence.windows.first?.title, "~/Developer/tiling-app — ~/x")
        XCTAssertEqual(evidence.label, "w", "An explicit tab name is a label")
        XCTAssertEqual(workspaceTopicSanitizedTitle(String(repeating: "长", count: 130), appName: "A")?.wasCut, true)
        XCTAssertNil(workspaceTopicSanitizedTitle("Terminal", appName: "Terminal"), "A title that only names the app")
        let generated = WorkspaceSidebarWorkspaceViewModel(name: "w2", projectId: workspace.projectId, displayName: "Bank statement",
            sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false,
            isVisible: false, items: [])
        XCTAssertNil(workspaceTopicEvidence(for: generated, token: .init(rawValue: 0), liveWindowCount: 0).label,
            "A generated name may come from a window title")
    }

    func testConsentIsBoundToTheExactTextAndWindowsShown() async throws {
        let web = tab("web", [(60, TopicTestApps.safari, "ECON 4310 syllabus")])
        let first = await prepare()
        let shown = try XCTUnwrap(first.skipped.first { name(first, $0.token) == "web" }?.preview)
        let consent = WorkspaceTopicBrowserConsent(name: "web", workspace: web, windowIds: [60], text: shown)
        let included = await prepare(consents: [consent])
        XCTAssertTrue(included.candidates.contains { $0.promptText == shown }, "Included with the text the user saw")

        (web.allLeafWindowsRecursive.first as? TestWindow)?.customTitle = "Medical results"
        resetCachedWindowTitles()
        let changed = await prepare(consents: [consent])
        XCTAssertFalse(changed.candidates.contains { name(changed, $0.token) == "web" }, "A new title isn't covered")
        XCTAssertEqual(changed.revokedConsents.count, 1)

        config.workspaceSidebar.intelligence.excludedApps = ["com.apple.Safari"]
        let excluded = await prepare(consents: [WorkspaceTopicBrowserConsent(name: "web", workspace: web, windowIds: [60],
            text: changed.skipped.first?.preview ?? "")])
        XCTAssertEqual(excluded.skipped.first { name(excluded, $0.token) == "web" }?.reason, .excludedApp(appName: "Safari"),
            "Excluding an app beats consent")
    }

    func testAWindowTheListShowsButIsGoneMakesTheTabStale() async {
        let a = tab("a", [(70, TopicTestApps.xcode, "tiling-app")])
        let b = tab("b", [(71, TopicTestApps.terminal, "tiling-app")])
        await updateWorkspaceSidebarModel()
        let snapshot = WorkspaceTopicTestEnvironment.snapshot
        a.allLeafWindowsRecursive.first?.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let request = prepareWorkspaceTopicRequest(scope: WorkspaceTopicTestEnvironment.scope(), snapshot: snapshot)
        XCTAssertEqual(request.skipped.first { name(request, $0.token) == "a" }?.reason, .changed)
    }

    func testBrowsersAreRecognizedByFamily() {
        for id in ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome.canary", "org.mozilla.firefox",
                   "company.thebrowser.Browser", "com.microsoft.edgemac.Dev", "com.brave.Browser.nightly", "com.kagi.kagimacOS"] {
            XCTAssertTrue(workspaceTopicIsBrowser(id), id)
        }
        XCTAssertFalse(workspaceTopicIsBrowser("com.apple.dt.Xcode"))
        XCTAssertFalse(workspaceTopicIsBrowser(nil))
    }
}
