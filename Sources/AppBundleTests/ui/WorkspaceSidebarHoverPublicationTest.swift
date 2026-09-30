import AppKit
@testable import AppBundle
import Combine
import SwiftUI
import XCTest

/// Pointer movement rechecks hover about 30 times a second. An open sidebar must not answer
/// each recheck with an expansion notification or a model publication: either one
/// invalidates the whole SwiftUI tree, which kept WinMux busy whenever the pointer moved.
@MainActor
final class WorkspaceSidebarHoverPublicationTest: XCTestCase {
    func testOnlyAChangeOrASearchAnnouncesAnExpansion() {
        func announces(isExpanded: Bool = true, isCollapseAnnounced: Bool = false, isShown: Bool = true,
                       visibleWidth: CGFloat = 280, startsSearch: Bool = false) -> Bool {
            shouldAnnounceWorkspaceSidebarExpansion(isExpanded: isExpanded, isCollapseAnnounced: isCollapseAnnounced,
                isShown: isShown, visibleWidth: visibleWidth, expandedWidth: 280, startsSearch: startsSearch)
        }
        XCTAssertFalse(announces(), "Open at full width: nothing changes")
        XCTAssertFalse(announces(visibleWidth: 560), "Browsing a second project keeps its wider view")
        XCTAssertTrue(announces(isExpanded: false))
        XCTAssertTrue(announces(visibleWidth: 48), "The rail still has to grow")
        XCTAssertTrue(announces(isCollapseAnnounced: true), "The view must drop its collapsing state")
        XCTAssertTrue(announces(isShown: false), "Hidden or suppressed panels must reveal")
        XCTAssertTrue(announces(startsSearch: true), "Hover-to-search reaches an open sidebar")
    }

    func testHoverRechecksOnAnOpenSidebarAnnounceAndPublishNothing() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            let probe = ExpansionProbe(panel)
            panel.expandSidebar(to: 280)
            XCTAssertEqual(probe.expansions, 1, "A real expansion is announced once")
            XCTAssertEqual(probe.searchStarts, 0, "A passive expansion never starts search")
            XCTAssertEqual(probe.expandedWrites, 1)
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)

            probe.reset()
            recheck(panel, hovering: true, times: 60)
            for _ in 0 ..< 10 { panel.expandSidebar(to: 280) }
            XCTAssertEqual(probe.expansions, 0)
            XCTAssertEqual(probe.publications, 0, "Rechecks must not invalidate the sidebar view")
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
        }
    }

    func testPinnedOpenSidebarIgnoresPointerMovementAnywhere() throws {
        for mode in [WorkspaceSidebarMode.sidebar, .tabs] {
            try withPanel(mode: mode, pinned: true) { panel in
                XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
                let probe = ExpansionProbe(panel)
                recheck(panel, hovering: false, times: 60)
                recheck(panel, hovering: true, times: 60)
                XCTAssertEqual(probe.expansions, 0, "\(mode)")
                XCTAssertEqual(probe.collapses, 0, "\(mode)")
                XCTAssertEqual(probe.publications, 0, "\(mode): pointer movement must not invalidate the view")
                XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
                XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            }
        }
    }

    /// The whole recheck each pointer event runs: passthrough, hover region from the real
    /// pointer, then setHovering. A pinned panel stays open wherever the pointer is.
    func testPointerRechecksOfAPinnedPanelPublishNothingWhereverThePointerIs() throws {
        for mode in [WorkspaceSidebarMode.sidebar, .tabs] {
            try withPanel(mode: mode, pinned: true) { panel in
                let probe = ExpansionProbe(panel)
                let depth = panel.menuTrackingDepth
                panel.menuTrackingDepth = 0
                defer { panel.menuTrackingDepth = depth }
                for _ in 0 ..< 60 { panel.updateHoverStateFromMousePosition() }
                XCTAssertEqual(probe.expansions + probe.collapses, 0, "\(mode)")
                XCTAssertEqual(probe.publications, 0, "\(mode)")
                XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            }
        }
    }

    /// Every global mouse-drag event runs `refreshAll`, which refreshes each panel.
    func testRepeatedRefreshesOfAnUnchangedPanelPublishNothing() throws {
        for (mode, pinned) in [(WorkspaceSidebarMode.sidebar, true), (.tabs, true), (.sidebar, false)] {
            try withPanel(mode: mode, pinned: pinned) { panel in
                for expanded in pinned ? [true] : [false, true] {
                    if expanded { panel.expandSidebar(to: 280) }
                    let probe = ExpansionProbe(panel)
                    for _ in 0 ..< 60 { panel.refresh(on: mainMonitor) }
                    XCTAssertEqual(probe.publications, 0, "\(mode) pinned=\(pinned) expanded=\(expanded)")
                    XCTAssertEqual(probe.expansions + probe.collapses, 0)
                    XCTAssertEqual(panel.viewModel.isWorkspaceSidebarExpanded, expanded)
                }
            }
        }
    }

    func testReturningBeforeACollapseFiresAnnouncesTheExpansionOnce() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            panel.expandSidebar(to: 280)
            let probe = ExpansionProbe(panel)
            recheck(panel, hovering: false, times: 1)
            XCTAssertEqual(probe.collapses, 1)
            XCTAssertNotNil(panel.pendingCollapse)
            // Back inside within the collapse delay: the width never changed, but the view
            // heard the collapse and must hear the expansion to drop its collapsing state.
            recheck(panel, hovering: true, times: 30)
            XCTAssertNil(panel.pendingCollapse)
            XCTAssertEqual(probe.expansions, 1)
            XCTAssertEqual(probe.searchStarts, 0)
            XCTAssertEqual(probe.publications, 0)

            // A command closes the sidebar; opening it again is a real expansion.
            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertEqual(probe.collapses, 2)
            probe.reset()
            panel.expandSidebar(to: 280)
            XCTAssertEqual(probe.expansions, 1)
            XCTAssertEqual(probe.expandedWrites, 1)
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(probe.expansions, 1)
        }
    }

    func testCancelledCollapseAtFullWidthStillAnnouncesTheReturn() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            panel.expandSidebar(to: 280)
            let probe = ExpansionProbe(panel)
            // The collapse announced itself, then its work item found the pointer inside and
            // returned without changing the width.
            panel.announceCollapse()
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(probe.expansions, 1)
            XCTAssertEqual(probe.publications, 0)

            // Hidden and shown again at full width before the view renders the zero width
            // between: it still holds the collapse and must hear the next expansion.
            panel.announceCollapse()
            panel.resetHiddenSidebarState()
            panel.refresh(on: mainMonitor)
            panel.orderFront(nil)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, 280)
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(probe.expansions, 2)
        }
    }

    /// The consumer's side: the view reserves the pager's place while growing or collapsing
    /// (WorkspaceSidebarViewLayout), so its render shows which transition it believes in.
    func testTheViewKeepsNoTransitionStateAfterACancelledCollapse() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            let collapsed = workspaceSidebarConfiguration().collapsedWidth
            let compactWidth = collapsed + (280 - collapsed) * 0.3
            let host = NSHostingView(rootView: sidebarRoot(target: panel.monitorScopeId, visibleWidth: compactWidth))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 520)
            host.appearance = NSAppearance(named: .aqua)
            let compact = try render(host)

            panel.expandSidebar(to: 280)
            XCTAssertNotEqual(try render(host), compact, "A real expansion still reserves the compact pager's place")
            host.rootView = sidebarRoot(target: panel.monitorScopeId, visibleWidth: 280)
            let open = try render(host)

            recheck(panel, hovering: false, times: 1)
            // Rendering outlasts the collapse delay: its work item finds the tracking lock
            // and returns without narrowing, as it does when the pointer is back inside.
            XCTAssertNotEqual(try render(host), open, "The view heard the collapse")
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(try render(host), open, "Returning after a cancelled collapse restores the open sidebar")

            // Narrowing without another announcement shows any expansion flag left behind.
            host.rootView = sidebarRoot(target: panel.monitorScopeId, visibleWidth: compactWidth)
            XCTAssertEqual(try render(host), compact, "A cancelled collapse leaves no expansion state behind")
        }
    }

    /// A reset zeroes the panel's width and the next refresh restores it. The view can miss
    /// the zero width between, and then only the next expansion clears its collapse.
    func testTheViewRecoversAFullWidthCollapseAcrossAReset() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            panel.expandSidebar(to: 280)
            let host = NSHostingView(rootView: sidebarRoot(target: panel.monitorScopeId, visibleWidth: 280))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 520)
            host.appearance = NSAppearance(named: .aqua)
            let open = try render(host)
            recheck(panel, hovering: false, times: 1)
            panel.pendingCollapse?.cancel()
            panel.pendingCollapse = nil
            let collapsing = try render(host)
            XCTAssertNotEqual(collapsing, open)

            panel.resetHiddenSidebarState()
            panel.refresh(on: mainMonitor)
            panel.orderFront(nil)
            XCTAssertEqual(try render(host), collapsing, "The view never saw the zero width")
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(try render(host), open, "The next expansion still clears the collapse")
        }
    }

    func testAutoHiddenSidebarStillRevealsAndAnnounces() throws {
        try withPanel(mode: .sidebar, pinned: false) { panel in
            config.workspaceSidebar.autoHide = true
            panel.expandSidebar(to: 280)
            panel.hideSidebar(.pointerExit, animated: false)
            XCTAssertNotNil(panel.autoHideReason)
            let probe = ExpansionProbe(panel)
            panel.expandSidebar(to: 280)
            XCTAssertEqual(probe.expansions, 1)
            XCTAssertNil(panel.autoHideReason, "The hidden sidebar reveals")
            XCTAssertTrue(panel.viewModel.isWorkspaceSidebarExpanded)
            probe.reset()
            recheck(panel, hovering: true, times: 30)
            XCTAssertEqual(probe.expansions, 0)
            XCTAssertEqual(probe.publications, 0)
        }
    }

    private func sidebarRoot(target: String, visibleWidth: CGFloat) -> AnyView {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = workspaceSidebarConfiguration()
        snapshot.configuration.chromeStyle = .solid
        snapshot.visibleWidth = visibleWidth
        snapshot.targetMonitorScopeId = target
        snapshot.projects = ["one", "two", "three"].map {
            .init(id: WorkspaceProjectId($0), displayName: $0, colorHex: "#7BA3C9")
        }
        snapshot.activeProjectId = WorkspaceProjectId("one")
        // A window-less host never advances an animation; render each state as it lands.
        return AnyView(WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true, reduceTransparencyOverride: true)
            .transaction { $0.animation = nil }
            .frame(width: 280, height: 520))
    }

    private func render(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    /// `setHovering` is what each pointer recheck calls with the hover state it computed.
    private func recheck(_ panel: WorkspaceSidebarPanel, hovering: Bool, times: Int) {
        let depth = panel.menuTrackingDepth
        panel.menuTrackingDepth = 0
        defer { panel.menuTrackingDepth = depth }
        for _ in 0 ..< times { panel.setHovering(hovering) }
    }

    private func withPanel(mode: WorkspaceSidebarMode, pinned: Bool, _ body: (WorkspaceSidebarPanel) throws -> Void) throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let panel = WorkspaceSidebarPanel.shared
        let oldFrame = panel.frame
        let trackingDepth = panel.menuTrackingDepth
        panel.resetHiddenSidebarState()
        panel.menuTrackingDepth = 1 // Deferred rechecks must not read the real desktop pointer.
        defer {
            panel.pendingCollapse?.cancel()
            panel.pendingCollapse = nil
            panel.resetHiddenSidebarState()
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.menuTrackingDepth = trackingDepth
            panel.setFrame(oldFrame, display: false)
            config = oldConfig
            TrayMenuModel.shared.isEnabled = wasEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = mode
        config.workspaceSidebar.browserTabs = false
        config.workspaceSidebar.autoHide = false
        config.workspaceSidebar.alwaysExpanded = pinned
        config.workspaceSidebar.tabsAlwaysExpanded = pinned
        config.workspaceSidebar.width = 280
        TrayMenuModel.shared.isEnabled = true
        panel.viewModel.isWorkspaceSidebarExpanded = false
        panel.refresh(on: mainMonitor)
        panel.orderFront(nil)
        try body(panel)
    }
}

@MainActor
private final class ExpansionProbe {
    private(set) var expansions = 0
    private(set) var searchStarts = 0
    private(set) var collapses = 0
    private(set) var publications = 0
    private(set) var expandedWrites = 0
    private var subscriptions: [AnyCancellable] = []

    init(_ panel: WorkspaceSidebarPanel) {
        let center = NotificationCenter.default
        subscriptions = [
            center.publisher(for: workspaceSidebarWillExpandNotification, object: panel).sink { [unowned self] note in
                expansions += 1
                if note.userInfo?[workspaceSidebarExpansionStartsSearchKey] as? Bool == true { searchStarts += 1 }
            },
            center.publisher(for: workspaceSidebarWillCollapseNotification, object: panel).sink { [unowned self] _ in
                collapses += 1
            },
            panel.viewModel.objectWillChange.sink { [unowned self] in publications += 1 },
            panel.viewModel.$isWorkspaceSidebarExpanded.dropFirst().sink { [unowned self] _ in expandedWrites += 1 },
        ]
    }

    func reset() {
        expansions = 0
        searchStarts = 0
        collapses = 0
        publications = 0
        expandedWrites = 0
    }
}
