import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarAllProjectsTest: XCTestCase {
    private func snapshot(position: WorkspaceDockPosition = .bottom) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 64, expandedWidth: 300,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: true, dockPosition: position)
        snapshot.visibleWidth = 300
        snapshot.projects = [
            .init(id: workspaceProjectDefaultId, displayName: "Default", colorHex: nil),
            .init(id: "research", displayName: "Research", colorHex: "#69B5F8"),
            .init(id: "empty-project", displayName: "Empty project", colorHex: nil),
        ]
        snapshot.workspaces = [
            workspace("1", project: workspaceProjectDefaultId, title: "Planning", windowId: 801),
            workspace("2", project: "research", title: "Research notes", windowId: 802),
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

    func testBottomExpandedListIncludesAllProjectsButCompactDockStillPages() {
        for position in WorkspaceDockPosition.allCases {
            let view = WorkspaceSidebarView(snapshot: snapshot(position: position))
            XCTAssertEqual(view.usesExpandedProjectList, position == .bottom)
            XCTAssertEqual(view.currentFilteredProjectWorkspaces().map(\.name), ["1"],
                "The compact shelf continues to show the selected project")
            XCTAssertEqual(view.currentSearchSelections(), position == .bottom
                ? [.window(801), .window(802)]
                : [.window(801)])
            XCTAssertEqual(view.shouldHandleProjectSwipe(horizontalTranslation: 100, verticalTranslation: 0,
                expansionProgress: 1), position != .bottom)
            XCTAssertTrue(view.shouldHandleProjectSwipe(horizontalTranslation: 100, verticalTranslation: 0,
                expansionProgress: 0))
        }
    }

    func testAllProjectsRespectMonitorScope() {
        var fixture = snapshot()
        fixture.selectedMonitorScopeId = "monitor:0,0"
        fixture.workspaces.append(workspace("3", project: "research", title: "Third", windowId: 803))
        let previous = fixture.workspaces.removeLast()
        fixture.workspaces.append(.init(name: previous.name, projectId: previous.projectId,
            displayName: previous.displayName, sidebarLabel: previous.sidebarLabel, isGeneratedName: false,
            monitorScopeId: "monitor:1600,0", monitorName: "External", isFocused: false, isVisible: true,
            items: previous.items))
        let view = WorkspaceSidebarView(snapshot: fixture)
        XCTAssertEqual(view.currentFilteredProjectWorkspaces(allProjects: true).map(\.name), ["1", "2"])
    }

    func testExpandedListRendersWorkspaceAndCreateDropTargetsForEveryProject() throws {
        let fixture = snapshot()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true,
            reduceTransparencyOverride: true)
        let probe = DropTargetProbe()
        let content = view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 300, height: 640)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 640)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        let kinds = probe.targets.map(\.kind)
        XCTAssertTrue(kinds.contains(.workspace("1")))
        XCTAssertTrue(kinds.contains(.workspace("2")), "An inactive project's workspace must be expanded by default")
        for project in fixture.projects {
            XCTAssertTrue(kinds.contains(.newWorkspace(projectId: project.id, monitorScopeId: workspaceSidebarDefaultScopeId)),
                "Every project, including an empty one, must remain reachable")
        }
        let first = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("1") })
        let second = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("2") })
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertTrue(probe.targets.allSatisfy { host.bounds.contains($0.frame) })
        XCTAssertNil(host.window)
        func dragSources(in view: NSView) -> [WorkspaceSidebarWorkspaceDragSourceView] {
            (view as? WorkspaceSidebarWorkspaceDragSourceView).map { [$0] } ?? view.subviews.flatMap(dragSources)
        }
        let sources = dragSources(in: host)
        XCTAssertEqual(sources.count, fixture.workspaces.count)
        for source in sources {
            XCTAssertGreaterThan(source.frame.width, 100)
            XCTAssertEqual(source.frame.height, workspaceSidebarWorkspaceSectionHeaderHeight, accuracy: 0.5)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-projects-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("all-projects.png"))
    }

    func testNativePasteboardDragIsAcceptedByProjectThroughHostingView() async throws {
        let fixture = snapshot()
        let actions = WorkspaceSidebarActions(send: { _ in XCTFail("Drag negotiation must not move a workspace") })
        let view = WorkspaceSidebarView(snapshot: fixture, actions: actions, reduceMotionOverride: true,
            reduceTransparencyOverride: true)
        let probe = DropTargetProbe()
        let content = view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 300, height: 640)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(probe.targets.first { $0.kind == .workspace("2") })
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
        XCTAssertFalse(candidates.isEmpty)
        let destination = try XCTUnwrap(candidates.first {
            _ = $0.draggingEntered(info)
            return $0.draggingUpdated(info).contains(.move)
        })
        XCTAssertNotNil(pasteboard.availableType(from: destination.registeredDraggedTypes))
        // Complete drop delivery requires a WindowServer drag session. This offscreen
        // probe verifies AppKit registration and SwiftUI's provider validation only.
        destination.draggingExited(info)
        destination.draggingEnded(info)
    }
}

@MainActor
private final class DropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}

@MainActor
private final class SidebarWorkspaceDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingSequenceNumber = 1
    let draggingSource: Any?
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    private var itemsByClasses: [String: [NSDraggingItem]] = [:]

    init(window: NSWindow, point: NSPoint, pasteboard: NSPasteboard, source: NSView) {
        draggingDestinationWindow = window
        draggingLocation = point
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}

    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let key = classes.map(NSStringFromClass).joined(separator: ",")
        if itemsByClasses[key] == nil {
            let objects = draggingPasteboard.readObjects(forClasses: classes, options: searchOptions) ?? []
            itemsByClasses[key] = objects.compactMap { ($0 as? NSPasteboardWriting).map(NSDraggingItem.init(pasteboardWriter:)) }
        }
        for (index, item) in (itemsByClasses[key] ?? []).enumerated() {
            var stop: ObjCBool = false
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}
