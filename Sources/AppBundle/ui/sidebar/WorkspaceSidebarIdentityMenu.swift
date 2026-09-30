import AppKit
import SwiftUI

enum WorkspaceSidebarIdentityTarget: Equatable {
    case workspace(String)
    case tab(String, windowId: UInt32?)
    case project(WorkspaceProjectId)
    case collection(String, isSearching: Bool = false, monitorScopeId: String? = nil, createMonitorScopeId: String? = nil)

    var monitorScopeId: String? {
        if case .collection(_, _, let scope, _) = self { return scope }
        return nil
    }

    /// The tab a tab's or workspace's menu is for.
    var tabName: String? {
        switch self {
            case .tab(let name, _), .workspace(let name): name
            case .project, .collection: nil
        }
    }
}

/// An item's name, color and icon, and its menu. Right-clicking shows `entries` as a native menu;
/// Rename… and Change Icon… there open the editor for the same item.
@MainActor
final class WorkspaceSidebarIdentityMenuModel: ObservableObject {
    @Published var name: String
    @Published var color: String?
    @Published var emoji: String?
    @Published var showsIcons = false
    @Published var query = ""
    /// What an unnamed tab is called in the list, shown in the empty name field. Never saved.
    let placeholder: String
    var committedName: String
    let rename: (String) -> Void
    let setColor: (String?) -> Void
    let setEmoji: (String?) -> Void
    /// The item's own actions, before the appearance items and after them.
    let leadingEntries: [WorkspaceSidebarAppMenuEntry]
    let trailingEntries: [WorkspaceSidebarAppMenuEntry]
    /// Opens the editor for this item, with the icons showing or the name selected. Set by
    /// whoever shows the menu, so the editor opens where the menu was.
    var openEditor: (_ model: WorkspaceSidebarIdentityMenuModel, _ showsIcons: Bool) -> Void = { _, _ in }

    init(name: String, placeholder: String = "", color: String?, emoji: String?, rename: @escaping (String) -> Void,
         setColor: @escaping (String?) -> Void, setEmoji: @escaping (String?) -> Void,
         entries: [WorkspaceSidebarAppMenuEntry], trailingEntries: [WorkspaceSidebarAppMenuEntry] = []) {
        self.name = name
        self.placeholder = placeholder
        committedName = name
        self.color = color
        self.emoji = emoji
        self.rename = rename
        self.setColor = setColor
        self.setEmoji = setEmoji
        leadingEntries = entries
        self.trailingEntries = trailingEntries
    }

    /// The whole menu: the item's actions, with its appearance just above its last group.
    var entries: [WorkspaceSidebarAppMenuEntry] {
        workspaceSidebarMenuWithoutStraySeparators(leadingEntries + [.separator] + appearanceEntries + [.separator] + trailingEntries)
    }

    var appearanceEntries: [WorkspaceSidebarAppMenuEntry] {
        [
            .init(title: "Rename…", perform: { self.openEditorAfterMenu(showsIcons: false) }),
            .init(title: "Color", children: colorChoices, kind: .palette),
            .init(title: "Change Icon…", perform: { self.openEditorAfterMenu(showsIcons: true) }),
        ]
    }

    /// Default and the presets. A custom color from the config checks none of them, and stays
    /// until one is chosen; choosing the current one changes nothing.
    var colorChoices: [WorkspaceSidebarAppMenuEntry] {
        let choices: [(name: String, hex: String?)] = [("Default", nil)] + workspaceSidebarIdentityColors.map { ($0.name, $0.hex) }
        return choices.map { choice in
            let isCurrent = isCurrentColor(choice.hex)
            return .init(title: choice.name, checked: isCurrent,
                perform: isCurrent ? nil : { self.chooseColor(choice.hex) }, swatch: choice.hex)
        }
    }

    /// After the menu has gone, so the editor gets keyboard focus. The menu, which is all that
    /// holds this model, is released by then, so the pending editor holds it instead.
    private func openEditorAfterMenu(showsIcons: Bool) {
        DispatchQueue.main.async { self.openEditor(self, showsIcons) }
    }

    /// Compared as colors, so "#00b894" is Green; nil is Default.
    func isCurrentColor(_ hex: String?) -> Bool {
        guard let hex else { return color == nil }
        return color.flatMap(normalizedWorkspaceSidebarColorHex) == normalizedWorkspaceSidebarColorHex(hex)
    }

    func commitName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != committedName else { return }
        committedName = value
        rename(value)
    }

    func chooseColor(_ value: String?) { commitName(); color = value; setColor(value) }
    func chooseEmoji(_ value: String?) { commitName(); emoji = value; setEmoji(value) }
}

@MainActor
func workspaceSidebarIdentityMenuModel(_ target: WorkspaceSidebarIdentityTarget,
                                       targetMonitorScopeId: String? = nil,
                                       sendAction: @escaping @MainActor (WorkspaceSidebarAction, String?) -> Void = {
                                           handleWorkspaceSidebarAction($0, targetMonitorScopeId: $1)
                                       }) -> WorkspaceSidebarIdentityMenuModel? {
    let actionScope = target.monitorScopeId ?? targetMonitorScopeId
    let send: @MainActor (WorkspaceSidebarAction) -> Void = { sendAction($0, actionScope) }
    let projects = TrayMenuModel.shared.workspaceSidebarProjects
    switch target {
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            let canDelete = canDeleteWorkspaceProject(id)
            // Deleting a project with windows asks first.
            let asks = canDelete && !windowsInWorkspaceProject(id).isEmpty
            return .init(name: project.displayName, color: project.colorHex, emoji: project.emoji,
                rename: { send(.renameProject(id, displayName: $0)) },
                setColor: { send(.setProjectColor(id, colorHex: $0)) },
                setEmoji: { send(.setProjectEmoji(id, emoji: $0)) },
                entries: [
                    .init(title: "Switch to Project", perform: { send(.selectProject(id)) }),
                    .init(title: "New Project", perform: { send(.createProject) }),
                ],
                trailingEntries: [
                    .init(title: asks ? "Delete Project…" : "Delete Project", enabled: canDelete, isDestructive: true,
                        perform: { send(.deleteProject(id)) },
                        help: canDelete ? nil : "The default project can't be deleted."),
                ])
        case .workspace(let name):
            guard let workspace = TrayMenuModel.shared.workspaceSidebarWorkspaces.first(where: { $0.name == name }) else { return nil }
            return workspaceSidebarWorkspaceIdentityMenuModel(workspace, send: send)
        case .tab(let name, let windowId):
            guard let workspace = TrayMenuModel.shared.workspaceSidebarWorkspaces.first(where: { $0.name == name }) else { return nil }
            return workspaceSidebarWorkspaceIdentityMenuModel(workspace, windowId: windowId, send: send)
        case .collection(let id, let isSearching, _, let createMonitorScopeId):
            guard let group = workspaceSidebarOrganizationStore.state.collections.first(where: { $0.id == id }) else { return nil }
            let scope = actionScope ?? TrayMenuModel.shared.workspaceSidebarTargetMonitorScopeId
            let disclosure = WorkspaceSidebarTabCollectionDisclosure(group: group,
                containsActiveTab: group.containsVisibleWorkspace(on: scope),
                isSearching: isSearching)
            return .init(name: group.name, color: group.colorHex, emoji: group.emoji,
                rename: { send(.renameTabCollection(id, $0)) },
                setColor: { send(.setTabCollectionColor(id, $0)) }, setEmoji: { send(.setTabCollectionEmoji(id, $0)) },
                entries: [
                    .init(title: disclosure.isCollapsed ? "Expand Group" : "Collapse Group", enabled: disclosure.canToggle,
                        perform: { send(.toggleTabCollection(id)) },
                        help: disclosure.canToggle ? nil
                            : isSearching ? "Groups stay open while searching." : "The group holds the tab that's showing."),
                    .init(title: "New Tab in Group", perform: {
                        send(.createTabInCollection(id, monitorScopeId: createMonitorScopeId ?? scope))
                    }),
                    workspaceSidebarProjectDestinations(projects, excluding: group.projectId) { project in
                        send(.moveTabCollection(id, project))
                    },
                ].compactMap { $0 },
                trailingEntries: [
                    // Keeps its tabs, so it's the group's last item but not a destructive one.
                    .init(title: "Ungroup Tabs", perform: { send(.ungroupTabCollection(id)) }),
                ])
    }
}

/// Move to Project, listing the other projects; none when there's nowhere else to go.
@MainActor
func workspaceSidebarProjectDestinations(_ projects: [WorkspaceSidebarProjectViewModel], excluding projectId: WorkspaceProjectId,
                                         move: @escaping (WorkspaceProjectId) -> Void) -> WorkspaceSidebarAppMenuEntry? {
    let destinations = projects.filter { $0.id != projectId }
    guard !destinations.isEmpty else { return nil }
    return .init(title: "Move to Project", children: destinations.map { project in
        .named((project.emoji.map { $0 + " " } ?? "") + project.displayName, perform: { move(project.id) })
    })
}

/// What an unnamed tab shows in the list: its windows' titles, or its saved apps.
@MainActor
func workspaceSidebarTabListTitle(_ tab: WorkspaceSidebarWorkspaceViewModel) -> String {
    guard tab.sidebarLabel.isEmpty else { return tab.displayName }
    let windows = workspaceSidebarPinnedTabWindows(tab)
    if !windows.isEmpty { return windows.map { $0.title?.takeIf { !$0.isEmpty } ?? $0.appName }.joined(separator: " · ") }
    let savedApps = tab.savedState?.apps ?? []
    return savedApps.isEmpty ? "Empty Tab" : workspaceSidebarSavedAppNames(savedApps)
}

@MainActor
func workspaceSidebarWorkspaceIdentityMenuModel(_ workspace: WorkspaceSidebarWorkspaceViewModel,
    windowId: UInt32? = nil,
    send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> WorkspaceSidebarIdentityMenuModel {
    let name = workspace.name
    let context = workspaceSidebarWorkspaceMenuContext(workspaceName: name)
    let sections = workspaceSidebarWorkspaceMenuSections(workspace, context: context)
    func entries(_ group: [WorkspaceSidebarWorkspaceMenuEntry]) -> [WorkspaceSidebarAppMenuEntry] {
        group.map { workspaceSidebarAppMenuEntry($0, send: send) }
    }
    var leading: [WorkspaceSidebarAppMenuEntry] = []
    var trailing: [WorkspaceSidebarAppMenuEntry] = []
    // A generated name like "Workspace 3" isn't what an unnamed tab shows, so its field starts empty.
    let isUnnamedTab = context.separatesIntoTabs && workspace.isGeneratedName && workspace.sidebarLabel.isEmpty
    if context.separatesIntoTabs {
        let projects = TrayMenuModel.shared.workspaceSidebarProjects
        let groups = workspaceSidebarOrganizationStore.state.collections.filter { $0.projectId == workspace.projectId }
        var destinations: [WorkspaceSidebarAppMenuEntry] = [
            .init(title: "New Group…", perform: { send(.createTabCollection(name)) }),
            .separator,
        ]
        destinations += groups.map { group in
            .named((group.emoji.map { $0 + " " } ?? "") + group.name,
                checked: group.workspaceNames.contains(name), perform: { send(.assignTabCollection(name, group.id)) })
        }
        if workspaceSidebarOrganizationStore.collection(containing: name) != nil {
            destinations += [.separator, .init(title: "Remove from Group", perform: { send(.assignTabCollection(name, nil)) })]
        }
        leading = [
            .init(title: workspace.appearance.isFavorite ? "Unpin Tab" : "Pin Tab",
                perform: { send(.setWorkspaceFavorite(name, !workspace.appearance.isFavorite)) }),
            .init(title: "Add to Group", children: destinations),
        ]
        if let move = workspaceSidebarProjectDestinations(projects, excluding: workspace.projectId, move: { project in
            send(.moveWorkspace(name, toProject: project))
        }) { leading.append(move) }
        leading.append(.separator)
        let windows = workspaceSidebarPinnedTabWindows(workspace)
        let clickedWindow = windows.first(where: { $0.windowId == windowId }) ?? (windows.count == 1 ? windows.first : nil)
        if let window = clickedWindow, let sourceId = Workspace.existing(byName: name)?.id {
            let splitTargets = workspaceSidebarSplitDestinations(windowId: window.windowId)
            if !splitTargets.isEmpty {
                leading.append(.init(title: "Split with", children: splitTargets.map { target in
                    let snapshot = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == target.name }
                    let label = snapshot.map(workspaceSidebarTabListTitle)?.takeIf { !$0.isEmpty } ?? workspaceDisplayName(target.name)
                    let emoji = snapshot?.appearance.emoji.map { $0 + " " } ?? ""
                    return .named(emoji + label,
                        perform: { send(.splitTabWindow(window.windowId, fromWorkspace: sourceId, withWorkspace: target.id)) })
                }))
            }
        }
        if let window = clickedWindow, windows.count > 1 {
            leading.append(.named(window.title?.takeIf { !$0.isEmpty } ?? window.appName, { "Move “\($0)” to New Tab" },
                perform: { send(.detachTabWindow(window.windowId)) }))
        }
        leading += entries(sections.layout) + [.separator] + entries(sections.keep)
        trailing = entries(sections.remove) + [.separator]
        if let window = clickedWindow {
            trailing.append(.init(title: "Close Window", isDestructive: true, perform: { send(.closeWindow(window.windowId)) }))
        }
        if windows.count > 1 {
            let whole = workspaceSidebarTabPresentation(workspace) == .folder ? "Tab" : "Split"
            trailing.append(.init(title: "Close All Windows in \(whole)…", isDestructive: true, perform: { send(.closeTabWindows(name)) }))
        } else if windows.isEmpty {
            trailing.append(.init(title: "Close Empty Tab", isDestructive: true, perform: { send(.closeEmptyTab(name)) }))
        }
    } else {
        leading = entries(sections.keep)
        trailing = entries(sections.panel) + [.separator] + entries(sections.remove)
    }
    return .init(name: isUnnamedTab ? "" : workspace.displayName, placeholder: workspaceSidebarTabListTitle(workspace),
        color: workspace.appearance.colorHex, emoji: workspace.appearance.emoji,
        rename: { send(.renameWorkspace(name, displayName: $0)) },
        setColor: { send(.setWorkspaceColor(name, $0)) }, setEmoji: { send(.setWorkspaceEmoji(name, $0)) },
        entries: leading, trailingEntries: trailing)
}

@MainActor
final class WorkspaceSidebarIdentityMenu: NSObject, NSWindowDelegate {
    static let shared = WorkspaceSidebarIdentityMenu()
    private(set) var panel: NSPanel?
    private var model: WorkspaceSidebarIdentityMenuModel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var previousKeyWindow: NSWindow?
    private var anchor = NSPoint.zero
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTrackingDepth = 0
    private(set) var menuRequest = 0
    /// One of these menus is tracking, which keeps the sidebar open under it like the editor does,
    /// even when the pointer isn't over the sidebar (a menu opened from VoiceOver).
    private(set) var isShowingMenu = false
    static var isVisible: Bool { shared.panel?.isVisible == true || shared.isShowingMenu }

    /// The item's menu, or its editor with the name selected or the icons showing. `scope` is the
    /// display whose sidebar asked, when known; otherwise it's the display at `point`.
    static func show(_ target: WorkspaceSidebarIdentityTarget, at point: NSPoint = NSEvent.mouseLocation,
                     scope: String? = nil, selectName: Bool = false, showsIcons: Bool = false) {
        guard selectName || showsIcons else { return shared.showMenu(target, at: point, scope: scope) }
        guard let model = model(for: target, at: point, scope: scope) else { return }
        model.showsIcons = showsIcons
        shared.openEditor(model, at: point, selectName: selectName)
    }

    /// Without a click: at the control, for its own sidebar's display.
    static func show(_ target: WorkspaceSidebarIdentityTarget, from anchor: WorkspaceSidebarMenuAnchor,
                     selectName: Bool = false, showsIcons: Bool = false) {
        show(target, at: anchor.point ?? NSEvent.mouseLocation, scope: anchor.monitorScopeId,
            selectName: selectName, showsIcons: showsIcons)
    }

    /// A right-click or Control-click. On one of several chosen tabs it opens their shared menu.
    static func showMenu(_ target: WorkspaceSidebarIdentityTarget, with event: NSEvent, in view: NSView) {
        if let name = target.tabName, let selection = workspaceSidebarTabSelectionMenu(containing: name) {
            return shared.show(selection, click: (event, view))
        }
        let point = NSEvent.mouseLocation
        guard let model = model(for: target, at: point, scope: workspaceSidebarMenuScope(of: view)) else { return }
        shared.presentMenu(model, at: point, click: (event, view))
    }

    /// The same menu without a click, such as VoiceOver's Show Menu.
    func showMenu(_ target: WorkspaceSidebarIdentityTarget, at point: NSPoint, scope: String? = nil) {
        if let name = target.tabName, let selection = workspaceSidebarTabSelectionMenu(containing: name) {
            return show(selection, at: point)
        }
        guard let model = Self.model(for: target, at: point, scope: scope) else { return }
        presentMenu(model, at: point)
    }

    /// A menu that isn't an item's identity menu, such as an app's: with its click, or at a point.
    func show(_ menu: NSMenu, click: (NSEvent, NSView)) {
        close(commit: true)
        menuRequest += 1
        track(menu, .click(click.0, click.1))
    }

    func show(_ menu: NSMenu, at point: NSPoint) {
        close(commit: true)
        menuRequest += 1
        popUpLater(menu, at: point, request: menuRequest)
    }

    enum Origin {
        case click(NSEvent, NSView)
        case point(NSPoint)
    }

    /// Puts a menu on screen and tracks it until it closes. Tests replace it to read the menu instead.
    var presentNativeMenu: (NSMenu, Origin) -> Void = { menu, origin in
        switch origin {
            case .click(let event, let view): NSMenu.popUpContextMenu(menu, with: event, for: view)
            case .point(let point): menu.popUp(positioning: nil, at: point, in: nil)
        }
    }

    private func track(_ menu: NSMenu, _ origin: Origin) {
        isShowingMenu = true
        defer {
            isShowingMenu = false
            WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
        }
        presentNativeMenu(menu, origin)
    }

    /// The Dock's entry: the editor while choosing a name or an icon, otherwise the item's menu.
    func open(_ model: WorkspaceSidebarIdentityMenuModel, at point: NSPoint, selectName: Bool) {
        if selectName || model.showsIcons { openEditor(model, at: point, selectName: selectName) }
        else { presentMenu(model, at: point) }
    }

    static func model(for target: WorkspaceSidebarIdentityTarget, at point: NSPoint, scope: String? = nil,
                      sendAction: @escaping @MainActor (WorkspaceSidebarAction, String?) -> Void = {
                          handleWorkspaceSidebarAction($0, targetMonitorScopeId: $1)
                      }) -> WorkspaceSidebarIdentityMenuModel? {
        let scope = scope ?? workspaceSidebarMonitorScopeId(for: normalizeAppKitScreenPoint(point).monitorApproximation)
        return workspaceSidebarIdentityMenuModel(target, targetMonitorScopeId: scope, sendAction: sendAction)
    }

    /// Shows the item's native menu, with the click that asked for it, or on the next turn otherwise.
    func presentMenu(_ model: WorkspaceSidebarIdentityMenuModel, at point: NSPoint, click: (NSEvent, NSView)? = nil) {
        close(commit: true)
        WorkspaceSidebarPanel.inputSession.owner?.cancelInlineTextEditing()
        menuRequest += 1
        let request = menuRequest
        model.openEditor = { [weak self] model, showsIcons in
            // Unless another menu or editor has opened since.
            guard let self, self.menuRequest == request else { return }
            model.showsIcons = showsIcons
            self.openEditor(model, at: point, selectName: !showsIcons)
        }
        let menu = workspaceSidebarNativeAppMenu(model.entries)
        guard let click else { return popUpLater(menu, at: point, request: request) }
        track(menu, .click(click.0, click.1))
    }

    /// Accessibility and Dock callers must not wait out menu tracking. A newer menu, or the
    /// editor opening meanwhile, wins.
    private func popUpLater(_ menu: NSMenu, at point: NSPoint, request: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuRequest == request else { return }
            self.track(menu, .point(point))
        }
    }

    func openEditor(_ model: WorkspaceSidebarIdentityMenuModel, at point: NSPoint, selectName: Bool) {
        close(commit: true)
        menuRequest += 1
        WorkspaceSidebarPanel.inputSession.owner?.cancelInlineTextEditing()
        self.model = model
        anchor = point
        previousKeyWindow = NSApp.keyWindow
        let panel = WorkspaceSidebarIdentityPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WorkspaceSidebarIdentityMenuView(model: model, selectName: selectName,
            usesMaterial: true,
            resized: { [weak self] in self?.resize() },
            dismiss: { [weak self] commit in self?.close(commit: commit) }))
        self.panel = panel
        resizeNow()
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(commit: true) }
            },
        ]
        panel.makeKeyAndOrderFront(nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.menuTrackingDepth == 0 else { return false }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.close(commit: false)
                    return true
                }
                if event.type != .keyDown, event.window !== panel, !panel.frame.contains(NSEvent.mouseLocation) {
                    self.close(commit: true)
                }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuTrackingDepth == 0 else { return }
                self.close(commit: true)
            }
        }
    }

    func resize() {
        DispatchQueue.main.async { [weak self] in self?.resizeNow() }
    }

    private func resizeNow() {
        guard let panel, let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let x = min(max(anchor.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        let y = min(max(anchor.y - size.height, bounds.minY + 8), bounds.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    func close(commit: Bool) {
        guard let panel else { return }
        self.panel = nil
        if commit { model?.commitName() }
        model = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers = []
        menuTrackingDepth = 0
        panel.orderOut(nil)
        if previousKeyWindow?.isVisible == true { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Native action submenus temporarily own menu tracking, but don't close this panel.
        guard let panel, notification.object as? NSWindow === panel else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel, self.menuTrackingDepth == 0, !panel.isKeyWindow else { return }
            self.close(commit: true)
        }
    }
}

private final class WorkspaceSidebarIdentityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

let workspaceSidebarIdentityEditorCornerRadius: CGFloat = 12

/// Popover material behind the editor, which the system makes opaque with Reduce Transparency.
private struct WorkspaceSidebarIdentityEditorMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The name, color and icon editor, opened by Rename… or Change Icon… in the item's menu.
struct WorkspaceSidebarIdentityMenuView: View {
    @ObservedObject var model: WorkspaceSidebarIdentityMenuModel
    var selectName = false
    /// In its panel the editor sits on popover material; a render without a window gets a plain card.
    var usesMaterial = false
    var resized: () -> Void = {}
    var dismiss: (Bool) -> Void = { _ in }
    @FocusState private var nameFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: workspaceSidebarIdentityEditorCornerRadius)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(model.placeholder.isEmpty ? "Name" : model.placeholder, text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(8)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .focused($nameFocused)
                    .onSubmit { model.commitName(); nameFocused = false }
                    .accessibilityLabel("Name")
                HStack(spacing: 6) {
                    swatch(nil, name: "Default")
                    ForEach(workspaceSidebarIdentityColors, id: \.hex) { preset in swatch(preset.hex, name: preset.name) }
                }.padding(.horizontal, 4).padding(.vertical, 4)
                Button {
                    model.commitName()
                    model.showsIcons.toggle()
                    searchFocused = model.showsIcons
                } label: {
                    HStack {
                        Text("Change Icon")
                        Spacer()
                        if let emoji = model.emoji { Text(emoji) }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }.frame(maxWidth: .infinity).padding(7).contentShape(Rectangle())
                }.buttonStyle(WorkspaceSidebarIdentityButtonStyle())
                Divider()
                Button {
                    model.chooseColor(nil)
                    model.chooseEmoji(nil)
                } label: {
                    Text("Reset Appearance").frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceSidebarIdentityButtonStyle())
                .disabled(model.color == nil && model.emoji == nil)
            }
            .frame(width: 252)
            if model.showsIcons { iconPicker.frame(width: 218) }
        }
        .padding(10)
        .background {
            if usesMaterial { WorkspaceSidebarIdentityEditorMaterial().clipShape(shape) }
            else { shape.fill(Color(nsColor: .windowBackgroundColor)) }
        }
        // Increase Contrast gets a border that reads against any background.
        .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.55 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
        .font(.system(size: 13))
        .fixedSize()
        .onAppear { nameFocused = selectName; searchFocused = model.showsIcons }
        .onChange(of: model.showsIcons) { _ in resized() }
        .onChange(of: model.query) { _ in resized() }
    }

    private func swatch(_ hex: String?, name: String) -> some View {
        let isCurrent = model.isCurrentColor(hex)
        return Button { model.chooseColor(hex) } label: {
            Group {
                if let color = hex.flatMap(workspaceSidebarColor) { Circle().fill(color) }
                else {
                    // Default is no color: a slashed ring, as in the menu's palette.
                    let stroke = Color(nsColor: .secondaryLabelColor)
                    Circle().strokeBorder(stroke, lineWidth: 1.5)
                        .overlay(Capsule().fill(stroke).frame(width: 1.5).padding(3).rotationEffect(.degrees(45)))
                }
            }
            .frame(width: 21, height: 21)
            .padding(2)
            .overlay(Circle().strokeBorder(isCurrent ? Color.primary.opacity(0.65) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name + " color")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Emoji").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(6)
            TextField("Search emoji or paste one", text: $model.query)
                .textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityLabel("Search emoji")
            ScrollView {
              LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 5), spacing: 8) {
                ForEach(workspaceSidebarEmojiMatches(model.query), id: \.emoji) { item in
                    Button { model.chooseEmoji(item.emoji) } label: {
                        Text(item.emoji).font(.system(size: 23)).frame(width: 34, height: 34)
                            .background(model.emoji == item.emoji ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).accessibilityLabel(item.keywords)
                }
              }
            }.frame(height: min(252, CGFloat((workspaceSidebarEmojiMatches(model.query).count + 4) / 5) * 42))
            if workspaceSidebarEmojiMatches(model.query).isEmpty { Text("No matching emoji").foregroundStyle(.secondary) }
            Button("Remove Icon") { model.chooseEmoji(nil) }.buttonStyle(WorkspaceSidebarIdentityButtonStyle())
                .disabled(model.emoji == nil)
            Text("You can also paste any emoji.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(8)
    }
}

struct WorkspaceSidebarIdentityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false
        // A custom style has to dim itself when disabled.
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .background(Color.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.16 : (isHovered ? 0.09 : 0)),
                    in: RoundedRectangle(cornerRadius: 5))
                .onHover { isHovered = $0 }
        }
    }
}

let workspaceSidebarIdentityColors: [(name: String, hex: String)] = [
    ("Green", "#00B894"), ("Blue", "#009AD0"), ("Purple", "#8070BA"),
    ("Yellow", "#E8B000"), ("Pink", "#DE85A3"), ("Red", "#D75A6B"), ("Orange", "#EA8150"),
]

struct WorkspaceSidebarEmojiChoice {
    let emoji: String
    let keywords: String
}

func workspaceSidebarEmojiMatches(_ query: String) -> [WorkspaceSidebarEmojiChoice] {
    let choices: [(String, String)] = [
        ("💻", "computer laptop code development"), ("🏠", "home house personal"), ("💼", "work briefcase office"),
        ("✏️", "pencil write drawing design"), ("📝", "notes memo writing document"), ("🎨", "art palette design creative"),
        ("📚", "books reading study research"), ("🔬", "science microscope research"), ("🌐", "web globe internet browser"),
        ("🚀", "rocket launch startup"), ("⚙️", "gear settings engineering"), ("🛠️", "tools hammer wrench engineering"),
        ("📁", "folder files documents"), ("📊", "chart analysis analytics data"), ("📅", "calendar schedule meetings"),
        ("💬", "chat messages communication"), ("📧", "email mail inbox"), ("🎯", "target goal focus"),
        ("⭐️", "star favorite"), ("❤️", "heart love"), ("🌸", "flower spring blossom"),
        ("🌱", "plant seedling grow"), ("☀️", "sun summer day"), ("🌙", "moon night"), ("🔥", "fire hot urgent"),
        ("🎵", "music note audio"), ("🎮", "game controller play"), ("📷", "camera photo"), ("🎬", "movie video film"),
        ("✈️", "plane travel flight"), ("☕️", "coffee break"), ("🧠", "brain ideas think"), ("💡", "light bulb idea"),
        ("✅", "check done complete"), ("🧪", "test tube experiment"), ("🐛", "bug debug"), ("🔒", "lock security private"),
        ("📌", "pin important"), ("🧭", "compass explore"), ("🦊", "fox animal"),
    ]
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let pasted = normalizedWorkspaceProjectEmoji(text) { return [.init(emoji: pasted, keywords: "Use \(pasted)")] }
    return choices.filter { text.isEmpty || $0.1.contains(text) }.map { .init(emoji: $0.0, keywords: $0.1) }
}

/// Where a control is on screen, for opening its menu without a click. Each control holds its
/// own, so the same tab drawn in two places, such as its list and another display's drop
/// column, keeps two.
@MainActor
final class WorkspaceSidebarMenuAnchor {
    weak var view: NSView?

    /// The control's bottom-left corner on screen, where a menu opened without a click appears.
    var point: NSPoint? {
        guard let view, let window = view.window else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return NSPoint(x: frame.minX, y: frame.minY)
    }

    var monitorScopeId: String? { view.flatMap(workspaceSidebarMenuScope(of:)) }
}

/// The display of the sidebar that a control is in, which its menu's actions are for.
@MainActor
func workspaceSidebarMenuScope(of view: NSView) -> String? {
    (view.window as? WorkspaceSidebarPanel)?.monitorScopeId
}

/// Right clicks and Control-clicks go to `open`, while ordinary clicks and drags pass through
/// to the control underneath.
struct WorkspaceSidebarMenuTrigger: NSViewRepresentable {
    let anchor: WorkspaceSidebarMenuAnchor
    let open: @MainActor (NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> Trigger {
        let view = Trigger(open: open)
        anchor.view = view
        return view
    }

    func updateNSView(_ view: Trigger, context: Context) {
        view.open = open
        anchor.view = view
    }

    final class Trigger: NSView {
        var open: @MainActor (NSEvent, NSView) -> Void
        init(open: @escaping @MainActor (NSEvent, NSView) -> Void) { self.open = open; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)), let event = NSApp.currentEvent,
                  workspaceSidebarOpensContextMenu(event)
            else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { open(event, self) }
        override func mouseDown(with event: NSEvent) { open(event, self) }
    }
}

/// Only these reach the trigger; every other event goes to the row underneath.
func workspaceSidebarOpensContextMenu(_ event: NSEvent) -> Bool {
    event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
}

/// An item's native menu on right-click, Control-click and VoiceOver's Show Menu, and its
/// editor through the named action. `tabActions` also names the menu for a Tabs row.
struct WorkspaceSidebarIdentityMenuModifier: ViewModifier {
    let target: WorkspaceSidebarIdentityTarget
    var tabActions = false
    @State private var anchor = WorkspaceSidebarMenuAnchor()

    func body(content: Content) -> some View {
        let target = target
        let anchor = anchor
        content
            .overlay { WorkspaceSidebarMenuTrigger(anchor: anchor) { WorkspaceSidebarIdentityMenu.showMenu(target, with: $0, in: $1) } }
            .accessibilityAction(.showMenu) { WorkspaceSidebarIdentityMenu.show(target, from: anchor) }
            .modifier(WorkspaceSidebarNamedMenuAction(name: tabActions ? "Tab Actions" : nil) {
                WorkspaceSidebarIdentityMenu.show(target, from: anchor)
            })
            .accessibilityAction(named: "Edit Name, Color and Icon") { WorkspaceSidebarIdentityMenu.show(target, from: anchor, selectName: true) }
    }
}

private struct WorkspaceSidebarNamedMenuAction: ViewModifier {
    let name: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let name { content.accessibilityAction(named: name, action) } else { content }
    }
}

/// A menu built from entries when it opens, such as an app's, shown by the same native renderer.
struct WorkspaceSidebarNativeContextMenu: ViewModifier {
    let entries: @MainActor () -> [WorkspaceSidebarAppMenuEntry]
    @State private var anchor = WorkspaceSidebarMenuAnchor()

    func body(content: Content) -> some View {
        let entries = entries
        let anchor = anchor
        content
            .overlay {
                WorkspaceSidebarMenuTrigger(anchor: anchor) { event, view in
                    WorkspaceSidebarIdentityMenu.shared.show(workspaceSidebarNativeAppMenu(entries()), click: (event, view))
                }
            }
            .accessibilityAction(.showMenu) {
                WorkspaceSidebarIdentityMenu.shared.show(workspaceSidebarNativeAppMenu(entries()),
                    at: anchor.point ?? NSEvent.mouseLocation)
            }
    }
}

extension View {
    func sidebarIdentityMenu(_ target: WorkspaceSidebarIdentityTarget) -> some View {
        modifier(WorkspaceSidebarIdentityMenuModifier(target: target))
    }
}

/// `sidebarIdentityMenu`, for a control that offers it only sometimes.
struct WorkspaceSidebarOptionalIdentityMenu: ViewModifier {
    let target: WorkspaceSidebarIdentityTarget?

    func body(content: Content) -> some View {
        if let target { content.sidebarIdentityMenu(target) } else { content }
    }
}

/// A Tabs row's menu: the tab's own for a tab's row, or only Close Window for a window listed
/// inside a folder.
struct WorkspaceSidebarTabRowMenu: ViewModifier {
    let target: WorkspaceSidebarIdentityTarget?
    let close: () -> Void

    func body(content: Content) -> some View {
        if let target {
            content.modifier(WorkspaceSidebarIdentityMenuModifier(target: target, tabActions: true))
        } else {
            content.contextMenu { Button("Close Window", action: close) }
        }
    }
}
