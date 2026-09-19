import Foundation
import TOMLKit

private let workspaceSidebarParser: [String: any ParserProtocol<WorkspaceSidebarConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "enable-focus": Parser(\.enableFocus, parseBool),
    "stay-on-top": Parser(\.stayOnTop, parseBool),
    "auto-hide": Parser(\.autoHide, parseBool),
    "always-expanded": Parser(\.alwaysExpanded, parseBool),
    "mode": Parser(\.mode, parseWorkspaceSidebarMode),
    "show-app-icons": Parser(\.showAppIcons, parseBool),
    "show-app-badges": Parser(\.showAppBadges, parseBool),
    "dock-magnification": Parser(\.dockMagnification, parseBool),
    "dock-magnification-amount": Parser(\.dockMagnificationAmount, parseWorkspaceSidebarUnitInterval),
    "dock-icon-size": Parser(\.dockIconSize) { raw, backtrace in
        parseInt(raw, backtrace).filter(.semantic(backtrace, "Must be between 24 and 48 points")) { (24...48).contains($0) }
    },
    "dock-position": Parser(\.dockPosition) { raw, backtrace in
        parseString(raw, backtrace).flatMap { value in
            WorkspaceDockPosition(rawValue: value).orFailure(.semantic(backtrace, "Possible values: left, bottom, right"))
        }
    },
    "dock-left-gap": Parser(\.dockLeftGap) { raw, backtrace in
        parseInt(raw, backtrace).filter(.semantic(backtrace, "Must be between 0 and 24 points")) { (0...24).contains($0) }
    },
    "collapsed-width": Parser(\.collapsedWidth, parseWorkspaceSidebarWidth),
    "width": Parser(\.width, parseWorkspaceSidebarWidth),
    "monitor": Parser(\.monitor) { value, backtrace, errors in
        parseMonitorDescriptions(value, backtrace, &errors)
    },
    "show-status-pills": Parser(\.showStatusPills, parseBool),
    "show-clock": Parser(\.showClock, parseBool),
    "show-seconds": Parser(\.showSeconds, parseBool),
    "show-date": Parser(\.showDate, parseBool),
    "show-weekday": Parser(\.showWeekday, parseBool),
    "chrome-style": Parser(\.chromeStyle, parseChromeStyle),
    "glass-opacity": Parser(\.glassOpacity, parseWorkspaceSidebarUnitInterval),
    "solid-chrome-color": Parser(\.solidChromeColor, parseChromeSolidColor),
    "solid-chrome-custom-color": Parser(\.solidChromeCustomColor, parseChromeSolidCustomColor),
    "sidebar-appearance": Parser(\.sidebarAppearance) { raw, backtrace, errors in
        parseTable(raw, SidebarAppearanceConfig(), [
            "background-opacity": Parser(\.backgroundOpacity, parseWorkspaceSidebarUnitInterval),
            "blur": Parser(\.blur, parseBool),
        ], backtrace, &errors)
    },
    "dock-appearance": Parser(\.dockAppearance) { raw, backtrace, errors in
        parseTable(raw, DockAppearanceConfig(), [
            "style": Parser(\.style) { parseChromeStyle($0, $1).map(Optional.some) },
            "glass-opacity": Parser(\.glassOpacity) { parseWorkspaceSidebarUnitInterval($0, $1).map(Optional.some) },
            "solid-color": Parser(\.solidColor) { parseChromeSolidColor($0, $1).map(Optional.some) },
            "custom-color": Parser(\.customColor) { parseChromeSolidCustomColor($0, $1).map(Optional.some) },
        ], backtrace, &errors)
    },
    "use-liquid-glass": Parser(\.chromeStyle) { raw, backtrace in
        parseBool(raw, backtrace).map { $0 ? .liquidGlass : .solid }
    },
    "menu-bar-reserve-height": Parser(\.menuBarReserveHeight, parseWorkspaceSidebarMenuBarReserveHeight),
    "project-deletion-action": Parser(\.projectDeletionAction, parseWorkspaceProjectDeletionAction),
    "workspace-labels": Parser(\.workspaceLabels, parseWorkspaceSidebarLabels),
    "project-labels": Parser(\.projectLabels, parseWorkspaceSidebarLabels),
    "project-colors": Parser(\.projectColors, parseWorkspaceSidebarProjectColors),
    "project-emojis": Parser(\.projectEmojis, parseWorkspaceSidebarProjectEmojis),
]

func parseWorkspaceSidebar(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> WorkspaceSidebarConfig {
    var parsed = parseTable(raw, WorkspaceSidebarConfig(), workspaceSidebarParser, backtrace, &errors)
    // Explicit mode wins over the old show-app-icons alias, regardless of table order.
    if let value = raw.table?["mode"]?.string, let mode = WorkspaceSidebarMode(rawValue: value) {
        parsed.mode = mode
    }
    // Preserve the legacy key only when the modern setting is absent. This makes the
    // Appearance setting authoritative for configs that contain both keys.
    if let modernRawValue = raw.table?["chrome-style"]?.string,
       let modernStyle = ChromeStyle(rawValue: modernRawValue)
    {
        parsed.chromeStyle = modernStyle
    }
    if parsed.alwaysExpanded, parsed.width <= parsed.collapsedWidth {
        errors += [.semantic(
            backtrace + .key("width"),
            "Must be greater than collapsed-width when always-expanded is true",
        )]
    }
    return parsed
}

private func parseWorkspaceSidebarMode(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<WorkspaceSidebarMode> {
    parseString(raw, backtrace).flatMap { value in
        WorkspaceSidebarMode(rawValue: value).orFailure(.semantic(backtrace, "Possible values: sidebar, dock"))
    }
}

private func parseChromeSolidCustomColor(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<String> {
    parseString(raw, backtrace).flatMap { rawValue in
        normalizedWorkspaceSidebarColorHex(rawValue).orFailure(.semantic(backtrace, "Use a six-digit hex color, such as #1A2B3C"))
    }
}

private func parseChromeStyle(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<ChromeStyle> {
    parseString(raw, backtrace).flatMap { rawValue in
        ChromeStyle(rawValue: rawValue).orFailure(.semantic(
            backtrace,
            "Possible values: \(ChromeStyle.allCases.map(\.rawValue).joined(separator: ", "))",
        ))
    }
}

private func parseWorkspaceSidebarUnitInterval(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<Double> {
    let value = raw.double ?? raw.int.map(Double.init)
    return value
        .orFailure(.semantic(backtrace, "Must be a number from 0 to 1"))
        .filter(.semantic(backtrace, "Must be a finite number from 0 to 1")) { $0.isFinite && (0...1).contains($0) }
}

private func parseChromeSolidColor(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<ChromeSolidColor> {
    parseString(raw, backtrace).flatMap { rawValue in
        ChromeSolidColor(rawValue: rawValue).orFailure(.semantic(
            backtrace,
            "Possible values: \(ChromeSolidColor.allCases.map(\.rawValue).joined(separator: ", "))",
        ))
    }
}

private func parseWorkspaceSidebarWidth(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<Int> {
    parseInt(raw, backtrace)
        .filter(.semantic(backtrace, "Must be greater than 0")) { $0 > 0 }
}

private func parseWorkspaceSidebarMenuBarReserveHeight(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace) -> ParsedToml<Int> {
    parseInt(raw, backtrace)
        .filter(.semantic(backtrace, "Must be greater than or equal to 0")) { $0 >= 0 }
}

private func parseWorkspaceProjectDeletionAction(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
) -> ParsedToml<WorkspaceProjectDeletionAction> {
    parseString(raw, backtrace).flatMap { rawValue in
        WorkspaceProjectDeletionAction(rawValue: rawValue)
            .orFailure(.semantic(
                backtrace,
                "Possible values: \(WorkspaceProjectDeletionAction.allCases.map(\.rawValue).joined(separator: ", "))",
            ))
    }
}

private func parseWorkspaceSidebarLabels(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> [String: String] {
    guard let rawTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return [:]
    }
    var result: [String: String] = [:]
    for (workspaceName, rawLabel) in rawTable {
        if let label = parseString(rawLabel, backtrace + .key(workspaceName)).getOrNil(appendErrorTo: &errors) {
            result[workspaceName] = label
        }
    }
    return result
}

func normalizedWorkspaceSidebarColorHex(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let allowedCharacters = Set("0123456789abcdefABCDEF")
    guard hex.count == 6,
          hex.allSatisfy({ allowedCharacters.contains($0) })
    else {
        return nil
    }
    return "#\(hex.uppercased())"
}

private func parseWorkspaceSidebarProjectColors(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> [String: String] {
    guard let rawTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return [:]
    }
    var result: [String: String] = [:]
    for (projectId, rawColor) in rawTable {
        let colorBacktrace = backtrace + .key(projectId)
        guard let color = parseString(rawColor, colorBacktrace).getOrNil(appendErrorTo: &errors) else { continue }
        guard let normalized = normalizedWorkspaceSidebarColorHex(color) else {
            errors.append(.semantic(colorBacktrace, "Must be a hex color like '#RRGGBB'"))
            continue
        }
        result[projectId] = normalized
    }
    return result
}

private func parseWorkspaceSidebarProjectEmojis(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> [String: String] {
    guard let rawTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return [:]
    }
    var result: [String: String] = [:]
    for (projectId, rawEmoji) in rawTable {
        let path = backtrace + .key(projectId)
        guard let value = parseString(rawEmoji, path).getOrNil(appendErrorTo: &errors) else { continue }
        guard let emoji = normalizedWorkspaceProjectEmoji(value) else {
            errors.append(.semantic(path, "Must be a single emoji"))
            continue
        }
        result[projectId] = emoji
    }
    return result
}
