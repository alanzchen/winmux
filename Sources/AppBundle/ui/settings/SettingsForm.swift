import AppKit
import SwiftUI

struct SettingsForm: View {
    let page: SettingsSidebarItem
    @ObservedObject var editor: SettingsEditor
    @ObservedObject var model: ShortcutSettingsModel
    var targetField: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    let layout = page == .appearance && geometry.size.width >= 880
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                    layout {
                        if page == .appearance {
                            SettingsDockPreview(editor: editor)
                                .frame(width: geometry.size.width >= 880 ? 280 : nil)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(SettingsGroup.allCases.filter { $0.page == page }) { group in
                                groupView(group)
                                    .id(group.rawValue)

                            }
                            if page == .general { SettingsPermissionsView().id("permissions") }
                            if page == .workspaces { ShortcutSettingsWorkspacePane(model: model) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                    .background(SettingsScrollRetention(page: page.rawValue, revealingTarget: targetField != nil))
                }
                .coordinateSpace(name: "settingsScroll")
                .onChange(of: targetField) { target in reveal(target, proxy: proxy) }
                .onAppear { reveal(targetField, proxy: proxy) }
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: SettingsGroup) -> some View {
        let fields = SettingsCatalog.fields.filter { $0.group == group && ($0.visible(editor) || $0.id == targetField) }
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(group.title).font(.headline)
                    Spacer()
                    Menu {
                        Button("Restore Defaults") { editor.reset(group) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Options for \(group.title)")
                    .disabled(editor.isSaving)
                }
                VStack(spacing: 0) {
                    ForEach(fields) { field in
                        SettingsFieldRow(field: field, editor: editor, highlighted: field.id == targetField)
                            .id(field.id)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5) }
            }
        }
    }

    private func reveal(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
}

struct SettingsFieldRow: View {
    let field: SettingsField
    @ObservedObject var editor: SettingsEditor
    var highlighted = false
    @State private var isDragging = false
    @State private var colorSave: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: SettingsValue { editor.value(field) }
    private var unavailable: String? {
        if !field.visible(editor) { return SettingsCatalog.visibilityHint(for: field, editor: editor) }
        return field.unavailableReason(editor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch field.control {
                case .toggle:
                    Toggle(field.title, isOn: Binding(get: { current.bool }, set: { change(.bool($0), commit: true) }))
                        .toggleStyle(.switch).controlSize(.small)
                case .position: positionPicker
                case .choice(let options):
                    HStack {
                        Text(field.title).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Picker(field.title, selection: Binding(get: { current.text }, set: { change(.text($0), commit: true) })) {
                            ForEach(options) { option in
                                HStack {
                                    if field.key.contains("color"), let color = ChromeSolidColor(rawValue: option.value) {
                                        Circle().fill(color.color).frame(width: 10, height: 10)
                                    }
                                    Text(option.title)
                                }.tag(option.value)
                            }
                        }
                        .labelsHidden().frame(maxWidth: 185).accessibilityLabel(field.title)
                    }
                case .integer(let range): numberControl(range: Double(range.lowerBound)...Double(range.upperBound), integer: true)
                case .percentage, .magnification: numberControl(range: 0...1, integer: false)
                case .text:
                    Text(field.title)
                    HStack {
                        TextField(field.title, text: Binding(get: { current.text }, set: { change(.text($0), commit: false) }))
                            .textFieldStyle(.roundedBorder).onSubmit { editor.commit(field) }
                        Button("Apply") { editor.commit(field) }.disabled(editor.drafts[field.id] == nil)
                    }
                case .color:
                    ColorPicker(field.title, selection: Binding(get: { Color(chromeHex: current.text) },
                        set: { color in
                            change(.text(color.chromeHex), commit: false)
                            colorSave?.cancel()
                            colorSave = Task { @MainActor in
                                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                                editor.commit(field)
                            }
                        }), supportsOpacity: false)
            }
            Text(unavailable ?? field.help)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if reduceMotion, field.key.hasPrefix("dock-magnification") {
                Text("macOS Reduce Motion is on, so magnification is currently paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.id == "workspace-sidebar.dock-icon-size" {
                SettingsEffectiveDockSize(maximum: current.integer)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(unavailable != nil)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.\(field.id)")
        .onDisappear {
            colorSave?.cancel()
            if case .color = field.control { editor.commit(field) }
            if isDragging { editor.commit(field) }
        }
    }

    private var positionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.title)
            HStack(spacing: 8) {
                ForEach(WorkspaceDockPosition.allCases) { position in
                    Button { change(.text(position.rawValue), commit: true) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: position == .left ? "sidebar.left" : position == .right ? "sidebar.right" : "rectangle.bottomthird.inset.filled")
                                .font(.title3)
                            Text(position.rawValue.capitalized)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(current.text == position.rawValue ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dock position: \(position.rawValue)")
                    .accessibilityAddTraits(current.text == position.rawValue ? .isSelected : [])
                }
            }
        }
    }

    private func numberControl(range: ClosedRange<Double>, integer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.title)
                Spacer()
                if case .magnification = field.control {
                    Text(magnificationLabel).monospacedDigit()
                } else if integer {
                    Text("\(current.integer) pt").monospacedDigit()
                } else {
                    Text("\(Int((current.number * 100).rounded()))%").monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                Slider(value: Binding(get: { current.number }, set: { value in
                    change(integer ? .integer(Int(value.rounded())) : .number(value), commit: !isDragging)
                }), in: range, step: integer ? 1 : 0.01) { editing in
                    isDragging = editing
                    if !editing { editor.commit(field) }
                }
                .accessibilityLabel(field.title)
                .accessibilityValue(accessibleNumber(integer: integer))
                Stepper(field.title, onIncrement: { step(integer ? 1 : 0.01, range: range, integer: integer) },
                    onDecrement: { step(integer ? -1 : -0.01, range: range, integer: integer) })
                    .labelsHidden().controlSize(.small)
                    .accessibilityLabel(field.title)
                    .accessibilityValue(accessibleNumber(integer: integer))
            }
        }
    }

    private var magnificationLabel: String { (1 + current.number).formatted(.number.precision(.fractionLength(0...2))) + "×" }

    private func accessibleNumber(integer: Bool) -> String {
        if case .magnification = field.control { return magnificationLabel }
        return integer ? "\(current.integer) points" : "\(Int((current.number * 100).rounded())) percent"
    }

    private func step(_ delta: Double, range: ClosedRange<Double>, integer: Bool) {
        let value = min(max(current.number + delta, range.lowerBound), range.upperBound)
        change(integer ? .integer(Int(value.rounded())) : .number(value), commit: true)
    }

    private func change(_ value: SettingsValue, commit: Bool) {
        if case .number(let number) = value { editor.setDraft(.number((number * 100).rounded() / 100), for: field) }
        else { editor.setDraft(value, for: field) }
        if commit { editor.commit(field) }
    }
}

private struct SettingsEffectiveDockSize: View {
    let maximum: Int
    var body: some View {
        // Sample only while this settings row is visible, never on Dock animation frames.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sizes = WorkspaceSidebarPanel.visiblePanels.compactMap(\.fittedDockRestingWidth)
                .map { Int(($0 * CGFloat(WorkspaceSidebarConfig.defaultDockIconSize) / CGFloat(WorkspaceSidebarConfig.dockCompactWidth)).rounded()) }
            if let minimum = sizes.min(), minimum < maximum {
                Text("Current fitted size: \(minimum) pt\(sizes.min() == sizes.max() ? "" : " on the most crowded display")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsSaveFeedback: View {
    @ObservedObject var editor: SettingsEditor
    @ObservedObject var model: ShortcutSettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = editor.error ?? model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(3).help(message)
                HStack {
                    if editor.error != nil {
                        if editor.canRetry { Button("Retry") { editor.retry() } }
                        Button("Revert unsaved changes") {
                            let revertDocument = editor.hasPendingDocument
                            editor.revertDrafts()
                            if revertDocument { model.settingsDocument.loadFromDisk() }
                        }
                    } else { Button("Dismiss") { model.errorMessage = nil } }
                }
                .disabled(editor.isSaving)
            } else {
                HStack {
                    if editor.isSaving { ProgressView().controlSize(.small) }
                    Text(!editor.isSaving && !editor.drafts.isEmpty ? "Unsaved changes" : editor.status)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let title = editor.undoTitle {
                        Button(title) { editor.undo() }.disabled(editor.isSaving || !editor.drafts.isEmpty)
                            .help(editor.drafts.isEmpty ? title : "Apply or revert unsaved changes to undo")
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsPermissionsView: View {
    @StateObject private var recording = ScreenRecordingPermissionModel()
    var body: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Accessibility is required to manage windows. Screen Recording is optional and enables the double-sided window animation.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(recording.isGranted ? "Screen Recording: allowed" : "Screen Recording: not enabled")
                HStack {
                    if !recording.isGranted && !recording.didRequest {
                        Button("Allow Screen Recording…") { recording.requestFromSettings() }
                    }
                    Button("Accessibility Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }
                }
                Button("Screen Recording Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { recording.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recording.refresh() }
    }
}
