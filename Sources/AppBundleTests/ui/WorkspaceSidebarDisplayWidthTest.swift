@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceSidebarDisplayWidthTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setUpWorkspacesForTests() }

    func testParsesEachDisplaysOwnWidth() {
        let (parsed, errors) = parseConfigForTests("""
            [workspace-sidebar]
            width = 240
            width-per-display = false

            [workspace-sidebar.display-widths]
            "Built-in Retina Display" = 220
            "DELL U3224KB 2" = 320
            "Display v2.0 \\"Pro\\"" = 300
            """)
        XCTAssertEqual(errors, [])
        XCTAssertFalse(parsed.workspaceSidebar.widthPerDisplay)
        XCTAssertEqual(parsed.workspaceSidebar.displayWidths,
            ["Built-in Retina Display": 220, "DELL U3224KB 2": 320, "Display v2.0 \"Pro\"": 300])
        XCTAssertTrue(defaultConfig.workspaceSidebar.widthPerDisplay, "Each display remembers its width by default")
        XCTAssertTrue(WorkspaceSidebarConfig().widthPerDisplay, "The built-in default matches default-config.toml")
        XCTAssertEqual(defaultConfig.workspaceSidebar.displayWidths, [:])
    }

    func testRejectsDisplayWidthsTheSharedWidthWouldReject() {
        let (_, errors) = parseConfigForTests("""
            [workspace-sidebar]
            always-expanded = true
            collapsed-width = 60
            display-widths = { "Wide" = 300, "Narrow" = 60, "Zero" = 0, "Text" = "wide" }
            """)
        XCTAssertEqual(Set(errors), [
            "workspace-sidebar.display-widths.Zero: Must be greater than 0",
            "workspace-sidebar.display-widths.Text: Expected type is 'Int'. But actual type is 'String'",
            "workspace-sidebar.display-widths.Narrow: Must be greater than collapsed-width while the panel is kept expanded",
        ])
        let tabs = "[workspace-sidebar]\nmode = 'tabs'\ncollapsed-width = 60\ndisplay-widths = { \"Narrow\" = 50 }"
        XCTAssertEqual(parseConfigForTests(tabs).errors,
            ["workspace-sidebar.display-widths.Narrow: Must be greater than collapsed-width while the panel is kept expanded"],
            "Tabs mode keeps its sidebar open by default")
        XCTAssertEqual(parseConfigForTests(tabs + "\ntabs-always-expanded = false").errors, [])
        XCTAssertEqual(parseConfigForTests("[workspace-sidebar]\ndisplay-widths = 300").errors,
            ["workspace-sidebar.display-widths: Expected type is 'Table'. But actual type is 'Int'"])
    }

    func testWidthsNarrowerThanTheModeFitsAreWidenedAtLoad() {
        let table = """
            width = 130
            [workspace-sidebar.display-widths]
            "Narrow" = 100
            "Wide" = 300
            """
        let tabs = parseConfigForTests("[workspace-sidebar]\nmode = 'tabs'\n" + table)
        XCTAssertEqual(tabs.errors, [], "A narrow width still loads")
        XCTAssertEqual(tabs.config.workspaceSidebar.width, 160)
        XCTAssertEqual(tabs.config.workspaceSidebar.displayWidths, ["Narrow": 160, "Wide": 300])
        XCTAssertEqual(tabs.config.workspaceSidebar.width(onDisplayNamed: "Narrow"), 160)
        XCTAssertEqual(tabs.config.workspaceSidebar.width(onDisplayNamed: "Other"), 160)

        let sidebar = parseConfigForTests("[workspace-sidebar]\nmode = 'sidebar'\n" + table).config.workspaceSidebar
        XCTAssertEqual(sidebar.width, 130, "Sidebar mode fits from 120")
        XCTAssertEqual(sidebar.displayWidths, ["Narrow": 120, "Wide": 300])

        let dock = parseConfigForTests("[workspace-sidebar]\nmode = 'dock'\n" + table).config.workspaceSidebar
        XCTAssertEqual(dock.width, 130)
        XCTAssertEqual(dock.displayWidths, ["Narrow": 100, "Wide": 300], "The Dock's column width is used as written")

        // Checks still read the file as written.
        let rejected = parseConfigForTests("[workspace-sidebar]\nmode = 'sidebar'\nalways-expanded = true\ncollapsed-width = 110\nwidth = 100")
        XCTAssertEqual(rejected.errors,
            ["workspace-sidebar.width: Must be greater than collapsed-width when always-expanded is true"])
    }

    func testOnlySidebarAndTabsPanelsUseADisplaysOwnWidth() {
        var settings = WorkspaceSidebarConfig(mode: .tabs)
        settings.width = 240
        settings.displayWidths = ["Left": 300]
        XCTAssertEqual(settings.width(onDisplayNamed: "Left"), 300)
        XCTAssertEqual(settings.width(onDisplayNamed: "Right"), 240, "A display not resized yet uses the shared width")
        XCTAssertEqual(settings.width(onDisplayNamed: nil), 240)
        XCTAssertEqual(settings.onDisplay(named: "Left").width, 300)
        XCTAssertEqual(settings.widthTarget(forDisplayNamed: "Right"), .display("Right"))
        settings.mode = .sidebar
        XCTAssertEqual(settings.width(onDisplayNamed: "Left"), 300)

        settings.mode = .dock
        XCTAssertEqual(settings.width(onDisplayNamed: "Left"), 240, "The Dock's width sizes project columns, which have no edge to drag")
        XCTAssertEqual(settings.widthTarget(forDisplayNamed: "Left"), .shared)

        settings.mode = .tabs
        settings.widthPerDisplay = false
        XCTAssertEqual(settings.width(onDisplayNamed: "Left"), 240, "Turned off, every display shares the width")
        XCTAssertEqual(settings.widthTarget(forDisplayNamed: "Left"), .shared)
        XCTAssertEqual(settings.displayWidths, ["Left": 300], "Saved widths wait for the setting to come back on")
    }

    func testSavedWidthTargetsTheSharedWidthOrOneDisplay() {
        var settings = WorkspaceSidebarConfig(mode: .tabs)
        settings.setSavedWidth(300, for: .display("Left"))
        settings.setSavedWidth(260, for: .shared)
        XCTAssertEqual(settings.savedWidth(.display("Left")), 300)
        XCTAssertNil(settings.savedWidth(.display("Right")))
        XCTAssertEqual(settings.savedWidth(.shared), 260)
        settings.setSavedWidth(nil, for: .shared)
        XCTAssertEqual(settings.width, 260, "The shared width is never removed")
        settings.setSavedWidth(nil, for: .display("Left"))
        XCTAssertEqual(settings.displayWidths, [:])
    }

    func testIdenticalDisplaysEachGetTheirOwnName() {
        let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in Retina Display", x: 0, isMain: true, uuid: nil)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "DELL U3224KB", x: 3840, uuid: nil)
        let middle = SavedWorkspaceTestMonitor(id: 3, name: "DELL U3224KB", x: 1920, uuid: nil)
        let monitors: [Monitor] = [laptop, middle, right]
        XCTAssertEqual(workspaceSidebarMonitorDisplayName(laptop, among: monitors), "Built-in Retina Display")
        XCTAssertEqual(workspaceSidebarMonitorDisplayName(middle, among: monitors), "DELL U3224KB 1",
            "Numbered from left to right, as in the display menu")
        XCTAssertEqual(workspaceSidebarMonitorDisplayName(right, among: monitors), "DELL U3224KB 2")
        XCTAssertEqual(workspaceSidebarMonitorDisplayName(right, among: [laptop, right]), "DELL U3224KB")

        setMonitorsForTests(monitors)
        let menuNames = buildWorkspaceSidebarMonitorScopes(sortedMonitors: sortedMonitors, focusedMonitorScopeId: "")
            .filter { $0.id.hasPrefix("monitor:") }.map(\.displayName)
        XCTAssertEqual(menuNames, ["Built-in Retina Display", "DELL U3224KB 1", "DELL U3224KB 2"])
    }

    func testTiledWindowsMakeRoomForEachDisplaysOwnWidth() {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: nil)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: nil)
        setMonitorsForTests([left, right])
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.tabsAlwaysExpanded = true
        config.workspaceSidebar.width = 240
        config.workspaceSidebar.displayWidths = ["Right": 320]
        XCTAssertEqual(left.workspaceSidebarInset, 240)
        XCTAssertEqual(right.workspaceSidebarInset, 320)
        let ownWidthTilingX = right.visibleRectPaddedByOuterGaps.topLeftX

        config.workspaceSidebar.widthPerDisplay = false
        XCTAssertEqual(right.workspaceSidebarInset, 240)
        XCTAssertEqual(ownWidthTilingX - right.visibleRectPaddedByOuterGaps.topLeftX, 80)
    }

    func testPanelContentUsesItsDisplaysWidth() {
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.displayWidths = ["Right": 320]
        XCTAssertEqual(workspaceSidebarConfiguration(displayName: "Right").expandedWidth, 320)
        XCTAssertEqual(workspaceSidebarConfiguration(displayName: "Left").expandedWidth, CGFloat(config.workspaceSidebar.width))
        XCTAssertEqual(workspaceSidebarConfiguration().expandedWidth, CGFloat(config.workspaceSidebar.width))
    }

    func testDisplayWidthsAreWrittenToTheirOwnTable() {
        let start = "[workspace-sidebar]\n    width = 240\n"
        let added = updateWorkspaceSidebarDisplayWidthConfig(in: start, display: "Display v2.0 \"Pro\"", width: 300)
        XCTAssertEqual(added, start + "\n[workspace-sidebar.display-widths]\n\"Display v2.0 \\\"Pro\\\"\" = 300")
        let second = updateWorkspaceSidebarDisplayWidthConfig(in: added, display: "DELL U3224KB 2", width: 320)
        let changed = updateWorkspaceSidebarDisplayWidthConfig(in: second, display: "Display v2.0 \"Pro\"", width: 280)
        let parsed = parseConfigForTests(changed)
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.config.workspaceSidebar.displayWidths, ["Display v2.0 \"Pro\"": 280, "DELL U3224KB 2": 320])
        XCTAssertEqual(parsed.config.workspaceSidebar.width, 240)

        let oneLeft = updateWorkspaceSidebarDisplayWidthConfig(in: changed, display: "Display v2.0 \"Pro\"", width: nil)
        XCTAssertEqual(parseConfigForTests(oneLeft).config.workspaceSidebar.displayWidths, ["DELL U3224KB 2": 320])
        let none = updateWorkspaceSidebarDisplayWidthConfig(in: oneLeft, display: "DELL U3224KB 2", width: nil)
        XCTAssertFalse(none.contains("display-widths"), "The last removal drops the table: \(none)")
        XCTAssertEqual(parseConfigForTests(none).errors, [])
        XCTAssertEqual(updateWorkspaceSidebarDisplayWidthConfig(in: start, display: "Missing", width: nil), start)
    }

    func testCommentedTableHeadersKeepTheirTablesApart() {
        let text = """
            [workspace-sidebar.display-widths] # set by dragging
            "Studio Display" = 300

            [workspace-sidebar.workspace-labels] # names
            "Studio Display" = "Work"
            """
        let resized = updateWorkspaceSidebarDisplayWidthConfig(in: text, display: "Studio Display", width: 320)
        let parsed = parseConfigForTests(resized)
        XCTAssertEqual(parsed.errors, [], resized)
        XCTAssertEqual(parsed.config.workspaceSidebar.displayWidths, ["Studio Display": 320])
        XCTAssertEqual(parsed.config.workspaceSidebar.workspaceLabels, ["Studio Display": "Work"],
            "The next table's matching key must survive: \(resized)")
        XCTAssertTrue(resized.contains("[workspace-sidebar.display-widths] # set by dragging"))

        let reset = updateWorkspaceSidebarDisplayWidthConfig(in: text, display: "Studio Display", width: nil)
        XCTAssertEqual(parseConfigForTests(reset).config.workspaceSidebar.displayWidths, [:], reset)
        XCTAssertEqual(parseConfigForTests(reset).config.workspaceSidebar.workspaceLabels, ["Studio Display": "Work"], reset)

        let labels = updateWorkspaceSidebarLabelConfig(in: """
            [workspace-sidebar.workspace-labels] # names
            "1" = "Code"
            [workspace-sidebar.project-labels] # projects
            "1" = "Client"
            """, workspaceName: "1", label: "Web")
        XCTAssertEqual(parseConfigForTests(labels).config.workspaceSidebar.projectLabels, ["1": "Client"], labels)
        XCTAssertEqual(parseConfigForTests(labels).config.workspaceSidebar.workspaceLabels, ["1": "Web"], labels)
    }

    func testTextInsideAMultilineStringIsNeverAHeaderOrAKey() {
        let quote = "\"\"\""
        let text = """
            [workspace-sidebar.workspace-labels]
            "1" = \(quote)
            [example] # label text
            "2" = "not a key"
            \(quote)
            "2" = "Old"
            "3" = '''one line'''
            [workspace-sidebar.project-labels]
            "2" = "Client"
            """
        let renamed = updateWorkspaceSidebarLabelConfig(in: text, workspaceName: "2", label: "Web")
        let parsed = parseConfigForTests(renamed)
        XCTAssertEqual(parsed.errors, [], renamed)
        XCTAssertEqual(parsed.config.workspaceSidebar.workspaceLabels,
            ["1": "[example] # label text\n\"2\" = \"not a key\"\n", "2": "Web", "3": "one line"], renamed)
        XCTAssertEqual(parsed.config.workspaceSidebar.projectLabels, ["2": "Client"], renamed)

        let replaced = updateWorkspaceSidebarLabelConfig(in: text, workspaceName: "1", label: "Code")
        let replacedConfig = parseConfigForTests(replaced)
        XCTAssertEqual(replacedConfig.errors, [], "The whole multi-line value goes: \(replaced)")
        XCTAssertEqual(replacedConfig.config.workspaceSidebar.workspaceLabels, ["1": "Code", "2": "Old", "3": "one line"])

        let widths = "[workspace-sidebar.display-widths]\n\"Left\" = 300\n" + text
        XCTAssertEqual(parseConfigForTests(updateWorkspaceSidebarDisplayWidthConfig(in: widths, display: "Left", width: nil))
            .config.workspaceSidebar.workspaceLabels, parseConfigForTests(text).config.workspaceSidebar.workspaceLabels)
    }

    func testTheTomlParserDecidesWhereMultilineValuesEnd() {
        let quote = "\"\"\""
        // An escaped quote before two more doesn't close the string.
        let escaped = """
            [workspace-sidebar.workspace-labels]
            "1" = \(quote)
            a \\\(quote) still inside
            "2" = "text"
            \(quote)
            "2" = "Old"
            "3" = \(quote)one\(quote)"
            "4" = '''two''''
            """
        let renamed = updateWorkspaceSidebarLabelConfig(in: escaped, workspaceName: "2", label: "Web")
        let labels = parseConfigForTests(renamed)
        XCTAssertEqual(labels.errors, [], renamed)
        XCTAssertEqual(labels.config.workspaceSidebar.workspaceLabels,
            ["1": "a \(quote) still inside\n\"2\" = \"text\"\n", "2": "Web", "3": "one\"", "4": "two'"], renamed)

        // One line closes a string and opens the next; another closes with four quotes, then opens.
        for array in [
            "exec-on-workspace-change = [\n    \(quote)first\n\(quote), \(quote)second\n\(quote),\n]",
            "exec-on-workspace-change = [\(quote)one\(quote)\", \(quote)two\n\(quote), '''three\n'''', 'four']",
        ] {
            let text = array + "\n\n[workspace-sidebar.display-widths]\n\"Left\" = 300\n"
            XCTAssertEqual(parseConfigForTests(text).errors, [], text)
            let resized = updateWorkspaceSidebarDisplayWidthConfig(in: text, display: "Left", width: 320)
            XCTAssertEqual(parseConfigForTests(resized).errors, [], resized)
            XCTAssertEqual(parseConfigForTests(resized).config.workspaceSidebar.displayWidths, ["Left": 320], resized)
            XCTAssertEqual(parseConfigForTests(resized).config.execOnWorkspaceChange, parseConfigForTests(text).config.execOnWorkspaceChange)
            let reset = updateWorkspaceSidebarDisplayWidthConfig(in: text, display: "Left", width: nil)
            XCTAssertEqual(parseConfigForTests(reset).config.workspaceSidebar.displayWidths, [:], reset)
        }
    }
}
