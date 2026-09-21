import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarNativeDockTest: XCTestCase {
    func testOutgoingCompactRendererCannotOverwriteExpandedHitRegions() throws {
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            var surfaces: [CGRect] = []
            var iconUpdates = 0
            var dropUpdates = 0
            let input = fixture(position: position, actions: .init(
                setDropTargets: { _ in dropUpdates += 1 },
                setSurfaceFrame: { surfaces.append($0) },
                setDockIconFrames: { _ in iconUpdates += 1 }))
            let window = NSWindow(contentRect: CGRect(x: 350, y: 250, width: 800, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let parent = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
            let compact = WorkspaceSidebarNativeDockView(frame: parent.bounds)
            parent.addSubview(compact)
            window.contentView = parent
            compact.configure(input)
            window.orderFrontRegardless()
            compact.layoutSubtreeIfNeeded()
            defer { compact.detach(); window.close() }
            let oldDriver = try XCTUnwrap(compact.subviews.compactMap { $0 as? WorkspaceSidebarDockDisplayLinkView }.first)
            let icon = try XCTUnwrap(compact.geometry?.icons.first?.first)
            let point = window.convertPoint(toScreen: compact.convert(CGPoint(x: icon.midX, y: icon.midY), to: nil))
            oldDriver.currentScreenPoint = { point }
            oldDriver.receiveNativePointer(point)
            oldDriver.advance(to: 1)
            XCTAssertTrue(oldDriver.isRunning)

            // SwiftUI retains the outgoing native view during its transition.
            // The expanded renderer takes the same controller before that view
            // receives dismantleNSView, so both views still have a window here.
            let expandedDriver = WorkspaceSidebarDockDisplayLinkView(frame: parent.bounds)
            expandedDriver.configurePointer(blockers: .expanded, contains: { _ in true })
            parent.addSubview(expandedDriver)
            input.motion.attach(to: expandedDriver)
            XCTAssertFalse(oldDriver.isRunning)
            XCTAssertFalse(oldDriver.isPointerAttached)
            let expanded = workspaceSidebarSurfaceFrame(availableSize: parent.bounds.size,
                visibleWidth: 280, compactHeight: input.compactLength, expansionProgress: 1,
                fitsDockContent: true, compactLeftGap: 2, position: position)
            input.hitRegions.surface = expanded
            input.hitRegions.icons = []
            surfaces.removeAll()
            iconUpdates = 0
            dropUpdates = 0

            // Late tracking, display and layout callbacks must not restore compact
            // surface, icon or drop geometry after expansion has installed its own.
            oldDriver.receiveNativePointer(point)
            oldDriver.advance(to: 2)
            compact.setFrameSize(CGSize(width: 801, height: 800))
            compact.layoutSubtreeIfNeeded()
            compact.render(.init(pointer: CGPoint(x: icon.midX, y: icon.midY), strength: 1))
            XCTAssertNotEqual(compact.geometry?.surface, expanded,
                "The outgoing renderer recomputed compact geometry; it must only suppress publication")
            compact.viewDidChangeBackingProperties()
            XCTAssertTrue(input.motion.owns(expandedDriver), "Backing changes must not reclaim outgoing input")
            XCTAssertTrue(expandedDriver.isPointerAttached)
            XCTAssertEqual(input.hitRegions.surface, expanded)
            XCTAssertTrue(input.hitRegions.icons.isEmpty)
            XCTAssertTrue(surfaces.isEmpty)
            XCTAssertEqual(iconUpdates, 0)
            XCTAssertEqual(dropUpdates, 0)
            XCTAssertFalse(oldDriver.isRunning)
            let outgoingSurface = try XCTUnwrap(compact.geometry?.surface)
            XCTAssertNil(compact.hitTest(compact.convert(CGPoint(x: outgoingSurface.midX, y: outgoingSurface.midY), to: parent)),
                "The outgoing renderer must not intercept the expanded view's clicks")

            // Returning to compact mode reclaims input and publishes fresh geometry.
            compact.configure(input)
            XCTAssertFalse(surfaces.isEmpty)
            XCTAssertEqual(input.hitRegions.surface, compact.geometry?.surface)
            oldDriver.receiveNativePointer(point)
            XCTAssertTrue(oldDriver.isRunning)
        }
    }

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

    func testSurfaceHitTestingPreservesExactRoundedCornersOnEveryEdge() throws {
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            let input = fixture(position: position)
            let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
            let parent = NSView(frame: view.frame)
            parent.addSubview(view)
            view.configure(input)
            view.layoutSubtreeIfNeeded()
            defer { view.detach() }
            let icon = try XCTUnwrap(view.geometry?.icons[0].first)
            for frame in [WorkspaceSidebarDockMotionFrame(), .init(pointer: CGPoint(x: icon.midX, y: icon.midY), strength: 1)] {
                view.render(frame)
                let rect = try XCTUnwrap(view.geometry).surface
                let radius = input.configuration.compactRailWidth / 3
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                let boundaryPoints = [
                    CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
                    CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
                    CGPoint(x: rect.minX + radius, y: rect.minY), CGPoint(x: rect.maxX - radius, y: rect.minY),
                    CGPoint(x: rect.minX + radius, y: rect.maxY), CGPoint(x: rect.maxX - radius, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY + radius), CGPoint(x: rect.minX, y: rect.maxY - radius),
                    CGPoint(x: rect.maxX, y: rect.minY + radius), CGPoint(x: rect.maxX, y: rect.maxY - radius),
                ]
                for boundary in boundaryPoints {
                    let inParent = view.convert(boundary, to: parent)
                    let point = view.convert(inParent, from: parent)
                    let expected = path.contains(point) || input.hitRegions.icons.contains { $0.contains(point) }
                    XCTAssertEqual(view.hitTest(inParent) != nil, expected, "Boundary mismatch at \(point) in \(position)")
                }
                for x in stride(from: rect.minX, through: rect.maxX, by: 8) {
                    for y in stride(from: rect.minY, through: rect.maxY, by: 8) {
                        let inParent = view.convert(CGPoint(x: x, y: y), to: parent)
                        let point = view.convert(inParent, from: parent)
                        let expected = path.contains(point) || input.hitRegions.icons.contains { $0.contains(point) }
                        XCTAssertEqual(view.hitTest(inParent) != nil, expected)
                    }
                }
                for cornerX in [rect.minX - 1, rect.maxX - radius - 1] {
                    for cornerY in [rect.minY - 1, rect.maxY - radius - 1] {
                        for x in stride(from: cornerX, through: cornerX + radius + 2, by: 0.5) {
                            for y in stride(from: cornerY, through: cornerY + radius + 2, by: 0.5) {
                                // Use the same round trip as hitTest; fractional
                                // shelf edges can lose an ulp during y-axis flipping.
                                let inParent = view.convert(CGPoint(x: x, y: y), to: parent)
                                let point = view.convert(inParent, from: parent)
                                let expected = path.contains(point) || input.hitRegions.icons.contains { $0.contains(point) }
                                XCTAssertEqual(view.hitTest(inParent) != nil, expected,
                                    "Corner mismatch at \(point) in \(position)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testManuallyPlacedGlassFollowsShelfThroughLayoutOnEveryEdge() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Native glass requires macOS 26") }
        for position: WorkspaceDockPosition in [.left, .right, .bottom] {
            var input = fixture(position: position, chromeStyle: .liquidGlass)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
            window.contentView = view
            defer { view.detach(); window.contentView = nil; window.close() }
            view.configure(input)
            view.layoutSubtreeIfNeeded()
            let glass = try XCTUnwrap(view.subviews.compactMap { $0 as? NSGlassEffectView }.first)
            let resting = try XCTUnwrap(view.geometry).surface
            let icon = try XCTUnwrap(view.geometry?.icons[0].first)
            // Pointer frames normally bypass configure and AppKit layout entirely.
            view.render(.init(pointer: CGPoint(x: icon.midX, y: icon.midY), strength: 1))
            XCTAssertEqual(glass.frame, view.geometry?.surface)
            XCTAssertNotEqual(glass.frame, resting)
            view.render(.init())
            XCTAssertEqual(glass.frame, resting)
            for point: CGPoint? in [CGPoint(x: icon.midX, y: icon.midY), nil] {
                input.pointerOverride = point
                view.configure(input)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                CATransaction.flush()
                XCTAssertEqual(glass.frame, view.geometry?.surface)
                XCTAssertEqual(glass.cornerRadius, input.configuration.compactRailWidth / 3)
                if point == nil { XCTAssertEqual(glass.frame, resting) }
                else { XCTAssertNotEqual(glass.frame, resting) }
            }
        }
    }

    func testBackingScaleChangeRefreshesCreateArtworkWhenLensScaleIsEqual() throws {
        let window = NativeDockTestScaleWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        window.contentView = view
        defer { view.detach(); window.contentView = nil; window.close() }
        func createImage() throws -> CGImage {
            let rect = try XCTUnwrap(view.geometry?.create)
            let layers = try XCTUnwrap(view.layer?.sublayers).flatMap { $0.sublayers ?? [] }
            let value = try XCTUnwrap(layers.first { $0.frame == rect && $0.contents != nil }?.contents)
            return try XCTUnwrap(CFGetTypeID(value as CFTypeRef) == CGImage.typeID ? (value as! CGImage) : nil)
        }
        window.testScale = 2
        view.configure(fixture(magnificationAmount: 0))
        view.layoutSubtreeIfNeeded()
        let first = try createImage()
        window.testScale = 1
        view.configure(fixture(magnificationAmount: 1))
        view.layoutSubtreeIfNeeded()
        let second = try createImage()
        XCTAssertEqual(first.width, 64)
        XCTAssertEqual(second.width, 32, "Create glyph uses backing scale independently of the equal 2x lens raster scale")
    }

    func testFocusChangesReuseAppArtworkAndUpdateOnlyWorkspaceStyle() throws {
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        var workspace = sidebarAppIconsTestWorkspace()
        workspace.apps = (0..<3).map { .init(name: "App \($0)", bundleId: nil, bundlePath: nil) }
        let input = fixture(workspace: workspace)
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        defer { view.detach() }
        let poses = try XCTUnwrap(view.geometry).icons[0]
        let layers = try XCTUnwrap(view.layer?.sublayers).flatMap { $0.sublayers ?? [] }
        let tiles = try poses.map { pose in try XCTUnwrap(layers.first { $0.frame == pose && $0.contents != nil }) }
        let artwork = try tiles.map { try XCTUnwrap($0.contents as AnyObject?) }
        view.configure(input)
        for (index, tile) in tiles.enumerated() {
            XCTAssertNotNil(tile.superlayer, "An identical snapshot must keep the existing tile")
            XCTAssertTrue(tile.contents as AnyObject? === artwork[index], "An identical snapshot must keep cached artwork")
        }
        view.configure(fixture(workspace: workspace, opacity: 0.72))
        for (index, tile) in tiles.enumerated() {
            XCTAssertNotNil(tile.superlayer, "Opacity must not detach cached artwork")
            XCTAssertTrue(tile.contents as AnyObject? === artwork[index])
            XCTAssertEqual(tile.opacity, 0.72, accuracy: 0.0001)
        }
        view.configure(fixture(workspace: workspace, isActive: false, opacity: 0.72))
        XCTAssertFalse(tiles[0].contents as AnyObject? === artwork[0], "Workspace active styling must still update")
        for index in 1..<tiles.count {
            XCTAssertNotNil(tiles[index].superlayer)
            XCTAssertTrue(tiles[index].contents as AnyObject? === artwork[index], "Focus must not reload app icons")
        }
        var changed = input.workspaces[0].workspace
        changed.apps.removeLast()
        view.configure(fixture(workspace: changed))
        XCTAssertTrue(tiles.allSatisfy { $0.superlayer == nil }, "Structural changes still replace the artwork")
    }

    func testDetachInvalidatesReleasedArtworkCache() throws {
        let view = WorkspaceSidebarNativeDockView(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        defer { view.detach() }
        let input = fixture()
        view.configure(input)
        view.layoutSubtreeIfNeeded()
        let pose = try XCTUnwrap(view.geometry?.icons[0].first)
        let layers = try XCTUnwrap(view.layer?.sublayers).flatMap { $0.sublayers ?? [] }
        let tile = try XCTUnwrap(layers.first { $0.frame == pose && $0.contents != nil })
        view.detach()
        // Dismantling is terminal in SwiftUI. Even an accidental later snapshot
        // must not reuse layers whose image subscriptions have been released.
        view.configure(input)
        XCTAssertNil(tile.superlayer)
        let newPose = try XCTUnwrap(view.geometry?.icons[0].first)
        let newLayers = try XCTUnwrap(view.layer?.sublayers).flatMap { $0.sublayers ?? [] }
        let newTile = try XCTUnwrap(newLayers.first { $0.frame == newPose && $0.contents != nil })
        XCTAssertFalse(newTile === tile, "Released artwork must be replaced with a populated tile")
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
                         isActive: Bool = true, opacity: Double = 1, magnificationAmount: Double = 0.5, chromeStyle: ChromeStyle = .solid,
                         onSelect: @escaping (String) -> Void = { _ in },
                         onDrop: @escaping (WorkspaceSidebarDragPayload) -> Void = { _ in },
                         actions: WorkspaceSidebarActions = .init()) -> WorkspaceSidebarNativeDock {
        var config = WorkspaceSidebarConfiguration.empty
        config.showAppIcons = true
        config.dockMagnification = true
        config.dockMagnificationAmount = magnificationAmount
        config.dockPosition = position
        config.compactLeftGap = 2
        config.chromeStyle = chromeStyle
        var model = workspace ?? sidebarAppIconsTestWorkspace()
        if workspace == nil { model.apps = sidebarAppIconsTestApps(count: 3) }
        let compactLength = workspaceSidebarDockContentHeight(appCounts: [model.apps.count], configuration: config,
            showsCreateWorkspace: true, showsMonitorSelector: false, projectCount: 1)
        return WorkspaceSidebarNativeDock(configuration: config, visibleWidth: config.compactRailWidth,
            compactLength: compactLength, leadingLength: 0, trailingLength: position == .bottom ? 32 : 38,
            leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()),
            workspaces: [.init(workspace: model, isActive: isActive, isEnabled: true, opacity: opacity,
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

@MainActor
private final class NativeDockTestScaleWindow: NSWindow {
    var testScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { testScale }
}
