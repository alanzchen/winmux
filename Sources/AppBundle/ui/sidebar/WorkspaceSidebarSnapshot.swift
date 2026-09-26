import CoreGraphics

struct WorkspaceSidebarSnapshot: Equatable {
    var workspaces: [WorkspaceSidebarWorkspaceViewModel]
    var projects: [WorkspaceSidebarProjectViewModel]
    var activeProjectId: WorkspaceProjectId
    var monitorScopes: [WorkspaceSidebarMonitorScopeViewModel]
    var selectedMonitorScopeId: String
    var targetMonitorScopeId: String
    var focusedMonitorScopeId: String
    var visibleWidth: CGFloat
    var hoveredWorkspaceName: String?
    var dropPreview: WorkspaceSidebarDropPreviewViewModel?
    var configuration: WorkspaceSidebarConfiguration
    var dockDrag: WorkspaceSidebarDockDragPresentation? = nil
    // Unprojected counts keep drag-hover previews from resizing their own targets.
    var dockRestingAppCounts: [String: Int]? = nil

    static let empty = WorkspaceSidebarSnapshot(
        workspaces: [],
        projects: [],
        activeProjectId: workspaceProjectDefaultId,
        monitorScopes: [],
        selectedMonitorScopeId: workspaceSidebarDefaultScopeId,
        targetMonitorScopeId: workspaceSidebarDefaultScopeId,
        focusedMonitorScopeId: "",
        visibleWidth: 0,
        hoveredWorkspaceName: nil,
        dropPreview: nil,
        configuration: .empty,
    )
}

struct WorkspaceSidebarConfiguration: Equatable {
    var collapsedWidth: CGFloat
    var expandedWidth: CGFloat
    var topPadding: CGFloat
    var showMonitorSelector: Bool
    var showsClock: Bool
    var showsSeconds: Bool
    var showsDate: Bool
    var showsWeekday: Bool
    var showsStatusPills: Bool
    var chromeStyle: ChromeStyle
    var solidChromeColor: ChromeSolidColor
    var solidChromeCustomColor: String
    var showAppIcons: Bool = false
    var usesTabsList: Bool = false
    var showWorkspaceTooltips: Bool = true
    var showAppTooltips: Bool = true
    var showHiddenWorkspaceAppReminders: Bool = false
    var dockMagnification: Bool = false
    var dockMagnificationAmount: Double = 0.5
    var dockIconSize: CGFloat = CGFloat(WorkspaceSidebarConfig.defaultDockIconSize)
    var dockPosition: WorkspaceDockPosition = .left
    var compactLeftGap: CGFloat = 0
    var glassOpacity: Double = 1
    var sidebarBackgroundOpacity: Double = 0.70
    var sidebarBlur: Bool = true
    // Auto-hide makes collapsedWidth zero; the compact layout retains its resolved rail width.
    var configuredCollapsedWidth: CGFloat? = nil
    var alwaysExpanded: Bool = false

    var compactRailWidth: CGFloat {
        showAppIcons ? WorkspaceSidebarConfig.dockWidth(forIconSize: dockIconSize) : configuredCollapsedWidth ?? collapsedWidth
    }
    var compactDockScale: CGFloat { showAppIcons ? dockIconSize / CGFloat(WorkspaceSidebarConfig.defaultDockIconSize) : 1 }
    var compactHorizontalInset: CGFloat { workspaceSidebarCompactRailHorizontalInset * compactDockScale }
    var expansionStartWidth: CGFloat { showAppIcons ? compactRailWidth : collapsedWidth }
    var floatsExpandedView: Bool { showAppIcons && !alwaysExpanded }

    var effectiveGlassOpacity: Double {
        showAppIcons && chromeStyle == .liquidGlass ? glassOpacity : 1
    }

    static let empty = WorkspaceSidebarConfiguration(
        collapsedWidth: 0,
        expandedWidth: 0,
        topPadding: 12,
        showMonitorSelector: false,
        showsClock: false,
        showsSeconds: false,
        showsDate: false,
        showsWeekday: false,
        showsStatusPills: false,
        chromeStyle: .liquidGlass,
        solidChromeColor: .midnight,
        solidChromeCustomColor: "#191B20",
    )
}

enum WorkspaceSidebarAction: Equatable {
    case selectWorkspace(String)
    case overrideWorkspaceInUse(String)
    case expandForWorkspaceOverride
    case expandSidebar
    case selectWindow(UInt32)
    case closeWindow(UInt32)
    case selectApp(workspaceName: String, appId: String)
    case overrideWorkspaceInUseAndSelectApp(workspaceName: String, appId: String)
    case selectProject(WorkspaceProjectId)
    case createProject
    case renameProject(WorkspaceProjectId, displayName: String)
    case setProjectColor(WorkspaceProjectId, colorHex: String?)
    case editProjectEmoji(WorkspaceProjectId)
    case setProjectEmoji(WorkspaceProjectId, emoji: String?)
    case deleteProject(WorkspaceProjectId)
    case moveProject(WorkspaceProjectId, relativeTo: WorkspaceProjectId, after: Bool)
    case selectMonitorScope(String)
    case createWorkspace(projectId: WorkspaceProjectId, monitorScopeId: String)
    case renameWorkspace(String, displayName: String)
    case deleteWorkspace(String)
    /// Tabs mode: every window but the one in use gets a tab of its own.
    case separateWorkspaceIntoTabs(String)
    /// Tabs mode: closes an empty workspace's tab, moving to the next tab.
    case closeEmptyTab(String)
    case saveWorkspace(String)
    case forgetSavedWorkspace(String)
    case setSavedWorkspacePinned(String, Bool)
    case openSavedWorkspaceApps(String)
    case moveWorkspace(String, toProject: WorkspaceProjectId)
    case moveWindow(UInt32, toWorkspace: String)
    case moveTabGroup(UInt32, toWorkspace: String)
    case moveWindowToNewWorkspace(UInt32, projectId: WorkspaceProjectId, monitorScopeId: String)
    case moveTabGroupToNewWorkspace(UInt32, projectId: WorkspaceProjectId, monitorScopeId: String)
    case previewWindowDrop(UInt32, target: WorkspaceSidebarDropTargetKind)
    case previewTabGroupDrop(UInt32, target: WorkspaceSidebarDropTargetKind)
    case clearDropPreview
}

struct WorkspaceSidebarActions {
    var send: @MainActor (WorkspaceSidebarAction) -> Void
    var setDropTargets: @MainActor ([WorkspaceSidebarDropTargetFrame]) -> Void
    var setSurfaceFrame: @MainActor (CGRect) -> Void
    var setExpandedSurfaceFrame: @MainActor (CGRect?) -> Void
    var setExpandedDropTargets: @MainActor ([WorkspaceSidebarDropTargetFrame]) -> Void
    var setDockRestingWidth: @MainActor (CGFloat?) -> Void
    var setDockIconFrames: @MainActor ([CGRect]) -> Void
    var hoverWorkspace: @MainActor (String, Bool) -> Void
    var resolveAppDragWindow: @MainActor (String, String) -> UInt32?
    var windowDragChanged: @MainActor (UInt32, CGPoint) -> Void
    var appIconDragChanged: @MainActor (UInt32, CGPoint, CGFloat) -> Void
    var windowDragEnded: @MainActor (UInt32, CGPoint) -> Void
    var tabGroupDragChanged: @MainActor (UInt32, CGPoint) -> Void
    var tabGroupDragEnded: @MainActor (UInt32, CGPoint) -> Void

    init(
        send: @escaping @MainActor (WorkspaceSidebarAction) -> Void = { _ in },
        setDropTargets: @escaping @MainActor ([WorkspaceSidebarDropTargetFrame]) -> Void = { _ in },
        setSurfaceFrame: @escaping @MainActor (CGRect) -> Void = { _ in },
        setExpandedSurfaceFrame: @escaping @MainActor (CGRect?) -> Void = { _ in },
        setExpandedDropTargets: @escaping @MainActor ([WorkspaceSidebarDropTargetFrame]) -> Void = { _ in },
        setDockRestingWidth: @escaping @MainActor (CGFloat?) -> Void = { _ in },
        setDockIconFrames: @escaping @MainActor ([CGRect]) -> Void = { _ in },
        hoverWorkspace: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
        resolveAppDragWindow: @escaping @MainActor (String, String) -> UInt32? = { _, _ in nil },
        windowDragChanged: @escaping @MainActor (UInt32, CGPoint) -> Void = { _, _ in },
        windowDragEnded: @escaping @MainActor (UInt32, CGPoint) -> Void = { _, _ in },
        tabGroupDragChanged: @escaping @MainActor (UInt32, CGPoint) -> Void = { _, _ in },
        tabGroupDragEnded: @escaping @MainActor (UInt32, CGPoint) -> Void = { _, _ in },
        appIconDragChanged: (@MainActor (UInt32, CGPoint, CGFloat) -> Void)? = nil
    ) {
        self.send = send
        self.setDropTargets = setDropTargets
        self.setSurfaceFrame = setSurfaceFrame
        self.setExpandedSurfaceFrame = setExpandedSurfaceFrame
        self.setExpandedDropTargets = setExpandedDropTargets
        self.setDockRestingWidth = setDockRestingWidth
        self.setDockIconFrames = setDockIconFrames
        self.hoverWorkspace = hoverWorkspace
        self.resolveAppDragWindow = resolveAppDragWindow
        self.windowDragChanged = windowDragChanged
        self.appIconDragChanged = appIconDragChanged ?? { id, point, _ in windowDragChanged(id, point) }
        self.windowDragEnded = windowDragEnded
        self.tabGroupDragChanged = tabGroupDragChanged
        self.tabGroupDragEnded = tabGroupDragEnded
    }
}
