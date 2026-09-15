@testable import AppBundle
import AppKit
import XCTest

/// An actual Zen save-panel capture plus synthetic AX trees covering compatibility
/// cases and incomplete accessibility information not present in that capture.
final class AxTransientWindowTest: XCTestCase {
    @MainActor
    func testCapturedZenSaveSheetStaysTransientWhileAppReportsItAsFocusedWindow() throws {
        let url = projectRoot.appending(path: "test-fixtures/accessibility/zen-1.21.16b-save-panel.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let browser = try capturedElement(XCTUnwrap(fixture["browserWithSavePanel"] as? [String: Any]))
        XCTAssertEqual(fixture["saveSheetIsCanonicalAppWindow"] as? Bool, false)
        XCTAssertEqual(fixture["formatSheetIsCanonicalAppWindow"] as? Bool, false)

        for parentIsRegistered in [false, true] {
            for _ in 0 ..< 3 {
                for stage in ["saveSheet", "formatSheet"] {
                    let sheet = try capturedElement(XCTUnwrap(fixture[stage] as? [String: Any]))
                    let app = SyntheticAxElement(role: kAXApplicationRole)
                        .put(Ax.focusedWindowAttr, (windowId: UInt32(2), ax: sheet))
                    // This exact equality made the legacy Firefox heuristic accept the
                    // native sheet, even though AXFocused was false in the capture.
                    XCTAssertEqual(app.get(Ax.focusedWindowAttr)?.windowId, sheet.containingWindowId())
                    XCTAssertEqual(sheet.get(Ax.isFocused), false)
                    XCTAssertEqual(sheet.getWindowType(axApp: app, .zenBrowser, .regular, .normalWindow), .popup)
                    XCTAssertTrue(browser.isWindowHeuristic(axApp: app, .zenBrowser, .regular, .normalWindow))
                    let resolution = resolveAxFocusedWindow(sheet, isRegistered: { parentIsRegistered && $0 == 1 }, appWindows: {
                        XCTFail("A captured sheet must be rejected before enumeration, even when its parent is unknown")
                        return []
                    })
                    guard case .transient = resolution else { return XCTFail("Captured \(stage) must not register a new window") }
                }
            }
        }

        let serviceWindow = try capturedElement(XCTUnwrap(fixture["savePanelServiceWindow"] as? [String: Any]))
        let serviceApp = SyntheticAxElement(role: kAXApplicationRole)
        XCTAssertEqual(serviceWindow.getWindowType(axApp: serviceApp, .openAndSavePanelService, .regular, .normalWindow), .popup)
    }

    private func capturedElement(_ record: [String: Any]) throws -> SyntheticAxElement {
        let element = SyntheticAxElement(id: (record["windowId"] as? NSNumber)?.uint32Value, role: record["AXRole"] as? String)
        if let subrole = record["AXSubrole"] as? String { element.put(Ax.subroleAttr, subrole) }
        if let focused = record["AXFocused"] as? Bool { element.put(Ax.isFocused, focused) }
        if let main = record["AXMain"] as? Bool { element.put(Ax.isMainAttr, main) }
        if let identifier = record["AXIdentifier"] as? String { element.put(Ax.identifierAttr, identifier) }
        if let parent = record["parent"] as? [String: Any] { element.put(Ax.parentAttr, try capturedElement(parent)) }
        for name in record["windowButtons"] as? [String] ?? [] {
            let button = SyntheticAxElement(role: kAXButtonRole)
            switch name {
                case Ax.closeButtonAttr.key: element.put(Ax.closeButtonAttr, button)
                case Ax.fullscreenButtonAttr.key: element.put(Ax.fullscreenButtonAttr, button)
                case Ax.minimizeButtonAttr.key: element.put(Ax.minimizeButtonAttr, button)
                case Ax.zoomButtonAttr.key: element.put(Ax.zoomButtonAttr, button)
                default: XCTFail("Unrecognized captured window button: \(name)")
            }
        }
        return element
    }

    func testFocusedAttachedUIIsNeverPromotedByFirefoxHeuristic() {
        for role in [kAXSheetRole, kAXMenuRole, kAXMenuItemRole, kAXPopUpButtonRole, kAXGroupRole] {
            let element = SyntheticAxElement(id: 1, role: role)
                .put(Ax.subroleAttr, kAXStandardWindowSubrole)
                .put(Ax.isFocused, true)
                .put(Ax.isMainAttr, true)
                .put(Ax.closeButtonAttr, SyntheticAxElement(role: kAXButtonRole))
            let app = SyntheticAxElement(role: kAXApplicationRole)
                .put(Ax.focusedWindowAttr, (windowId: 1, ax: element))
            XCTAssertEqual(element.getWindowType(axApp: app, .zenBrowser, .regular, .normalWindow), .popup, role)
            XCTAssertEqual(element.getWindowType(axApp: app, .mozillaFirefox, .regular, .normalWindow), .popup, role)
        }
    }

    func testAttachedWindowBehindViewBridgeGroupsRemainsPopupWhenFocused() {
        let owner = SyntheticAxElement(id: 1, role: kAXWindowRole)
        let group = SyntheticAxElement(role: kAXGroupRole).put(Ax.parentAttr, owner)
        let attached = SyntheticAxElement(id: 2, role: kAXWindowRole)
            .put(Ax.parentAttr, group)
            .put(Ax.subroleAttr, kAXDialogSubrole)
        let app = SyntheticAxElement(role: kAXApplicationRole)
        for focused in [false, true, false, true] {
            attached.put(Ax.isFocused, focused)
            XCTAssertEqual(attached.getWindowType(axApp: app, .zenBrowser, .regular, .normalWindow), .popup)
        }
    }

    func testIndependentWindowsDialogsAndFirefoxVideoWindowsRemainEligible() {
        let app = SyntheticAxElement(role: kAXApplicationRole)
        let enabledButton = SyntheticAxElement(role: kAXButtonRole).put(Ax.enabledAttr, true)
        let regular = SyntheticAxElement(id: 1, role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.minimizeButtonAttr, enabledButton)
            .put(Ax.fullscreenButtonAttr, enabledButton)
        XCTAssertEqual(regular.getWindowType(axApp: app, .zenBrowser, .regular, .normalWindow), .window)

        let dialog = SyntheticAxElement(id: 2, role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXDialogSubrole)
            .put(Ax.closeButtonAttr, enabledButton)
        XCTAssertEqual(dialog.getWindowType(axApp: app, .zenBrowser, .regular, .normalWindow), .dialog)

        let pictureInPicture = SyntheticAxElement(id: 3, role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.closeButtonAttr, enabledButton)
        XCTAssertEqual(pictureInPicture.getWindowType(axApp: app, .mozillaFirefox, .regular, .normalWindow), .dialog)

        let video = SyntheticAxElement(id: 4, role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXUnknownSubrole)
            .put(Ax.isFocused, true)
        XCTAssertEqual(video.getWindowType(axApp: app, .mozillaFirefox, .regular, .normalWindow), .dialog)
    }

    func testOpenAndSaveServiceWindowIsNeverIndependent() {
        let service = SyntheticAxElement(role: kAXApplicationRole)
        let window = SyntheticAxElement(id: 1, role: kAXWindowRole)
            .put(Ax.parentAttr, service)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.isFocused, true)
        XCTAssertEqual(window.getWindowType(axApp: service, .openAndSavePanelService, .regular, .normalWindow), .popup)
    }

    func testFocusedProxyUsesCanonicalEnumeratedWindow() {
        let proxy = SyntheticAxElement(id: 42, role: kAXUnknownRole)
        let canonical = SyntheticAxElement(id: 42, role: kAXWindowRole)
        let result = resolveAxFocusedWindow(proxy, isRegistered: { _ in false }, appWindows: { [(windowId: UInt32(42), ax: canonical)] })
        guard case .newWindow(let id, let element) = result else { return XCTFail("Expected canonical window") }
        XCTAssertEqual(id, 42)
        XCTAssertTrue((element as? SyntheticAxElement) === canonical)
    }

    func testFocusedControlAliasingKnownParentNeverRegistersOrResolvesAsParent() {
        let control = SyntheticAxElement(id: 42, role: kAXPopUpButtonRole).put(Ax.isFocused, true)
        let result = resolveAxFocusedWindow(control, isRegistered: { _ in true }, appWindows: {
            XCTFail("Attached controls should not need window enumeration")
            return []
        })
        guard case .transient = result else { return XCTFail("Expected native transient focus") }
    }

    func testKnownWindowDoesNotNeedEnumeration() {
        let known = SyntheticAxElement(id: 42, role: kAXWindowRole)
        let result = resolveAxFocusedWindow(known, isRegistered: { $0 == 42 }, appWindows: {
            XCTFail("Known windows must keep the registry fast path")
            return []
        })
        guard case .existing(42) = result else { return XCTFail("Expected existing window") }
    }

    func testNewWindowWithoutOwnershipEvidenceWaitsForEnumeration() {
        let unknown = SyntheticAxElement(id: 42, role: kAXWindowRole)
        let unresolved = resolveAxFocusedWindow(unknown, isRegistered: { _ in false }, appWindows: { [] })
        guard case .unavailable = unresolved else { return XCTFail("Missing ancestry must not be guessed") }
        let resolved = resolveAxFocusedWindow(unknown, isRegistered: { _ in false }, appWindows: { [(windowId: UInt32(42), ax: unknown)] })
        guard case .newWindow(42, _) = resolved else { return XCTFail("Enumeration should resolve the new window") }
    }

    func testApplicationOwnedNewWindowCanPrecedeEnumeration() {
        let app = SyntheticAxElement(role: kAXApplicationRole)
        let window = SyntheticAxElement(id: 42, role: kAXWindowRole).put(Ax.parentAttr, app)
        let resolved = resolveAxFocusedWindow(window, isRegistered: { _ in false }, appWindows: { [] })
        guard case .newWindow(42, _) = resolved else { return XCTFail("Expected independent application window") }
    }

    func testMissingAttributesAndCyclicParentsAreBounded() {
        let missing = SyntheticAxElement(id: 42)
        XCTAssertFalse(missing.isAttachedTransientHeuristic())
        let group = SyntheticAxElement(role: kAXGroupRole)
        group.put(Ax.parentAttr, group)
        let window = SyntheticAxElement(id: 42, role: kAXWindowRole).put(Ax.parentAttr, group)
        XCTAssertFalse(window.isAttachedTransientHeuristic())
        XCTAssertLessThanOrEqual(group.readCounts[Ax.parentAttr.key, default: 0], 8)
    }
}

private final class SyntheticAxElement: AxUiElementMock {
    private let id: UInt32?
    private var attributes: [String: Any] = [:]
    private(set) var readCounts: [String: Int] = [:]

    init(id: UInt32? = nil, role: String? = nil) {
        self.id = id
        attributes[Ax.roleAttr.key] = role
    }

    @discardableResult
    func put<Attr: ReadableAttr>(_ attr: Attr, _ value: Attr.T) -> Self {
        attributes[attr.key] = value
        return self
    }

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        readCounts[attr.key, default: 0] += 1
        return attributes[attr.key] as? Attr.T
    }

    func containingWindowId() -> CGWindowID? { id }
}
