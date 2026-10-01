import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// The preview as rendered: real states from a fake provider, hosted in AppKit, at the Tabs
/// sidebar's narrow widths. Renders go to WINMUX_RENDER_DIR when it's set.
@MainActor
final class WorkspaceTopicSuggestionViewTest: XCTestCase {
    private var provider: FakeWorkspaceTopicProvider!
    private var coordinator: WorkspaceTopicCoordinator!
    static let widths: [CGFloat] = [160, 180, 200, 240, 320]

    override func setUp() async throws {
        setUpWorkspacesForTests()
        TopicTestApps.reset()
        provider = FakeWorkspaceTopicProvider(script: [
            "ECON 4310": ["ECON 4310"], "平台经济": ["平台经济"], "Kyoto": ["Kyoto"],
        ])
        coordinator = WorkspaceTopicTestEnvironment.setUp(provider: provider)
    }

    override func tearDown() async throws {
        await provider.release()
        WorkspaceTopicTestEnvironment.tearDown()
        TopicTestApps.reset()
        try await super.tearDown()
    }

    /// Tabs with long English and Chinese titles, a browser tab, and a split.
    private func makeTabs() {
        let tabs: [(String, [(TestApp, String)])] = [
            ("deck", [(TopicTestApps.keynote, "ECON 4310 Lecture 3 — Price Elasticity of Demand and Supply in Competitive Markets")]),
            ("grades", [(TopicTestApps.numbers, "ECON 4310 期中成绩与平时作业汇总表（第二学期，含补考名单）.numbers")]),
            ("notes", [(TopicTestApps.xcode, "平台经济文献综述 — 平台竞争与网络效应的实证研究笔记（草稿第三版）")]),
            ("review", [(TopicTestApps.mail, "Re: 平台经济 reading group — next week's paper and the discussion questions")]),
            ("web", [(TopicTestApps.safari, "Kyoto Station to Arashiyama — Train Times, Passes and Day Trip Planning")]),
            ("split", [(TopicTestApps.terminal, "Kyoto itinerary — build"), (TopicTestApps.numbers, "Kyoto trip budget.numbers")]),
        ]
        var id: UInt32 = 400
        for (name, windows) in tabs {
            let workspace = Workspace.get(byName: name)
            for (app, title) in windows {
                TestWindow.new(id: id, parent: workspace.rootTilingContainer, app: app, title: title)
                id += 1
            }
        }
    }

    private func ready() async throws {
        makeTabs()
        await updateWorkspaceSidebarModel()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
    }

    private func host(width: CGFloat, reduceMotion: Bool = false, showsSkipped: Bool = false,
                      showsAnalyzed: Bool = false) -> NSHostingView<some View> {
        let view = NSHostingView(rootView: WorkspaceTopicSuggestionView(coordinator: coordinator, width: width, maximumHeight: 900,
            reduceMotionOverride: reduceMotion, showsSkipped: showsSkipped, showsAnalyzed: showsAnalyzed)
            .transaction { $0.animation = nil })
        view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 600))
        view.layoutSubtreeIfNeeded()
        view.frame.size = CGSize(width: width, height: max(view.fittingSize.height, 100))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func spin(_ seconds: Double = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func render(_ view: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WINMUX_RENDER_DIR"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("topic-\(name).png"))
    }

    func testTheReadyPreviewFitsEveryNarrowWidth() async throws {
        try await ready()
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(Set(coordinator.groups.map(\.name)), ["ECON 4310", "平台经济"])
        for width in Self.widths {
            let view = host(width: width)
            spin()
            XCTAssertLessThanOrEqual(view.fittingSize.width, width + 0.5, "Nothing widens the preview at \(width)")
            XCTAssertGreaterThan(view.fittingSize.height, 150)
            try render(view, "ready-\(Int(width))")
        }
    }

    private func renderEveryWidth(_ state: String, reduceMotion: Bool = false, showsSkipped: Bool = false,
                                  showsAnalyzed: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        for width in Self.widths {
            let view = host(width: width, reduceMotion: reduceMotion, showsSkipped: showsSkipped, showsAnalyzed: showsAnalyzed)
            spin(0.2)
            XCTAssertLessThanOrEqual(view.fittingSize.width, width + 0.5, "\(state) at \(width)", file: file, line: line)
            try render(view, "\(state)-\(Int(width))")
        }
    }

    func testEveryStateFitsEveryNarrowWidth() async throws {
        makeTabs()
        await updateWorkspaceSidebarModel()
        await provider.hold()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.waitUntil { await self.provider.heldCount == 1 }
        XCTAssertEqual(coordinator.phase, .analyzing(done: 0, total: 5))
        try renderEveryWidth("analyzing")
        try renderEveryWidth("analyzing-reduce-motion", reduceMotion: true)
        await provider.release()
        try await WorkspaceTopicTestEnvironment.settle(coordinator)

        // Edited into a problem: one tab left, and a name too long.
        coordinator.groups[0].members[1].isIncluded = false
        coordinator.groups[1].name = String(repeating: "很长的组名", count: 13)
        XCTAssertNotNil(coordinator.groups[0].problem)
        XCTAssertNotNil(coordinator.groups[1].problem)
        try renderEveryWidth("problems", showsSkipped: true, showsAnalyzed: true)

        let unavailable = FakeWorkspaceTopicProvider(availability: .unavailable(.appleIntelligenceNotEnabled))
        coordinator.reset()
        coordinator.makeProvider = { unavailable }
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .unavailable(.appleIntelligenceNotEnabled))
        try renderEveryWidth("unavailable")

        let busy = FakeWorkspaceTopicProvider()
        await busy.fail("ECON", with: .busy)
        coordinator.reset()
        coordinator.makeProvider = { busy }
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.busy))
        try renderEveryWidth("failed")
    }

    func testNothingToGroupStillOffersTheBrowserTab() async throws {
        let web = Workspace.get(byName: "web")
        TestWindow.new(id: 480, parent: web.rootTilingContainer, app: TopicTestApps.safari,
            title: "Kyoto Station to Arashiyama — Train Times, Passes and Day Trip Planning")
        let notes = Workspace.get(byName: "notes")
        TestWindow.new(id: 481, parent: notes.rootTilingContainer, app: TopicTestApps.numbers, title: "Kyoto trip budget.numbers")
        await updateWorkspaceSidebarModel()
        coordinator.suggest(WorkspaceTopicTestEnvironment.scope(), snapshot: WorkspaceTopicTestEnvironment.snapshot)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertEqual(coordinator.groups, [])
        XCTAssertTrue(coordinator.request?.prepared.skipped.contains { $0.reason == .browser(appName: "Safari") } == true)
        try renderEveryWidth("empty-with-browser", showsSkipped: true)
        let token = try XCTUnwrap(coordinator.request?.prepared.skipped.first { $0.reason == .browser(appName: "Safari") }?.token)
        coordinator.setBrowserTab(token, included: true)
        try await WorkspaceTopicTestEnvironment.settle(coordinator)
        XCTAssertEqual(coordinator.groups.map(\.name), ["Kyoto"], "Including the browser tab finds the pair")
        try renderEveryWidth("browser-included")
    }

    func testAnOutOfDateApplyKeepsThePreviewOpenWithAReason() async throws {
        try await ready()
        (Workspace.existing(byName: "deck")?.allLeafWindowsRecursive.first as? TestWindow)?.customTitle = "Something else"
        resetCachedWindowTitles()
        await updateWorkspaceSidebarModel()
        await coordinator.apply()?.value
        XCTAssertEqual(coordinator.phase, .notApplied(workspaceTopicOutOfDateMessage))
        try renderEveryWidth("not-applied")
    }

    /// Closing hands key back only while the preview has it: after the user moved on, an
    /// automatic close (say, the setting turned off) leaves their choice alone.
    func testClosingTheRealPanelDoesntTakeFocusBackFromALaterWindow() async throws {
        try await ready()
        func keyable() -> KeyablePanel {
            let panel = KeyablePanel(contentRect: CGRect(x: 600, y: 300, width: 120, height: 80), styleMask: [.borderless],
                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            return panel
        }
        let before = keyable(), later = keyable()
        defer { before.close(); later.close() }
        before.makeKeyAndOrderFront(nil)
        spin(0.2)
        try XCTSkipUnless(before.isKeyWindow, "This session can't make test windows key")
        let preview = WorkspaceTopicSuggestionPanel.shared
        preview.show(anchor: CGRect(x: 0, y: 200, width: 240, height: 600), sidebarWidth: 240)
        spin(0.2)
        XCTAssertTrue(preview.isVisible)
        XCTAssertFalse(before.isKeyWindow, "The preview took key when it opened")
        preview.close()
        spin(0.2)
        XCTAssertTrue(before.isKeyWindow, "Closed while it had key: key goes back")

        preview.show(anchor: CGRect(x: 0, y: 200, width: 240, height: 600), sidebarWidth: 240)
        spin(0.2)
        later.makeKeyAndOrderFront(nil)
        spin(0.2)
        XCTAssertTrue(later.isKeyWindow)
        config.workspaceSidebar.intelligence.mode = .off
        syncWorkspaceTopicSuggestions()
        spin(0.2)
        XCTAssertFalse(preview.isVisible, "Turning it off closes the preview")
        XCTAssertTrue(later.isKeyWindow, "and leaves the window the user chose since")
    }

    /// Real clicks and typing in a key panel: the group's checkbox, its name field, then Apply.
    func testClickingTypingAndApplyingInThePreview() async throws {
        try await ready()
        let panel = KeyablePanel(contentRect: CGRect(x: 40, y: 40, width: 240, height: 700), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let view = host(width: 240)
        panel.setContentSize(view.frame.size)
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        spin()
        let econ = try XCTUnwrap(coordinator.groups.firstIndex { $0.name == "ECON 4310" })
        let field = try XCTUnwrap(textFields(in: view).first { $0.stringValue == "ECON 4310" })
        // The checkbox sits just before the name field, on its line.
        let checkbox = field.convert(NSPoint(x: -14, y: field.bounds.midY), to: nil)
        click(panel, at: checkbox)
        XCTAssertFalse(coordinator.groups[econ].isIncluded, "Unchecking leaves the group out")
        click(panel, at: checkbox)
        XCTAssertTrue(coordinator.groups[econ].isIncluded)

        XCTAssertTrue(panel.makeFirstResponder(field))
        spin(0.1)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Economics", replacementRange: editor.selectedRange())
        spin()
        XCTAssertEqual(coordinator.groups[econ].name, "Economics", "Typing renames the group")

        // Apply: the footer's trailing button.
        let apply = view.convert(NSPoint(x: view.bounds.maxX - 40, y: view.isFlipped ? view.bounds.maxY - 24 : 24), to: nil)
        click(panel, at: apply)
        try await WorkspaceTopicTestEnvironment.waitUntil { self.coordinator.phase == .idle }
        XCTAssertEqual(Set(workspaceSidebarOrganizationStore.state.collections.map(\.name)), ["Economics", "平台经济"])
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Group by Topic")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
        }
        spin(0.15)
    }

    private func describe(_ view: NSView, depth: Int) -> [String] {
        var lines = [String(repeating: "  ", count: depth) + String(describing: type(of: view)) +
            ((view as? NSButton).map { " title=\($0.title) state=\($0.state.rawValue)" } ?? "") +
            ((view as? NSTextField).map { " text=\($0.stringValue)" } ?? "")]
        for subview in view.subviews { lines += describe(subview, depth: depth + 1) }
        return lines
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
