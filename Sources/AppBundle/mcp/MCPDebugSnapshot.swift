import AppKit
import Common

/// The most a snapshot's JSON may be, in bytes: well within what an MCP client takes from one tool's answer.
@MainActor var mcpDebugSnapshotByteLimit = 64 * 1024
/// How long a snapshot waits for an app to answer its reads. One that hasn't is marked so, and its read is left
/// to finish on its own; until it does, no other is queued behind it.
@MainActor var mcpDebugSnapshotReadTimeout: Duration = .seconds(2)
/// Apps whose last snapshot read hasn't finished.
@MainActor private var debugSnapshotAppsReading: Set<Int32> = []

struct MCPDebugSnapshotOptions: Equatable, Sendable {
    /// Only these windows: the rows they're in, whole, and their events.
    var windowIds: Set<UInt32>? = nil
    var includeTitles = false
    /// A recording keeps events of its own, so its snapshots leave the log out.
    var includesEvents = true
    /// Below `mcpDebugSnapshotByteLimit`, for a recording's states, which must fit its fetch pages.
    var byteLimit: Int? = nil
}

/// What a snapshot reads from macOS for a window, live. Nothing read is kept.
struct DebugSnapshotNativeRead: Equatable, Sendable {
    var axFrame: Rect? = nil
    /// The AX error reading the frame got, if it failed.
    var axFrameError: String? = nil
    /// Whether the app's own list of its windows has it; nil when the list couldn't be read.
    var appListsWindow: Bool? = nil
    var appWindowListError: String? = nil
    /// Only when titles are asked for.
    var title: String? = nil
}

/// Reads the native facts of windows of one app for a snapshot, in one go, without recording anything it reads.
/// Tests replace it.
@MainActor var debugSnapshotNativeReads: @MainActor (_ windows: [Window], _ includeTitles: Bool) async -> [UInt32: DebugSnapshotNativeRead] = {
    windows, includeTitles in
    guard let app = (windows.first as? MacWindow)?.macApp else { return [:] }
    return (try? await app.debugSnapshotRead(windows.map(\.windowId), includeTitles: includeTitles)) ?? [:]
}

/// What an app's bundle is, by its path: a regular app, an app inside another one (a helper when it declares no
/// interface of its own), or an XPC service.
func debugSnapshotAppPathKind(_ bundlePath: String?, isHelper: Bool = false) -> String {
    guard let bundlePath, !bundlePath.isEmpty else { return "unknown" }
    let components = URL(fileURLWithPath: bundlePath).pathComponents
    if components.contains("XPCServices") || components.contains(where: { $0.hasSuffix(".xpc") }) { return "xpc" }
    guard components.count(where: { $0.hasSuffix(".app") }) > 1 else { return "app" }
    return isHelper ? "nestedHelper" : "nestedApp"
}

/// One JSON document for diagnosing window and sidebar problems: displays, the sidebar's rows as the panel draws
/// them with each member window's state, windows no row lists, and recent window events. It reads only: the
/// sidebar's model as last published, the window tree, and each window's frame and its app's window list, read
/// from macOS without recording them. Nothing runs, moves, refreshes or lays out.
@MainActor
func mcpDebugSnapshot(_ options: MCPDebugSnapshotOptions) async -> MCPJSON {
    let wanted = options.windowIds
    let model = TrayMenuModel.shared
    let rendered = model.workspaceSidebarWorkspaces
    let inPanel = Set(model.visibleWorkspaceSidebarWorkspaces.map(\.name))
    let rows = rendered.filter { row in wanted.map { !$0.isDisjoint(with: debugSnapshotWindowIds(row)) } ?? true }
    let listed = Set(rendered.flatMap(debugSnapshotWindowIds))
    let live = debugSnapshotLiveWindows()
    let unlisted = live.filter { window in !listed.contains(window.windowId) && wanted?.contains(window.windowId) != false }
    var toRead: [UInt32] = []
    var seen: Set<UInt32> = []
    for id in rows.flatMap(debugSnapshotWindowIds) + unlisted.map(\.windowId) where seen.insert(id).inserted { toRead.append(id) }
    let snapshot = DebugSnapshotWriter(
        includeTitles: options.includeTitles,
        windows: Dictionary(live.map { ($0.windowId, $0) }, uniquingKeysWith: { first, _ in first }),
        reads: await debugSnapshotReads(toRead, includeTitles: options.includeTitles))

    let focusedMonitor = focus.workspace.workspaceMonitor
    let events = WindowLifecycleLog.shared.events.filter { event in
        guard let wanted else { return true }
        return event.windowId.map(wanted.contains) ?? false
    }
    var document: [String: MCPJSON] = [
        "schema": .string("winmux-debug-snapshot/1"),
        "generatedAt": .string(debugSnapshotTime(Date())),
        "winmux": .object(["version": .string(winMuxAppVersion), "commit": .string(gitHash)]),
        "macOS": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        "redaction": .object(["titles": .string(options.includeTitles ? "included" : "omitted")]),
        "filter": wanted.map { .object(["windowIds": .array($0.sorted().map { .int(Int($0)) })]) } ?? .null,
        "focus": .object([
            "windowId": focus.windowOrNil.map { .int(Int($0.windowId)) } ?? .null,
            "workspace": .string(focus.workspace.name),
            "monitorId": focusedMonitor.monitorId_oneBased.map(MCPJSON.int) ?? .null,
        ]),
        "monitors": .array(sortedMonitors.map { debugSnapshotMonitor($0, focused: $0.rect.topLeftCorner == focusedMonitor.rect.topLeftCorner) }),
        "sidebar": .object([
            "enabled": .bool(config.workspaceSidebar.enabled),
            "mode": .string("\(config.workspaceSidebar.mode)"),
            "rowCount": .int(rendered.count),
            "rows": .array(rows.map { snapshot.row($0, inPanel: inPanel.contains($0.name)) }),
        ]),
        "unlistedWindows": .array(unlisted.map { snapshot.member(of: $0) }),
    ]
    if options.includesEvents {
        document["events"] = .array(events.map(debugSnapshotEvent))
        document["eventsOverwritten"] = .int(WindowLifecycleLog.shared.overwritten)
    }
    return mcpDebugSnapshotFitted(document, limit: min(mcpDebugSnapshotByteLimit, options.byteLimit ?? .max))
}

/// Within `limit` bytes, encoded: what matters least goes first, the oldest events, then windows no row lists,
/// then the last rows, then the last displays, and the document says how many of each it left out.
func mcpDebugSnapshotFitted(_ document: [String: MCPJSON], limit: Int) -> MCPJSON {
    func size(_ document: [String: MCPJSON]) -> Int { MCPJSON.object(document).encoded().count }
    guard size(document) > limit else { return .object(document) }
    let stages: [(name: String, path: [String], keepsNewest: Bool)] = [
        ("events", ["events"], true),
        ("unlistedWindows", ["unlistedWindows"], false),
        ("rows", ["sidebar", "rows"], false),
        ("monitors", ["monitors"], false),
    ]
    var current = document
    var omitted: [String: Int] = [:]
    func marked(_ document: [String: MCPJSON], _ omitted: [String: Int]) -> [String: MCPJSON] {
        var document = document
        document["truncated"] = .object(["limitBytes": .int(limit), "omitted": .object(omitted.mapValues(MCPJSON.int))])
        return document
    }
    for stage in stages {
        guard let items = debugSnapshotArray(current, stage.path) else { continue }
        func keeping(_ count: Int) -> ([String: MCPJSON], [String: Int]) {
            var omittedHere = omitted
            omittedHere[stage.name] = items.count - count
            let kept = stage.keepsNewest ? Array(items.suffix(count)) : Array(items.prefix(count))
            return (marked(debugSnapshotSetting(current, stage.path, .array(kept)), omittedHere), omittedHere)
        }
        // The most that fits: everything kept didn't, so search below it.
        var low = 0, high = items.count - 1
        var best: Int?
        while low <= high {
            let middle = (low + high) / 2
            if size(keeping(middle).0) <= limit {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        if let best {
            return .object(keeping(best).0)
        }
        (current, omitted) = keeping(0)
    }
    return .object(marked([
        "schema": document["schema"] ?? .null,
        "winmux": document["winmux"] ?? .null,
        "generatedAt": document["generatedAt"] ?? .null,
    ], omitted))
}

private func debugSnapshotArray(_ document: [String: MCPJSON], _ path: [String]) -> [MCPJSON]? {
    path.count == 1 ? document[path[0]]?.array : document[path[0]]?[path[1]]?.array
}

private func debugSnapshotSetting(_ document: [String: MCPJSON], _ path: [String], _ value: MCPJSON) -> [String: MCPJSON] {
    var document = document
    if path.count == 1 {
        document[path[0]] = value
    } else if var inner = document[path[0]]?.object {
        inner[path[1]] = value
        document[path[0]] = .object(inner)
    }
    return document
}

/// Every window a row lists, in any part of it.
private func debugSnapshotWindowIds(_ row: WorkspaceSidebarWorkspaceViewModel) -> [UInt32] {
    var ids: [UInt32] = []
    for item in row.items {
        switch item.kind {
            case .window(let window): ids.append(window.windowId)
            case .tabGroup(let group): ids += (group.allWindows.isEmpty ? group.tabs : group.allWindows).map(\.windowId)
        }
    }
    ids += row.associatedWindows.map(\.window.windowId)
    ids += row.offscreenMembers.map(\.windowId)
    if let lent = row.lentWindow { ids.append(lent.windowId) }
    return ids
}

/// Every window in WinMux's tree or registered with it, once each.
@MainActor
private func debugSnapshotLiveWindows() -> [Window] {
    var seen: Set<UInt32> = []
    let inTree = Workspace.all.flatMap(\.allLeafWindowsRecursive) + macosMinimizedWindowsContainer.allLeafWindowsRecursive
        + macosPopupWindowsContainer.allLeafWindowsRecursive
    let registered: [Window] = MacWindow.allWindows.sorted { $0.windowId < $1.windowId }
    return (inTree + registered).filter { seen.insert($0.windowId).inserted }
}

enum DebugSnapshotRead: Sendable {
    case read(DebugSnapshotNativeRead)
    /// Not a window macOS can be asked about, or its app has gone.
    case unavailable
    case timedOut
    /// Its app hasn't finished answering an earlier snapshot.
    case busy
}

/// Each window's native read: each app's windows in one read, the apps at once, none waited for longer than
/// `mcpDebugSnapshotReadTimeout`. An app still answering an earlier snapshot isn't asked again.
@MainActor
private func debugSnapshotReads(_ windowIds: [UInt32], includeTitles: Bool) async -> [UInt32: DebugSnapshotRead] {
    var reads: [UInt32: DebugSnapshotRead] = [:]
    var byApp: [Int32: [UInt32]] = [:]
    var apps: [Int32] = []
    for windowId in windowIds {
        guard let window = Window.get(byId: windowId) else {
            reads[windowId] = .unavailable
            continue
        }
        let pid = window.app.pid
        if byApp[pid] == nil { apps.append(pid) }
        byApp[pid, default: []].append(windowId)
    }
    let timeout = mcpDebugSnapshotReadTimeout
    let answers = await withTaskGroup(of: [UInt32: DebugSnapshotRead].self) { group in
        for pid in apps {
            let ids = byApp[pid] ?? []
            if debugSnapshotAppsReading.contains(pid) {
                group.addTask { Dictionary(uniqueKeysWithValues: ids.map { ($0, .busy) }) }
                continue
            }
            debugSnapshotAppsReading.insert(pid)
            group.addTask {
                await mcpFirst(orAfter: timeout) { await debugSnapshotAppRead(pid, ids, includeTitles) }
                    ?? Dictionary(uniqueKeysWithValues: ids.map { ($0, .timedOut) })
            }
        }
        var all: [UInt32: DebugSnapshotRead] = [:]
        for await answer in group { all.merge(answer) { first, _ in first } }
        return all
    }
    return reads.merging(answers) { first, _ in first }
}

/// One app's windows, read together. The app is free for the next snapshot once this finishes, in time or not.
@MainActor
private func debugSnapshotAppRead(_ pid: Int32, _ windowIds: [UInt32], _ includeTitles: Bool) async -> [UInt32: DebugSnapshotRead] {
    defer { debugSnapshotAppsReading.remove(pid) }
    let windows = windowIds.compactMap { Window.get(byId: $0) }
    let answers = await debugSnapshotNativeReads(windows, includeTitles)
    return Dictionary(uniqueKeysWithValues: windowIds.map { ($0, answers[$0].map(DebugSnapshotRead.read) ?? .unavailable) })
}

@MainActor
private func debugSnapshotMonitor(_ monitor: Monitor, focused: Bool) -> MCPJSON {
    let shown = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(monitor)]?.activeWorkspaceId
        .flatMap { winMuxWorkspaceState.workspaceById[$0] }
    return .object([
        "id": monitor.monitorId_oneBased.map(MCPJSON.int) ?? .null,
        "appKitScreenId": .int(monitor.monitorAppKitNsScreenScreensId),
        "name": .string(monitor.name),
        "main": .bool(monitor.isMain),
        "builtIn": monitor.displayIdentity.map { .bool($0.isBuiltin) } ?? .null,
        "placeholder": .bool(monitor.isFallbackMonitor),
        "frame": debugSnapshotRect(monitor.rect),
        "visibleFrame": debugSnapshotRect(monitor.visibleRect),
        "shownWorkspace": shown.map { .string($0.name) } ?? .null,
        "focused": .bool(focused),
    ])
}

func debugSnapshotEvent(_ event: WindowLifecycleEvent) -> MCPJSON {
    var object: [String: MCPJSON] = [
        "at": .string(debugSnapshotTime(event.at)),
        "kind": .string(event.kind.rawValue),
        "detail": .object(event.detail.mapValues(MCPJSON.string)),
    ]
    if let windowId = event.windowId { object["windowId"] = .int(Int(windowId)) }
    return .object(object)
}

private func debugSnapshotTime(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

private func debugSnapshotNumber(_ value: CGFloat) -> MCPJSON {
    // JSON has no NaN or infinity: one would make the whole document unencodable.
    guard value.isFinite else { return .null }
    let rounded = value.rounded()
    if abs(value - rounded) < 0.001, abs(rounded) < 1e9 { return .int(Int(rounded)) }
    return .double((Double(value) * 100).rounded() / 100)
}

func debugSnapshotRect(_ rect: Rect?) -> MCPJSON {
    guard let rect else { return .null }
    return .object(["x": debugSnapshotNumber(rect.topLeftX), "y": debugSnapshotNumber(rect.topLeftY),
                    "width": debugSnapshotNumber(rect.width), "height": debugSnapshotNumber(rect.height)])
}

private func debugSnapshotPoint(_ point: CGPoint?) -> MCPJSON {
    guard let point else { return .null }
    return .object(["x": debugSnapshotNumber(point.x), "y": debugSnapshotNumber(point.y)])
}

/// Writes rows and members, leaving titles, labels and paths out unless they're asked for.
@MainActor
private struct DebugSnapshotWriter {
    let includeTitles: Bool
    let windows: [UInt32: Window]
    let reads: [UInt32: DebugSnapshotRead]

    func row(_ row: WorkspaceSidebarWorkspaceViewModel, inPanel: Bool) -> MCPJSON {
        let items: [MCPJSON] = row.items.map { item in
            switch item.kind {
                case .window(let window):
                    return .object(["kind": .string("window"), "member": member(window)])
                case .tabGroup(let group):
                    var object: [String: MCPJSON] = [
                        "kind": .string("group"),
                        "representativeWindowId": .int(Int(group.representativeWindowId)),
                        "windowCount": .int(group.windowCount),
                        "members": .array((group.allWindows.isEmpty ? group.tabs : group.allWindows).map(member)),
                    ]
                    if includeTitles { object["title"] = .string(group.title) }
                    return .object(object)
            }
        }
        let isPinned = row.appearance.isFavorite
        let hasMembers = !items.isEmpty || !row.associatedWindows.isEmpty || !row.offscreenMembers.isEmpty
        var object: [String: MCPJSON] = [
            "workspace": .string(row.name),
            "kind": .string(isPinned ? "pinned" : "ordinary"),
            "focused": .bool(row.isFocused),
            "visible": .bool(row.isVisible),
            "shownInPanel": .bool(inPanel),
            "monitorScopeId": .string(row.monitorScopeId),
            "monitorName": row.monitorName.map(MCPJSON.string) ?? .null,
            "pinOrder": row.appearance.pinOrder.map(MCPJSON.int) ?? .null,
            "pinScope": row.appearance.pinScope.map { .string("\($0)") } ?? .null,
            "items": .array(items),
            "auxiliary": .array(row.associatedWindows.map { associated in
                .object(["member": member(associated.window), "parentWindowId": .int(Int(associated.parentWindowId)),
                         "role": .string(associated.role.rawValue)])
            }),
            "offscreen": .array(row.offscreenMembers.map { offscreen in
                .object(["member": member(windowId: offscreen.windowId, appName: offscreen.appName, bundleId: offscreen.appBundleId,
                                          bundlePath: offscreen.appBundlePath, title: offscreen.title, focused: nil),
                         "state": .string(offscreen.state.rawValue)])
            }),
            "lentWindow": row.lentWindow.map(member) ?? .null,
            "recallsWindows": .bool(row.recallsWindows),
            "leftEmpty": .bool(row.isLeftEmpty),
            "emptyPin": .bool(isPinned && !hasMembers),
            "hasPinHome": .bool(row.pinHome != nil),
            "saved": row.savedState.map { saved in
                .object([
                    "keepWhenEmpty": .bool(saved.keepWhenEmpty),
                    "pinnedToDisplay": .bool(saved.isPinnedToDisplay),
                    "homeConnected": .bool(saved.isHomeConnected),
                    "forceAssigned": .bool(saved.isForceAssignedByConfig),
                    "missingApps": .array(saved.missingAppNames.map(MCPJSON.string)),
                    // What an empty saved tab or pin shows in place of windows, one per saved window.
                    "placeholders": .array(saved.apps.map { .object(["appBundleId": .string($0.bundleId), "appName": .string($0.name)]) }),
                ])
            } ?? .null,
        ]
        if includeTitles { object["label"] = .string(row.sidebarLabel) }
        return .object(object)
    }

    func member(_ window: WorkspaceSidebarWindowViewModel) -> MCPJSON {
        member(windowId: window.windowId, appName: window.appName, bundleId: window.appBundleId, bundlePath: window.appBundlePath,
               title: window.title, focused: window.isFocused)
    }

    func member(of window: Window) -> MCPJSON {
        var title: String? = nil
        if case .read(let read)? = reads[window.windowId] { title = read.title }
        return member(windowId: window.windowId, appName: window.app.name ?? "", bundleId: window.app.rawAppBundleId,
                      bundlePath: window.app.bundlePath, title: title, focused: focus.windowOrNil === window)
    }

    /// A row's member, as the sidebar names it, and what WinMux and macOS know of its window.
    func member(windowId: UInt32, appName: String, bundleId: String?, bundlePath: String?, title: String?, focused: Bool?) -> MCPJSON {
        var object: [String: MCPJSON] = [
            "windowId": .int(Int(windowId)),
            "appName": .string(appName),
            "appBundleId": bundleId.map(MCPJSON.string) ?? .null,
        ]
        if let focused { object["focused"] = .bool(focused) }
        if includeTitles {
            object["title"] = title.map(MCPJSON.string) ?? .null
            object["appPath"] = bundlePath.map(MCPJSON.string) ?? .null
        }
        guard let window = windows[windowId] else {
            // Listed, and no window of WinMux's has the id.
            object["live"] = .bool(false)
            object["lastAxError"] = lastAxError(windowId)
            return .object(object)
        }
        object["live"] = .bool(true)
        object["pid"] = .int(Int(window.app.pid))
        let path = window.app.bundlePath
        object["appPathKind"] = .string(debugSnapshotAppPathKind(path, isHelper: savedWorkspaceAppIsHelper(bundlePath: path)))
        object["workspace"] = window.nodeWorkspace.map { .string($0.name) } ?? .null
        object["placement"] = .string(debugSnapshotPlacement(window.parent))
        object["floating"] = .bool(window.parent is Workspace)
        object["parent"] = debugSnapshotParent(window)
        object["auxiliary"] = auxiliary(window)
        object["state"] = state(window)
        object["frames"] = frames(window)
        switch reads[windowId] {
            case .read(let read)?:
                object["nativeRead"] = .string("ok")
                object["appListsWindow"] = read.appListsWindow.map(MCPJSON.bool) ?? .null
                if let error = read.appWindowListError { object["appWindowListError"] = .string(error) }
            case .timedOut?:
                object["nativeRead"] = .string("timedOut")
                object["appListsWindow"] = .null
            case .busy?:
                object["nativeRead"] = .string("busy")
                object["appListsWindow"] = .null
            case .unavailable?, nil:
                object["nativeRead"] = .string("unavailable")
                object["appListsWindow"] = .null
        }
        object["lastAxError"] = lastAxError(windowId)
        object["pending"] = .bool(savedWorkspaceRuntime.routingInFlightWindowIds.contains(windowId)
            || savedWorkspaceRuntime.windowsAwaitingTitle[windowId] != nil)
        return .object(object)
    }

    private func lastAxError(_ windowId: UInt32) -> MCPJSON {
        guard let last = AxWindowErrorLog.shared.last(windowId: windowId) else { return .null }
        return .object(["error": .string(last.error), "at": .string(debugSnapshotTime(last.at))])
    }

    private func auxiliary(_ window: Window) -> MCPJSON {
        let registry = AuxiliaryWindowRegistry.shared
        let children = registry.entries.filter { $0.value.parentWindowId == window.windowId && $0.value.pid == window.app.pid }
            .keys.sorted().map { MCPJSON.int(Int($0)) }
        guard let role = registry.role(of: window) else {
            return children.isEmpty ? .null : .object(["children": .array(children)])
        }
        return .object([
            "role": .string(role.rawValue),
            "parentWindowId": registry.parentWindowId(of: window).map { .int(Int($0)) } ?? .null,
            "listedUnder": auxiliaryWindowParent(of: window).map { .int(Int($0.windowId)) } ?? .null,
            "children": .array(children),
        ])
    }

    private func state(_ window: Window) -> MCPJSON {
        let parentKind = window.parent.map(\.kind)
        var object: [String: MCPJSON] = [
            "hiddenWithApp": .bool(parentKind == .macosHiddenAppsWindowsContainer),
            "minimized": .bool(parentKind == .macosMinimizedWindowsContainer),
            "nativeFullscreen": .bool(parentKind == .macosFullscreenWindowsContainer),
            "winmuxFullscreen": .bool(window.isFullscreen),
            "parkedInCorner": .bool(window.isHiddenInCorner),
            "lastKnownNativeMinimized": window.lastKnownNativeMinimized.map(MCPJSON.bool) ?? .null,
            "lastKnownNativeFullscreen": window.lastKnownNativeFullscreen.map(MCPJSON.bool) ?? .null,
        ]
        if window.isHiddenInCorner, let parking = window.cornerParkingForDebug?.parking {
            object["park"] = .object([
                "corner": parking.corner.map { .string("\($0)") } ?? .null,
                "target": debugSnapshotPoint(parking.target),
                "onVisibleFrame": debugSnapshotRect(parking.monitorVisibleRect),
                "confirmed": .bool(parking.isConfirmed),
                "unconfirmedParks": .int(parking.unconfirmedParks),
                "retriesExhausted": .bool(parking.exhaustedAtNativeGeneration != nil),
            ])
        } else {
            object["park"] = .null
        }
        return .object(object)
    }

    /// Where WinMux last placed it, what it last saw, and what macOS says now.
    private func frames(_ window: Window) -> MCPJSON {
        var object: [String: MCPJSON] = [
            "lastPlaced": debugSnapshotRect(window.layoutPlacedRect),
            "lastLayoutCell": debugSnapshotRect(window.lastAppliedLayoutPhysicalRect),
            "lastObserved": debugSnapshotRect(window.lastKnownActualRect),
        ]
        if case .read(let read)? = reads[window.windowId] {
            object["ax"] = debugSnapshotRect(read.axFrame)
            if let error = read.axFrameError { object["axError"] = .string(error) }
        } else {
            object["ax"] = .null
        }
        return .object(object)
    }
}

private func debugSnapshotPlacement(_ parent: NonLeafTreeNodeObject?) -> String {
    switch parent?.kind {
        case .tilingContainer?: "tiling"
        case .workspace?: "floating"
        case .macosMinimizedWindowsContainer?: "minimized"
        case .macosHiddenAppsWindowsContainer?: "hiddenWithApp"
        case .macosFullscreenWindowsContainer?: "nativeFullscreen"
        case .macosPopupWindowsContainer?: "popup"
        case nil: "unbound"
    }
}

@MainActor
private func debugSnapshotParent(_ window: Window) -> MCPJSON {
    guard let parent = window.parent else { return .null }
    var object: [String: MCPJSON] = ["kind": .string(parent.kind.rawValue)]
    if let container = parent as? TilingContainer {
        object["layout"] = .string(container.layout.rawValue)
        object["orientation"] = .string("\(container.orientation)")
        object["isRoot"] = .bool(container.parent is Workspace)
        object["windowCount"] = .int(container.allLeafWindowsRecursive.count)
    }
    return .object(object)
}
