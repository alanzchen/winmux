@testable import AppBundle
import AppKit
import Combine
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAppRemindersTest: XCTestCase {
    private let chat = WorkspaceSidebarAppViewModel(name: "Chat", bundleId: "test.chat", bundlePath: "/Applications/Chat.app")
    private let editor = WorkspaceSidebarAppViewModel(name: "Editor", bundleId: "test.editor", bundlePath: "/Applications/Editor.app")

    private func workspace(_ name: String, visible: Bool = false, apps: [WorkspaceSidebarAppViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: name,
            isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
            isFocused: false, isVisible: visible, items: [], apps: apps)
    }

    func testRemindersOnlyIncludeBadgedAppsOutsideTheDockAndVisibleDisplays() {
        let workspaces = [workspace("shown", apps: [chat]), workspace("hidden", apps: [chat, editor]),
            workspace("other display", visible: true, apps: [chat]), workspace("also hidden", apps: [chat])]
        let badges = WorkspaceSidebarDockBadgeSnapshot(labelsByPath: ["/Applications/Chat.app": "3"])
        let reminders = workspaceSidebarAppReminders(workspaces: workspaces,
            displayedWorkspaceNames: ["shown"], badges: badges, enabled: true)
        XCTAssertEqual(reminders.map { $0.workspace.name }, ["hidden", "also hidden"])
        XCTAssertEqual(reminders.map(\.app), [chat, chat])
        XCTAssertEqual(Set(reminders.map(\.id)).count, 2, "Shared application badges retain distinct workspace destinations")
        XCTAssertTrue(workspaceSidebarAppReminders(workspaces: workspaces,
            displayedWorkspaceNames: [], badges: badges, enabled: false).isEmpty)
        XCTAssertTrue(workspaceSidebarAppReminders(workspaces: workspaces,
            displayedWorkspaceNames: [], badges: .init(), enabled: true).isEmpty, "Cleared badges remove reminders")
        XCTAssertTrue(workspaceSidebarAppReminders(workspaces: workspaces,
            displayedWorkspaceNames: Set(workspaces.map(\.name)), badges: badges, enabled: true).isEmpty)
    }

    func testReminderOptionDefaultsOffParsesAndIsDockOnly() {
        let field = SettingsCatalog.field("workspace-sidebar.show-hidden-workspace-app-reminders")
        XCTAssertEqual(field.defaultValue, .bool(false))
        var settings = defaultConfig
        settings.workspaceSidebar.mode = .dock
        let editor = SettingsEditor(configuration: settings)
        XCTAssertTrue(field.visible(editor))
        editor.setDraft(.text("sidebar"), for: SettingsCatalog.field("workspace-sidebar.mode"))
        XCTAssertFalse(field.visible(editor))
        XCTAssertTrue(SettingsCatalog.results("reminders").contains { $0.id == field.id })
        XCTAssertFalse(WorkspaceSidebarConfig().showHiddenWorkspaceAppReminders)
        let (parsed, errors) = parseConfig("[workspace-sidebar]\nshow-hidden-workspace-app-reminders = true\nshow-app-badges = false\n")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(parsed.workspaceSidebar.showHiddenWorkspaceAppReminders)
        XCTAssertFalse(parsed.workspaceSidebar.showAppBadges, "Reminder setting is independent of ordinary icon badges")
        XCTAssertFalse(parseConfig("[workspace-sidebar]\nshow-hidden-workspace-app-reminders = 'yes'\n").1.isEmpty)
        let previous = config
        defer { config = previous }
        config = parsed
        XCTAssertTrue(workspaceSidebarConfiguration().showHiddenWorkspaceAppReminders)
    }

    func testReminderReserveIsBoundedAndIncludedInAllDockOrientations() {
        XCTAssertEqual(workspaceSidebarReminderLength(count: 0, iconSize: 52), 0)
        XCTAssertEqual(workspaceSidebarReminderLength(count: 1, iconSize: 52), 68)
        XCTAssertEqual(workspaceSidebarReminderLength(count: 3, iconSize: 52), 188)
        XCTAssertEqual(workspaceSidebarReminderLength(count: 30, iconSize: 52), 188)
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            var layout = WorkspaceSidebarConfiguration.empty
            layout.showAppIcons = true
            layout.dockPosition = position
            for clock in [true, false] {
                layout.showsClock = clock
                let base = workspaceSidebarDockContentHeight(appCounts: [2], configuration: layout,
                    showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1)
                let reminders = workspaceSidebarDockContentHeight(appCounts: [2], configuration: layout,
                    showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1, reminderCount: 5)
                XCTAssertEqual(reminders - base, workspaceSidebarReminderLength(count: 5, iconSize: layout.dockIconSize), accuracy: 0.01)
                let size = workspaceSidebarFittedDockIconSize(appCounts: [2], configuration: layout,
                    availableHeight: reminders - 20, showsCreateWorkspace: true, showsMonitorSelector: false,
                    projectCount: 1, reminderCount: 5)
                XCTAssertLessThan(size, layout.dockIconSize)
                let emptyPageLength = workspaceSidebarDockContentHeight(appCounts: [], configuration: layout,
                    showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1, reminderCount: 3)
                let emptyPageSize = workspaceSidebarFittedDockIconSize(appCounts: [], configuration: layout,
                    availableHeight: emptyPageLength - 20, showsCreateWorkspace: true, showsMonitorSelector: false,
                    projectCount: 1, reminderCount: 3)
                XCTAssertLessThan(emptyPageSize, layout.dockIconSize, "Reminder-only Docks also fit the available space")
            }
        }
    }

    func testDockResizesWhenReminderBadgesClearWithoutPointerInput() async throws {
        let previous = ProcessInfo.processInfo.environment["WINMUX_NATIVE_DOCK"]
        defer {
            if let previous { setenv("WINMUX_NATIVE_DOCK", previous, 1) }
            else { unsetenv("WINMUX_NATIVE_DOCK") }
        }
        for renderer in ["1", "0"] {
            setenv("WINMUX_NATIVE_DOCK", renderer, 1)
            for position: WorkspaceDockPosition in [.left, .right, .bottom] {
                try await checkLiveResize(position: position, renderer: renderer)
            }
        }
    }

    private func checkLiveResize(position: WorkspaceDockPosition, renderer: String) async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: ["/Applications/Chat.app": "3"]) })
        model.setEnabled(true, showsAppBadges: false)
        defer { model.setEnabled(false) }
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = [workspace("shown", visible: true, apps: [editor]),
            .init(name: "hidden", projectId: "other-project", displayName: "Research", sidebarLabel: "Research",
                isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
                isFocused: false, isVisible: false, items: [], apps: [chat])]
        snapshot.visibleWidth = 64
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.showHiddenWorkspaceAppReminders = true
        snapshot.configuration.dockPosition = position
        snapshot.configuration.chromeStyle = .solid
        snapshot.configuration.showsClock = true
        var surface = CGRect.zero
        let view = WorkspaceSidebarView(snapshot: snapshot,
            actions: .init(setSurfaceFrame: { surface = $0 }), reduceMotionOverride: true, dockBadgeModel: model)
        XCTAssertEqual(view.hiddenWorkspaceAppReminders.count, 1)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        host.layoutSubtreeIfNeeded()
        let initial = position == .bottom ? surface.width : surface.height
        XCTAssertGreaterThan(initial, 0)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: surface))
        host.cacheDisplay(in: surface, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/issue-fixes-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("dock-hidden-app-reminders-\(position)-\(renderer).png"))
        model.setEnabled(false)
        for _ in 0..<50 where (position == .bottom ? surface.width : surface.height) == initial {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(initial - (position == .bottom ? surface.width : surface.height),
            workspaceSidebarReminderLength(count: 1, iconSize: snapshot.configuration.dockIconSize), accuracy: 0.1)
        XCTAssertTrue(view.hiddenWorkspaceAppReminders.isEmpty)
    }

    func testReminderViewportCanScrollToAdditionalApps() async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: ["/Applications/Chat.app": "3"]) })
        model.setEnabled(true, showsAppBadges: false)
        defer { model.setEnabled(false) }
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.showAppIcons = true
        snapshot.configuration.showHiddenWorkspaceAppReminders = true
        snapshot.workspaces = (1...5).map { index in
            .init(name: "hidden-\(index)", projectId: "other-project", displayName: "Hidden \(index)", sidebarLabel: "",
                isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
                isFocused: false, isVisible: false, items: [], apps: [chat])
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            snapshot.configuration.dockPosition = position
            let view = WorkspaceSidebarView(snapshot: snapshot, dockBadgeModel: model)
            XCTAssertEqual(view.hiddenWorkspaceAppReminders.count, 5)
            let host = NSHostingView(rootView: view.hiddenWorkspaceReminderSection(layout: snapshot.configuration))
            let length = workspaceSidebarReminderLength(count: 5, iconSize: snapshot.configuration.dockIconSize)
            let horizontal = position == .bottom
            host.frame = CGRect(x: 0, y: 0, width: horizontal ? length : snapshot.configuration.compactRailWidth,
                height: horizontal ? snapshot.configuration.compactRailWidth : length)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollView(in: host))
            let document = try XCTUnwrap(scroll.documentView)
            let contentLength = horizontal ? document.frame.width : document.frame.height
            let viewportLength = horizontal ? scroll.contentView.bounds.width : scroll.contentView.bounds.height
            XCTAssertGreaterThan(contentLength, viewportLength, "All five reminders must remain in the scrollable document")
            let destination = horizontal ? CGPoint(x: contentLength - viewportLength, y: 0)
                : CGPoint(x: 0, y: contentLength - viewportLength)
            scroll.contentView.scroll(to: destination)
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertGreaterThan(horizontal ? scroll.contentView.bounds.minX : scroll.contentView.bounds.minY, 0)
        }
    }

    func testUnreadCountChangesDoNotInvalidateDockGeometry() {
        let presence = WorkspaceSidebarDockBadgePresence()
        var emissions = 0
        let observation = presence.objectWillChange.sink { emissions += 1 }
        presence.update(.init(labelsByPath: ["/Applications/Chat.app": "1"]))
        XCTAssertEqual(emissions, 1)
        presence.update(.init(labelsByPath: ["/Applications/Chat.app": "99"], showsAppBadges: false))
        XCTAssertEqual(emissions, 1, "Count and ordinary badge setting changes only redraw badge leaves")
        presence.update(.init())
        XCTAssertEqual(emissions, 2)
        withExtendedLifetime(observation) {}
    }

    func testReminderPollingDoesNotEnableOrdinaryBadgesAndCanToggleLive() async throws {
        let model = WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: ["/Applications/Chat.app": "3"]) })
        defer { model.setEnabled(false) }
        model.setEnabled(true, showsAppBadges: false)
        for _ in 0..<100 where model.snapshot.labelsByPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.snapshot.label(forPath: chat.bundlePath), "3")
        XCTAssertFalse(model.snapshot.showsAppBadges)
        model.setEnabled(true, showsAppBadges: true)
        XCTAssertTrue(model.snapshot.showsAppBadges)
        model.setEnabled(true, showsAppBadges: false)
        XCTAssertFalse(model.snapshot.showsAppBadges)
        XCTAssertEqual(model.snapshot.label(forPath: chat.bundlePath), "3")
        model.setEnabled(false)
        XCTAssertTrue(model.snapshot.labelsByPath.isEmpty)
        XCTAssertFalse(model.snapshot.showsAppBadges)
    }
}
