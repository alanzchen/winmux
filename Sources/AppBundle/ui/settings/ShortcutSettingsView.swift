import AppKit
import Common
import MASShortcut
import SwiftUI

public let shortcutSettingsWindowId = "\(winMuxAppName).shortcutSettings"
let shortcutSettingsDefaultSize = CGSize(width: 760, height: 620)
let shortcutSettingsMinimumSize = CGSize(width: 700, height: 480)

@MainActor
public func getShortcutSettingsWindow(model: ShortcutSettingsModel) -> some Scene {
    SwiftUI.Window("WinMux Settings", id: shortcutSettingsWindowId) {
        ShortcutSettingsView(model: model)
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
            }
    }
    .defaultSize(width: shortcutSettingsDefaultSize.width, height: shortcutSettingsDefaultSize.height)
    .defaultPosition(.center)
    .windowResizability(.contentMinSize)
}

@MainActor
public func openShortcutSettingsWindow(_ openWindow: OpenWindowAction) {
    ShortcutSettingsModel.shared.reload()
    if let existingWindow = shortcutSettingsWindow() {
        presentShortcutSettingsWindow(existingWindow)
    } else {
        openWindow(id: shortcutSettingsWindowId)
        DispatchQueue.main.async {
            if let createdWindow = shortcutSettingsWindow() {
                presentShortcutSettingsWindow(createdWindow)
            }
        }
    }
}

enum SettingsSidebarItem: String, Hashable, Identifiable, CaseIterable {
    case general, appearance, behavior, workspaces, shortcuts, configuration, reference
    static let navigation: [Self] = [.general, .appearance, .behavior, .workspaces, .shortcuts, .configuration]
    var id: Self { self }
    var label: String {
        switch self {
            case .general: "General"
            case .appearance: "Dock & Sidebar"
            case .behavior: "Windows & Layout"
            case .workspaces: "Projects & Workspaces"
            case .shortcuts: "Shortcuts"
            case .configuration: "Advanced"
            case .reference: "Configuration Reference"
        }
    }
    var icon: String {
        switch self {
            case .general: "gearshape"
            case .appearance: "sidebar.left"
            case .behavior: "macwindow.on.rectangle"
            case .workspaces: "rectangle.3.group"
            case .shortcuts: "keyboard"
            case .configuration: "slider.horizontal.3"
            case .reference: "book"
        }
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @StateObject private var editor = SettingsEditor()
    @State private var selectedItem: SettingsSidebarItem?
    @State private var query = ""
    @State private var searchTarget: SearchTarget?
    @AppStorage("WinMux.settings.lastPane") private var lastPane = SettingsSidebarItem.general.rawValue
    @AppStorage("WinMux.settings.advancedTab") private var advancedTab = "editor"
    private var targetField: String? { searchTarget?.field }
    private struct SearchTarget {
        let page: SettingsSidebarItem
        let field: String
        var tab: String?
    }

    init(model: ShortcutSettingsModel, selectedItem: SettingsSidebarItem? = nil) {
        self.model = model
        _selectedItem = State(initialValue: selectedItem ?? model.requestedSettingsPage
            ?? UserDefaults.standard.string(forKey: "WinMux.settings.lastPane").flatMap(SettingsSidebarItem.init(rawValue:)) ?? .general)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedItem) {
                ForEach(SettingsSidebarItem.navigation) { item in
                    NavigationLink(value: item) { Label(item.label, systemImage: item.icon) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pane
                } else { searchResults }
                Divider()
                SettingsSaveFeedback(editor: editor, model: model)
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selectedItem?.label ?? "WinMux Settings")
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search settings")
        .frame(minWidth: shortcutSettingsMinimumSize.width, maxWidth: .infinity,
               minHeight: shortcutSettingsMinimumSize.height, maxHeight: .infinity)
        .onChange(of: selectedItem) { next in
            if let next { lastPane = next.rawValue }
            query = ""
            if next != searchTarget?.page { searchTarget = nil }
        }
        .onChange(of: query) { next in if !next.isEmpty { searchTarget = nil } }
        .onChange(of: advancedTab) { next in
            if searchTarget?.page == .configuration && next != searchTarget?.tab { searchTarget = nil }
        }
        .onChange(of: model.openRequestId) { _ in consumeRequestedPage() }
        .onAppear { consumeRequestedPage() }
        .onReceive(NotificationCenter.default.publisher(for: settingsConfigurationDidReload)) { _ in
            editor.synchronize(config)
            model.reload()
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selectedItem {
            case .general, .appearance, .behavior, .workspaces:
                SettingsForm(page: selectedItem ?? .general, editor: editor, model: model, targetField: targetField)
                    .id(selectedItem)
            case .shortcuts: ShortcutSettingsShortcutsView(model: model)
            case .configuration: SettingsAdvancedPane(model: model, editor: editor, tab: $advancedTab, targetField: targetField)
            case .reference: ShortcutConfigurationReferenceView()
            case nil: Text("Select a settings page")
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let matches = SettingsCatalog.results(query)
                if matches.isEmpty && !matchesPage("shortcuts keyboard bindings permissions accessibility screen recording debug performance logs diagnostics automation toml configuration reference") {
                    Label("No matching settings", systemImage: "magnifyingglass").font(.headline)
                    Text("Try a name such as opacity, magnification, clock, or a TOML key.").foregroundStyle(.secondary)
                }
                ForEach(matches) { field in
                    Button {
                        openSearchTarget(page: field.group.page, field: field.id,
                            tab: field.group == .automation ? "automation" : nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.title).font(.headline)
                            Text("\(field.group.page.label) › \(field.group.title)").font(.caption).foregroundStyle(.secondary)
                            Text(field.help).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .buttonStyle(.plain)
                }
                if matchesPage("shortcuts keyboard bindings") {
                    Button("Open keyboard shortcuts") { selectedItem = .shortcuts; query = "" }
                }
                if matchesPage("permissions accessibility screen recording") {
                    Button("Open permissions") {
                        openSearchTarget(page: .general, field: "permissions")
                    }
                }
                ForEach([("diagnostics", "Diagnostics", "debug performance logs diagnostics"),
                         ("automation", "Automation", "automation events actions"),
                         ("editor", "TOML Editor", "toml configuration editor"),
                         ("reference", "Configuration Reference", "reference rules integration")], id: \.0) { tab, title, keywords in
                    if matchesPage(keywords) {
                        Button("Open \(title)") { advancedTab = tab; selectedItem = .configuration; query = "" }
                    }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func matchesPage(_ keywords: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { keywords.localizedStandardContains(String($0)) }
    }

    private func openSearchTarget(page: SettingsSidebarItem, field: String, tab: String? = nil) {
        // Publish the target in the same update as the page, before its scroll
        // bridge mounts. Search navigation never first restores the old offset.
        searchTarget = SearchTarget(page: page, field: field, tab: tab)
        if let tab { advancedTab = tab }
        selectedItem = page
        query = ""
    }

    private func consumeRequestedPage() {
        guard let page = model.requestedSettingsPage else { return }
        searchTarget = nil
        selectedItem = page
        model.requestedSettingsPage = nil
        query = ""
    }
}

struct SettingsAdvancedPane: View {
    @ObservedObject var model: ShortcutSettingsModel
    @ObservedObject var editor: SettingsEditor
    @Binding var tab: String
    var targetField: String?
    var body: some View {
        VStack(spacing: 0) {
            Picker("Advanced section", selection: $tab) {
                Text("TOML Editor").tag("editor")
                Text("Automation").tag("automation")
                Text("Diagnostics").tag("diagnostics")
                Text("Reference").tag("reference")
            }
            .pickerStyle(.segmented).padding(16)
            switch tab {
                case "automation": ShortcutAutomationSettingsView(editor: editor, targetField: targetField)
                case "diagnostics": ScrollView {
                    DockPerformanceSettingsView().padding(20)
                        .background(SettingsScrollRetention(page: "advanced.diagnostics"))
                }
                case "reference": ShortcutConfigurationReferenceView()
                default: ShortcutAdvancedView(model: model, editor: editor)
            }
        }
    }
}

struct ShortcutSettingsShortcutsView: View {
    @ObservedObject var model: ShortcutSettingsModel

    var body: some View {
        ShortcutCategoryView(model: model, category: .managed)
    }
}

struct ShortcutSettingsWorkspacePane: View {
    @ObservedObject var model: ShortcutSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.sections.filter { $0.category == .common }) { section in
                ShortcutSectionView(model: model, section: section)
            }
        }
    }
}

struct ShortcutCategoryView: View {
    @ObservedObject var model: ShortcutSettingsModel
    let category: ShortcutSettingsModel.Category

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.white)
                        .padding()
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                let sections = model.sections.filter { $0.category == category && $0.id != "managed-move" }
                ForEach(sections) { section in
                    ShortcutSectionView(model: model, section: section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(SettingsScrollRetention(page: "shortcuts.\(category)"))
        }
    }
}

struct ShortcutSectionView: View {
    @ObservedObject var model: ShortcutSettingsModel
    let section: ShortcutSettingsModel.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if section.id != "managed-focus" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.headline)
                    if let summary = section.summary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if section.id == "managed-focus" {
                ManagedDirectionalShortcutsView(model: model)
            } else if section.id == "managed-move" {
                EmptyView()
            } else if section.id == "managed-splits" {
                CompassPad(model: model, title: "Split", prefix: "split") {
                    SplitDemoView()
                }
            } else if section.id == "workspaces" {
                WorkspaceShortcutSectionView(model: model)
            } else {
                VStack(spacing: 0) {
                    ForEach(section.actions.indices, id: \.self) { index in
                        let action = section.actions[index]
                        ShortcutRow(model: model, action: action)
                        if index < section.actions.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct ShortcutRow: View {
    @ObservedObject var model: ShortcutSettingsModel
    let action: ShortcutSettingsModel.Action

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(
                shortcut: .init(get: { model.shortcutValue(for: action.id) },
                                set: { model.setShortcutValue($0, for: action.id) }),
                onChange: { _ in }
            )
            .frame(width: 140, height: 22)
        }
        .padding(.vertical, 6)
    }
}
