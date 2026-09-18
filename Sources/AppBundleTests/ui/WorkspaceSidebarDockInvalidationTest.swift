import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockInvalidationTest: XCTestCase {
    func testHeaderMotionKeepsArtworkConstructionStableWhileHitFramesMove() {
        let driver = MotionDriver()
        let builds = ContentReads()
        let artworkReads = ContentReads()
        let geometry = HeaderFrames()
        func header(revision: Int = 0) -> some View {
            WorkspaceSidebarDockHeaderMotion(itemSize: 40, count: 2, availableWidth: 50,
                magnificationEnabled: true, amount: 1, reportsHitFrames: true) {
                builds.count += 1
                return StableArtworkProbe(reads: artworkReads, revision: revision)
                    .modifier(WorkspaceSidebarDockIconMotion(index: 0, itemSize: 40))
            }
            .onPreferenceChange(WorkspaceSidebarDockIconFramesPreference.self) { geometry.frames = $0 }
            .onPreferenceChange(ArtworkRevisionPreference.self) { geometry.revision = $0 }
        }
        let host = NSHostingView(rootView: HeaderMotionRoot(driver: driver, content: header()))
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 300)
        host.layoutSubtreeIfNeeded()
        let initialBuilds = builds.count
        let initialReads = artworkReads.count
        let restingFrames = geometry.frames
        XCTAssertEqual(restingFrames.count, 2)
        for y in [20.0, 65, 30, 70, 40, 60] {
            driver.context = .init(restingSurface: .zero, pointer: CGPoint(x: 32, y: y), strength: 1)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(builds.count, initialBuilds, "Per-frame layout must not reconstruct artwork/action closures")
        XCTAssertEqual(artworkReads.count, initialReads)
        XCTAssertEqual(geometry.frames.count, 2)
        XCTAssertNotEqual(geometry.frames, restingFrames, "Magnified hit regions must still follow rendering")
        let expected = WorkspaceSidebarDockMagnification(itemSize: 40, count: 2, enabled: true, amount: 1)
            .frames(width: 50, pointerY: 60)
        XCTAssertEqual(geometry.frames.first?.width ?? 0, expected[0].width, accuracy: 0.001)
        host.rootView = HeaderMotionRoot(driver: driver, content: header(revision: 1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(geometry.revision, 1, "SwiftUI must adopt the new snapshot's content")
        XCTAssertGreaterThan(artworkReads.count, initialReads)
    }

    func testRapidPointerUpdatesDoNotRebuildContentOutsideLens() {
        let driver = MotionDriver()
        let near = ContentReads()
        let far = ContentReads()
        let content = VStack {
            MagnificationProbe(reads: near)
                .modifier(section(origin: 3))
            MagnificationProbe(reads: far)
                .modifier(section(origin: 1000))
        }
        let host = NSHostingView(rootView: MotionRoot(driver: driver, content: content))
        host.frame = CGRect(x: 0, y: 0, width: 64, height: 900)
        host.layoutSubtreeIfNeeded()
        let initialFarReads = far.count
        let initialNearReads = near.count
        for y in [30.0, 90, 40, 80, 35, 85, 45, 75] {
            driver.context = .init(restingSurface: .zero, pointer: CGPoint(x: 32, y: y), strength: 1)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(near.count, initialNearReads, "The active lens must still render new geometry")
        XCTAssertEqual(far.count, initialFarReads, "Unchanged sections must not rebuild their controls on every frame")
        XCTAssertNil(far.last?.pointerY)
        XCTAssertNotNil(near.last?.pointerY)

        // Crossing into the other section changes its lens without replacing its content.
        driver.context.pointer = CGPoint(x: 32, y: 1040)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(far.count, initialFarReads)
        XCTAssertNotNil(far.last?.pointerY)
        XCTAssertNil(near.last?.pointerY)
    }

    func testPreparedOriginsKeepSharedColumnMappingThroughSeparators() {
        let counts = [1, 0, 4, 2]
        let origins = workspaceSidebarDockSectionOrigins(appCounts: counts, itemSize: 40)
        XCTAssertEqual(origins, [3, 99, 151, 379])
        for pointer: CGFloat in stride(from: -200, through: 900, by: 17) {
            for strength: CGFloat in [0, 0.2, 1] {
                let column = WorkspaceSidebarDockColumnMagnification(appCounts: counts,
                    itemSize: 40, amount: 0.7, pointerY: pointer, strength: strength)
                for index in counts.indices {
                    let layout = WorkspaceSidebarDockMagnification(itemSize: 40, count: 1 + counts[index],
                        enabled: true, amount: 0.7)
                    XCTAssertEqual(layout.sectionMagnification(pointerY: pointer - origins[index], strength: strength),
                        column.sections[index])
                }
            }
        }
    }

    private func section(origin: CGFloat) -> WorkspaceSidebarDockSectionMotion {
        .init(columnOrigin: 0, sectionOrigin: origin, itemSize: 40, appCount: 4,
            amount: 1, isEnabled: true)
    }
}

@MainActor
private final class HeaderFrames {
    var frames: [CGRect] = []
    var revision = 0
}

private struct ArtworkRevisionPreference: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = nextValue() }
}

private struct HeaderMotionRoot<Content: View>: View {
    @ObservedObject var driver: MotionDriver
    let content: Content
    var body: some View {
        content.environment(\.workspaceSidebarDockSectionMagnification,
            .init(pointerY: driver.context.pointer?.y, strength: driver.context.strength))
            .coordinateSpace(name: "workspaceSidebarContent")
    }
}

private struct StableArtworkProbe: View {
    let reads: ContentReads
    let revision: Int
    var body: some View {
        reads.count += 1
        return (revision == 0 ? Color.blue : Color.red).frame(width: 40, height: 40)
            .preference(key: ArtworkRevisionPreference.self, value: revision)
    }
}

@MainActor
private final class ContentReads {
    var count = 0
    var last: WorkspaceSidebarDockSectionMagnification?
}

@MainActor
private final class MotionDriver: ObservableObject {
    @Published var context = WorkspaceSidebarDockLayoutContext()
}

private struct MotionRoot<Content: View>: View {
    @ObservedObject var driver: MotionDriver
    let content: Content
    var body: some View { content.environment(\.workspaceSidebarDockLayoutContext, driver.context) }
}

private struct MagnificationProbe: View {
    let reads: ContentReads
    @Environment(\.workspaceSidebarDockSectionMagnification) private var magnification
    var body: some View {
        reads.count += 1
        reads.last = magnification
        return Color.clear.frame(width: 40, height: 40)
    }
}
