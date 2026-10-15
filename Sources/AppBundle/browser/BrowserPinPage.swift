import AppKit

// What a browser window shows, for a pinned page: the address of its selected tab and whether it's a
// private window, read from that window alone, never from whichever window is in front.
//
// Safari 27 reports no AXDocument for its windows. The selected tab's page is the window's AXWebArea,
// whose AXURL is the full address; Safari builds that part of its tree only once something asks, so
// the first read can miss it. A private window has a toolbar element identified `Private`, whatever
// the language, and its title ends in ", Private Browsing" in English. Chromium browsers report the
// selected tab's address as the window's AXDocument, Incognito windows too; their title says
// "(Incognito)" in English only, so a Chromium window is known not to be private only from the
// browser's own answer to `mode`, which a window keeps for its life, found by the window's frame: the
// browser's `bounds` of a window are its accessibility frame.

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
    /// The window's frame, top-left origin, as accessibility reports it; read for Chromium browsers.
    var frame: CGRect? = nil
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
    /// The element's frame, top-left origin; nil when it couldn't be read.
    func frame() -> CGRect?
}

extension PinPageAXNode {
    func frame() -> CGRect? { nil }
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

    func frame() -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
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
            return .init(url: window.text(kAXDocumentAttribute).value, title: title, privacy: incognito ? .private : .unknown,
                frame: window.frame())
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

/// The windows of process `pid` that show exactly `url`, by number, read from each window by
/// accessibility whether or not WinMux has registered it. Nil when the process didn't list its windows.
/// Safe off the main thread.
nonisolated func pinPageAXWindowsShowing(pid: Int32, url: String, adapter: BrowserTabAdapter) -> [UInt32]? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
          let windows = raw as? [AXUIElement] else { return nil }
    return windows.compactMap { window in
        guard readPinPageWindow(NativePinPageNode(element: window), adapter: adapter).url == url else { return nil }
        return window.containingWindowId()
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

/// A Chromium browser: a new normal window showing the marker `item 1 of argv`. Its answer is the
/// browser's own number for that window, which isn't the window server's: the window is found by the
/// marker it shows, then sent to the page by this number.
func pinPageChromiumOpenScript(bundleId: String) -> String {
    """
    on run argv
        tell application id "\(bundleId)"
            set w to make new window with properties {mode:"normal"}
            set URL of active tab of w to (item 1 of argv)
            return (id of w) as text
        end tell
    end run
    """
}

/// A Chromium browser: the window it numbers `item 1 of argv`, sent to `item 2 of argv`.
func pinPageChromiumGoScript(bundleId: String) -> String {
    """
    on run argv
        tell application id "\(bundleId)"
            set URL of active tab of (window id ((item 1 of argv) as integer)) to (item 2 of argv)
        end tell
        return "ok"
    end run
    """
}

/// The browser's own number for the window its answer names, if any.
func pinPageChromiumWindowNumber(_ answer: String) -> String? {
    let number = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    return !number.isEmpty && number.allSatisfy(\.isNumber) ? number : nil
}

/// A Chromium browser: the mode and bounds of each of its windows, one per line: "normal<TAB>l,t,r,b".
/// No window's address is asked for.
func pinPageChromiumModeScript(bundleId: String) -> String {
    """
    on run argv
        set separator to character id 9
        set answer to {}
        tell application id "\(bundleId)"
            repeat with candidate in (get every window)
                set {x1, y1, x2, y2} to bounds of candidate
                set end of answer to ((mode of candidate) & separator & x1 & "," & y1 & "," & x2 & "," & y2)
            end repeat
        end tell
        set AppleScript's text item delimiters to character id 10
        return answer as text
    end run
    """
}

/// What the browser's answer says of the window whose frame is `frame`: a window keeps its mode for its
/// life, and the browser's bounds of a window are its accessibility frame. Private if any window there
/// is Incognito, normal if each window there is normal, unknown if none is there.
func pinPageChromiumPrivacy(_ answer: String, frame: CGRect) -> PinPagePrivacy {
    let wanted = [frame.minX, frame.minY, frame.maxX, frame.maxY].map { Int($0.rounded()) }
    let modes = answer.split(whereSeparator: \.isNewline).compactMap { line -> Substring? in
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let bounds = fields[1].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 4, !bounds.contains(nil) else { return nil }
        let isThere = zip(bounds.compactMap { $0 }.map { Int($0.rounded()) }, wanted).allSatisfy { abs($0 - $1) <= 1 }
        return isThere ? fields[0] : nil
    }
    if modes.isEmpty { return .unknown }
    return modes.allSatisfy { $0 == "normal" } ? .normal : .private
}
