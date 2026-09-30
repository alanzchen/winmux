import AppKit
import SwiftUI

/// The same menu description feeds AppKit's menus and SwiftUI's context menus.
@MainActor
struct WorkspaceSidebarAppMenuEntry {
    enum Kind: Equatable {
        case item
        /// Names the target of the items below it, when a menu mixes targets.
        case header
        /// A row of color swatches, from `children`; each child's `swatch` is its color.
        case palette
    }

    var title: String = ""
    var checked = false
    var enabled = true
    var isDestructive = false
    var children: [WorkspaceSidebarAppMenuEntry] = []
    var perform: (() -> Void)? = nil
    var kind = Kind.item
    /// The full name a shortened title stands for, for its tooltip and VoiceOver.
    var fullTitle: String? = nil
    /// Why a disabled item can't be chosen.
    var help: String? = nil
    /// A palette swatch's color. Nil is Default, no color.
    var swatch: String? = nil

    static var separator: Self { Self() }
    static func header(_ title: String) -> Self { Self(title: title, enabled: false, kind: .header) }
    var isSeparator: Bool { kind == .item && title.isEmpty }
}

/// Keeps a menu narrow: a long window, tab or display name keeps its start and its end, so a
/// file's extension still shows. Only the name is shortened, never the command around it.
func workspaceSidebarMenuName(_ name: String, limit: Int = 40) -> String {
    guard name.count > limit else { return name }
    let tail = limit / 3
    return String(name.prefix(limit - tail - 1)) + "…" + String(name.suffix(tail))
}

extension WorkspaceSidebarAppMenuEntry {
    /// An entry whose title includes a name, shortened by `workspaceSidebarMenuName`.
    static func named(_ name: String, _ format: (String) -> String = { $0 }, checked: Bool = false,
                      enabled: Bool = true, isDestructive: Bool = false, children: [Self] = [],
                      perform: (() -> Void)? = nil) -> Self {
        let short = workspaceSidebarMenuName(name)
        return Self(title: format(short), checked: checked, enabled: enabled, isDestructive: isDestructive,
            children: children, perform: perform, fullTitle: short == name ? nil : format(name))
    }

    static func header(named name: String, _ format: (String) -> String) -> Self {
        var entry = named(name, format, enabled: false)
        entry.kind = .header
        return entry
    }
}

/// Separators only between groups: optional entries can leave two in a row or one at an end.
@MainActor
func workspaceSidebarMenuWithoutStraySeparators(_ entries: [WorkspaceSidebarAppMenuEntry]) -> [WorkspaceSidebarAppMenuEntry] {
    var result: [WorkspaceSidebarAppMenuEntry] = []
    for entry in entries where !(entry.isSeparator && (result.last?.isSeparator ?? true)) {
        result.append(entry)
    }
    if result.last?.isSeparator == true { result.removeLast() }
    return result
}

@MainActor
func workspaceSidebarAppMenu(workspaceName: String, app: WorkspaceSidebarAppViewModel) -> [WorkspaceSidebarAppMenuEntry] {
    guard let workspace = Workspace.existing(byName: workspaceName) else { return [] }
    let windows = workspaceSidebarWindowsForAppSummary(workspace).filter { workspaceSidebarAppIdentity($0) == app.id }
    var entries: [WorkspaceSidebarAppMenuEntry] = [.header("\(app.name) · \(workspaceDisplayName(workspaceName))")]
    func title(_ window: Window) -> String { cachedWindowTitle(for: window)?.takeIf { !$0.isEmpty } ?? app.name }
    func windowEntry(_ window: Window, owner: Workspace, _ format: @escaping (String) -> String = { $0 }) -> WorkspaceSidebarAppMenuEntry {
        .named(title(window), format, checked: focus.windowOrNil === window,
            perform: { performWorkspaceSidebarWindowAction(.focus, window: window, workspaceName: owner.name) })
    }
    entries += windows.sorted { $0.windowId < $1.windowId }.map { windowEntry($0, owner: workspace) }
    let otherWindows = orderedWorkspacesForPresentation().filter { $0 !== workspace }.flatMap { other in
        workspaceSidebarWindowsForAppSummary(other).filter { workspaceSidebarAppIdentity($0) == app.id }
            .sorted { $0.windowId < $1.windowId }.map { window in
                let owner = workspaceDisplayName(other.name)
                return windowEntry(window, owner: other) { "\($0) — \(owner)" }
            }
    }
    if !otherWindows.isEmpty { entries.append(.init(title: "Other Workspaces", children: otherWindows)) }
    // The window the next items act on gets its own heading, instead of a submenu of its own.
    let current = workspaceSidebarAppWindow(in: workspace, appId: app.id) ?? windows.sorted { $0.windowId < $1.windowId }.first
    if let current {
        let minimized = current.parent is MacosMinimizedWindowsContainer || current.lastKnownNativeMinimized == true
        entries += [.separator, .header(named: title(current)) { "Window · \($0)" }]
        entries.append(.init(title: minimized ? "Restore" : "Minimize", enabled: current is MacWindow && (minimized || workspaceSidebarCanMinimize(current)),
            perform: { performWorkspaceSidebarWindowAction(minimized ? .focus : .minimize, window: current, workspaceName: workspaceName) }))
        let destinations = orderedWorkspacesForPresentation().filter { $0 !== workspace && !$0.isArchived }
        if !destinations.isEmpty, current.participatesInWorkspaceFocus, !minimized {
            entries.append(.init(title: "Move to Workspace", children: destinations.map { destination in
                .named(workspaceDisplayName(destination.name), perform: {
                    moveWindowFromSidebar(current.windowId, toWorkspace: destination.name, validation: {
                        !serverArgs.isReadOnly && workspaceSidebarMenuCanMove(current,
                            workspaceName: workspaceName, destination: destination)
                    })
                })
            }))
        }
        // Last in its section, so it's plain which window it closes.
        entries.append(.init(title: "Close Window", enabled: current is MacWindow, isDestructive: true, perform: {
            performWorkspaceSidebarWindowAction(.close, window: current, workspaceName: workspaceName)
        }))
    }
    entries.append(.separator)
    if let path = app.bundlePath {
        entries.append(.init(title: "Show in Finder", perform: {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }))
    }
    // Capture actual processes represented by this icon, not a name/PID lookup that can
    // accidentally act on a relaunched application while a menu remains open.
    let allAppWindows = orderedWorkspacesForPresentation().flatMap { owner in
        workspaceSidebarWindowsForAppSummary(owner).filter { workspaceSidebarAppIdentity($0) == app.id }
    }
    let processes = allAppWindows.compactMap { ($0 as? MacWindow)?.macApp.nsApp }
        .reduce(into: [NSRunningApplication]()) { result, process in
            if !result.contains(where: { $0 == process }) { result.append(process) }
        }
    if !processes.isEmpty {
        let hidden = processes.allSatisfy(\.isHidden)
        entries.append(.init(title: "\(hidden ? "Show" : "Hide") \(app.name)", perform: {
            guard !serverArgs.isReadOnly else { return }
            for process in processes where !process.isTerminated {
                if hidden { process.unhide() } else { process.hide() }
            }
        }))
        entries += [.separator, .init(title: "Quit \(app.name)", isDestructive: true, perform: {
            guard !serverArgs.isReadOnly else { return }
            for process in processes where !process.isTerminated { process.terminate() }
        })]
    }
    return workspaceSidebarMenuWithoutStraySeparators(entries)
}

@MainActor
func workspaceSidebarMenuCanMove(_ window: Window, workspaceName: String, destination: Workspace) -> Bool {
    window.participatesInWorkspaceFocus && window.lastKnownNativeMinimized != true &&
        window.lastKnownNativeFullscreen != true &&
        workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName) &&
        Workspace.existing(byName: destination.name) === destination && !destination.isArchived
}

@MainActor
func workspaceSidebarCanMinimize(_ window: Window) -> Bool {
    window.participatesInWorkspaceFocus && window.lastKnownNativeFullscreen != true && window.lastKnownNativeMinimized != true
}

enum WorkspaceSidebarMenuWindowAction { case focus, minimize, close }

@MainActor
func workspaceSidebarMenuWindowIsCurrent(_ window: Window, workspaceName: String) -> Bool {
    guard Window.get(byId: window.windowId) === window,
          let workspace = Workspace.existing(byName: workspaceName) else { return false }
    return workspaceSidebarWindowsForAppSummary(workspace).contains { $0 === window }
}

@MainActor
func performWorkspaceSidebarWindowAction(
    _ action: WorkspaceSidebarMenuWindowAction, window: Window, workspaceName: String,
    targetMonitorScopeId: String? = nil, overrideWorkspaceInUse: Bool = false
) {
    guard !serverArgs.isReadOnly, workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName) else { return }
    if case .focus = action { WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation() }
    var shouldRaise = false
    runWorkspaceSidebarSession(afterLayout: {
        guard shouldRaise, workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName),
              focus.windowOrNil === window, window.nodeWorkspace?.isVisible == true,
              window.lastKnownNativeMinimized != true, let macWindow = window as? MacWindow else { return }
        macWindow.macApp.nativeFocus(window.windowId, forceRaise: true)
    }) {
        guard workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName),
              let workspace = Workspace.existing(byName: workspaceName), let macWindow = window as? MacWindow else { return }
        switch action {
            case .close:
                if try await !macWindow.macApp.pressCloseButton(window.windowId) {
                    showWorkspaceSidebarError("This window could not be closed.")
                }
            case .minimize:
                guard workspaceSidebarCanMinimize(window) else { return }
                guard try await macWindow.macApp.setDockMenuMinimized(window.windowId, true) else {
                    showWorkspaceSidebarError("This window could not be minimized.")
                    return
                }
                guard workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName),
                      window.participatesInWorkspaceFocus else { return }
                window.rememberMacOsLayoutOrigin()
                window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                window.invalidateLastKnownNativeState()
            case .focus:
                if let targetMonitorScopeId, workspaceSidebarMonitor(forScopeId: targetMonitorScopeId) == nil { return }
                if overrideWorkspaceInUse {
                    guard let targetMonitorScopeId,
                          let monitor = workspaceSidebarMonitor(forScopeId: targetMonitorScopeId),
                          overrideWorkspaceOnMonitorBySwappingActiveViewports(workspace, targetMonitor: monitor) else { return }
                }
                guard focusWorkspaceFromSidebar(workspace, targetMonitorScopeId: targetMonitorScopeId) else { return }
                macWindow.macApp.nsApp.unhide()
                if window.parent is MacosHiddenAppsWindowsContainer,
                   case .macos(let kind, let previousWorkspace) = window.layoutReason {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: kind,
                        prevWorkspaceName: previousWorkspace, workspace: workspace)
                }
                if window.parent is MacosMinimizedWindowsContainer || window.lastKnownNativeMinimized == true {
                    guard try await macWindow.macApp.setDockMenuMinimized(window.windowId, false) else {
                        showWorkspaceSidebarError("This window could not be restored.")
                        return
                    }
                    guard workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName) else { return }
                    if case .macos(let kind, let previousWorkspace) = window.layoutReason {
                        try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: kind,
                            prevWorkspaceName: previousWorkspace, workspace: workspace)
                    }
                    window.invalidateLastKnownNativeState()
                }
                guard workspaceSidebarMenuWindowIsCurrent(window, workspaceName: workspaceName) else { return }
                guard focusWorkspaceFromSidebar(workspace, targetMonitorScopeId: targetMonitorScopeId) else { return }
                guard let liveFocus = window.toLiveFocusOrNil(), setFocus(to: liveFocus) else { return }
                shouldRaise = true
        }
    }
}

@MainActor
func workspaceSidebarNativeAppMenu(_ entries: [WorkspaceSidebarAppMenuEntry]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let entries = workspaceSidebarMenuWithoutStraySeparators(entries)
    for (entry, title) in zip(entries, workspaceSidebarMenuTitles(entries)) {
        if entry.isSeparator { menu.addItem(.separator()); continue }
        switch entry.kind {
            case .header:
                menu.addItem(workspaceSidebarNativeMenuHeader(title, fullTitle: entry.fullTitle))
            case .palette:
                menu.addItem(workspaceSidebarNativeMenuPalette(entry))
            case .item:
                let item = WorkspaceSidebarNativeDockMenuItem(title) { entry.perform?() }
                item.isEnabled = entry.enabled
                item.state = entry.checked ? .on : .off
                item.toolTip = entry.fullTitle ?? entry.help
                if let fullTitle = entry.fullTitle, title != fullTitle { item.setAccessibilityLabel(fullTitle) }
                if !entry.children.isEmpty { item.submenu = workspaceSidebarNativeAppMenu(entry.children) }
                menu.addItem(item)
        }
    }
    return menu
}

/// Shortened names that came out the same show in full, so choosing between them stays safe.
@MainActor
func workspaceSidebarMenuTitles(_ entries: [WorkspaceSidebarAppMenuEntry]) -> [String] {
    var counts: [String: Int] = [:]
    for entry in entries { counts[entry.title, default: 0] += 1 }
    return entries.map { entry in
        guard let fullTitle = entry.fullTitle, counts[entry.title, default: 0] > 1 else { return entry.title }
        return fullTitle
    }
}

@MainActor
private func workspaceSidebarNativeMenuHeader(_ title: String, fullTitle: String?) -> NSMenuItem {
    let item: NSMenuItem
    if #available(macOS 14, *) {
        item = .sectionHeader(title: title)
    } else {
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
    }
    item.toolTip = fullTitle
    if let fullTitle { item.setAccessibilityLabel(fullTitle) }
    return item
}

/// Every swatch shares this target and action, which is what makes AppKit treat the row as one
/// choice with one selected color.
@MainActor
final class WorkspaceSidebarMenuPalette: NSObject {
    let choices: [WorkspaceSidebarAppMenuEntry]
    init(_ choices: [WorkspaceSidebarAppMenuEntry]) { self.choices = choices }

    @objc func choose(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        let choice = choices[sender.tag]
        // Choosing the current color again changes nothing, as in the editor.
        guard !choice.checked else { return }
        choice.perform?()
    }
}

/// Colors as a row of swatches in the menu itself, like Finder's tags, on macOS 14 and later;
/// before that, a Color submenu with the same swatches and check marks.
@MainActor
func workspaceSidebarNativeMenuPalette(_ entry: WorkspaceSidebarAppMenuEntry) -> NSMenuItem {
    let palette = WorkspaceSidebarMenuPalette(entry.children)
    let swatches = NSMenu(title: entry.title)
    swatches.autoenablesItems = false
    if #available(macOS 14, *) {
        swatches.presentationStyle = .palette
        swatches.selectionMode = .selectOne
    }
    for (index, choice) in entry.children.enumerated() {
        let item = NSMenuItem(title: choice.title, action: #selector(WorkspaceSidebarMenuPalette.choose(_:)), keyEquivalent: "")
        item.target = palette
        item.tag = index
        item.image = workspaceSidebarMenuSwatchImage(hex: choice.swatch, isSelected: choice.checked)
        item.state = choice.checked ? .on : .off
        item.isEnabled = choice.enabled
        item.toolTip = choice.title
        swatches.addItem(item)
    }
    let carrier = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
    // Menu items don't retain their targets.
    carrier.representedObject = palette
    carrier.submenu = swatches
    carrier.isEnabled = entry.enabled
    return carrier
}

/// A swatch drawn for the menu's appearance: a filled circle, or a slashed ring for Default,
/// with a ring around the chosen one so it stays visible under the pointer's highlight.
func workspaceSidebarMenuSwatchImage(hex: String?, isSelected: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
        if let color = hex.flatMap(workspaceSidebarNSColor(hex:)) {
            color.setFill()
            circle.fill()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 5.5, y: rect.minY + 5.5))
            slash.line(to: NSPoint(x: rect.maxX - 5.5, y: rect.maxY - 5.5))
            slash.lineWidth = 1.2
            slash.stroke()
        }
        if isSelected {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.labelColor.setStroke()
            ring.stroke()
        }
        return true
    }
    return image
}

/// Keep live tree traversal out of the animated icon button's body evaluation.
struct WorkspaceSidebarAppMenuContent: View {
    let workspaceName: String
    let app: WorkspaceSidebarAppViewModel

    var body: some View {
        WorkspaceSidebarAppContextMenu(entries: workspaceSidebarAppMenu(workspaceName: workspaceName, app: app))
    }
}

/// SwiftUI's rendering of the same entries, for `.contextMenu`: native check marks, disabled
/// submenus, headers as captions, and a palette as a Color submenu.
struct WorkspaceSidebarAppContextMenu: View {
    let entries: [WorkspaceSidebarAppMenuEntry]
    var body: some View {
        let entries = workspaceSidebarMenuWithoutStraySeparators(entries)
        let titles = workspaceSidebarMenuTitles(entries)
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            let title = titles[index]
            if entry.isSeparator { Divider() }
            else if entry.kind == .header { Text(title) }
            else if !entry.children.isEmpty {
                Menu(title) { AnyView(WorkspaceSidebarAppContextMenu(entries: entry.children)) }
                    .disabled(!entry.enabled)
            } else if entry.checked {
                Toggle(title, isOn: Binding(get: { true }, set: { _ in entry.perform?() }))
                    .disabled(!entry.enabled)
            } else {
                Button(title) { entry.perform?() }
                    .disabled(!entry.enabled)
            }
        }
    }
}
