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
}

/// The editable identity section is shared by every mode and item type. Actions below
/// it remain specific to the item; choosing a swatch never dismisses the editor.
@MainActor
final class WorkspaceSidebarIdentityMenuModel: ObservableObject {
    @Published var name: String
    @Published var color: String?
    @Published var emoji: String?
    @Published var showsIcons = false
    @Published var query = ""
    var committedName: String
    let rename: (String) -> Void
    let setColor: (String?) -> Void
    let setEmoji: (String?) -> Void
    let entries: [WorkspaceSidebarAppMenuEntry]

    init(name: String, color: String?, emoji: String?, rename: @escaping (String) -> Void,
         setColor: @escaping (String?) -> Void, setEmoji: @escaping (String?) -> Void,
         entries: [WorkspaceSidebarAppMenuEntry]) {
        self.name = name
        committedName = name
        self.color = color
        self.emoji = emoji
        self.rename = rename
        self.setColor = setColor
        self.setEmoji = setEmoji
        self.entries = entries
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
    switch target {
        case .project(let id):
            guard let project = TrayMenuModel.shared.workspaceSidebarProjects.first(where: { $0.id == id }) else { return nil }
            return .init(name: project.displayName, color: project.colorHex, emoji: project.emoji,
                rename: { send(.renameProject(id, displayName: $0)) },
                setColor: { send(.setProjectColor(id, colorHex: $0)) },
                setEmoji: { send(.setProjectEmoji(id, emoji: $0)) },
                entries: [
                    .init(title: "Switch to Project", perform: { send(.selectProject(id)) }),
                    .init(title: "New Project", perform: { send(.createProject) }),
                    .separator,
                    .init(title: "Delete Project", enabled: canDeleteWorkspaceProject(id), isDestructive: true,
                        perform: { send(.deleteProject(id)) }),
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
                        perform: { send(.toggleTabCollection(id)) }),
                    .init(title: "Move Group to", enabled: TrayMenuModel.shared.workspaceSidebarProjects.count > 1,
                        children: TrayMenuModel.shared.workspaceSidebarProjects.filter { $0.id != group.projectId }.map { project in
                            .init(title: project.displayName, perform: { send(.moveTabCollection(id, project.id)) })
                        }),
                    .init(title: "Ungroup Tabs", perform: { send(.ungroupTabCollection(id)) }),
                    .separator,
                    .init(title: "New Tab in Group", perform: {
                        send(.createTabInCollection(id, monitorScopeId: createMonitorScopeId ?? scope))
                    }),
                ])
    }
}

@MainActor
func workspaceSidebarWorkspaceIdentityMenuModel(_ workspace: WorkspaceSidebarWorkspaceViewModel,
    windowId: UInt32? = nil,
    send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> WorkspaceSidebarIdentityMenuModel {
    let name = workspace.name
    var entries = workspaceSidebarWorkspaceMenu(workspace, rename: {}, send: send)
        .filter { $0.title != "Rename Workspace" && $0.title != "Rename Tab" }
    if config.usesBrowserTabs {
        let separate = entries.first { $0.title == "Separate into Tabs" }
        let keepEntries = entries.filter { $0.title != "Separate into Tabs" }
        let groups = workspaceSidebarOrganizationStore.state.collections.filter { $0.projectId == workspace.projectId }
        var destinations: [WorkspaceSidebarAppMenuEntry] = [
            .init(title: "New Group…", perform: { send(.createTabCollection(name)) }),
        ]
        if !groups.isEmpty { destinations.append(.separator) }
        destinations += groups.map { group in
            .init(title: (group.emoji.map { $0 + " " } ?? "") + group.name,
                checked: group.workspaceNames.contains(name), perform: { send(.assignTabCollection(name, group.id)) })
        }
        if workspaceSidebarOrganizationStore.collection(containing: name) != nil {
            destinations += [.separator, .init(title: "Remove from Group", perform: { send(.assignTabCollection(name, nil)) })]
        }
        entries = [
            .init(title: workspace.appearance.isFavorite ? "Unpin Tab" : "Pin Tab",
                perform: { send(.setWorkspaceFavorite(name, !workspace.appearance.isFavorite)) }),
            .init(title: "Add to Group", children: destinations),
            .init(title: "Move to Project", enabled: TrayMenuModel.shared.workspaceSidebarProjects.count > 1,
                children: TrayMenuModel.shared.workspaceSidebarProjects.filter { $0.id != workspace.projectId }.map { project in
                    .init(title: project.displayName, perform: { send(.moveWorkspace(name, toProject: project.id)) })
                }),
        ]
        let windows = workspaceSidebarPinnedTabWindows(workspace)
        let clickedWindow = windows.first(where: { $0.windowId == windowId }) ?? (windows.count == 1 ? windows.first : nil)
        if let window = clickedWindow, let sourceId = Workspace.existing(byName: name)?.id {
            let splitTargets = workspaceSidebarSplitDestinations(windowId: window.windowId)
            entries.append(.init(title: "Split with", enabled: !splitTargets.isEmpty, children: splitTargets.map { target in
                let snapshot = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == target.name }
                let label = snapshot.map { tab in
                    tab.sidebarLabel.isEmpty
                        ? workspaceSidebarPinnedTabWindows(tab).map { $0.title ?? $0.appName }.joined(separator: " · ")
                        : tab.displayName
                }?.takeIf { !$0.isEmpty } ?? workspaceDisplayName(target.name)
                let emoji = snapshot?.appearance.emoji.map { $0 + " " } ?? ""
                return .init(title: emoji + label,
                    perform: { send(.splitTabWindow(window.windowId, fromWorkspace: sourceId, withWorkspace: target.id)) })
            }))
        }
        entries.append(.separator)
        if let window = clickedWindow, windows.count > 1 {
            entries.append(.init(title: "Move \(window.appName) to New Tab", perform: { send(.detachTabWindow(window.windowId)) }))
        }
        if let separate { entries.append(separate) }
        entries += [.separator] + keepEntries + [.separator]
        if let window = clickedWindow {
            entries.append(.init(title: "Close Window", isDestructive: true, perform: { send(.closeWindow(window.windowId)) }))
        }
        if windows.count > 1 {
            entries.append(.init(title: "Close All Windows in Split…", isDestructive: true, perform: { send(.closeTabWindows(name)) }))
        } else if windows.isEmpty {
            entries.append(.init(title: "Close Empty Tab", isDestructive: true, perform: { send(.closeEmptyTab(name)) }))
        }
    }
    var clean: [WorkspaceSidebarAppMenuEntry] = []
    for entry in entries where !entry.title.isEmpty || clean.last?.title.isEmpty == false { clean.append(entry) }
    if clean.last?.title.isEmpty == true { clean.removeLast() }
    return .init(name: workspace.displayName, color: workspace.appearance.colorHex, emoji: workspace.appearance.emoji,
        rename: { send(.renameWorkspace(name, displayName: $0)) },
        setColor: { send(.setWorkspaceColor(name, $0)) }, setEmoji: { send(.setWorkspaceEmoji(name, $0)) }, entries: clean)
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
    static var isVisible: Bool { shared.panel?.isVisible == true }

    static func show(_ target: WorkspaceSidebarIdentityTarget, at point: NSPoint = NSEvent.mouseLocation,
                     selectName: Bool = false, showsIcons: Bool = false) {
        let scope = workspaceSidebarMonitorScopeId(for: normalizeAppKitScreenPoint(point).monitorApproximation)
        guard let model = workspaceSidebarIdentityMenuModel(target, targetMonitorScopeId: scope) else { return }
        model.showsIcons = showsIcons
        shared.open(model, at: point, selectName: selectName)
    }

    func open(_ model: WorkspaceSidebarIdentityMenuModel, at point: NSPoint, selectName: Bool) {
        close(commit: true)
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

struct WorkspaceSidebarIdentityMenuView: View {
    @ObservedObject var model: WorkspaceSidebarIdentityMenuModel
    var selectName = false
    var resized: () -> Void = {}
    var dismiss: (Bool) -> Void = { _ in }
    @FocusState private var nameFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $model.name)
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
                ForEach(model.entries.indices, id: \.self) { index in entry(model.entries[index]) }
                Divider()
                Button("Reset Appearance") {
                    model.chooseColor(nil)
                    model.chooseEmoji(nil)
                }.buttonStyle(WorkspaceSidebarIdentityButtonStyle()).padding(.horizontal, 7)
            }
            .frame(width: 252)
            if model.showsIcons { iconPicker.frame(width: 218) }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .font(.system(size: 13))
        .fixedSize()
        .onAppear { nameFocused = selectName; searchFocused = model.showsIcons }
        .onChange(of: model.showsIcons) { _ in resized() }
        .onChange(of: model.query) { _ in resized() }
    }

    private func swatch(_ hex: String?, name: String) -> some View {
        Button { model.chooseColor(hex) } label: {
            Circle().fill(hex.flatMap(workspaceSidebarColor) ?? Color(nsColor: .secondaryLabelColor))
                .frame(width: 21, height: 21)
                .padding(2)
                .overlay(Circle().strokeBorder(model.color == hex ? Color.primary.opacity(0.65) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name + " color")
        .accessibilityAddTraits(model.color == hex ? .isSelected : [])
    }

    @ViewBuilder private func entry(_ entry: WorkspaceSidebarAppMenuEntry) -> some View {
        if entry.title.isEmpty { Divider() }
        else if !entry.children.isEmpty {
            Menu {
                WorkspaceSidebarAppContextMenu(entries: entry.children.map { child in
                    var value = child
                    value.perform = { dismiss(true); child.perform?() }
                    return value
                })
            } label: { Text(entry.title).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
            .menuStyle(.borderlessButton)
            .disabled(!entry.enabled)
        } else {
            Button { dismiss(true); entry.perform?() } label: {
                HStack {
                    Text(entry.title)
                    Spacer()
                    if entry.checked { Image(systemName: "checkmark") }
                }.padding(7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(WorkspaceSidebarIdentityButtonStyle())
            .foregroundStyle(entry.isDestructive ? Color.red : Color.primary)
            .disabled(!entry.enabled)
        }
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
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.09 : 0)),
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

/// Right clicks are intercepted while ordinary clicks and drags pass through to the
/// original control. A keyboard accessibility action opens the identical editor.
struct WorkspaceSidebarIdentityMenuTrigger: NSViewRepresentable {
    let target: WorkspaceSidebarIdentityTarget
    func makeNSView(context: Context) -> Trigger { Trigger(target: target) }
    func updateNSView(_ view: Trigger, context: Context) { view.target = target }

    final class Trigger: NSView {
        var target: WorkspaceSidebarIdentityTarget
        init(target: WorkspaceSidebarIdentityTarget) { self.target = target; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(convert(point, from: superview)), let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { WorkspaceSidebarIdentityMenu.show(target) }
        override func mouseDown(with event: NSEvent) { WorkspaceSidebarIdentityMenu.show(target) }
    }
}

extension View {
    func sidebarIdentityMenu(_ target: WorkspaceSidebarIdentityTarget) -> some View {
        overlay { WorkspaceSidebarIdentityMenuTrigger(target: target) }
            .accessibilityAction(named: "Edit Name, Color and Icon") { WorkspaceSidebarIdentityMenu.show(target, selectName: true) }
    }
}
