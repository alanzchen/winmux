import SwiftUI

func workspaceSidebarBrowserSearchContext(_ workspace: WorkspaceSidebarWorkspaceViewModel,
    projects: [WorkspaceSidebarProjectViewModel], collections: [WorkspaceTabCollection]) -> String {
    ([projects.first { $0.id == workspace.projectId }?.displayName] +
        collections.filter { $0.workspaceNames.contains(workspace.name) }.map { Optional($0.name) })
        .compactMap { $0 }.joined(separator: " ")
}

func workspaceSidebarMatchingBrowserTabs(_ snapshot: BrowserWindowTabs?, window: WorkspaceSidebarWindowViewModel,
    workspace: WorkspaceSidebarWorkspaceViewModel, query: String, context: String = "") -> [BrowserTab] {
    guard workspaceSidebarTabPresentation(workspace) != .folder, let snapshot, snapshot.isGroup else { return [] }
    let terms = query.split(whereSeparator: \.isWhitespace).map { $0.localizedLowercase }
    guard !terms.isEmpty else { return snapshot.tabs }
    let header = workspaceSidebarBrowserHeaderSearchText(window, workspace: workspace, context: context)
    return snapshot.tabs.filter { tab in
        let text = [tab.title, tab.host ?? "", header].joined(separator: " ").localizedLowercase
        return terms.allSatisfy(text.contains)
    }
}

func workspaceSidebarBrowserHeaderMatchesSearch(_ window: WorkspaceSidebarWindowViewModel,
    workspace: WorkspaceSidebarWorkspaceViewModel, query: String, context: String = "") -> Bool {
    let text = workspaceSidebarBrowserHeaderSearchText(window, workspace: workspace, context: context)
    return query.split(whereSeparator: \.isWhitespace).map { $0.localizedLowercase }.allSatisfy(text.contains)
}

private func workspaceSidebarBrowserHeaderSearchText(_ window: WorkspaceSidebarWindowViewModel,
    workspace: WorkspaceSidebarWorkspaceViewModel, context: String) -> String {
    [window.appName, window.appBundleId ?? "", workspaceSidebarSearchableBundleName(window.appBundlePath) ?? "",
     workspace.sidebarLabel, workspace.displayName, workspace.name, context].joined(separator: " ").localizedLowercase
}

func workspaceSidebarBrowserTabAccessibilityLabel(_ tab: BrowserTab, appName: String) -> String {
    let sound = switch tab.audio {
        case .playing: ", playing sound"
        case .muted: ", muted"
        case nil: ""
    }
    return "\(tab.title)\(sound), browser tab in \(appName)"
}

/// A browser tab selects and closes, like a tab in the browser's own tab bar. Window close,
/// drag, split, rename and workspace actions belong exclusively to the owning window's header.
struct WorkspaceSidebarBrowserTabRowView: View {
    let tab: BrowserTab
    let window: WorkspaceSidebarWindowViewModel
    let isActive: Bool
    let isSearchSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @ObservedObject private var icons = BrowserTabIconModel.shared
    @ObservedObject private var siteIcons = SafariExtensionIcons.shared
    @Environment(\.workspaceSidebarTabIndent) private var indent
    @Environment(\.workspaceSidebarReducesMotion) private var reducesMotion

    private var isShown: Bool { isActive && tab.isSelected }

    var body: some View {
        Button(action: onSelect) {
            // The same columns as a tab's row: icon, title, then the trailing slot.
            HStack(spacing: 9) {
                Group {
                    if let key = tab.siteIcon, let image = siteIcons.images[key] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else if let origin = tab.iconOrigin, let image = icons.images[origin] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath)
                    }
                }.frame(width: workspaceSidebarTabIconSize, height: workspaceSidebarTabIconSize)
                Text(tab.title)
                    .font(.system(size: 13, weight: isShown ? .medium : .regular))
                    .foregroundStyle(Color.primary.opacity(isShown ? 0.95 : 0.82))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let audio = tab.audio {
                    Image(systemName: audio == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .help(audio == .muted ? "Muted" : "Playing sound")
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                Group {
                    if tab.isSelected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .opacity(isHovered ? 0 : 1)
                    }
                }.frame(width: workspaceSidebarTabTrailingSlotWidth)
            }
            .padding(.leading, indent.leadingPadding)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, maxHeight: workspaceSidebarTabRowHeight,
                alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Over the row, as on a tab's row, so closing never also selects the tab.
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityHidden(true)
            .frame(width: workspaceSidebarTabTrailingSlotWidth)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .background {
            RoundedRectangle(cornerRadius: indent.rowCornerRadius, style: .continuous)
                .fill(isShown ? Color(nsColor: .controlBackgroundColor)
                    : Color.primary.opacity(isSearchSelected ? 0.13 : isHovered ? 0.06 : 0))
                .shadow(color: isShown ? Color.black.opacity(0.22) : .clear, radius: 3, y: 1)
        }
        .animation(WorkspaceSidebarTabMotion.selection(reducesMotion: reducesMotion), value: isShown)
        .overlay {
            WindowMiddleClickCatcher(browserTab: tab.target) { close() }
        }
        .onHover { hovering in withAnimation(WorkspaceSidebarTabMotion.hover) { isHovered = hovering } }
        .contextMenu {
            Button("Close Tab") { close() }
        }
        .accessibilityAction(named: "Close") { close() }
        .onAppear { icons.request(tab.iconOrigin) }
        .onChange(of: tab.iconOrigin) { icons.request($0) }
        .help(tab.title)
        .accessibilityLabel(workspaceSidebarBrowserTabAccessibilityLabel(tab, appName: window.appName))
        .accessibilityAddTraits(isShown ? .isSelected : [])
        .id(tab.target.rowId)
    }

    private func close() {
        guard !isWorkspaceSidebarDragInProgress() else { return }
        onClose()
    }
}

/// A browser window's tabs, in the same card as every other group. The header is the
/// window's own row, which selects, drags, and closes the window.
struct WorkspaceSidebarBrowserTabGroupView<Header: View>: View {
    let snapshot: BrowserWindowTabs
    let window: WorkspaceSidebarWindowViewModel
    let tabs: [BrowserTab]
    let isActive: Bool
    let isSearching: Bool
    var tint: Color? = nil
    var cardCornerRadius: CGFloat? = nil
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let activation: WorkspaceSidebarTabActivation
    let actions: WorkspaceSidebarActions
    @ViewBuilder let header: () -> Header
    @State private var collapsed = false

    /// The tab in use, and a search, always show the window's tabs.
    private var canToggle: Bool { !isActive && !isSearching }
    private var isCollapsed: Bool { collapsed && canToggle }

    var body: some View {
        WorkspaceSidebarTabGroupCard(tint: tint, isExpanded: !isCollapsed, isActive: isActive, cornerRadius: cardCornerRadius) {
            header()
                .overlay(alignment: .leading) {
                    WorkspaceSidebarTabDisclosureButton(isExpanded: !isCollapsed, tint: tint, canToggle: canToggle,
                        label: isCollapsed ? "Expand browser tabs" : "Collapse browser tabs") { collapsed.toggle() }
                }
        } content: {
            ForEach(tabs) { tab in
                WorkspaceSidebarBrowserTabRowView(tab: tab, window: window,
                    isActive: isActive && window.isFocused,
                    isSearchSelected: selectedSearchTarget == .browserTab(tab.target),
                    onSelect: { activation.select(.selectBrowserTab(tab.target), send: actions.send) },
                    onClose: { actions.send(.closeBrowserTab(tab.target)) })
                .transition(.workspaceSidebarTabReveal)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(window.appName), \(snapshot.tabs.count) browser tabs")
    }
}
