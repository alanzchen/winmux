import AppKit
import Common

// Pinning with a Hookmark-compatible integration (Tabs mode): the user's own scripts for an app read the
// item its front window shows, and open such an item again.
//
// Hookmark's scripts read whatever is in front. A tab's menu can be opened on a tab that isn't, so WinMux
// first brings that tab's window to the front, as a click on it would, checks the app's focused window is
// that very window, runs the script, and checks again that it still is: anything else, and it keeps nothing
// the script found. It never runs a script in the background, never on its own, and never for a window the
// user didn't pick. What the script answers is untrusted data: kept only once it's a well-formed address.
//
// A link's identity isn't a window's: opening one with an integration's Open Item is a launcher's open.
// Nothing is claimed or moved.

// MARK: - Seams

/// Brings the window to the front, as a click on its tab's row does. Replaceable for tests.
@MainActor
var linkIntegrationFocusWindow: @MainActor (Window) async -> Void = { window in
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    await runWorkspaceSidebarSession {
        focusWindowFromSidebarNow(window.windowId, targetMonitorScopeId: nil, keepsPointer: true)
    }?.value
}

/// The frontmost app's process and its focused window, as accessibility reports them. Replaceable for tests.
@MainActor
var linkIntegrationFrontWindow: @MainActor () async -> (pid: Int32, windowId: UInt32)? = {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    let front: (pid: Int32, windowId: UInt32)? = await Task.detached {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self).containingWindowId().map { (pid, $0) }
    }.value
    // The app read must still be the front one: another may have come forward during the read.
    guard let front, NSWorkspace.shared.frontmostApplication?.processIdentifier == front.pid else { return nil }
    return front
}

/// How many native focus changes macOS has reported so far. Replaceable for tests.
@MainActor
var linkIntegrationFocusEvents: @MainActor () -> UInt64 = { nativeFocusEvents.value }

/// How long WinMux waits for the window it brought forward to be the front window.
let linkIntegrationFrontWait: TimeInterval = 2
/// How long the focus change WinMux made has to be reported before a script runs.
let linkIntegrationFocusSettle: TimeInterval = 0.2

// MARK: - Taking a link

enum LinkIntegrationCapture: Equatable {
    case captured(WorkspaceSidebarPinResource)
    case refused(String)
}

/// The integration for this window's app, as a menu offers it.
@MainActor
func linkIntegrationMenuState(_ integration: LinkIntegration) -> (enabled: Bool, help: String) {
    let analysis = integration.analysis
    if !integration.isEnabled { return (false, "The \(integration.appName) integration is off. Turn it on in Settings → Integrations.") }
    if !integration.isActive {
        return (false, "Its scripts changed since you turned it on. Look at them again in Settings → Integrations.")
    }
    if !analysis.canCapture { return (false, analysis.problems.first ?? "This integration can't take a link.") }
    return (true, "Runs your \(integration.appName) integration's Get Address script on this tab's window, brought to the front first")
}

/// Pin with an integration, or Update from Window with one: the tab's one window is brought to the front,
/// checked, and the integration's scripts read the item it shows. As with Pin Page, a newer Pin or Update,
/// or any change to the tab since, ends it with nothing written.
@MainActor
func pinLinkWithIntegrationFromSidebar(_ name: String, integrationId: String, updating: Bool) {
    guard let tab = Workspace.existing(byName: name) else { return }
    guard let integration = linkIntegrationStore.integration(id: integrationId) else {
        return showPinDocumentNotice("Pin with Integration", "That integration is gone.")
    }
    let title = updating ? "Update from Window" : "Pin with \(integration.appName) Integration"
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice(title, reason) }
    let state = linkIntegrationMenuState(integration)
    guard state.enabled else { return showPinDocumentNotice(title, state.help) }
    let window: Window
    switch pinDocumentSourceWindow(tab) {
        case .success(let source): window = source
        case .failure(let refusal): return showPinDocumentNotice(title, refusal.message)
    }
    guard window.app.rawAppBundleId == integration.bundleId else {
        return showPinDocumentNotice(title, "This tab's window isn't \(integration.appName)'s.")
    }
    let appearance = workspaceSidebarOrganizationStore.state.workspaces[name]
    if appearance?.isFavorite == true, appearance?.document != nil { return }
    if updating, appearance?.isFavorite != true || appearance?.link == nil { return }
    let target = PinDocumentTarget(tab)
    let operation = beginPinResourceOperation(name)
    // Each script runs only while this is the tab's newest Pin or Update, the tab is as it was, and the
    // integration is still on with the scripts the user trusted.
    let isStillWanted: @MainActor () -> Bool = {
        isNewestPinResourceOperation(name, operation) && target.isCurrent && pinDocumentStillSource(tab, window)
            && linkIntegrationStore.integration(id: integration.id).map { $0.isActive && $0.digest == integration.digest } == true
    }
    _ = Task { @MainActor in
        let capture = await captureWithLinkIntegration(integration, window: window, isStillWanted: isStillWanted)
        guard isNewestPinResourceOperation(name, operation) else { return }
        guard target.isCurrent, pinDocumentStillSource(tab, window) else {
            endPinResourceOperation(name, operation)
            return showPinDocumentNotice(title, pinDocumentChangedMessage)
        }
        switch capture {
            case .refused(let why):
                endPinResourceOperation(name, operation)
                showPinDocumentNotice(title, why)
            case .captured(let resource):
                runPinDocumentWrite(title) {
                    defer { endPinResourceOperation(name, operation) }
                    guard isNewestPinResourceOperation(name, operation) else { return nil }
                    guard target.isCurrent, pinDocumentStillSource(tab, window) else { return pinDocumentChangedMessage }
                    // The user may have turned it off or changed it meanwhile.
                    guard linkIntegrationStore.integration(id: integration.id)?.digest == integration.digest,
                          linkIntegrationStore.integration(id: integration.id)?.isActive == true
                    else { return "The integration changed while it ran. Nothing was pinned." }
                    return commitWorkspaceSidebarPinResource(tab, resource, title: title)
                }
        }
    }
}

let linkIntegrationWithdrawnMessage = "The integration was turned off, changed or removed, or the tab changed, so WinMux ran nothing more."
let linkIntegrationFrontChangedMessage = "The front window changed while the integration ran, so WinMux keeps nothing it found."

/// Runs the integration's Get Address, and Get Name if needed, on `window`, with it in front throughout:
/// any focus change macOS reports while a script runs, even one that comes back, voids what it found.
@MainActor
func captureWithLinkIntegration(_ integration: LinkIntegration, window: Window,
                                isStillWanted: @escaping @MainActor () -> Bool = { true }) async -> LinkIntegrationCapture {
    let appName = integration.appName
    // A browser's window must be known not to be private before anything is read from it.
    if let browser = BrowserTabAdapter(bundleId: integration.bundleId),
       let refusal = await pinPageWindowPrivacyRefusal(window, browser: browser) {
        return .refused(refusal)
    }
    guard isStillWanted() else { return .refused(linkIntegrationWithdrawnMessage) }
    guard await linkIntegrationBringToFront(window) else {
        return .refused("WinMux couldn't bring this tab's window to the front, so it ran nothing. Integrations read what's in front.")
    }
    let address = await runLinkIntegrationSlot(integration.getAddress, integration: integration, window: window,
        isStillWanted: isStillWanted)
    let output: String
    switch address {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let answer): output = answer
    }
    switch parseHookmarkAddress(output) {
        case .empty:
            return .refused("\(appName)'s integration found no item in this window.")
        case .callback:
            return .refused("\(appName)'s integration waits for the app to call Hookmark back, which only Hookmark receives.")
        case .hookmarkLink:
            return .refused("\(appName)'s integration answered with a Hookmark link (hook://), which only Hookmark opens.")
        case .invalid(let why):
            return .refused("\(appName)'s integration answered with something WinMux doesn't keep. \(why)")
        case .file(let url, _):
            guard let document = makeWorkspaceSidebarPinDocument(url, bundleId: integration.bundleId) else {
                return .refused("WinMux can't tell “\(url.lastPathComponent)” apart from other files on its disk, so it pins nothing.")
            }
            return .captured(.file(document))
        case .link(let url, let answeredName):
            var name = answeredName
            if name == nil, let getName = integration.getName, integration.analysis.canName {
                // Get Name runs only when the address carried no name, under the same checks. Its answer is
                // kept only if they all held; the address, checked already, is kept either way.
                if case .success(let answer) = await runLinkIntegrationSlot(getName, integration: integration, window: window,
                    isStillWanted: isStillWanted) {
                    name = hookmarkCleanName(answer)
                }
            }
            let title = name.flatMap { $0.isEmpty ? nil : $0 } ?? String(url.prefix(200))
            return .captured(.link(WorkspaceSidebarPinLink(url: url, title: title, adapter: "integration",
                bundleId: integration.bundleId, source: .window, integration: integration.id)))
    }
}

/// One script slot: run only while still wanted, with the window in front and no focus change reported since
/// that was checked; its answer kept only if macOS reported no focus change while it ran and the window is
/// still in front. The clipboard is the script's to use: WinMux never writes it. The answer, or why there's none.
@MainActor
private func runLinkIntegrationSlot(_ script: String, integration: LinkIntegration, window: Window,
                                    isStillWanted: @MainActor () -> Bool) async -> Result<String, LinkIntegrationRefusal> {
    let appName = integration.appName
    guard isStillWanted() else { return .failure(.init(linkIntegrationWithdrawnMessage)) }
    let focusEvents = linkIntegrationFocusEvents()
    let inFrontBefore = await linkIntegrationWindowIsInFront(window)
    // Right before the script starts: nothing reported since the count, and still wanted.
    guard inFrontBefore, linkIntegrationFocusEvents() == focusEvents, isStillWanted() else {
        return .failure(.init(linkIntegrationFrontChangedMessage))
    }
    let result = await runHookmarkScript(script, HookmarkPlaceholderValues(appName: appName))
    let inFront = await linkIntegrationWindowIsInFront(window)
    guard inFront, linkIntegrationFocusEvents() == focusEvents else { return .failure(.init(linkIntegrationFrontChangedMessage)) }
    switch result {
        case .success(let output): return .success(output)
        case .notAuthorized:
            return .failure(.init("Allow WinMux to control \(appName) in System Settings → Privacy & Security → Automation, then try again."))
        case .failed(let message): return .failure(.init("\(appName)'s integration script failed: \(message)"))
        case .timedOut:
            return .failure(.init("\(appName)'s integration didn't answer within \(Int(hookmarkScriptTimeout)) seconds."))
    }
}

struct LinkIntegrationRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Brings the window forward and waits until it's the front app's focused window.
@MainActor
func linkIntegrationBringToFront(_ window: Window) async -> Bool {
    if await linkIntegrationWindowIsInFront(window) { return true }
    await linkIntegrationFocusWindow(window)
    let deadline = ProcessInfo.processInfo.systemUptime + linkIntegrationFrontWait
    while ProcessInfo.processInfo.systemUptime < deadline {
        if await linkIntegrationWindowIsInFront(window) {
            // macOS reports the focus change WinMux just made a moment later: let it land before a script's
            // run is measured against it.
            do { try await Task.sleep(for: .seconds(linkIntegrationFocusSettle)) } catch { return false }
            return await linkIntegrationWindowIsInFront(window)
        }
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
    }
    return false
}

@MainActor
func linkIntegrationWindowIsInFront(_ window: Window) async -> Bool {
    guard let front = await linkIntegrationFrontWindow() else { return false }
    return front.pid == window.app.pid && front.windowId == window.windowId && Window.get(byId: window.windowId) === window
}

/// Why a browser window can't have anything read from it now, if so: private, or not known not to be.
@MainActor
func pinPageWindowPrivacyRefusal(_ window: Window, browser: BrowserTabAdapter) async -> String? {
    let appName = window.app.name ?? (browser == .safari ? "Safari" : "The browser")
    var read = await pinPageWindowRead(window)
    // Safari builds a window's accessibility only once something asks, so a first read of a window in the
    // background may not reach its toolbar yet: read again, as Pin Page does, before calling it uncertain.
    for _ in 0 ..< 2 where browser == .safari && read != nil && read?.privacy == .unknown {
        try? await Task.sleep(for: .milliseconds(250))
        read = await pinPageWindowRead(window)
    }
    guard let read else { return "WinMux couldn't read this \(appName) window, so it runs nothing on it." }
    if read.privacy == .private { return pinPagePrivateMessage }
    switch browser {
        case .safari:
            return read.privacy == .normal ? nil
                : "WinMux can't tell whether this is a Private Browsing window, so it runs nothing on it."
        case .chromium:
            switch await pinPageChromiumModesOf(window.app.pid) {
                case .success(let modes):
                    let after = await pinPageWindowRead(window)
                    if after?.privacy == .private { return pinPagePrivateMessage }
                    switch pinPageChromiumPrivacy(modes) {
                        case .normal: return nil
                        case .private: return pinPageIncognitoOpenMessage(appName)
                        case .unknown: return "\(appName) didn't say whether this is an Incognito window, so WinMux runs nothing on it."
                    }
                case .failure(.notAuthorized):
                    return "WinMux asks \(appName) whether its windows are Incognito windows first. Allow WinMux to control "
                        + "\(appName) in System Settings → Privacy & Security → Automation, then try again."
                case .failure:
                    return "\(appName) didn't say whether this is an Incognito window, so WinMux runs nothing on it."
            }
    }
}

// MARK: - Opening

/// An integration's Open Item opens the pinned address, given as `$0`, as a launcher would: nothing is
/// claimed or moved. A change to the pin before it runs opens nothing.
@MainActor
func openPinnedLinkWithIntegration(_ integration: LinkIntegration, link: WorkspaceSidebarPinLink, target: PinDocumentTarget) {
    guard let openItem = integration.openItem else { return }
    _ = Task { @MainActor in
        // Only the scripts the user trusted, as they were when the pin was clicked.
        guard target.isCurrent, let current = linkIntegrationStore.integration(id: integration.id), current.isActive,
              current.digest == integration.digest else { return }
        let result = await runHookmarkScript(openItem, HookmarkPlaceholderValues(address: link.url, appName: integration.appName))
        guard target.isCurrent else { return }
        switch result {
            case .success: break
            case .notAuthorized:
                showPinDocumentNotice("Pinned Link",
                    "Allow WinMux to control \(integration.appName) in System Settings → Privacy & Security → Automation to open this pin.")
            case .failed(let message):
                showPinDocumentNotice("Pinned Link", "\(integration.appName)'s Open Item script failed: \(message)")
            case .timedOut:
                showPinDocumentNotice("Pinned Link",
                    "\(integration.appName)'s Open Item script didn't finish within \(Int(hookmarkScriptTimeout)) seconds.")
        }
    }
}

/// Whether an integration opens `link`, taken by one (or typed for a scheme only one opens): its Open Item,
/// while it's on; nil when it has none it can run, so macOS opens the link, as Hookmark leaves it to. One
/// that's off, changed or removed says so, and nothing else is chosen in its place.
@MainActor
func linkIntegrationOpening(_ link: WorkspaceSidebarPinLink) -> Result<LinkIntegration, PinLinkEntryRefusal>? {
    guard let id = link.integration else { return nil }
    guard let integration = linkIntegrationStore.integration(id: id) else {
        return .failure(.init("This pin opens with an integration that's since been removed. Add it again in Settings → "
            + "Integrations, then choose Update from Window, or choose Edit Link…"))
    }
    // Off or changed, it stands for nothing, not even macOS's own way of opening the link.
    if !integration.isEnabled {
        return .failure(.init("This pin opens with the \(integration.appName) integration, which is off. "
            + "Turn it on in Settings → Integrations, or choose Edit Link…"))
    }
    if !integration.isActive {
        return .failure(.init("The \(integration.appName) integration's scripts changed since you turned it on, so it runs "
            + "nothing. Look at them again in Settings → Integrations."))
    }
    guard integration.openItem?.isEmpty == false else { return nil }
    return integration.analysis.canOpen ? .success(integration) : nil
}

// MARK: - Menu

/// The tab menu's integration item for a tab whose one window's app has an integration: Pin with it, or
/// Update from Window with it for a pinned link.
@MainActor
func workspaceSidebarPinIntegrationMenuEntries(_ workspace: WorkspaceSidebarWorkspaceViewModel, windowBundleId: String?,
                                               refusal: PinDocumentRefusal?,
                                               send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> [WorkspaceSidebarAppMenuEntry] {
    guard let integration = linkIntegrationStore.integration(forBundleId: windowBundleId) else { return [] }
    let name = workspace.name
    let state = linkIntegrationMenuState(integration)
    let help = switch refusal {
        case .split: "A pinned split brings back its own windows."
        case .noWindow: "Open the item in this tab first."
        case .severalWindows: "Works on a tab with one window."
        case nil: state.help
    }
    let updating = workspace.appearance.isFavorite && workspace.appearance.link != nil
    return [.init(title: updating ? "Update from Window (\(integration.appName) Integration)" : "Pin with \(integration.appName) Integration",
        enabled: state.enabled && refusal == nil,
        perform: { send(.pinLinkWithIntegration(name, integrationId: integration.id, updating: updating)) }, help: help)]
}
