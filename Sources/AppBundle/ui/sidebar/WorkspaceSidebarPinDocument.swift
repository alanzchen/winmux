import AppKit
import Common

// Pin Document (Tabs mode): a pin that keeps the file its one window showed and, clicked with no
// window, opens that file again in the same app, taking only the window proven to show it.
//
// A file is the same file only by its file-resource identity on its volume, read fresh, never by
// its path, its name, or because a window is the only new one. The pin stores a bookmark, which
// follows the file when it's renamed or moved on its disk, with the file's number and its volume to
// check what the bookmark finds; without both, nothing is opened. A file replaced at the same path,
// as a safe save does, is another file: the pin says it can't find its document until Update
// Document from Window pins the file again. Nothing adopts a replacement on its own.
//
// Everything that waits, for an app's answer or for a session's turn, was started for one state of
// the pin: a `PinDocumentTarget`. Any change to that pin since, Undo included, ends it without a
// write, a placement or a focus.

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

/// A file's number on its volume and that volume's UUID, read fresh; nil where the file system has none.
func pinDocumentFileNumber(_ url: URL) -> (fileId: UInt64?, volume: String?) {
    let fileId = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    var fresh = URL(fileURLWithPath: url.path)
    fresh.removeAllCachedResourceValues()
    return (fileId, try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
}

/// What a pinned document's bookmark finds now, checked against the file's number and volume.
enum PinDocumentResolution {
    /// The pinned file; `isStale` once it was renamed or moved, for a fresh bookmark.
    case found(URL, isStale: Bool)
    /// Deleted, replaced (a safe save included), or on a disk that isn't mounted.
    case missing
    /// No file number or volume to check it against, kept or readable now: it isn't opened.
    case unverifiable

    var url: URL? { if case .found(let url, _) = self { url } else { nil } }

    func message(_ name: String) -> String {
        switch self {
            case .found: ""
            case .missing:
                "Can't find “\(name)”: it was deleted, replaced, or moved to another disk. "
                    + "Open it in this tab and choose Update Document from Window, or choose Forget Document."
            case .unverifiable:
                "WinMux can't check that “\(name)” is still the same file, so it doesn't open it. "
                    + "Open it in this tab and choose Update Document from Window, or choose Forget Document."
        }
    }
}

func resolvePinDocument(_ document: WorkspaceSidebarPinDocument) -> PinDocumentResolution {
    guard let fileId = document.fileId, let volume = document.volume else { return .unverifiable }
    var isStale = false
    guard let url = try? URL(resolvingBookmarkData: document.bookmark, options: [.withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &isStale),
          FileManager.default.fileExists(atPath: url.path)
    else { return .missing }
    let found = pinDocumentFileNumber(url)
    guard let foundId = found.fileId, let foundVolume = found.volume else { return .unverifiable }
    guard foundId == fileId, foundVolume == volume else { return .missing }
    return .found(url.standardizedFileURL, isStale: isStale)
}

/// What a pin keeps of the file at `url` for the app `bundleId`. Nil when no bookmark can be made, or
/// the file has no number and volume to check it by later.
func makeWorkspaceSidebarPinDocument(_ url: URL, bundleId: String) -> WorkspaceSidebarPinDocument? {
    let number = pinDocumentFileNumber(url)
    guard let fileId = number.fileId, let volume = number.volume,
          let bookmark = try? url.bookmarkData(options: [.withoutImplicitSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
    return WorkspaceSidebarPinDocument(bookmark: bookmark, bundleId: bundleId, name: url.lastPathComponent,
        fileId: fileId, volume: volume)
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

/// Awaited at the start of a queued Pin, Update or Forget, before its last check. Tests hold it there.
@MainActor
var pinDocumentWillCommit: @MainActor () async -> Void = {}

/// Awaited at the start of the session that focuses a window already showing a pinned document,
/// before its last check. Tests hold it there.
@MainActor
var pinDocumentWillFocusOpenWindow: @MainActor () async -> Void = {}

/// Called between a new pin's saved identity write and its organization write. Tests fail one there.
@MainActor
var pinDocumentBeforeOrganizationWriteForTests: (@MainActor () -> Void)?

/// At most this many of an app's windows are read when looking for one that already shows a document.
let pinDocumentScanLimit = 24

@MainActor
func showPinDocumentNotice(_ title: String, _ body: String) {
    showWorkspaceSidebarNotice(.init(title: title, body: body, details: Message(description: title, body: body)))
}

let pinDocumentChangedMessage = "The tab changed while WinMux read its window. Nothing was changed."

// MARK: - Which pin, in which state

/// What a document or link operation or request was started for: a pin by name, that very workspace,
/// and its appearance's revision then. Any write to that appearance since, Undo included, another
/// workspace under the name, or another organization store, makes it stale.
@MainActor
struct PinDocumentTarget {
    let name: String
    weak var workspace: Workspace?
    let revision: UInt64
    let store: ObjectIdentifier

    init(_ workspace: Workspace) {
        name = workspace.name
        self.workspace = workspace
        revision = workspaceSidebarOrganizationStore.appearanceRevision(of: workspace.name)
        store = ObjectIdentifier(workspaceSidebarOrganizationStore)
    }

    var isCurrent: Bool {
        guard let workspace, ObjectIdentifier(workspaceSidebarOrganizationStore) == store,
              workspaceSidebarOrganizationStore.appearanceRevision(of: name) == revision,
              Workspace.existing(byName: name) === workspace,
              winMuxWorkspaceState.workspaceById[workspace.id] === workspace, !workspace.isArchived
        else { return false }
        return true
    }
}

/// The organization store changed these appearances: document requests made for an older state of
/// them are withdrawn, waiting or already claimed.
@MainActor
func workspaceSidebarAppearancesDidChange(_ names: Set<String>) {
    NewWindowIntentRegistry.shared.withdrawUnwantedIntents()
}

@MainActor
func workspaceIsPinnedDocument(_ workspace: Workspace) -> Bool { workspaceIsPinnedDocument(named: workspace.name) }

@MainActor
func workspaceIsPinnedDocument(named name: String) -> Bool {
    workspaceSidebarOrganizationStore.state.workspaces[name].map { $0.isFavorite && $0.document != nil } == true
}

/// A pin that opens its own resource, a file or an address: never any window of its app, so it's no
/// app's home, and saved routing sends it nothing.
@MainActor
func workspaceIsPinnedResource(_ workspace: Workspace) -> Bool { workspaceIsPinnedResource(named: workspace.name) }

@MainActor
func workspaceIsPinnedResource(named name: String) -> Bool {
    workspaceSidebarOrganizationStore.state.workspaces[name].map { $0.isFavorite && $0.resource != nil } == true
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

/// Whether `window` is still `tab`'s one window, and still the window WinMux knows by its number.
@MainActor
func pinDocumentStillSource(_ tab: Workspace, _ window: Window) -> Bool {
    guard case .success(let now) = pinDocumentSourceWindow(tab), now === window, window.isBound else { return false }
    return Window.get(byId: window.windowId) === window
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

/// Why nothing can be pinned now, if so: --read-only, or a store that can't be written.
@MainActor
func pinDocumentReadOnlyReason() -> String? {
    if serverArgs.isReadOnly { return "WinMux is running with --read-only." }
    return workspaceSidebarOrganizationStore.readOnlyReason ?? savedWorkspaceStore.readOnlyReason
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
    case captured(WorkspaceSidebarPinDocument)
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
    let number = pinDocumentFileNumber(fileURL)
    guard number.fileId != nil, number.volume != nil else {
        return .refused("WinMux can't tell “\(fileURL.lastPathComponent)” apart from other files on its disk, "
            + "so it can't pin it as a document. Use Pin Tab.")
    }
    guard let document = makeWorkspaceSidebarPinDocument(fileURL, bundleId: bundleId) else {
        return .refused("WinMux couldn't keep a link to “\(fileURL.lastPathComponent)”.")
    }
    return .captured(document)
}

@MainActor private var lastPinDocumentOperation: UInt64 = 0
/// The Pin or Update of each tab under way, of a document or a link: a newer one for the tab
/// supersedes it.
@MainActor private var pinDocumentOperations: [String: UInt64] = [:]

/// Starts a Pin or Update of the tab named `name`, superseding any under way.
@MainActor
func beginPinResourceOperation(_ name: String) -> UInt64 {
    lastPinDocumentOperation &+= 1
    pinDocumentOperations[name] = lastPinDocumentOperation
    return lastPinDocumentOperation
}

/// Whether `operation` is still the tab's newest Pin or Update.
@MainActor
func isNewestPinResourceOperation(_ name: String, _ operation: UInt64) -> Bool { pinDocumentOperations[name] == operation }

@MainActor
func endPinResourceOperation(_ name: String, _ operation: UInt64) { endPinDocumentOperation(name, operation) }

@MainActor
private func endPinDocumentOperation(_ name: String, _ operation: UInt64) {
    if pinDocumentOperations[name] == operation { pinDocumentOperations[name] = nil }
}

/// Pin Document, or Update Document from Window with `updating`: the tab's one window's file, read
/// from the window itself, becomes the pin's document. It was asked for one state of the tab: a newer
/// Pin or Update of it, or any change to it since (Pin, Unpin, Forget, Undo), ends it with nothing
/// written. The last check is made in the session that writes, right before the write.
@MainActor
func pinDocumentFromSidebar(_ name: String, updating: Bool) {
    let title = updating ? "Update Document" : "Pin Document"
    guard let tab = Workspace.existing(byName: name) else { return }
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice(title, reason) }
    if updating, !workspaceIsPinnedDocument(tab) { return }
    let window: Window
    switch pinDocumentSourceWindow(tab) {
        case .success(let source): window = source
        case .failure(let refusal): return showPinDocumentNotice(title, refusal.message)
    }
    let target = PinDocumentTarget(tab)
    let operation = beginPinResourceOperation(name)
    _ = Task { @MainActor in
        let capture = await capturePinDocument(from: window)
        // A newer Pin or Update of this tab took over: it reports.
        guard pinDocumentOperations[name] == operation else { return }
        guard target.isCurrent, pinDocumentStillSource(tab, window) else {
            endPinDocumentOperation(name, operation)
            return showPinDocumentNotice(title, pinDocumentChangedMessage)
        }
        switch capture {
            case .refused(let why):
                endPinDocumentOperation(name, operation)
                showPinDocumentNotice(title, why)
            case .captured(let document):
                runPinDocumentWrite(title) {
                    defer { endPinDocumentOperation(name, operation) }
                    guard pinDocumentOperations[name] == operation else { return nil }
                    guard target.isCurrent, pinDocumentStillSource(tab, window) else { return pinDocumentChangedMessage }
                    return commitWorkspaceSidebarPinDocument(tab, document, title: title)
                }
        }
    }
}

@MainActor
func forgetPinDocumentFromSidebar(_ name: String) {
    guard let tab = Workspace.existing(byName: name) else { return }
    if serverArgs.isReadOnly || workspaceSidebarOrganizationStore.readOnlyReason != nil {
        return showPinDocumentNotice("Forget Document", pinDocumentReadOnlyReason() ?? "")
    }
    let target = PinDocumentTarget(tab)
    runPinDocumentWrite("Forget Document") {
        guard target.isCurrent, workspaceIsPinnedDocument(tab) else { return nil }
        return commitWorkspaceSidebarPinDocument(tab, nil, title: "Forget Document")
    }
}

/// Runs `checkAndWrite` in its own session, once that session's turn comes: synchronous, so nothing
/// changes between its last check and its write. It returns what to tell the user, if anything.
@MainActor
func runPinDocumentWrite(_ title: String, _ checkAndWrite: @escaping @MainActor () -> String?) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    _ = Task { @MainActor in
        var message: String?
        do {
            try await runLightSession(.menuBarButton, token) {
                await pinDocumentWillCommit()
                message = checkAndWrite()
                if message == nil { await updateWorkspaceSidebarModel() }
            }
        } catch {
            message = message ?? error.localizedDescription
        }
        if let message { showPinDocumentNotice(title, message) }
    }
}

/// The write itself: pins `tab` with `document`, or sets or forgets a pin's document. A tab not saved
/// yet gets its saved identity first, written and confirmed, then the organization, in one write. If
/// that fails, the identity is taken back, in memory and on disk, and the message says so if even that
/// fails. Undo, recorded only on success, puts back exactly this. Returns the failure's message.
@MainActor
func commitWorkspaceSidebarPinDocument(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument?, title: String) -> String? {
    commitWorkspaceSidebarPinResource(tab, document.map(WorkspaceSidebarPinResource.file), title: title)
}

/// The same write for any resource: a file or an address replaces whatever the pin had; nil forgets it.
@MainActor
func commitWorkspaceSidebarPinResource(_ tab: Workspace, _ resource: WorkspaceSidebarPinResource?, title: String) -> String? {
    let store = workspaceSidebarOrganizationStore
    let isPinned = store.state.workspaces[tab.name]?.isFavorite == true
    let pins = resource != nil && !isPinned
    guard pins || isPinned else { return nil }
    let savedBefore = savedWorkspaceStore.file
    let runtimeBefore = SavedWorkspaceRuntimeIdentityState()
    let lifecycle = tab.lifecycle
    let undoBefore = WorkspaceSidebarTabUndoSnapshot()
    var identities = WorkspaceSidebarOrganizationIdentityDelta()
    do {
        if pins {
            let previous = savedWorkspaceStore.record(named: tab.name)
            let result = try ensureSavedWorkspaceRecord(tab, flush: false, keepWhenEmpty: true)
            if result.created {
                identities.created.append(.init(name: tab.name, workspace: tab, lifecycle: lifecycle))
            } else if previous?.keepWhenEmpty == false {
                identities.promoted.append(tab.name)
            }
            try savedWorkspaceStore.flushNowReportingFailure()
        }
        pinDocumentBeforeOrganizationWriteForTests?()
        try store.update { state in
            if pins {
                state.workspaces[tab.name, default: .init()].setFavorite(true)
                // A pinned tab leaves its group, as pinning always has.
                for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == tab.name } }
            }
            state.workspaces[tab.name]?.resource = resource
        }
    } catch {
        // Nothing has used the new identity yet: this is the same main-actor turn.
        savedWorkspaceStore.restoreForRollback(savedBefore)
        runtimeBefore.restore()
        tab.lifecycle = lifecycle
        var message = "Couldn't \(title.lowercased()): \(error.localizedDescription)"
        if pins {
            do { try savedWorkspaceStore.flushNowReportingFailure() } catch {
                message += " WinMux also couldn't remove the saved tab identity it had just added; it stays saved."
            }
        }
        return message
    }
    WorkspaceSidebarTabUndo.shared.recordOrganizationEdit(title, before: undoBefore, after: WorkspaceSidebarTabUndoSnapshot(),
        identities: identities)
    return nil
}

// MARK: - Reopen

/// A pinned document whose window is gone, clicked once the pin is shown, wherever the click put it:
/// its file opens again in its app, and only the window proven to show that file comes to the pin.
/// A window that already shows it is focused where it is, and the notice says where; nothing moves.
/// Nothing else opens instead: a file gone, replaced, unverifiable or on another disk, or an app gone,
/// only says so. A change to the pin while this waits, Undo included, withdraws it.
@MainActor
func openPinnedDocument(_ tab: Workspace, _ document: WorkspaceSidebarPinDocument) {
    guard !serverArgs.isReadOnly else { return showPinDocumentNotice("Pinned Document", "WinMux is running with --read-only.") }
    let resolution = resolvePinDocument(document)
    guard let url = resolution.url, let identity = PinDocumentIdentity(fileURL: url) else {
        return showPinDocumentNotice("Pinned Document", (resolution.url == nil ? resolution : .missing).message(document.name))
    }
    guard let appURL = pinDocumentAppURL(document.bundleId) else {
        return showPinDocumentNotice("Pinned Document", "The app that showed “\(document.name)” isn't installed.")
    }
    let target = PinDocumentTarget(tab)
    let focusGeneration = focusChangeGeneration
    _ = Task { @MainActor in
        if let open = await windowShowingPinDocument(identity, bundleId: document.bundleId) {
            guard target.isCurrent else { return }
            return revealOpenPinDocument(open, for: tab, target: target, document: document, focusGeneration: focusGeneration)
        }
        guard target.isCurrent, !workspaceHasLifecycleWindows(tab) else { return }
        // The file may have changed while the app's windows were read: found again, right before the
        // app is asked, and only that same file, wherever it is now.
        let fresh = resolvePinDocument(document)
        guard let freshURL = fresh.url, PinDocumentIdentity(fileURL: freshURL) == identity else {
            return showPinDocumentNotice("Pinned Document", (fresh.url == nil ? fresh : .missing).message(document.name))
        }
        await requestPinnedDocumentWindow(tab, target: target, document: document, url: freshURL, identity: identity,
            appURL: appURL, focusGeneration: focusGeneration)
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

/// The document is open in a window already. Anywhere but the pin, the notice says where, and it stays
/// there. It's focused, in a session of its own, only if then the pin is as it was, the user hasn't
/// moved on, and it's still that window, keeping the pointer where it is, as a pin's click does, for
/// that focus change only.
@MainActor
private func revealOpenPinDocument(_ window: Window, for tab: Workspace, target: PinDocumentTarget,
                                   document: WorkspaceSidebarPinDocument, focusGeneration: UInt64) {
    if window.nodeWorkspace !== tab {
        let place = window.nodeWorkspace.map { "“\(workspaceDisplayName($0.name))”" } ?? "another window"
        showPinDocumentNotice("Pinned Document", "“\(document.name)” is already open in \(place). It stays there; "
            + "this pin opens it once that window is closed.")
    }
    WorkspaceSidebarPanel.suppressEdgeTrapForWorkspaceActivation()
    runWorkspaceSidebarSession {
        await pinDocumentWillFocusOpenWindow()
        guard target.isCurrent, focusChangeGeneration == focusGeneration,
              Window.get(byId: window.windowId) === window, window.isBound else { return }
        focusWindowFromSidebarNow(window.windowId, targetMonitorScopeId: nil, keepsPointer: true)
    }
}

/// Registers the request for the file's window, then asks the app, with nothing awaited between the
/// last check of the file and the ask. The request stands only while the pin is as it was.
@MainActor
private func requestPinnedDocumentWindow(_ tab: Workspace, target: PinDocumentTarget, document: WorkspaceSidebarPinDocument,
                                         url: URL, identity: PinDocumentIdentity, appURL: URL, focusGeneration: UInt64) async {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: document.bundleId)
        .first { $0.activationPolicy == .regular && !$0.isTerminated }
    let pid = running?.processIdentifier
    let appName = running?.localizedName ?? appURL.deletingPathExtension().lastPathComponent
    let registry = NewWindowIntentRegistry.shared
    guard let intent = registry.register(bundleId: document.bundleId, pid: pid, targetWorkspace: tab,
        preexistingWindowIds: pid.map(existingWindowIds(pid:)) ?? [], focusGeneration: focusGeneration,
        timeout: 2 * newWindowIntentTimeout, document: identity,
        completion: { outcome in
            finishPinnedDocumentRequest(outcome, target: target, document: document, identity: identity, appName: appName)
        },
        isStillWanted: { target.isCurrent })
    else {
        return showPinDocumentNotice("Pinned Document", "\(appName) is already opening a window. Try again in a moment.")
    }
    let intentId = intent.id
    registry.recordFocusWhenSent(forIntent: intentId, .current)
    _ = Task { @MainActor in await watchNewWindowIntentExpiry(intentId) }
    do {
        let reached = try await openPinDocumentFile(url, appURL)
        // The pin changed while the app was asked: the request is withdrawn, if not already.
        guard target.isCurrent else { return registry.cancel(intentId: intentId) }
        if reached != pid { registry.setPid(reached, forIntent: intentId) }
        registry.restartDeadline(forIntent: intentId)
    } catch {
        registry.cancel(intentId: intentId,
            outcome: target.isCurrent ? .failed("\(appName) couldn't open “\(document.name)”: \(error.localizedDescription)") : .cancelled)
    }
}

@MainActor
private func finishPinnedDocumentRequest(_ outcome: NewWindowRequestOutcome, target: PinDocumentTarget,
                                         document: WorkspaceSidebarPinDocument, identity: PinDocumentIdentity, appName: String) {
    guard target.isCurrent else { return }
    switch outcome {
        case .placed:
            // Found renamed or moved: the same file, so its bookmark and name are brought up to date.
            refreshPinDocument(target.name)
        case .timedOut:
            _ = Task { @MainActor in
                // The app may have shown it in a window that went elsewhere, its file reported late.
                let open = await windowShowingPinDocument(identity, bundleId: document.bundleId)
                guard target.isCurrent else { return }
                if let open, let place = open.nodeWorkspace.map({ "“\(workspaceDisplayName($0.name))”" }) {
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

/// A pinned document's bookmark that finds its very file renamed or moved, checked by the file's
/// number and volume, is made fresh, with the file's new name. Nothing else changes the pinned file:
/// a file replaced at its path, even one its window shows, isn't adopted. Left alone while the pin's
/// window is being opened.
@MainActor
func refreshPinDocument(_ name: String) {
    guard let tab = Workspace.existing(byName: name),
          let document = workspaceSidebarOrganizationStore.state.workspaces[name].flatMap({ $0.isFavorite ? $0.document : nil }),
          !NewWindowIntentRegistry.shared.isWaitingForWindow(in: tab),
          case .found(let url, let isStale) = resolvePinDocument(document),
          isStale || document.name != url.lastPathComponent,
          let fresh = makeWorkspaceSidebarPinDocument(url, bundleId: document.bundleId),
          fresh.fileId == document.fileId, fresh.volume == document.volume
    else { return }
    try? workspaceSidebarOrganizationStore.update { state in
        guard state.workspaces[name]?.isFavorite == true, state.workspaces[name]?.document == document else { return }
        state.workspaces[name]?.document = fresh
    }
}

@MainActor private var lastLivePinDocumentRefresh: TimeInterval = -.infinity

/// After the sidebar updates, at most every two seconds: pinned documents' bookmarks are kept current.
@MainActor
func refreshLivePinDocumentsIfDue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard !isUnitTest, !serverArgs.isReadOnly, workspaceSidebarOrganizationStore.readOnlyReason == nil,
          now - lastLivePinDocumentRefresh >= 2 else { return }
    let names = workspaceSidebarOrganizationStore.state.workspaces.filter { $0.value.isFavorite && $0.value.document != nil }.keys
    guard !names.isEmpty else { return }
    lastLivePinDocumentRefresh = now
    for name in names.sorted() { refreshPinDocument(name) }
}
