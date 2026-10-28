@testable import AppBundle
import AppKit
import XCTest

final class AxAppPopupTest: XCTestCase {
    @MainActor
    func testUpstreamAppCaptures() throws {
        let url = projectRoot.appending(path: "test-fixtures/accessibility/upstream-app-popups.json")
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(records.count, 8)
        for record in records {
            let name = try XCTUnwrap(record["name"] as? String)
            let bundleId = try XCTUnwrap(KnownBundleId(rawValue: XCTUnwrap(record["bundleId"] as? String)))
            let expected = try XCTUnwrap(AxUiElementWindowType(rawValue: XCTUnwrap(record["expectedType"] as? String)))
            let app = PopupAxElement(role: kAXApplicationRole)
            let window = PopupAxElement(role: try XCTUnwrap(record["AXRole"] as? String))
                .put(Ax.parentAttr, app)
                .put(Ax.subroleAttr, try XCTUnwrap(record["AXSubrole"] as? String))
                .put(Ax.isFocused, try XCTUnwrap(record["AXFocused"] as? Bool))
                .put(Ax.isMainAttr, try XCTUnwrap(record["AXMain"] as? Bool))
            let buttons = try XCTUnwrap(record["windowButtons"] as? [String: [String: Bool]])
            for (key, attributes) in buttons {
                let button = PopupAxElement(role: kAXButtonRole).put(Ax.enabledAttr, try XCTUnwrap(attributes["AXEnabled"]))
                switch key {
                    case Ax.closeButtonAttr.key: window.put(Ax.closeButtonAttr, button)
                    case Ax.fullscreenButtonAttr.key: window.put(Ax.fullscreenButtonAttr, button)
                    case Ax.minimizeButtonAttr.key: window.put(Ax.minimizeButtonAttr, button)
                    case Ax.zoomButtonAttr.key: window.put(Ax.zoomButtonAttr, button)
                    default: XCTFail("Unknown captured button: \(key)")
                }
            }
            let level: MacOsWindowLevel
            switch record["windowLevel"] as? String {
                case "normalWindow": level = .normalWindow
                case "alwaysOnTopWindow": level = .alwaysOnTopWindow
                default: level = .new(windowLevel: try XCTUnwrap(record["windowLevel"] as? Int))
            }
            let policy: NSApplication.ActivationPolicy = record["activationPolicy"] as? String == "accessory" ? .accessory : .regular
            XCTAssertEqual(window.getWindowType(axApp: app, bundleId, policy, level), expected, name)
        }
    }

    func testOrdinaryWindowsFromPopupAppsRemainManaged() {
        let app = PopupAxElement(role: kAXApplicationRole)
        let enabled = PopupAxElement(role: kAXButtonRole).put(Ax.enabledAttr, true)
        let window = PopupAxElement(role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.closeButtonAttr, enabled)
            .put(Ax.fullscreenButtonAttr, enabled)
            .put(Ax.minimizeButtonAttr, enabled)
            .put(Ax.zoomButtonAttr, enabled)
        for id in [KnownBundleId.outlook, .codex, .wisprFlow, .emacs] {
            for policy in [NSApplication.ActivationPolicy.regular, .accessory] {
                XCTAssertEqual(window.getWindowType(axApp: app, id, policy, .normalWindow), .window, id.rawValue)
            }
        }
    }

    func testElevatedAppOverlaysStayPopupEvenWhenFocused() {
        let app = PopupAxElement(role: kAXApplicationRole)
        let window = PopupAxElement(role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.isFocused, true)
            .put(Ax.isMainAttr, true)
        for id in [KnownBundleId.outlook, .codex, .wisprFlow] {
            for policy in [NSApplication.ActivationPolicy.regular, .accessory] {
                for level in [MacOsWindowLevel.alwaysOnTopWindow, .unknown(windowLevel: 1000)] {
                    XCTAssertEqual(window.getWindowType(axApp: app, id, policy, level), .popup, id.rawValue)
                }
            }
        }
    }

    func testEmacsChildFramesStayPopupAndOtherAppsKeepFloatingDialogs() {
        let app = PopupAxElement(role: kAXApplicationRole)
        let window = PopupAxElement(role: kAXWindowRole)
            .put(Ax.parentAttr, app)
            .put(Ax.subroleAttr, kAXFloatingWindowSubrole)
            .put(Ax.closeButtonAttr, PopupAxElement(role: kAXButtonRole))
        for main in [false, true] {
            window.put(Ax.isMainAttr, main)
            window.put(Ax.isFocused, main)
            XCTAssertEqual(window.getWindowType(axApp: app, .emacs, .regular, .normalWindow), .popup)
            XCTAssertEqual(window.getWindowType(axApp: app, nil, .regular, .normalWindow), .dialog)
        }
    }

    func testAppSpecificPredicatesKeepAttachedTransientProtection() {
        let app = PopupAxElement(role: kAXApplicationRole)
        let owner = PopupAxElement(role: kAXWindowRole).put(Ax.parentAttr, app)
        let sheet = PopupAxElement(role: kAXSheetRole)
            .put(Ax.parentAttr, owner)
            .put(Ax.subroleAttr, kAXStandardWindowSubrole)
            .put(Ax.isFocused, true)
            .put(Ax.fullscreenButtonAttr, PopupAxElement(role: kAXButtonRole).put(Ax.enabledAttr, true))
        for id in [KnownBundleId.outlook, .codex, .wisprFlow, .emacs, .openAndSavePanelService] {
            XCTAssertEqual(sheet.getWindowType(axApp: app, id, .regular, .normalWindow), .popup, id.rawValue)
        }
    }
}

private final class PopupAxElement: AxUiElementMock {
    private var attributes: [String: Any] = [:]

    init(role: String) {
        attributes[Ax.roleAttr.key] = role
    }

    @discardableResult
    func put<Attr: ReadableAttr>(_ attr: Attr, _ value: Attr.T) -> Self {
        attributes[attr.key] = value
        return self
    }

    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? {
        attributes[attr.key] as? Attr.T
    }

    func containingWindowId() -> CGWindowID? { 1 }
}
