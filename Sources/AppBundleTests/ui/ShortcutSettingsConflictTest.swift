@testable import AppBundle
import XCTest

@MainActor
final class ShortcutSettingsConflictTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        setUpWorkspacesForTests()
        ShortcutSettingsModel.shared.reload()
    }

    func testOnlyCustomCommandBindingsBlockAManagedShortcut() {
        let (parsed, errors) = parseConfig(
            """
            [mode.main.binding]
                alt-h = 'focus left'
                alt-1 = 'workspace 1'
                cmd-shift-x = 'reload-config'
            """,
        )
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        config.modes = parsed.modes
        let model = ShortcutSettingsModel.shared
        model.reload()

        // A managed shortcut moves to the new action or workspace instead of conflicting.
        XCTAssertNil(model.customCommandConflict(for: "alt-h"))
        XCTAssertNil(model.customWorkspaceConflict(for: "alt-h"))
        XCTAssertNil(model.customWorkspaceConflict(for: "alt-1"))
        // A custom command keeps its shortcut.
        XCTAssertEqual(model.customCommandConflict(for: "cmd-shift-x"), "reload-config")
        XCTAssertEqual(model.customWorkspaceConflict(for: "cmd-shift-x"), "reload-config")
        // An unbound shortcut is free.
        XCTAssertNil(model.customCommandConflict(for: "alt-j"))
        XCTAssertNil(model.customWorkspaceConflict(for: "alt-j"))
    }
}
