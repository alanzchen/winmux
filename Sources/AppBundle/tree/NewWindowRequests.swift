import AppKit
import Common

/// How WinMux asks an app for one fresh window without switching to the windows it already has.
enum NewWindowMethod: Equatable {
    /// Not running and no adapter: launching opens it normally. Its windows follow the usual
    /// rules, landing in the focused workspace, and none is claimed as "the new window".
    case open
    /// Not running, with an adapter: launch in the background, let it restore its session,
    /// then ask for one fresh window.
    case launchThenScript(String)
    /// A tested AppleScript command that makes a window without activating the app.
    case script(String)
    /// Opt-in for other running apps: press the app's own New Window menu item.
    case menuItem
    /// Running, with no adapter and the menu fallback off. The launcher can't do anything useful.
    case unsupported
}

/// Apps with a tested way to make one new window. Each command creates a window directly;
/// none activates the app, so its other windows stay where they are.
let newWindowScriptCommands: [String: String] = [
    "com.apple.Safari": "make new document",
    "com.apple.finder": "make new Finder window",
    "com.apple.Terminal": "do script \"\"",
    "com.apple.TextEdit": "make new document",
    "com.googlecode.iterm2": "create window with default profile",
    "com.google.Chrome": "make new window",
    "com.brave.Browser": "make new window",
    "com.microsoft.edgemac": "make new window",
    "org.chromium.Chromium": "make new window",
]

func newWindowScriptSource(bundleId: String) -> String? {
    newWindowScriptCommands[bundleId].map { "tell application id \"\(bundleId)\" to \($0)" }
}

func newWindowMethod(bundleId: String, isRunning: Bool, menuFallbackEnabled: Bool) -> NewWindowMethod {
    if let script = newWindowScriptSource(bundleId: bundleId) {
        return isRunning ? .script(script) : .launchThenScript(script)
    }
    guard isRunning else { return .open }
    return menuFallbackEnabled ? .menuItem : .unsupported
}

/// Menu titles that mean "a new window of this app", in the languages WinMux recognizes.
let newWindowMenuTitles: Set<String> = [
    "new window", "nouvelle fenêtre", "neues fenster", "nueva ventana", "nuova finestra",
    "nova janela", "nieuw venster", "nytt fönster", "新建窗口", "新增視窗", "新規ウインドウ", "새로운 윈도우", "새 윈도우",
]

enum NewWindowMenuItemMatch {
    /// "New Window" itself.
    case exact
    /// An English "New … Window", such as Finder's "New Finder Window", or a "New Window…".
    case named
}

/// Whether a menu item makes a new window. Never a document, tab, message, or private window.
func newWindowMenuItemMatch(_ title: String) -> NewWindowMenuItemMatch? {
    var normalized = title.replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // "New Window…" still makes a window but asks something first, so a plain one wins.
    var asksFirst = false
    for ellipsis in ["…", "..."] where normalized.hasSuffix(ellipsis) {
        normalized = String(normalized.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces)
        asksFirst = true
    }
    if newWindowMenuTitles.contains(normalized) { return asksFirst ? .named : .exact }
    let isNamed = normalized.hasPrefix("new ") && normalized.hasSuffix(" window") &&
        !normalized.contains("private") && !normalized.contains("incognito")
    return isNamed ? .named : nil
}

/// Which menu item to press: an exact "New Window" first, then a named one.
func bestNewWindowMenuItemIndex(_ titles: [String]) -> Int? {
    let matches = titles.map(newWindowMenuItemMatch)
    return matches.firstIndex(of: .exact) ?? matches.firstIndex(of: .named)
}

enum NewWindowScriptResult: Equatable {
    case success
    case notAuthorized
    case failed(String)
}

/// AppleScript error -1743 means the user hasn't allowed WinMux to control the app.
func newWindowScriptResult(exitStatus: Int32, stderr: String) -> NewWindowScriptResult {
    if exitStatus == 0 { return .success }
    if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") { return .notAuthorized }
    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(message.isEmpty ? "AppleScript exited with status \(exitStatus)" : message)
}

/// How long an AppleScript request may take, including a first-time permission prompt the
/// user is reading. The window's own arrival deadline starts once the app has replied.
let newWindowScriptTimeout: TimeInterval = 60

/// Runs the script in `osascript` so a first-time permission prompt never blocks WinMux.
func runNewWindowScript(_ source: String, timeout: TimeInterval = newWindowScriptTimeout) async -> NewWindowScriptResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        let state = NewWindowScriptState(continuation)
        process.terminationHandler = { finished in
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            state.resume(newWindowScriptResult(exitStatus: finished.terminationStatus, stderr: stderr))
        }
        do {
            try process.run()
        } catch {
            state.resume(.failed(error.localizedDescription))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
            state.resume(.failed("The app didn't respond"))
        }
    }
}

/// Resumes the continuation once, whichever of termination or timeout comes first.
private final class NewWindowScriptState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NewWindowScriptResult, Never>?

    init(_ continuation: CheckedContinuation<NewWindowScriptResult, Never>) { self.continuation = continuation }

    func resume(_ result: NewWindowScriptResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

struct NewWindowRequestTarget: Equatable {
    let bundleId: String
    let appName: String
    let bundleURL: URL?
}

/// Every window a process has, including ones on other Spaces that WinMux hasn't registered.
@MainActor
func existingWindowIds(pid: Int32) -> Set<UInt32> {
    Set(MacWindow.allWindows.filter { $0.app.pid == pid }.map(\.windowId)).union(windowServerWindowIds(pid: pid))
}

/// A snapshot of every window on the system, so keep it off the main thread when polling.
nonisolated func windowServerWindowIds(pid: Int32) -> Set<UInt32> {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return Set(windows.compactMap { window in
        (window[kCGWindowOwnerPID as String] as? Int32) == pid ? window[kCGWindowNumber as String] as? UInt32 : nil
    })
}

/// Lets the launcher cancel a request at any stage, including while an app is still launching
/// and no intent has been registered yet.
@MainActor
final class NewWindowRequestHandle {
    fileprivate(set) var intentId: Int?
    private(set) var isCancelled = false

    /// The app may still open a window; it just follows the usual rules instead.
    func cancel() {
        isCancelled = true
        if let intentId { NewWindowIntentRegistry.shared.cancel(intentId: intentId) }
    }
}

/// Asks the app for one new window and reports once that window has landed in the workspace.
@MainActor
@discardableResult
func requestNewWindow(
    _ target: NewWindowRequestTarget,
    targetWorkspace: Workspace,
    completion: @escaping @MainActor (NewWindowRequestOutcome) -> Void,
) -> NewWindowRequestHandle {
    let handle = NewWindowRequestHandle()
    requestNewWindow(target, targetWorkspace: targetWorkspace, handle: handle, completion: completion)
    return handle
}

@MainActor
private func requestNewWindow(
    _ target: NewWindowRequestTarget,
    targetWorkspace: Workspace,
    handle: NewWindowRequestHandle,
    completion: @escaping @MainActor (NewWindowRequestOutcome) -> Void,
) {
    guard !serverArgs.isReadOnly else {
        completion(.failed("WinMux is read-only"))
        return
    }
    // Focus moving at any point after the choice, even while an app launches, means the user
    // has moved on.
    let focusGeneration = focusChangeGeneration
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId)
        .first { $0.activationPolicy == .regular && !$0.isTerminated }
    switch newWindowMethod(bundleId: target.bundleId, isRunning: running != nil,
        menuFallbackEnabled: config.workspaceSidebar.launcherMenuFallback)
    {
        case .unsupported:
            completion(.failed("\(target.appName) can't open a new window from WinMux"))
        case .open:
            Task { @MainActor in
                let failure = await launchApplication(target, activates: true).failure
                if handle.isCancelled {
                    completion(.cancelled)
                } else if let failure {
                    completion(.failed(failure))
                } else {
                    completion(.opened)
                }
            }
        case .launchThenScript(let script):
            Task { @MainActor in
                let launch = await launchApplication(target, activates: false)
                guard let app = launch.app else {
                    completion(.failed(launch.failure ?? "\(target.appName) couldn't be opened"))
                    return
                }
                // Session restore finishes first; only the window asked for afterwards is claimed.
                await waitUntilSettled(app)
                guard !handle.isCancelled,
                      winMuxWorkspaceState.workspaceById[targetWorkspace.id] === targetWorkspace, !targetWorkspace.isArchived
                else {
                    completion(.cancelled)
                    return
                }
                handle.intentId = startNewWindowRequest(.script(script), target: target, pid: app.processIdentifier,
                    targetWorkspace: targetWorkspace, focusGeneration: focusGeneration, completion: completion)
            }
        case .script, .menuItem:
            let method = newWindowMethod(bundleId: target.bundleId, isRunning: true,
                menuFallbackEnabled: config.workspaceSidebar.launcherMenuFallback)
            handle.intentId = startNewWindowRequest(method, target: target, pid: running?.processIdentifier,
                targetWorkspace: targetWorkspace, focusGeneration: focusGeneration, completion: completion)
    }
}

/// Registers the intent, then sends the request.
@MainActor
@discardableResult
private func startNewWindowRequest(
    _ method: NewWindowMethod,
    target: NewWindowRequestTarget,
    pid: Int32?,
    targetWorkspace: Workspace,
    focusGeneration: UInt64,
    completion: @escaping @MainActor (NewWindowRequestOutcome) -> Void,
) -> Int? {
    let registry = NewWindowIntentRegistry.shared
    guard let intent = registry.register(bundleId: target.bundleId, pid: pid, targetWorkspace: targetWorkspace,
        preexistingWindowIds: pid.map(existingWindowIds(pid:)) ?? [], focusGeneration: focusGeneration,
        timeout: newWindowScriptTimeout + newWindowIntentTimeout,
        completion: { outcome in completion(outcome) })
    else {
        completion(.failed("\(target.appName) is already opening a window"))
        return nil
    }
    let intentId = intent.id
    // Expiry runs on its own, so a request stuck in dispatch still ends.
    Task { @MainActor in await watchNewWindowIntentExpiry(intentId) }
    Task { @MainActor in
        registry.recordFocusWhenSent(forIntent: intentId, .current)
        if let failure = await dispatchNewWindowRequest(method, target: target, pid: pid) {
            registry.cancel(intentId: intentId, outcome: .failed(failure))
        } else {
            // The app took the request; its window now has the usual time to appear.
            registry.restartDeadline(forIntent: intentId)
        }
    }
    return intentId
}

/// Ends the request at its deadline. Wakes at least every second, because the deadline moves
/// once the app accepts the request.
@MainActor
func watchNewWindowIntentExpiry(_ intentId: Int) async {
    let registry = NewWindowIntentRegistry.shared
    while let deadline = registry.deadline(forIntent: intentId) {
        try? await Task.sleep(for: .seconds(min(max(deadline - registry.now(), 0) + 0.2, 1)))
        registry.expireOverdueIntents()
    }
}

private struct NewWindowLaunch {
    var app: NSRunningApplication?
    var failure: String?
}

@MainActor
private func launchApplication(_ target: NewWindowRequestTarget, activates: Bool) async -> NewWindowLaunch {
    let url = target.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId)
    guard let url else { return NewWindowLaunch(failure: "\(target.appName) isn't installed") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    configuration.addsToRecentItems = false
    do {
        return NewWindowLaunch(app: try await NSWorkspace.shared.openApplication(at: url, configuration: configuration))
    } catch {
        return NewWindowLaunch(failure: "\(target.appName) couldn't be opened: \(error.localizedDescription)")
    }
}

/// Waits for launch to finish, then until the app stops opening the windows it restores:
/// its window list unchanged for most of a second, or six seconds at most.
@MainActor
private func waitUntilSettled(_ app: NSRunningApplication) async {
    for _ in 0..<150 {
        if app.isFinishedLaunching { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    let pid = app.processIdentifier
    func snapshot() async -> Set<UInt32> { await Task.detached { windowServerWindowIds(pid: pid) }.value }
    var windows = await snapshot()
    var unchangedPolls = 0
    for _ in 0..<24 {
        if unchangedPolls >= 3 { break }
        try? await Task.sleep(for: .milliseconds(250))
        let current = await snapshot()
        unchangedPolls = current == windows ? unchangedPolls + 1 : 0
        windows = current
    }
}

/// Sends the request. Returns a message when it couldn't be sent.
@MainActor
private func dispatchNewWindowRequest(_ method: NewWindowMethod, target: NewWindowRequestTarget, pid: Int32?) async -> String? {
    switch method {
        case .script(let source):
            switch await runNewWindowScript(source) {
                case .success: return nil
                case .notAuthorized:
                    return "Allow WinMux to control \(target.appName) in System Settings → Privacy & Security → Automation"
                case .failed(let message): return "\(target.appName) couldn't open a new window: \(message)"
            }
        case .menuItem:
            guard let pid, let macApp = MacApp.allAppsMap[pid] else { return "WinMux isn't managing \(target.appName) yet" }
            let pressed = (try? await macApp.pressNewWindowMenuItem()) ?? false
            return pressed ? nil : "\(target.appName) has no New Window menu item"
        case .open, .launchThenScript, .unsupported:
            return "\(target.appName) can't open a new window from WinMux"
    }
}
