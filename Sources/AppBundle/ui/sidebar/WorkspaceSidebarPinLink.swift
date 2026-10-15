import AppKit
import Common

// Pin Page, Pin Message and Pin Link (Tabs mode): a pin that keeps an address, a web page or an item
// in an app, and, clicked with no window, opens it again.
//
// Three things, never taken for one another:
// - Taking a link from a tab's window (Pin Page, Pin Message): an adapter reads that one window, never
//   whichever is in front, only when asked, and refuses a private window. Adding an app is adding an
//   adapter to `pinLinkAdapters`.
// - Opening a web page in a browser that says which window it made (Safari, and Chromium browsers):
//   a fresh window, which comes to the pin only once the browser's own answer names it. An address
//   other windows show too, or a window that can't be told, is never taken for it.
// - Opening any other link: the app the system opens such links with opens it, as a launcher does.
//   Nothing is claimed or moved: the app shows it where it does.
//
// The address is kept exactly as it was taken or typed. A page its window goes on to isn't the pin's
// until Update Page from Window says so. Nothing of a private window is kept, and no address is logged.

// MARK: - Seams

/// What a browser window shows, read from that window. Replaceable for tests.
@MainActor
var pinPageWindowRead: @MainActor (Window) async -> PinPageWindowRead? = { window in
    guard let window = window as? MacWindow else { return nil }
    return try? await window.macApp.getPinPageWindowRead(window.windowId)
}

/// Runs an AppleScript with its arguments. Replaceable for tests.
@MainActor
var pinLinkScript: @MainActor (String, [String]) async -> (result: NewWindowScriptResult, output: String) = { source, arguments in
    await runAppleScript(source, arguments: arguments)
}

/// The windows of a process that show exactly an address, read from each window. Replaceable for tests.
@MainActor
var pinPageWindowsShowing: @MainActor (Int32, String, BrowserTabAdapter) async -> [UInt32]? = { pid, url, browser in
    await Task.detached { pinPageAXWindowsShowing(pid: pid, url: url, adapter: browser) }.value
}

/// The marker a pinned page's fresh window first shows. Replaceable for tests.
@MainActor
var pinPageNewWindowMarker: @MainActor () -> String = pinPageWindowMarker

/// The running, regular process of an app. Replaceable for tests.
@MainActor
var pinPageRunningPid: @MainActor (String) -> Int32? = { bundleId in
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .first { $0.activationPolicy == .regular && !$0.isTerminated }?.processIdentifier
}

/// Launches a browser in the background and waits until it has put back its own windows. Its pid, or
/// nil if it couldn't be opened. Replaceable for tests.
@MainActor
var pinPageLaunchBrowser: @MainActor (String, URL) async -> Int32? = { bundleId, appURL in
    let launch = await launchApplication(.init(bundleId: bundleId, appName: bundleId, bundleURL: appURL), activates: false)
    guard let app = launch.app else { return nil }
    await waitUntilSettled(app)
    return app.isTerminated ? nil : app.processIdentifier
}

/// The app the system opens `url` with, and its bundle id. Replaceable for tests.
@MainActor
var pinLinkHandlerApp: @MainActor (URL) -> (url: URL, bundleId: String?)? = { url in
    NSWorkspace.shared.urlForApplication(toOpen: url).map { ($0, Bundle(url: $0)?.bundleIdentifier) }
}

/// Opens `url` with the app at the second URL, bringing that app forward, as a launcher does.
/// Replaceable for tests.
@MainActor
var openPinLinkURL: @MainActor (URL, URL) async throws -> Void = { url, app in
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
}

/// What the user typed or pasted for a link.
struct PinLinkEntry: Equatable {
    var address: String
    var name: String
}

/// Asks for a link: `heading`, the fields as they are, the button that confirms, and what was wrong with
/// the last answer, if anything. Nil when cancelled. Replaceable for tests.
@MainActor
var pinLinkPrompt: @MainActor (_ heading: String, _ entry: PinLinkEntry, _ confirm: String, _ problem: String?) -> PinLinkEntry? = {
    heading, entry, confirm, problem in
    let alert = NSAlert()
    alert.messageText = heading
    alert.informativeText = problem ?? "A web page, or a link to an item in an app, such as a message, a note or a task. "
        + "Clicking the pin while it has no window opens it."
    if problem != nil { alert.alertStyle = .warning }
    let address = NSTextField(string: entry.address)
    address.placeholderString = "https://example.com/page, or an app's link"
    address.setAccessibilityLabel("Address")
    address.identifier = NSUserInterfaceItemIdentifier("WinMux.pinLink.address")
    let name = NSTextField(string: entry.name)
    name.placeholderString = "Name (optional)"
    name.setAccessibilityLabel("Name")
    name.identifier = NSUserInterfaceItemIdentifier("WinMux.pinLink.name")
    for field in [address, name] {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
    }
    let stack = NSStackView(views: [address, name])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
    alert.accessoryView = stack
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = address
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return PinLinkEntry(address: address.stringValue, name: name.stringValue)
}

// MARK: - Adapters

/// What an adapter took from a window.
enum PinLinkCapture: Equatable {
    case captured(url: String, title: String)
    case refused(String)
}

/// How WinMux takes a link from one kind of app's window, read from that window only, never from
/// whichever window is in front, and only when the user asks.
@MainActor
struct PinLinkAdapter {
    /// Kept in the link, saying how it was taken: "safari", "chromium", "mail".
    let id: String
    /// What it pins, in the menu: "Page" makes Pin Page.
    let itemName: String
    /// Whether it takes links from this app's windows.
    let takesWindows: @MainActor (String) -> Bool
    /// The link `window` shows now, or why there's none.
    let capture: @MainActor (Window) async -> PinLinkCapture
}

/// The adapters, by the apps whose windows they read. One app, one adapter: the first that takes it.
@MainActor
var pinLinkAdapters: [PinLinkAdapter] = [
    PinLinkAdapter(id: "safari", itemName: "Page", takesWindows: { BrowserTabAdapter(bundleId: $0) == .safari },
        capture: { await capturePinPage($0, browser: .safari) }),
    PinLinkAdapter(id: "chromium", itemName: "Page", takesWindows: { BrowserTabAdapter(bundleId: $0) == .chromium },
        capture: { await capturePinPage($0, browser: .chromium) }),
    PinLinkAdapter(id: "mail", itemName: "Message", takesWindows: { $0 == "com.apple.mail" },
        capture: { await capturePinMessage($0) }),
]

@MainActor
func pinLinkAdapter(forBundleId bundleId: String?) -> PinLinkAdapter? {
    guard let bundleId else { return nil }
    return pinLinkAdapters.first { $0.takesWindows(bundleId) }
}

let pinPagePrivateMessage = "Pages in a private window aren't pinned: WinMux keeps nothing of private browsing."
let pinPageIncognitoMessage = "This page is open in an Incognito window, so it isn't pinned: WinMux keeps nothing of private browsing."

/// Only web pages are pinned from a browser's window, and opened in one.
func pinLinkIsWebAddress(_ address: String) -> Bool {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
}

/// The page a browser window shows: its full address, unless the window is private, or isn't known
/// not to be.
@MainActor
func capturePinPage(_ window: Window, browser: BrowserTabAdapter) async -> PinLinkCapture {
    let appName = window.app.name ?? (browser == .safari ? "Safari" : "The browser")
    var read = await pinPageWindowRead(window)
    // Safari builds a window's page for accessibility only once something asks: the first read can miss it.
    for _ in 0 ..< 2 where read != nil && read?.url == nil && read?.privacy != .private && read?.showsSeveralPages == false {
        try? await Task.sleep(for: .milliseconds(250))
        read = await pinPageWindowRead(window)
    }
    guard let read else { return .refused("WinMux couldn't read this \(appName) window.") }
    if read.privacy == .private { return .refused(pinPagePrivateMessage) }
    if read.showsSeveralPages { return .refused("This window shows more than one page, so WinMux can't tell which to pin.") }
    guard let url = read.url else { return .refused("This \(appName) window shows no web page. Open the page in it first.") }
    guard pinLinkIsWebAddress(url) else {
        return .refused("Pin Page pins web pages, whose address starts with http or https. Use Pin Link… for another address.")
    }
    switch browser {
        case .safari:
            guard read.privacy == .normal else {
                return .refused("WinMux can't tell whether this is a Private Browsing window, so it pins nothing.")
            }
        case .chromium:
            guard let bundleId = window.app.rawAppBundleId else { return .refused("WinMux doesn't know which app shows this window.") }
            guard let frame = read.frame else { return .refused("WinMux couldn't read where this \(appName) window is, so it pins nothing.") }
            // Only the browser can say a window isn't Incognito, whatever its language. A window keeps its
            // mode for its life; the browser's windows are told apart by their frames, not their pages.
            let answer = await pinLinkScript(pinPageChromiumModeScript(bundleId: bundleId), [])
            switch answer.result {
                case .success: break
                case .notAuthorized:
                    return .refused("To pin a page, WinMux asks \(appName) whether its window is an Incognito window. Allow WinMux "
                        + "to control \(appName) in System Settings → Privacy & Security → Automation, then try again.")
                case .failed:
                    return .refused("\(appName) didn't say whether this is an Incognito window, so WinMux pins nothing.")
            }
            // This window must have stayed where it was, showing the page, while the browser answered: the
            // answer is then about this window, or a window exactly where it is, and any Incognito one there
            // refuses.
            let after = await pinPageWindowRead(window)
            guard after?.url == url, after?.frame == frame, after?.privacy == .unknown else {
                return .refused(after?.privacy == .private ? pinPagePrivateMessage
                    : "This window changed while WinMux checked it, so it pins nothing. Try again.")
            }
            switch pinPageChromiumPrivacy(answer.output, frame: frame) {
                case .normal: break
                case .private: return .refused(pinPageIncognitoMessage)
                case .unknown: return .refused("\(appName) didn't say whether this is an Incognito window, so WinMux pins nothing.")
            }
    }
    let title = pinPageDisplayTitle(read.title, appName: window.app.name) ?? URL(string: url)?.host ?? url
    return .captured(url: url, title: title)
}

/// Mail: the one message selected in the message viewer whose window is the window WinMux knows by
/// `item 1 of argv`, by its Message-ID: "message<TAB>id<TAB>subject", "selected<TAB>count", or "none".
/// A viewer's window is Cocoa's, whose id is the window server's number.
let pinMessageMailScript = """
    on run argv
        set wanted to (item 1 of argv) as integer
        set separator to character id 9
        tell application id "com.apple.mail"
            repeat with viewer in (get every message viewer)
                if (id of window of viewer) is wanted then
                    set chosen to (get selected messages of viewer)
                    if chosen is missing value then return "selected" & separator & "0"
                    if (count of chosen) is not 1 then return "selected" & separator & (count of chosen)
                    set picked to item 1 of chosen
                    return "message" & separator & (message id of picked) & separator & (subject of picked)
                end if
            end repeat
        end tell
        return "none"
    end run
    """

private let pinMessageIdAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!$&'()*+,;=:@"))

/// Mail's own link to the message with this Message-ID.
func pinMessageURL(messageId: String) -> String? {
    var id = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
    guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: pinMessageIdAllowed) else { return nil }
    return "message://%3C\(encoded)%3E"
}

/// What Mail's answer to `pinMessageMailScript` says.
func pinMessageCapture(_ answer: String) -> PinLinkCapture {
    let fields = answer.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    switch fields.first {
        case "message":
            guard fields.count >= 2, let url = pinMessageURL(messageId: fields[1]) else {
                return .refused("Mail gave no Message-ID for this message, so WinMux can't link to it.")
            }
            let subject = fields.count == 3 ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return .captured(url: url, title: subject.isEmpty ? "Mail Message" : subject)
        case "selected":
            return fields.count == 2 && fields[1] == "0"
                ? .refused("Select the message in this Mail window first.")
                : .refused("Select just one message in this Mail window.")
        default:
            return .refused("WinMux pins a message from Mail's main window, with that message selected.")
    }
}

/// The message selected in a Mail viewer window, by its Message-ID, as Mail itself answers.
@MainActor
func capturePinMessage(_ window: Window) async -> PinLinkCapture {
    let answer = await pinLinkScript(pinMessageMailScript, [String(window.windowId)])
    switch answer.result {
        case .success: return pinMessageCapture(answer.output)
        case .notAuthorized:
            return .refused("To pin a message, WinMux asks Mail which message is selected. Allow WinMux to control Mail "
                + "in System Settings → Privacy & Security → Automation, then try again.")
        case .failed: return .refused("Mail didn't say which message is selected in this window.")
    }
}

// MARK: - Pin, update, forget

/// Pin Page or Pin Message, or Update … from Window with `updating`: the link the tab's one window shows,
/// read from that window by its app's adapter, becomes the pin's link. As with a document, a newer Pin
/// or Update of the tab, or any change to it since, ends it with nothing written.
@MainActor
func pinLinkFromWindowFromSidebar(_ name: String, updating: Bool) {
    guard let tab = Workspace.existing(byName: name) else { return }
    let window: Window
    switch pinDocumentSourceWindow(tab) {
        case .success(let source): window = source
        case .failure(let refusal): return showPinDocumentNotice(updating ? "Update Link" : "Pin Page", refusal.message)
    }
    guard let adapter = pinLinkAdapter(forBundleId: window.app.rawAppBundleId), let bundleId = window.app.rawAppBundleId else {
        return showPinDocumentNotice("Pin Link", "WinMux can't take a link from this window. Use Pin Link… to type or paste one.")
    }
    let title = updating ? "Update \(adapter.itemName) from Window" : "Pin \(adapter.itemName)"
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice(title, reason) }
    let appearance = workspaceSidebarOrganizationStore.state.workspaces[name]
    if updating, appearance?.isFavorite != true || appearance?.link == nil { return }
    if appearance?.isFavorite == true, appearance?.document != nil { return }
    let target = PinDocumentTarget(tab)
    let operation = beginPinResourceOperation(name)
    _ = Task { @MainActor in
        let capture = await adapter.capture(window)
        // A newer Pin or Update of this tab took over: it reports.
        guard isNewestPinResourceOperation(name, operation) else { return }
        guard target.isCurrent, pinDocumentStillSource(tab, window) else {
            endPinResourceOperation(name, operation)
            return showPinDocumentNotice(title, pinDocumentChangedMessage)
        }
        switch capture {
            case .refused(let why):
                endPinResourceOperation(name, operation)
                showPinDocumentNotice(title, why)
            case .captured(let url, let pageTitle):
                let link = WorkspaceSidebarPinLink(url: url, title: pageTitle, adapter: adapter.id, bundleId: bundleId, source: .window)
                runPinDocumentWrite(title) {
                    defer { endPinResourceOperation(name, operation) }
                    guard isNewestPinResourceOperation(name, operation) else { return nil }
                    guard target.isCurrent, pinDocumentStillSource(tab, window) else { return pinDocumentChangedMessage }
                    return commitWorkspaceSidebarPinResource(tab, .link(link), title: title)
                }
        }
    }
}

/// The link a typed or pasted entry makes, or what's wrong with it. Editing `previous` keeps how it was
/// taken while the address stays the same, and the browser it opens in while it stays a web page.
@MainActor
func pinLinkFromEntry(_ entry: PinLinkEntry, editing previous: WorkspaceSidebarPinLink? = nil) -> Result<WorkspaceSidebarPinLink, PinLinkEntryRefusal> {
    var address = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty else { return .failure(.init("Type or paste an address.")) }
    guard address.count <= 8192 else { return .failure(.init("That address is too long to pin.")) }
    guard !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    else { return .failure(.init("An address can't contain spaces or line breaks.")) }
    // "example.com/page", as a browser's address field takes it.
    if URL(string: address)?.scheme == nil, address.contains("."), !address.hasPrefix("/") { address = "https://" + address }
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
        return .failure(.init("That isn't an address WinMux can open."))
    }
    var handlerName: String?
    switch scheme {
        case "file":
            return .failure(.init("To pin a file, open it in this tab and choose Pin Document: it keeps the file even when it's renamed or moved."))
        case "javascript", "data", "about", "blob", "vbscript":
            return .failure(.init("WinMux doesn't pin “\(scheme):” addresses."))
        case "http", "https":
            guard url.host?.isEmpty == false else { return .failure(.init("That web address has no site in it.")) }
        default:
            guard let handler = pinLinkHandlerApp(url) else {
                return .failure(.init("No app on this Mac opens “\(scheme):” links."))
            }
            handlerName = FileManager.default.displayName(atPath: handler.url.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }
    var name = String(entry.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    if name.isEmpty { name = url.host?.takeIf { !$0.isEmpty && (scheme == "http" || scheme == "https") } ?? handlerName ?? scheme }
    var link = WorkspaceSidebarPinLink(url: address, title: name, adapter: "link", bundleId: nil, source: .manual)
    if let previous, previous.url == address {
        link.adapter = previous.adapter
        link.bundleId = previous.bundleId
        link.source = previous.source
    } else if let previous, pinLinkIsWebAddress(address), BrowserTabAdapter(bundleId: previous.bundleId) != nil {
        // Still a page, still opened in the browser it was taken in.
        link.adapter = previous.adapter
        link.bundleId = previous.bundleId
    }
    return .success(link)
}

struct PinLinkEntryRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Asks for a link until it's one WinMux can pin, or the user cancels.
@MainActor
private func askForPinLink(_ heading: String, confirm: String, previous: WorkspaceSidebarPinLink?) -> WorkspaceSidebarPinLink? {
    var entry = PinLinkEntry(address: previous?.url ?? "", name: previous?.title ?? "")
    var problem: String?
    while let answer = pinLinkPrompt(heading, entry, confirm, problem) {
        entry = answer
        switch pinLinkFromEntry(answer, editing: previous) {
            case .success(let link): return link
            case .failure(let refusal): problem = refusal.message
        }
    }
    return nil
}

/// Pin Link… for a tab, or Edit Link… for a pinned link: the address typed or pasted becomes the pin's.
/// The tab may change while the user types: the write checks it again, in its own session.
@MainActor
func editPinLinkFromSidebar(_ name: String) {
    guard let tab = Workspace.existing(byName: name) else { return }
    let appearance = workspaceSidebarOrganizationStore.state.workspaces[name]
    let isPinned = appearance?.isFavorite == true
    // A pinned document keeps its file until it's forgotten; a pinned split brings back its own windows.
    guard !(isPinned && appearance?.document != nil), appearance?.composition == nil else { return }
    let previous = isPinned ? appearance?.link : nil
    let title = previous == nil ? "Pin Link" : "Edit Link"
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice(title, reason) }
    let target = PinDocumentTarget(tab)
    guard let link = askForPinLink(previous == nil ? "Pin a Link to This Tab" : "Edit Link", confirm: previous == nil ? "Pin" : "Save",
        previous: previous), link != previous else { return }
    runPinDocumentWrite(title) {
        guard target.isCurrent else { return pinDocumentChangedMessage }
        return commitWorkspaceSidebarPinResource(tab, .link(link), title: title)
    }
}

/// New Link Pin…: a new pin in `projectId` on the display of `monitorScopeId`, holding only the link
/// typed or pasted. It opens when clicked.
@MainActor
func newLinkPinFromSidebar(projectId: WorkspaceProjectId, monitorScopeId: String) {
    if let reason = pinDocumentReadOnlyReason() { return showPinDocumentNotice("New Link Pin", reason) }
    guard let link = askForPinLink("New Link Pin", confirm: "Pin", previous: nil) else { return }
    runPinDocumentWrite("New Link Pin") {
        guard winMuxWorkspaceState.projectsById[projectId] != nil else { return "That project is gone." }
        let tab = createBlankWorkspace(projectId: projectId, monitor: workspaceSidebarTargetMonitor(scopeId: monitorScopeId))
        return commitWorkspaceSidebarPinResource(tab, .link(link), title: "New Link Pin")
    }
}

@MainActor
func forgetPinLinkFromSidebar(_ name: String) {
    guard let tab = Workspace.existing(byName: name) else { return }
    if serverArgs.isReadOnly || workspaceSidebarOrganizationStore.readOnlyReason != nil {
        return showPinDocumentNotice("Forget Link", pinDocumentReadOnlyReason() ?? "")
    }
    let target = PinDocumentTarget(tab)
    runPinDocumentWrite("Forget Link") {
        guard target.isCurrent, workspaceSidebarOrganizationStore.state.workspaces[tab.name]
            .map({ $0.isFavorite && $0.link != nil }) == true else { return nil }
        return commitWorkspaceSidebarPinResource(tab, nil, title: "Forget Link")
    }
}

// MARK: - Open

/// How a pinned link opens.
enum PinLinkOpening: Equatable {
    /// A web page, in a fresh window of a browser that says which window it made.
    case freshWindow(bundleId: String, appURL: URL, browser: BrowserTabAdapter)
    /// By an app, as a launcher opens it: nothing is claimed or moved.
    case launcher(appURL: URL)
}

/// How `link` opens now, or why it can't. The app it was taken in, while installed; otherwise the app
/// the system opens such links with.
@MainActor
func pinLinkOpening(_ link: WorkspaceSidebarPinLink) -> Result<PinLinkOpening, PinLinkEntryRefusal> {
    guard link.version <= WorkspaceSidebarPinLink.currentVersion else {
        return .failure(.init("A newer WinMux made this pin's link. Update WinMux to open it."))
    }
    guard link.isReadable, let url = URL(string: link.url), let scheme = url.scheme else {
        return .failure(.init("This pin's link is empty or damaged. Choose Edit Link… to set it again."))
    }
    let isPage = pinLinkIsWebAddress(link.url)
    if let bundleId = link.bundleId, let appURL = pinDocumentAppURL(bundleId) {
        if isPage, let browser = BrowserTabAdapter(bundleId: bundleId) { return .success(.freshWindow(bundleId: bundleId, appURL: appURL, browser: browser)) }
        return .success(.launcher(appURL: appURL))
    }
    guard let handler = pinLinkHandlerApp(url) else { return .failure(.init("No app on this Mac opens “\(scheme):” links.")) }
    if isPage, let bundleId = handler.bundleId, let browser = BrowserTabAdapter(bundleId: bundleId) {
        return .success(.freshWindow(bundleId: bundleId, appURL: handler.url, browser: browser))
    }
    return .success(.launcher(appURL: handler.url))
}

/// A pinned link whose window is gone, clicked once the pin is shown. A web page opens in a fresh window
/// of its browser, which comes to the pin only when the browser's answer names it; any other link opens
/// as a launcher opens it. A change to the pin meanwhile, Undo included, withdraws it.
@MainActor
func openPinnedLink(_ tab: Workspace, _ link: WorkspaceSidebarPinLink) {
    guard !serverArgs.isReadOnly else { return showPinDocumentNotice("Pinned Link", "WinMux is running with --read-only.") }
    let opening: PinLinkOpening
    switch pinLinkOpening(link) {
        case .success(let how): opening = how
        case .failure(let refusal): return showPinDocumentNotice("Pinned Link", refusal.message)
    }
    guard let url = URL(string: link.url) else { return }
    let target = PinDocumentTarget(tab)
    let focusGeneration = focusChangeGeneration
    switch opening {
        case .launcher(let appURL):
            _ = Task { @MainActor in
                guard target.isCurrent else { return }
                do {
                    try await openPinLinkURL(url, appURL)
                } catch {
                    showPinDocumentNotice("Pinned Link", "Couldn't open “\(link.title)”: \(error.localizedDescription)")
                }
            }
        case .freshWindow(let bundleId, let appURL, let browser):
            _ = Task { @MainActor in
                await requestPinnedPageWindow(tab, target: target, link: link, bundleId: bundleId, appURL: appURL, browser: browser,
                    focusGeneration: focusGeneration)
            }
    }
}

/// Registers the request for the page's window, then asks the browser for a fresh window. That window
/// first shows a one-time marker, so the browser's window made for this request, and only it, is found
/// by what it shows, before it's sent to the page: Safari names it in its answer; a Chromium browser's is
/// the one window showing the marker, sent on by the browser's own number for the window it made.
/// Nothing else, such as a window showing the same page, is taken for it. A window that can't be told
/// goes where any new window goes.
@MainActor
private func requestPinnedPageWindow(_ tab: Workspace, target: PinDocumentTarget, link: WorkspaceSidebarPinLink,
                                     bundleId: String, appURL: URL, browser: BrowserTabAdapter, focusGeneration: UInt64) async {
    let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.localizedName
        ?? appURL.deletingPathExtension().lastPathComponent
    var pid = pinPageRunningPid(bundleId)
    if pid == nil {
        // Its own windows come back first; only the window asked for afterwards is the pin's.
        pid = await pinPageLaunchBrowser(bundleId, appURL)
    }
    guard let pid else { return showPinDocumentNotice("Pinned Page", "\(appName) couldn't be opened.") }
    guard target.isCurrent, !workspaceHasLifecycleWindows(tab) else { return }
    let page = PinPageExpectation(url: link.url)
    let registry = NewWindowIntentRegistry.shared
    guard let intent = registry.register(bundleId: bundleId, pid: pid, targetWorkspace: tab,
        preexistingWindowIds: existingWindowIds(pid: pid), focusGeneration: focusGeneration,
        timeout: newWindowScriptTimeout + newWindowIntentTimeout, page: page,
        completion: { outcome in finishPinnedPageRequest(outcome, target: target, link: link, appName: appName) },
        isStillWanted: { target.isCurrent })
    else {
        return showPinDocumentNotice("Pinned Page", "\(appName) is already opening a window. Try again in a moment.")
    }
    let intentId = intent.id
    registry.recordFocusWhenSent(forIntent: intentId, .current)
    _ = Task { @MainActor in await watchNewWindowIntentExpiry(intentId) }
    func giveUp(_ outcome: NewWindowRequestOutcome) {
        page.decide(nil)
        registry.cancel(intentId: intentId, outcome: target.isCurrent ? outcome : .cancelled)
    }
    func failure(_ result: NewWindowScriptResult) -> NewWindowRequestOutcome {
        switch result {
            case .notAuthorized:
                .failed("Allow WinMux to control \(appName) in System Settings → Privacy & Security → Automation to open pinned pages.")
            case .failed(let message): .failed("\(appName) couldn't open “\(link.title)”: \(message)")
            case .success: .failed("\(appName) opened “\(link.title)”, but WinMux couldn't tell which window it opened in, "
                + "so that window went where new windows go.")
        }
    }
    let marker = pinPageNewWindowMarker()
    var made: UInt32?
    switch browser {
        case .safari:
            let answer = await pinLinkScript(pinPageSafariOpenScript, [link.url, marker])
            guard answer.result == .success else { return giveUp(failure(answer.result)) }
            made = pinPageSafariMadeWindow(answer.output)
        case .chromium:
            let answer = await pinLinkScript(pinPageChromiumOpenScript(bundleId: bundleId), [marker])
            guard answer.result == .success else { return giveUp(failure(answer.result)) }
            guard let number = pinPageChromiumWindowNumber(answer.output), let marked = await pinPageWindowShowing(marker, pid: pid)
            else { return giveUp(failure(.success)) }
            let sent = await pinLinkScript(pinPageChromiumGoScript(bundleId: bundleId), [number, link.url])
            guard sent.result == .success else { return giveUp(failure(sent.result)) }
            made = marked
    }
    guard target.isCurrent else { return giveUp(.cancelled) }
    // A window the process had before the request can't be the one it made.
    guard let made, !intent.preexistingWindowIds.contains(made) else { return giveUp(failure(.success)) }
    page.decide(made)
    registry.restartDeadline(forIntent: intentId)

    @MainActor func pinPageWindowShowing(_ marker: String, pid: Int32) async -> UInt32? {
        // The window is there once the browser has answered; what it shows may take a moment to read.
        for attempt in 0 ..< 12 {
            if attempt > 0 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return nil }
            }
            guard let showing = await pinPageWindowsShowing(pid, marker, .chromium) else { continue }
            if showing.count > 1 { return nil }
            if let only = showing.first { return only }
        }
        return nil
    }
}

@MainActor
private func finishPinnedPageRequest(_ outcome: NewWindowRequestOutcome, target: PinDocumentTarget, link: WorkspaceSidebarPinLink,
                                     appName: String) {
    guard target.isCurrent else { return }
    switch outcome {
        case .timedOut:
            showPinDocumentNotice("Pinned Page", "\(appName) didn't open “\(link.title)” in a window WinMux could place.")
        case .failed(let reason):
            showPinDocumentNotice("Pinned Page", reason)
        case .placed, .cancelled, .opened:
            break
    }
}

// MARK: - Menu and display

/// Tabs mode: the identity menu's resource items for a tab. A pinned document's own; for a pinned link,
/// Update … from Window when an adapter reads its one window, Edit Link… and Forget Link; otherwise Pin
/// Page or Pin Message for a window an adapter reads, then Pin Document and Pin Link….
@MainActor
func workspaceSidebarPinResourceMenuEntries(_ workspace: WorkspaceSidebarWorkspaceViewModel,
                                            send: @escaping @MainActor (WorkspaceSidebarAction) -> Void) -> [WorkspaceSidebarAppMenuEntry] {
    let name = workspace.name
    let appearance = workspace.appearance
    if appearance.isFavorite, appearance.document != nil { return workspaceSidebarPinDocumentMenuEntries(workspace, send: send) }
    let windows = workspaceSidebarPinnedTabWindows(workspace)
    let isSplitPin = appearance.composition != nil
    let refusal: PinDocumentRefusal? = isSplitPin ? .split : windows.isEmpty ? .noWindow : windows.count > 1 ? .severalWindows : nil
    let adapter = windows.count == 1 ? pinLinkAdapter(forBundleId: windows[0].appBundleId) : nil
    let splitHelp = "A pinned split brings back its own windows."
    if appearance.isFavorite, let link = appearance.link {
        var entries: [WorkspaceSidebarAppMenuEntry] = []
        if let adapter {
            entries.append(.init(title: "Update \(adapter.itemName) from Window", enabled: refusal == nil,
                perform: { send(.updatePinLinkFromWindow(name)) },
                help: refusal.map { _ in splitHelp } ?? "Pins this tab to the \(adapter.itemName.lowercased()) its window shows now, instead of “\(link.title)”"))
        }
        return entries + [
            .init(title: "Edit Link…", perform: { send(.editPinLink(name)) }, help: "Changes the address this pin opens"),
            .init(title: "Forget Link", perform: { send(.forgetPinLink(name)) }),
        ]
    }
    // Pin Document stays for every window: a browser can show a file too.
    let capture: [WorkspaceSidebarAppMenuEntry] = adapter.map { adapter in
        [.init(title: "Pin \(adapter.itemName)", enabled: refusal == nil, perform: { send(.pinLinkFromWindow(name)) },
            help: refusal.map { _ in splitHelp } ?? "Pins this tab to the \(adapter.itemName.lowercased()) its window shows")]
    } ?? []
    return capture + workspaceSidebarPinDocumentMenuEntries(workspace, send: send) + [
        .init(title: "Pin Link…", enabled: !isSplitPin, perform: { send(.editPinLink(name)) },
            help: isSplitPin ? splitHelp : "Pins this tab to a web page or an app's link you type or paste"),
    ]
}

/// The app a pinned link opens in, for its tile while it has no window: the one it was taken in, or the
/// system's app for such links. Looked up at most once a minute per app or scheme.
@MainActor
func workspaceSidebarPinLinkApp(_ link: WorkspaceSidebarPinLink) -> WorkspaceSidebarSavedApp? {
    let key = link.bundleId ?? URL(string: link.url)?.scheme?.lowercased() ?? ""
    let now = ProcessInfo.processInfo.systemUptime
    if let cached = pinLinkAppCache[key], now - cached.at < 60 { return cached.app }
    var app: WorkspaceSidebarSavedApp?
    if let bundleId = link.bundleId, let appURL = pinDocumentAppURL(bundleId) {
        app = .init(bundleId: bundleId, bundlePath: appURL.path, name: savedWorkspaceAppDisplayName(bundleId: bundleId, appName: nil,
            bundlePath: appURL.path))
    } else if let url = URL(string: link.url), let handler = pinLinkHandlerApp(url), let bundleId = handler.bundleId {
        app = .init(bundleId: bundleId, bundlePath: handler.url.path,
            name: savedWorkspaceAppDisplayName(bundleId: bundleId, appName: nil, bundlePath: handler.url.path))
    }
    pinLinkAppCache[key] = (app, now)
    return app
}

@MainActor private var pinLinkAppCache: [String: (app: WorkspaceSidebarSavedApp?, at: TimeInterval)] = [:]

@MainActor
func resetPinLinkAppCacheForTests() { pinLinkAppCache = [:] }
