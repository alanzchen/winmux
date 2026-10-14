import AppKit
import Common

/// What an auxiliary window is. Tabs mode keeps one floating in the tab of the window it was
/// opened from, listed under that window, instead of giving it a tab of its own.
enum AuxiliaryWindowRole: String, Equatable, Sendable {
    /// Mail's standalone message window: File > Open Message, or a double-click.
    case mailMessage
    /// Mail's New Message, Reply or Forward window.
    case mailCompose
    /// A window WinMux floats as a dialog.
    case dialog

    /// A draft or a message opened to read: gone once it's done, so a saved tab or pin never records it.
    var isEphemeral: Bool { self != .dialog }
}

/// Auxiliary windows WinMux has recognized, for as long as each window lives. The parent is only
/// where it came from: whether it's listed under it is `auxiliaryWindowParent(of:)`'s to say.
@MainActor
final class AuxiliaryWindowRegistry {
    static let shared = AuxiliaryWindowRegistry()

    struct Entry: Equatable {
        let pid: Int32
        let role: AuxiliaryWindowRole
        /// The window it was opened from. Nil once that one closed.
        var parentWindowId: UInt32?
    }

    private(set) var entries: [UInt32: Entry] = [:]

    func record(_ windowId: UInt32, pid: Int32, role: AuxiliaryWindowRole, parentWindowId: UInt32) {
        entries[windowId] = Entry(pid: pid, role: role, parentWindowId: parentWindowId)
    }

    func role(of window: Window) -> AuxiliaryWindowRole? { entry(of: window)?.role }

    func parentWindowId(of window: Window) -> UInt32? { entry(of: window)?.parentWindowId }

    /// The user made it a window of its own on purpose, by moving it to a tab of its own: from then on
    /// it's an ordinary window, never listed under its parent again, and saved as any other.
    func detach(_ window: Window) {
        guard entry(of: window) != nil else { return }
        entries.removeValue(forKey: window.windowId)
    }

    /// A window closed. Windows opened from it stay open and keep their role, with no parent.
    func forget(windowId: UInt32, pid: Int32) {
        if entries[windowId]?.pid == pid { entries.removeValue(forKey: windowId) }
        for (id, entry) in entries where entry.parentWindowId == windowId { entries[id]?.parentWindowId = nil }
    }

    func removeAll() { entries.removeAll() }

    private func entry(of window: Window) -> Entry? {
        guard let entry = entries[window.windowId], entry.pid == window.app.pid else { return nil }
        return entry
    }
}

/// The window an auxiliary window is listed under: its parent, while both are in the same tab,
/// the auxiliary one floating there and the parent tiled or floating in it, not itself one listed
/// under another. Anything else lists it as a window of its own, as before.
@MainActor
func auxiliaryWindowParent(of window: Window) -> Window? {
    guard config.usesBrowserTabs, window.isFloating,
          let parentId = AuxiliaryWindowRegistry.shared.parentWindowId(of: window),
          let parent = Window.get(byId: parentId), parent !== window, parent.app.pid == window.app.pid,
          let workspace = window.nodeWorkspace, parent.nodeWorkspace === workspace,
          parent.parent is TilingContainer || parent.isFloating,
          AuxiliaryWindowRegistry.shared.parentWindowId(of: parent) == nil
    else { return nil }
    return parent
}

/// Whether `window` is an auxiliary window whose parent is still open, wherever either is now. A pin's
/// structure doesn't count it: the pin's window is its parent, even while the pin has lent it.
@MainActor
func isAuxiliaryWindowOfOpenParent(_ window: Window) -> Bool {
    guard AuxiliaryWindowRegistry.shared.role(of: window) != nil,
          let parentId = AuxiliaryWindowRegistry.shared.parentWindowId(of: window),
          let parent = Window.get(byId: parentId)
    else { return false }
    return parent !== window && parent.app.pid == window.app.pid
}

/// Whether `window` is a floating draft or message window, which a saved tab or pin never records. A
/// dialog is saved as before, and a window the user moved to a tab of its own is an ordinary one.
@MainActor
func isEphemeralAuxiliaryWindow(_ window: Window) -> Bool {
    window.isFloating && AuxiliaryWindowRegistry.shared.role(of: window)?.isEphemeral == true
}

// MARK: - Where a new window came from

/// WinMux's focus as a span: which window, since when, and a serial that changes whenever the window
/// does, even to another of the same app's. Reselecting the same window keeps the span.
struct AuxiliaryFocusSpan: Equatable {
    let windowId: UInt32?
    let since: TimeInterval
    let serial: UInt64
}

@MainActor private(set) var auxiliaryFocusSpan = AuxiliaryFocusSpan(windowId: nil, since: 0, serial: 0)

/// Called whenever WinMux's focus changes.
@MainActor
func noteFocusedWindowForAuxiliaryWindows(_ window: Window?, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard window?.windowId != auxiliaryFocusSpan.windowId else { return }
    auxiliaryFocusSpan = AuxiliaryFocusSpan(windowId: window?.windowId, since: uptime, serial: auxiliaryFocusSpan.serial &+ 1)
}

/// The last app the system made active, and when, as its notification said. WinMux takes the app
/// active at its start as active since then, which is only later than it really became active.
@MainActor private(set) var lastAppActivation: (pid: Int32, uptime: TimeInterval)?

@MainActor
func noteAppActivatedForAuxiliaryWindows(pid: Int32, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    lastAppActivation = (pid, uptime)
}

/// One window the window server lists on screen, front to back: metadata only.
struct AuxiliaryOrderedWindow: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let layer: Int
}

/// Where a new window is among its app's windows on screen, as the window server orders them.
enum AuxiliaryWindowStacking: Equatable, Sendable {
    /// It isn't listed on screen.
    case absent
    /// One of the app's windows WinMux knows is in front of it, or another one it doesn't is.
    case notFront
    /// In front of every window of its app; `below` is the next WinMux knows, if any.
    case front(below: UInt32?)
}

/// The new window's place among its app's normal-level windows, front to back. Any window of the app
/// above it makes it not the front one. Below it, windows WinMux doesn't know (sheets, popovers,
/// windows not registered yet) are passed over to find the next one it does.
func auxiliaryWindowStacking(_ windows: [AuxiliaryOrderedWindow], newWindowId: UInt32, pid: Int32,
                             isRegistered: (UInt32) -> Bool) -> AuxiliaryWindowStacking {
    let own = windows.filter { $0.pid == pid && $0.layer == 0 }
    guard let index = own.firstIndex(where: { $0.id == newWindowId }) else { return .absent }
    guard index == own.startIndex else { return .notFront }
    return .front(below: own[(index + 1)...].first { isRegistered($0.id) }?.id)
}

/// The window server's on-screen list, as `CGWindowListCopyWindowInfo` gives it, front to back.
func auxiliaryOrderedWindows(_ infos: [[String: Any]]) -> [AuxiliaryOrderedWindow] {
    infos.compactMap { info in
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        return AuxiliaryOrderedWindow(id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
    }
}

/// What WinMux reads when it first sees a window, before any accessibility answer. Tests replace it.
struct AuxiliaryWindowOriginEnvironment {
    var orderedWindows: @MainActor () -> [AuxiliaryOrderedWindow]?
    /// The user's last mouse or key press or release, by the window server's count: when, never what.
    var lastUserInput: @MainActor () -> TimeInterval?
    var appIsActive: @MainActor (Int32) -> Bool

    @MainActor static var native: AuxiliaryWindowOriginEnvironment { AuxiliaryWindowOriginEnvironment(
        orderedWindows: {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
                .map(auxiliaryOrderedWindows)
        },
        lastUserInput: {
            let kinds: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                        .otherMouseUp, .keyDown]
            let since = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
            return since.map { ProcessInfo.processInfo.systemUptime - $0 }
        },
        appIsActive: { pid in NSRunningApplication(processIdentifier: pid)?.isActive == true },
    ) }
}

@MainActor var auxiliaryWindowOriginEnvironment = AuxiliaryWindowOriginEnvironment.native

/// Everything a new window's origin is decided by, read at once when WinMux first sees it, before
/// any accessibility answer could let the world move on.
struct AuxiliaryWindowOriginEvidence {
    let newWindowId: UInt32
    let pid: Int32
    let observedAt: TimeInterval
    /// The tab on screen then, which the window appeared in.
    let workspace: Workspace
    /// WinMux's focus then: its window, of the same app, and the span it had been focused for.
    let focusedWindow: Window
    let focusSpan: AuxiliaryFocusSpan
    let appIsActive: Bool
    /// When the app last became active, if that's known.
    let appActivatedAt: TimeInterval?
    let lastUserInput: TimeInterval?
    let stacking: AuxiliaryWindowStacking
}

/// How recent the user's last press must be for a window to count as opened by it.
let auxiliaryWindowInputWindow: TimeInterval = 5

/// What WinMux knows when it first sees `newWindowId` of `pid`, or nil when nothing could tie it to a
/// window here: not Tabs mode, at startup, or WinMux's focus not on a window of that app.
@MainActor
func captureAuxiliaryWindowOriginEvidence(newWindowId: UInt32, pid: Int32, observedAt: TimeInterval,
                                          environment: AuxiliaryWindowOriginEnvironment? = nil) -> AuxiliaryWindowOriginEvidence?
{
    let environment = environment ?? auxiliaryWindowOriginEnvironment
    guard config.usesBrowserTabs, !isStartup, !serverArgs.isReadOnly,
          let focused = focus.windowOrNil, focused.windowId != newWindowId, focused.app.pid == pid,
          auxiliaryFocusSpan.windowId == focused.windowId
    else { return nil }
    let stacking = environment.orderedWindows().map {
        auxiliaryWindowStacking($0, newWindowId: newWindowId, pid: pid, isRegistered: { Window.get(byId: $0) != nil })
    } ?? .absent
    return AuxiliaryWindowOriginEvidence(newWindowId: newWindowId, pid: pid, observedAt: observedAt, workspace: focus.workspace,
        focusedWindow: focused, focusSpan: auxiliaryFocusSpan, appIsActive: environment.appIsActive(pid),
        appActivatedAt: lastAppActivation?.pid == pid ? lastAppActivation?.uptime : nil,
        lastUserInput: environment.lastUserInput(), stacking: stacking)
}

/// The window the new one was opened from, or nil when that isn't positively shown. All of this must
/// hold, as read when WinMux first saw the new window:
/// - its app was active, and became so before the user's last press;
/// - WinMux's focus was on that same window since before that press, which was recent;
/// - the new window was on screen, in front of every window of its app, with that window right below it;
/// and, now, nothing has changed since: the same focus span, the same window, in the same tab.
/// Anything else (a window made in the background or behind, one a link in another app opened, a
/// switch between windows, focus moving during the accessibility read) leaves it a window of its own.
@MainActor
func auxiliaryWindowOrigin(_ evidence: AuxiliaryWindowOriginEvidence) -> Window? {
    let focused = evidence.focusedWindow
    guard config.usesBrowserTabs, evidence.appIsActive,
          let activated = evidence.appActivatedAt, let input = evidence.lastUserInput,
          activated < input, evidence.focusSpan.windowId == focused.windowId, evidence.focusSpan.since < input,
          input <= evidence.observedAt, evidence.observedAt - input <= auxiliaryWindowInputWindow,
          evidence.stacking == .front(below: focused.windowId),
          auxiliaryFocusSpan.serial == evidence.focusSpan.serial,
          Window.get(byId: focused.windowId) === focused, focus.workspace === evidence.workspace,
          focused.nodeWorkspace === evidence.workspace, !evidence.workspace.isArchived,
          focused.parent is TilingContainer || focused.isFloating
    else { return nil }
    // One level: a window opened from an auxiliary window goes with its parent.
    let origin = auxiliaryWindowParent(of: focused) ?? focused
    return origin.nodeWorkspace === evidence.workspace ? origin : nil
}

/// Where a new auxiliary window goes: floating in its parent's tab.
struct AuxiliaryWindowPlacement {
    let parent: Window
    let role: AuxiliaryWindowRole
    var workspace: Workspace { parent.nodeWorkspace.orDie() }
}

/// The role and parent of a window that just appeared, or nil to place it as before. `role` asks
/// the app's accessibility tree, only once the evidence holds, and the evidence is checked again after.
@MainActor
func auxiliaryWindowPlacement(_ evidence: AuxiliaryWindowOriginEvidence?, type: AxUiElementWindowType,
                              role: () async throws -> AuxiliaryWindowRole?) async rethrows -> AuxiliaryWindowPlacement? {
    guard type != .popup, let evidence, auxiliaryWindowOrigin(evidence) != nil else { return nil }
    let windowRole: AuxiliaryWindowRole? = type == .dialog ? .dialog : try await role()
    // The accessibility read awaited: nothing may have changed meanwhile.
    guard let windowRole, let parent = auxiliaryWindowOrigin(evidence) else { return nil }
    return AuxiliaryWindowPlacement(parent: parent, role: windowRole)
}

/// Records a placed auxiliary window. On its first appearance it keeps the app's size and place,
/// moved only as far as needed into the tab's area beside the sidebar, and made smaller only if it
/// doesn't fit there. Nothing claims to restore a size the app used before.
@MainActor
func recordAuxiliaryWindow(_ window: Window, placement: AuxiliaryWindowPlacement, initialRect: Rect?) {
    AuxiliaryWindowRegistry.shared.record(window.windowId, pid: window.app.pid, role: placement.role,
        parentWindowId: placement.parent.windowId)
    guard let initialRect, let workspace = window.nodeWorkspace, workspace.isVisible else { return }
    let fitted = auxiliaryWindowFrame(initialRect, in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)
    guard fitted != initialRect else { return }
    let resized = fitted.size != initialRect.size
    window.recordAuthoritativeActualRect(fitted)
    if resized { window.lastFloatingSize = fitted.size }
    window.setAxFrame(fitted.topLeftCorner, resized ? fitted.size : nil)
}

/// `rect` moved inside `area`, and made smaller only where it's larger than the area.
func auxiliaryWindowFrame(_ rect: Rect, in area: Rect) -> Rect {
    let width = min(rect.width, area.width)
    let height = min(rect.height, area.height)
    return Rect(topLeftX: rect.topLeftX.coerce(in: area.minX ... area.maxX - width),
        topLeftY: rect.topLeftY.coerce(in: area.minY ... area.maxY - height), width: width, height: height)
}

// MARK: - Accessibility

extension AxUiElementMock {
    /// Mail 16 on macOS 27, as captured in a clean VM: a message or compose window, told apart from
    /// the main viewer by its own fields. A compose window (New Message, Reply) has `Mail.toField`
    /// and `Mail.subjectField` among its children; a message window is a
    /// `Mail.messageViewer.window.N`, as the main viewer is too, but with the message content
    /// (`_MAIL_MESSAGE_CONTENT`) as its own child rather than in a split view. Anything else, or a
    /// window not built yet, isn't recognized.
    func mailAuxiliaryWindowRole() -> AuxiliaryWindowRole? {
        guard get(Ax.subroleAttr) == kAXStandardWindowSubrole else { return nil }
        let childIds = Set((get(Ax.childElementsAttr) ?? []).compactMap { $0.get(Ax.identifierAttr) })
        if childIds.contains("Mail.toField"), childIds.contains("Mail.subjectField") { return .mailCompose }
        if get(Ax.identifierAttr)?.hasPrefix("Mail.messageViewer.window.") == true,
           childIds.contains("_MAIL_MESSAGE_CONTENT") { return .mailMessage }
        return nil
    }
}
