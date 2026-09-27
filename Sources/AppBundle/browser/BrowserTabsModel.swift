import AppKit
import Combine
import Common

@MainActor
final class BrowserTabsModel: ObservableObject {
    static let shared = BrowserTabsModel()
    @Published private(set) var snapshots: [UInt32: BrowserWindowTabs] = [:]
    private var cache = BrowserTabSnapshotCache()
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var generation = 0
    private var schedule = BrowserTabReadSchedule()
    private var watched: [String: Set<UInt32>] = [:]
    private var iconsEnabled = false
    private var iconAssociations = BrowserTabIconAssociations()

    init(snapshots: [UInt32: BrowserWindowTabs] = [:]) {
        self.snapshots = snapshots
    }

    func watch(_ windowIds: Set<UInt32>, sidebar: String) {
        watched[sidebar] = windowIds.isEmpty ? nil : windowIds
        schedule.watch(watched.values.reduce(into: Set<UInt32>()) { $0.formUnion($1) })
    }

    func setEnabled(_ enabled: Bool) {
        let icons = enabled && config.workspaceSidebar.browserTabIcons
        BrowserTabIconModel.shared.setEnabled(icons)
        if icons != iconsEnabled {
            iconsEnabled = icons
            iconAssociations = .init()
            cache.clearIconMetadata()
            for id in schedule.watched { schedule.reset(id) }
            publish()
        }
        guard enabled else {
            guard task != nil else { return }
            generation += 1
            task?.cancel()
            task = nil
            selectionTask?.cancel()
            cache = .init()
            snapshots = [:]
            schedule = .init()
            schedule.watch(watched.values.reduce(into: Set<UInt32>()) { $0.formUnion($1) })
            let apps = Array(MacApp.allAppsMap.values)
            cleanup = Task { for app in apps { await app.clearBrowserTabs() } }
            return
        }
        guard task == nil, !isUnitTest else { return }
        let token = generation
        task = Task { [weak self] in
            await self?.cleanup?.value
            while !Task.isCancelled, let self, self.generation == token {
                await self.reconcile(generation: token)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func markDirty(_ windowId: UInt32, pid: Int32) {
        guard task != nil, Window.get(byId: windowId)?.app.pid == pid else { return }
        schedule.markDirty(windowId)
    }

    private func reconcile(generation token: Int) async {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != lockScreenAppBundleId else { return }
        let owners = MacWindow.allWindowsMap.values.filter { BrowserTabAdapter(bundleId: $0.app.rawAppBundleId) != nil }
        let now = ProcessInfo.processInfo.systemUptime
        let ownerPids = Dictionary(uniqueKeysWithValues: owners.map { ($0.windowId, $0.app.pid) })
        cache.reconcile(owners: ownerPids, now: now)
        iconAssociations.retain(Set(cache.snapshots.values.flatMap { $0.tabs.map(\.target) }))
        publish()
        schedule.retain(Set(ownerPids.keys))
        schedule.focus(focus.windowOrNil?.windowId)
        // Hidden rails retain their cache but do no browser work. Revealing them
        // resumes reads without creating a window-layout refresh session.
        guard !schedule.watched.isEmpty, !isMouseWindowDragInProgress() else { return }
        let ordered = owners.filter { schedule.watched.contains($0.windowId) }.sorted { left, right in
            if (left.windowId == focus.windowOrNil?.windowId) != (right.windowId == focus.windowOrNil?.windowId) {
                return left.windowId == focus.windowOrNil?.windowId
            }
            return schedule.lastRead(left.windowId) < schedule.lastRead(right.windowId)
        }
        // Small batches leave room for frame/focus jobs, while many browser
        // windows still reconcile within the stale-read timeout.
        var reads = 0
        for window in ordered {
            if reads >= 3 || ProcessInfo.processInfo.systemUptime - now > 0.12 { break }
            guard schedule.isDue(window.windowId, now: now),
                  let app = window.app as? MacApp, app.browserTabsMayRead else { continue }
            let result = try? await app.readBrowserTabs(window.windowId, readIcons: iconsEnabled)
            reads += 1
            guard generation == token, !Task.isCancelled else { return }
            schedule.didRead(window.windowId, now: ProcessInfo.processInfo.systemUptime, succeeded: result != nil)
            if var result, Window.get(byId: window.windowId)?.app === app {
                if !iconsEnabled { result.iconCandidate = nil }
                iconAssociations.update(result, now: ProcessInfo.processInfo.systemUptime)
                cache.receive(result, now: ProcessInfo.processInfo.systemUptime)
                publish()
            } else {
                cache.recordFailure(windowId: window.windowId, now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func publish() {
        let next = cache.snapshots.mapValues { value in
            var value = value
            value.tabs = value.tabs.map { tab in
                var tab = tab
                tab.iconOrigin = iconsEnabled ? iconAssociations.origins[tab.target] : nil
                return tab
            }
            return value
        }
        if snapshots != next { snapshots = next }
    }

    func select(_ target: BrowserTabTarget, monitorScopeId: String?) {
        guard config.workspaceSidebar.usesTabsList, config.workspaceSidebar.browserTabs,
              TrayMenuModel.shared.isEnabled, !serverArgs.isReadOnly
        else { return }
        selectionTask?.cancel()
        guard let window = Window.get(byId: target.windowId) else {
            focusWindowFromSidebar(target.windowId, targetMonitorScopeId: monitorScopeId)
            return
        }
        guard window.app.pid == target.pid, let app = window.app as? MacApp else { return }
        guard let workspace = window.toLiveFocusOrNil()?.workspace else {
            focusWindowFromSidebar(target.windowId, targetMonitorScopeId: monitorScopeId)
            return
        }
        guard browserTabSelectionAllowed(workspace: workspace, monitorScopeId: monitorScopeId) else { return }
        let token = generation
        selectionTask = Task { [weak self] in
            _ = try? await app.selectBrowserTab(target)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.schedule.reset(target.windowId)
            guard Window.get(byId: target.windowId) === window else { return }
            if let workspace = window.toLiveFocusOrNil()?.workspace,
               !browserTabSelectionAllowed(workspace: workspace, monitorScopeId: monitorScopeId) { return }
            // A stale tab focuses only its original window. No index/title fallback.
            focusWindowFromSidebar(target.windowId, targetMonitorScopeId: monitorScopeId)
        }
    }
}

@MainActor
func browserTabSelectionAllowed(workspace: Workspace, monitorScopeId: String?) -> Bool {
    guard let monitorScopeId, !workspaceSidebarMonitorScopeIsSentinel(monitorScopeId) else { return true }
    guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else { return false }
    return !workspace.isVisible || workspace.workspaceMonitor.rect == monitor.rect
}
