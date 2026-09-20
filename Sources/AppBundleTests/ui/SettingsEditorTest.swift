import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class SettingsEditorTest: XCTestCase {
    func testCatalogValuesRoundTripAndSearchFindsLabelsAndTOMLKeys() {
        let saved = config
        defer { config = saved }
        let ids = SettingsCatalog.fields.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for field in SettingsCatalog.fields where field.writePreference == nil {
            let text = updateSettingsAppearanceConfig(in: "config-version = 2\n", section: field.section,
                values: [field.key: field.render(field.defaultValue)])
            let parsed = parseConfig(text)
            XCTAssertTrue(parsed.errors.isEmpty, "\(field.id): \(parsed.errors)")
            XCTAssertEqual(field.read(parsed.config), field.defaultValue, field.id)
        }
        XCTAssertTrue(SettingsCatalog.results("dock opacity").contains { $0.key == "glass-opacity" })
        XCTAssertTrue(SettingsCatalog.results("dock-position").contains { $0.title == "Position" })
        XCTAssertTrue(SettingsCatalog.results("clock seconds").contains { $0.key == "show-seconds" })
        XCTAssertTrue(SettingsCatalog.results("nonexistent-setting-xyz").isEmpty)
    }

    func testDependentControlsAndPreviewRespondBeforeSaving() {
        var configuration = defaultConfig
        configuration.workspaceSidebar.mode = .dock
        let editor = SettingsEditor(configuration: configuration)
        let clock = SettingsCatalog.field("workspace-sidebar.show-clock")
        editor.setDraft(.bool(false), for: clock)
        XCTAssertFalse(SettingsCatalog.field("workspace-sidebar.show-seconds").visible(editor))
        let style = SettingsCatalog.field("workspace-sidebar.dock-appearance.style")
        editor.setDraft(.text("solid"), for: style)
        XCTAssertFalse(SettingsCatalog.field("workspace-sidebar.dock-appearance.glass-opacity").visible(editor))
        XCTAssertTrue(SettingsCatalog.field("workspace-sidebar.dock-appearance.solid-color").visible(editor))
        editor.setDraft(.integer(32), for: SettingsCatalog.field("workspace-sidebar.dock-icon-size"))
        editor.setDraft(.text("right"), for: SettingsCatalog.field("workspace-sidebar.dock-position"))
        let preview = SettingsDockPreview(editor: editor).previewConfiguration
        XCTAssertEqual(preview.dockIconSize, 32)
        XCTAssertEqual(preview.dockPosition, .right)
        XCTAssertEqual(preview.chromeStyle, .solid)
        XCTAssertFalse(editor.isSaving)
    }

    func testRapidChangesAreSerializedAndLastValueWins() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("start-at-login")
        editor.setDraft(.bool(true), for: field); editor.commit(field)
        editor.setDraft(.bool(false), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertEqual(disk.writes.count, 2)
        XCTAssertFalse(parseConfig(disk.text).config.startAtLogin)
        XCTAssertFalse(editor.value(field).bool)
        XCTAssertTrue(editor.drafts.isEmpty)
        XCTAssertNil(editor.error)
    }

    func testWriteFailureCanRetryAndRevertWithoutPretendingItSaved() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("start-at-login")
        disk.failWrites = true
        editor.setDraft(.bool(true), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.error)
        XCTAssertTrue(editor.canRetry)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertNil(editor.undoTitle)
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.startAtLogin)
        XCTAssertNil(editor.error)
        XCTAssertEqual(editor.undoTitle, "Undo Start at login")
        editor.setDraft(.bool(false), for: field)
        editor.revertDrafts()
        XCTAssertTrue(editor.value(field).bool)
    }

    func testReloadFailureRollsBackAndDoesNotCreateUndoEntry() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        let original = disk.text
        config = parseConfig(original).config
        let editor = SettingsEditor(persistence: disk.persistence)
        disk.failNextReload = true
        let field = SettingsCatalog.field("start-at-login")
        editor.setDraft(.bool(true), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertEqual(disk.text, original)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertNotNil(editor.error)
        XCTAssertNil(editor.undoTitle)
    }

    func testUndoPreservesExternalEditsAndExternalValuesSynchronize() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("start-at-login")
        editor.setDraft(.bool(true), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        disk.text = disk.text.replacingOccurrences(of: "auto-reload-config = false", with: "auto-reload-config = true")
        let external = disk.text
        await editor.undoAndWait()
        XCTAssertEqual(disk.text, external)
        XCTAssertNotNil(editor.error)
        XCTAssertFalse(editor.canRetry)
        XCTAssertNil(editor.undoTitle)
        editor.revertDrafts()
        editor.synchronize(parseConfig(external).config)
        XCTAssertTrue(editor.value(SettingsCatalog.field("auto-reload-config")).bool)
    }

    func testSectionResetIsOneUndoAndPreservesDockInheritanceAndOtherSettings() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "\n[workspace-sidebar]\nchrome-style = 'solid'\nsolid-chrome-color = 'blue'\ndock-icon-size = 32\n"
        let original = disk.text
        config = parseConfig(original).config
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.reset(.windowChrome)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertEqual(config.workspaceSidebar.chromeStyle, defaultConfig.workspaceSidebar.chromeStyle)
        XCTAssertEqual(config.workspaceSidebar.dockChromeStyle, .solid)
        XCTAssertEqual(config.workspaceSidebar.dockSolidColor, .blue)
        XCTAssertEqual(config.workspaceSidebar.dockIconSize, 32)
        await editor.undoAndWait()
        XCTAssertEqual(disk.text, original)
    }

    func testExternalEditBetweenSavesAndQuotedValuesArePreserved() async throws {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        disk.text += "\n# External comment\nenable-shake-to-toggle-tiling = false\n"
        let field = SettingsCatalog.field("persistent-workspaces")
        editor.setDraft(.text("a/b, quoted\"name, work\\space"), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertTrue(disk.text.contains("# External comment"))
        XCTAssertFalse(config.enableShakeToToggleTiling)
        XCTAssertEqual(Array(config.persistentWorkspaces), ["a/b", "quoted\"name", "work\\space"])
    }

    func testMultilineValuesAreReplacedWithoutLeavingArrayFragments() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        disk.text += "persistent-workspaces = [\n  '1', # Keep\n  'two]words',\n]\n# Other setting\n[workspace-sidebar]\nwidth = 250\n"
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("persistent-workspaces")
        editor.setDraft(.text("3, 4"), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertEqual(Array(config.persistentWorkspaces), ["3", "4"])
        XCTAssertEqual(config.workspaceSidebar.width, 250)
        XCTAssertTrue(disk.text.contains("# Other setting"))
    }

    func testDocumentSaveRejectsExternalEditAndSupportsUndo() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let original = disk.text
        let edited = original.replacingOccurrences(of: "start-at-login = false", with: "start-at-login = true")
        editor.saveDocument(edited, expected: original)
        await editor.waitUntilIdle()
        XCTAssertTrue(config.startAtLogin)
        await editor.undoAndWait()
        XCTAssertEqual(disk.text, original)
        disk.text += "# External edit\n"
        let external = disk.text
        editor.saveDocument(edited, expected: original)
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.error)
        XCTAssertEqual(disk.text, external)
    }

    func testTOMLEditIgnoresKeysAndHeadersInsideMultilineStrings() {
        let original = """
        config-version = 2
        exec-on-workspace-change = ['''
        [workspace-sidebar]
        dock-icon-size = 24
        ''']
        [workspace-sidebar]
        'dock-icon-size' = 32
        """
        let updated = updateSettingsScalarConfig(in: original, section: "workspace-sidebar",
            key: "dock-icon-size", renderedValue: "40")
        XCTAssertTrue(updated.contains("dock-icon-size = 24"))
        XCTAssertFalse(updated.contains("'dock-icon-size' = 32"))
        XCTAssertEqual(parseConfig(updated).config.workspaceSidebar.dockIconSize, 40)
        XCTAssertTrue(parseConfig(updated).errors.isEmpty)
    }

    func testTOMLEditUpdatesEquivalentDottedKeysAndSubtables() {
        for text in ["[gaps.inner]\nhorizontal = 8\nvertical = 9\n", "gaps.inner.horizontal = 8\n", "[gaps.inner]\nvertical = 9\n"] {
            let updated = updateSettingsScalarConfig(in: text, section: "gaps", key: "inner.horizontal", renderedValue: "12")
            let parsed = parseConfig(updated)
            XCTAssertTrue(parsed.errors.isEmpty, "\(updated): \(parsed.errors)")
            XCTAssertEqual(settingsConstantValue(parsed.config.gaps.inner.horizontal), 12)
        }
    }

    func testTOMLEditPreservesCRLFAndSkipsMultilineQuotedKeysContainingEquals() {
        let original = "config-version = 2\r\nstart-at-login = false\r\n[exec.env-vars]\r\n'A=B' = '''\r\n[workspace-sidebar]\r\ndock-icon-size = 24\r\n'''\r\n"
        let updated = updateSettingsScalarConfig(in: original, section: "workspace-sidebar", key: "dock-icon-size", renderedValue: "40")
        XCTAssertTrue(updated.contains("dock-icon-size = 24"))
        XCTAssertTrue(updated.contains("dock-icon-size = 40"))
        XCTAssertFalse(updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "New and existing lines must use CRLF")
        let replaced = updateSettingsScalarConfig(in: updated, section: nil, key: "start-at-login", renderedValue: "true")
        XCTAssertTrue(replaced.contains("start-at-login = true\r\n"))
    }

    func testWindowAppearanceCanPreserveInheritedDockOnMinimalConfig() {
        let updated = updateSettingsAppearanceConfig(in: "config-version = 2\n", section: "workspace-sidebar",
            values: ["chrome-style": "'solid'"], preservingDockAppearance: true)
        let parsed = parseConfig(updated)
        XCTAssertTrue(parsed.errors.isEmpty, "\(updated): \(parsed.errors)")
        XCTAssertEqual(parsed.config.workspaceSidebar.chromeStyle, .solid)
        XCTAssertEqual(parsed.config.workspaceSidebar.dockChromeStyle, defaultConfig.workspaceSidebar.dockChromeStyle)
    }

    func testTOMLInsertionKeepsMostSpecificTableWhenParentAppearsLater() {
        let gaps = "[gaps.inner]\nvertical = 9\n[gaps]\nouter.left = 12\n"
        let updated = updateSettingsScalarConfig(in: gaps, section: "gaps", key: "inner.horizontal", renderedValue: "16")
        let parsed = parseConfig(updated)
        XCTAssertTrue(parsed.errors.isEmpty, "\(updated): \(parsed.errors)")
        XCTAssertEqual(settingsConstantValue(parsed.config.gaps.inner.horizontal), 16)
        XCTAssertEqual(settingsConstantValue(parsed.config.gaps.inner.vertical), 9)
        XCTAssertEqual(settingsConstantValue(parsed.config.gaps.outer.left), 12)

        let appearance = "[workspace-sidebar.dock-appearance]\nstyle = 'solid'\n[workspace-sidebar]\nwidth = 250\nglass-opacity = 0.4\n"
        let chrome = updateSettingsAppearanceConfig(in: appearance, section: "workspace-sidebar",
            values: ["chrome-style": "'solid'"], preservingDockAppearance: true)
        let result = parseConfig(chrome)
        XCTAssertTrue(result.errors.isEmpty, "\(chrome): \(result.errors)")
        XCTAssertEqual(result.config.workspaceSidebar.dockChromeStyle, .solid)
        XCTAssertEqual(result.config.workspaceSidebar.dockGlassOpacity, 0.4)
        XCTAssertEqual(result.config.workspaceSidebar.width, 250)
    }

    func testPreferenceSaveAndUndoDoNotWriteTOML() async throws {
        setScheduledRefreshOverrideForTests { _, _, _ in }
        let field = SettingsCatalog.field("preferences.double-sided-windows")
        let previous = field.read(config)
        defer {
            var preferences = ExperimentalUISettings(); preferences.doubleSidedWindows = previous.bool
            setScheduledRefreshOverrideForTests(nil)
        }
        let disk = SettingsTestDisk()
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.setDraft(.bool(!previous.bool), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertEqual(field.read(config).bool, !previous.bool)
        XCTAssertEqual(editor.value(field).bool, !previous.bool)
        XCTAssertTrue(disk.writes.isEmpty)
        await editor.undoAndWait()
        XCTAssertEqual(field.read(config), previous)
        XCTAssertTrue(disk.writes.isEmpty)
        try await waitForScheduledRefreshForTests()
    }

    func testAutomationDraftSurvivesReloadFailureAndExternalRefresh() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.automationFields.first { $0.key == "on-focus-changed" }!
        let draft = SettingsValue.text("focus left\n   \nfocus right")
        disk.failNextReload = true
        editor.setDraft(draft, for: field); editor.commit(field)
        await editor.waitUntilIdle()
        editor.synchronize(config)
        XCTAssertEqual(editor.value(field), draft)
        XCTAssertNotNil(editor.error)
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertTrue(editor.drafts.isEmpty)
        XCTAssertEqual(config.onFocusChanged.count, 2)
    }

    func testFormEditCannotTruncateAnInvalidFileAndRawEditorCanRepairIt() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        disk.text += "persistent-workspaces = [\n'1'\n[workspace-sidebar]\ndock-icon-size = 32\n"
        let original = disk.text
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("persistent-workspaces")
        editor.setDraft(.text("2"), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        XCTAssertEqual(disk.text, original)
        XCTAssertTrue(disk.writes.isEmpty)
        XCTAssertNotNil(editor.error)
        XCTAssertFalse(editor.hasPendingDocument, "Reverting this error must preserve an unrelated TOML draft")
        editor.revertDrafts()
        let repaired = original.replacingOccurrences(of: "'1'\n[workspace-sidebar]", with: "'1']\n[workspace-sidebar]")
        editor.saveDocument(repaired, expected: original)
        XCTAssertTrue(editor.hasPendingDocument)
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertEqual(disk.text, repaired)
        XCTAssertNil(editor.undoTitle, "Undo must not offer to reinstall the broken configuration")
    }

    func testDocumentSaveRejectsDifferentConfigurationFileEvenWithIdenticalContents() async {
        let disk = SettingsTestDisk()
        let editor = SettingsEditor(persistence: disk.persistence)
        editor.saveDocument(disk.text, expected: disk.text, expectedURL: URL(fileURLWithPath: "/another/settings.toml"))
        await editor.waitUntilIdle()
        XCTAssertNotNil(editor.error)
        XCTAssertTrue(disk.writes.isEmpty)
    }

    func testFailedWriteRetainsQueuedChangesForRetry() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        disk.failWrites = true
        for key in ["start-at-login", "auto-reload-config"] {
            let field = SettingsCatalog.field(key)
            editor.setDraft(.bool(true), for: field); editor.commit(field)
        }
        await editor.waitUntilIdle()
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertTrue(config.startAtLogin)
        XCTAssertTrue(config.autoReloadConfig)
        XCTAssertTrue(editor.drafts.isEmpty)
    }

    func testReturningToOriginalValueAfterFailureWinsOnRetry() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let field = SettingsCatalog.field("start-at-login")
        disk.failWrites = true
        editor.setDraft(.bool(true), for: field); editor.commit(field)
        await editor.waitUntilIdle()
        editor.setDraft(.bool(false), for: field); editor.commit(field)
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertNil(editor.error)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertFalse(editor.value(field).bool)
        XCTAssertTrue(editor.drafts.isEmpty)
    }

    func testDocumentCompletionRunsForItsOwnSuccessfulRetryBeforeLaterFailure() async {
        let saved = config
        defer { config = saved }
        let disk = SettingsTestDisk()
        config = parseConfig(disk.text).config
        let editor = SettingsEditor(persistence: disk.persistence)
        let original = disk.text
        let edited = original.replacingOccurrences(of: "start-at-login = false", with: "start-at-login = true")
        var completions = 0
        disk.failWrites = true
        editor.saveDocument(edited, expected: original) { completions += 1 }
        await editor.waitUntilIdle()
        XCTAssertEqual(completions, 0)
        editor.saveRaw([SettingsFileEdit(values: ["unknown-setting": "true"])], title: "Invalid later request")
        disk.failWrites = false
        editor.retry()
        await editor.waitUntilIdle()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(disk.text, edited)
        XCTAssertNotNil(editor.error, "The later failure must not hide the document's own successful result")
    }
}

@MainActor
private extension SettingsEditor {
    func undoAndWait() async { undo(); await waitUntilIdle() }
}

@MainActor
private final class SettingsTestDisk {
    var text = "config-version = 2\nstart-at-login = false\nauto-reload-config = false\n"
    var writes: [String] = []
    var failWrites = false
    var failNextReload = false
    var persistence: SettingsPersistence {
        SettingsPersistence(target: { URL(fileURLWithPath: "/test-only/settings.toml") }, read: { _ in self.text },
            write: { _, text in
                if self.failWrites { throw SettingsEditError("Test write denied") }
                self.text = text; self.writes.append(text)
            }, reload: { _ in
                await Task.yield()
                if self.failNextReload { self.failNextReload = false; return false }
                let parsed = parseConfig(self.text)
                guard parsed.errors.isEmpty else { return false }
                config = parsed.config
                return true
            })
    }
}
