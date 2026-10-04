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
    private var safariFrames = SafariExtensionFrameTrack()
    /// Safari windows to walk in full at their next read: a lone tab's speaker shows only there.
    private var rediscover: Set<UInt32> = []

    init(snapshots: [UInt32: BrowserWindowTabs] = [:], safariExtension: SafariExtensionBridge = .shared) {
        self.snapshots = snapshots
        self.safariExtension = safariExtension
        safariExtension.sightSafariWindows = { [weak self] measured in self?.sightSafariWindows(measured: measured) ?? [:] }
        safariExtension.reportArrived = { [weak self] in
            guard let self, self.task != nil else { return false }
            self.publish()
            return self.safariAssociations.awaitsReport || self.safariAssociations.awaitsAnotherReport(self.safariExtension.windows)
        }
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
            safariFrames = .init()
            rediscover = []
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

    /// A browser's tabs say they're playing sound only from the next read, so when a browser
    /// starts or stops playing, the windows of it the sidebar shows are read now, not in turn.
    func rereadWindows(of bundleIds: Set<String>) {
        guard task != nil else { return }
        let rereads = browserTabRereads(MacWindow.allWindowsMap.values.map { ($0.windowId, $0.app.rawAppBundleId) },
            changed: bundleIds, watched: schedule.watched)
        rediscover.formUnion(rereads.rediscover)
        for id in rereads.now { schedule.reset(id) }
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
        safariExtension.retain(safariIsRunning: MacApp.allAppsMap.values.contains { $0.rawAppBundleId == safariBundleId })
        trackSafariFrames(now: now)
        iconAssociations.retain(Set(cache.snapshots.values.flatMap { $0.tabs.map(\.target) }))
        publish()
        schedule.retain(Set(ownerPids.keys))
        schedule.relax(settledSafariWindows(now: now))
        rediscover = rediscover.filter { ownerPids[$0] != nil }
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
            // While a browser plays, a window without a tab strip can start or stop playing with
            // no change Core Audio would report, so it's walked more often.
            let read = try? await app.readBrowserTabs(window.windowId, readIcons: iconsEnabled,
                rediscover: rediscover.remove(window.windowId) != nil,
                loneRediscovery: AudioActivityModel.shared.isPlaying(bundleId: app.rawAppBundleId)
                    ? browserLoneTabRediscoveryWhilePlaying : browserLoneTabRediscovery,
                extensionButton: safariExtension.configuration?.toolbarIdentifier)
            let result = read?.tabs ?? read?.loneTab
            reads += 1
            guard generation == token, !Task.isCancelled else { return }
            schedule.didRead(window.windowId, now: ProcessInfo.processInfo.systemUptime, succeeded: result != nil, started: readStarted)
            if var result, Window.get(byId: window.windowId)?.app === app {
                if !iconsEnabled { result.iconCandidate = nil }
                iconAssociations.update(result, now: ProcessInfo.processInfo.systemUptime)
                cache.receive(result, now: ProcessInfo.processInfo.systemUptime, started: readStarted)
                pendingSelections.observe(result, readStarted: readStarted)
                publish()
            } else {
                cache.recordFailure(windowId: window.windowId, now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func publish() {
        updateSafariAssociations()
        let now = ProcessInfo.processInfo.systemUptime
        pendingSelections.expire(now: now)
        let next = cache.snapshots.mapValues { value in
            browserTabsShown(pendingSelections.apply(value), read: cache.observed[value.windowId], now: now,
                safari: safariAssociations, iconOrigins: iconsEnabled ? iconAssociations.origins : [:])
        }
        if snapshots != next { snapshots = next }
    }

    /// Pairs Safari windows with what the extension reports, only when there's something new: a
    /// fresh read, a report, or a Safari window appearing or going. Moving a window isn't: the
    /// reports' bounds are compared with where windows were when each report arrived.
    private func updateSafariAssociations() {
        let safari = cache.snapshots.values.filter { MacApp.allAppsMap[$0.pid]?.rawAppBundleId == safariBundleId }
        let read = Set(safari.map(\.windowId))
        let unread = safariExtensionUnreadWindows(live: liveSafariWindows(), read: read)
        let evidence = SafariExtensionEvidence(observed: Dictionary(uniqueKeysWithValues: safari.map { ($0.windowId, cache.observed[$0.windowId] ?? 0) }),
            reports: safariExtension.generation, unread: unread)
        guard evidence != safariEvidence else { return }
        let reported = evidence.reports != safariEvidence?.reports
        safariEvidence = evidence
        safariAssociations.update(safari.map { .init(snapshot: $0, observed: cache.observed[$0.windowId] ?? 0,
                readStarted: cache.readStarted[$0.windowId], appeared: safariFrames.appeared($0.windowId) ?? .infinity) },
            windows: safariExtension.windows, unread: unread,
            unreadAppeared: Dictionary(uniqueKeysWithValues: unread.map { ($0, safariFrames.appeared($0) ?? .infinity) }),
            now: ProcessInfo.processInfo.systemUptime)
        // Safari reports where its windows are only with its tabs; ask again rather than wait a minute.
        if safariAssociations.awaitsReport { safariExtension.requestResync(atMostEvery: 10) }
        // A report that no longer agrees with a window's last read, or reorders its tabs, says they
        // changed; one its button names can start counting from a read after it: read those now.
        if reported { for id in safariAssociations.rereads { schedule.invalidate(id, now: ProcessInfo.processInfo.systemUptime) } }
    }

    private func settledSafariWindows(now: TimeInterval) -> Set<UInt32> {
        guard safariExtension.allSites else { return [] }
        return safariExtensionSettledWindows(Array(cache.snapshots.values), safariAssociations, windows: safariExtension.windows, now: now)
    }

    private func liveSafariWindows() -> [UInt32] {
        MacWindow.allWindowsMap.values.filter { $0.app.rawAppBundleId == safariBundleId }.map(\.windowId)
    }

    /// Notes where each Safari window is, a few times a second while a sidebar shows browser
    /// tabs, so a report arriving knows which windows have held still since Safari measured them.
    /// Frames come from the window server, in one request, rather than WinMux's cache, which
    /// lags a move until its notification arrives. Each window's counts of the writes WinMux ran
    /// and the moves it heard about catch a move and a move back between two samples; a window
    /// with a write running counts as moving.
    private func trackSafariFrames(now: TimeInterval) {
        let windows = MacWindow.allWindowsMap.values.filter { $0.app.rawAppBundleId == safariBundleId }
        guard safariExtension.isAvailable else {
            safariFrames = .init()
            return
        }
        // With no Safari window, nothing is sampled, but any that opens later is new.
        guard !windows.isEmpty else {
            safariFrames.observe([UInt32: SafariExtensionFrameSample](), now: now)
            return
        }
        // Hidden sidebars read no browser windows; nothing is paired meanwhile.
        guard !schedule.watched.isEmpty else {
            safariFrames.pause()
            return
        }
        let frames = windowServerFrames(windows.map(\.windowId))
        safariFrames.observe(Dictionary(windows.map { window in
            let writes = window.macApp.frameWriteLedger.state(window.windowId)
            return (window.windowId, SafariExtensionFrameSample(
                frame: frames[window.windowId]
                    ?? window.lastKnownActualRect.map { CGRect(x: $0.topLeftX, y: $0.topLeftY, width: $0.width, height: $0.height) },
                identity: ObjectIdentifier(window), generation: window.nativeStateObservationToken(),
                writes: writes.version, writing: writes.writing))
        }, uniquingKeysWith: { first, _ in first }), now: now)
    }

    private func sightSafariWindows(measured: TimeInterval) -> [UInt32: CGRect] {
        trackSafariFrames(now: ProcessInfo.processInfo.systemUptime)
        return safariFrames.sighting(measured: measured)
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
            let closed = (try? await app.closeBrowserTab(target))?.isDispatched == true
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
            let pressed = (try? await app.selectBrowserTab(target))?.isDispatched == true
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

/// Which windows to read again when `changed` apps start or stop playing: the sidebar's browser
/// windows now. Safari's windows without a tab strip, which read only their title in between,
/// are walked at their next read, even ones the sidebar shows later, which would otherwise keep
/// the sound they had when it stopped showing them.
func browserTabRereads(_ windows: [(id: UInt32, bundleId: String?)], changed: Set<String>,
                       watched: Set<UInt32>) -> (now: Set<UInt32>, rediscover: Set<UInt32>) {
    var result: (now: Set<UInt32>, rediscover: Set<UInt32>) = ([], [])
    for window in windows {
        guard let bundleId = window.bundleId, changed.contains(bundleId), let adapter = BrowserTabAdapter(bundleId: bundleId) else { continue }
        if adapter == .safari { result.rediscover.insert(window.id) }
        if watched.contains(window.id) { result.now.insert(window.id) }
    }
    return result
}

/// How recent a report must be for the windows it describes to be read only now and then: the
/// extension reports at least once a minute, and only what changed in between.
let safariExtensionSettledReportAge: TimeInterval = 90

/// Safari windows the extension describes in full, by a report from its last check-in or since.
/// Its reports say when their tabs change, which reads them again at once, so they're otherwise
/// read only now and then. Only while the extension may read every website: otherwise it can't
/// see some tabs' titles change.
func safariExtensionSettledWindows(_ snapshots: [BrowserWindowTabs], _ associations: SafariExtensionAssociations,
                                   windows: [SafariExtensionWindow], now: TimeInterval) -> Set<UInt32> {
    let reported = Dictionary(windows.map { ($0.key, $0.received) }, uniquingKeysWith: max)
    return Set(snapshots.filter { snapshot in
        guard case .resolved(let key) = associations.resolution(of: snapshot.windowId),
              let received = reported[key], now - received < safariExtensionSettledReportAge else { return false }
        return associations.settles(snapshot)
    }.map(\.windowId))
}

/// How long the sound a read found in a tab's name counts. The sidebar's windows are read every
/// few seconds; one it stopped showing keeps its tabs, but not their sound.
let browserTabSoundLifetime: TimeInterval = 10

/// A window's tabs as the sidebar shows them: with what the Safari extension says about them,
/// and their icons, and the sound a read found only while that read is recent.
func browserTabsShown(_ snapshot: BrowserWindowTabs, read: TimeInterval?, now: TimeInterval,
                      safari: SafariExtensionAssociations, iconOrigins: [BrowserTabTarget: URL]) -> BrowserWindowTabs {
    var snapshot = snapshot
    let heard = read.map { now - $0 < browserTabSoundLifetime } ?? false
    snapshot.tabs = snapshot.tabs.map { tab in
        var tab = tab
        if !heard { tab.audio = nil }
        tab = safari.described(tab)
        tab.iconOrigin = iconOrigins[tab.target]
        return tab
    }
    snapshot.knowsSound = safari.agreeing.contains(snapshot.windowId)
    snapshot.marker = nil
    return snapshot
}

/// Where the window server has windows WinMux hasn't measured lately, such as ones that just
/// opened or moved, in the same top-left screen coordinates, in one request.
private func windowServerFrames(_ ids: [UInt32]) -> [UInt32: CGRect] {
    guard !ids.isEmpty else { return [:] }
    var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &values, values.count, nil),
          let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
    var frames: [UInt32: CGRect] = [:]
    for description in descriptions {
        guard let number = (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = description[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
        frames[number] = frame
    }
    return frames
}

@MainActor
func browserTabSelectionAllowed(workspace: Workspace, monitorScopeId: String?) -> Bool {
    guard let monitorScopeId, !workspaceSidebarMonitorScopeIsSentinel(monitorScopeId) else { return true }
    guard let monitor = workspaceSidebarMonitor(forScopeId: monitorScopeId) else { return false }
    return !workspace.isVisible || workspace.workspaceMonitor.rect == monitor.rect
}
