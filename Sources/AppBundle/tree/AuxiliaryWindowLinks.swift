import Common
import Foundation

// Links between auxiliary windows and the windows they were opened from, kept for WinMux's next start in
// the same boot: an update or a quit doesn't make a dialog under a pin's window one of the pin's cells.
// Each is kept with the identity a pin keeps of a window it lends: the window's number, its process and
// that process's launch, and the boot. A link comes back only for that same window, still floating, in
// that same process, launched when it was, in that same boot, with its parent a window of that same
// process; nothing else is linked. A window moved to a tab of its own, or closed, is forgotten here as it
// is in memory, and one whose parent closed keeps no parent.

/// One link, as kept.
struct AuxiliaryWindowLinkRecord: Codable, Equatable {
    /// The auxiliary window, as a pin keeps a window it lends.
    var window: WorkspaceSidebarPinWindow
    var role: AuxiliaryWindowRole
    /// The window it was opened from, in the same process. Nil once that one closed.
    var parentWindowId: UInt32?
}

private struct AuxiliaryWindowLinksFile: Codable {
    var version = 1
    var links: [AuxiliaryWindowLinkRecord]

    init(links: [AuxiliaryWindowLinkRecord]) { self.links = links }

    /// A link this WinMux can't read is left out, not the rest with it.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        struct Lossy: Decodable {
            let link: AuxiliaryWindowLinkRecord?
            init(from decoder: Decoder) throws { link = try? AuxiliaryWindowLinkRecord(from: decoder) }
        }
        links = try values.decode([Lossy].self, forKey: .links).compactMap(\.link)
    }
}

/// Where the links are kept, beside the saved workspaces. Nil in unit tests unless a test sets it.
@MainActor var auxiliaryWindowLinksURL: @MainActor () -> URL? = {
    guard !isUnitTest, let saved = try? savedWorkspacesFileUrl() else { return nil }
    return saved.deletingLastPathComponent().appendingPathComponent("auxiliary-window-links.json")
}

/// How long after it's read at startup a link waits for its windows to be registered.
let auxiliaryWindowLinksRecoveryWindow: TimeInterval = 60

/// The uptime the wait is timed by. Replaceable for tests.
@MainActor var auxiliaryWindowLinksNow: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

/// Links read at startup and not recovered yet: their windows, or their parents, may not be registered yet.
@MainActor private(set) var pendingAuxiliaryWindowLinks: [AuxiliaryWindowLinkRecord] = []
@MainActor private var pendingAuxiliaryWindowLinksDeadline: TimeInterval = 0

/// Reads the links kept by WinMux's last run, before its windows are registered. Those of a process that's
/// gone, or of another boot, are left: their windows are gone too.
@MainActor
func loadAuxiliaryWindowLinksForStartup() {
    pendingAuxiliaryWindowLinks = []
    guard let url = auxiliaryWindowLinksURL(), let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(AuxiliaryWindowLinksFile.self, from: data), file.version == 1
    else { return }
    pendingAuxiliaryWindowLinks = file.links.filter { $0.window.mayStillBeOpen }
    pendingAuxiliaryWindowLinksDeadline = auxiliaryWindowLinksNow() + auxiliaryWindowLinksRecoveryWindow
}

/// After a refresh registered windows: each link read at startup whose window is that same window, still
/// floating and not linked since, is linked again, to its parent while that's a window of the same process.
/// A link whose parent isn't registered waits for it until the deadline, then keeps no parent, as when a
/// parent closes; one whose window isn't registered by then is dropped.
@MainActor
func recoverAuxiliaryWindowLinks() {
    guard !pendingAuxiliaryWindowLinks.isEmpty else { return }
    let isDue = auxiliaryWindowLinksNow() >= pendingAuxiliaryWindowLinksDeadline
    let registry = AuxiliaryWindowRegistry.shared
    var waiting: [AuxiliaryWindowLinkRecord] = []
    var restored = false
    for link in pendingAuxiliaryWindowLinks where link.window.mayStillBeOpen {
        guard let window = link.window.live else {
            if !isDue { waiting.append(link) }
            continue
        }
        // Only a floating window is listed under another, and one linked since keeps that link.
        guard window.isFloating, registry.role(of: window) == nil else { continue }
        let parent = link.parentWindowId.flatMap(Window.get(byId:)).flatMap { $0 !== window && $0.app.pid == window.app.pid ? $0 : nil }
        if link.parentWindowId != nil, parent == nil, !isDue {
            waiting.append(link)
            continue
        }
        registry.restore(window.windowId, pid: window.app.pid, role: link.role, parentWindowId: parent?.windowId)
        restored = true
    }
    // Written only when something changed: this runs after every refresh while links wait.
    guard restored || waiting != pendingAuxiliaryWindowLinks else { return }
    pendingAuxiliaryWindowLinks = waiting
    persistAuxiliaryWindowLinks()
}

/// A window moved to a tab of its own, or closed, before its link read at startup was recovered: it isn't.
/// Links waiting for it as their parent keep no parent. Returns whether anything changed.
@MainActor
@discardableResult
func discardPendingAuxiliaryWindowLink(windowId: UInt32, pid: Int32, asParent: Bool) -> Bool {
    let before = pendingAuxiliaryWindowLinks
    pendingAuxiliaryWindowLinks.removeAll { $0.window.windowId == windowId && $0.window.pid == pid }
    if asParent {
        for index in pendingAuxiliaryWindowLinks.indices
            where pendingAuxiliaryWindowLinks[index].parentWindowId == windowId && pendingAuxiliaryWindowLinks[index].window.pid == pid {
            pendingAuxiliaryWindowLinks[index].parentWindowId = nil
        }
    }
    return pendingAuxiliaryWindowLinks != before
}

/// Writes the links WinMux knows now, with those still waiting from startup. Best effort: a link not kept
/// is a window of its own after the next start, as before.
@MainActor
func persistAuxiliaryWindowLinks() {
    guard !serverArgs.isReadOnly, let url = auxiliaryWindowLinksURL() else { return }
    let known = AuxiliaryWindowRegistry.shared.entries.compactMap { windowId, entry -> AuxiliaryWindowLinkRecord? in
        guard let window = Window.get(byId: windowId), window.app.pid == entry.pid else { return nil }
        return AuxiliaryWindowLinkRecord(window: WorkspaceSidebarPinWindow(window), role: entry.role, parentWindowId: entry.parentWindowId)
    }.sorted { $0.window.windowId < $1.window.windowId }
    let links = known + pendingAuxiliaryWindowLinks
    do {
        guard !links.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder.winMuxDefault.encode(AuxiliaryWindowLinksFile(links: links))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    } catch {}
}
