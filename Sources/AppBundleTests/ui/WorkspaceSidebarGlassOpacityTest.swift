import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarGlassOpacityTest: XCTestCase {
    func testSidebarKeepsDarkBackdropRegardlessOfDockOpacityOrStyle() throws {
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

    func testExpandedDockUsesSidebarBackgroundRegardlessOfDockOpacity() throws {
        let sidebar = try render(opacity: 1, dockMode: false)
        let expected = try XCTUnwrap(sidebar.tiffRepresentation)
        for opacity in [0.0, 0.4, 1.0] {
            let expanded = try render(opacity: opacity, dockMode: true, progress: 1, alwaysExpanded: true)
            XCTAssertEqual(try XCTUnwrap(expanded.tiffRepresentation), expected)
        }
    }

    func testExpandingTransparentDockGraduallyAddsOpaqueSidebarBackground() throws {
        // Native glass needs WindowServer; the opaque option exercises the same fade
        // in detached rendering without mistaking a missing native backdrop for a gap.
        let originalForeground = try color(render(opacity: 0, dockMode: true, sidebarBlur: false), at: CGPoint(x: 40, y: 40))
        var previousAlpha: CGFloat = -1
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let bitmap = try render(opacity: 0, dockMode: true, progress: progress, sidebarBlur: false, alwaysExpanded: true)
            let background = try color(bitmap, at: CGPoint(x: 10, y: 10))
            XCTAssertGreaterThan(background.alphaComponent, previousAlpha)
            previousAlpha = background.alphaComponent
            let foreground = try color(bitmap, at: CGPoint(x: 40, y: 40))
            XCTAssertEqual(foreground.greenComponent, originalForeground.greenComponent, accuracy: 0.001)
            XCTAssertEqual(foreground.alphaComponent, 1, accuracy: 0.01)
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

    func testOpaqueAppearanceRemainsOpaqueThroughoutExpansion() throws {
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let solid = try render(opacity: 0.2, style: .solid, dockMode: true, progress: progress, sidebarBlur: false)
            XCTAssertEqual(try color(solid, at: CGPoint(x: 10, y: 10)).alphaComponent, 1, accuracy: 0.01)
            for opacity in [0.0, 0.4, 1.0] {
                let accessible = try render(opacity: opacity, dockMode: true, progress: progress, reduceTransparency: true)
                XCTAssertEqual(try color(accessible, at: CGPoint(x: 10, y: 10)).alphaComponent, 1, accuracy: 0.01)
            }
        }
    }

    func testSidebarDarknessOnlyStrengthensTheBackgroundOverlay() throws {
        var previousBrightness: CGFloat = 2
        var previousForeground: NSColor?
        for darkness in [0.0, 0.3, 0.7, 1.0] {
            let bitmap = try render(opacity: 1, sidebarDarkness: darkness, whiteBackdrop: true)
            let background = try color(bitmap, at: CGPoint(x: 10, y: 10))
            let brightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
            XCTAssertLessThan(brightness, previousBrightness)
            previousBrightness = brightness
            let foreground = try color(bitmap, at: CGPoint(x: 40, y: 40))
            if let previousForeground {
                XCTAssertEqual(foreground.greenComponent, previousForeground.greenComponent, accuracy: 0.001)
            }
            XCTAssertEqual(foreground.alphaComponent, 1, accuracy: 0.01)
            previousForeground = foreground
        }
    }

    func testAppearancePreferencesReachSidebarSnapshot() {
        let previous = config
        defer { config = previous }
        config.workspaceSidebar.dockAppearance.glassOpacity = 0.35
        config.workspaceSidebar.showAppIcons = true
        let snapshot = workspaceSidebarConfiguration()
        XCTAssertEqual(snapshot.glassOpacity, 0.35)
        XCTAssertTrue(snapshot.showAppIcons)
    }

    private func render(opacity: Double, style: ChromeStyle = .liquidGlass, dockMode: Bool = false,
                        progress: Double = 0, sidebarBlur: Bool = true, sidebarDarkness: Double = 0.7,
                        reduceTransparency: Bool = false, whiteBackdrop: Bool = false,
                        alwaysExpanded: Bool = false) throws -> NSBitmapImageRep {
        var snapshot = WorkspaceSidebarSnapshot.empty
        // Only a pinned Dock morphs its own surface; a collapsible Dock opens floating columns.
        snapshot.configuration.alwaysExpanded = alwaysExpanded
        snapshot.configuration.chromeStyle = style
        snapshot.configuration.glassOpacity = opacity
        snapshot.configuration.showAppIcons = dockMode
        snapshot.configuration.sidebarBlur = sidebarBlur
        snapshot.configuration.sidebarBackgroundOpacity = sidebarDarkness
        snapshot.configuration.collapsedWidth = 64
        snapshot.configuration.expandedWidth = 240
        snapshot.visibleWidth = 64 + 176 * progress
        let sidebar = WorkspaceSidebarView(snapshot: snapshot, reduceTransparencyOverride: reduceTransparency)
        let content = ZStack {
            sidebar.sidebarSurface(in: Rectangle())
            Rectangle().fill(Color(red: 0, green: 1, blue: 0)).frame(width: 12, height: 12)
        }
        .frame(width: 80, height: 80)
        .background(whiteBackdrop ? Color.white : .clear)
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
