import AppKit
import Common
import PrivateApi

protocol ReadableAttr: Sendable {
    associatedtype T
    var getter: @Sendable (AnyObject) -> T? { get }
    var key: String { get }
}

protocol WritableAttr: ReadableAttr, Sendable {
    var setter: @Sendable (T) -> CFTypeRef? { get }
}

// Quick reference:
//
// // informational attributes
// kAXRoleAttribute
// kAXSubroleAttribute
// kAXRoleDescriptionAttribute
// kAXTitleAttribute
// kAXDescriptionAttribute
// kAXHelpAttribute
//
// // hierarchy or relationship attributes
// kAXParentAttribute
// kAXChildrenAttribute
// kAXSelectedChildrenAttribute
// kAXVisibleChildrenAttribute
// kAXWindowAttribute
// kAXTopLevelUIElementAttribute
// kAXTitleUIElementAttribute
// kAXServesAsTitleForUIElementsAttribute
// kAXLinkedUIElementsAttribute
// kAXSharedFocusElementsAttribute
//
// // visual state attributes
// kAXEnabledAttribute
// kAXFocusedAttribute
// kAXPositionAttribute
// kAXSizeAttribute
//
// // value attributes
// kAXValueAttribute
// kAXValueDescriptionAttribute
// kAXMinValueAttribute
// kAXMaxValueAttribute
// kAXValueIncrementAttribute
// kAXValueWrapsAttribute
// kAXAllowedValuesAttribute
//
// // text-specific attributes
// kAXSelectedTextAttribute
// kAXSelectedTextRangeAttribute
// kAXSelectedTextRangesAttribute
// kAXVisibleCharacterRangeAttribute
// kAXNumberOfCharactersAttribute
// kAXSharedTextUIElementsAttribute
// kAXSharedCharacterRangeAttribute
//
// // window, sheet, or drawer-specific attributes
// kAXMainAttribute
// kAXMinimizedAttribute
// kAXCloseButtonAttribute
// kAXZoomButtonAttribute
// kAXMinimizeButtonAttribute
// kAXToolbarButtonAttribute
// kAXProxyAttribute
// kAXGrowAreaAttribute
// kAXModalAttribute
// kAXDefaultButtonAttribute
// kAXCancelButtonAttribute
//
// // menu or menu item-specific attributes
// kAXMenuItemCmdCharAttribute
// kAXMenuItemCmdVirtualKeyAttribute
// kAXMenuItemCmdGlyphAttribute
// kAXMenuItemCmdModifiersAttribute
// kAXMenuItemMarkCharAttribute
// kAXMenuItemPrimaryUIElementAttribute
//
// // application element-specific attributes
// kAXMenuBarAttribute
// kAXWindowsAttribute
// kAXFrontmostAttribute
// kAXHiddenAttribute
// kAXMainWindowAttribute
// kAXFocusedWindowAttribute
// kAXFocusedUIElementAttribute
// kAXExtrasMenuBarAttribute
//
// // date/time-specific attributes
// kAXHourFieldAttribute
// kAXMinuteFieldAttribute
// kAXSecondFieldAttribute
// kAXAMPMFieldAttribute
// kAXDayFieldAttribute
// kAXMonthFieldAttribute
// kAXYearFieldAttribute
//
// // table, outline, or browser-specific attributes
// kAXRowsAttribute
// kAXVisibleRowsAttribute
// kAXSelectedRowsAttribute
// kAXColumnsAttribute
// kAXVisibleColumnsAttribute
// kAXSelectedColumnsAttribute
// kAXSortDirectionAttribute
// kAXColumnHeaderUIElementsAttribute
// kAXIndexAttribute
// kAXDisclosingAttribute
// kAXDisclosedRowsAttribute
// kAXDisclosedByRowAttribute
//
// // matte-specific attributes
// kAXMatteHoleAttribute
// kAXMatteContentUIElementAttribute
//
// // ruler-specific attributes
// kAXMarkerUIElementsAttribute
// kAXUnitsAttribute
// kAXUnitDescriptionAttribute
// kAXMarkerTypeAttribute
// kAXMarkerTypeDescriptionAttribute
//
// // miscellaneous or role-specific attributes
// kAXHorizontalScrollBarAttribute
// kAXVerticalScrollBarAttribute
// kAXOrientationAttribute
// kAXHeaderAttribute
// kAXEditedAttribute
// kAXTabsAttribute
// kAXOverflowButtonAttribute
// kAXFilenameAttribute
// kAXExpandedAttribute
// kAXSelectedAttribute
// kAXSplittersAttribute
// kAXContentsAttribute
// kAXNextContentsAttribute
// kAXPreviousContentsAttribute
// kAXDocumentAttribute
// kAXIncrementorAttribute
// kAXDecrementButtonAttribute
// kAXIncrementButtonAttribute
// kAXColumnTitleAttribute
// kAXURLAttribute
// kAXLabelUIElementsAttribute
// kAXLabelValueAttribute
// kAXShownMenuUIElementAttribute
// kAXIsApplicationRunningAttribute
// kAXFocusedApplicationAttribute
// kAXElementBusyAttribute
// kAXAlternateUIVisibleAttribute
enum Ax {
    struct ReadableAttrImpl<T>: ReadableAttr {
        var key: String
        var getter: @Sendable (AnyObject) -> T?
    }

    struct WritableAttrImpl<T>: WritableAttr {
        var key: String
        var getter: @Sendable (AnyObject) -> T?
        var setter: @Sendable (T) -> CFTypeRef?
    }

    static let titleAttr = WritableAttrImpl<String>(
        key: kAXTitleAttribute,
        getter: { $0 as? String },
        setter: { $0 as CFTypeRef },
    )
    static let roleAttr = WritableAttrImpl<String>(
        key: kAXRoleAttribute,
        getter: { $0 as? String },
        setter: { $0 as CFTypeRef },
    )
    static let subroleAttr = WritableAttrImpl<String>(
        key: kAXSubroleAttribute,
        getter: { $0 as? String },
        setter: { $0 as CFTypeRef },
    )
    static let identifierAttr = ReadableAttrImpl<String>(
        key: kAXIdentifierAttribute,
        getter: { $0 as? String },
    )
    /// The URL, as a string, of the document a window shows: a file for a document app, a page for a
    /// browser, or none.
    static let documentAttr = ReadableAttrImpl<String>(
        key: kAXDocumentAttribute,
        getter: { $0 as? String },
    )
    static let parentAttr = ReadableAttrImpl<any AxUiElementMock>(
        key: kAXParentAttribute,
        getter: castToAxUiElementMock,
    )
    // static let modalAttr = ReadableAttrImpl<Bool>(
    //     key: kAXModalAttribute,
    //     getter: { $0 as? Bool },
    // )
    static let enabledAttr = ReadableAttrImpl<Bool>(
        key: kAXEnabledAttribute,
        getter: { $0 as? Bool },
    )
    static let enhancedUserInterfaceAttr = WritableAttrImpl<Bool>(
        key: "AXEnhancedUserInterface",
        getter: { $0 as? Bool },
        setter: { $0 as CFTypeRef },
    )
    static let minimizedAttr = WritableAttrImpl<Bool>(
        key: kAXMinimizedAttribute,
        getter: { $0 as? Bool },
        setter: { $0 as CFTypeRef },
    )
    //static let minimizedAttr = ReadableAttrImpl<Bool>(
    //    key: kAXMinimizedAttribute,
    //    getter: { $0 as? Bool }
    //)
    static let isFullscreenAttr = WritableAttrImpl<Bool>(
        key: "AXFullScreen",
        getter: { $0 as? Bool },
        setter: { $0 as CFTypeRef },
    )
    static let isFocused = ReadableAttrImpl<Bool>(
        key: kAXFocusedAttribute,
        getter: { $0 as? Bool },
    )
    static let isMainAttr = WritableAttrImpl<Bool>(
        key: kAXMainAttribute,
        getter: { $0 as? Bool },
        setter: { $0 as CFTypeRef },
    )
    static let sizeAttr = WritableAttrImpl<CGSize>(
        key: kAXSizeAttribute,
        getter: {
            var raw: CGSize = .zero
            check(AXValueGetValue($0 as! AXValue, .cgSize, &raw))
            return raw
        },
        setter: {
            var size = $0
            return AXValueCreate(.cgSize, &size) as CFTypeRef
        },
    )
    static let topLeftCornerAttr = WritableAttrImpl<CGPoint>(
        key: kAXPositionAttribute,
        getter: {
            var raw: CGPoint = .zero
            AXValueGetValue($0 as! AXValue, .cgPoint, &raw)
            return raw
        },
        setter: {
            var size = $0
            return AXValueCreate(.cgPoint, &size) as CFTypeRef
        },
    )
    /// Returns windows visible on all monitors
    /// If some windows are located on not active macOS Spaces then they won't be returned
    static let windowsAttr = ReadableAttrImpl<[WindowIdAndAxUiElement]>(
        key: kAXWindowsAttribute,
        getter: { ($0 as? NSArray)?.compactMap(windowOrNil).map { ($0.windowId, $0.ax.cast) } ?? [] },
    )
    /// The same windows, read in full: nil (not read) when the answer isn't a list, or when an element's window id
    /// didn't come in time, so a window it leaves out is one the app doesn't list (`refreshRegisteredAxWindows`).
    /// Elements that aren't windows (Finder's desktop) are left out, as `windowsAttr` does.
    static let windowsInFullAttr = ReadableAttrImpl<[WindowIdAndAxUiElement]>(
        key: kAXWindowsAttribute,
        getter: { windowsInFull($0) },
    )
    static let focusedWindowAttr = ReadableAttrImpl<WindowIdAndAxUiElementMock>(
        key: kAXFocusedWindowAttribute,
        getter: windowOrNil,
    )
    //static let mainWindowAttr = ReadableAttrImpl<AXUIElement>(
    //    key: kAXMainWindowAttribute,
    //    getter: tryGetWindow
    //)
    static let menuBarAttr = ReadableAttrImpl<AXUIElement>(
        key: kAXMenuBarAttribute,
        getter: { CFGetTypeID($0 as CFTypeRef) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil },
    )
    static let childrenAttr = ReadableAttrImpl<[AXUIElement]>(
        key: kAXChildrenAttribute,
        // Element by element, so one unexpected child doesn't hide the rest.
        getter: { ($0 as? NSArray)?.compactMap { child in
            CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
        } },
    )
    /// The same children, readable through `AxUiElementMock`, so tests can supply them.
    static let childElementsAttr = ReadableAttrImpl<[any AxUiElementMock]>(
        key: kAXChildrenAttribute,
        getter: { ($0 as? NSArray)?.compactMap { child -> (any AxUiElementMock)? in
            CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
        } },
    )
    static let closeButtonAttr = ReadableAttrImpl<any AxUiElementMock>(
        key: kAXCloseButtonAttribute,
        getter: castToAxUiElementMock,
    )
    // Note! fullscreen is not the same as "zoom" (green plus)
    static let fullscreenButtonAttr = ReadableAttrImpl<any AxUiElementMock>(
        key: kAXFullScreenButtonAttribute,
        getter: castToAxUiElementMock,
    )
    // green plus
    static let zoomButtonAttr = ReadableAttrImpl<any AxUiElementMock>(
        key: kAXZoomButtonAttribute,
        getter: castToAxUiElementMock,
    )
    static let minimizeButtonAttr = ReadableAttrImpl<any AxUiElementMock>(
        key: kAXMinimizeButtonAttribute,
        getter: castToAxUiElementMock,
    )
    //static let growAreaAttr = ReadableAttrImpl<AXUIElement>(
    //    key: kAXGrowAreaAttribute,
    //    getter: { ($0 as! AXUIElement) }
    //)
}

let kAXWinMuxSynthetic = "WinMux.synthetic"

private func castToAxUiElementMock(_ a: AnyObject) -> AxUiElementMock {
    if isUnitTest {
        if let str = a as? String, let commaIndex = str.firstIndex(of: ",") {
            let windowId = UInt32.init(String(str.prefix(upTo: commaIndex)).removePrefix("AXUIElement(AxWindowId="))
            if let windowId {
                return castToAxUiElementMock([
                    "WinMux.axWindowId": Json.uint32(windowId),
                    kAXWinMuxSynthetic: Json.bool(true),
                ] as AnyObject)
            }
        }
        if let dict = a as? [String: Json] { // Convert from _SwiftDeferredNSDictionary<String, Json>
            return dict as? AxUiElementMock ?? dieT("Cannot cast \(type(of: a)) to AxUiElementMock")
        }
        die("Can't convert \(a) to AxUiElementMock")
    }
    return a as! AXUIElement
}

typealias WindowIdAndAxUiElement = (windowId: UInt32, ax: AXUIElement)

/// `Ax.windowsInFullAttr`'s windows, each element's window id asked of `windowId`.
func windowsInFull(_ raw: AnyObject, windowId: (AXUIElement) -> (windowId: CGWindowID?, error: AXError) = {
    AXUIElementSetMessagingTimeout($0, 1.0) // As AxWindow.new: not the 6s global default
    return $0.containingWindowIdWithError()
}) -> [WindowIdAndAxUiElement]? {
    guard let elements = raw as? NSArray else { return nil }
    var windows: [WindowIdAndAxUiElement] = []
    for element in elements {
        guard CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID() else { continue }
        let ax = element as! AXUIElement
        let (id, error) = windowId(ax)
        if error == .cannotComplete { return nil }
        if let id { windows.append((id, ax)) }
    }
    return windows
}
typealias WindowIdAndAxUiElementMock = (windowId: UInt32, ax: AxUiElementMock)

private func windowOrNil(_ any: Any?) -> WindowIdAndAxUiElementMock? {
    guard let any else { return nil }
    let potentialWindow = castToAxUiElementMock(any as AnyObject)
    // Filter out non-window objects (e.g. Finder's desktop)
    let windowId = potentialWindow.containingWindowId()
    if let windowId {
        return (windowId, potentialWindow)
    } else {
        return nil
    }
}

extension AXUIElement: AxUiElementMock {
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        let state = signposter.beginInterval(#function, "attr: \(attr.key) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
        defer { signposter.endInterval(#function, state) }
        var raw: AnyObject?
        return AXUIElementCopyAttributeValue(self, attr.key as CFString, &raw) == .success
            ? raw.flatMap(attr.getter)
            : nil
    }

    @discardableResult func set<Attr: WritableAttr>(_ attr: Attr, _ value: Attr.T) -> Bool {
        if serverArgs.isReadOnly { return false }
        let state = signposter.beginInterval(#function, "attr: \(attr.key) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
        defer { signposter.endInterval(#function, state) }
        guard let value = attr.setter(value) else { return false }
        return AXUIElementSetAttributeValue(self, attr.key as CFString, value) == .success
    }

    func containingWindowId() -> CGWindowID? {
        let state = signposter.beginInterval(#function, "axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
        defer { signposter.endInterval(#function, state) }
        var cgWindowId = CGWindowID()
        let error = _AXUIElementGetWindow(self, &cgWindowId)
        return validAxWindowId(cgWindowId, error: error)
    }

    /// Like containingWindowId, with the AXError: a timeout (.cannotComplete, a busy app) is told apart from an element
    /// that answers for nothing. Neither is proof the window closed (`windowLivenessVerdict`).
    func containingWindowIdWithError() -> (windowId: CGWindowID?, error: AXError) {
        let state = signposter.beginInterval(#function, "axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
        defer { signposter.endInterval(#function, state) }
        var cgWindowId = CGWindowID()
        let error = _AXUIElementGetWindow(self, &cgWindowId)
        return (validAxWindowId(cgWindowId, error: error), error)
    }
}

extension AXObserver {
    static func new(_ pid: pid_t, _ handler: AXObserverCallback) -> AXObserver? {
        var observer: AXObserver? = nil
        return AXObserverCreate(pid, handler, &observer) == .success ? observer : nil
    }
}

/// AX can report success for a non-window UI element while returning the reserved ID zero, which Apple calls "a
/// guaranteed invalid window ID": no window (upstream AeroSpace 0f6b2e78). The AX error is kept separately
/// (`registeredAxWindowAnswer`).
func validAxWindowId(_ windowId: CGWindowID, error: AXError) -> CGWindowID? {
    error == .success && windowId != kCGNullWindowID ? windowId : nil
}

/// What a registered window's own AX query says about it.
enum RegisteredAxWindowAnswer: Equatable {
    /// AX resolves it to its window.
    case alive
    /// The app didn't answer in time: busy.
    case busy
    /// Its element answers for nothing: the window closed, or the element went stale while the window lives on.
    case gone
}

/// Whether AX resolves a registered window to a window ID, as upstream AeroSpace asks. A timeout is a busy app; any other
/// failure (no value, an unsupported attribute, an illegal argument, a failure, a successful zero ID, an invalid element)
/// is an element that answers for nothing. Neither proves the window closed: `windowLivenessVerdict` goes by the window
/// server and the app's AXWindows for that.
func registeredAxWindowAnswer(windowId: CGWindowID?, error: AXError) -> RegisteredAxWindowAnswer {
    if windowId != nil { return .alive }
    return error == .cannotComplete ? .busy : .gone
}
