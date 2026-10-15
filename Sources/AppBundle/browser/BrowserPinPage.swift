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
// browser's own answer to `mode`.

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

/// At most this many elements are read looking for a Safari window's page or its private marker.
private let pinPageReadLimit = 400

/// Reads `window` of a browser of `adapter`'s kind. Runs on the app's AX thread.
func readPinPageWindow(_ window: AXUIElement, adapter: BrowserTabAdapter) -> PinPageWindowRead {
    AXUIElementSetMessagingTimeout(window, 0.2)
    defer { AXUIElementSetMessagingTimeout(window, 1.0) }
    let title = pinPageString(window, kAXTitleAttribute)
    switch adapter {
        case .chromium:
            let incognito = title?.contains("(Incognito)") == true
            return .init(url: pinPageString(window, kAXDocumentAttribute), title: title, privacy: incognito ? .private : .unknown)
        case .safari:
            var urls: [String] = []
            var privacy: PinPagePrivacy = title?.hasSuffix(", Private Browsing") == true ? .private : .unknown
            var sawToolbar = false
            var queue: [(element: AXUIElement, inToolbar: Bool)] = [(window, false)]
            var visited = 0
            while !queue.isEmpty, visited < pinPageReadLimit {
                let (element, inToolbar) = queue.removeFirst()
                visited += 1
                AXUIElementSetMessagingTimeout(element, 0.1)
                let role = pinPageString(element, kAXRoleAttribute)
                if role == "AXWebArea" {
                    // A page's frames are inside its own area, never read as pages of their own.
                    if let url = pinPageString(element, "AXURL"), !urls.contains(url) { urls.append(url) }
                    continue
                }
                let isToolbar = role == kAXToolbarRole
                if isToolbar { sawToolbar = true }
                if inToolbar || isToolbar, pinPageString(element, kAXIdentifierAttribute) == "Private" { privacy = .private }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                      let list = children as? [AXUIElement] else { continue }
                for child in list { queue.append((child, inToolbar || isToolbar)) }
            }
            if privacy == .unknown, sawToolbar { privacy = .normal }
            return .init(url: urls.count == 1 ? urls[0] : nil, title: title, privacy: privacy, showsSeveralPages: urls.count > 1)
    }
}

private func pinPageString(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
    if let string = value as? String { return string }
    if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! NSURL).absoluteString }
    return nil
}

/// The windows a process lists for accessibility, by number: what a person sees as its windows, never
/// the helper windows a browser keeps off screen (a new Chrome window brings four). Nil when the
/// process didn't answer. Safe off the main thread.
nonisolated func pinPageAXWindowNumbers(pid: Int32) -> Set<UInt32>? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
          let windows = raw as? [AXUIElement] else { return nil }
    return Set(windows.compactMap { $0.containingWindowId() })
}

/// The title a browser gives a window, without the browser's own name or private suffix.
func pinPageDisplayTitle(_ title: String?, appName: String?) -> String? {
    guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
    for suffix in [", Private Browsing", " (Incognito)"] where title.hasSuffix(suffix) { title.removeLast(suffix.count) }
    if let appName, title.hasSuffix(" - \(appName)") { title.removeLast(appName.count + 3) }
    return title.isEmpty ? nil : title
}

// MARK: - The browsers' own answers

/// Safari: a new window showing `item 1 of argv`, and which window that is, by Safari's own count of its
/// windows before and after, in one script: "<new windows' numbers>;<front window's number>". Safari's
/// window numbers are the window server's. `make new document` always makes a window, even for an
/// address another window shows.
let pinPageSafariOpenScript = """
    on run argv
        tell application id "com.apple.Safari"
            set known to (get id of every window)
            make new document with properties {URL:(item 1 of argv)}
            set current to (get id of every window)
            set frontId to (get id of front window)
        end tell
        set made to {}
        repeat with candidate in current
            if known does not contain (contents of candidate) then set end of made to (contents of candidate)
        end repeat
        set AppleScript's text item delimiters to ","
        return (made as text) & ";" & frontId
    end run
    """

/// The window Safari's answer names: one new window only, and the one in front. Nil otherwise.
func pinPageSafariMadeWindow(_ answer: String) -> UInt32? {
    let parts = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ";", omittingEmptySubsequences: false)
    guard parts.count == 2, let front = UInt32(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    let made = parts[0].split(separator: ",").map { UInt32($0.trimmingCharacters(in: .whitespaces)) }
    guard made.count == 1, let window = made[0], window == front else { return nil }
    return window
}

/// A Chromium browser: a new window, its selected tab sent to `item 1 of argv`. Its answer names the
/// browser's own window, not the window server's, so the window is told by the browser's windows.
func pinPageChromiumOpenScript(bundleId: String) -> String {
    """
    on run argv
        tell application id "\(bundleId)"
            set w to make new window
            set URL of active tab of w to (item 1 of argv)
        end tell
        return "ok"
    end run
    """
}

/// A Chromium browser: the mode and selected address of each of its windows whose selected tab may be
/// `item 1 of argv`, one per line: "normal<TAB>address". The browser matches letter case loosely, so
/// the address is compared again exactly; no other window's address is asked for.
func pinPageChromiumModeScript(bundleId: String) -> String {
    """
    on run argv
        set wanted to item 1 of argv
        set separator to character id 9
        set answer to {}
        tell application id "\(bundleId)"
            repeat with candidate in (get every window whose URL of active tab is wanted)
                set end of answer to ((mode of candidate) & separator & (URL of active tab of candidate))
            end repeat
        end tell
        set AppleScript's text item delimiters to character id 10
        return answer as text
    end run
    """
}

/// What the browser's answer says of the windows whose selected tab is exactly `url`: private if any is,
/// normal if each says so, unknown if none shows it.
func pinPageChromiumPrivacy(_ answer: String, url: String) -> PinPagePrivacy {
    let modes = answer.split(whereSeparator: \.isNewline).compactMap { line -> Substring? in
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return fields.count == 2 && fields[1] == url ? fields[0] : nil
    }
    if modes.isEmpty { return .unknown }
    return modes.allSatisfy { $0 == "normal" } ? .normal : .private
}
