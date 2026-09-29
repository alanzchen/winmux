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
    private var pendingSelections = BrowserTabPendingSelections()
    private let safariExtension: SafariExtensionBridge
    private var safariAssociations = SafariExtensionAssociations()
    private var safariEvidence: SafariExtensionEvidence?
    /// When a window's last read found no tab strip at all.
    private var withoutTabStrips: [UInt32: TimeInterval] = [:]

    init(snapshots: [UInt32: BrowserWindowTabs] = [:], safariExtension: SafariExtensionBridge = .shared) {
        self.snapshots = snapshots
        self.safariExtension = safariExtension
    }

    /// The windows some sidebar shows, and so the ones read.
    var watchedWindowIds: Set<UInt32> { schedule.watched }

    func watch(_ windowIds: Set<UInt32>, sidebar: String) {
        watched[sidebar] = windowIds.isEmpty ? nil : windowIds
        schedule.watch(watched.values.reduce(into: Set<UInt32>()) { $0.formUnion($1) })
    }

    func setEnabled(_ enabled: Bool) {
        safariExtension.setEnabled(enabled)
        if !enabled {
            pendingSelections = .init()
            safariAssociations = .init()
            safariEvidence = nil
            withoutTabStrips = [:]
        }
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
        // The window may have just shown its tab strip, as when a second tab opens.
        withoutTabStrips[windowId] = nil
    }

    private func reconcile(generation token: Int) async {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != lockScreenAppBundleId else { return }
        let owners = MacWindow.allWindowsMap.values.filter { BrowserTabAdapter(bundleId: $0.app.rawAppBundleId) != nil }
        let now = ProcessInfo.processInfo.systemUptime
        let ownerPids = Dictionary(uniqueKeysWithValues: owners.map { ($0.windowId, $0.app.pid) })
        cache.reconcile(owners: ownerPids, now: now)
        safariExtension.retain(safariIsRunning: MacApp.allAppsMap.values.contains { $0.rawAppBundleId == safariBundleId })
        iconAssociations.retain(Set(cache.snapshots.values.flatMap { $0.tabs.map(\.target) }))
        publish()
        schedule.retain(Set(ownerPids.keys))
        withoutTabStrips = withoutTabStrips.filter { ownerPids[$0.key] != nil }
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
            let readStarted = ProcessInfo.processInfo.systemUptime
            let read = try? await app.readBrowserTabs(window.windowId, readIcons: iconsEnabled)
            let result = read?.tabs
            reads += 1
            guard generation == token, !Task.isCancelled else { return }
            withoutTabStrips[window.windowId] = read?.hasNoTabStrip == true ? ProcessInfo.processInfo.systemUptime : nil
            schedule.didRead(window.windowId, now: ProcessInfo.processInfo.systemUptime, succeeded: result != nil)
            if var result, Window.get(byId: window.windowId)?.app === app {
                if !iconsEnabled { result.iconCandidate = nil }
                iconAssociations.update(result, now: ProcessInfo.processInfo.systemUptime)
                cache.receive(result, now: ProcessInfo.processInfo.systemUptime)
                pendingSelections.observe(result, readStarted: readStarted)
                publish()
            } else {
                cache.recordFailure(windowId: window.windowId, now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func publish() {
        updateSafariAssociations()
        pendingSelections.expire(now: ProcessInfo.processInfo.systemUptime)
        let next = cache.snapshots.mapValues { value in
            var value = pendingSelections.apply(value)
            value.tabs = value.tabs.map { tab in
                var tab = safariAssociations.described(tab)
                tab.iconOrigin = iconsEnabled ? iconAssociations.origins[tab.target] : nil
                return tab
            }
            return value
        }
        if snapshots != next { snapshots = next }
    }

    /// Pairs Safari windows with what the extension reports, only when there's something new: a
    /// fresh read, a report, or a Safari window appearing or going.
    private func updateSafariAssociations() {
        let safari = cache.snapshots.values.filter { MacApp.allAppsMap[$0.pid]?.rawAppBundleId == safariBundleId }
        let read = Set(safari.map(\.windowId))
        func frame(_ id: UInt32) -> CGRect? {
            Window.get(byId: id)?.lastKnownActualRect.map { CGRect(x: $0.topLeftX, y: $0.topLeftY, width: $0.width, height: $0.height) }
                ?? windowServerFrame(id)
        }
        let live = MacWindow.allWindowsMap.values.filter { $0.app.rawAppBundleId == safariBundleId }.map(\.windowId)
        let unread = safariExtensionUnreadWindows(live: live, read: read, withoutTabStrips: safariExtensionStriplessWindows(
            withoutTabStrips, watched: schedule.watched, now: ProcessInfo.processInfo.systemUptime)).map(frame)
        let evidence = SafariExtensionEvidence(observed: Dictionary(uniqueKeysWithValues: safari.map { ($0.windowId, cache.observed[$0.windowId] ?? 0) }),
            reports: safariExtension.generation, unreadFrames: unread)
        guard evidence != safariEvidence else { return }
        safariEvidence = evidence
        safariAssociations.update(safari.map { .init(snapshot: $0, frame: frame($0.windowId), observed: cache.observed[$0.windowId] ?? 0) },
            windows: safariExtension.windows, unreadFrames: unread, now: ProcessInfo.processInfo.systemUptime)
        // Safari reports where its windows are only with its tabs; ask again rather than wait a minute.
        if safariAssociations.awaitsFrames { safariExtension.requestResync(atMostEvery: 10) }
    }

    /// Closes one browser tab, as middle-clicking it in a browser's tab bar does. The window
    /// stays where it is; the list drops the tab at once and rereads it right after.
    func close(_ target: BrowserTabTarget) {
        guard config.workspaceSidebar.usesTabsList, config.workspaceSidebar.browserTabs,
              TrayMenuModel.shared.isEnabled, !serverArgs.isReadOnly,
              let window = Window.get(byId: target.windowId), window.app.pid == target.pid,
              let app = window.app as? MacApp
        else { return }
        let token = generation
        Task { [weak self] in
            let closed = (try? await app.closeBrowserTab(target)) == true
            guard let self, self.generation == token else { return }
            self.schedule.reset(target.windowId)
            guard closed else {
                MessageModel.shared.message = Message(description: "Close Tab Error",
                    body: "\(window.app.name ?? "The browser") didn't offer a way to close this tab.")
                return
            }
            self.cache.removeTab(target)
            self.publish()
            // A tab can ask before it closes, such as for unsent form data. In a window that
            // isn't on screen the prompt would stay out of view, so bring it forward, as closing
            // a hidden window does. A read that still lists the tab restores its row.
            guard Window.get(byId: target.windowId) === window, windowIsHiddenFromView(window) else { return }
            for _ in 0..<windowMiddleClickSheetPollCount {
                do { try await Task.sleep(for: windowMiddleClickSheetPollInterval) } catch { return }
                guard Window.get(byId: target.windowId) === window else { return }
                if (try? await app.windowShowsSheet(target.windowId)) == true {
                    focusWindowFromSidebar(target.windowId)
                    return
                }
            }
        }
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
        // Show the chosen tab as selected now, not once the next read confirms it.
        let attempt = pendingSelections.begin(target, now: ProcessInfo.processInfo.systemUptime)
        publish()
        let token = generation
        selectionTask = Task { [weak self] in
            // Cancelled or not, a press that ran reports whether it did; none that didn't switched the tab.
            let pressed = (try? await app.selectBrowserTab(target)) == true
            guard let self, self.generation == token else { return }
            self.pendingSelections.settle(attempt: attempt, windowId: target.windowId, refused: !pressed,
                now: ProcessInfo.processInfo.systemUptime)
            if !pressed { self.publish() }
            self.schedule.reset(target.windowId)
            guard !Task.isCancelled else { return }
            guard Window.get(byId: target.windowId) === window else { return }
            if let workspace = window.toLiveFocusOrNil()?.workspace,
               !browserTabSelectionAllowed(workspace: workspace, monitorScopeId: monitorScopeId) { return }
            // A stale tab focuses only its original window. No index/title fallback.
            focusWindowFromSidebar(target.windowId, targetMonitorScopeId: monitorScopeId)
        }
    }
}

/// Where the window server has a window WinMux hasn't measured yet, such as one that just opened,
/// in the same top-left screen coordinates.
private func windowServerFrame(_ id: UInt32) -> CGRect? {
    var value = UnsafeRawPointer(bitPattern: UInt(id))
    guard let ids = CFArrayCreate(nil, &value, 1, nil),
          let bounds = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first?[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
}

@MainActor
func browserTabSelectionAllowed(workspace: Workspace, monitorScopeId: String?) -> Bool {
    guard let monitorScopeId, !workspaceSidebarMonitorScopeIsSentinel(monitorScopeId) else { return true }
    guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else { return false }
    return !workspace.isVisible || workspace.workspaceMonitor.rect == monitor.rect
}
