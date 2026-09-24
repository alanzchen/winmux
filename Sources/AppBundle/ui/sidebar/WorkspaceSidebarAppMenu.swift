import AppKit
import SwiftUI

/// The same menu description feeds AppKit's layer-backed Dock and SwiftUI's rail.
@MainActor
struct WorkspaceSidebarAppMenuEntry {
    var title: String = ""
    var checked = false
    var enabled = true
    var isDestructive = false
    var children: [WorkspaceSidebarAppMenuEntry] = []
    var perform: (() -> Void)? = nil

    static var separator: Self { Self() }
}

@MainActor
func workspaceSidebarAppMenu(workspaceName: String, app: WorkspaceSidebarAppViewModel) -> [WorkspaceSidebarAppMenuEntry] {
    guard let workspace = Workspace.existing(byName: workspaceName) else { return [] }
    let windows = workspaceSidebarWindowsForAppSummary(workspace).filter { workspaceSidebarAppIdentity($0) == app.id }
    var entries: [WorkspaceSidebarAppMenuEntry] = [.init(title: "\(app.name) · \(workspaceDisplayName(workspaceName))", enabled: false)]
    func windowEntry(_ window: Window, owner: Workspace) -> WorkspaceSidebarAppMenuEntry {
        .init(title: cachedWindowTitle(for: window)?.takeIf { !$0.isEmpty } ?? app.name,
            checked: focus.windowOrNil === window,
            perform: { performWorkspaceSidebarWindowAction(.focus, window: window, workspaceName: owner.name) })
    }
    entries += windows.sorted { $0.windowId < $1.windowId }.map { windowEntry($0, owner: workspace) }
    let otherWindows = orderedWorkspacesForPresentation().filter { $0 !== workspace }.flatMap { other in
        workspaceSidebarWindowsForAppSummary(other).filter { workspaceSidebarAppIdentity($0) == app.id }
            .sorted { $0.windowId < $1.windowId }.map { window -> WorkspaceSidebarAppMenuEntry in
                var entry = windowEntry(window, owner: other)
                entry.title += " — \(workspaceDisplayName(other.name))"
                return entry
            }
    }
    if !otherWindows.isEmpty { entries.append(.init(title: "Other Workspaces", children: otherWindows)) }
    if !windows.isEmpty { entries.append(.separator) }
    let current = workspaceSidebarAppWindow(in: workspace, appId: app.id) ?? windows.sorted { $0.windowId < $1.windowId }.first
    if let current {
        let title = cachedWindowTitle(for: current)?.takeIf { !$0.isEmpty } ?? app.name
        let minimized = current.parent is MacosMinimizedWindowsContainer || current.lastKnownNativeMinimized == true
        var controls: [WorkspaceSidebarAppMenuEntry] = [
            .init(title: minimized ? "Restore" : "Minimize", enabled: current is MacWindow && (minimized || workspaceSidebarCanMinimize(current)),
                perform: { performWorkspaceSidebarWindowAction(minimized ? .focus : .minimize, window: current, workspaceName: workspaceName) }),
        ]
        let destinations = orderedWorkspacesForPresentation().filter { $0 !== workspace && !$0.isArchived }
        if !destinations.isEmpty, current.participatesInWorkspaceFocus, !minimized {
            controls.append(.init(title: "Move to Workspace", children: destinations.map { destination in
                .init(title: workspaceDisplayName(destination.name), perform: {
                    moveWindowFromSidebar(current.windowId, toWorkspace: destination.name, validation: {
                        !serverArgs.isReadOnly && workspaceSidebarMenuCanMove(current,
                            workspaceName: workspaceName, destination: destination)
                    })
                })
            }))
        }
        controls.append(.init(title: "Close Window", enabled: current is MacWindow, perform: {
            performWorkspaceSidebarWindowAction(.close, window: current, workspaceName: workspaceName)
        }))
        entries.append(.init(title: "Window: \(title)", children: controls))
        entries.append(.separator)
    }
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
        entries.append(.init(title: "Quit \(app.name)", perform: {
            guard !serverArgs.isReadOnly else { return }
            for process in processes where !process.isTerminated { process.terminate() }
        }))
    }
    return entries
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
    for entry in entries {
        if entry.title.isEmpty { menu.addItem(.separator()); continue }
        let item = WorkspaceSidebarNativeDockMenuItem(entry.title) { entry.perform?() }
        item.isEnabled = entry.enabled
        item.state = entry.checked ? .on : .off
        if !entry.children.isEmpty { item.submenu = workspaceSidebarNativeAppMenu(entry.children) }
        menu.addItem(item)
    }
    return menu
}

/// Keep live tree traversal out of the animated icon button's body evaluation.
struct WorkspaceSidebarAppMenuContent: View {
    let workspaceName: String
    let app: WorkspaceSidebarAppViewModel

    var body: some View {
        WorkspaceSidebarAppContextMenu(entries: workspaceSidebarAppMenu(workspaceName: workspaceName, app: app))
    }
}

struct WorkspaceSidebarAppContextMenu: View {
    let entries: [WorkspaceSidebarAppMenuEntry]
    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            if entry.title.isEmpty { Divider() }
            else if !entry.children.isEmpty {
                Menu(entry.title) { AnyView(WorkspaceSidebarAppContextMenu(entries: entry.children)) }
            } else {
                Button(role: entry.isDestructive ? .destructive : nil, action: { entry.perform?() }) {
                    if entry.checked { Label(entry.title, systemImage: "checkmark") }
                    else { Text(entry.title) }
                }
                .disabled(!entry.enabled)
            }
        }
    }
}
