import Foundation

private let workspaceSidebarSectionHeader = "[workspace-sidebar]"
private let workspaceSidebarMenuBarReserveKey = "menu-bar-reserve-height"
private let workspaceSidebarProjectDeletionActionKey = "project-deletion-action"
private let workspaceSidebarProjectOrderKey = "project-order"

func updateWorkspaceSidebarMenuBarReserveConfig(
    in configText: String,
    height: Int,
) -> String {
    updateWorkspaceSidebarScalarConfig(
        in: configText,
        key: workspaceSidebarMenuBarReserveKey,
        renderedValue: "\(height)",
    )
}

func updateWorkspaceSidebarProjectDeletionActionConfig(
    in configText: String,
    action: WorkspaceProjectDeletionAction,
) -> String {
    updateWorkspaceSidebarScalarConfig(
        in: configText,
        key: workspaceSidebarProjectDeletionActionKey,
        renderedValue: "'\(action.rawValue)'",
    )
}

/// Returns nil, leaving the file alone, when an existing multi-line value has no closing bracket
/// inside the `[workspace-sidebar]` table.
func updateWorkspaceSidebarProjectOrderConfig(in configText: String, order: [String]) -> String? {
    let rendered = "[" + order.map { "\"\(tomlEscape($0))\"" }.joined(separator: ", ") + "]"
    // The value is rewritten on one line; drop the continuation lines of a hand-written multi-line array.
    var lines = configText.components(separatedBy: "\n")
    // Brackets inside quoted ids or comments do not open or close the list.
    func content(_ line: String) -> String { tomlUnquotedContent(line) }
    if let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == workspaceSidebarSectionHeader }) {
        // A table header may carry a comment; it still ends the table.
        let section = lines[(sectionIndex + 1)...].prefix { line in
            let header = content(line)
            return !(header.hasPrefix("[") && header.hasSuffix("]"))
        }
        if let keyIndex = section.firstIndex(where: { workspaceSidebarConfigKey(in: $0) == workspaceSidebarProjectOrderKey }),
           let value = content(lines[keyIndex]).split(separator: "=", maxSplits: 1).last,
           value.contains("["), !value.contains("]")
        {
            guard let closingIndex = section[(keyIndex + 1)...].firstIndex(where: { content($0).contains("]") }) else {
                return nil
            }
            lines.removeSubrange((keyIndex + 1)...closingIndex)
        }
    }
    return updateWorkspaceSidebarScalarConfig(in: lines.joined(separator: "\n"), key: workspaceSidebarProjectOrderKey,
        renderedValue: rendered)
}

private func updateWorkspaceSidebarScalarConfig(
    in configText: String,
    key: String,
    renderedValue: String,
) -> String {
    let lines = configText.components(separatedBy: "\n")
    guard let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == workspaceSidebarSectionHeader }) else {
        var result = configText
        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        if !result.isEmpty {
            result += "\n"
        }
        result += "\(workspaceSidebarSectionHeader)\n"
        result += "    \(key) = \(renderedValue)"
        return result
    }

    let sectionEnd = lines[(sectionIndex + 1)...]
        .firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }) ?? lines.endIndex

    var resultLines = lines
    for lineIndex in (sectionIndex + 1)..<sectionEnd {
        guard workspaceSidebarConfigKey(in: resultLines[lineIndex]) == key else { continue }
        let indentation = String(resultLines[lineIndex].prefix(while: { $0.isWhitespace }))
        let trailingComment = trailingTomlComment(in: resultLines[lineIndex]).map { " " + $0 } ?? ""
        resultLines[lineIndex] = "\(indentation)\(key) = \(renderedValue)\(trailingComment)"
        return resultLines.joined(separator: "\n")
    }

    resultLines.insert("    \(key) = \(renderedValue)", at: sectionIndex + 1)
    return resultLines.joined(separator: "\n")
}

@MainActor
func persistWorkspaceSidebarMenuBarReserveHeight(_ height: Int, targetUrl explicitTargetUrl: URL? = nil) throws -> URL {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(
        at: targetUrl,
        contentsWhenMissing: starterConfigText(),
    )
    let updatedText = updateWorkspaceSidebarMenuBarReserveConfig(in: currentText, height: height)
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
    return targetUrl
}

@MainActor
func persistWorkspaceSidebarProjectOrder(_ order: [String], targetUrl explicitTargetUrl: URL? = nil) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    guard let updatedText = updateWorkspaceSidebarProjectOrderConfig(in: currentText, order: order) else {
        throw WorkspaceMutationError.unreadableProjectOrder
    }
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
func persistWorkspaceSidebarProjectDeletionAction(
    _ action: WorkspaceProjectDeletionAction,
    targetUrl explicitTargetUrl: URL? = nil,
) throws -> URL {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(
        at: targetUrl,
        contentsWhenMissing: starterConfigText(),
    )
    let updatedText = updateWorkspaceSidebarProjectDeletionActionConfig(in: currentText, action: action)
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
    return targetUrl
}

func updateWorkspaceSidebarLabelConfig(
    in configText: String,
    workspaceName: String,
    label: String?,
) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(
        in: configText,
        sectionHeader: "[workspace-sidebar.workspace-labels]",
        key: workspaceName,
        value: label,
    )
}

func updateWorkspaceSidebarProjectLabelConfig(
    in configText: String,
    projectId: String,
    label: String?,
) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(
        in: configText,
        sectionHeader: "[workspace-sidebar.project-labels]",
        key: projectId,
        value: label,
    )
}

func updateWorkspaceSidebarProjectColorConfig(
    in configText: String,
    projectId: String,
    colorHex: String?,
) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(
        in: configText,
        sectionHeader: "[workspace-sidebar.project-colors]",
        key: projectId,
        value: colorHex,
    )
}

func updateWorkspaceSidebarProjectEmojiConfig(
    in configText: String,
    projectId: String,
    emoji: String?,
) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(
        in: configText,
        sectionHeader: "[workspace-sidebar.project-emojis]",
        key: projectId,
        value: emoji,
        preserveCommentsWhenEmpty: true,
    )
}

private func updateWorkspaceSidebarKeyValueSectionConfig(
    in configText: String,
    sectionHeader: String,
    key: String,
    value: String?,
    preserveCommentsWhenEmpty: Bool = false,
) -> String {
    let lines = configText.components(separatedBy: "\n")
    guard let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sectionHeader }) else {
        guard let value else { return configText }
        var result = configText
        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        if !result.isEmpty {
            result += "\n"
        }
        result += "\(sectionHeader)\n"
        result += tomlWorkspaceSidebarKeyValueLine(key: key, value: value)
        return result
    }

    let sectionEnd = lines[(sectionIndex + 1)...]
        .firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }) ?? lines.endIndex

    var resultLines = Array(lines[..<sectionIndex])
    resultLines.append(lines[sectionIndex])

    var wroteValue = false
    var bodyLines: [String] = []
    for line in lines[(sectionIndex + 1)..<sectionEnd] {
        if workspaceSidebarLabelKey(in: line) == key {
            if let value, !wroteValue {
                bodyLines.append(tomlWorkspaceSidebarKeyValueLine(key: key, value: value))
                wroteValue = true
            }
            continue
        }
        bodyLines.append(line)
    }
    if let value, !wroteValue {
        bodyLines.append(tomlWorkspaceSidebarKeyValueLine(key: key, value: value))
    }

    let hasAnyEntries = bodyLines.contains(where: { workspaceSidebarLabelKey(in: $0) != nil })
    let hasComments = bodyLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    if hasAnyEntries || (preserveCommentsWhenEmpty && hasComments) {
        resultLines.append(contentsOf: bodyLines)
    } else {
        resultLines.removeLast()
        if !resultLines.isEmpty, resultLines.last?.isEmpty == false {
            resultLines.append("")
        }
    }
    resultLines.append(contentsOf: lines[sectionEnd...])
    return resultLines.joined(separator: "\n")
}

@MainActor
func persistWorkspaceSidebarLabel(
    workspaceName: String,
    label: String?,
    targetUrl explicitTargetUrl: URL? = nil,
) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarLabelConfig(
        in: currentText,
        workspaceName: workspaceName,
        label: label,
    )
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
func persistWorkspaceSidebarProjectLabel(
    projectId: String,
    label: String?,
    targetUrl explicitTargetUrl: URL? = nil,
) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectLabelConfig(
        in: currentText,
        projectId: projectId,
        label: label,
    )
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
func persistWorkspaceSidebarProjectColor(
    projectId: String,
    colorHex: String?,
    targetUrl explicitTargetUrl: URL? = nil,
) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectColorConfig(
        in: currentText,
        projectId: projectId,
        colorHex: colorHex,
    )
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
func persistWorkspaceSidebarProjectMetadata(
    projectId: String,
    label: String?,
    colorHex: String?,
    emoji: String?,
    targetUrl explicitTargetUrl: URL? = nil,
) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let textWithLabel = updateWorkspaceSidebarProjectLabelConfig(
        in: currentText,
        projectId: projectId,
        label: label,
    )
    let textWithColor = updateWorkspaceSidebarProjectColorConfig(
        in: textWithLabel,
        projectId: projectId,
        colorHex: colorHex,
    )
    let updatedText = updateWorkspaceSidebarProjectEmojiConfig(
        in: textWithColor,
        projectId: projectId,
        emoji: emoji,
    )
    if let parent = targetUrl.deletingLastPathComponent().takeIf({ $0.path != targetUrl.path }) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
func persistWorkspaceSidebarProjectEmoji(
    projectId: String,
    emoji: String?,
    targetUrl explicitTargetUrl: URL? = nil,
) throws {
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectEmojiConfig(in: currentText, projectId: projectId, emoji: emoji)
    try FileManager.default.createDirectory(at: targetUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
    try updatedText.write(to: targetUrl, atomically: true, encoding: .utf8)
}

@MainActor
private func preferredWorkspaceSidebarConfigUrl() -> URL {
    preferredEditableConfigUrl()
}

private func readWorkspaceSidebarConfig(at targetUrl: URL, contentsWhenMissing: @autoclosure () -> String) throws -> String {
    do {
        return try String(contentsOf: targetUrl, encoding: .utf8)
    } catch {
        let cocoaError = error as NSError
        guard cocoaError.domain == NSCocoaErrorDomain,
              cocoaError.code == NSFileReadNoSuchFileError
        else {
            throw error
        }
        return contentsWhenMissing()
    }
}

private func workspaceSidebarLabelKey(in line: String) -> String? {
    workspaceSidebarConfigKey(in: line)
}

private func workspaceSidebarConfigKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    if key.hasPrefix("'"), key.hasSuffix("'"), key.count >= 2 {
        return String(key.dropFirst().dropLast())
    }
    if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
        let inner = key.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
    return String(key)
}

private func trailingTomlComment(in line: String) -> String? {
    guard let hashIndex = tomlCommentStart(in: line) else { return nil }
    return String(line[hashIndex...]).trimmingCharacters(in: .whitespaces)
}

/// Where a line's comment starts, skipping `#` inside quoted strings. A line whose quote never
/// closes is not valid TOML; its first `#` is kept as the comment, as before.
private func tomlCommentStart(in line: String) -> String.Index? {
    let scan = tomlScan(line)
    return scan.commentStart ?? (scan.endsInsideQuote ? line.firstIndex(of: "#") : nil)
}

/// A line's text outside quoted strings and its comment.
private func tomlUnquotedContent(_ line: String) -> String {
    tomlScan(line).unquoted.trimmingCharacters(in: .whitespaces)
}

private func tomlScan(_ line: String) -> (unquoted: String, commentStart: String.Index?, endsInsideQuote: Bool) {
    var quote: Character?
    var escaped = false
    var unquoted = ""
    for index in line.indices {
        let character = line[index]
        if let open = quote {
            if escaped {
                escaped = false
            } else if character == "\\", open == "\"" {
                escaped = true
            } else if character == open {
                quote = nil
            }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "#" {
            return (unquoted, index, false)
        } else {
            unquoted.append(character)
        }
    }
    return (unquoted, nil, quote != nil)
}

private func tomlWorkspaceSidebarKeyValueLine(key: String, value: String) -> String {
    "\"\(tomlEscape(key))\" = \"\(tomlEscape(value))\""
}

func tomlEscape(_ raw: String) -> String {
    raw.unicodeScalars.map { scalar in
        switch scalar.value {
            case 0x08: "\\b"
            case 0x09: "\\t"
            case 0x0A: "\\n"
            case 0x0C: "\\f"
            case 0x0D: "\\r"
            case 0x22: "\\\""
            case 0x5C: "\\\\"
            case 0x00 ... 0x1F, 0x7F ... 0x9F:
                String(format: "\\u%04X", scalar.value)
            default:
                String(scalar)
        }
    }.joined()
}
