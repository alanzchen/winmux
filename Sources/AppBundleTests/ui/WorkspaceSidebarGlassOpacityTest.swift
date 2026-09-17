import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarGlassOpacityTest: XCTestCase {
    func testSidebarKeepsOriginalDarkMaterialRegardlessOfDockOpacityOrStyle() throws {
        let original = try render(opacity: 1, dockMode: false)
        let originalData = try XCTUnwrap(original.tiffRepresentation)
        for style: ChromeStyle in [.liquidGlass, .solid] {
            for opacity in [0.0, 0.4, 1.0] {
                let bitmap = try render(opacity: opacity, style: style, dockMode: false)
                XCTAssertEqual(try XCTUnwrap(bitmap.tiffRepresentation), originalData)
            }
        }
    }

    func testNativeDockOpacityAndForeground() throws {
        try verifyGlassOpacity(dockMode: true)
    }

    func testDockUsesOneSurfaceAcrossCompactAndExpandedStates() throws {
        // WindowServer owns native glass, but a second dark Sidebar scrim would still
        // change detached-rendering pixels as the Dock expands.
        let compact = try render(opacity: 1, dockMode: true, progress: 0)
        let expected = try XCTUnwrap(compact.tiffRepresentation)
        for progress in [0.25, 0.5, 0.75, 1.0] {
            let expanded = try render(opacity: 1, dockMode: true, progress: progress)
            XCTAssertEqual(try XCTUnwrap(expanded.tiffRepresentation), expected)
        }
    }

    private func verifyGlassOpacity(dockMode: Bool) throws {
        let transparent = try render(opacity: 0, dockMode: dockMode)
        let translucent = try render(opacity: 0.4, dockMode: dockMode)
        let original = try render(opacity: 1, dockMode: dockMode)

        let clearBackground = try color(transparent, at: CGPoint(x: 10, y: 10))
        let partialBackground = try color(translucent, at: CGPoint(x: 10, y: 10))
        let originalBackground = try color(original, at: CGPoint(x: 10, y: 10))
        XCTAssertLessThan(clearBackground.alphaComponent, 0.01)

        let originalForeground = try color(original, at: CGPoint(x: 40, y: 40))
        XCTAssertGreaterThan(originalForeground.greenComponent, 0.9)
        for bitmap in [transparent, translucent, original] {
            let foreground = try color(bitmap, at: CGPoint(x: 40, y: 40))
            XCTAssertEqual(foreground.alphaComponent, 1, accuracy: 0.01)
            XCTAssertEqual(foreground.greenComponent, originalForeground.greenComponent, accuracy: 0.001)
            XCTAssertEqual(foreground.redComponent, originalForeground.redComponent, accuracy: 0.001)
            XCTAssertEqual(foreground.blueComponent, originalForeground.blueComponent, accuracy: 0.001)
        }
        if dockMode, originalBackground.alphaComponent < 0.01 {
            throw XCTSkip("Native Liquid Glass is composed by WindowServer; detached bitmap rendering cannot measure its background. Foreground checks passed; validate material opacity in the native preview.")
        }
        XCTAssertGreaterThan(partialBackground.alphaComponent, clearBackground.alphaComponent + 0.05)
        XCTAssertGreaterThan(originalBackground.alphaComponent, partialBackground.alphaComponent + 0.1)
    }

    func testSolidDockKeepsItsOpacity() throws {
        for opacity in [0.0, 0.4, 1.0] {
            let bitmap = try render(opacity: opacity, style: .solid, dockMode: true)
            XCTAssertEqual(try color(bitmap, at: CGPoint(x: 10, y: 10)).alphaComponent, 1, accuracy: 0.01)
        }
    }

    func testAppearancePreferencesReachSidebarSnapshot() {
        let previous = config
        defer { config = previous }
        config.workspaceSidebar.glassOpacity = 0.35
        config.workspaceSidebar.showAppIcons = true
        let snapshot = workspaceSidebarConfiguration()
        XCTAssertEqual(snapshot.glassOpacity, 0.35)
        XCTAssertTrue(snapshot.showAppIcons)
    }

    private func render(opacity: Double, style: ChromeStyle = .liquidGlass, dockMode: Bool = false,
                        progress: Double = 0) throws -> NSBitmapImageRep {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.chromeStyle = style
        snapshot.configuration.glassOpacity = opacity
        snapshot.configuration.showAppIcons = dockMode
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.visibleWidth = 64 + 176 * progress
        let sidebar = WorkspaceSidebarView(snapshot: snapshot)
        let content = ZStack {
            sidebar.sidebarSurface(in: Rectangle())
            Rectangle().fill(Color(red: 0, green: 1, blue: 0)).frame(width: 12, height: 12)
        }
        .frame(width: 80, height: 80)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ bitmap: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / 80
        return try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }
}
