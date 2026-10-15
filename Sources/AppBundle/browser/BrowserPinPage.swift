import AppKit

// What a browser window shows, for a pinned page: the address of its selected tab and whether it's a
// private window, read from that window alone, never from whichever window is in front.
//
// Safari 27 reports no AXDocument for its windows. The selected tab's page is the window's AXWebArea,
// whose AXURL is the full address; Safari builds that part of its tree only once something asks, so
// the first read can miss it. A private window has a toolbar element identified `Private`, whatever
// the language, and its title ends in ", Private Browsing" in English. Chromium browsers report the
// selected tab's address as the window's AXDocument, Incognito windows too; their title says
// "(Incognito)" in English only. Nothing ties the browser's own windows to accessibility's, so a
// Chromium window is known not to be private only when the browser says every one of its windows is
// normal: a window keeps its mode for its life, and this one was there before and after it said so.

enum PinPagePrivacy: Equatable, Sendable {
    case normal
    case `private`
    /// Nothing says either way.
    case unknown
}

struct PinPageWindowRead: Equatable, Sendable {
    /// The selected tab's full address, as the browser reports it; nil if none was found, or if the
    /// window shows more than one page.
    var url: String?
    var title: String?
    var privacy: PinPagePrivacy
    /// The window shows several pages side by side: none of them is "the" page.
    var showsSeveralPages = false
}

/// At most this many elements are read looking for a Safari window's page or its private marker. The
/// page's own content is never walked: its area ends the search there.
let pinPageReadLimit = 400

/// One element of a browser window, as the page reader reads it. `NativePinPageNode` reads accessibility;
/// tests bring their own.
protocol PinPageAXNode {
    /// The attribute's text: nil when the element has none, `unreadable` when the read failed otherwise.
    func text(_ attribute: String) -> (value: String?, unreadable: Bool)
    /// Nil when the children couldn't be read.
    func children() -> [Self]?
}

struct NativePinPageNode: PinPageAXNode {
    let element: AXUIElement

    func text(_ attribute: String) -> (value: String?, unreadable: Bool) {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return (nil, false) }
        guard error == .success, let value else { return (nil, true) }
        if let string = value as? String { return (string, false) }
        if CFGetTypeID(value) == CFURLGetTypeID() { return ((value as! NSURL).absoluteString, false) }
        return (nil, false)
    }

    func children() -> [Self]? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success, let list = value as? [AXUIElement] else { return nil }
        return list.map { Self(element: $0) }
    }
}

/// Reads `window` of a browser of `adapter`'s kind. Runs on the app's AX thread, or off the main thread.
/// A Safari window is normal only once its toolbar was found and everything around its page was read
/// without the private marker: a read that failed, or a search cut short, leaves it unknown, never normal.
func readPinPageWindow<Node: PinPageAXNode>(_ window: Node, adapter: BrowserTabAdapter) -> PinPageWindowRead {
    let title = window.text(kAXTitleAttribute).value
    switch adapter {
        case .chromium:
            let incognito = title?.contains("(Incognito)") == true
            return .init(url: window.text(kAXDocumentAttribute).value, title: title, privacy: incognito ? .private : .unknown)
        case .safari:
            var urls: [String] = []
            var isPrivate = title?.hasSuffix(", Private Browsing") == true
            var sawToolbar = false
            var isComplete = true
            var queue: [(node: Node, inToolbar: Bool)] = [(window, false)]
            var visited = 0
            while !queue.isEmpty {
                guard visited < pinPageReadLimit else {
                    isComplete = false
                    break
                }
                let (node, inToolbar) = queue.removeFirst()
                visited += 1
                let role = node.text(kAXRoleAttribute)
                if role.unreadable { isComplete = false }
                if role.value == "AXWebArea" {
                    // A page's frames are inside its own area, never read as pages of their own.
                    if let url = node.text("AXURL").value, !urls.contains(url) { urls.append(url) }
                    continue
                }
                let isToolbar = role.value == kAXToolbarRole
                if isToolbar { sawToolbar = true }
                if inToolbar || isToolbar {
                    let identifier = node.text(kAXIdentifierAttribute)
                    if identifier.unreadable { isComplete = false }
                    if identifier.value == "Private" { isPrivate = true }
                }
                guard let children = node.children() else {
                    isComplete = false
                    continue
                }
                for child in children { queue.append((child, inToolbar || isToolbar)) }
            }
            let privacy: PinPagePrivacy = isPrivate ? .private : sawToolbar && isComplete ? .normal : .unknown
            return .init(url: urls.count == 1 ? urls[0] : nil, title: title, privacy: privacy, showsSeveralPages: urls.count > 1)
    }
}

/// The title a browser gives a window, without the browser's own name or private suffix.
func pinPageDisplayTitle(_ title: String?, appName: String?) -> String? {
    guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
    for suffix in [", Private Browsing", " (Incognito)"] where title.hasSuffix(suffix) { title.removeLast(suffix.count) }
    if let appName, title.hasSuffix(" - \(appName)") { title.removeLast(appName.count + 3) }
    return title.isEmpty ? nil : title
}

// MARK: - The browsers' own answers

/// A one-time address a pinned page's fresh window first shows, so that window, and only it, can be
/// found by what it shows: the browser's own window made for this request, never one merely new or
/// showing the same page. Nothing is logged or kept of it.
func pinPageWindowMarker() -> String { "about:blank#winmux-\(UUID().uuidString)" }

/// Safari: a new window showing the marker `item 2 of argv`, then the one window showing it is sent to
/// `item 1 of argv`. Its answer is that window's number, which is the window server's, or "none".
/// `make new document` always makes a window, even for an address another window shows.
let pinPageSafariOpenScript = """
    on run argv
        set target to item 1 of argv
        set marker to item 2 of argv
        tell application id "com.apple.Safari"
            make new document with properties {URL:marker}
            set marked to (get id of every window whose URL of current tab is marker)
            if (count of marked) is not 1 then return "none"
            set madeId to item 1 of marked
            set URL of current tab of window id madeId to target
        end tell
        return madeId as text
    end run
    """

/// The window Safari's answer names, if it named one.
func pinPageSafariMadeWindow(_ answer: String) -> UInt32? {
    UInt32(answer.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// A Chromium browser: a new normal window showing `item 1 of argv`. Nothing ties the browser's
/// windows to the window server's, so this window is only opened, never taken for the pin: it goes
/// where any new window goes, which is the pin while the pin is the empty tab in front.
func pinPageChromiumOpenScript(bundleId: String) -> String {
    """
    on run argv
        tell application id "\(bundleId)"
            set w to make new window with properties {mode:"normal"}
            set URL of active tab of w to (item 1 of argv)
        end tell
        return "ok"
    end run
    """
}

/// A Chromium browser: the mode of each of its windows, one per line. No window's address is asked for.
func pinPageChromiumModeScript(bundleId: String) -> String {
    """
    on run argv
        tell application id "\(bundleId)"
            set modes to (get mode of every window)
        end tell
        set AppleScript's text item delimiters to character id 10
        return modes as text
    end run
    """
}

/// What the browser's answer says of all its windows: normal if every one is, private if any isn't,
/// unknown if it named none.
func pinPageChromiumPrivacy(_ answer: String) -> PinPagePrivacy {
    let modes = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if modes.isEmpty { return .unknown }
    return modes.allSatisfy { $0 == "normal" } ? .normal : .private
}
