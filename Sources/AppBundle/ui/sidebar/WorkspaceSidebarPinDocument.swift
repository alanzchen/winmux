import AppKit
import Common

// Pin Document (Tabs mode): a pin that keeps the file its one window showed and, clicked with no
// window, opens that file again in the same app, taking only the window proven to show it.
//
// A file is the same file only by its file-resource identity on its volume, read fresh, never by
// its path, its name, or because a window is the only new one. The pin stores a bookmark, which
// follows the file when it's renamed or moved on its disk, with the file's number and volume to
// check what the bookmark finds. A file replaced at the same path, as a safe save does, is another
// file: the pin then says it can't find its document, unless its own window, still showing that
// path, was seen with it, which is the document saved.

/// A file as the system tells files apart now: its resource and its volume, read fresh. Valid only
/// until restart, so it's never stored.
struct PinDocumentIdentity: Equatable {
    let resource: NSObject
    let volume: NSObject

    init?(fileURL url: URL) {
        guard url.isFileURL else { return nil }
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let resource = values.fileResourceIdentifier as? NSObject,
              let volume = values.volumeIdentifier as? NSObject
        else { return nil }
        self.resource = resource
        self.volume = volume
    }

    /// The file a window's AXDocument names, if it's a file that exists.
    init?(axDocument: String?) {
        guard let url = pinDocumentFileURL(axDocument) else { return nil }
        self.init(fileURL: url)
    }

    static func == (a: Self, b: Self) -> Bool { a.resource.isEqual(b.resource) && a.volume.isEqual(b.volume) }
}

/// The file an AXDocument names: a file URL whose file exists. A browser's page, or nothing, isn't one.
func pinDocumentFileURL(_ axDocument: String?) -> URL? {
    guard let axDocument, let url = URL(string: axDocument), url.isFileURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url.standardizedFileURL
}

/// A pinned document's file, found by its bookmark and checked: the same file number on the same
/// volume as when it was pinned. `isStale` once it was renamed or moved, for a fresh bookmark.
struct ResolvedPinDocument {
    let url: URL
    let isStale: Bool
}

/// Nil for a file deleted, on a disk that isn't mounted, or replaced, safe saves included.
func resolvePinDocument(_ document: WorkspaceSidebarPinDocument) -> ResolvedPinDocument? {
    var isStale = false
    guard let url = try? URL(resolvingBookmarkData: document.bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &isStale),
          FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    if let fileId = document.fileId, let volume = document.volume {
        let found = pinDocumentFileNumber(url)
        guard found.fileId == fileId, found.volume == volume else { return nil }
    }
    return ResolvedPinDocument(url: url.standardizedFileURL, isStale: isStale)
}

/// A file's number on its volume and that volume's UUID, read fresh; nil where the file system has none.
func pinDocumentFileNumber(_ url: URL) -> (fileId: UInt64?, volume: String?) {
    let fileId = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    var fresh = URL(fileURLWithPath: url.path)
    fresh.removeAllCachedResourceValues()
    return (fileId, try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
}

/// What a pin keeps of the file at `url` for the app `bundleId`. Nil when no bookmark can be made.
func makeWorkspaceSidebarPinDocument(_ url: URL, bundleId: String) -> WorkspaceSidebarPinDocument? {
    guard let bookmark = try? url.bookmarkData(options: [.withoutImplicitSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
    let number = pinDocumentFileNumber(url)
    return WorkspaceSidebarPinDocument(bookmark: bookmark, bundleId: bundleId, name: url.lastPathComponent,
        fileId: number.fileId, volume: number.volume)
}

// MARK: - Seams

/// A window's AXDocument, as its app reports it. Replaceable for tests.
@MainActor
var pinDocumentAXDocument: @MainActor (Window) async -> String? = { window in
    guard let window = window as? MacWindow else { return nil }
    return try? await window.macApp.getAxDocument(window.windowId)
}

/// The windows of an app that might already show a pinned document. Replaceable for tests.
@MainActor
var pinDocumentCandidateWindows: @MainActor (String) -> [Window] = { bundleId in
    MacWindow.allWindows.filter { $0.app.rawAppBundleId == bundleId }
}

/// The installed app for a bundle id. Replaceable for tests.
@MainActor
var pinDocumentAppURL: @MainActor (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

/// Opens `file` in the app at `app`, without activating it, as a pin reopen does; returns the pid of
/// the app it reached. Replaceable for tests.
@MainActor
var openPinDocumentFile: @MainActor (URL, URL) async throws -> Int32 = { file, app in
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    return try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration).processIdentifier
}

/// At most this many of an app's windows are read when looking for one that already shows a document.
let pinDocumentScanLimit = 24

@MainActor
func showPinDocumentNotice(_ title: String, _ body: String) {
    showWorkspaceSidebarNotice(.init(title: title, body: body, details: Message(description: title, body: body)))
}

// MARK: - Which tabs

@MainActor
func workspaceIsPinnedDocument(_ workspace: Workspace) -> Bool { workspaceIsPinnedDocument(named: workspace.name) }

@MainActor
func workspaceIsPinnedDocument(named name: String) -> Bool {
    workspaceSidebarOrganizationStore.state.workspaces[name].map { $0.isFavorite && $0.document != nil } == true
}

/// The window a tab's document is taken from: its only window, in a tab that isn't a pinned split.
@MainActor
func pinDocumentSourceWindow(_ tab: Workspace) -> Result<Window, PinDocumentRefusal> {
    if workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.composition != nil { return .failure(.split) }
    let windows = tab.allLeafWindowsRecursive
    if windows.isEmpty { return .failure(.noWindow) }
    guard windows.count == 1, let window = windows.first else { return .failure(.severalWindows) }
    return .success(window)
}

enum PinDocumentRefusal: Error, Equatable {
    case noWindow, severalWindows, split

    var message: String {
        switch self {
            case .noWindow: "Open the document in this tab first."
            case .severalWindows: "Pin Document works on a tab with one window."
            case .split: "A pinned split can't be a pinned document."
        }
    }
}

/// Tabs mode: the identity menu's document items for a tab. Pin Document for a tab, or a pin, that
/// has none; Update Document from Window and Forget Document for a pinned document.
@MainActor
func workspaceSidebarPinDocumentMenuEntries(_ workspace: WorkspaceSidebarWorkspaceViewModel,
                                            send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> [WorkspaceSidebarAppMenuEntry] {
    let name = workspace.name
    let windows = workspaceSidebarPinnedTabWindows(workspace)
    let refusal: PinDocumentRefusal? = workspace.appearance.composition != nil ? .split
        : windows.isEmpty ? .noWindow : windows.count > 1 ? .severalWindows : nil
    guard workspace.appearance.isFavorite, let document = workspace.appearance.document else {
        return [.init(title: "Pin Document", enabled: refusal == nil, perform: { send(.pinDocument(name)) },
            help: refusal?.message ?? "Pins this tab to the file its window shows")]
    }
    return [
        .init(title: "Update Document from Window", enabled: refusal == nil, perform: { send(.updatePinDocument(name)) },
            help: refusal?.message ?? "Pins this tab to the file its window shows now, instead of “\(document.name)”"),
        .init(title: "Forget Document", perform: { send(.forgetPinDocument(name)) }),
    ]
}

// MARK: - Pin, update, forget

enum PinDocumentCapture {
    case captured(WorkspaceSidebarPinDocument, path: String)
    case refused(String)
}

/// The document `window` shows, as its app reports it: a saved file it has, never a page or nothing.
@MainActor
func capturePinDocument(from window: Window) async -> PinDocumentCapture {
    let appName = window.app.name ?? "The app"
    guard let bundleId = window.app.rawAppBundleId else { return .refused("WinMux doesn't know which app shows this window.") }
    guard let axDocument = await pinDocumentAXDocument(window) else {
        return .refused("\(appName) doesn't report a file for this window. Save the document first, or use Pin Tab.")
    }
    guard let url = URL(string: axDocument), url.isFileURL else {
        return .refused("This window doesn't show a file, so it can't be a pinned document. Use Pin Tab.")
    }
    guard let fileURL = pinDocumentFileURL(axDocument) else {
        return .refused("The file this window shows isn't on disk. Save it, then try again.")
    }
    guard let document = makeWorkspaceSidebarPinDocument(fileURL, bundleId: bundleId) else {
        return .refused("WinMux couldn't keep a link to “\(fileURL.lastPathComponent)”.")
    }
    return .captured(document, path: fileURL.path)
}

/// Pin Document, or Update Document from Window with `updating`: the tab's one window's file, read
/// from the window itself, becomes the pin's document. All or nothing: a refusal, a tab or window
/// changed while the app answered, or a failed write leave the tab as it was.
@MainActor
func pinDocumentFromSidebar(_ name: String, updating: Bool) {
    guard !serverArgs.isReadOnly, let tab = Workspace.existing(byName: name) else { return }
    let title = updating ? "Update Document" : "Pin Document"
    let window: Window
    switch pinDocumentSourceWindow(tab) {
        case .success(let source): window = source
        case .failure(let refusal): return showPinDocumentNotice(title, refusal.message)
    }
    _ = Task { @MainActor in
        let capture = await capturePinDocument(from: window)
        let unchanged: Bool = {
            guard Workspace.existing(byName: name) === tab, case .success(let now) = pinDocumentSourceWindow(tab), now === window
            else { return false }
            return !updating || workspaceIsPinnedDocument(named: name)
        }()
        guard unchanged else {
            return showPinDocumentNotice(title, "“\(workspaceDisplayName(name))” changed while WinMux read its window. Nothing was changed.")
        }
        switch capture {
            case .refused(let why):
                showPinDocumentNotice(title, why)
            case .captured(let document, let path):
                runWorkspaceSidebarSession(undoTitle: title) {
                    try setWorkspaceSidebarPinDocument(tab, document)
                    notePinDocumentProof(name, window: window, path: path)
                    await updateWorkspaceSidebarModel()
                }
        }
    }
}

@MainActor
func forgetPinDocumentFromSidebar(_ name: String) {
    guard !serverArgs.isReadOnly else { return }
    runWorkspaceSidebarSession(undoTitle: "Forget Document") {
        guard let tab = Workspace.existing(byName: name) else { return }
        try setWorkspaceSidebarPinDocument(tab, nil)
        pinDocumentProofs[name] = nil
        await updateWorkspaceSidebarModel()
    }
}

/// Pins `tab` with `document`, or sets a pin's document, in one write: a failure leaves the tab as it
/// was. Nil forgets the document and keeps the pin.
@MainActor
func setWorkspaceSidebarPinDocument(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument?) throws {
    let store = workspaceSidebarOrganizationStore
    let pins = document != nil && store.state.workspaces[tab.name]?.isFavorite != true
    if pins { try saveWorkspaceSidebarIdentities([tab]) }
    try store.update { state in
        if pins {
            state.workspaces[tab.name, default: .init()].setFavorite(true)
            // A pinned tab leaves its group, as pinning always has.
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == tab.name } }
        }
        guard state.workspaces[tab.name]?.isFavorite == true else { return }
        state.workspaces[tab.name]?.document = document
    }
}

// MARK: - Reopen

/// A pinned document whose window is gone, clicked once the pin is shown, wherever the click put it:
/// its file opens again in its app, and only the window proven to show that file comes to the pin.
/// A window that already shows it is focused where it is, and the notice says where; nothing moves.
/// Nothing else opens instead: a file gone, replaced or on another disk, or an app gone, only says so.
@MainActor
func openPinnedDocument(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument) {
    let name = tab.name
    guard !serverArgs.isReadOnly else { return showPinDocumentNotice("Pinned Document", "WinMux is read-only.") }
    guard let resolved = resolvePinDocument(document), let identity = PinDocumentIdentity(fileURL: resolved.url) else {
        return showPinDocumentNotice("Pinned Document", "Can't find “\(document.name)”: it was deleted, replaced, or moved to another disk. "
            + "Open it in this tab and choose Update Document from Window, or choose Forget Document.")
    }
    guard let appURL = pinDocumentAppURL(document.bundleId) else {
        return showPinDocumentNotice("Pinned Document", "The app that showed “\(document.name)” isn't installed.")
    }
    let focusGeneration = focusChangeGeneration
    _ = Task { @MainActor in
        let stillAsked = {
            winMuxWorkspaceState.workspaceById[tab.id] === tab && !tab.isArchived
                && workspaceSidebarOrganizationStore.state.workspaces[name]?.document == document
        }
        if let open = await windowShowingPinDocument(identity, bundleId: document.bundleId) {
            guard stillAsked() else { return }
            return revealOpenPinDocument(open, for: tab, document: document, focusGeneration: focusGeneration)
        }
        guard stillAsked(), !workspaceHasLifecycleWindows(tab) else { return }
        await requestPinnedDocumentWindow(tab, document, url: resolved.url, identity: identity, appURL: appURL,
            focusGeneration: focusGeneration)
    }
}

/// The first of the app's windows WinMux knows that shows this very file.
@MainActor
func windowShowingPinDocument(_ identity: PinDocumentIdentity, bundleId: String) async -> Window? {
    for window in pinDocumentCandidateWindows(bundleId).prefix(pinDocumentScanLimit) {
        let document = await pinDocumentAXDocument(window)
        if window.isBound, PinDocumentIdentity(axDocument: document) == identity { return window }
    }
    return nil
}

/// The document is open in a window already: in the pin, it's simply focused; anywhere else, it stays
/// there, focused unless the user moved on meanwhile, and the notice says where.
@MainActor
private func revealOpenPinDocument(_ window: Window, for tab: Workspace, document: WorkspaceSidebarPinDocument,
                                   focusGeneration: UInt64) {
    let userIsHere = focusChangeGeneration == focusGeneration
    if window.nodeWorkspace === tab {
        if userIsHere { focusWindowFromSidebar(window.windowId) }
        return
    }
    if userIsHere { focusWindowFromSidebar(window.windowId) }
    let place = window.nodeWorkspace.map { "“\(workspaceDisplayName($0.name))”" } ?? "another window"
    showPinDocumentNotice("Pinned Document", "“\(document.name)” is already open in \(place). It stays there; "
        + "this pin opens it once that window is closed.")
}

@MainActor
private func requestPinnedDocumentWindow(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument, url: URL,
                                         identity: PinDocumentIdentity, appURL: URL, focusGeneration: UInt64) async {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: document.bundleId)
        .first { $0.activationPolicy == .regular && !$0.isTerminated }
    let pid = running?.processIdentifier
    let appName = running?.localizedName ?? appURL.deletingPathExtension().lastPathComponent
    let registry = NewWindowIntentRegistry.shared
    let name = tab.name
    guard let intent = registry.register(bundleId: document.bundleId, pid: pid, targetWorkspace: tab,
        preexistingWindowIds: pid.map(existingWindowIds(pid:)) ?? [], focusGeneration: focusGeneration,
        timeout: 2 * newWindowIntentTimeout, document: identity,
        completion: { outcome in
            finishPinnedDocumentRequest(outcome, pinName: name, document: document, url: url, identity: identity, appName: appName)
        })
    else {
        return showPinDocumentNotice("Pinned Document", "\(appName) is already opening a window. Try again in a moment.")
    }
    let intentId = intent.id
    registry.recordFocusWhenSent(forIntent: intentId, .current)
    _ = Task { @MainActor in await watchNewWindowIntentExpiry(intentId) }
    do {
        let reached = try await openPinDocumentFile(url, appURL)
        if reached != pid { registry.setPid(reached, forIntent: intentId) }
        registry.restartDeadline(forIntent: intentId)
    } catch {
        registry.cancel(intentId: intentId, outcome: .failed("\(appName) couldn't open “\(document.name)”: \(error.localizedDescription)"))
    }
}

@MainActor
private func finishPinnedDocumentRequest(_ outcome: NewWindowRequestOutcome, pinName: String, document: WorkspaceSidebarPinDocument,
                                         url: URL, identity: PinDocumentIdentity, appName: String) {
    switch outcome {
        case .placed(let windowId):
            guard let window = Window.get(byId: windowId) else { return }
            notePinDocumentProof(pinName, window: window, path: url.path)
            // Found renamed or moved: the bookmark is refreshed now that its window proved the file.
            if resolvePinDocument(document)?.isStale == true || document.name != url.lastPathComponent {
                storeRefreshedPinDocument(pinName, replacing: document, with: url)
            }
        case .timedOut:
            _ = Task { @MainActor in
                // The app may have shown it in a window that went elsewhere, its file reported late.
                if let open = await windowShowingPinDocument(identity, bundleId: document.bundleId), open.nodeWorkspace != nil {
                    let place = open.nodeWorkspace.map { "“\(workspaceDisplayName($0.name))”" } ?? "another window"
                    showPinDocumentNotice("Pinned Document", "\(appName) opened “\(document.name)” in \(place). It stays there.")
                } else {
                    showPinDocumentNotice("Pinned Document", "\(appName) didn't open “\(document.name)”.")
                }
            }
        case .failed(let reason):
            showPinDocumentNotice("Pinned Document", reason)
        case .cancelled, .opened:
            break
    }
}

// MARK: - Keeping the bookmark current

/// The pin's own window last seen showing its document, and that file's path: while that same window
/// shows that path, a file replaced there is the document saved, not another file.
@MainActor
final class PinDocumentProof {
    weak var window: Window?
    let path: String

    init(window: Window, path: String) {
        self.window = window
        self.path = path
    }
}

@MainActor
var pinDocumentProofs: [String: PinDocumentProof] = [:]

@MainActor
func notePinDocumentProof(_ name: String, window: Window, path: String) {
    pinDocumentProofs[name] = PinDocumentProof(window: window, path: URL(fileURLWithPath: path).standardizedFileURL.path)
}

/// Writes a fresh bookmark of `url`, if the pin still has `old`. A failed write keeps the old one.
@MainActor
private func storeRefreshedPinDocument(_ name: String, replacing old: WorkspaceSidebarPinDocument, with url: URL) {
    guard let fresh = makeWorkspaceSidebarPinDocument(url, bundleId: old.bundleId) else { return }
    try? workspaceSidebarOrganizationStore.update { state in
        guard state.workspaces[name]?.document == old else { return }
        state.workspaces[name]?.document = fresh
    }
}

/// A pinned document whose own window is open: its file renamed or moved gets a fresh bookmark, and a
/// file replaced at the path that same window still shows, as a save does, becomes the pinned file.
/// Anything else is left as it is: a window showing another file never changes what the pin opens.
@MainActor
func refreshPinDocument(_ name: String) async {
    guard let tab = Workspace.existing(byName: name),
          let document = workspaceSidebarOrganizationStore.state.workspaces[name].flatMap({ $0.isFavorite ? $0.document : nil }),
          case .success(let window) = pinDocumentSourceWindow(tab), window.app.rawAppBundleId == document.bundleId
    else { return }
    let axDocument = await pinDocumentAXDocument(window)
    guard let url = pinDocumentFileURL(axDocument), let shown = PinDocumentIdentity(fileURL: url),
          // Unchanged while the app answered.
          workspaceSidebarOrganizationStore.state.workspaces[name]?.document == document,
          case .success(let still) = pinDocumentSourceWindow(tab), still === window
    else { return }
    if let resolved = resolvePinDocument(document), PinDocumentIdentity(fileURL: resolved.url) == shown {
        notePinDocumentProof(name, window: window, path: url.path)
        if resolved.isStale || document.name != url.lastPathComponent { storeRefreshedPinDocument(name, replacing: document, with: url) }
        return
    }
    guard let proof = pinDocumentProofs[name], proof.window === window, proof.path == url.path else { return }
    storeRefreshedPinDocument(name, replacing: document, with: url)
}

@MainActor private var lastLivePinDocumentRefresh: TimeInterval = -.infinity
@MainActor private var isRefreshingLivePinDocuments = false

/// After the sidebar updates, at most every two seconds: the pinned documents whose own window is
/// open have their bookmarks kept current, one AX read each.
@MainActor
func refreshLivePinDocumentsIfDue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard !isUnitTest, !serverArgs.isReadOnly, !isRefreshingLivePinDocuments, now - lastLivePinDocumentRefresh >= 2 else { return }
    let names = workspaceSidebarOrganizationStore.state.workspaces.filter { $0.value.isFavorite && $0.value.document != nil }.keys
    guard !names.isEmpty else { return }
    lastLivePinDocumentRefresh = now
    isRefreshingLivePinDocuments = true
    _ = Task { @MainActor in
        defer { isRefreshingLivePinDocuments = false }
        for name in names.sorted() { await refreshPinDocument(name) }
    }
}
