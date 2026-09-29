import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

/// A browser window with one tab shows that tab's website icon in place of the browser's.
final class WorkspaceSidebarWindowIconTest: XCTestCase {
    private let red = String(repeating: "a", count: 64)
    private let blue = String(repeating: "b", count: 64)
    private let green = String(repeating: "c", count: 64)

    private func snapshot(_ id: UInt32, icons: [String?], origins: [URL?]? = nil) -> BrowserWindowTabs {
        let session = UUID()
        return .init(windowId: id, pid: 7, windowSession: session, tabs: icons.enumerated().map { index, icon in
            .init(target: .init(windowId: id, pid: 7, windowSession: session, tabId: UUID()), title: "Tab \(index)",
                isSelected: index == 0, iconOrigin: origins?[index], siteIcon: icon)
        })
    }

    /// No app, so the fallback is a grey glyph that no website color is mistaken for.
    private func window(_ id: UInt32, title: String = "Page") -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: "\(id)", appName: "Browser", appBundleId: nil, appBundlePath: nil,
            title: title, isFocused: false)
    }

    func testAWindowWithOneTabTakesItsWebsiteIconAndAGroupKeepsItsBrowsers() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.com"))
        let info = WorkspaceSidebarBrowserWindows([
            1: snapshot(1, icons: [red]),
            2: snapshot(2, icons: [nil], origins: [origin]),
            3: snapshot(3, icons: [red, blue]),
            4: snapshot(4, icons: [nil]),
        ], windows: [])
        XCTAssertEqual(info.siteIcons[1], .init(key: red, origin: nil), "The Safari extension's icon")
        XCTAssertEqual(info.siteIcons[2], .init(key: nil, origin: origin), "A Chromium tab's fetched icon")
        XCTAssertNil(info.siteIcons[3], "A group's row keeps the browser's icon above its tabs'")
        XCTAssertNil(info.siteIcons[4], "No icon known: the browser's")
        XCTAssertNil(info.siteIcons[5])
    }

    private func png(_ color: NSColor) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(NSImage(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
    }

    /// How many pixels of the rendered view are mostly one color.
    @MainActor
    private func pixels(_ host: NSView, _ color: (NSColor) -> Bool) throws -> Int {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color(pixel) { count += 1 }
            }
        }
        return count
    }

    private func isRed(_ pixel: NSColor) -> Bool { pixel.redComponent > 0.8 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3 }
    private func isBlue(_ pixel: NSColor) -> Bool { pixel.blueComponent > 0.8 && pixel.redComponent < 0.3 && pixel.greenComponent < 0.3 }
    private func isGreen(_ pixel: NSColor) -> Bool { pixel.greenComponent > 0.6 && pixel.redComponent < 0.3 && pixel.blueComponent < 0.3 }

    @MainActor
    func testAWindowsRowShowsItsWebsiteIconAndFollowsThePageItShows() throws {
        SafariExtensionIcons.shared.images = [red: try png(.red), blue: try png(.blue)]
        defer { SafariExtensionIcons.shared.images = [:] }
        let row = window(1)
        func show(_ icons: [String?]) -> NSHostingView<AnyView> {
            let info = WorkspaceSidebarBrowserWindows([1: snapshot(1, icons: icons)], windows: [row])
            return NSHostingView(rootView: AnyView(WorkspaceSidebarTabRowView(window: row, indent: 0, isSearchSelected: false,
                isDragSource: false, actions: WorkspaceSidebarActions(), onSelect: {})
                .frame(width: 260).environment(\.workspaceSidebarBrowserWindows, info).environment(\.colorScheme, .light)))
        }
        let host = show([red])
        host.frame = CGRect(x: 0, y: 0, width: 260, height: workspaceSidebarTabRowHeight)
        let scale = CGFloat(try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)).pixelsWide) / host.bounds.width
        let iconArea = 0.8 * pow(workspaceSidebarTabIconSize * scale, 2)
        XCTAssertGreaterThan(CGFloat(try pixels(host, isRed)), iconArea, "The tab's website icon fills the icon column")
        // The page navigates: the same row, given the next snapshot, shows the new site's icon.
        host.rootView = show([blue]).rootView
        XCTAssertEqual(try pixels(host, isRed), 0)
        XCTAssertGreaterThan(CGFloat(try pixels(host, isBlue)), iconArea)
        host.rootView = show([green]).rootView
        XCTAssertEqual(try pixels(host, isBlue), 0, "An icon not made yet shows the browser's, not the old site's")
        XCTAssertEqual(try pixels(host, isGreen), 0)
        host.rootView = show([red, blue]).rootView
        XCTAssertEqual(try pixels(host, isRed) + pixels(host, isBlue), 0, "A group's header keeps the browser's icon")
    }

    /// The Tabs sidebar gives its rows and pinned tiles what the browser read: a pinned window
    /// and a listed one, each with one tab, show their sites; a group's header doesn't.
    @MainActor
    func testTheTabsSidebarsRowsAndPinnedTilesShowTheirTabsWebsiteIcons() throws {
        SafariExtensionIcons.shared.images = [red: try png(.red), blue: try png(.blue), green: try png(.green)]
        defer { SafariExtensionIcons.shared.images = [:] }
        func workspace(_ window: WorkspaceSidebarWindowViewModel, pinned: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: window.workspaceName, projectId: workspaceProjectDefaultId, displayName: window.workspaceName, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: false,
                items: [.init(kind: .window(window))], appearance: .init(isFavorite: pinned))
        }
        var sidebar = WorkspaceSidebarSnapshot.empty
        sidebar.configuration.usesTabsList = true
        sidebar.configuration.expandedWidth = 280
        sidebar.configuration.collapsedWidth = 44
        sidebar.visibleWidth = 280
        sidebar.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        sidebar.workspaces = [workspace(window(1, title: "Pinned"), pinned: true), workspace(window(2, title: "Listed")),
            workspace(window(3, title: "Group"))]
        let model = BrowserTabsModel(snapshots: [1: snapshot(1, icons: [red]), 2: snapshot(2, icons: [blue]),
            3: snapshot(3, icons: [nil, green])])
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: sidebar, reduceMotionOverride: true,
            reduceTransparencyOverride: true, browserTabsModel: model).frame(width: 280, height: 480).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 480)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        XCTAssertGreaterThan(CGFloat(try pixels(host, isRed)), 0.8 * pow(18 * scale, 2), "The pinned tile shows its site")
        XCTAssertGreaterThan(CGFloat(try pixels(host, isBlue)), 0.8 * pow(workspaceSidebarTabIconSize * scale, 2),
            "The listed window's row shows its site")
        // The group's second tab row shows green; its header stays the browser's, so only one icon's worth.
        let green = CGFloat(try pixels(host, isGreen))
        XCTAssertGreaterThan(green, 0.8 * pow(workspaceSidebarTabIconSize * scale, 2))
        XCTAssertLessThan(green, 1.3 * pow(workspaceSidebarTabIconSize * scale, 2))
    }

    func testAChromiumWindowWithOneTabGetsItsFetchedIcon() throws {
        var snapshot = snapshot(1, icons: [nil])
        let target = snapshot.tabs[0].target
        let origin = try XCTUnwrap(URL(string: "https://example.com"))
        snapshot.iconCandidate = .init(target: target, origin: origin)
        var associations = BrowserTabIconAssociations()
        associations.update(snapshot, now: 0)
        associations.update(snapshot, now: 1)
        XCTAssertEqual(associations.origins[target], origin, "Two reads of a lone tab settle its icon as they do a group's")
    }
}
