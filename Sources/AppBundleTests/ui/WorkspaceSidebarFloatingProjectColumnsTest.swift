import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarFloatingProjectColumnsTest: XCTestCase {
    func testFloatingRegionSitsBesideTheRestingDockOnEveryEdge() {
        let size = CGSize(width: 1400, height: 900)
        let inset: CGFloat = 2 + 64 + workspaceSidebarFloatingViewGap
        let margin = workspaceSidebarFloatingViewMargin
        let left = workspaceSidebarFloatingViewRegion(availableSize: size, dockThickness: 64, dockGap: 2, position: .left)
        XCTAssertEqual(left, CGRect(x: inset, y: margin, width: 1400 - inset - margin, height: 900 - margin * 2))
        let right = workspaceSidebarFloatingViewRegion(availableSize: size, dockThickness: 64, dockGap: 2, position: .right)
        XCTAssertEqual(right, CGRect(x: margin, y: margin, width: 1400 - inset - margin, height: 900 - margin * 2))
        let bottom = workspaceSidebarFloatingViewRegion(availableSize: size, dockThickness: 64, dockGap: 2, position: .bottom)
        XCTAssertEqual(bottom.maxY, 900 - inset, accuracy: 0.001)
        XCTAssertEqual(bottom.height, workspaceSidebarFloatingViewMaximumHeight(availableHeight: 900))
        XCTAssertEqual(bottom.minX, margin)
        XCTAssertEqual(bottom.width, 1400 - margin * 2)
        let short = workspaceSidebarFloatingViewRegion(availableSize: CGSize(width: 800, height: 120),
            dockThickness: 64, dockGap: 2, position: .bottom)
        XCTAssertGreaterThanOrEqual(short.minY, 0, "A short display must not push the view above the panel")
        XCTAssertLessThanOrEqual(short.maxY, 120 - inset + 0.001)
        XCTAssertEqual(workspaceSidebarFloatingViewAlignment(.left), .leading)
        XCTAssertEqual(workspaceSidebarFloatingViewAlignment(.right), .trailing)
        XCTAssertEqual(workspaceSidebarFloatingViewAlignment(.bottom), .bottom)
        XCTAssertEqual(workspaceSidebarProjectColumnsWidth(columnCount: 3, columnWidth: 276),
            276 * 3 + workspaceSidebarProjectColumnGap * 2)
        XCTAssertEqual(workspaceSidebarProjectColumnsWidth(columnCount: 0, columnWidth: 276), 276)
    }

    func testCollapsibleDockKeepsItsRestingRendererWhileExpanded() {
        for position in WorkspaceDockPosition.allCases {
            var fixture = snapshot(position: position)
            fixture.visibleWidth = fixture.configuration.expandedWidth
            let view = WorkspaceSidebarView(snapshot: fixture)
            let layout = view.dockLayout(availableHeight: 900)
            XCTAssertTrue(view.usesProjectColumns)
            XCTAssertTrue(view.usesNativeDock, "The Dock stays mounted beside its floating view")
            XCTAssertEqual(view.dockSurfaceProgress, 0)
            XCTAssertEqual(view.fittedVisibleWidth(layout: layout), layout.compactRailWidth, accuracy: 0.001)
            XCTAssertNil(view.browsedProjectId)

            fixture.configuration.alwaysExpanded = true
            let pinned = WorkspaceSidebarView(snapshot: fixture)
            XCTAssertFalse(pinned.usesProjectColumns, "A pinned Dock reserves one pane and keeps its morph")
            XCTAssertFalse(pinned.usesNativeDock)
            XCTAssertEqual(pinned.dockSurfaceProgress, 1)
        }
    }

    func testFloatingColumnsRenderOneRoundedColumnPerProjectBesideTheDock() throws {
        let size = CGSize(width: 1400, height: 900)
        for position in WorkspaceDockPosition.allCases {
            var fixture = snapshot(position: position)
            fixture.visibleWidth = fixture.configuration.expandedWidth
            let probe = FloatingColumnsProbe()
            let view = WorkspaceSidebarView(snapshot: fixture, actions: probe.actions,
                reduceMotionOverride: true, reduceTransparencyOverride: true)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            host.layoutSubtreeIfNeeded()

            let card = try XCTUnwrap(probe.expanded, "\(position)")
            XCTAssertTrue(host.bounds.contains(card), "\(position): \(card)")
            let layout = view.dockLayout(availableHeight: position == .bottom ? size.width : size.height)
            let edge = fixture.configuration.compactLeftGap + layout.compactRailWidth + workspaceSidebarFloatingViewGap
            switch position {
                case .left: XCTAssertEqual(card.minX, edge, accuracy: 0.5)
                case .right: XCTAssertEqual(card.maxX, size.width - edge, accuracy: 0.5)
                case .bottom: XCTAssertEqual(card.maxY, size.height - edge, accuracy: 0.5)
            }
            if let dock = probe.dock {
                XCTAssertFalse(dock.intersects(card), "\(position): the Dock remains visible beside the view")
            }
            let columnWidth = workspaceSidebarSectionWidth(1, layout: fixture.configuration)
            XCTAssertEqual(card.width, workspaceSidebarProjectColumnsWidth(columnCount: 3, columnWidth: columnWidth)
                + workspaceSidebarContentLeadingInset * 2, accuracy: 0.5)

            let targets = probe.expandedTargets
            XCTAssertTrue(targets.allSatisfy { card.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) })
            XCTAssertFalse(probe.dockTargets.isEmpty, "\(position): the resting Dock keeps its own drop targets")
            XCTAssertFalse(probe.dockTargets.contains { card.intersects($0.frame) },
                "Floating targets stay separate from the Dock's own targets")
            let creates = fixture.projects.map { project in
                targets.first { $0.kind == .newWorkspace(projectId: project.id, monitorScopeId: workspaceSidebarDefaultScopeId) }
            }
            XCTAssertTrue(creates.allSatisfy { $0 != nil }, "Every project, including an empty one, has a column")
            let columns = creates.compactMap { $0?.frame }
            for (previous, next) in zip(columns, columns.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next.minX, previous.maxX + workspaceSidebarProjectColumnGap - 0.5)
            }
            let first = try XCTUnwrap(targets.first { $0.kind == .workspace("1") })
            let second = try XCTUnwrap(targets.first { $0.kind == .workspace("2") })
            XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "Projects are side by side, not stacked")
            XCTAssertEqual(second.frame.minY, first.frame.minY, accuracy: 0.5)

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            func alpha(_ point: CGPoint) -> CGFloat {
                bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? 0
            }
            XCTAssertGreaterThan(alpha(CGPoint(x: card.midX, y: card.midY)), 0.9)
            // The empty lower corner of the last column shows the Sidebar surface, not the Dock chrome.
            let surface = try XCTUnwrap(bitmap.colorAt(x: Int((card.maxX - 24) * scale),
                y: Int((card.maxY - 24) * scale))?.usingColorSpace(.sRGB))
            for component in [surface.redComponent, surface.greenComponent, surface.blueComponent] {
                XCTAssertEqual(component, 0.08, accuracy: 0.03, "\(position): expanded view uses Sidebar appearance")
            }
            for corner in [CGPoint(x: card.minX + 1, y: card.minY + 1), CGPoint(x: card.maxX - 2, y: card.minY + 1),
                           CGPoint(x: card.minX + 1, y: card.maxY - 2), CGPoint(x: card.maxX - 2, y: card.maxY - 2)] {
                XCTAssertLessThan(alpha(corner), 0.1, "\(position): every corner is rounded")
            }
            let directory = projectRoot.appendingPathComponent(".build/sidebar-projects-ui", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("floating-columns-\(position.rawValue).png"))
        }
    }

    func testSearchKeepsTheCardSizeSoItsFieldStaysUnderThePointer() {
        let inset = workspaceSidebarContentLeadingInset
        let columnWidth: CGFloat = 256
        let allColumns = workspaceSidebarProjectColumnsWidth(columnCount: 3, columnWidth: columnWidth)
        XCTAssertEqual(workspaceSidebarProjectColumnsCardWidth(columnsWidth: allColumns, columnWidth: columnWidth,
            newProjectWidth: 90), allColumns + inset * 2)
        XCTAssertGreaterThanOrEqual(workspaceSidebarProjectColumnsCardWidth(columnsWidth: columnWidth,
            columnWidth: columnWidth, newProjectWidth: 90), inset + columnWidth + 16 + 90 + inset + 4,
            "A single column still fits the search field and New Project")

        XCTAssertEqual(workspaceSidebarProjectColumnsListHeight(measured: 120, search: 0, minimum: 40, maximum: 500), 120)
        XCTAssertEqual(workspaceSidebarProjectColumnsListHeight(measured: 60, search: 320, minimum: 40, maximum: 500), 320,
            "Fewer matches must not shrink the card and move its search field")
        XCTAssertEqual(workspaceSidebarProjectColumnsListHeight(measured: 400, search: 320, minimum: 40, maximum: 500), 400)
        XCTAssertEqual(workspaceSidebarProjectColumnsListHeight(measured: 60, search: 900, minimum: 40, maximum: 500), 500)
        XCTAssertEqual(workspaceSidebarProjectColumnsListHeight(measured: 10, search: 0, minimum: 40, maximum: 500), 40)
    }

    func testSingleProjectCardKeepsNewProjectInside() throws {
        var fixture = snapshot(position: .left)
        fixture.projects = [fixture.projects[0]]
        fixture.workspaces = [fixture.workspaces[0]]
        fixture.visibleWidth = fixture.configuration.expandedWidth
        let probe = FloatingColumnsProbe()
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: fixture, actions: probe.actions,
            reduceMotionOverride: true, reduceTransparencyOverride: true))
        host.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(probe.expanded)
        let columnWidth = workspaceSidebarSectionWidth(1, layout: fixture.configuration)
        XCTAssertGreaterThan(card.width, columnWidth + workspaceSidebarContentLeadingInset * 2 + 60,
            "The toolbar's New Project button is not clipped by a one-column card")
    }

    func testCollapsedDockDoesNotMountFloatingColumns() {
        for position in WorkspaceDockPosition.allCases {
            let probe = FloatingColumnsProbe()
            let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot(position: position),
                actions: probe.actions, reduceMotionOverride: true, reduceTransparencyOverride: true))
            host.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(probe.dock, "\(position)")
            XCTAssertNil(probe.expanded, "\(position): columns insert and remove with expansion")
            XCTAssertTrue(probe.expandedTargets.isEmpty)
        }
    }

    func testFloatingColumnsScrollWhenProjectsExceedTheDisplay() throws {
        var fixture = snapshot(position: .left)
        fixture.projects += (0..<8).map { .init(id: WorkspaceProjectId(rawValue: "extra-\($0)"), displayName: "Extra \($0)", colorHex: nil) }
        fixture.visibleWidth = fixture.configuration.expandedWidth
        let probe = FloatingColumnsProbe()
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: fixture, actions: probe.actions,
            reduceMotionOverride: true, reduceTransparencyOverride: true))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(probe.expanded)
        XCTAssertLessThanOrEqual(card.maxX, 1200 - workspaceSidebarFloatingViewMargin + 0.5)
        XCTAssertTrue(probe.expandedTargets.allSatisfy { card.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) },
            "Columns scrolled out of view cannot accept drops")
        XCTAssertFalse(probe.expandedTargets.contains {
            $0.kind == .newWorkspace(projectId: "extra-7", monitorScopeId: workspaceSidebarDefaultScopeId)
        })
    }

    func testNativeWorkspaceDragIsAcceptedByAnotherProjectColumn() async throws {
        var fixture = snapshot(position: .left)
        fixture.visibleWidth = fixture.configuration.expandedWidth
        let probe = FloatingColumnsProbe()
        var actions = probe.actions
        actions.send = { _ in XCTFail("Drag negotiation must not move a workspace") }
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: fixture, actions: actions,
            reduceMotionOverride: true, reduceTransparencyOverride: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(probe.expandedTargets.first { $0.kind == .workspace("2") })
        let point = host.convert(CGPoint(x: target.frame.midX, y: target.frame.midY), to: nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([try XCTUnwrap(
            WorkspaceSidebarWorkspaceDragPayload(workspaceName: "1").pasteboardItem)]))
        let source = WorkspaceSidebarWorkspaceDragSourceView()
        source.beginDrag()
        defer { source.finishDrag() }
        let info = SidebarWorkspaceDraggingInfo(window: window, point: point, pasteboard: pasteboard, source: source)
        func destinations(in view: NSView) -> [NSView] {
            (view.registeredDraggedTypes.isEmpty ? [] : [view]) + view.subviews.flatMap(destinations)
        }
        let candidates = destinations(in: host).filter { $0.bounds.contains($0.convert(point, from: nil)) }
        let destination = try XCTUnwrap(candidates.first {
            _ = $0.draggingEntered(info)
            return $0.draggingUpdated(info).contains(.move)
        })
        destination.draggingExited(info)
        destination.draggingEnded(info)
    }

    func testFloatingColumnsAcceptPointerAndRetainHoverOnlyWhileExpanded() throws {
        try withPanel(position: .bottom) { panel in
            XCTAssertLessThan(workspaceSidebarFloatingViewGap, panel.hoverExitTolerance,
                "Crossing from the Dock to its floating view must never collapse it")
            panel.visibleSurfaceFrame = CGRect(x: 212, y: 674, width: 600, height: 64)
            let dock = panel.visibleSurfaceFrameOnScreen
            panel.expandSidebar(to: 280)
            panel.updateExpandedSurfaceFrame(CGRect(x: 150, y: 264, width: 724, height: 400))
            let card = try XCTUnwrap(panel.activeExpandedSurfaceFrameOnScreen)
            XCTAssertEqual(card.minY, dock.maxY + workspaceSidebarFloatingViewGap, accuracy: 0.5)
            let inside = CGPoint(x: card.midX, y: card.midY)
            let gap = CGPoint(x: dock.midX, y: dock.maxY + workspaceSidebarFloatingViewGap / 2)
            let beside = CGPoint(x: card.minX + 20, y: dock.midY)
            let far = CGPoint(x: card.midX, y: card.maxY + 80)
            XCTAssertTrue(panel.isScreenPointInsideVisibleRegion(inside))
            XCTAssertTrue(panel.isScreenPointInsideHoverRegion(inside))
            XCTAssertTrue(panel.isScreenPointInsideHoverRegion(gap), "The gap keeps the view open")
            XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(gap), "The gap passes clicks through")
            XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(beside))
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(beside),
                "Space beside the Dock below the view is not an invisible hover target")
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(far))
            XCTAssertTrue(panel.isScreenPointInsideVisibleRegion(CGPoint(x: dock.midX, y: dock.midY)),
                "The resting Dock stays interactive while the view is open")

            panel.viewModel.workspaceSidebarVisibleWidth = 150
            XCTAssertNil(panel.activeExpandedSurfaceFrameInHostingView,
                "A partly expanded view that SwiftUI does not hit-test must not block clicks")
            XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(inside))
            panel.viewModel.workspaceSidebarVisibleWidth = 280

            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertNil(panel.activeExpandedSurfaceFrameInHostingView)
            XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(inside), "A fading view passes clicks through")
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(inside))
        }
    }

    func testAutoHideFadesFloatingColumnsAndSlidesOnlyTheDock() throws {
        try withPanel(position: .left) { panel in
            let restingWidth = config.workspaceSidebar.effectiveCollapsedWidth
            panel.visibleSurfaceFrame = CGRect(x: 2, y: 200, width: 64, height: 340)
            let restingOffset = panel.slideOffset
            panel.expandSidebar(to: 280)
            panel.updateExpandedSurfaceFrame(CGRect(x: 76, y: 80, width: 860, height: 500))
            panel.updateExpandedDropTargets([.init(kind: .workspace("2"), frame: CGRect(x: 100, y: 120, width: 256, height: 32))])
            let card = try XCTUnwrap(panel.activeExpandedSurfaceFrameOnScreen)
            let cardCenter = CGPoint(x: card.midX, y: card.midY)
            panel.hideSidebar(.pointerExit)
            XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, restingWidth,
                "The floating view fades in place instead of sliding across the display")
            XCTAssertNil(panel.activeExpandedSurfaceFrameInHostingView)
            XCTAssertEqual(panel.slideOffset.x, restingOffset.x, accuracy: 0.5, "Only the resting Dock slides")
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(cardCenter))

            // Even at full width, a hiding panel's floating view is not a re-entry target.
            panel.viewModel.workspaceSidebarVisibleWidth = 280
            XCTAssertNotNil(panel.activeExpandedSurfaceFrameInHostingView)
            XCTAssertFalse(panel.isScreenPointInsideHoverRegion(cardCenter),
                "The outgoing view is not a wide re-entry target")
            XCTAssertFalse(panel.isScreenPointInsideVisibleRegion(cardCenter))

            // The hide completion discards the floating geometry the view no longer reports.
            panel.clearHiddenSidebarContent(preserveSurface: true)
            XCTAssertNil(panel.expandedSurfaceFrame)
            XCTAssertTrue(panel.expandedDropTargetFrames.isEmpty)
        }
    }

    func testDropTargetsAndContainmentIncludeFloatingColumnsOnlyWhileExpanded() throws {
        try withPanel(position: .left) { panel in
            panel.visibleSurfaceFrame = CGRect(x: 2, y: 200, width: 64, height: 340)
            let dockTarget = WorkspaceSidebarDropTargetFrame(kind: .workspace("1"), frame: CGRect(x: 8, y: 220, width: 52, height: 52))
            let cardTarget = WorkspaceSidebarDropTargetFrame(kind: .workspace("2"), frame: CGRect(x: 100, y: 120, width: 256, height: 32))
            panel.updateDropTargets([dockTarget])
            panel.expandSidebar(to: 280)
            panel.updateExpandedSurfaceFrame(CGRect(x: 76, y: 80, width: 560, height: 500))
            panel.updateExpandedDropTargets([cardTarget])
            @MainActor func screenPoint(_ rect: CGRect) -> CGPoint {
                panel.convertToScreen(panel.hostingView.convert(CGRect(x: rect.midX, y: rect.midY, width: 0, height: 0), to: nil)).origin
            }
            let cardPoint = screenPoint(cardTarget.frame)
            let dockPoint = screenPoint(dockTarget.frame)
            XCTAssertEqual(panel.dropTarget(atScreenPoint: cardPoint, hitSlop: NSEdgeInsets())?.kind, .workspace("2"))
            XCTAssertEqual(panel.dropTarget(atScreenPoint: dockPoint, hitSlop: NSEdgeInsets())?.kind, .workspace("1"))
            let gapPoint = screenPoint(CGRect(x: 71, y: 300, width: 0, height: 0))
            XCTAssertNil(panel.dropTarget(atScreenPoint: gapPoint, hitSlop: NSEdgeInsets()))

            let normalizedCard = CGRect(origin: cardPoint, size: .zero).monitorFrameNormalized().topLeftCorner
            let normalizedGap = CGRect(origin: gapPoint, size: .zero).monitorFrameNormalized().topLeftCorner
            XCTAssertNotNil(panel.visibleScreenRectNormalized(containing: normalizedCard))
            XCTAssertNil(panel.visibleScreenRectNormalized(containing: normalizedGap))

            closeWorkspaceSidebarFromCommand(panel)
            XCTAssertNil(panel.dropTarget(atScreenPoint: cardPoint, hitSlop: NSEdgeInsets()),
                "A collapsing view cannot receive a drop")
            XCTAssertNil(panel.visibleScreenRectNormalized(containing: normalizedCard))
            panel.resetHiddenSidebarState()
            XCTAssertNil(panel.expandedSurfaceFrame)
            XCTAssertTrue(panel.expandedDropTargetFrames.isEmpty)
        }
    }

    private func snapshot(position: WorkspaceDockPosition) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 64, expandedWidth: 300,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: true, dockPosition: position, compactLeftGap: 2)
        snapshot.visibleWidth = 64
        snapshot.projects = [
            .init(id: workspaceProjectDefaultId, displayName: "Default", colorHex: nil),
            .init(id: "research", displayName: "Research", colorHex: "#69B5F8", emoji: "🔬"),
            .init(id: "empty-project", displayName: "Empty project", colorHex: nil),
        ]
        snapshot.workspaces = [
            workspace("1", project: workspaceProjectDefaultId, title: "Planning", windowId: 801),
            workspace("2", project: "research", title: "Research notes", windowId: 802),
            workspace("3", project: "research", title: "Paper draft", windowId: 803),
        ]
        return snapshot
    }

    private func workspace(_ name: String, project: WorkspaceProjectId, title: String,
                           windowId: UInt32) -> WorkspaceSidebarWorkspaceViewModel {
        let window = WorkspaceSidebarWindowViewModel(windowId: windowId, workspaceName: name,
            appName: "Notes", appBundleId: nil, appBundlePath: nil, title: title, isFocused: false)
        return WorkspaceSidebarWorkspaceViewModel(name: name, projectId: project,
            displayName: "Workspace \(name)", sidebarLabel: name, isGeneratedName: false,
            monitorScopeId: "monitor:0,0", monitorName: "Main", isFocused: false, isVisible: false,
            items: [.init(kind: .window(window))])
    }

    private func withPanel(position: WorkspaceDockPosition, _ body: (WorkspaceSidebarPanel) throws -> Void) throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
        let oldConfig = config
        let wasEnabled = TrayMenuModel.shared.isEnabled
        let panel = WorkspaceSidebarPanel.shared
        let oldFrame = panel.frame
        let trackingDepth = panel.menuTrackingDepth
        panel.resetHiddenSidebarState()
        panel.menuTrackingDepth = 1 // Ignore the real desktop pointer during controlled geometry checks.
        defer {
            panel.resetHiddenSidebarState()
            panel.viewModel.isWorkspaceSidebarExpanded = false
            panel.menuTrackingDepth = trackingDepth
            panel.setFrame(oldFrame, display: false)
            config = oldConfig
            TrayMenuModel.shared.isEnabled = wasEnabled
        }
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .dock
        config.workspaceSidebar.dockPosition = position
        config.workspaceSidebar.dockIconSize = 48
        config.workspaceSidebar.autoHide = false
        config.workspaceSidebar.alwaysExpanded = false
        config.workspaceSidebar.width = 280
        TrayMenuModel.shared.isEnabled = true
        panel.refresh(on: mainMonitor)
        panel.setFrame(CGRect(x: 100, y: 100, width: 1024, height: 740), display: false)
        panel.viewModel.workspaceSidebarVisibleWidth = 64
        panel.viewModel.isWorkspaceSidebarExpanded = false
        panel.orderFront(nil)
        try body(panel)
    }
}

@MainActor
private final class FloatingColumnsProbe {
    var dock: CGRect?
    var dockTargets: [WorkspaceSidebarDropTargetFrame] = []
    var expanded: CGRect?
    var expandedTargets: [WorkspaceSidebarDropTargetFrame] = []

    var actions: WorkspaceSidebarActions {
        WorkspaceSidebarActions(
            setDropTargets: { [weak self] in self?.dockTargets = $0 },
            setSurfaceFrame: { [weak self] in self?.dock = $0 },
            setExpandedSurfaceFrame: { [weak self] in self?.expanded = $0 },
            setExpandedDropTargets: { [weak self] in self?.expandedTargets = $0 }
        )
    }
}
