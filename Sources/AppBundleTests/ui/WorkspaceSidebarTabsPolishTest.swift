import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarTabsPolishTest: XCTestCase {
    override func tearDown() async throws {
        config = defaultConfig
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        try await super.tearDown()
    }

    func testPinnedSplitPreservesWindowOrderIncludingTwoWindowsOfTheSameApp() {
        let workspace = workspace("pair", windows: [window(2), window(1)])
        XCTAssertEqual(workspaceSidebarPinnedTabWindows(workspace).map(\.windowId), [2, 1])
        XCTAssertEqual(WorkspaceSidebarPinnedGridLayout(workspaces: [workspace, workspace], width: 260).columns, 2)
        let narrow = WorkspaceSidebarPinnedGridLayout(workspaces: [workspace, workspace], width: 140)
        XCTAssertEqual(narrow.columns, 1)
        XCTAssertEqual(narrow.height, 116, "A pair takes a whole tile at narrow widths")
        XCTAssertEqual(WorkspaceSidebarPinnedGridLayout(workspaces: [], width: 260).height, 0)
    }

    func testPinnedAnimationIgnoresTitleAndFocusChangesButTracksMembership() {
        let original = workspace("pair", windows: [window(1), window(2)])
        var changed = workspace("pair", windows: [.init(windowId: 1, workspaceName: "pair", appName: "Safari",
            appBundleId: nil, appBundlePath: nil, title: "Updated title", isFocused: false), window(2)])
        changed.isFocused.toggle()
        XCTAssertEqual(WorkspaceSidebarPinnedTabIdentity(original), WorkspaceSidebarPinnedTabIdentity(changed))
        XCTAssertNotEqual(WorkspaceSidebarPinnedTabIdentity(original),
            WorkspaceSidebarPinnedTabIdentity(workspace("pair", windows: [window(1)])))
    }

    func testActiveGroupOnAnotherDisplayDoesNotLockThisSidebar() throws {
        setUpWorkspacesForTests()
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let rightWorkspace = Workspace.get(byName: "right")
        _ = TestWindow.new(id: 1, parent: rightWorkspace.rootTilingContainer)
        XCTAssertTrue(right.setActiveWorkspace(rightWorkspace))
        let group = try workspaceSidebarOrganizationStore.create(projectId: rightWorkspace.projectId, workspaceNames: [rightWorkspace.name])
        let leftScope = workspaceSidebarMonitorScopeId(for: left)
        let rightScope = workspaceSidebarMonitorScopeId(for: right)
        XCTAssertFalse(group.containsVisibleWorkspace(on: leftScope))
        XCTAssertTrue(group.containsVisibleWorkspace(on: rightScope))
        XCTAssertEqual(workspaceSidebarIdentityMenuModel(.collection(group.id), targetMonitorScopeId: leftScope)?.entries.first?.enabled, true)
        XCTAssertEqual(workspaceSidebarIdentityMenuModel(.collection(group.id), targetMonitorScopeId: rightScope)?.entries.first?.enabled, false)
        XCTAssertEqual(workspaceSidebarIdentityMenuModel(.collection(group.id, monitorScopeId: leftScope),
            targetMonitorScopeId: rightScope)?.entries.first?.enabled, true,
            "A keyboard menu stays on its sidebar's display even when the pointer is on the other display")
        try toggleWorkspaceSidebarTabCollection(group.id, monitorScopeId: rightScope)
        XCTAssertFalse(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }).isCollapsed)
        try toggleWorkspaceSidebarTabCollection(group.id, monitorScopeId: leftScope)
        XCTAssertTrue(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }).isCollapsed)
    }

    func testSelectingSplitMemberPlacesTheWorkspaceOnTheClickedDisplay() {
        setUpWorkspacesForTests()
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT")
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        let target = Workspace.get(byName: "split")
        _ = TestWindow.new(id: 1, parent: target.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: target.rootTilingContainer)
        XCTAssertTrue(right.setActiveWorkspace(target))
        let leftScope = workspaceSidebarMonitorScopeId(for: left)
        XCTAssertFalse(focusWindowFromSidebar(second, targetMonitorScopeId: leftScope), "A visible workspace needs explicit takeover")
        XCTAssertTrue(right.setActiveWorkspace(Workspace.get(byName: "other")))
        XCTAssertTrue(focusWindowFromSidebar(second, targetMonitorScopeId: leftScope))
        XCTAssertEqual(target.workspaceMonitor.rect, left.rect)
        XCTAssertTrue(focus.windowOrNil === second)
        XCTAssertTrue(TestApp.shared.focusedWindow === second)
    }

    func testGroupMenuUsesTheSelectedCreateDestinationAndKeepsItsOwnDisplayForDisclosure() throws {
        setUpWorkspacesForTests()
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspaceProjectDefaultId, workspaceNames: [])
        let left = "monitor:0.0,0.0"
        let right = "monitor:1920.0,0.0"
        var sent: [WorkspaceSidebarAction] = []
        var scopes: [String?] = []
        let menu = try XCTUnwrap(workspaceSidebarIdentityMenuModel(
            .collection(group.id, monitorScopeId: left, createMonitorScopeId: right), targetMonitorScopeId: right,
            sendAction: { sent.append($0); scopes.append($1) }))
        try XCTUnwrap(menu.entries.first { $0.title == "Collapse Group" }?.perform)()
        try XCTUnwrap(menu.entries.first { $0.title == "New Tab in Group" }?.perform)()
        XCTAssertEqual(sent, [.toggleTabCollection(group.id), .createTabInCollection(group.id, monitorScopeId: right)])
        XCTAssertEqual(scopes, [left, left], "Actions retain their origin while creation carries the selected destination")
    }

    func testActiveGroupStaysFullyExpandedAndCollapseDoesNotChangeItsSavedState() throws {
        setUpWorkspacesForTests()
        let active = focus.workspace
        _ = TestWindow.new(id: 1, parent: active.rootTilingContainer)
        let inactive = Workspace.get(byName: "inactive")
        _ = TestWindow.new(id: 2, parent: inactive.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: active.projectId,
            workspaceNames: [active.name, inactive.name])
        XCTAssertTrue(group.containsVisibleWorkspace())
        let activeMenu = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.collection(group.id)))
        XCTAssertEqual(activeMenu.entries.first?.title, "Collapse Group")
        XCTAssertEqual(activeMenu.entries.first?.enabled, false)
        try toggleWorkspaceSidebarTabCollection(group.id)
        XCTAssertFalse(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }).isCollapsed)

        var saved = group
        saved.isCollapsed = true
        let activeDisclosure = WorkspaceSidebarTabCollectionDisclosure(group: saved, containsActiveTab: true)
        XCTAssertFalse(activeDisclosure.isCollapsed, "Saved collapse cannot leave a sideways arrow beside an active group")
        XCTAssertFalse(activeDisclosure.canToggle)
        let inactiveDisclosure = WorkspaceSidebarTabCollectionDisclosure(group: saved, containsActiveTab: false)
        XCTAssertTrue(inactiveDisclosure.isCollapsed)
        XCTAssertTrue(inactiveDisclosure.canToggle)
        let searching = WorkspaceSidebarTabCollectionDisclosure(group: saved, containsActiveTab: false, isSearching: true)
        XCTAssertFalse(searching.isCollapsed)
        XCTAssertFalse(searching.canToggle, "Search-expanded rows and arrow must agree too")

        XCTAssertTrue(Workspace.get(byName: "outside").focusWorkspace())
        XCTAssertFalse(group.containsVisibleWorkspace())
        try toggleWorkspaceSidebarTabCollection(group.id)
        XCTAssertTrue(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }).isCollapsed)
        let inactiveMenu = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.collection(group.id)))
        XCTAssertEqual(inactiveMenu.entries.first?.title, "Expand Group")
        XCTAssertEqual(inactiveMenu.entries.first?.enabled, true)
        let searchMenu = try XCTUnwrap(workspaceSidebarIdentityMenuModel(.collection(group.id, isSearching: true)))
        XCTAssertEqual(searchMenu.entries.first?.title, "Collapse Group", "Search shows an expanded group, including in its menu")
        XCTAssertEqual(searchMenu.entries.first?.enabled, false, "Search must not change the saved disclosure state")
        try toggleWorkspaceSidebarTabCollection(group.id)
        XCTAssertFalse(try XCTUnwrap(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }).isCollapsed)
    }

    func testEveryPinnedSplitButtonSelectsItsOwnWindow() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        var selected: [UInt32?] = []
        let content = WorkspaceSidebarPinnedTab(workspace: workspace("pair", windows: [window(1), window(2)]),
            badgeModel: WorkspaceSidebarDockBadgeModel()) { selected.append($0) }
            .frame(width: 160, height: 54)
        let host = NSHostingView(rootView: content)
        let native = NSWindow(contentRect: CGRect(x: 300, y: 200, width: 160, height: 54),
            styleMask: [.borderless], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.orderFrontRegardless()
        defer { native.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        native.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for (index, x) in [CGFloat(40), 120].enumerated() {
            let point = host.convert(CGPoint(x: x, y: 27), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: false)
            }
            let deadline = Date().addingTimeInterval(2)
            while selected.count < index + 1, let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: deadline,
                inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        XCTAssertEqual(selected, [1, 2], "Each half activates its own window without also selecting its sibling")
    }

    func testActiveCollectionRendersEveryMemberDespiteASavedCollapsedPreference() async throws {
        for (active, otherDisplay, sentinel) in [(true, false, false), (false, false, false), (true, true, false), (true, false, true)] {
            var snapshot = fixture(width: 280)
            snapshot.visibleWidth = 280
            if sentinel { snapshot.targetMonitorScopeId = workspaceSidebarDefaultScopeId }
            snapshot.configuration.tabCollections[0].isCollapsed = true
            snapshot.workspaces[2] = workspace("Single", windows: [window(4)],
                scope: otherDisplay ? "monitor:1920,0" : "monitor:0,0")
            snapshot.workspaces[2].isVisible = active
            var targets: [WorkspaceSidebarDropTargetFrame] = []
            let view = WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { targets = $0 }),
                reduceMotionOverride: true, reduceTransparencyOverride: true)
            let host = NSHostingView(rootView: view.frame(width: 280, height: 620))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<200 where targets.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(targets.contains { $0.kind == .tabCollection(snapshot.configuration.tabCollections[0].id) })
            for name in ["Single", "Split"] {
                XCTAssertEqual(targets.contains { $0.kind == .workspace(name) }, active && !otherDisplay,
                    "An active group stays fully open; an inactive collapsed group hides every member")
            }
        }
    }

    func testBadgePollingAndSettingAreAvailableInTabsButRemainOptIn() {
        var sidebar = WorkspaceSidebarConfig(mode: .tabs)
        XCTAssertFalse(workspaceSidebarNeedsDockBadgePolling(sidebar))
        sidebar.showAppBadges = true
        XCTAssertTrue(workspaceSidebarNeedsDockBadgePolling(sidebar))
        sidebar.mode = .sidebar
        XCTAssertFalse(workspaceSidebarNeedsDockBadgePolling(sidebar))
        sidebar.mode = .dock
        XCTAssertTrue(workspaceSidebarNeedsDockBadgePolling(sidebar))
        sidebar.showAppBadges = false
        sidebar.showHiddenWorkspaceAppReminders = true
        XCTAssertTrue(workspaceSidebarNeedsDockBadgePolling(sidebar))
        sidebar.mode = .tabs
        XCTAssertFalse(workspaceSidebarNeedsDockBadgePolling(sidebar), "Dock reminders alone must not poll in Tabs")

        let field = SettingsCatalog.field("workspace-sidebar.show-app-badges")
        for mode in ["tabs", "dock", "sidebar"] {
            let editor = SettingsEditor(configuration: defaultConfig)
            editor.setDraft(.text(mode), for: SettingsCatalog.field("workspace-sidebar.mode"))
            XCTAssertEqual(field.visible(editor), mode != "sidebar")
        }
    }

    func testLiveBadgeAppearsAtTheRightOfTheTabAndDisappearsWhenDisabled() async throws {
        let reader = TabsPolishBadgeReader()
        let model = WorkspaceSidebarDockBadgeModel(read: { await reader.next() })
        defer { model.setEnabled(false) }
        let row = WorkspaceSidebarTabRowView(window: window(1), indent: 0, isSearchSelected: false,
            isDragSource: false, actions: .init(), onSelect: {}, badgeModel: model)
        let host = NSHostingView(rootView: row.frame(width: 180, height: 36).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 36)
        XCTAssertEqual(try redPixels(host).count, 0)
        model.setEnabled(true)
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(30))
        let red = try redPixels(host)
        XCTAssertGreaterThan(red.count, 20)
        XCTAssertTrue(red.allSatisfy { $0.x >= host.bounds.width - workspaceSidebarTabCloseSlotWidth - 34 &&
            $0.x < host.bounds.width - workspaceSidebarTabCloseSlotWidth },
            "Badge stays beside the separate close slot")
        let before = try render(host).representation(using: .png, properties: [:])
        for _ in 0..<600 where model.snapshot.label(forPath: "/Applications/Test.app") != "7" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.snapshot.label(forPath: "/Applications/Test.app"), "7")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotEqual(try render(host).representation(using: .png, properties: [:]), before,
            "Count-only updates repaint a mounted tab without rebuilding the sidebar snapshot")
        model.setEnabled(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try redPixels(host).count, 0, "Disabling badges updates an already mounted tab")
    }

    func testPanelBottomMatchesTilingOnOffsetDisplaysWithDockAndOuterGaps() throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
        for y: CGFloat in [-1080, 0, 250] {
            for gap in [0, 8, 24] {
                config.gaps.outer.bottom = .constant(gap)
                let monitor = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Display",
                    rect: Rect(topLeftX: -1920, topLeftY: y, width: 1920, height: 1080),
                    visibleRect: Rect(topLeftX: -1920, topLeftY: y + 24, width: 1920, height: 1000), isMain: true)
                let inset = monitor.rect.maxY - monitor.standardTilingRect.maxY
                XCTAssertEqual(inset, CGFloat(56 + gap + 1))
                let screen = CGRect(x: -1920, y: 1080 - monitor.rect.maxY, width: 1920, height: 1080)
                let panel = try XCTUnwrap(workspaceSidebarPanelLayout(screenFrame: screen,
                    sidebarConfig: config.workspaceSidebar, tabsBottomInset: inset))
                XCTAssertEqual(panel.frame.minY, 1080 - monitor.standardTilingRect.maxY)
                XCTAssertEqual(panel.frame.maxY, screen.maxY - CGFloat(config.workspaceSidebar.menuBarReserveHeight))
                XCTAssertFalse(panel.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.minY - 1)))
                config.workspaceSidebar.mode = .dock
                XCTAssertEqual(workspaceSidebarPanelLayout(screenFrame: screen, sidebarConfig: config.workspaceSidebar,
                    tabsBottomInset: inset)?.frame.minY, screen.minY, "Dock geometry stays unchanged")
                config.workspaceSidebar.mode = .tabs
            }
        }
    }

    func testCompactBadgeIsASmallRoundDot() async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: ["/Applications/Test.app": "12"]) })
        model.setEnabled(true)
        defer { model.setEnabled(false) }
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        let host = NSHostingView(rootView: WorkspaceSidebarTabBadge(appName: "Test", bundlePath: "/Applications/Test.app",
            model: model, compact: true).frame(width: 20, height: 34))
        host.frame = CGRect(x: 0, y: 0, width: 20, height: 34)
        let pixels = try redPixels(host)
        let width = try XCTUnwrap(pixels.map(\.x).max()) - XCTUnwrap(pixels.map(\.x).min())
        let height = try XCTUnwrap(pixels.map(\.y).max()) - XCTUnwrap(pixels.map(\.y).min())
        XCTAssertGreaterThan(width, 4)
        XCTAssertLessThanOrEqual(width, 6)
        XCTAssertEqual(width, height, accuracy: 0.5)
    }

    func testSidebarAndRealLayoutShareTheBottomAfterGapAndWidthChanges() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.enabled = true
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        for (width, gap) in [(180, 0), (280, 24), (220, 8)] {
            config.workspaceSidebar.width = width
            config.gaps.outer.bottom = .constant(gap)
            try await workspace.layoutWorkspace()
            let monitor = workspace.workspaceMonitor
            XCTAssertEqual(monitor.workspaceSidebarInset, CGFloat(width), "Live width reserves actual horizontal space")
            let inset = monitor.rect.maxY - monitor.standardTilingRect.maxY
            let panel = try XCTUnwrap(workspaceSidebarPanelLayout(
                screenFrame: CGRect(x: 0, y: 0, width: monitor.width, height: monitor.height),
                sidebarConfig: config.workspaceSidebar, tabsBottomInset: inset))
            for window in [first, second] {
                let rect = try XCTUnwrap(window.lastAppliedLayoutPhysicalRect)
                XCTAssertEqual(panel.frame.minY, monitor.rect.maxY - rect.maxY,
                    "The panel follows the actual split layout after live settings changes")
            }
        }
    }

    func testNativePanelLayoutUsesTheMonitorsFinalBottomBoundary() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        setUpWorkspacesForTests()
        config.workspaceSidebar = .init(enabled: true, mode: .tabs)
        config.gaps.outer.bottom = .constant(24)
        let wasEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        defer { TrayMenuModel.shared.isEnabled = wasEnabled }
        let monitor = mainMonitor
        let screen = try XCTUnwrap(NSScreen.screens.getOrNil(atIndex: monitor.monitorAppKitNsScreenScreensId - 1))
        let layout = try XCTUnwrap(WorkspaceSidebarPanel.shared.currentSidebarPanelLayout(on: monitor))
        XCTAssertEqual(layout.frame.minY, screen.frame.minY + monitor.rect.maxY - monitor.standardTilingRect.maxY)
        XCTAssertGreaterThanOrEqual(layout.frame.minY - screen.frame.minY, 25)
    }

    func testTabsWithPinnedSplitsBadgesAndProjectFooterRenderAtExpandedAndCompactWidths() async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: {
            .init(labelsByPath: ["/Applications/Test.app": "12", "/Applications/Other.app": "•"])
        })
        model.setEnabled(true)
        defer { model.setEnabled(false) }
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        for width: CGFloat in [180, 280, 44] {
            var snapshot = fixture(width: width == 44 ? 280 : width)
            snapshot.visibleWidth = width
            let view = WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: false,
                reduceTransparencyOverride: true, dockBadgeModel: model)
            let host = NSHostingView(rootView: view.frame(width: width, height: 620).environment(\.colorScheme, .light))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 620)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let bitmap = try render(host)
            let directory = projectRoot.appendingPathComponent(".build/sidebar-tabs-polish")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("tabs-\(Int(width)).png"))
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5, "Footer and pinned splits fit the sidebar")
            XCTAssertGreaterThan(try redPixels(host).count, 20, "Badges render in the full sidebar at every tested width")
        }
    }

    private func window(_ id: UInt32, other: Bool = false) -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: "pair", appName: other ? "Notes" : "Safari",
            appBundleId: other ? "com.apple.Notes" : "com.apple.Safari",
            appBundlePath: other ? "/Applications/Other.app" : "/Applications/Test.app",
            title: other ? "Design notes" : "A tab with a long title", isFocused: id == 1)
    }

    private func workspace(_ name: String, windows: [WorkspaceSidebarWindowViewModel], pinned: Bool = false,
                           scope: String = "monitor:0,0", label: String = "", emoji: String? = nil) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: label.isEmpty ? name : label, sidebarLabel: label,
            isGeneratedName: false, monitorScopeId: scope, monitorName: nil,
            isFocused: windows.contains(where: \.isFocused), isVisible: windows.contains(where: \.isFocused),
            items: windows.map { .init(kind: .window($0)) }, appearance: .init(emoji: emoji, isFavorite: pinned))
    }

    private func fixture(width: CGFloat) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: width,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid,
            solidChromeColor: .midnight, solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true,
            alwaysExpanded: true)
        snapshot.targetMonitorScopeId = "monitor:0,0"
        snapshot.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: "#7BA3C9", emoji: "🔬"),
            .init(id: "personal", displayName: "Personal", colorHex: "#7DBF8E", emoji: "🏡"),
            .init(id: "design", displayName: "Design", colorHex: "#BF8AAE", emoji: "🎨")]
        snapshot.workspaces = [workspace("Pinned split", windows: [window(1), window(2, other: true)], pinned: true,
                label: "Design review", emoji: "🎨"),
            workspace("Pinned single", windows: [window(3)], pinned: true),
            workspace("Single", windows: [window(4)]), workspace("Split", windows: [window(5), window(6, other: true)],
                label: "Checkout bug", emoji: "🐛")]
        snapshot.configuration.tabCollections = [.init(projectId: workspaceProjectDefaultId, name: "Website Eng",
            colorHex: "#E8B000", workspaceNames: ["Single", "Split"])]
        return snapshot
    }

    private func render(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func redPixels(_ host: NSView) throws -> [CGPoint] {
        let bitmap = try render(host)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var pixels: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.8, color.greenComponent < 0.35, color.blueComponent < 0.35,
                      color.alphaComponent > 0.5 else { continue }
                pixels.append(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale))
            }
        }
        return pixels
    }
}

private actor TabsPolishBadgeReader {
    private var reads = 0

    func next() -> WorkspaceSidebarDockBadgeSnapshot {
        reads += 1
        return .init(labelsByPath: ["/Applications/Test.app": reads == 1 ? "1234" : "7"])
    }
}
