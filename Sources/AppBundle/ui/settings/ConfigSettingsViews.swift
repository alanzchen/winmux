import SwiftUI
import TOMLKit

struct ShortcutAutomationSettingsView: View {
    @ObservedObject var editor: SettingsEditor
    var targetField: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection("Event actions") {
                        ForEach(SettingsCatalog.automationFields) { field in
                            SettingsMultilineField(field.title, text: Binding(get: { editor.value(field).text },
                                set: { editor.setDraft(.text($0), for: field) }), help: field.help,
                                isDirty: editor.drafts[field.id] != nil) { editor.commit(field) }
                                .id(field.id)
                                .background(targetField == field.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                    Text("Window routing, execution environments, key mappings and monitor assignments remain available in the TOML Editor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(SettingsScrollRetention(page: "advanced.automation", revealingTarget: targetField != nil))
            }
            .onAppear { reveal(proxy) }
            .onChange(of: targetField) { _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let targetField else { return }
        DispatchQueue.main.async { proxy.scrollTo(targetField, anchor: .center) }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: StrokeToken.hairline)
            }
        }
    }
}

private struct SettingsMultilineField: View {
    let title: String
    @Binding var text: String
    let help: String
    let isDirty: Bool
    let save: () -> Void

    init(_ title: String, text: Binding<String>, help: String, isDirty: Bool, save: @escaping () -> Void) {
        self.title = title; _text = text; self.help = help; self.isDirty = isDirty; self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            Text(help).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced)).frame(minHeight: 50)
                .accessibilityLabel(title)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            Button("Apply", action: save).controlSize(.small)
                .accessibilityLabel("Apply \(title)").disabled(!isDirty)
        }.padding(12)
    }
}

@MainActor
func updateSettingsAppearanceConfig(in text: String, section: String?, values: [String: String],
                                    preservingDockAppearance: Bool = false) -> String {
    var preservedValues: [String: String] = [:]
    if preservingDockAppearance {
        // Parse the text read for this save, not values captured when Settings opened.
        // Explicit Dock values remain untouched; only inherited fields need freezing.
        let settings = parseConfig(text).config.workspaceSidebar
        if settings.dockAppearance.style == nil { preservedValues["style"] = "'\(settings.dockChromeStyle.rawValue)'" }
        if settings.dockAppearance.glassOpacity == nil { preservedValues["glass-opacity"] = "\(settings.dockGlassOpacity)" }
        if settings.dockAppearance.solidColor == nil { preservedValues["solid-color"] = "'\(settings.dockSolidColor.rawValue)'" }
        if settings.dockAppearance.customColor == nil { preservedValues["custom-color"] = "'\(settings.dockCustomColor)'" }
    }
    let preserved = preservedValues.sorted(by: { $0.key < $1.key }).reduce(text) { text, entry in
        updateSettingsScalarConfig(in: text, section: "workspace-sidebar.dock-appearance", key: entry.key, renderedValue: entry.value)
    }
    return values.sorted(by: { $0.key < $1.key }).reduce(preserved) { text, entry in
        updateSettingsScalarConfig(in: text, section: section, key: entry.key, renderedValue: entry.value)
    }
}

func updateSettingsScalarConfig(in text: String, section: String?, key: String, renderedValue: String) -> String {
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    // Scan complete TOML statements so text inside a multiline string/array can
    // never be mistaken for another key or a table header.
    var index = 0
    var currentSection: String?
    var insertion = section == nil ? 0 : nil
    var insertionKey = key
    var insertionDepth = 0
    let path = [section, key].compactMap { $0 }.joined(separator: ".")
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { index += 1; continue }
        if line.hasPrefix("[") {
            currentSection = settingsSectionName(in: line) ?? "<array-of-tables>"
            // An explicit child table may precede its parent. Keep the deepest
            // matching table so a later parent cannot redefine that child.
            if let currentSection, currentSection.count > insertionDepth, path.hasPrefix(currentSection + ".") {
                insertion = index + 1
                insertionKey = String(path.dropFirst(currentSection.count + 1))
                insertionDepth = currentSection.count
            }
            index += 1
            continue
        }
        var end = index + 1
        if let equal = settingsAssignmentIndex(in: line) {
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            // Single-line scalars cannot continue. For containers/triple strings,
            // parse only at possible closing delimiters, not every prefix line.
            let delimiter = value.hasPrefix("\"\"\"") ? "\"\"\"" : value.hasPrefix("'''") ? "'''"
                : value.hasPrefix("[") ? "]" : value.hasPrefix("{") ? "}" : nil
            if let delimiter {
                while end < lines.count {
                    if lines[end - 1].contains(delimiter),
                       (try? TOMLTable(string: lines[index..<end].joined(separator: "\n") + "\n")) != nil { break }
                    end += 1
                }
            }
        }
        if let existingKey = settingsKey(in: lines[index]),
           [currentSection, existingKey].compactMap({ $0 }).joined(separator: ".") == [section, key].compactMap({ $0 }).joined(separator: ".") {
            let indent = String(lines[index].prefix(while: { $0.isWhitespace }))
            lines.replaceSubrange(index..<end, with: ["\(indent)\(existingKey) = \(renderedValue)"])
            return lines.joined(separator: newline)
        }
        index = end
    }
    if let insertion {
        lines.insert("\(section == nil ? "" : "    ")\(insertionKey) = \(renderedValue)", at: insertion)
    } else if let section {
        if lines.last?.isEmpty == false { lines.append("") }
        lines.append("[\(section)]")
        lines.append("    \(key) = \(renderedValue)")
    }
    return lines.joined(separator: newline)
}

private func settingsSectionName(in line: String) -> String? {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("["), !line.hasPrefix("[["), let end = line.firstIndex(of: "]") else { return nil }
    let suffix = line[line.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard suffix.isEmpty || suffix.hasPrefix("#") else { return nil }
    let name = line[line.index(after: line.startIndex)..<end]
    return name.split(separator: ".").map { component in
        component.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }.joined(separator: ".")
}

private func settingsKey(in line: String) -> String? {
    let line = line.trimmingCharacters(in: .whitespaces)
    guard !line.hasPrefix("#"), let equal = settingsAssignmentIndex(in: line) else { return nil }
    return String(line[..<equal]).trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}

private func settingsAssignmentIndex(in line: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped { escaped = false; continue }
        if quote == "\"", character == "\\" { escaped = true; continue }
        if let current = quote {
            if character == current { quote = nil }
        } else if character == "\"" || character == "'" { quote = character }
        else if character == "=" { return index }
    }
    return nil
}

func settingsConstantValue(_ value: DynamicConfigValue<Int>) -> Int {
    switch value {
        case .constant(let value): value
        case .perMonitor(_, let `default`): `default`
    }
}
