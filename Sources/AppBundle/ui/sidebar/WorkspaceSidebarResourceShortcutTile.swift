import AppKit
import SwiftUI

/// A shortcut among the pins: its app's icon with a shortcut's arrow, its resource's name below, and a
/// dashed outline, as nothing that holds windows has. Clicked, it goes to its resource; ⌘-clicked, it
/// brings the window proven to show it here, where there's one. It's lit only while such a window is in
/// front, never for a shortcut WinMux can only open.
struct WorkspaceSidebarResourceShortcutTile: View {
    let shortcut: WorkspaceSidebarResourceShortcutViewModel
    var compact = false
    /// The project the sidebar shows, and its name, for the menu's scope item.
    let contextProjectId: WorkspaceProjectId
    let contextProjectName: String
    let send: @MainActor (WorkspaceSidebarAction) -> Void
    @State private var isHovered = false

    var body: some View {
        Button { go(bringHere: NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.shift)) } label: {
            VStack(spacing: 2) {
                icon
                    .overlay(alignment: .bottomTrailing) { WorkspaceSidebarShortcutArrow(compact: compact).offset(x: 3, y: 3) }
                if !compact {
                    Text(shortcut.name)
                        .font(.system(size: 9.5))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 34 : 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(shortcut.isActive ? 0.18 : (isHovered ? (compact ? 0.07 : 0.10) : 0)),
            in: RoundedRectangle(cornerRadius: compact ? 8 : 13))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 8 : 13)
                .strokeBorder(Color.primary.opacity(compact ? 0.22 : 0.26), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2.5]))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Image(systemName: shortcut.symbolName)
                .font(.system(size: compact ? 7 : 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(compact ? 2 : 5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .opacity(shortcut.isReadable ? 1 : 0.5)
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        .help(shortcut.isInAllProjects ? "\(shortcut.help)\nIn all projects" : shortcut.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shortcut.name), shortcut")
        .accessibilityValue([shortcut.app?.name, shortcut.isInAllProjects ? "In all projects" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(shortcut.help)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(shortcut.isActive ? .isSelected : [])
        .accessibilityAction { go(bringHere: false) }
        .workspaceSidebarShortcutBringHereAction(shortcut.findsItsWindow ? { go(bringHere: true) } : nil)
        .modifier(WorkspaceSidebarNativeContextMenu { [shortcut, contextProjectId, contextProjectName, send] in
            workspaceSidebarResourceShortcutMenuEntries(shortcut, contextProjectId: contextProjectId,
                contextProjectName: contextProjectName, send: send)
        })
    }

    @ViewBuilder
    private var icon: some View {
        let size: CGFloat = compact ? 18 : 22
        if let app = shortcut.app {
            WorkspaceSidebarTabIcon(bundleId: app.bundleId, bundlePath: app.bundlePath, size: size)
        } else {
            Image(systemName: shortcut.symbolName).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }

    private func go(bringHere: Bool) {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        send(.goToResourceShortcut(shortcut.id, bringHere: bringHere))
    }
}

/// A shortcut's mark, a small arrow in a disc on its icon's corner, as an alias has.
struct WorkspaceSidebarShortcutArrow: View {
    let compact: Bool

    var body: some View {
        let size: CGFloat = compact ? 9 : 11
        Image(systemName: "arrow.up.forward")
            .font(.system(size: size * 0.55, weight: .heavy))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// “Bring Window Here”, for a shortcut that finds its window, as ⌘-click.
    @ViewBuilder
    func workspaceSidebarShortcutBringHereAction(_ action: (() -> Void)?) -> some View {
        if let action { accessibilityAction(named: "Bring Window Here", action) } else { self }
    }
}

/// A shortcut's menu: go to it, change where it's shown or its link, or remove it, with Undo.
@MainActor
func workspaceSidebarResourceShortcutMenuEntries(_ shortcut: WorkspaceSidebarResourceShortcutViewModel,
                                                 contextProjectId: WorkspaceProjectId, contextProjectName: String,
                                                 send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> [WorkspaceSidebarAppMenuEntry] {
    let id = shortcut.id
    var entries: [WorkspaceSidebarAppMenuEntry] = [
        .header(named: shortcut.name, { "Shortcut to “\($0)”" }),
        .named(shortcut.name, { shortcut.findsItsWindow ? "Go to “\($0)”" : "Open “\($0)”" }, enabled: shortcut.isReadable,
            perform: { send(.goToResourceShortcut(id, bringHere: false)) }),
    ]
    if shortcut.findsItsWindow {
        entries.append(.init(title: "Bring Window Here", enabled: shortcut.isReadable,
            perform: { send(.goToResourceShortcut(id, bringHere: true)) },
            help: "Brings the window that shows it to this display, as ⌘-click does"))
    }
    entries.append(.separator)
    if shortcut.isLink, shortcut.isReadable {
        entries.append(.init(title: "Edit Link…", perform: { send(.editResourceShortcutLink(id)) },
            help: "Changes the address this shortcut opens"))
    }
    entries.append(shortcut.isInAllProjects
        ? .named(contextProjectName, { "Show in “\($0)” Only" },
            perform: { send(.setResourceShortcutScope(id, allProjects: false, projectId: contextProjectId)) })
        : .init(title: "Show in All Projects",
            perform: { send(.setResourceShortcutScope(id, allProjects: true, projectId: contextProjectId)) }))
    entries += [.separator, .init(title: "Remove Shortcut", perform: { send(.removeResourceShortcut(id)) },
        help: "Removes only the shortcut. Nothing it opened is closed.")]
    return entries
}
