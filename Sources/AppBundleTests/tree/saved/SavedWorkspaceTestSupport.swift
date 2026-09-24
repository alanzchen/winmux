@testable import AppBundle
import AppKit
import Common
import XCTest

struct SavedWorkspaceTestMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
    let displayIdentity: MonitorDisplayIdentity?

    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }

    init(id: Int, name: String, x: CGFloat, y: CGFloat = 0, width: CGFloat = 1920, height: CGFloat = 1080, isMain: Bool = false, uuid: String?, isBuiltin: Bool = false) {
        monitorAppKitNsScreenScreensId = id
        self.name = name
        rect = Rect(topLeftX: x, topLeftY: y, width: width, height: height)
        visibleRect = rect
        self.isMain = isMain
        displayIdentity = uuid.map { MonitorDisplayIdentity(uuid: $0, isBuiltin: isBuiltin) }
            ?? (isBuiltin ? MonitorDisplayIdentity(uuid: nil, isBuiltin: true) : nil)
    }

    func moved(toX x: CGFloat, y: CGFloat = 0, isMain: Bool? = nil) -> SavedWorkspaceTestMonitor {
        SavedWorkspaceTestMonitor(
            id: monitorAppKitNsScreenScreensId,
            name: name,
            x: x,
            y: y,
            width: rect.width,
            height: rect.height,
            isMain: isMain ?? self.isMain,
            uuid: displayIdentity?.uuid,
            isBuiltin: displayIdentity?.isBuiltin ?? false,
        )
    }
}

let savedTestNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Puts the saved-workspace runtime in a known state: WinMux has been running a while (so the
/// startup restore window is over) and the given apps are running.
@MainActor
func setSavedWorkspaceTestEnvironment(
    now: Date = savedTestNow,
    runningApps: [String: [SavedRunningApp]] = [:],
    runtimeReadyAgo: TimeInterval = 3600,
) {
    savedWorkspaceRuntime.environment = .forTests(now: now, runningApps: runningApps)
    savedWorkspaceRuntime.runtimeReadyAt = now.addingTimeInterval(-runtimeReadyAgo)
}

@MainActor
func savedTestFacts(
    now: Date = savedTestNow,
    runningApps: [String: [SavedRunningApp]] = [:],
    titles: [UInt32: String] = [:],
    flatten: Bool = false,
    oppositeOrientation: Bool = false,
    startupRestoreActive: Bool = false,
) -> SavedWorkspaceCaptureFacts {
    SavedWorkspaceCaptureFacts(
        now: now,
        runningApps: runningApps,
        titleByWindowId: titles,
        normalization: SavedLayoutNormalization(flatten: flatten, oppositeOrientation: oppositeOrientation),
        startupRestoreActive: startupRestoreActive,
    )
}

func savedSlot(_ id: String, bundleId: String = "com.test.editor", title: String? = nil, windowId: UInt32? = nil, pid: Int32? = nil, weight: CGFloat = 1, isMostRecent: Bool = false) -> SavedLayoutNode {
    .slot(SavedWindowSlot(id: id, bundleId: bundleId, title: title, weight: weight, isMostRecentInParent: isMostRecent, lastWindowId: windowId, lastPid: pid))
}

func savedContainer(_ layout: Layout = .tiles, _ orientation: Orientation = .h, weight: CGFloat = 1, _ children: [SavedLayoutNode]) -> SavedLayoutNode {
    .container(SavedLayoutContainer(layout: layout, orientation: orientation, weight: weight, children: children))
}

func savedRoot(_ layout: Layout = .tiles, _ orientation: Orientation = .h, _ children: [SavedLayoutNode]) -> SavedLayoutContainer {
    SavedLayoutContainer(layout: layout, orientation: orientation, children: children)
}

/// A compact description of a saved tree: `h[a v[b c]]`, with `t` for tab groups.
func savedShape(_ container: SavedLayoutContainer) -> String {
    func describe(_ node: SavedLayoutNode) -> String {
        switch node {
            case .slot(let slot): slot.id
            case .container(let container): savedShape(container)
        }
    }
    let kind = container.layout == .tabGroup ? "t" : container.orientation == .h ? "h" : "v"
    return "\(kind)[\(container.children.map(describe).joined(separator: " "))]"
}

/// A compact description of a live tree, with window ids.
@MainActor
func liveShape(_ container: TilingContainer) -> String {
    let kind = container.layout == .tabGroup ? "t" : container.orientation == .h ? "h" : "v"
    let children = container.children.map { child -> String in
        switch child.nodeCases {
            case .window(let window): String(window.windowId)
            case .tilingContainer(let nested): liveShape(nested)
            default: "?"
        }
    }
    return "\(kind)[\(children.joined(separator: " "))]"
}

@MainActor
func makeSavedTestWorkspace(_ name: String, displayName: String? = nil) throws -> Workspace {
    let workspace = Workspace.get(byName: name)
    try ensureSavedWorkspaceRecord(workspace)
    if let displayName {
        savedWorkspaceStore.update(named: name) { $0.displayName = displayName }
    }
    return workspace
}
