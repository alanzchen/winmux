import AppKit
@testable import AppBundle
import SwiftUI
import Vision
import XCTest

final class BrowserTabsTest: XCTestCase {
    func testTabRadioValueFallsBackToSelectedWhenUnavailable() {
        XCTAssertEqual(browserTabSelectedValue(value: 0, selected: 1), false)
        XCTAssertEqual(browserTabSelectedValue(value: 1, selected: 1), true)
        XCTAssertEqual(browserTabSelectedValue(value: nil, selected: 1), true)
        XCTAssertNil(browserTabSelectedValue(value: nil, selected: nil))
    }

    func testPollingBacksOffFailuresAndNeverReadsHiddenWindows() {
        var schedule = BrowserTabReadSchedule()
        XCTAssertFalse(schedule.isDue(1, now: 0))
        schedule.watch([1, 2])
        schedule.focus(1)
        XCTAssertTrue(schedule.isDue(1, now: 0))
        var time = 0.0
        for interval in [1.0, 2, 4, 8, 16, 30, 30] {
            schedule.didRead(1, now: time, succeeded: false)
            schedule.markDirty(1)
            XCTAssertFalse(schedule.isDue(1, now: time + interval - 0.1))
            XCTAssertTrue(schedule.isDue(1, now: time + interval))
            time += interval
        }
        schedule.markDirty(1)
        XCTAssertTrue(schedule.isDue(1, now: time))
        schedule.didRead(1, now: time, succeeded: true)
        schedule.markDirty(1)
        XCTAssertFalse(schedule.isDue(1, now: time + 0.5), "Noisy notifications cannot cause four scans a second")
        XCTAssertTrue(schedule.isDue(1, now: time + 1))
        schedule.watch([])
        XCTAssertFalse(schedule.isDue(1, now: time + 1000))
        schedule.watch([1, 2])
        XCTAssertTrue(schedule.isDue(1, now: time), "Revealing the sidebar refreshes immediately")
        schedule.didRead(2, now: time, succeeded: false)
        schedule.focus(2)
        XCTAssertTrue(schedule.isDue(2, now: time), "Changing focus resets retry backoff")
    }

    func testIncompleteCachedStripKeepsContainerAndSelectionOnlyRechecksItsTarget() throws {
        let tree = fixture(.chromium)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        let rootReads = tree.root.structureReads
        tree.tabs[1].unreadable = true
        XCTAssertNil(tree.scanner.scan())
        XCTAssertTrue(tree.scanner.container === tree.container)
        XCTAssertTrue(tree.scanner.observedNodes.contains(tree.tabs[0]), "Incomplete icon confirmation must keep the selected tab's subscriptions")
        XCTAssertNil(tree.scanner.scan())
        XCTAssertEqual(tree.root.structureReads, rootReads)
        XCTAssertTrue(tree.scanner.select(snapshot.tabs[0].target), "An unrelated unreadable tab cannot block an exact live target")
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.select(snapshot.tabs[0].target), "A removed handle is rejected even before another complete scan")
    }

    func testLargeCachedStripGetsABoundedBudgetBasedOnItsSize() throws {
        let tree = fixture(.chromium)
        for _ in 0..<118 { tree.container.append(tab("Background", selected: false)) }
        var time = 0.0
        tree.container.nodes.forEach { $0.onInfoRead = { time += 0.0009 } }
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time })
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.count, 120)
        let snapshot = try XCTUnwrap(scanner.scan())
        XCTAssertEqual(snapshot.tabs.count, 120, "A 108 ms complete cached scan fits the scaled 150 ms cap")
        XCTAssertTrue(scanner.confirmsSelection(in: snapshot, until: time + 0.02), "Icons recheck just the selected control, not 120 tab records")
        tree.tabs[0].selected = false
        XCTAssertFalse(scanner.confirmsSelection(in: snapshot, until: time + 0.02))
        tree.tabs[0].selected = true
        XCTAssertFalse(scanner.confirmsSelection(in: snapshot, until: time + 0.02, cancelled: { true }))
        XCTAssertNil(scanner.scan(until: time + 0.02), "An outer job budget is still authoritative")
        XCTAssertTrue(scanner.container === tree.container)
    }

    func testUnreadableDiscoveryBranchNeverHidesAnUnknownSecondStrip() {
        let tree = fixture(.chromium)
        let unknown = BrowserTestNode("AXGroup")
        unknown.unreadable = true
        tree.root.append(unknown)
        XCTAssertNil(tree.scanner.scan(), "An unreadable branch may contain another tab container")
        unknown.unreadable = false
        XCTAssertNotNil(tree.scanner.scan())
    }

    func testCachedChromeStructureIsPeriodicallyRediscovered() throws {
        let tree = fixture(.chromium)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, now: { time })
        let first = try XCTUnwrap(scanner.scan())
        let extra = BrowserTestNode("AXTabGroup")
        tree.root.append(extra)
        time = 61
        XCTAssertNil(scanner.scan(), "A new second strip must eventually invalidate the original complete-list assumption")
        tree.root.nodes.removeLast()
        XCTAssertEqual(try XCTUnwrap(scanner.scan()).tabs.map(\.id), first.tabs.map(\.id))
    }
    func testSafariFindsTabsOutsideEmptyTabGroupAndSkipsPageAndSidebar() throws {
        let tree = fixture(.safari)
        let forbidden = BrowserTestNode("AXWebArea")
        let fakeTab = tab("Page radio", selected: true)
        forbidden.append(fakeTab)
        let outline = BrowserTestNode("AXOutline")
        outline.append(tab("Sidebar", selected: true))
        tree.root.append(forbidden)
        tree.root.append(outline)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(forbidden.childReads, 0)
        XCTAssertEqual(forbidden.infoReads, 0)
        XCTAssertEqual(fakeTab.structureReads, 0)
        XCTAssertEqual(outline.childReads, 0)
    }

    func testOnlyAFullReadWithNoTabAtAllSaysAWindowHasNoTabStrip() {
        let root = BrowserTestNode("AXWindow")
        root.append(BrowserTestNode("AXToolbar"))
        root.append(BrowserTestNode("AXGroup"))
        let scanner = BrowserTabScanner(root: root, adapter: .safari, windowId: 1, pid: 2)
        XCTAssertNil(scanner.scan())
        XCTAssertTrue(scanner.foundNoTabStrip, "Such as Safari's Settings, or a lone tab with the tab bar hidden")
        let unknown = BrowserTestNode("AXGroup")
        unknown.unreadable = true
        root.append(unknown)
        XCTAssertNil(scanner.scan())
        XCTAssertFalse(scanner.foundNoTabStrip, "An unreadable branch could hold a tab strip")
        root.nodes.removeLast()
        XCTAssertNil(scanner.scan())
        XCTAssertTrue(scanner.foundNoTabStrip)
        XCTAssertNil(scanner.scan(cancelled: { true }))
        XCTAssertFalse(scanner.foundNoTabStrip, "A scan that stopped early says nothing about the window")
        let tree = fixture(.safari)
        XCTAssertNotNil(tree.scanner.scan())
        XCTAssertFalse(tree.scanner.foundNoTabStrip)
    }

    func testDuplicateTitlesReorderByIdentityAndSelectExactControl() throws {
        let tree = fixture(.chromium)
        tree.tabs.forEach { $0.title = "Duplicate" }
        let first = try XCTUnwrap(tree.scanner.scan())
        XCTAssertNotEqual(first.tabs[0].id, first.tabs[1].id)
        tree.container.nodes.reverse()
        let second = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(second.tabs.map(\.id), first.tabs.reversed().map(\.id))
        XCTAssertTrue(tree.scanner.select(first.tabs[0].target))
        XCTAssertEqual(tree.tabs[0].presses, 1)
        XCTAssertEqual(tree.tabs[1].presses, 0)
    }

    func testIncompleteReadsKeepIdentityButRetiredAndMovedTargetsCannotPress() throws {
        let tree = fixture(.chromium)
        let first = try XCTUnwrap(tree.scanner.scan())
        tree.container.unreadable = true
        XCTAssertNil(tree.scanner.scan())
        tree.container.unreadable = false
        XCTAssertEqual(try XCTUnwrap(tree.scanner.scan()).tabs.map(\.id), first.tabs.map(\.id))
        tree.container.nodes.removeFirst()
        tree.tabs[1].selected = true
        let single = try XCTUnwrap(tree.scanner.scan())
        XCTAssertFalse(single.isGroup)
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target))
        let otherWindow = BrowserTestNode("AXWindow")
        tree.container.owner = otherWindow
        XCTAssertFalse(tree.scanner.select(first.tabs[1].target))
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0])
    }

    func testModeRestartDoesNotReuseIdsAndWrongProcessCannotSelect() throws {
        let tree = fixture(.chromium)
        let first = try XCTUnwrap(tree.scanner.scan())
        let restarted = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45)
        let second = try XCTUnwrap(restarted.scan())
        XCTAssertNotEqual(first.windowSession, second.windowSession)
        XCTAssertTrue(Set(first.tabs.map(\.id)).isDisjoint(with: second.tabs.map(\.id)))
        XCTAssertFalse(restarted.select(first.tabs[0].target))
        let wrong = BrowserTabTarget(windowId: 123, pid: 46, windowSession: first.windowSession, tabId: first.tabs[0].id)
        XCTAssertFalse(tree.scanner.select(wrong))
        tree.tabs[0].supportsPress = false
        XCTAssertFalse(tree.scanner.select(first.tabs[0].target))
    }

    func testAmbiguousSelectionAndNativeGroupsNeverPublishPartialTabList() {
        let tree = fixture(.chromium)
        tree.tabs[0].selected = false
        XCTAssertNil(tree.scanner.scan())
        tree.tabs.forEach { $0.selected = true }
        XCTAssertNil(tree.scanner.scan())
        tree.tabs[1].selected = false
        tree.container.append(BrowserTestNode("AXButton"))
        XCTAssertNil(tree.scanner.scan(), "Unrecognized native group headers must not silently lose hidden tabs")
    }

    func testTraversalLimitsAndCancellationReturnNoPartialList() {
        let tree = fixture(.chromium)
        var time = 0.0
        let scanner = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45,
            now: { time += 0.05; return time })
        XCTAssertNil(scanner.scan())
        let cancelled = BrowserTabScanner(root: tree.root, adapter: .chromium, windowId: 123, pid: 45, isCancelled: { true })
        XCTAssertNil(cancelled.scan())
        XCTAssertNil(tree.scanner.scan(cancelled: { true }))
        for _ in 0..<260 { tree.container.append(tab("Extra", selected: false)) }
        XCTAssertNil(tree.scanner.scan())
    }

    func testCacheExpiresAndRemovesOwnersWithoutChangingCompleteSnapshots() throws {
        let snapshot = try XCTUnwrap(fixture(.chromium).scanner.scan())
        var cache = BrowserTabSnapshotCache()
        cache.receive(snapshot, now: 1)
        cache.recordFailure(windowId: 123, now: 2)
        cache.reconcile(owners: [123: 45], now: 8)
        XCTAssertEqual(cache.snapshots[123], snapshot)
        cache.reconcile(owners: [123: 45], now: 12)
        XCTAssertTrue(cache.snapshots.isEmpty)
        cache.receive(snapshot, now: 13)
        cache.reconcile(owners: [123: 99], now: 13)
        XCTAssertTrue(cache.snapshots.isEmpty, "A recycled window ID in a new process is not the old owner")
        cache.receive(snapshot, now: 20)
        cache.reconcile(owners: [123: 45], now: 81)
        XCTAssertEqual(cache.snapshots[123], snapshot, "Hidden panels keep stable geometry until an actual failed read or owner retirement")
    }

    @MainActor
    func testSettingsDefaultToBrowserTabsWithIconsOptIn() {
        let (parsed, errors) = parseConfig("""
            [workspace-sidebar]
            mode = 'tabs'
            browser-tabs = false
            browser-tab-icons = true
            """)
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertFalse(parsed.workspaceSidebar.browserTabs)
        XCTAssertTrue(parsed.workspaceSidebar.browserTabIcons)
        XCTAssertTrue(defaultConfig.workspaceSidebar.browserTabs)
        XCTAssertFalse(defaultConfig.workspaceSidebar.browserTabIcons)
        XCTAssertEqual(SettingsCatalog.field("workspace-sidebar.browser-tabs").title, "Show browser tabs")
    }

    @MainActor
    func testBrowserSelectionKeepsTheDisplayTakeoverGuard() {
        setUpWorkspacesForTests()
        defer { setMonitorsForTests(nil); config = defaultConfig }
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let workspace = Workspace.get(byName: "browser")
        _ = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(right.setActiveWorkspace(workspace))
        XCTAssertFalse(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: left)))
        XCTAssertTrue(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: right)))
        XCTAssertFalse(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: "missing-display"))
        XCTAssertTrue(right.setActiveWorkspace(Workspace.get(byName: "other")))
        XCTAssertTrue(browserTabSelectionAllowed(workspace: workspace, monitorScopeId: workspaceSidebarMonitorScopeId(for: left)))
    }

    @MainActor
    func testBrowserGroupAndSplitRenderWithoutChangingWindowIdentity() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Google Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: "/Applications/Google Chrome.app", title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Research notes", isFocused: false)
        for split in [false, true] {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.expandedWidth = 280
            snapshot.configuration.collapsedWidth = 44
            snapshot.visibleWidth = 280
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
            let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
                displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
                isFocused: true, isVisible: true, items: (split ? [chrome, notes] : [chrome]).map { .init(kind: .window($0)) })
            snapshot.workspaces = [workspace]
            let model = BrowserTabsModel(snapshots: [123: browser])
            let view = WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true,
                reduceTransparencyOverride: true, browserTabsModel: model)
            let host = NSHostingView(rootView: view.frame(width: 280, height: 480).environment(\.colorScheme, .light))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let recognize = VNRecognizeTextRequest()
            recognize.recognitionLevel = .accurate
            recognize.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([recognize])
            let renderedText = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(renderedText.contains("Alpha"), renderedText)
            XCTAssertTrue(renderedText.contains("Beta"), renderedText)
            XCTAssertTrue(renderedText.contains("Chrome"), renderedText)
            let directory = projectRoot.appendingPathComponent(".build/browser-tabs-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(split ? "split.png" : "single.png"))
            XCTAssertEqual(host.fittingSize.width, 280, accuracy: 0.5)
            XCTAssertEqual(workspaceSidebarPinnedTabWindows(workspace).count, split ? 2 : 1)
        }
    }

    /// Hosts a Tabs sidebar the way its panel does: the same view, given each new snapshot.
    @MainActor
    private final class BrowserWatchSidebar {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let model: BrowserTabsModel

        init(model: BrowserTabsModel) {
            self.model = model
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
        }

        func show(_ windows: [WorkspaceSidebarWindowViewModel], width: CGFloat = 280, scope: String = "monitor:0.0,0.0") {
            var snapshot = WorkspaceSidebarSnapshot.empty
            snapshot.configuration.usesTabsList = true
            snapshot.configuration.expandedWidth = 280
            snapshot.configuration.collapsedWidth = 44
            snapshot.visibleWidth = width
            snapshot.targetMonitorScopeId = scope
            snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
            snapshot.workspaces = windows.map { window in
                WorkspaceSidebarWorkspaceViewModel(name: window.workspaceName, projectId: workspaceProjectDefaultId,
                    displayName: window.workspaceName, sidebarLabel: "", isGeneratedName: true, monitorScopeId: scope,
                    monitorName: nil, isFocused: window.isFocused, isVisible: window.isFocused, items: [.init(kind: .window(window))])
            }
            host.rootView = AnyView(WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true,
                reduceTransparencyOverride: true, browserTabsModel: model).frame(width: 280, height: 480))
            host.layoutSubtreeIfNeeded()
        }

        func hide() {
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
        }
    }

    private func browserWindow(_ id: UInt32, workspace: String, focused: Bool = false) -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: workspace, appName: "Google Chrome", appBundleId: "com.google.Chrome",
            appBundlePath: nil, title: "Page \(id)", isFocused: focused)
    }

    /// SwiftUI applies a new root view on its next pass. Let it run first, even when the watch
    /// shouldn't change, then wait for the expected watch rather than a fixed time.
    @MainActor
    private func assertWatch(_ model: BrowserTabsModel, _ expected: Set<UInt32>, _ message: String, line: UInt = #line) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let deadline = Date(timeIntervalSinceNow: 2)
        while model.watchedWindowIds != expected, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(model.watchedWindowIds, expected, message, line: line)
    }

    @MainActor
    func testTheSidebarReadsTheBrowserWindowsItShowsAfterEachSnapshot() {
        // Each change must be read from the new snapshot, not the view before it: a watch one change
        // behind never read a window after launch, or one that joined a project later.
        let model = BrowserTabsModel()
        let sidebar = BrowserWatchSidebar(model: model)
        let a = browserWindow(83, workspace: "1", focused: true)
        let b = browserWindow(67, workspace: "2")
        sidebar.show([], width: 0)
        assertWatch(model, [], "A panel first appears empty")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "The first real snapshot's windows are read")
        sidebar.show([a])
        assertWatch(model, [83], "A window that leaves the sidebar stops being read at once")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "A window that joins the project is read")
        sidebar.show([browserWindow(83, workspace: "1"), browserWindow(67, workspace: "2", focused: true)])
        assertWatch(model, [83, 67], "Focusing the other window changes nothing read")
        sidebar.show([a, b], width: 44)
        assertWatch(model, [], "The collapsed rail shows no browser tabs, so it reads none")
        sidebar.show([a, b])
        assertWatch(model, [83, 67], "Expanding it again reads them again")
        sidebar.hide()
        assertWatch(model, [], "A sidebar that goes away stops its reads")
        sidebar.show([a])
        assertWatch(model, [83], "One that appears with windows reads them at once")
    }

    @MainActor
    func testEachDisplaysSidebarKeepsItsOwnReadsWhenOneMovesOrGoes() {
        let model = BrowserTabsModel()
        let left = BrowserWatchSidebar(model: model)
        let right = BrowserWatchSidebar(model: model)
        left.show([browserWindow(83, workspace: "1", focused: true)], scope: "monitor:0.0,0.0")
        right.show([browserWindow(67, workspace: "2", focused: true)], scope: "monitor:1920.0,0.0")
        assertWatch(model, [83, 67], "Both sidebars' windows are read")
        // The left panel now describes another display with the same windows...
        left.show([browserWindow(83, workspace: "1", focused: true)], scope: "monitor:0.0,1080.0")
        assertWatch(model, [83, 67], "Moving keeps its windows read")
        // ...and its old display's reads are gone, not left behind to keep a window read.
        left.show([], scope: "monitor:0.0,1080.0")
        assertWatch(model, [67], "Only the new display's reads remained to clear")
        right.hide()
        assertWatch(model, [], "The other sidebar's reads end with it")
    }

    func testTitlesOnlyRemoveKnownDiagnosticSuffixes() {
        XCTAssertEqual(browserTabDisplayTitle("Design - API - Memory usage - 64 MB"), "Design - API")
        XCTAssertEqual(browserTabDisplayTitle("项目 - 内存用量 - 64 MB"), "项目")
        XCTAssertEqual(browserTabDisplayTitle("Design - API"), "Design - API")
        XCTAssertEqual(browserTabDisplayTitle(""), "Untitled tab")
        XCTAssertNil(BrowserTabAdapter(bundleId: "company.thebrowser.Browser"))
        XCTAssertNotNil(BrowserTabAdapter(bundleId: "com.microsoft.edgemac"))
    }

    @MainActor
    func testSearchKeyboardAndScrollTargetUseTheSameBrowserChild() throws {
        let snapshot = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let window = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .window(window))])
        let browsers = [window.id: snapshot]
        let results = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Beta", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(results.map(\.name), ["1"])
        let choices = workspaceSidebarSearchSelections(workspaces: results, browserTabs: browsers, query: "Beta")
        XCTAssertEqual(choices, [.browserTab(snapshot.tabs[1].target)])
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: results, searchSelection: choices.first)?.rowId,
            snapshot.tabs[1].target.rowId)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: results), [.window(123)], "Other modes use only windows")
        XCTAssertEqual(workspaceSidebarTabPresentation(workspace), .single(window), "The layout still owns exactly one window")
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: "Alpha"),
            [.browserTab(snapshot.tabs[0].target)], "The active window title must not match every sibling tab")
        for headerQuery in ["Chrome", "1"] {
            XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: headerQuery).first,
                .window(123), "Matching an app or workspace focuses its window without switching to its first browser tab")
        }
        let projects = [WorkspaceSidebarProjectViewModel(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil)]
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers, query: "Research", projects: projects).first,
            .window(123))
    }

    @MainActor
    func testSplitSearchOrderFollowsHeadersThenBrowserChildren() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Notes", isFocused: false)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "Research", sidebarLabel: "Research", isGeneratedName: false, monitorScopeId: "monitor:0,0",
            monitorName: nil, isFocused: true, isVisible: true, items: [chrome, notes].map { .init(kind: .window($0)) })
        let browsers: [UInt32: BrowserWindowTabs] = [123: browser]
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers),
            [.window(123), .window(124)] + browser.tabs.map { .browserTab($0.target) })
        let results = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Research Beta", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: results, browserTabs: browsers, query: "Research Beta"),
            [.browserTab(browser.tabs[1].target)], "Only the matching child remains when the other split half does not match")
        let otherSession = UUID()
        let otherBrowser = BrowserWindowTabs(windowId: 124, pid: 45, windowSession: otherSession,
            tabs: browser.tabs.map { .init(target: .init(windowId: 124, pid: 45, windowSession: otherSession, tabId: UUID()),
                title: $0.title, isSelected: $0.isSelected) })
        let otherChrome = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: false)
        let pair = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "Research", sidebarLabel: "Research", isGeneratedName: false, monitorScopeId: "monitor:0,0",
            monitorName: nil, isFocused: true, isVisible: true, items: [chrome, otherChrome].map { .init(kind: .window($0)) })
        let pairBrowsers = [UInt32(123): browser, UInt32(124): otherBrowser]
        let pairResults = workspaceSidebarFilteredWorkspacesByProject([pair.projectId: [pair]], projects: [],
            query: "Beta", browserTabs: pairBrowsers)[pair.projectId] ?? []
        XCTAssertEqual(workspaceSidebarTabPresentation(try XCTUnwrap(pairResults.first)), .split(chrome, otherChrome))
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: pairResults, browserTabs: pairBrowsers, query: "Beta"),
            [.browserTab(browser.tabs[1].target), .browserTab(otherBrowser.tabs[1].target)],
            "A specific tab match must reach that tab when both browser halves remain in the split")
        XCTAssertEqual(Array(workspaceSidebarSearchSelections(workspaces: [pair], browserTabs: pairBrowsers, query: "Chrome").prefix(2)),
            [.window(123), .window(124)])
    }

    @MainActor
    func testLegacyFolderSearchAndScrollNeverTargetUndisplayedBrowserChildren() throws {
        let browser = try XCTUnwrap(fixture(.chromium).scanner.scan())
        let chrome = WorkspaceSidebarWindowViewModel(windowId: 123, workspaceName: "1", appName: "Chrome",
            appBundleId: "com.google.Chrome", appBundlePath: nil, title: "Alpha", isFocused: true)
        let notes = WorkspaceSidebarWindowViewModel(windowId: 124, workspaceName: "1", appName: "Notes",
            appBundleId: "com.apple.Notes", appBundlePath: nil, title: "Notes", isFocused: false)
        let stack = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 124, workspaceName: "1", title: "Stack",
            windowCount: 1, isFocused: false, tabs: [notes], allWindows: [notes])
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId,
            displayName: "1", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil,
            isFocused: true, isVisible: true, items: [.init(kind: .window(chrome)), .init(kind: .tabGroup(stack))])
        let browsers: [UInt32: BrowserWindowTabs] = [123: browser]
        XCTAssertEqual(workspaceSidebarTabPresentation(workspace), .folder)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace], browserTabs: browsers), [.window(123), .window(124)])
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: [workspace], searchSelection: nil, browserTabs: browsers)?.rowId, "window:123")
        XCTAssertEqual(workspaceSidebarTabScrollTarget(folders: [workspace], searchSelection: .browserTab(browser.tabs[0].target),
            browserTabs: browsers)?.rowId, "window:123")
        XCTAssertTrue((workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Beta", browserTabs: browsers)[workspace.projectId] ?? []).isEmpty)
        let appMatches = workspaceSidebarFilteredWorkspacesByProject([workspace.projectId: [workspace]], projects: [],
            query: "Chrome", browserTabs: browsers)[workspace.projectId] ?? []
        XCTAssertEqual(workspaceSidebarTabPresentation(try XCTUnwrap(appMatches.first)), .folder)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: appMatches, browserTabs: browsers, query: "Chrome"), [.window(123)],
            "Filtering a legacy folder cannot reveal previously unsearchable browser children")
    }

    func testClosingATabPressesOnlyThatTabsOwnCloseButtonAndNeverSelectsIt() throws {
        let tree = fixture(.chromium)
        let closeAlpha = BrowserTestNode("AXButton", subrole: "AXCloseButton")
        tree.tabs[0].append(BrowserTestNode("AXButton"))
        tree.tabs[0].append(closeAlpha)
        let closeBeta = BrowserTestNode("AXButton")
        tree.tabs[1].append(BrowserTestNode("AXStaticText"))
        tree.tabs[1].append(closeBeta)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertEqual(snapshot.tabs.count, 2, "A tab's own controls aren't tabs")
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target), "A tab's only button is its close button")
        XCTAssertEqual(closeBeta.presses, 1)
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[0].target), "Among several buttons, the close button")
        XCTAssertEqual(closeAlpha.presses, 1)
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Closing never selects the tab")
    }

    func testSafarisHiddenCloseButtonIsReachedThroughItsUnlocalizedCloseAction() throws {
        let tree = fixture(.safari)
        let close = "Name:关闭标签页\nTarget:0x7801b6d500\nSelector:_closeButtonClicked:"
        tree.tabs[1].actions = ["AXScrollToVisible", "AXShowMenu", "AXPress", close]
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertTrue(tree.scanner.close(snapshot.tabs[1].target), "Found by selector, whatever the language")
        XCTAssertEqual(tree.tabs[1].performed, [close])
        XCTAssertEqual(tree.tabs.map(\.presses), [0, 0], "Not the tab's press, which would select it")
        tree.tabs[0].actions = ["AXPress", "Name:Other\nTarget:0x1\nSelector:_otherAction:"]
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "Another named action isn't a close")
        XCTAssertEqual(tree.tabs[0].performed, [])
    }

    func testATabWithoutAnUnambiguousCloseControlOrThatMovedIsLeftOpen() throws {
        let tree = fixture(.safari)
        let first = BrowserTestNode("AXButton"), second = BrowserTestNode("AXButton")
        tree.tabs[1].append(first)
        tree.tabs[1].append(second)
        let snapshot = try XCTUnwrap(tree.scanner.scan())
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "No close button")
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[1].target), "Two unnamed buttons: guessing could do something else")
        XCTAssertEqual(first.presses + second.presses, 0)
        tree.container.nodes.removeFirst()
        XCTAssertFalse(tree.scanner.close(snapshot.tabs[0].target), "A tab that's gone")
    }

    func testAClosedTabLeavesTheListBeforeTheNextRead() {
        var cache = BrowserTabSnapshotCache()
        let session = UUID()
        let tabs = (0..<3).map { index in
            BrowserTab(target: .init(windowId: 1, pid: 2, windowSession: session, tabId: UUID()), title: "\(index)",
                isSelected: index == 0)
        }
        cache.receive(.init(windowId: 1, pid: 2, windowSession: session, tabs: tabs), now: 0)
        cache.removeTab(tabs[1].target)
        XCTAssertEqual(cache.snapshots[1]?.tabs.map(\.title), ["0", "2"])
        cache.removeTab(.init(windowId: 1, pid: 2, windowSession: UUID(), tabId: tabs[0].target.tabId))
        XCTAssertEqual(cache.snapshots[1]?.tabs.count, 2, "A target from an earlier scan of the window is ignored")
    }

    private func fixture(_ adapter: BrowserTabAdapter) -> (root: BrowserTestNode, container: BrowserTestNode,
        tabs: [BrowserTestNode], scanner: BrowserTabScanner<BrowserTestNode>) {
        let root = BrowserTestNode("AXWindow")
        let container = BrowserTestNode(adapter == .safari ? "AXOpaqueProviderGroup" : "AXTabGroup")
        if adapter == .safari { root.append(BrowserTestNode("AXTabGroup")) }
        root.append(container)
        let tabs = [tab("Alpha", selected: true), tab("Beta", selected: false)]
        for tab in tabs { container.append(tab) }
        return (root, container, tabs, BrowserTabScanner(root: root, adapter: adapter, windowId: 123, pid: 45))
    }

    private func tab(_ title: String, selected: Bool) -> BrowserTestNode {
        let node = BrowserTestNode("AXRadioButton", subrole: "AXTabButton")
        node.title = title
        node.selected = selected
        return node
    }
}

private final class BrowserTestNode: BrowserTabAXNode {
    static func == (lhs: BrowserTestNode, rhs: BrowserTestNode) -> Bool { lhs === rhs }
    let role: String
    let subrole: String
    var title = ""
    var selected = false
    var unreadable = false
    var supportsPress = true
    var presses = 0
    var structureReads = 0
    var childReads = 0
    var infoReads = 0
    var onInfoRead: () -> Void = {}
    var nodes: [BrowserTestNode] = []
    weak var ancestor: BrowserTestNode?
    weak var owner: BrowserTestNode?

    init(_ role: String, subrole: String = "") { self.role = role; self.subrole = subrole }
    func append(_ child: BrowserTestNode) {
        child.ancestor = self
        child.owner = role == "AXWindow" ? self : owner
        nodes.append(child)
    }
    func structure() -> BrowserTabAXStructure? {
        structureReads += 1
        return unreadable ? nil : .init(role: role, subrole: subrole)
    }
    func children() -> [BrowserTestNode]? { childReads += 1; return unreadable ? nil : nodes }
    func parent() -> BrowserTestNode? { ancestor }
    func window() -> BrowserTestNode? { owner }
    func tabInfo() -> BrowserTabAXInfo? { infoReads += 1; onInfoRead(); return unreadable ? nil : .init(title: title, selected: selected) }
    func press() -> Bool { if supportsPress { presses += 1 }; return supportsPress }
    var actions: [String] = []
    var performed: [String] = []
    func actionNames() -> [String] { actions }
    func perform(_ action: String) -> Bool { performed.append(action); return actions.contains(action) }
}
