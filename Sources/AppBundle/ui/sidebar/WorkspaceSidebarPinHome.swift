import AppKit
import Common

// Tabs mode: a pinned tab with a home, a file or an address it was pinned with. The tab keeps its
// window: clicking the pin shows that window, whatever it shows now. The home changes only when the
// user says so (Set Current … as Home, with Undo), and Return to Home opens it again, a separate
// action, never the pin's ordinary click.
//
// Whether the pin's window still shows its home is told only by what that very window says now, and
// only where that's exact: a file's identity, or the full address a browser's own window shows, read
// from it. Anything else (an app's item through a link or an integration, a private window, a window
// that can't be read, a pin with several windows) is unknown, and the pin shows no difference.

/// What a pin's own window was last read to show, compared with the pin's home.
enum WorkspaceSidebarPinHomeEvidence: Equatable {
    case showsHome
    /// Something else, by its name or title.
    case showsOther(String)
}

struct WorkspaceSidebarPinHomeReading: Equatable {
    /// The window read, the pin's one window then.
    let windowId: UInt32
    /// The home it was compared with.
    let home: WorkspaceSidebarPinResource
    let evidence: WorkspaceSidebarPinHomeEvidence?
    let at: TimeInterval
}

/// How long a reading counts as fresh.
let workspaceSidebarPinHomeReadingFreshness: TimeInterval = 30
/// How often a pin's window is read again, at most, as the sidebar updates.
let workspaceSidebarPinHomeReadInterval: TimeInterval = 1.5

@MainActor private(set) var workspaceSidebarPinHomeReadings: [String: WorkspaceSidebarPinHomeReading] = [:]
@MainActor private var workspaceSidebarPinHomeReadsInFlight: Set<String> = []

@MainActor
func resetWorkspaceSidebarPinHomeReadingsForTests() {
    workspaceSidebarPinHomeReadings = [:]
    workspaceSidebarPinHomeReadsInFlight = []
}

/// The uptime readings are timed by. Replaceable for tests.
@MainActor
var workspaceSidebarPinHomeNow: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

/// A pin's home, as its tile shows it: its name and, only on a fresh reading of the pin's one window
/// that says so, what that window shows instead.
struct WorkspaceSidebarPinHomeViewModel: Hashable {
    let homeName: String
    let showsInstead: String?
}

@MainActor
func workspaceSidebarPinHome(for workspace: Workspace) -> WorkspaceSidebarPinHomeViewModel? {
    guard let appearance = workspaceSidebarOrganizationStore.state.workspaces[workspace.name], appearance.isFavorite,
          let home = appearance.resource else { return nil }
    let homeName = switch home {
        case .file(let document): document.name
        case .link(let link): link.title
    }
    return WorkspaceSidebarPinHomeViewModel(homeName: homeName,
        showsInstead: workspaceSidebarPinHomeFreshEvidence(workspace, home: home).flatMap {
            if case .showsOther(let name) = $0 { name } else { nil }
        })
}

/// The pin's one window, if it has exactly one, as the reading needs it.
@MainActor
func workspaceSidebarPinHomeWindow(_ workspace: Workspace) -> Window? {
    let windows = workspace.allLeafWindowsRecursive
    return windows.count == 1 ? windows.first : nil
}

/// A reading of this pin's one window, against this home, taken lately: nil when there's none.
@MainActor
func workspaceSidebarPinHomeFreshEvidence(_ workspace: Workspace, home: WorkspaceSidebarPinResource) -> WorkspaceSidebarPinHomeEvidence? {
    guard let window = workspaceSidebarPinHomeWindow(workspace),
          let reading = workspaceSidebarPinHomeReadings[workspace.name],
          reading.windowId == window.windowId, reading.home == home,
          workspaceSidebarPinHomeNow() - reading.at <= workspaceSidebarPinHomeReadingFreshness
    else { return nil }
    return reading.evidence
}

/// What `window` shows, compared with `home`, by the only exact evidence there is: a file's identity
/// for a document, or the full address a browser's own window reports for a page in that browser.
/// Nil when it can't be told, or the window is private.
@MainActor
func readWorkspaceSidebarPinHomeEvidence(_ window: Window, home: WorkspaceSidebarPinResource) async -> WorkspaceSidebarPinHomeEvidence? {
    switch home {
        case .file(let document):
            guard window.app.rawAppBundleId == document.bundleId,
                  let homeURL = resolvePinDocument(document).url, let homeIdentity = PinDocumentIdentity(fileURL: homeURL),
                  let shown = pinDocumentFileURL(await pinDocumentAXDocument(window)),
                  let shownIdentity = PinDocumentIdentity(fileURL: shown)
            else { return nil }
            return shownIdentity == homeIdentity ? .showsHome : .showsOther(shown.lastPathComponent)
        case .link(let link):
            guard pinLinkIsWebAddress(link.url), let bundleId = link.bundleId, window.app.rawAppBundleId == bundleId,
                  BrowserTabAdapter(bundleId: bundleId) != nil,
                  let read = await pinPageWindowRead(window), read.privacy != .private, !read.showsSeveralPages,
                  let url = read.url
            else { return nil }
            if url == link.url { return .showsHome }
            // A page's title is said only from a window known not to be private: a Chromium window can't be
            // known so from what it shows, so it's only "another page".
            guard read.privacy == .normal else { return .showsOther("another page") }
            return .showsOther(pinPageDisplayTitle(read.title, appName: window.app.name) ?? URL(string: url)?.host ?? "another page")
    }
}

/// After the sidebar updates: each pin with a home and one window has that window read again, at most
/// every `workspaceSidebarPinHomeReadInterval`, and so does the front window for the document shortcuts
/// it may show. A reading that changes updates the sidebar once more.
@MainActor
func refreshWorkspaceSidebarPinHomeReadingsIfDue() {
    guard !isUnitTest else { return }
    _ = Task { @MainActor in
        let homes = await refreshWorkspaceSidebarPinHomeReadings()
        let shortcuts = await refreshResourceShortcutFrontReading()
        if homes || shortcuts { await updateWorkspaceSidebarModel() }
    }
}

/// Reads the windows due, and returns whether any reading changed what a tile shows.
@MainActor
@discardableResult
func refreshWorkspaceSidebarPinHomeReadings() async -> Bool {
    let now = workspaceSidebarPinHomeNow()
    var changed = false
    let names = Set(workspaceSidebarOrganizationStore.state.workspaces.filter { $0.value.isFavorite && $0.value.resource != nil }.keys)
    // Readings of pins gone, or with no home now, go.
    for name in workspaceSidebarPinHomeReadings.keys where !names.contains(name) {
        workspaceSidebarPinHomeReadings[name] = nil
    }
    for name in names.sorted() {
        guard let workspace = Workspace.existing(byName: name),
              let home = workspaceSidebarOrganizationStore.state.workspaces[name]?.resource,
              let window = workspaceSidebarPinHomeWindow(workspace),
              !workspaceSidebarPinHomeReadsInFlight.contains(name)
        else { continue }
        if let last = workspaceSidebarPinHomeReadings[name], last.windowId == window.windowId, last.home == home,
           now - last.at < workspaceSidebarPinHomeReadInterval { continue }
        workspaceSidebarPinHomeReadsInFlight.insert(name)
        let evidence = await readWorkspaceSidebarPinHomeEvidence(window, home: home)
        workspaceSidebarPinHomeReadsInFlight.remove(name)
        // The pin may have changed while its window was read: the reading is for what it was then.
        guard workspaceSidebarOrganizationStore.state.workspaces[name]?.resource == home else { continue }
        let previous = workspaceSidebarPinHomeReadings[name]
        workspaceSidebarPinHomeReadings[name] = .init(windowId: window.windowId, home: home, evidence: evidence,
            at: workspaceSidebarPinHomeNow())
        if previous?.evidence != evidence || previous?.windowId != window.windowId { changed = true }
    }
    return changed
}

// MARK: - Return to Home

/// Return to Home: the pin's home, again, without changing it or what the pin's window shows. A window
/// known to show it, the pin's own on a fresh reading or, for a file, any window found showing that
/// very file, is shown where it is. Otherwise the pin is shown and its home opened as clicking the pin
/// with no window would: a file or a page in a window that comes to the pin beside its others, which
/// stay; any other link by its app or its integration, in a window of the app's choosing. WinMux
/// closes and discards nothing; whatever the app does with what the window showed is the app's.
@MainActor
func returnPinToHomeFromSidebar(_ name: String) {
    guard let tab = Workspace.existing(byName: name),
          let appearance = workspaceSidebarOrganizationStore.state.workspaces[name], appearance.isFavorite,
          let home = appearance.resource
    else { return }
    if workspaceSidebarPinHomeFreshEvidence(tab, home: home) == .showsHome, let window = workspaceSidebarPinHomeWindow(tab) {
        return focusWindowFromSidebar(window.windowId)
    }
    switch home {
        case .file(let document):
            // A window showing the very file is found and shown wherever it is; otherwise it opens here.
            if !tab.isVisible { focusWorkspaceFromSidebar(name) }
            openPinnedDocument(tab, document, returningHome: true)
        case .link(let link):
            if !tab.isVisible { focusWorkspaceFromSidebar(name) }
            openPinnedLink(tab, link, returningHome: true)
    }
}
