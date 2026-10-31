import AppKit
import Common

// Tabs mode: shortcuts to resources, among the pins. A shortcut is taken from a tab's window, as a pin's
// home is, or typed, but the tab stays as it was: its window remains in its tab, where it was. A shortcut
// holds no window, lends none, and is never part of a pinned split. Clicking it goes to its resource:
// a window WinMux can prove shows it, which only a file's identity proves, is shown; anything else is
// opened by its app, its integration or macOS, as a launcher opens it, and WinMux says nothing of where
// it opened or claims the window it opened in.

// MARK: - Seams

/// Opens `file` with the app at the second URL, bringing it forward, as a launcher does. Replaceable for tests.
@MainActor
var openResourceShortcutFile: @MainActor (URL, URL) async throws -> Void = { file, app in
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
}

// MARK: - The sidebar's view of them

struct WorkspaceSidebarResourceShortcutViewModel: Hashable, Identifiable {
    let id: String
    /// The project whose pins it's among, unless it's in All Projects.
    let projectId: WorkspaceProjectId
    /// Always its resource's name.
    let name: String
    /// Its resource's mark: a page, a link or a document.
    let symbolName: String
    /// The app it opens in, for its icon.
    let app: WorkspaceSidebarSavedApp?
    let isInAllProjects: Bool
    /// A window proven to show its resource is in front. Never set for a shortcut WinMux can only open.
    var isActive = false
    /// WinMux can prove which window shows it, and so go to that window, not only open it.
    let findsItsWindow: Bool
    /// An address, not a file: Edit Link… changes it.
    let isLink: Bool
    /// Something it can't go to: from a newer WinMux, or damaged.
    let isReadable: Bool
    let help: String
}

/// Every project's shortcuts, in the order they were added.
@MainActor
func workspaceSidebarResourceShortcutViewModels() -> [WorkspaceSidebarResourceShortcutViewModel] {
    (workspaceSidebarOrganizationStore.state.resourceShortcuts ?? []).map(workspaceSidebarResourceShortcutViewModel)
}

extension [WorkspaceSidebarResourceShortcutViewModel] {
    /// Those among `projectId`'s pins: in All Projects, or the project's own.
    func shown(in projectId: WorkspaceProjectId) -> (allProjects: Self, project: Self) {
        (filter(\.isInAllProjects), filter { !$0.isInAllProjects && $0.projectId == projectId })
    }
}

@MainActor
func workspaceSidebarResourceShortcutViewModel(_ shortcut: WorkspaceSidebarResourceShortcut) -> WorkspaceSidebarResourceShortcutViewModel {
    let app = workspaceSidebarResourceShortcutApp(shortcut)
    let appName = app?.name
    let findsItsWindow = shortcut.document != nil
    let help: String
    if !shortcut.isReadable {
        help = shortcut.version > WorkspaceSidebarResourceShortcut.currentVersion
            ? "“\(shortcut.name)”: made by a newer WinMux" : "This shortcut is damaged. Remove it and add it again."
    } else if let document = shortcut.document {
        help = "Go to “\(document.name)” in \(appName ?? "its app")"
    } else if let link = shortcut.link, let integration = link.integration.flatMap(linkIntegrationStore.integration(id:)) {
        help = "Open “\(link.title)” with the \(integration.appName) integration. WinMux can't see which window shows it."
    } else {
        help = "Open “\(shortcut.name)”\(appName.map { " in \($0)" } ?? ""). WinMux can't see which window shows it."
    }
    return WorkspaceSidebarResourceShortcutViewModel(id: shortcut.id, projectId: shortcut.projectId, name: shortcut.name,
        symbolName: shortcut.resource?.symbolName ?? "questionmark", app: app, isInAllProjects: shortcut.isInAllProjects,
        isActive: workspaceSidebarResourceShortcutIsActive(shortcut), findsItsWindow: findsItsWindow, isLink: shortcut.link != nil,
        isReadable: shortcut.isReadable, help: help)
}

/// The app a shortcut opens in, for its icon: the document's app, or the link's.
@MainActor
func workspaceSidebarResourceShortcutApp(_ shortcut: WorkspaceSidebarResourceShortcut) -> WorkspaceSidebarSavedApp? {
    if let document = shortcut.document {
        let path = pinDocumentAppURL(document.bundleId)?.path
        return WorkspaceSidebarSavedApp(bundleId: document.bundleId, bundlePath: path,
            name: savedWorkspaceAppDisplayName(bundleId: document.bundleId, appName: nil, bundlePath: path))
    }
    return shortcut.link.flatMap(workspaceSidebarPinLinkApp)
}

// MARK: - Active: a window proven to show it, in front

/// The front window, read for the document shortcuts it proves: which ones it shows, by identity.
@MainActor private var resourceShortcutFrontReading: (windowId: UInt32, shortcutIds: Set<String>, at: TimeInterval)?

@MainActor
func resetResourceShortcutReadingsForTests() {
    resourceShortcutFrontReading = nil
    resourceShortcutsOpening = []
}

@MainActor
func workspaceSidebarResourceShortcutIsActive(_ shortcut: WorkspaceSidebarResourceShortcut) -> Bool {
    guard shortcut.document != nil, let reading = resourceShortcutFrontReading,
          focus.windowOrNil?.windowId == reading.windowId,
          workspaceSidebarPinHomeNow() - reading.at <= workspaceSidebarPinHomeReadingFreshness
    else { return false }
    return reading.shortcutIds.contains(shortcut.id)
}

/// Reads the front window's file, if a document shortcut is for its app, and returns whether which
/// shortcuts it proves changed.
@MainActor
@discardableResult
func refreshResourceShortcutFrontReading() async -> Bool {
    let shortcuts = (workspaceSidebarOrganizationStore.state.resourceShortcuts ?? []).filter { $0.document != nil && $0.isReadable }
    guard let window = focus.windowOrNil, let bundleId = window.app.rawAppBundleId,
          shortcuts.contains(where: { $0.document?.bundleId == bundleId })
    else {
        let changed = resourceShortcutFrontReading != nil
        resourceShortcutFrontReading = nil
        return changed
    }
    let shown = PinDocumentIdentity(axDocument: await pinDocumentAXDocument(window))
    var ids: Set<String> = []
    if let shown {
        for shortcut in shortcuts {
            guard let document = shortcut.document, document.bundleId == bundleId,
                  let url = resolvePinDocument(document).url, PinDocumentIdentity(fileURL: url) == shown else { continue }
            ids.insert(shortcut.id)
        }
    }
    let changed = resourceShortcutFrontReading?.shortcutIds != ids || resourceShortcutFrontReading?.windowId != window.windowId
    resourceShortcutFrontReading = (window.windowId, ids, workspaceSidebarPinHomeNow())
    return changed
}

// MARK: - Adding

/// Where a new shortcut's resource comes from.
enum WorkspaceSidebarResourceShortcutSource: Equatable {
    /// The file the tab's one window shows.
    case document
    /// The page or message the tab's one window shows, read by WinMux's adapter for its app.
    case window
    /// What the tab's one window shows, read by the user's integration for its app.
    case integration(String)
    /// A link typed or pasted.
    case link
}

/// Adds a shortcut, among the pins of `projectId`, to a resource taken from the tab `name`, or typed. The
/// tab and its window are left as they are.
@MainActor
func addResourceShortcutFromSidebar(_ name: String, source: WorkspaceSidebarResourceShortcutSource, projectId: WorkspaceProjectId? = nil) {
    guard let tab = Workspace.existing(byName: name) else { return }
    let projectId = projectId ?? tab.projectId
    let title = "Add Shortcut"
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice(title, reason) }
    if source == .link {
        guard let link = askForPinLink("Add Link Shortcut", confirm: "Add", previous: nil) else { return }
        return commitResourceShortcutWrite(.link(link), projectId: projectId, title: title)
    }
    let window: Window
    switch pinDocumentSourceWindow(tab) {
        case .success(let source): window = source
        case .failure(.noWindow): return showPinDocumentNotice(title, "Open it in this tab first.")
        case .failure: return showPinDocumentNotice(title, "A shortcut is taken from a tab with one window, not from a pinned split.")
    }
    _ = Task { @MainActor in
        let captured: Result<WorkspaceSidebarPinResource, LinkIntegrationRefusal>
        switch source {
            case .document:
                switch await capturePinDocument(from: window) {
                    case .captured(let document): captured = .success(.file(document))
                    case .refused(let why): captured = .failure(.init(why))
                }
            case .window:
                guard let adapter = pinLinkAdapter(forBundleId: window.app.rawAppBundleId),
                      let bundleId = window.app.rawAppBundleId else {
                    return showPinDocumentNotice(title, "WinMux can't take a link from this window. Use Add Shortcut → Link… to type or paste one.")
                }
                switch await adapter.capture(window) {
                    case .captured(let url, let pageTitle):
                        captured = .success(.link(WorkspaceSidebarPinLink(url: url, title: pageTitle, adapter: adapter.id,
                            bundleId: bundleId, source: .window)))
                    case .refused(let why): captured = .failure(.init(why))
                }
            case .integration(let id):
                guard let integration = linkIntegrationStore.integration(id: id) else {
                    return showPinDocumentNotice(title, "That integration is gone.")
                }
                let state = linkIntegrationMenuState(integration)
                guard state.enabled else { return showPinDocumentNotice(title, state.help) }
                guard window.app.rawAppBundleId == integration.bundleId else {
                    return showPinDocumentNotice(title, "This tab's window isn't \(integration.appName)'s.")
                }
                let isStillWanted: @MainActor () -> Bool = {
                    pinDocumentStillSource(tab, window)
                        && linkIntegrationStore.integration(id: integration.id).map { $0.isActive && $0.digest == integration.digest } == true
                }
                switch await captureWithLinkIntegration(integration, window: window, isStillWanted: isStillWanted) {
                    case .captured(let resource): captured = .success(resource)
                    case .refused(let why): captured = .failure(.init(why))
                }
            case .link:
                return
        }
        // What was read is the window's only while it's still the tab's one window.
        guard pinDocumentStillSource(tab, window) else { return showPinDocumentNotice(title, pinDocumentChangedMessage) }
        switch captured {
            case .failure(let refusal): showPinDocumentNotice(title, refusal.message)
            case .success(let resource): commitResourceShortcutWrite(resource, projectId: projectId, title: title)
        }
    }
}

/// Add Shortcut to Home: a shortcut to a pin's home, beside the pin, which stays as it is.
@MainActor
func addResourceShortcutToPinHomeFromSidebar(_ name: String) {
    guard let tab = Workspace.existing(byName: name),
          let appearance = workspaceSidebarOrganizationStore.state.workspaces[name], appearance.isFavorite,
          let home = appearance.resource
    else { return }
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice("Add Shortcut", reason) }
    commitResourceShortcutWrite(home, projectId: tab.projectId,
        pinScope: appearance.isPinnedInAllProjects ? .allProjects : nil, title: "Add Shortcut")
}

/// The write, in its own session: a shortcut to `resource` among the pins, unless one to it is there already.
@MainActor
func commitResourceShortcutWrite(_ resource: WorkspaceSidebarPinResource, projectId: WorkspaceProjectId,
                                 pinScope: WorkspaceSidebarPinScope? = nil, title: String) {
    runPinDocumentWrite(title) {
        let shortcut = WorkspaceSidebarResourceShortcut(projectId: projectId, resource: resource, pinScope: pinScope)
        let existing = workspaceSidebarOrganizationStore.state.resourceShortcuts ?? []
        if existing.contains(where: {
            $0.resource.map { resourceShortcutSameResource($0, resource) } == true && $0.pinScope == pinScope
                && (pinScope != nil || $0.projectId == projectId)
        }) {
            return "There's already a shortcut to “\(shortcut.name)” here."
        }
        return commitWorkspaceSidebarResourceShortcuts(title: title) { shortcuts in shortcuts.append(shortcut) }
    }
}

/// The same resource: a file by its identity and app, whatever its bookmark's bytes; an address exactly, with
/// the app and integration that open it.
func resourceShortcutSameResource(_ a: WorkspaceSidebarPinResource, _ b: WorkspaceSidebarPinResource) -> Bool {
    switch (a, b) {
        case (.file(let x), .file(let y)):
            x.bundleId == y.bundleId && x.fileId != nil && x.fileId == y.fileId && x.volume == y.volume
        case (.link(let x), .link(let y)):
            x.url == y.url && x.bundleId == y.bundleId && x.integration == y.integration
        default: false
    }
}

/// Changes the shortcuts in one write, with Undo. Returns the failure's message.
@MainActor
func commitWorkspaceSidebarResourceShortcuts(title: String, _ change: (inout [WorkspaceSidebarResourceShortcut]) -> Void) -> String? {
    let undoBefore = WorkspaceSidebarTabUndoSnapshot()
    do {
        try workspaceSidebarOrganizationStore.update { state in
            var shortcuts = state.resourceShortcuts ?? []
            change(&shortcuts)
            state.resourceShortcuts = shortcuts.isEmpty ? nil : shortcuts
        }
    } catch {
        return "Couldn't \(title.lowercased()): \(error.localizedDescription)"
    }
    WorkspaceSidebarTabUndo.shared.recordOrganizationEdit(title, before: undoBefore, after: WorkspaceSidebarTabUndoSnapshot(),
        identities: WorkspaceSidebarOrganizationIdentityDelta())
    return nil
}

@MainActor
func removeResourceShortcutFromSidebar(_ id: String) {
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice("Remove Shortcut", reason) }
    runPinDocumentWrite("Remove Shortcut") {
        guard workspaceSidebarOrganizationStore.state.resourceShortcuts?.contains(where: { $0.id == id }) == true else { return nil }
        return commitWorkspaceSidebarResourceShortcuts(title: "Remove Shortcut") { $0.removeAll { $0.id == id } }
    }
}

/// Shows the shortcut among every project's pins, or only among `projectId`'s.
@MainActor
func setResourceShortcutScopeFromSidebar(_ id: String, allProjects: Bool, projectId: WorkspaceProjectId) {
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice("Shortcut", reason) }
    runPinDocumentWrite("Move Shortcut") {
        let shortcuts = workspaceSidebarOrganizationStore.state.resourceShortcuts ?? []
        guard let moving = shortcuts.first(where: { $0.id == id }), let resource = moving.resource else { return nil }
        // One shortcut to a resource in a place: none moves where there's one already.
        let scope: WorkspaceSidebarPinScope? = allProjects ? .allProjects : nil
        if shortcuts.contains(where: {
            $0.id != id && $0.resource.map { resourceShortcutSameResource($0, resource) } == true && $0.pinScope == scope
                && (allProjects || $0.projectId == projectId)
        }) {
            return "There's already a shortcut to “\(moving.name)” there."
        }
        return commitWorkspaceSidebarResourceShortcuts(title: allProjects ? "Show Shortcut in All Projects" : "Show Shortcut in One Project") {
            guard let index = $0.firstIndex(where: { $0.id == id }) else { return }
            $0[index].pinScope = allProjects ? .allProjects : nil
            if !allProjects { $0[index].projectId = projectId }
        }
    }
}

/// Edit Link… for a link shortcut: the address typed or pasted becomes its own.
@MainActor
func editResourceShortcutLinkFromSidebar(_ id: String) {
    guard let shortcut = workspaceSidebarOrganizationStore.state.resourceShortcuts?.first(where: { $0.id == id }),
          let previous = shortcut.link else { return }
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice("Edit Link", reason) }
    guard let link = askForPinLink("Edit Link Shortcut", confirm: "Save", previous: previous), link != previous else { return }
    runPinDocumentWrite("Edit Link") {
        commitWorkspaceSidebarResourceShortcuts(title: "Edit Link") {
            guard let index = $0.firstIndex(where: { $0.id == id }) else { return }
            $0[index].resource = .link(link)
        }
    }
}

// MARK: - Going to it

/// Shortcuts being opened: another click on one does nothing until its open has ended, so nothing opens twice.
@MainActor private(set) var resourceShortcutsOpening: Set<String> = []

/// Go to the shortcut's resource. A window proven to show it (only a file's, by identity) is shown, as a
/// click on a tab with it shows it, on its display or brought here as WinMux's settings say; with
/// `bringHere`, ⌘-click, brought here. With no such window, it's opened, as a launcher opens it, wherever
/// its app puts it: ⌘-click then only says there's no window to bring.
@MainActor
func goToResourceShortcutFromSidebar(_ id: String, bringHere: Bool, targetMonitorScopeId: String?) {
    let title = "Shortcut"
    guard let shortcut = workspaceSidebarOrganizationStore.state.resourceShortcuts?.first(where: { $0.id == id }) else { return }
    guard !serverArgs.isReadOnly else { return showPinDocumentNotice(title, "WinMux is running with --read-only.") }
    guard shortcut.isReadable else {
        return showPinDocumentNotice(title, shortcut.version > WorkspaceSidebarResourceShortcut.currentVersion
            ? "A newer WinMux made this shortcut. Update WinMux to use it." : "This shortcut is damaged. Remove it and add it again.")
    }
    guard !resourceShortcutsOpening.contains(id) else { return }
    if let document = shortcut.document {
        let resolution = resolvePinDocument(document)
        guard let url = resolution.url, let identity = PinDocumentIdentity(fileURL: url) else {
            return showPinDocumentNotice(title, (resolution.url == nil ? resolution : .missing).message(document.name, forShortcut: true))
        }
        guard let appURL = pinDocumentAppURL(document.bundleId) else {
            return showPinDocumentNotice(title, "The app that showed “\(document.name)” isn't installed.")
        }
        resourceShortcutsOpening.insert(id)
        let focusGeneration = focusChangeGeneration
        _ = Task { @MainActor in
            defer { resourceShortcutsOpening.remove(id) }
            if let window = await windowShowingPinDocument(identity, bundleId: document.bundleId) {
                return showResourceShortcutWindow(window, bringHere: bringHere, targetMonitorScopeId: targetMonitorScopeId,
                    focusGeneration: focusGeneration)
            }
            if bringHere {
                return showPinDocumentNotice(title, "No window shows “\(document.name)”, so there's none to bring here. Click the shortcut to open it.")
            }
            // Found again right before the app is asked: only that same file.
            guard let fresh = resolvePinDocument(document).url, PinDocumentIdentity(fileURL: fresh) == identity else {
                return showPinDocumentNotice(title, PinDocumentResolution.missing.message(document.name, forShortcut: true))
            }
            do {
                try await openResourceShortcutFile(fresh, appURL)
            } catch {
                showPinDocumentNotice(title, "Couldn't open “\(document.name)”: \(error.localizedDescription)")
            }
        }
        return
    }
    guard let link = shortcut.link, let url = URL(string: link.url) else { return }
    if bringHere {
        return showPinDocumentNotice(title, "WinMux can't tell which window shows “\(link.title)”, so it can't bring one here. "
            + "Click the shortcut to open it.")
    }
    // The same choice of app as a pin's link, by its integration or its app, but always as a launcher opens it:
    // a page too goes to a window or tab of the browser's choosing, which nothing claims.
    let opening: PinLinkOpening
    switch pinLinkOpening(link, forShortcut: true) {
        case .success(let how): opening = how
        case .failure(let refusal): return showPinDocumentNotice(title, refusal.message)
    }
    resourceShortcutsOpening.insert(id)
    _ = Task { @MainActor in
        defer { resourceShortcutsOpening.remove(id) }
        switch opening {
            case .integration(let integration):
                await runResourceShortcutOpenItem(integration, link: link, title: title)
            case .launcher(let appURL), .managedWindow(_, let appURL), .newBrowserWindow(_, let appURL):
                do {
                    try await openPinLinkURL(url, appURL)
                } catch {
                    showPinDocumentNotice(title, "Couldn't open “\(link.title)”: \(error.localizedDescription)")
                }
        }
    }
}

/// The integration's Open Item for a shortcut's link: only the scripts the user trusted, as they were when
/// the shortcut was clicked, and once. A script that took too long may have run, so it's never run again
/// on its own.
@MainActor
private func runResourceShortcutOpenItem(_ integration: LinkIntegration, link: WorkspaceSidebarPinLink, title: String) async {
    guard let openItem = integration.openItem, let current = linkIntegrationStore.integration(id: integration.id),
          current.isActive, current.digest == integration.digest else { return }
    switch await runHookmarkScript(openItem, HookmarkPlaceholderValues(address: link.url, appName: integration.appName)) {
        case .success: break
        case .notAuthorized:
            showPinDocumentNotice(title,
                "Allow WinMux to control \(integration.appName) in System Settings → Privacy & Security → Automation to open this shortcut.")
        case .failed(let message):
            showPinDocumentNotice(title, "\(integration.appName)'s Open Item script failed: \(message)")
        case .timedOut:
            showPinDocumentNotice(title, "\(integration.appName)'s Open Item script didn't finish within \(Int(hookmarkScriptTimeout)) "
                + "seconds. It may still have opened it, so WinMux doesn't run it again.")
    }
}

/// A window proven to show a shortcut's resource, shown as clicking its tab shows it, once the user
/// hasn't moved on meanwhile and it's still that window. A shared pin's window follows WinMux's setting
/// for such clicks, or comes here with ⌘-click. Any other is shown where it is; with ⌘-click, its tab
/// comes here unless it's shown on another display, where it's then shown. The pointer stays put.
@MainActor
func showResourceShortcutWindow(_ window: Window, bringHere: Bool, targetMonitorScopeId: String?, focusGeneration: UInt64) {
    let isStillWanted: @MainActor () -> Bool = {
        focusChangeGeneration == focusGeneration && Window.get(byId: window.windowId) === window && window.isBound
    }
    if let pin = workspaceSidebarSharedPinClicked(windowId: window.windowId, targetMonitorScopeId: targetMonitorScopeId) {
        showSharedPinnedTabFromSidebar(pin, windowId: window.windowId, targetMonitorScopeId: targetMonitorScopeId,
            click: bringHere ? .command : .plain, proceeds: isStillWanted)
        return
    }
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    runWorkspaceSidebarSession {
        guard isStillWanted() else { return }
        let shown = bringHere && focusWindowFromSidebar(window, targetMonitorScopeId: targetMonitorScopeId)
            || focusWindowFromSidebar(window, targetMonitorScopeId: nil)
        if shown { noteFocusKeepsPointer() }
    }
}
