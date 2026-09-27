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
        let text = tab.title.localizedLowercase + " " + header
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

/// Browser children intentionally have only selection. Window close, drag, split,
/// rename and workspace actions belong exclusively to the owning window's header.
struct WorkspaceSidebarBrowserTabRowView: View {
    let tab: BrowserTab
    let window: WorkspaceSidebarWindowViewModel
    let isActive: Bool
    let isSearchSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false
    @ObservedObject private var icons = BrowserTabIconModel.shared

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Group {
                    if let origin = tab.iconOrigin, let image = icons.images[origin] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    } else {
                        WorkspaceSidebarTabIcon(bundleId: window.appBundleId, bundlePath: window.appBundlePath, size: 16)
                    }
                }.frame(width: 16, height: 16)
                Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if tab.isSelected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: workspaceSidebarTabRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(isActive && tab.isSelected
                ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(isSearchSelected ? 0.13 : isHovered ? 0.06 : 0))
        }
        .onHover { isHovered = $0 }
        .onAppear { icons.request(tab.iconOrigin) }
        .onChange(of: tab.iconOrigin) { icons.request($0) }
        .help(tab.title)
        .accessibilityLabel("\(tab.title), browser tab in \(window.appName)")
        .accessibilityAddTraits(isActive && tab.isSelected ? .isSelected : [])
        .id(tab.target.rowId)
    }
}

struct WorkspaceSidebarBrowserTabGroupView<Header: View>: View {
    let snapshot: BrowserWindowTabs
    let window: WorkspaceSidebarWindowViewModel
    let tabs: [BrowserTab]
    let isActive: Bool
    let isSearching: Bool
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let activation: WorkspaceSidebarTabActivation
    let actions: WorkspaceSidebarActions
    @ViewBuilder let header: () -> Header
    @State private var collapsed = false

    private var isCollapsed: Bool { collapsed && !isActive && !isSearching }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
                Button {
                    guard !isActive, !isSearching else { return }
                    collapsed.toggle()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: workspaceSidebarTabRowHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isActive || isSearching)
                .accessibilityLabel(isCollapsed ? "Expand browser tabs" : "Collapse browser tabs")
                header()
                Text("\(tabs.count)").font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.trailing, 8)
            }
            if !isCollapsed {
                ForEach(tabs) { tab in
                    WorkspaceSidebarBrowserTabRowView(tab: tab, window: window,
                        isActive: isActive && window.isFocused,
                        isSearchSelected: selectedSearchTarget == .browserTab(tab.target)) {
                        activation.select(.selectBrowserTab(tab.target), send: actions.send)
                    }
                }.padding(.leading, 14).padding(.trailing, 4)
            }
        }
        .padding(.bottom, isCollapsed ? 0 : 4)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(window.appName), \(snapshot.tabs.count) browser tabs")
    }
}
