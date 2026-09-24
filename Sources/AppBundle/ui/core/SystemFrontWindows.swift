import AppKit
import Common

/// System Settings and the system's permission prompts stay in front. WinMux's chrome yields
/// to them, and a covered Accessibility or Screen Recording prompt comes back to the front.
/// macOS lets only the owner set a window's level, so WinMux reorders itself and reactivates.
enum SystemFrontApp {
    static let systemSettings = "com.apple.systempreferences"
    /// Accessibility and Screen Recording prompts use the normal window level, so any window can cover them.
    static let accessPrompt = "com.apple.accessibility.universalAccessAuthWarn"
    /// Automation and file-access prompts sit one level above normal windows, below WinMux's chrome.
    static let notificationPrompt = "com.apple.UserNotificationCenter"
    static let all: Set<String> = [systemSettings, accessPrompt, notificationPrompt]
}

struct OrderedOnScreenWindow: Equatable {
    let id: UInt32
    let pid: pid_t
    let layer: Int
    /// Window-server coordinates (top-left origin).
    let frame: CGRect
}

struct SystemFrontWindow: Equatable {
    let id: UInt32
    let bundleId: String
    let layer: Int
    let frame: CGRect
}

struct RunningSystemApp: Equatable {
    let pid: pid_t
    let bundleId: String
    let isActive: Bool
}

/// Front to back. WinMux's Sidebar and Dock sit beneath these while any of them is on screen.
@MainActor
private(set) var systemFrontWindows: [SystemFrontWindow] = []

/// System windows among on-screen windows, front to back. Prompts at levels above WinMux's
/// chrome, such as authorization dialogs, need nothing and are not listed.
func selectSystemFrontWindows(in windows: [OrderedOnScreenWindow], bundleIdsByPid: [pid_t: String],
                              isHiddenByWinMux: (UInt32) -> Bool = { _ in false }) -> [SystemFrontWindow] {
    windows.compactMap { window in
        guard let bundleId = bundleIdsByPid[window.pid], SystemFrontApp.all.contains(bundleId),
              (0 ..< WinMuxPanelLayer.workspaceSidebar.level.rawValue).contains(window.layer),
              window.frame.width > 40, window.frame.height > 40,
              // System Settings on another workspace waits in a screen corner.
              !isHiddenByWinMux(window.id)
        else { return nil }
        return SystemFrontWindow(id: window.id, bundleId: bundleId, layer: window.layer, frame: window.frame)
    }
}

/// An Accessibility or Screen Recording prompt covered by a window of the frontmost app, which the
/// user just brought forward. Once the prompt is activated its covering app is no longer
/// frontmost, so a prompt that activation cannot raise is not reactivated again and again.
func coveredAccessPrompt(in windows: [OrderedOnScreenWindow], promptPids: Set<pid_t>, frontmostPid: pid_t?,
                         ownPid: pid_t) -> OrderedOnScreenWindow? {
    guard let frontmostPid, frontmostPid != ownPid, !promptPids.contains(frontmostPid) else { return nil }
    for (index, prompt) in windows.enumerated() where promptPids.contains(prompt.pid) && prompt.layer == 0 {
        let isCovered = windows[..<index].contains { window in
            window.pid == frontmostPid && window.layer == 0 && window.frame.width > 40 && window.frame.height > 40 &&
                window.frame.intersects(prompt.frame)
        }
        if isCovered { return prompt }
    }
    return nil
}

struct SystemFrontDecision: Equatable {
    var front: [SystemFrontWindow]
    var activatePid: pid_t?
    var showsPrompt: Bool
}

func decideSystemFront(windows: [OrderedOnScreenWindow], running: [RunningSystemApp], frontmostPid: pid_t?,
                       ownPid: pid_t, isHiddenByWinMux: (UInt32) -> Bool = { _ in false }) -> SystemFrontDecision {
    let bundleIdsByPid = Dictionary(running.map { ($0.pid, $0.bundleId) }, uniquingKeysWith: { first, _ in first })
    let front = selectSystemFrontWindows(in: windows, bundleIdsByPid: bundleIdsByPid, isHiddenByWinMux: isHiddenByWinMux)
    let promptPids = Set(running.filter { $0.bundleId == SystemFrontApp.accessPrompt }.map(\.pid))
    let covered = coveredAccessPrompt(in: windows, promptPids: promptPids, frontmostPid: frontmostPid, ownPid: ownPid)
    return SystemFrontDecision(front: front, activatePid: covered?.pid,
        showsPrompt: front.contains { $0.bundleId != SystemFrontApp.systemSettings })
}

/// Metadata only: no screenshots, titles, or Screen Recording permission.
private func orderedOnScreenWindows() -> [OrderedOnScreenWindow]? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    return windows.compactMap { window in
        guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return OrderedOnScreenWindow(id: id, pid: pid, layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            frame: frame)
    }
}

@MainActor
private var lastAccessPromptActivation: Date = .distantPast
/// When the Accessibility prompt's process launched or last showed a prompt. It may linger idle.
@MainActor
private var lastAccessPromptActivity: Date = .distantPast
@MainActor
private var systemPromptPollTimer: Timer?
@MainActor
private var runningApplicationsObservation: NSKeyValueObservation?
@MainActor
private var accessPromptPids: Set<pid_t> = []
@MainActor
private var lastSystemSettingsActivation: Date = .distantPast

/// A prompt's process launches without any event WinMux otherwise observes.
@MainActor
func startSystemFrontWindowWatcher() {
    guard runningApplicationsObservation == nil else { return }
    runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { _, _ in
        Task { @MainActor in updateSystemFrontWindows() }
    }
    // A prompt may already be waiting when WinMux starts.
    updateSystemFrontWindows(force: true)
}

@MainActor
func noteSystemSettingsActivation(now: Date = .now) {
    lastSystemSettingsActivation = now
}

/// System Settings activates before its window exists. For a moment after that, focus stays with it.
@MainActor
func isSystemSettingsOpening(now: Date = .now) -> Bool {
    now.timeIntervalSince(lastSystemSettingsActivation) < 3
}

/// Runs after every refresh session and while a prompt can be shown. Queries the window server
/// only when System Settings is visible or frontmost, a prompt can be on screen, or system
/// windows were already listed.
@MainActor
func updateSystemFrontWindows(force: Bool = false, now: Date = .now) {
    // Tests must not react to System Settings or prompts open on the machine running them.
    guard !isUnitTest else { return }
    let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningSystemApp? in
        guard let bundleId = app.bundleIdentifier, SystemFrontApp.all.contains(bundleId) else { return nil }
        return RunningSystemApp(pid: app.processIdentifier, bundleId: bundleId, isActive: app.isActive)
    }
    // A newly launched prompt process is about to show a prompt; one that lingers idle is not.
    let promptPids = Set(running.filter { $0.bundleId == SystemFrontApp.accessPrompt }.map(\.pid))
    if !promptPids.subtracting(accessPromptPids).isEmpty { lastAccessPromptActivity = now }
    accessPromptPids = promptPids
    let promptRecent = running.contains { $0.bundleId == SystemFrontApp.accessPrompt } &&
        now.timeIntervalSince(lastAccessPromptActivity) < 10
    // The notification prompt process always runs; its prompts activate it when they appear.
    let mayShow = force || !systemFrontWindows.isEmpty || promptRecent || isSystemSettingsInVisibleWorkspace() ||
        running.contains { $0.isActive }
    guard mayShow, let windows = orderedOnScreenWindows() else {
        if !mayShow {
            applySystemFrontWindows([])
            updateSystemPromptPolling(false)
        }
        return
    }
    let decision = decideSystemFront(windows: windows, running: running,
        frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
        ownPid: ProcessInfo.processInfo.processIdentifier) { id in Window.get(byId: id)?.isHiddenInCorner == true }
    applySystemFrontWindows(decision.front)
    if decision.front.contains(where: { $0.bundleId == SystemFrontApp.accessPrompt }) { lastAccessPromptActivity = now }
    if let pid = decision.activatePid, now.timeIntervalSince(lastAccessPromptActivation) > 0.4,
       let app = NSRunningApplication(processIdentifier: pid)
    {
        // A prompt waits for an answer: it takes focus back until it is answered.
        lastAccessPromptActivation = now
        app.activate(options: .activateIgnoringOtherApps)
    }
    // Clicking the frontmost app's window raises it over a prompt, and closing a prompt, raise no
    // event WinMux observes. Notification prompts activate their process before their window appears.
    updateSystemPromptPolling(decision.showsPrompt || promptRecent ||
        running.contains { $0.bundleId == SystemFrontApp.notificationPrompt && $0.isActive })
}

@MainActor
private func isSystemSettingsInVisibleWorkspace() -> Bool {
    monitors.contains { monitor in
        monitor.activeWorkspace.allLeafWindowsRecursive.contains { $0.app.rawAppBundleId == SystemFrontApp.systemSettings }
    }
}

@MainActor
private func updateSystemPromptPolling(_ isNeeded: Bool) {
    if isNeeded, systemPromptPollTimer == nil {
        systemPromptPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { updateSystemFrontWindows() }
        }
    } else if !isNeeded {
        systemPromptPollTimer?.invalidate()
        systemPromptPollTimer = nil
    }
}

@MainActor
func setSystemFrontWindowsForTests(_ windows: [SystemFrontWindow]) {
    applySystemFrontWindows(windows)
}

@MainActor
func resetSystemFrontStateForTests() {
    applySystemFrontWindows([])
    lastSystemSettingsActivation = .distantPast
}

@MainActor
private func applySystemFrontWindows(_ windows: [SystemFrontWindow]) {
    let changed = windows != systemFrontWindows
    systemFrontWindows = windows
    guard changed || !windows.isEmpty else { return }
    for panel in WorkspaceSidebarPanel.visiblePanels {
        panel.applyWorkspaceSidebarLayer(stayOnTop: config.workspaceSidebar.stayOnTop, yieldsToSystemWindows: panel.isAtRest)
    }
}

extension WorkspaceSidebarPanel {
    /// Collapsed, or pinned open. A Dock or Sidebar expanded for use keeps its level.
    var isAtRest: Bool { !viewModel.isWorkspaceSidebarExpanded || config.workspaceSidebar.alwaysExpanded }
}

/// System Settings opened from elsewhere joins the workspace you are on, instead of switching
/// you to the hidden workspace where its window was left.
@MainActor
func bringSystemSettingsToFocusedWorkspace(_ window: Window) {
    guard window.app.rawAppBundleId == SystemFrontApp.systemSettings else { return }
    moveFloatingWindowToFocusedWorkspace(window)
}

/// A window the user tiled, or one already visible on another display, keeps its place.
@MainActor
@discardableResult
func moveFloatingWindowToFocusedWorkspace(_ window: Window) -> Bool {
    let target = focus.workspace
    guard window.isFloating, target.isVisible, let source = window.nodeWorkspace, source !== target, !source.isVisible
    else { return false }
    window.bind(to: target, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    return true
}
