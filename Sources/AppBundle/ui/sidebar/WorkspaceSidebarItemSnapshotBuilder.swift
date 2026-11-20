@MainActor
func buildWorkspaceSidebarItems(
    for content: WorkspaceTabSnapshot,
    currentFocus: LiveFocus,
) async -> (items: [WorkspaceSidebarItemViewModel], associated: [WorkspaceSidebarAssociatedWindowViewModel]) {
    let displayed = content.root.sidebarWindows + content.floatingMembers.map(\.window)
    var windows: [UInt32: WorkspaceSidebarWindowViewModel] = [:]
    for window in displayed where windows[window.windowId] == nil {
        guard let member = content.member(window.windowId) else { continue }
        windows[window.windowId] = await makeWorkspaceSidebarWindowViewModel(for: window,
            workspaceName: content.workspace.name, currentFocus: currentFocus, state: member.state)
    }
    var items = buildWorkspaceSidebarContainerItems(content.root, windows: windows,
        workspaceName: content.workspace.name, currentFocus: currentFocus)
    items += content.floatingMembers.compactMap { member in
        windows[member.window.windowId].map { .init(kind: .window($0)) }
    }
    // A stack retains its existing folder presentation; only ordinary rows nest auxiliary windows.
    guard config.usesBrowserTabs, !items.contains(where: { if case .tabGroup = $0.kind { true } else { false } })
    else { return (items, []) }
    let links = Dictionary(uniqueKeysWithValues: content.floatingMembers.compactMap { member -> (UInt32, WorkspaceTabAttachment)? in
        guard let attachment = member.attachment,
              attachment.listedUnderWindowId != nil || content.isPinned && attachment.hasLiveParent else { return nil }
        return (member.window.windowId, attachment)
    })
    let listed = Set(items.compactMap { item -> UInt32? in
        guard case .window(let window) = item.kind, links[window.windowId] == nil else { return nil }
        return window.windowId
    })
    var main: [WorkspaceSidebarItemViewModel] = []
    var associated: [WorkspaceSidebarAssociatedWindowViewModel] = []
    for item in items {
        if case .window(let window) = item.kind, let link = links[window.windowId], let parent = link.parentWindowId,
           link.listedUnderWindowId == nil || listed.contains(parent) {
            associated.append(.init(window: window, parentWindowId: parent, role: link.role))
        } else { main.append(item) }
    }
    return (main, associated)
}
