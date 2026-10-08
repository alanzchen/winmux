import AppKit
import SwiftUI

/// Workspace Panel page: the panel switch and mode cards, then only what the active mode uses.
struct SettingsPanelPage: View {
    @ObservedObject var editor: SettingsEditor
    var targetField: String?
    let wide: Bool
    var openTOMLEditor: () -> Void = {}

    private var sidebar: WorkspaceSidebarConfig { editor.projection.workspaceSidebar }

    var body: some View {
        let mode = sidebar.mode
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                row(SettingsPanelLayout.enabledField)
                SettingsModePicker(editor: editor, highlighted: targetField == SettingsPanelLayout.modeField)
                    .id(SettingsPanelLayout.modeField)
            }
            if let callout = SettingsPanelLayout.callout(target: targetField, in: editor.projection) {
                calloutView(callout)
            }
            if sidebar.enabled {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                layout {
                    SettingsDockPreview(editor: editor).frame(width: wide ? 280 : nil)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(SettingsPanelLayout.sections(mode)) { section($0, mode: mode, footer: footer($0)) }
                        section(SettingsPanelLayout.shared, mode: mode, footer: AnyView(VStack(alignment: .leading, spacing: 6) {
                            Text(SettingsPanelLayout.monitorSummary(sidebar))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Edit Displays in TOML Editor…", action: openTOMLEditor).controlSize(.small)
                        }))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Turn on Show the workspace panel to choose where it appears and how it looks. Window, project, and shortcut settings on the other pages still apply.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(_ section: SettingsPanelSection) -> AnyView? {
        guard section.id == SettingsPanelLayout.tabsContentSection, sidebar.browserTabs else { return nil }
        let safari = SafariExtensionBridge.shared.isAvailable
        let chrome = ChromeExtensionSetup.bundled(in: Bundle.main.bundleURL) != nil
        guard safari || chrome else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            if safari { SafariExtensionSettingsStatus() }
            if chrome { ChromeExtensionSettingsSetup() }
        })
    }

    private func row(_ id: String, mode: WorkspaceSidebarMode? = nil) -> some View {
        let field = SettingsCatalog.field(id)
        return SettingsFieldRow(field: field, editor: editor, highlighted: field.id == targetField,
            note: mode.flatMap { SettingsPanelLayout.sharedNote(for: field, in: $0) })
            .id(field.id)
    }

    private func section(_ section: SettingsPanelSection, mode: WorkspaceSidebarMode, footer: AnyView? = nil) -> some View {
        let fields = section.fields.map(SettingsCatalog.field)
        let visible = fields.filter { $0.availability(editor).isShown || $0.id == targetField }
        let others = Set(fields.flatMap { $0.modes ?? [] }).subtracting([mode])
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(section.title).font(.headline)
                Spacer()
                Menu {
                    if section.id != SettingsPanelLayout.shared.id, !others.isEmpty {
                        Text("Also changes \(settingsModesText(others))")
                    }
                    Button("Restore Defaults") { editor.reset(fields, title: section.title) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Options for \(section.title)")
                .disabled(editor.isSaving)
            }
            if let note = section.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard {
                ForEach(visible) { field in row(field.id, mode: mode) }
                if let footer {
                    footer.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(section.id)
    }

    private func calloutView(_ callout: SettingsPanelCallout) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Search result").font(.headline)
            SettingsCard {
                row(callout.field)
                HStack {
                    ForEach(callout.actions, id: \.self) { action in
                        switch action {
                            case .useMode(let mode):
                                Button("Use \(mode.settingsTitle)") { select(mode) }
                            case .turnOnPanel:
                                Button("Turn On the Panel") { turnOnPanel() }
                        }
                    }
                }
                .controlSize(.small)
                .disabled(editor.isSaving)
                .padding(12)
            }
        }
    }

    private func select(_ mode: WorkspaceSidebarMode) {
        let field = SettingsCatalog.field(SettingsPanelLayout.modeField)
        editor.setDraft(.text(mode.rawValue), for: field)
        editor.commit(field)
    }

    private func turnOnPanel() {
        let field = SettingsCatalog.field(SettingsPanelLayout.enabledField)
        editor.setDraft(.bool(true), for: field)
        editor.commit(field)
    }
}

/// Whether Safari's WinMux Tabs extension is on and reporting, under Tabs mode's content settings.
struct SafariExtensionSettingsStatus: View {
    @State private var connection: SafariExtensionConnection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Safari Extension Settings…") { SafariExtensionBridge.shared.showInSafari() }.controlSize(.small)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = Task { await refresh() }
        }
    }

    private var summary: String {
        switch connection {
            case .connected(allSites: true):
                "WinMux Tabs is showing Safari tabs' website icons and sound."
            case .connected(allSites: false):
                "WinMux Tabs can't read every website, so some Safari tabs keep Safari's icon. Allow it on every website in Safari."
            case .waiting:
                "WinMux Tabs is on in Safari. Website icons appear once Safari reports its tabs, within a minute."
            case .off, .unavailable, nil:
                "Website icons for Safari tabs come from WinMux Tabs, a Safari extension included with WinMux. Turn it on in Safari's Extensions settings and allow it on every website."
        }
    }

    private func refresh() async {
        connection = await SafariExtensionBridge.shared.connection()
    }
}

/// WinMux Tabs for Chrome: whether it's reporting, and its setup, which runs only when chosen.
struct ChromeExtensionSettingsSetup: View {
    @State private var connected = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(connected
                ? "WinMux Tabs for Chrome is reporting. In each Chrome window where its toolbar button is pinned, WinMux switches tabs through it."
                : "WinMux Tabs for Chrome adds Chrome tabs' host names and lets WinMux switch Chrome tabs through Chrome. Chrome loads it as an unpacked extension.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Set Up Chrome Extension…") { setUp() }.controlSize(.small).disabled(working)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { connected = BrowserTabsModel.shared.chromeExtensionConnected }

    private func setUp() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { ChromeExtensionSetup.presentNextSteps(folder: try await ChromeExtensionSetup.run()) }
            catch { ChromeExtensionSetup.presentFailure(error) }
        }
    }
}

/// Dock, Sidebar and Tabs as three cards. Choosing one switches the live panel.
struct SettingsModePicker: View {
    @ObservedObject var editor: SettingsEditor
    var highlighted = false
    private var field: SettingsField { SettingsCatalog.field(SettingsPanelLayout.modeField) }

    var body: some View {
        let selected = editor.projection.workspaceSidebar.mode
        let live = editor.configuration.workspaceSidebar.mode
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode")
            HStack(spacing: 8) {
                ForEach(WorkspaceSidebarMode.settingsOrder) { mode in
                    let notApplied = mode == selected && mode != live && !editor.isSaving && editor.pendingTabsSwitch == nil
                    Button {
                        editor.setDraft(.text(mode.rawValue), for: field)
                        editor.commit(field)
                    } label: {
                        card(mode, isSelected: mode == selected, notApplied: notApplied)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.settingsTitle) mode")
                    .accessibilityValue(notApplied ? "Not applied" : "")
                    .accessibilityHint(mode.settingsSummary)
                    .accessibilityAddTraits(mode == selected ? .isSelected : [])
                }
            }
            if selected != .tabs {
                Text("Switching to Tabs turns window stacks into separate tabs. Undo restores the setting, not the stacks.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        .disabled(editor.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.\(field.id)")
    }

    private func card(_ mode: WorkspaceSidebarMode, isSelected: Bool, notApplied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: mode.settingsSymbol).font(.title2).frame(height: 28)
            Text(mode.settingsTitle).font(.headline)
            Text(mode.settingsSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if notApplied {
                Label("Not applied", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension WorkspaceSidebarMode {
    var settingsSummary: String {
        switch self {
            case .dock: "Workspace tiles and app icons on a screen edge."
            case .sidebar: "A compact rail that expands into window details."
            case .tabs: "Each workspace is a tab in a browser-style sidebar."
        }
    }
    var settingsSymbol: String {
        switch self {
            case .dock: "dock.rectangle"
            case .sidebar: "sidebar.left"
            case .tabs: "list.bullet.rectangle"
        }
    }
}

/// The rounded group background used by settings pages.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5) }
    }
}
