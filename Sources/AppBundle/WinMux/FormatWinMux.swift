import Common

/// A project as `list-projects --format` sees it (hook `projects` in format.swift).
struct ProjectFormatObject {
    let index: Int
    let project: WorkspaceProject
    let colorHex: String?
    let isFocused: Bool
    let isVisible: Bool
    let workspaceCount: Int
    let windowCount: Int
}

func expandProjectFormatVar(_ p: ProjectFormatObject, _ f: FormatVar.ProjectFormatVar) -> Result<Primitive, String> {
    switch f {
        case .projectIndex: .success(.int(p.index))
        case .projectId: .success(.string(p.project.id.rawValue))
        case .projectName: .success(.string(p.project.name))
        case .projectColor: .success(.string(p.colorHex ?? "auto"))
        case .projectFocused: .success(.bool(p.isFocused))
        case .projectVisible: .success(.bool(p.isVisible))
        case .projectWorkspaceCount: .success(.int(p.workspaceCount))
        case .projectWindowCount: .success(.int(p.windowCount))
    }
}

extension WinMuxHooks {
    /// `list-windows` order (hook `listWindowsOrder`): upstream's app name and title, then the window id, so windows
    /// that tie come out in the same order every time (the windows are gathered from an unordered set).
    static func windowListOrder(_ list: [WindowWithPrefetchedTitle]) -> [WindowWithPrefetchedTitle] {
        list.sorted {
            let leftApp = $0.window.app.name ?? "", rightApp = $1.window.app.name ?? ""
            if leftApp != rightApp { return leftApp < rightApp }
            let leftTitle = $0.title ?? "", rightTitle = $1.title ?? ""
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            return $0.window.windowId < $1.window.windowId
        }
    }
}
