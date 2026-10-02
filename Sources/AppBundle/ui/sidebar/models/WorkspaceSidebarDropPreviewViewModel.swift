import SwiftUI

struct WorkspaceSidebarDropPreviewTabItem: Hashable {
    let title: String
    let appName: String
    let appBundleIdentifier: String?
    let appBundlePath: String?
}

struct WorkspaceSidebarDropPreviewViewModel: Hashable {
    let sourceWindowId: UInt32
    var label: String
    let appName: String
    let appBundleIdentifier: String?
    let appBundlePath: String?
    let targetWorkspaceName: String?
    let targetsNewWorkspace: Bool
    let targetProjectId: WorkspaceProjectId?
    let targetMonitorScopeId: String?
    var isTabGroup: Bool
    var windowCount: Int
    var tabItems: [WorkspaceSidebarDropPreviewTabItem]
    /// Tabs mode: the side of the target tab it goes, or a stack.
    var targetCollectionId: String? = nil
    var targetPlacement: WorkspaceSidebarTabDropPlacement? = nil
    /// Tabs mode: where its split label sits, away from the pointer.
    var targetLabelSlot: WorkspaceSidebarTabDropLabelSlot? = nil
    /// Tabs mode: the gap between tabs it goes to.
    var targetGap: WorkspaceSidebarTabGap? = nil
    /// Tabs mode: the dragged window leaves others behind in its tab, so the gap gets a new tab.
    var separatesFromTab = false
    /// Tabs mode: the drop pins the tab.
    var targetsPinned = false
    /// Tabs mode: the pin it goes beside among the pinned tiles.
    var targetPinnedGap: WorkspaceSidebarTabGap? = nil
    /// Tabs mode: the dragged pinned tab the target tab joins, on the other side of the half shown.
    var receivingPinnedTabName: String? = nil
    /// Tabs mode: how many chosen tabs the drag carries together, when it carries several.
    var batchTabCount: Int? = nil

    init(
        sourceWindowId: UInt32,
        label: String,
        appName: String,
        appBundleIdentifier: String? = nil,
        appBundlePath: String? = nil,
        targetWorkspaceName: String?,
        targetsNewWorkspace: Bool,
        targetProjectId: WorkspaceProjectId? = nil,
        targetMonitorScopeId: String? = nil,
        isTabGroup: Bool,
        windowCount: Int,
        tabItems: [WorkspaceSidebarDropPreviewTabItem] = []
    ) {
        self.sourceWindowId = sourceWindowId
        self.label = label
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appBundlePath = appBundlePath
        self.targetWorkspaceName = targetWorkspaceName
        self.targetsNewWorkspace = targetsNewWorkspace
        self.targetProjectId = targetProjectId
        self.targetMonitorScopeId = targetMonitorScopeId
        self.isTabGroup = isTabGroup
        self.windowCount = windowCount
        self.tabItems = tabItems
    }
}
