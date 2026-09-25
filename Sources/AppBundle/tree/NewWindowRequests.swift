import AppKit
import Common

/// How WinMux asks an app for one fresh window without switching to the windows it already has.
enum NewWindowMethod: Equatable {
    /// Not running: launching it opens its first window.
    case launch
    /// A tested AppleScript command that makes a window without activating the app.
    case script(String)
    /// Opt-in for other running apps: press the app's own New Window menu item.
    case menuItem
    /// Running, with no adapter and the menu fallback off. The launcher can only switch to it.
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

func newWindowMethod(bundleId: String, isRunning: Bool, menuFallbackEnabled: Bool) -> NewWindowMethod {
    guard isRunning else { return .launch }
    if let command = newWindowScriptCommands[bundleId] {
        return .script("tell application id \"\(bundleId)\" to \(command)")
    }
    return menuFallbackEnabled ? .menuItem : .unsupported
}

/// Menu titles that mean "a new window of this app", in the languages WinMux recognizes.
let newWindowMenuTitles: Set<String> = [
    "new window", "nouvelle fenêtre", "neues fenster", "nueva ventana", "nuova finestra",
    "nova janela", "nieuw venster", "nytt fönster", "新建窗口", "新增視窗", "新規ウインドウ", "새로운 윈도우", "새 윈도우",
]

/// Which menu item to press: an exact "New Window" first, then an English "New … Window",
/// such as Finder's "New Finder Window". Never a document, tab, or message command.
func bestNewWindowMenuItemIndex(_ titles: [String]) -> Int? {
    let normalized = titles.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    if let exact = normalized.firstIndex(where: { newWindowMenuTitles.contains($0) }) { return exact }
    return normalized.firstIndex { title in
        title.hasPrefix("new ") && title.hasSuffix(" window") && !title.contains("private") && !title.contains("incognito")
    }
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

/// Runs the script in `osascript` so a first-time permission prompt never blocks WinMux.
func runNewWindowScript(_ source: String, timeout: TimeInterval = newWindowIntentTimeout) async -> NewWindowScriptResult {
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

/// Asks the app for one new window and waits until that window lands in `targetWorkspaceName`.
/// Success means the window was placed, not merely that the request was sent.
@MainActor
@discardableResult
func requestNewWindow(
    _ target: NewWindowRequestTarget,
    targetWorkspaceName: String,
    completion: @escaping @MainActor (NewWindowRequestOutcome) -> Void,
) -> Bool {
    guard !serverArgs.isReadOnly else {
        completion(.failed("WinMux is read-only"))
        return false
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId)
        .first { $0.activationPolicy == .regular && !$0.isTerminated }
    let method = newWindowMethod(bundleId: target.bundleId, isRunning: running != nil,
        menuFallbackEnabled: config.workspaceSidebar.launcherMenuFallback)
    if method == .unsupported {
        completion(.failed("\(target.appName) doesn't support opening a new window from WinMux"))
        return false
    }
    let pid = running?.processIdentifier
    let preexisting = Set(MacWindow.allWindows.filter { pid != nil && $0.app.pid == pid }.map(\.windowId))
    let registry = NewWindowIntentRegistry.shared
    guard let intent = registry.register(bundleId: target.bundleId, pid: pid, targetWorkspaceName: targetWorkspaceName,
        preexistingWindowIds: preexisting, focusGeneration: focusChangeGeneration,
        completion: { outcome in completion(outcome) })
    else {
        completion(.failed("\(target.appName) is already opening a window"))
        return false
    }
    let intentId = intent.id
    Task { @MainActor in
        if let failure = await dispatchNewWindowRequest(method, target: target, running: running, intentId: intentId) {
            registry.cancel(intentId: intentId, outcome: .failed(failure))
            return
        }
        // Detection places the window; this only ends a request that never produced one.
        try? await Task.sleep(for: .seconds(newWindowIntentTimeout + 0.5))
        registry.expireOverdueIntents()
    }
    return true
}

/// Sends the request. Returns a message when it couldn't be sent.
@MainActor
private func dispatchNewWindowRequest(
    _ method: NewWindowMethod,
    target: NewWindowRequestTarget,
    running: NSRunningApplication?,
    intentId: Int,
) async -> String? {
    switch method {
        case .launch:
            let url = target.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId)
            guard let url else { return "\(target.appName) isn't installed" }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            do {
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                NewWindowIntentRegistry.shared.setPid(app.processIdentifier, forIntent: intentId)
                return nil
            } catch {
                return "\(target.appName) couldn't be opened: \(error.localizedDescription)"
            }
        case .script(let source):
            switch await runNewWindowScript(source) {
                case .success: return nil
                case .notAuthorized:
                    return "Allow WinMux to control \(target.appName) in System Settings → Privacy & Security → Automation"
                case .failed(let message): return "\(target.appName) couldn't open a new window: \(message)"
            }
        case .menuItem:
            guard let pid = running?.processIdentifier, let macApp = MacApp.allAppsMap[pid] else {
                return "WinMux isn't managing \(target.appName) yet"
            }
            let pressed = (try? await macApp.pressNewWindowMenuItem()) ?? false
            return pressed ? nil : "\(target.appName) has no New Window menu item"
        case .unsupported:
            return "\(target.appName) doesn't support opening a new window from WinMux"
    }
}
