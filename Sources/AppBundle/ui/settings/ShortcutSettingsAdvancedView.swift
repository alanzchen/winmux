import AppKit
import Common
import MASShortcut
import SwiftUI

@MainActor
final class SettingsConfigDocument: ObservableObject {
    @Published var text = ""
    @Published var validationMessage: String?
    @Published var saveMessage: String?
    var baseline = ""
    var targetUrl: URL?
    var hasLoaded = false
    var isDirty: Bool { text != baseline }

    func loadFromDisk() {
        let persistence = SettingsPersistence()
        let url = persistence.target()
        do {
            let loaded = try persistence.read(url)
            targetUrl = url
            text = loaded
            baseline = loaded
            hasLoaded = true
            validationMessage = nil
            saveMessage = nil
        } catch { validationMessage = error.localizedDescription }
    }
}

struct ShortcutAdvancedView: View {
    @ObservedObject var model: ShortcutSettingsModel
    @ObservedObject var editor: SettingsEditor
    @ObservedObject private var document: SettingsConfigDocument

    init(model: ShortcutSettingsModel, editor: SettingsEditor) {
        self.model = model
        self.editor = editor
        self.document = model.settingsDocument
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TOML Editor").font(.headline)
                if let url = document.targetUrl {
                    Text(url.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(url.path)
                }
                HStack {
                    Button("Reload From Disk") { loadFromDisk() }
                    Button("Validate") { validateConfig() }
                    Button("Save") { saveConfig() }
                        .keyboardShortcut("s", modifiers: [.command])
                        .disabled(editor.isSaving || !document.isDirty)
                    if document.isDirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                }
                .controlSize(.small)
            }
            if let validation = document.validationMessage {
                ScrollView {
                    Text(validation).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            } else if let message = document.saveMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $document.text)
                .accessibilityLabel("TOML configuration")
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .background(SettingsScrollRetention(page: "advanced.editor", textEditor: true))
        }
        .padding(18)
        .task { if !document.hasLoaded || !document.isDirty { loadFromDisk() } }
        .onReceive(NotificationCenter.default.publisher(for: settingsConfigurationDidReload)) { _ in
            if !document.isDirty { loadFromDisk() }
        }
    }

    private func loadFromDisk() { document.loadFromDisk() }

    private func validateConfig() {
        let errors = parseConfig(document.text).errors
        document.validationMessage = errors.isEmpty ? nil : errors.map(\.description).joined(separator: "\n\n")
        document.saveMessage = errors.isEmpty ? "Configuration is valid." : nil
    }

    private func saveConfig() {
        validateConfig()
        guard document.validationMessage == nil else { return }
        let submitted = document.text
        editor.saveDocument(submitted, expected: document.baseline, expectedURL: document.targetUrl) {
            document.baseline = submitted
            document.saveMessage = "Saved and applied."
            model.reload()
        }
    }
}

struct OpenShortcutSettingsButton: View {
    @Environment(\.openWindow) private var openWindow: OpenWindowAction

    var body: some View {
        Button("Settings…") {
            openShortcutSettingsWindow(openWindow)
        }
    }
}

@MainActor
func shortcutSettingsWindow() -> NSWindow? {
    NSApplication.shared.windows.first { $0.identifier?.rawValue == shortcutSettingsWindowId }
}

@MainActor
func presentShortcutSettingsWindow(_ window: NSWindow) {
    configureShortcutSettingsWindow(window)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}

@MainActor
func configureShortcutSettingsWindow(_ window: NSWindow) {
    if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
    // Clear the old fixed frame limits. Use content dimensions so title-bar height
    // does not reduce the space available to controls, and keep the user's frame.
    window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    window.minSize = .zero
    let chromeHeight = max(0, (window.contentView?.frame.height ?? 0) - window.contentLayoutRect.height)
    window.contentMinSize = NSSize(width: shortcutSettingsMinimumSize.width,
                                   height: shortcutSettingsMinimumSize.height + chromeHeight)
}
