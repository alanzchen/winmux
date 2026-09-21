import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarNativeDockTest: XCTestCase {
    func testScrollSuppressesLensAndRecoversWithoutAnotherMouseMove() async throws {
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = sidebarAppIconsTestApps(count: 15)
        var geometryPublications = 0
        let input = fixture(workspace: workspace, actions: .init(setSurfaceFrame: { _ in geometryPublications += 1 }))
        let window = NSWindow(contentRect: CGRect(x: 350, y: 250, width: 240, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        window.contentView = view
        view.configure(input)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        defer { view.detach(); window.close() }
        let driver = try XCTUnwrap(view.subviews.compactMap { $0 as? WorkspaceSidebarDockDisplayLinkView }.first)
        let point = window.convertPoint(toScreen: view.convert(CGPoint(x: 32, y: 90), to: nil))
        driver.currentScreenPoint = { point }
        driver.receiveNativePointer(point)
        driver.advance(to: 1)
        XCTAssertTrue(driver.isRunning)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        let before = geometryPublications
        view.scrollWheel(with: event)
        XCTAssertEqual(geometryPublications - before, 1, "Each scroll delta must publish one geometry update")
        XCTAssertTrue(driver.currentPointerBlockers.contains(.scroll))
        XCTAssertFalse(driver.isRunning)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(driver.currentPointerBlockers.contains(.scroll))
        XCTAssertNotNil(driver.motion.target, "A stationary pointer must recover after scrolling settles")
    }

    func testCreateCommitsOnlyOnReleaseInsideVisibleTarget() throws {
        var commands: [WorkspaceSidebarAction] = []
        let input = fixture(actions: .init(send: { commands.append($0) }))
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(view.buttonFrame(workspaceName: nil, appId: nil))
        let point = CGPoint(x: target.midX, y: target.midY)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: point))
        XCTAssertTrue(commands.isEmpty)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: .zero))
        XCTAssertTrue(commands.isEmpty)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: point))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: point))
        XCTAssertEqual(commands, [.createWorkspace(projectId: input.projectId, monitorScopeId: input.monitorScopeId)])
        view.detach()
    }

    func testDragKeepsOriginalIdentityAcrossSnapshotRemovalAndFinishesOnce() throws {
        var resolutions = 0
        var ends: [UInt32] = []
        var selections: [String] = []
        let actions = WorkspaceSidebarActions(resolveAppDragWindow: { _, _ in resolutions += 1; return 42 },
            windowDragEnded: { id, _ in ends.append(id) })
        let input = fixture(onSelect: { selections.append($0) }, actions: actions)
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        var workspace = input.workspaces[0].workspace
        let target = try XCTUnwrap(view.buttonFrame(workspaceName: workspace.name, appId: workspace.apps[0].id))
        let point = CGPoint(x: target.midX, y: target.midY)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: point))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: point.x + 8, y: point.y)))
        workspace.apps.removeFirst()
        view.configure(fixture(workspace: workspace, actions: actions))
        view.layoutSubtreeIfNeeded()
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: point))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: point))
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(ends, [42])
        XCTAssertTrue(selections.isEmpty)
        view.detach()
    }

    func testDropUsesCurrentWorkspaceHandlerAndRejectsStaleDestination() throws {
        var payloads: [WorkspaceSidebarDragPayload] = []
        var commands: [WorkspaceSidebarAction] = []
        let input = fixture(onDrop: { payloads.append($0) }, actions: .init(send: { commands.append($0) }))
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(view.geometry?.sections.first)
        XCTAssertEqual(view.dropTarget(at: CGPoint(x: target.midX, y: target.midY)), .workspace(input.workspaces[0].workspace.name))
        XCTAssertTrue(view.performDrop(.window(42), on: .workspace(input.workspaces[0].workspace.name)))
        XCTAssertEqual(payloads, [.window(42)])
        XCTAssertFalse(view.performDrop(.window(42), on: .workspace("removed")))
        XCTAssertTrue(view.performDrop(.tabGroup(43), on: .newWorkspace(projectId: input.projectId, monitorScopeId: input.monitorScopeId)))
        XCTAssertEqual(commands, [.moveTabGroupToNewWorkspace(43, projectId: input.projectId, monitorScopeId: input.monitorScopeId)])
        XCTAssertFalse(view.performDrop(.window(42), on: .newWorkspace(projectId: input.projectId, monitorScopeId: "disconnected")))
        view.detach()
    }

    func testUnattachedNativeViewDoesNotKeepItselfAlive() {
        weak var weakView: WorkspaceSidebarNativeDockView?
        autoreleasepool {
            let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
            view.configure(fixture())
            view.layoutSubtreeIfNeeded()
            weakView = view
        }
        XCTAssertNil(weakView)
    }

    func testHoverKeepsShelfPaddingTightOnEveryEdge() throws {
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            let input = fixture(position: position)
            let horizontal = position == .bottom
            func start(_ rect: CGRect) -> CGFloat { horizontal ? rect.minX : rect.minY }
            func end(_ rect: CGRect) -> CGFloat { horizontal ? rect.maxX : rect.maxY }
            func geometry(_ frame: WorkspaceSidebarDockMotionFrame) -> WorkspaceSidebarNativeDockGeometry {
                // Include a clock-sized control area beyond the lens radius.
                WorkspaceSidebarNativeDockGeometry(size: CGSize(width: 1600, height: 1600),
                    configuration: input.configuration, visibleWidth: input.visibleWidth,
                    compactLength: input.compactLength + 250, leadingLength: input.leadingLength,
                    trailingLength: input.trailingLength + 250, appCounts: [3], showsCreate: true, frame: frame)
            }
            let resting = geometry(.init())
            let first = try XCTUnwrap(resting.icons.first?.first)
            let create = try XCTUnwrap(resting.create)
            let leadingPadding = start(first) - start(resting.surface)
            let trailingPadding = start(resting.trailing) - end(create)
            // Sweep across icons, the create button, and the cold controls.
            for axis in stride(from: start(first), through: end(resting.trailing), by: 8) {
                let point = horizontal ? CGPoint(x: axis, y: first.midY) : CGPoint(x: first.midX, y: axis)
                let hovered = geometry(.init(pointer: point, strength: 1))
                XCTAssertEqual(start(hovered.icons[0][0]) - start(hovered.surface), leadingPadding, accuracy: 0.001)
                XCTAssertEqual(start(hovered.trailing) - end(try XCTUnwrap(hovered.create)), trailingPadding, accuracy: 0.001)
                XCTAssertEqual(hovered.maximumScroll, resting.maximumScroll, accuracy: 0.001)
            }
            let controlPoint = horizontal
                ? CGPoint(x: resting.trailing.maxX - 10, y: first.midY)
                : CGPoint(x: first.midX, y: resting.trailing.maxY - 10)
            let overControl = geometry(.init(pointer: controlPoint, strength: 1))
            XCTAssertEqual(overControl.surface, resting.surface)
            XCTAssertEqual(overControl.icons, resting.icons)
            XCTAssertEqual(overControl.trailing, resting.trailing)
        }
    }

    func testCachedArtworkAndHitFramesUseTheSamePoseOnEveryEdge() throws {
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            let input = fixture(position: position)
            let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
            let parent = NSView(frame: view.frame)
            parent.addSubview(view)
            view.configure(input)
            view.layoutSubtreeIfNeeded()
            let workspace = input.workspaces[0].workspace
            let resting = try XCTUnwrap(view.buttonFrame(workspaceName: workspace.name, appId: workspace.apps[0].id))
            let surface = try XCTUnwrap(view.geometry).surface
            view.render(.init(pointer: CGPoint(x: resting.midX, y: resting.midY), strength: 1))
            let enlarged = try XCTUnwrap(view.buttonFrame(workspaceName: workspace.name, appId: workspace.apps[0].id))
            XCTAssertEqual(enlarged.width, resting.width * 1.5, accuracy: 0.001)
            XCTAssertTrue(input.hitRegions.icons.contains(enlarged))
            XCTAssertEqual(view.hitTest(view.convert(CGPoint(x: enlarged.midX, y: enlarged.midY), to: parent)), view)
            switch position {
                case .left: XCTAssertEqual(enlarged.minX, resting.minX, accuracy: 0.001)
                case .right: XCTAssertEqual(enlarged.maxX, resting.maxX, accuracy: 0.001)
                case .bottom: XCTAssertEqual(enlarged.maxY, resting.maxY, accuracy: 0.001)
            }
            view.render(.init())
            XCTAssertEqual(view.geometry?.surface, surface)
            XCTAssertEqual(view.buttonFrame(workspaceName: workspace.name, appId: workspace.apps[0].id), resting)
            view.detach()
        }
    }

    func testAccessibilityActionsResolveCurrentSnapshotByIdentity() throws {
        var selections: [String] = []
        let input = fixture(onSelect: { selections.append($0) })
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        let children = try XCTUnwrap(view.accessibilityChildren()).compactMap { $0 as? WorkspaceSidebarNativeDockButton }
        let app = try XCTUnwrap(children.first { $0.appId != nil })
        XCTAssertTrue(app.accessibilityPerformPress())
        XCTAssertEqual(selections, [input.workspaces[0].workspace.apps[0].id])
        // A model refresh may remove an icon during a drag. A retained AX element
        // must not activate whichever app happens to inherit its old array index.
        var workspace = input.workspaces[0].workspace
        workspace.apps = []
        view.configure(fixture(workspace: workspace, onSelect: { selections.append($0) }))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(app.accessibilityPerformPress())
        XCTAssertEqual(selections.count, 1)
        view.detach()
    }

    func testOverflowClipsBothAccessibilityAndPointerTargets() throws {
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = sidebarAppIconsTestApps(count: 15)
        let input = fixture(workspace: workspace)
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(view.geometry).maximumScroll, 0)
        XCTAssertNil(view.buttonFrame(workspaceName: workspace.name, appId: workspace.apps.last!.id))
        XCTAssertNil(view.buttonFrame(workspaceName: nil, appId: nil))
        XCTAssertTrue(input.hitRegions.icons.allSatisfy { $0.maxY <= 142 })
        view.detach()
    }

    private func fixture(position: WorkspaceDockPosition = .left,
                         workspace: WorkspaceSidebarWorkspaceViewModel? = nil,
                         onSelect: @escaping (String) -> Void = { _ in },
                         onDrop: @escaping (WorkspaceSidebarDragPayload) -> Void = { _ in },
                         actions: WorkspaceSidebarActions = .init()) -> WorkspaceSidebarNativeDock {
        var config = WorkspaceSidebarConfiguration.empty
        config.showAppIcons = true
        config.dockMagnification = true
        config.dockPosition = position
        config.compactLeftGap = 2
        config.chromeStyle = .solid
        var model = workspace ?? sidebarAppIconsTestWorkspace()
        if workspace == nil { model.apps = sidebarAppIconsTestApps(count: 3) }
        let compactLength = workspaceSidebarDockContentHeight(appCounts: [model.apps.count], configuration: config,
            showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1)
        return WorkspaceSidebarNativeDock(configuration: config, visibleWidth: config.compactRailWidth,
            compactLength: compactLength, leadingLength: 0, trailingLength: position == .bottom ? 32 : 38,
            leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()),
            workspaces: [.init(workspace: model, isActive: true, isEnabled: true, opacity: 1,
                select: { onSelect(model.name) }, selectApp: { onSelect($0.id) }, rename: {}, drop: onDrop)],
            projectId: workspaceProjectDefaultId, monitorScopeId: workspaceSidebarDefaultScopeId,
            showsCreate: true, reduceTransparency: false, blockers: [],
            motion: WorkspaceSidebarDockMotionController(), hitRegions: WorkspaceSidebarDockHitRegions(), actions: actions)
    }

    private func mouseEvent(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
