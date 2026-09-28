import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class SettingsPanelPageTest: XCTestCase {
    func testEachModeListsExactlyTheSettingsItUses() {
        let pageFields = SettingsCatalog.fields.filter { $0.group.page == .appearance }
        for mode in WorkspaceSidebarMode.settingsOrder {
            let listed = SettingsPanelLayout.allSections(mode).flatMap(\.fields)
            XCTAssertEqual(listed.count, Set(listed).count, "\(mode): a setting is listed twice")
            let used = pageFields.filter { $0.modes?.contains(mode) == true }.map(\.id)
            XCTAssertEqual(Set(listed), Set(used), "\(mode)")
        }
        let header = [SettingsPanelLayout.enabledField, SettingsPanelLayout.modeField]
        XCTAssertEqual(Set(pageFields.filter { $0.modes == nil }.map(\.id)), Set(header), "Only the header is outside the modes")
        for id in SettingsPanelLayout.shared.fields {
            XCTAssertEqual(SettingsCatalog.field(id).modes, .allModes, "\(id) is shared, so every mode uses it")
        }
    }

    func testSharedSettingsSayWhichOtherModesTheyChange() {
        let width = SettingsCatalog.field("workspace-sidebar.width")
        XCTAssertEqual(SettingsPanelLayout.sharedNote(for: width, in: .dock), "Also changes Sidebar and Tabs modes.")
        XCTAssertEqual(SettingsPanelLayout.sharedNote(for: SettingsCatalog.field("workspace-sidebar.show-app-badges"), in: .tabs),
            "Also changes Dock mode.")
        XCTAssertNil(SettingsPanelLayout.sharedNote(for: SettingsCatalog.field("workspace-sidebar.dock-position"), in: .dock))
        XCTAssertNil(SettingsPanelLayout.sharedNote(for: SettingsCatalog.field("workspace-sidebar.stay-on-top"), in: .dock),
            "The shared section says it once for all of its rows")

        var configuration = defaultConfig
        configuration.workspaceSidebar.mode = .dock
        XCTAssertEqual(width.title(in: configuration), "Project column width")
        configuration.workspaceSidebar.alwaysExpanded = true
        XCTAssertEqual(width.title(in: configuration), "Panel width")
        configuration.workspaceSidebar.mode = .tabs
        XCTAssertEqual(width.title(in: configuration), "Sidebar width")
        for title in ["Project column width", "Panel width", "Expanded width", "Sidebar width"] {
            XCTAssertTrue(SettingsCatalog.results(title).contains { $0.id == width.id }, title)
        }
        XCTAssertEqual(SettingsCatalog.field("workspace-sidebar.collapsed-width").availability(in: configuration),
            .disabled("Turn off Keep the tab sidebar expanded to use this setting."), "The reason names this mode's own switch")
    }

    func testSearchNamesTheModeAndOffersToSwitchWithoutSwitching() {
        let browserTabs = SettingsCatalog.field("workspace-sidebar.browser-tabs")
        XCTAssertEqual(SettingsPanelLayout.breadcrumb(for: browserTabs, activeMode: .dock), "Workspace Panel › Tabs › Content")
        XCTAssertEqual(SettingsPanelLayout.breadcrumb(for: SettingsCatalog.field("workspace-sidebar.width"), activeMode: .sidebar),
            "Workspace Panel › Sidebar › Behavior")
        XCTAssertEqual(SettingsPanelLayout.breadcrumb(for: SettingsCatalog.field("workspace-sidebar.stay-on-top"), activeMode: .tabs),
            "Workspace Panel › Shared across modes")
        XCTAssertEqual(SettingsPanelLayout.breadcrumb(for: SettingsCatalog.field("window-tabs.height"), activeMode: .tabs),
            "Windows & Layout › Window tabs")
        XCTAssertTrue(SettingsCatalog.results("tabs browser").contains { $0.id == browserTabs.id })

        var configuration = defaultConfig
        configuration.workspaceSidebar.mode = .dock
        configuration.workspaceSidebar.enabled = true
        XCTAssertEqual(SettingsPanelLayout.callout(target: browserTabs.id, in: configuration),
            SettingsPanelCallout(field: browserTabs.id, actions: [.useMode(.tabs)]))
        XCTAssertNil(SettingsPanelLayout.callout(target: "workspace-sidebar.dock-position", in: configuration), "Shown in place")
        XCTAssertNil(SettingsPanelLayout.callout(target: "window-tabs.height", in: configuration))
        configuration.workspaceSidebar.enabled = false
        XCTAssertEqual(SettingsPanelLayout.callout(target: browserTabs.id, in: configuration)?.actions, [.useMode(.tabs), .turnOnPanel])
        XCTAssertEqual(SettingsPanelLayout.callout(target: "workspace-sidebar.dock-position", in: configuration)?.actions, [.turnOnPanel])
        XCTAssertNil(SettingsPanelLayout.callout(target: SettingsPanelLayout.modeField, in: configuration), "The header is always shown")
    }

    func testDisplaySummaryFollowsHowTheRunningAppResolvesMonitors() {
        let all = ["Studio Display", "DELL U2723QE"]
        XCTAssertEqual(SettingsPanelLayout.monitorSummary(configured: [], resolved: all, all: all, main: all[0]),
            "Panels appear on every display.")
        // Legacy `monitor = 'main'` puts a panel on every display.
        XCTAssertEqual(SettingsPanelLayout.monitorSummary(configured: [.main], resolved: all, all: all, main: all[0]),
            "Panels appear on every display.")
        XCTAssertEqual(SettingsPanelLayout.monitorSummary(configured: [.secondary], resolved: [all[1]], all: all, main: all[0]),
            "Panels appear on DELL U2723QE. While a display has no panel, every panel lists all displays' workspaces.")
        XCTAssertEqual(SettingsPanelLayout.monitorSummary(configured: [.sequenceNumber(9)], resolved: [], all: all, main: all[0]),
            "No display matches the monitor setting, so the panel appears on the main display, Studio Display.")
    }

    func testSwitchingToTabsAsksFirstWhileWindowStacksExist() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'dock'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let mode = SettingsCatalog.field(SettingsPanelLayout.modeField)

        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.pendingTabsSwitch)
        XCTAssertEqual(config.workspaceSidebar.mode, .dock, "Nothing is saved before confirmation")
        XCTAssertEqual(editor.projection.workspaceSidebar.mode, .dock, "The page keeps the running mode behind the question")
        editor.cancelTabsSwitch()
        XCTAssertNil(editor.pendingTabsSwitch)
        XCTAssertEqual(editor.value(mode), .text("dock"), "Cancel puts the cards back")

        editor.setDraft(.text("sidebar"), for: mode)
        editor.commit(mode)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.pendingTabsSwitch, "Other modes keep window stacks")
        XCTAssertEqual(config.workspaceSidebar.mode, .sidebar)

        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs)

        // Undo back out of Tabs needs no question; redoing the switch through Undo would.
        editor.undo()
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .sidebar)
        XCTAssertNil(editor.pendingTabsSwitch)
    }

    func testTurningOnAPanelSetToTabsAsksButChoosingTabsWhileOffDoesNot() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = false\n    mode = 'dock'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let mode = SettingsCatalog.field(SettingsPanelLayout.modeField)
        let enabled = SettingsCatalog.field(SettingsPanelLayout.enabledField)

        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.pendingTabsSwitch, "With the panel off, stacks stay")
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs)

        editor.setDraft(.bool(true), for: enabled)
        editor.commit(enabled)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.pendingTabsSwitch)
        XCTAssertFalse(config.workspaceSidebar.enabled)
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.usesBrowserTabs)

        editor.setDraft(.bool(false), for: enabled)
        editor.commit(enabled)
        await editor.waitUntilIdle()
        editor.undo()
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.pendingTabsSwitch, "Undo that turns Tabs back on asks too")
        XCTAssertFalse(config.workspaceSidebar.enabled)
        editor.cancelTabsSwitch()
        XCTAssertFalse(config.workspaceSidebar.enabled)
        XCTAssertNotNil(editor.undoTitle, "Cancelling keeps the Undo entry")

        editor.hasWindowStacks = { false }
        editor.undo()
        await editor.waitUntilIdle()
        XCTAssertNil(editor.pendingTabsSwitch, "Without stacks there is nothing to lose")
        XCTAssertTrue(config.usesBrowserTabs)
    }

    /// The question compares the running configuration with each save as it's about to run,
    /// so saves queued behind a failure, and TOML Editor saves, ask too.
    func testQueuedRetriedAndDocumentSavesAskBeforeTurningTabsOn() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'dock'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let mode = SettingsCatalog.field(SettingsPanelLayout.modeField)
        let enabled = SettingsCatalog.field(SettingsPanelLayout.enabledField)

        disk.failWrites = true
        editor.setDraft(.bool(false), for: enabled)
        editor.commit(enabled)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.error)
        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        editor.setDraft(.bool(true), for: enabled)
        editor.commit(enabled)
        XCTAssertNil(editor.pendingTabsSwitch, "Nothing turns Tabs on until the queue reaches that save")
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save, "Panel off, then Tabs, then panel on: the last save asks")
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs)
        XCTAssertFalse(config.usesBrowserTabs)
        XCTAssertFalse(editor.projection.workspaceSidebar.enabled, "The page shows the running panel while it asks")
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.usesBrowserTabs)

        XCTAssertTrue(disk.text.contains("mode = \"tabs\""), disk.text)
        let document = disk.text.replacingOccurrences(of: "mode = \"tabs\"", with: "mode = \"dock\"")
        editor.saveDocument(document, expected: disk.text)
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
        var ran = false
        editor.saveDocument(document.replacingOccurrences(of: "mode = \"dock\"", with: "mode = \"tabs\""), expected: disk.text) { ran = true }
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save, "A TOML edit that turns Tabs on asks too")
        XCTAssertTrue(editor.hasPendingDocument)
        editor.cancelTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertFalse(ran)
        XCTAssertFalse(config.usesBrowserTabs)
        XCTAssertFalse(editor.hasPendingDocument)
    }

    /// With automatic reload off, the file can already say Tabs while the app runs Dock. Any save
    /// then reloads Tabs, so it asks too.
    func testASaveThatWouldLoadAnExternalTabsEditAsks() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'dock'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        disk.text = disk.text.replacingOccurrences(of: "mode = 'dock'", with: "mode = 'tabs'")
        let width = SettingsCatalog.field("workspace-sidebar.width")
        editor.setDraft(.integer(300), for: width)
        editor.commit(width)
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save)
        XCTAssertTrue(disk.writes.isEmpty)
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.usesBrowserTabs)
        XCTAssertEqual(config.workspaceSidebar.width, 300)
    }

    /// Confirming a held save must not replace a newer choice queued behind it.
    func testConfirmingKeepsANewerDraftQueuedBehindTheHeldSave() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'dock'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let mode = SettingsCatalog.field(SettingsPanelLayout.modeField)
        let seconds = SettingsCatalog.field("workspace-sidebar.show-seconds")
        disk.failWrites = true
        editor.setDraft(.bool(!config.workspaceSidebar.showSeconds), for: seconds)
        editor.commit(seconds)
        await editor.waitUntilIdle()
        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        editor.setDraft(.text("sidebar"), for: mode)
        editor.commit(mode)
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save)
        XCTAssertEqual(editor.value(mode), .text("sidebar"), "The newer choice stays in the form")
        disk.failAfterWrites = disk.writes.count + 1
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs)
        XCTAssertNotNil(editor.error, "The Sidebar save failed")
        XCTAssertEqual(editor.projection.workspaceSidebar.mode, .sidebar, "The failed newer choice still shows, not applied")
    }

    /// While a question is open, Undo waits and new saves queue behind it.
    func testUndoAndSavesWaitWhileTheTabsQuestionIsOpen() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = true\n    mode = 'tabs'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let mode = SettingsCatalog.field(SettingsPanelLayout.modeField)
        let seconds = SettingsCatalog.field("workspace-sidebar.show-seconds")
        let secondsBefore = config.workspaceSidebar.showSeconds

        editor.setDraft(.text("dock"), for: mode)
        editor.commit(mode)
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
        editor.undo()
        XCTAssertEqual(editor.pendingTabsSwitch, .undo)
        editor.undo()
        editor.setDraft(.bool(!secondsBefore), for: seconds)
        editor.commit(seconds)
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.showSeconds, secondsBefore, "A save waits behind the open question")
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertEqual(config.workspaceSidebar.mode, .tabs, "The confirmed Undo is the one that ran")
        XCTAssertEqual(config.workspaceSidebar.showSeconds, !secondsBefore, "Then the queued save")
        XCTAssertEqual(editor.undoTitle, "Undo \(seconds.title)")

        editor.setDraft(.text("dock"), for: mode)
        editor.commit(mode)
        await editor.waitUntilIdle()
        editor.setDraft(.text("tabs"), for: mode)
        editor.commit(mode)
        XCTAssertEqual(editor.pendingTabsSwitch, .save)
        editor.undo()
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save, "Undo waits while a save is held")
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
        editor.cancelTabsSwitch()
        editor.undo()
        XCTAssertEqual(editor.pendingTabsSwitch, .undo, "Undoing the switch to Dock would turn Tabs back on")
        editor.cancelTabsSwitch()
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
    }

    func testRevertingAndRestoringDefaultsRespectTheTabsQuestion() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "[workspace-sidebar]\n    enabled = false\n    mode = 'tabs'\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.hasWindowStacks = { true }
        let enabled = SettingsCatalog.field(SettingsPanelLayout.enabledField)

        // Restoring the panel switch alone would turn Tabs on.
        editor.reset([enabled], title: "Panel")
        await editor.waitUntilIdle()
        XCTAssertEqual(editor.pendingTabsSwitch, .save)
        XCTAssertTrue(disk.writes.isEmpty)
        XCTAssertFalse(editor.projection.workspaceSidebar.enabled)
        editor.revertDrafts()
        XCTAssertNil(editor.pendingTabsSwitch, "Revert also drops the question")
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertTrue(disk.writes.isEmpty, "A dropped question can't be confirmed later")

        editor.reset([enabled], title: "Panel")
        editor.confirmTabsSwitch()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.usesBrowserTabs)
        XCTAssertEqual(editor.undoTitle, "Undo Restore Panel")

        // Restoring the whole header also restores Dock mode, so it asks nothing.
        disk.text = disk.text.replacingOccurrences(of: "enabled = true", with: "enabled = false")
        config = parseConfig(disk.text).config
        editor.synchronize(config)
        editor.reset(.dockMode)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.pendingTabsSwitch)
        XCTAssertEqual(config.workspaceSidebar.mode, .dock)
    }

    func testRestoringASectionLeavesOtherModesSettingsAlone() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += """
            [workspace-sidebar]
                enabled = true
                mode = 'dock'
                dock-left-gap = 9
                always-expanded = true
                tabs-always-expanded = false
                collapsed-width = 60
                width = 300

            """
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let section = SettingsPanelLayout.sections(.dock).first { $0.id == "dock.behavior" }!
        editor.reset(section.fields.map(SettingsCatalog.field), title: section.title)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertEqual(config.workspaceSidebar.dockLeftGap, defaultConfig.workspaceSidebar.dockLeftGap)
        XCTAssertEqual(config.workspaceSidebar.alwaysExpanded, defaultConfig.workspaceSidebar.alwaysExpanded)
        XCTAssertFalse(config.workspaceSidebar.tabsAlwaysExpanded, "Tabs' own setting is untouched")
        XCTAssertEqual(config.workspaceSidebar.collapsedWidth, 60)
        XCTAssertEqual(config.workspaceSidebar.width, 300, "Width belongs to another section")
        XCTAssertEqual(editor.undoTitle, "Undo Restore \(section.title)")
    }

    func testEntryPointsNameTheActiveMode() {
        XCTAssertEqual(workspaceSidebarWorkspaceMenuEntries(testWorkspace, context: .init(monitorCount: 1, panelMode: .dock)).first?.title,
            "Customize Dock…")
        XCTAssertEqual(workspaceSidebarWorkspaceMenuEntries(testWorkspace, context: .init(monitorCount: 1, panelMode: .sidebar)).first?.title,
            "Customize Sidebar…")
        let saved = ShortcutSettingsModel.shared.requestedSettingsPage
        defer { ShortcutSettingsModel.shared.requestedSettingsPage = saved }
        ShortcutSettingsModel.shared.requestPanelSettings()
        XCTAssertEqual(ShortcutSettingsModel.shared.requestedSettingsPage, .appearance)
        XCTAssertEqual(SettingsSidebarItem.appearance.label, "Workspace Panel")
    }

    /// Each mode remembers its own scroll position; the editor survives the remount.
    func testEachModeKeepsItsOwnScrollPosition() throws {
        let savedPositions = SettingsScrollMemory.shared.positions
        defer { SettingsScrollMemory.shared.positions = savedPositions }
        SettingsScrollMemory.shared.positions = [:]
        var configuration = defaultConfig
        configuration.workspaceSidebar.enabled = true
        configuration.workspaceSidebar.mode = .dock
        let editor = SettingsEditor(configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: SettingsForm(page: .appearance, editor: editor, model: .shared))
        settle(window)
        func scroll() throws -> NSScrollView {
            try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }.max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
        }
        try scroll().contentView.scroll(to: CGPoint(x: 0, y: 400))
        try scroll().reflectScrolledClipView(try scroll().contentView)
        settle(window)
        configuration.workspaceSidebar.mode = .sidebar
        editor.synchronize(configuration)
        settle(window)
        XCTAssertLessThan(try scroll().contentView.bounds.minY, 50, "Sidebar starts at its own position")
        configuration.workspaceSidebar.mode = .dock
        editor.synchronize(configuration)
        settle(window)
        settle(window)
        XCTAssertGreaterThan(try scroll().contentView.bounds.minY, 300, "Dock returns to where it was")
    }

    private var testWorkspace: WorkspaceSidebarWorkspaceViewModel {
        WorkspaceSidebarWorkspaceViewModel(name: "1", projectId: workspaceProjectDefaultId, displayName: "1", sidebarLabel: "1",
            isGeneratedName: false, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: true, items: [],
            savedState: nil)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
