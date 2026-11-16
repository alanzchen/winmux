import Foundation

private let workspaceSidebarSectionHeader = "[workspace-sidebar]"
private let workspaceSidebarProjectOrderKey = "project-order"

/// Returns nil, leaving the file alone, when an existing multi-line value has no closing bracket
/// inside the `[workspace-sidebar]` table.
func updateWorkspaceSidebarProjectOrderConfig(in configText: String, order: [String]) -> String? {
    let rendered = "[" + order.map { "\"\(tomlEscape($0))\"" }.joined(separator: ", ") + "]"
    // The value is rewritten on one line; drop the continuation lines of a hand-written multi-line array.
    var config = EditableConfigText(configText)
    var lines = config.lines
    let continuations = tomlMultilineValueContinuations(lines)
    if let section = workspaceSidebarConfigSection(in: lines, continuations: continuations),
       let keyIndex = section.dropFirst().first(where: {
           !continuations.contains($0) && workspaceSidebarConfigKey(in: lines[$0]) == workspaceSidebarProjectOrderKey
       }),
       let equal = settingsAssignmentIndex(in: lines[keyIndex]),
       lines[keyIndex][lines[keyIndex].index(after: equal)...].trimmingCharacters(in: .whitespaces).hasPrefix("[")
    {
        let valueEnd = lines.indices[(keyIndex + 1)...].first { !continuations.contains($0) } ?? lines.endIndex
        // Parsing the complete assignment also handles bracket characters in multi-line ids.
        // An unterminated array may have consumed the next table; never rewrite that input.
        guard WinMuxToml.parses(lines[keyIndex..<valueEnd].joined(separator: "\n")) else {
            return nil
        }
        lines.removeSubrange((keyIndex + 1)..<valueEnd)
    }
    config.lines = lines
    return updateWorkspaceSidebarScalarConfig(in: config.text, key: workspaceSidebarProjectOrderKey,
        renderedValue: rendered)
}

func updateWorkspaceSidebarScalarConfig(
    in configText: String,
    key: String,
    renderedValue: String,
) -> String {
    EditableConfigText.editing(configText) { config in
        let lines = config.lines
        let continuations = tomlMultilineValueContinuations(lines)
        guard let section = workspaceSidebarConfigSection(in: lines, continuations: continuations) else {
            config.appendTable(workspaceSidebarSectionHeader, ["    \(key) = \(renderedValue)"])
            return
        }
        for lineIndex in section.dropFirst() {
            guard !continuations.contains(lineIndex), workspaceSidebarConfigKey(in: lines[lineIndex]) == key else { continue }
            let indentation = String(lines[lineIndex].prefix(while: { $0.isWhitespace }))
            let trailingComment = trailingTomlComment(in: lines[lineIndex]).map { " " + $0 } ?? ""
            config.lines[lineIndex] = "\(indentation)\(key) = \(renderedValue)\(trailingComment)"
            return
        }
        config.lines.insert("    \(key) = \(renderedValue)", at: section.lowerBound + 1)
    }
}

/// Real table boundaries exclude comments and text contained in multi-line values.
private func workspaceSidebarConfigSection(in lines: [String], continuations: Set<Int>) -> Range<Int>? {
    guard let start = lines.indices.first(where: { index in
        guard !continuations.contains(index) else { return false }
        let line = lines[index]
        let text = tomlCommentStart(in: line).map { String(line[..<$0]) } ?? line
        return text.trimmingCharacters(in: .whitespaces) == workspaceSidebarSectionHeader
    }) else { return nil }
    let end = lines.indices[(start + 1)...].first { index in
        guard !continuations.contains(index) else { return false }
        let content = tomlUnquotedContent(lines[index])
        return content.hasPrefix("[") && content.hasSuffix("]")
    } ?? lines.endIndex
    return start..<end
}

@MainActor
func persistWorkspaceSidebarProjectOrder(_ order: [String], targetUrl explicitTargetUrl: URL? = nil, userInitiated: Bool = false) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    guard let updatedText = updateWorkspaceSidebarProjectOrderConfig(in: currentText, order: order) else {
        throw WorkspaceMutationError.unreadableProjectOrder
    }
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl, changing: [["workspace-sidebar", "project-order"]])
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

/// nil removes the display's own width, and the table once it's empty.
func updateWorkspaceSidebarDisplayWidthConfig(in configText: String, display: String, width: Int?) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(
        in: configText,
        sectionHeader: "[workspace-sidebar.display-widths]",
        key: display,
        renderedValue: width.map { "\($0)" },
    )
}

private func updateWorkspaceSidebarKeyValueSectionConfig(
    in configText: String,
    sectionHeader: String,
    key: String,
    value: String?,
    preserveCommentsWhenEmpty: Bool = false,
) -> String {
    updateWorkspaceSidebarKeyValueSectionConfig(in: configText, sectionHeader: sectionHeader, key: key,
        renderedValue: value.map { "\"\(tomlEscape($0))\"" }, preserveCommentsWhenEmpty: preserveCommentsWhenEmpty)
}

private func updateWorkspaceSidebarKeyValueSectionConfig(
    in configText: String,
    sectionHeader: String,
    key: String,
    renderedValue value: String?,
    preserveCommentsWhenEmpty: Bool = false,
) -> String {
    EditableConfigText.editing(configText) { config in
        config.lines = updatedKeyValueSectionLines(config.lines, sectionHeader: sectionHeader, key: key, renderedValue: value,
            preserveCommentsWhenEmpty: preserveCommentsWhenEmpty)
    }
}

private func updatedKeyValueSectionLines(
    _ lines: [String],
    sectionHeader: String,
    key: String,
    renderedValue value: String?,
    preserveCommentsWhenEmpty: Bool,
) -> [String] {
    // Text inside a multi-line value is never a header or a key.
    let continuations = tomlMultilineValueContinuations(lines)
    // A table header may carry a comment, including the next table's: that still ends this one,
    // so its keys are never edited as this table's.
    func isHeader(_ index: Int) -> Bool {
        guard !continuations.contains(index) else { return false }
        let content = tomlUnquotedContent(lines[index])
        return content.hasPrefix("[") && content.hasSuffix("]")
    }
    func isSectionHeader(_ index: Int) -> Bool {
        guard !continuations.contains(index) else { return false }
        let line = lines[index]
        let text = tomlCommentStart(in: line).map { String(line[..<$0]) } ?? line
        return text.trimmingCharacters(in: .whitespaces) == sectionHeader
    }
    guard let sectionIndex = lines.indices.first(where: isSectionHeader) else {
        guard let value else { return lines }
        return EditableConfigText.appendingTable(sectionHeader, [tomlWorkspaceSidebarKeyValueLine(key: key, value: value)], to: lines)
    }

    let sectionEnd = lines.indices[(sectionIndex + 1)...].first(where: isHeader) ?? lines.endIndex

    var resultLines = Array(lines[..<sectionIndex])
    resultLines.append(lines[sectionIndex])

    var wroteValue = false
    var bodyLines: [String] = []
    var hasAnyEntries = false
    var replacing = false
    for index in (sectionIndex + 1)..<sectionEnd {
        let line = lines[index]
        if continuations.contains(index) {
            // The rest of a replaced key's multi-line value goes with it.
            if !replacing { bodyLines.append(line) }
            continue
        }
        replacing = workspaceSidebarLabelKey(in: line) == key
        if replacing {
            if let value, !wroteValue {
                bodyLines.append(tomlWorkspaceSidebarKeyValueLine(key: key, value: value))
                hasAnyEntries = true
                wroteValue = true
            }
            continue
        }
        if workspaceSidebarLabelKey(in: line) != nil { hasAnyEntries = true }
        bodyLines.append(line)
    }
    if let value, !wroteValue {
        bodyLines.append(tomlWorkspaceSidebarKeyValueLine(key: key, value: value))
        hasAnyEntries = true
    }

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
    return resultLines
}

@MainActor
func persistWorkspaceSidebarLabel(
    workspaceName: String,
    label: String?,
    targetUrl explicitTargetUrl: URL? = nil,
    userInitiated: Bool = false,
) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarLabelConfig(
        in: currentText,
        workspaceName: workspaceName,
        label: label,
    )
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl, changing: [["workspace-sidebar", "workspace-labels", workspaceName]])
}

@MainActor
func persistWorkspaceSidebarProjectLabel(
    projectId: String,
    label: String?,
    targetUrl explicitTargetUrl: URL? = nil,
    userInitiated: Bool = false,
) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectLabelConfig(
        in: currentText,
        projectId: projectId,
        label: label,
    )
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl, changing: [["workspace-sidebar", "project-labels", projectId]])
}

@MainActor
func persistWorkspaceSidebarProjectColor(
    projectId: String,
    colorHex: String?,
    targetUrl explicitTargetUrl: URL? = nil,
    userInitiated: Bool = false,
) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectColorConfig(
        in: currentText,
        projectId: projectId,
        colorHex: colorHex,
    )
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl, changing: [["workspace-sidebar", "project-colors", projectId]])
}

@MainActor
func persistWorkspaceSidebarProjectMetadata(
    projectId: String,
    label: String?,
    colorHex: String?,
    emoji: String?,
    targetUrl explicitTargetUrl: URL? = nil,
    userInitiated: Bool = false,
) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
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
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl, changing: ["project-labels", "project-colors", "project-emojis"].map { ["workspace-sidebar", $0, projectId] })
}

@MainActor
func persistWorkspaceSidebarProjectEmoji(
    projectId: String,
    emoji: String?,
    targetUrl explicitTargetUrl: URL? = nil,
    userInitiated: Bool = false,
) throws {
    // D-S3-1: automatic write-back waits for a config without errors; explicit edits still go through the validated writer.
    guard userInitiated || !configWriteBackSuspended else { return }
    let targetUrl = explicitTargetUrl ?? preferredWorkspaceSidebarConfigUrl()
    let currentText = try readWorkspaceSidebarConfig(at: targetUrl, contentsWhenMissing: "")
    let updatedText = updateWorkspaceSidebarProjectEmojiConfig(in: currentText, projectId: projectId, emoji: emoji)
    try writeConfigFile(updatedText, replacing: currentText, at: targetUrl,
        changing: [["workspace-sidebar", "project-emojis", projectId]])
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

/// The indices of lines that continue a value begun on an earlier line: a multi-line string,
/// array or inline table. Like the Settings writer, the TOML parser decides where the value
/// ends, so escaped and doubled quotes inside it can't end it early.
func tomlMultilineValueContinuations(_ lines: [String]) -> Set<Int> {
    var result: Set<Int> = []
    var index = 0
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let end = line.hasPrefix("[") || line.hasPrefix("#") ? index + 1 : tomlStatementEnd(lines, from: index)
        result.formUnion((index + 1)..<end)
        index = end
    }
    return result
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
    "\"\(tomlEscape(key))\" = \(value)"
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
