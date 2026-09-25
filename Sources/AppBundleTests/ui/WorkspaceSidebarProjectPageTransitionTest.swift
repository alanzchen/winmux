import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarProjectPageTransitionTest: XCTestCase {
    private let research = WorkspaceProjectId("research")
    private let paper = WorkspaceProjectId("paper")

    func testPagesMoveInTheSwitchersOrder() {
        let projects = snapshot(active: workspaceProjectDefaultId).projects
        XCTAssertEqual(workspaceSidebarProjectPageDirection(from: workspaceProjectDefaultId, to: paper, projects: projects), 1)
        XCTAssertEqual(workspaceSidebarProjectPageDirection(from: paper, to: research, projects: projects), -1)
        XCTAssertNil(workspaceSidebarProjectPageDirection(from: paper, to: paper, projects: projects))
        XCTAssertNil(workspaceSidebarProjectPageDirection(from: WorkspaceProjectId("deleted"), to: paper, projects: projects),
            "A project deleted meanwhile has no page to slide out")
    }

    func testOnlyTheTwoPagesMoveAndReduceMotionCrossfades() {
        let start = workspaceSidebarProjectPagePlacements(direction: 1, progress: 0, pageWidth: 300, reduceMotion: false)
        XCTAssertEqual(start.outgoing, .init(offset: 0, opacity: 1), "The old page starts where it was")
        XCTAssertEqual(start.incoming, .init(offset: 300, opacity: 1), "The new one waits just beside it")
        let middle = workspaceSidebarProjectPagePlacements(direction: -1, progress: 0.5, pageWidth: 300, reduceMotion: false)
        XCTAssertEqual(middle.outgoing.offset, 150, "Moving to an earlier project slides right")
        XCTAssertEqual(middle.incoming.offset, -150)
        let end = workspaceSidebarProjectPagePlacements(direction: 1, progress: 1.4, pageWidth: 300, reduceMotion: false)
        XCTAssertEqual(end.incoming, .init(offset: 0, opacity: 1))
        XCTAssertEqual(end.outgoing.offset, -300)

        let fade = workspaceSidebarProjectPagePlacements(direction: 1, progress: 0.25, pageWidth: 300, reduceMotion: true)
        XCTAssertEqual(fade.outgoing, .init(offset: 0, opacity: 0.75))
        XCTAssertEqual(fade.incoming, .init(offset: 0, opacity: 0.25))
    }

    func testTheEasingMatchesTheSlidesCurve() {
        XCTAssertEqual(workspaceSidebarProjectPageEasing(0), 0, accuracy: 0.001)
        XCTAssertEqual(workspaceSidebarProjectPageEasing(1), 1, accuracy: 0.001)
        XCTAssertEqual(workspaceSidebarProjectPageEasing(2), 1, accuracy: 0.001)
        XCTAssertGreaterThan(workspaceSidebarProjectPageEasing(0.3), 0.6, "Most of the way there early, then settles")
        var previous: CGFloat = 0
        for step in 1...20 {
            let value = workspaceSidebarProjectPageEasing(Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testASwitchThatInterruptsAnotherPicksThePagesUpWhereTheyAre() throws {
        var first = workspaceSidebarProjectPageTransition(id: 1, from: workspaceProjectDefaultId, to: research, direction: 1,
            reducesMotion: false, interrupting: nil, at: 100)
        XCTAssertEqual(first.outgoingStart, 0)
        XCTAssertEqual(first.incomingStart, 1)
        XCTAssertEqual(first.positions(at: 200).incoming, 1, "Until the slide starts, nothing has moved")
        first.startedUptime = 100
        let halfway = 100 + workspaceSidebarProjectPageTransitionDuration / 2
        let positions = first.positions(at: halfway)
        XCTAssertLessThan(positions.incoming, 1)
        XCTAssertGreaterThan(positions.incoming, 0, "Research is still sliding in")

        let onward = workspaceSidebarProjectPageTransition(id: 2, from: research, to: paper, direction: 1,
            reducesMotion: false, interrupting: first, at: halfway)
        XCTAssertEqual(onward.outgoingStart, positions.incoming, accuracy: 0.0001, "Research leaves from where it had got to")
        XCTAssertEqual(onward.incomingStart, positions.incoming + 1, accuracy: 0.0001, "Paper follows right behind it")
        let start = workspaceSidebarProjectPagePlacements(direction: 1, progress: 0, pageWidth: 300, reduceMotion: false,
            outgoingStart: onward.outgoingStart, incomingStart: onward.incomingStart)
        XCTAssertEqual(start.outgoing.offset, positions.incoming * 300, accuracy: 0.001)

        let back = workspaceSidebarProjectPageTransition(id: 3, from: research, to: workspaceProjectDefaultId, direction: -1,
            reducesMotion: false, interrupting: first, at: halfway)
        XCTAssertEqual(back.incomingStart, positions.outgoing, accuracy: 0.0001, "Going straight back reverses both pages")

        let settled = workspaceSidebarProjectPageTransition(id: 4, from: research, to: paper, direction: 1,
            reducesMotion: false, interrupting: first, at: 100 + 5)
        XCTAssertEqual(settled.outgoingStart, 0, accuracy: 0.001, "A finished switch leaves its page in place")
        let unrelated = workspaceSidebarProjectPageTransition(id: 5, from: paper, to: research, direction: -1,
            reducesMotion: false, interrupting: first, at: halfway)
        XCTAssertEqual(unrelated.outgoingStart, 0)
    }

    func testOnlyTheSwitchingPagesLeaveTheirSlotsHoweverFarApart() throws {
        let transition = workspaceSidebarProjectPageTransition(id: 1, from: paper, to: workspaceProjectDefaultId,
            direction: -1, reducesMotion: false, interrupting: nil, at: 0)
        func placement(_ projectId: WorkspaceProjectId, index: Int, progress: CGFloat,
                       displayed: WorkspaceProjectId? = workspaceProjectDefaultId) -> WorkspaceSidebarProjectPagePlacement? {
            workspaceSidebarProjectPageSlotPlacement(projectId: projectId, index: index, displayIndex: 0,
                displayedProjectId: displayed, transition: transition, progress: progress, pageWidth: 300)
        }
        XCTAssertEqual(placement(paper, index: 2, progress: 0)?.offset, -600,
            "The old page, two slots away, starts in view")
        XCTAssertEqual(placement(paper, index: 2, progress: 1)?.offset, -300, "and leaves to the right")
        XCTAssertEqual(placement(workspaceProjectDefaultId, index: 0, progress: 0)?.offset, -300, "The new page enters from the left")
        XCTAssertNil(placement(research, index: 1, progress: 0.5), "The project in between never shows")
        XCTAssertNil(placement(paper, index: 2, progress: 0.5, displayed: research),
            "A pager showing another project ignores the switch")
    }

    func testAHiddenNameTakesNoRoomButKeepsItsSize() {
        func width(revealed: Bool) -> CGFloat {
            NSHostingView(rootView: WorkspaceSidebarRevealedWidthLayout(isRevealed: revealed, maxWidth: 120) {
                Text("Research").font(.system(size: 12, weight: .semibold))
            }.fixedSize()).fittingSize.width
        }
        XCTAssertEqual(width(revealed: false), 0)
        XCTAssertGreaterThan(width(revealed: true), 30)
        let long = NSHostingView(rootView: WorkspaceSidebarRevealedWidthLayout(isRevealed: true, maxWidth: 60) {
            Text(String(repeating: "Platform Paper ", count: 4)).lineLimit(1)
        }.fixedSize()).fittingSize.width
        XCTAssertLessThanOrEqual(long, 60, "A long name truncates at the limit")
    }

    func testSwitchingProjectsSlidesThePagesAndSettlesOnTheNewProject() throws {
        let size = CGSize(width: 300, height: 420)
        let (host, window) = hosted(sidebar(active: workspaceProjectDefaultId), size: size)
        defer { window.close() }
        settle(host, for: 0.2)
        let before = try capture(host)

        // Jump two projects to the right, as a click on the last emoji does.
        host.rootView = sidebar(active: paper)
        settle(host, for: 0.1)
        let during = try capture(host)
        settle(host, for: workspaceSidebarProjectPageTransitionDuration + 0.3)
        let after = try capture(host)

        let (reference, referenceWindow) = hosted(sidebar(active: paper), size: size)
        defer { referenceWindow.close() }
        settle(reference, for: 0.2)
        let expected = try capture(reference)

        try save([before, during, after], name: "project-switch-transition.png")
        XCTAssertNotEqual(during.tiffRepresentation, before.tiffRepresentation, "The switch is under way")
        XCTAssertNotEqual(during.tiffRepresentation, after.tiffRepresentation, "It animates rather than jumping")
        XCTAssertEqual(pixelDifference(after, expected), 0, accuracy: 0.002,
            "Once settled it looks exactly like the new project shown directly")
    }

    // MARK: - Fixtures

    private func sidebar(active: WorkspaceProjectId) -> WorkspaceSidebarView {
        WorkspaceSidebarView(snapshot: snapshot(active: active), reduceMotionOverride: false, reduceTransparencyOverride: true)
    }

    private func snapshot(active: WorkspaceProjectId) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 64, expandedWidth: 300,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false,
            chromeStyle: .solid, solidChromeColor: .midnight, solidChromeCustomColor: "#191B20",
            showAppIcons: false, dockPosition: .left, compactLeftGap: 2)
        snapshot.visibleWidth = 300
        snapshot.activeProjectId = active
        snapshot.projects = [
            .init(id: workspaceProjectDefaultId, displayName: "Default", colorHex: "#7BA3C9", emoji: "🏠"),
            .init(id: research, displayName: "Research", colorHex: "#69B5F8", emoji: "🔬"),
            .init(id: paper, displayName: "Paper", colorHex: "#9B8FC4", emoji: "📄"),
        ]
        snapshot.workspaces = [
            workspace("1", project: workspaceProjectDefaultId, title: "Planning", windowId: 801),
            workspace("2", project: workspaceProjectDefaultId, title: "Inbox", windowId: 802),
            workspace("3", project: research, title: "Research notes", windowId: 803),
            workspace("4", project: paper, title: "Paper draft", windowId: 804),
            workspace("5", project: paper, title: "Figures", windowId: 805),
            workspace("6", project: paper, title: "References", windowId: 806),
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

    /// In an offscreen window, so animations run and both captures render the same way.
    private func hosted(_ view: WorkspaceSidebarView, size: CGSize) -> (NSHostingView<WorkspaceSidebarView>, NSWindow) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    private func settle(_ host: NSView, for seconds: TimeInterval) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        host.layoutSubtreeIfNeeded()
    }

    private func capture(_ host: NSView) throws -> NSImage {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// The share of pixels that differ noticeably.
    private func pixelDifference(_ lhs: NSImage, _ rhs: NSImage) -> Double {
        guard let a = lhs.representations.first as? NSBitmapImageRep, let b = rhs.representations.first as? NSBitmapImageRep,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh
        else { return 1 }
        var different = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.06 { different += 1 }
            }
        }
        return Double(different) / Double((a.pixelsWide / 2) * (a.pixelsHigh / 2))
    }

    private func save(_ frames: [NSImage], name: String) throws {
        let content = HStack(spacing: 10) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, image in Image(nsImage: image) }
        }
        .padding(12).background(Color(white: 0.3))
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = projectRoot.appendingPathComponent(".build/sidebar-appearance-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
