struct WorkspaceSidebarWindowViewModel: Hashable, Identifiable {
    let windowId: UInt32
    let workspaceName: String
    let appName: String
    let appBundleId: String?
    let appBundlePath: String?
    let title: String?
    let isFocused: Bool

    var id: UInt32 { windowId }
}

/// Tabs mode: an auxiliary window, listed one level under the window of its tab it was opened from.
struct WorkspaceSidebarAssociatedWindowViewModel: Hashable, Identifiable {
    let window: WorkspaceSidebarWindowViewModel
    let parentWindowId: UInt32
    let role: AuxiliaryWindowRole

    var id: UInt32 { window.windowId }
}

struct WorkspaceSidebarTabGroupViewModel: Hashable, Identifiable {
    let representativeWindowId: UInt32
    let workspaceName: String
    let title: String
    let windowCount: Int
    let isFocused: Bool
    let tabs: [WorkspaceSidebarWindowViewModel]
    var searchVisibleTabs: [WorkspaceSidebarWindowViewModel]? = nil
    /// Every window in the stack, including all windows of a split inside one tab. Tabs mode
    /// lists windows, not tabs; other modes leave this empty.
    var allWindows: [WorkspaceSidebarWindowViewModel] = []

    var id: String { "group:\(representativeWindowId)" }
}
