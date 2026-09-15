import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarRenderingTest: XCTestCase {
    func testCompactMonitorControlPaintFitsMinimumAndDefaultRailWidths() throws {
        let scopes: [WorkspaceSidebarMonitorScopeViewModel] = [
            .init(id: "default", displayName: "Default", subtitle: nil, systemImageName: "display", isFocusedMonitor: false),
            .init(id: "focused", displayName: "Focus", subtitle: nil, systemImageName: "scope", isFocusedMonitor: false),
            .init(id: "monitor:0,0", displayName: "Main", subtitle: nil, systemImageName: "display", isFocusedMonitor: true),
            .init(id: "monitor:1920,0", displayName: "External display", subtitle: nil, systemImageName: "display", isFocusedMonitor: false),
            .init(id: "monitor:3840,0", displayName: "Third display", subtitle: nil, systemImageName: "display", isFocusedMonitor: false),
        ]
        for railWidth: CGFloat in [28, 44] {
            var renderedSelections: Set<Data> = []
            for (scopeIndex, scope) in scopes.enumerated() {
                let content = WorkspaceSidebarCompactMonitorSelector(
                    scopes: scopes,
                    selectedScopeId: scope.id,
                    sectionWidth: railWidth - 14,
                    onSelectScope: { _ in },
                )
                .padding(.horizontal, 7)
                .frame(width: railWidth, height: 40)
                .environment(\.colorScheme, .dark)
                .padding(16)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: railWidth + 32, height: 72)
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window, "Rendering must not open or activate a window")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try save(bitmap, name: "compact-monitor-rail-\(Int(railWidth))-scope-\(scopeIndex)")
                renderedSelections.insert(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))

                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let allowed = CGRect(x: 15, y: 15, width: railWidth + 2, height: 42)
                var paintedPixels = 0
                var overflowingPixels = 0
                for y in 0 ..< bitmap.pixelsHigh {
                    for x in 0 ..< bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                        paintedPixels += 1
                        if !allowed.contains(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)) {
                            overflowingPixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(paintedPixels, 10, "The native menu must actually render")
                XCTAssertEqual(overflowingPixels, 0, "The native menu paints beyond the \(railWidth)-point rail")
            }
            XCTAssertEqual(renderedSelections.count, scopes.count, "Default, Focus, and each physical display must be visually distinct")
        }
    }

    func testOccupiedWarningFitsAvailableCardWidthAndHeight() throws {
        for sidebarWidth: CGFloat in [120, 240] {
            let cardWidth = sidebarWidth - 24
            let warning = WorkspaceSidebarInUseOverrideOverlay(
                text: "In use on External display with a long descriptive name",
                onOverride: {},
                onCancel: {},
            )
            .frame(width: cardWidth)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: warning)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(rendered.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            try save(bitmap, name: "occupied-warning-sidebar-\(Int(sidebarWidth))")
            print("Occupied warning at sidebar width \(sidebarWidth): \(rendered.size)")
            XCTAssertEqual(rendered.size.width, cardWidth, accuracy: 0.5)
            XCTAssertGreaterThan(rendered.size.height, 40, "Text and both actions must render")
            XCTAssertLessThanOrEqual(rendered.size.height, workspaceSidebarInUseOverrideMinHeight(sectionWidth: cardWidth) + 0.5)
        }
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/issue-fixes-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
