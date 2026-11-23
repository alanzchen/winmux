import AppKit
@testable import AppBundle
import Combine
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarFloatCompanionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() async throws { config = defaultConfig }

    private func window(_ id: UInt32, floating: Bool, workspaceName: String = "27") -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: workspaceName, appName: floating ? "FaceTime" : "WeChat",
            appBundleId: floating ? "com.apple.FaceTime" : "com.tencent.xinWeChat",
            appBundlePath: floating ? "/System/Applications/FaceTime.app" : workspaceSidebarTestMissingAppPath,
            title: floating ? "FaceTime" : "WeChat", isFocused: false, state: floating ? .floating : .laidOut)
    }

    private func workspace(_ windows: [WorkspaceSidebarWindowViewModel], name: String = "27") -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
            isGeneratedName: true, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
            isFocused: false, isVisible: false, items: windows.map { .init(kind: .window($0)) },
            appearance: .init(colorHex: "#51897B", isFavorite: true))
    }

    func testCompanionContainsOneSmallWindowIconAndNoBadge() throws {
        let floating = window(2, floating: true)
        for mainSize: CGFloat in [22, 20, 13] {
            let companion = WorkspaceSidebarFloatCompanion(window: floating, mainIconSize: mainSize, onSelect: {})
            let icons = contained(WorkspaceSidebarWindowIcon.self, in: companion.body)
            XCTAssertEqual(icons.count, 1)
            let icon = try XCTUnwrap(icons.first)
            XCTAssertEqual(icon.window.windowId, floating.windowId)
            XCTAssertEqual(icon.size, mainSize * 0.45)
            XCTAssertGreaterThan(icon.size, 0)
            XCTAssertLessThan(icon.size, mainSize)
            XCTAssertTrue(contained(WorkspaceSidebarTabBadge.self, in: companion.body).isEmpty)

            // Prove the structural inspection sees a badge if one is accidentally added.
            let badged = companion.body.overlay {
                WorkspaceSidebarTabBadge(appName: floating.appName, bundlePath: floating.appBundlePath,
                    model: WorkspaceSidebarDockBadgeModel(read: { .init(labelsByPath: [:]) }), compact: false, windowId: floating.windowId)
            }
            XCTAssertEqual(contained(WorkspaceSidebarTabBadge.self, in: badged).count, 1)
        }
    }

    func testMixedPinKeepsAtMostTwoCompanionsFromTheCompleteWindowList() {
        let tiled = window(1, floating: false)
        let floats = [window(2, floating: true), window(3, floating: true), window(4, floating: true)]
        XCTAssertEqual(WorkspaceSidebarFloatCompanion.windows(in: [tiled, floats[0]]).map(\.windowId), [2])
        XCTAssertEqual(WorkspaceSidebarFloatCompanion.windows(in: [tiled] + floats).map(\.windowId), [2, 3])
        XCTAssertEqual(WorkspaceSidebarFloatCompanion.windows(in: [tiled, window(5, floating: false)] + floats).map(\.windowId), [2, 3])
    }

    func testFloatingOnlyAndTiledOnlyPinsHaveNoCompanions() {
        XCTAssertTrue(WorkspaceSidebarFloatCompanion.windows(in: []).isEmpty)
        XCTAssertTrue(WorkspaceSidebarFloatCompanion.windows(in: [window(1, floating: false)]).isEmpty)
        XCTAssertTrue(WorkspaceSidebarFloatCompanion.windows(in: [window(2, floating: true)]).isEmpty)
        XCTAssertTrue(WorkspaceSidebarFloatCompanion.windows(in: [window(2, floating: true), window(3, floating: true)]).isEmpty)
    }

    func testCompanionsLeaveTheAppBadgeCountToAFullSizeWindow() {
        var mixed = workspace([window(1, floating: false), window(2, floating: true)])
        var other = workspace([window(3, floating: true, workspaceName: "other")], name: "other")
        other.appearance.isFavorite = false
        let path = "/System/Applications/FaceTime.app"
        XCTAssertEqual(workspaceSidebarBadgeOwners([mixed, other])[path], 3)
        XCTAssertNil(workspaceSidebarBadgeOwners([mixed])[path], "A companion never owns a hidden count")
        mixed.appearance.isFavorite = false
        XCTAssertEqual(workspaceSidebarBadgeOwners([mixed, other])[path], 2, "Ordinary tab rows stay full size")
        let onlyFloats = workspace([window(2, floating: true)])
        XCTAssertEqual(workspaceSidebarBadgeOwners([onlyFloats, other])[path], 2, "Floating-only pins keep their badges")
    }

    func testCompanionRingCutsThroughTheMainSurfaceAndOverlappingFootprints() {
        let rect = CGRect(x: 0, y: 0, width: 72, height: 54)
        let untouched = WorkspaceSidebarFloatCompanionCutout(mainIconSize: 22, count: 0).path(in: rect)
        let single = WorkspaceSidebarFloatCompanionCutout(mainIconSize: 22, count: 1).path(in: rect)
        let pair = WorkspaceSidebarFloatCompanionCutout(mainIconSize: 22, count: 2).path(in: rect)
        XCTAssertTrue(untouched.contains(CGPoint(x: 43, y: 34)))
        XCTAssertFalse(single.contains(CGPoint(x: 43, y: 34)), "The ring reveals the tile, never a painted box")
        XCTAssertFalse(pair.contains(CGPoint(x: 40, y: 31)), "Overlapping cutouts stay transparent")
        XCTAssertTrue(pair.contains(CGPoint(x: 30, y: 20)), "Keep the main icon outside the companion corners")
        let rear = WorkspaceSidebarFloatCompanionCutout(mainIconSize: 22, count: 1, companionIndex: 1)
            .path(in: CGRect(x: 0, y: 0, width: 11.9, height: 11.9))
        XCTAssertFalse(rear.contains(CGPoint(x: 7, y: 7)), "The rear icon must not paint through the front ring")
        XCTAssertTrue(rear.contains(CGPoint(x: 2, y: 2)))
    }

    /// Inspect only eager value composition; never walk observable models or AppKit objects.
    private func contained<T>(_ type: T.Type, in value: Any) -> [T] {
        if let match = value as? T { return [match] }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return [] }
        return mirror.children.flatMap { contained(type, in: $0.value) }
    }

    /// An offscreen render diagnostic, exported only when the author asks for before/after assets.
    /// Geometry assertions run in the ordinary suite too; no native window is created.
    func testMixedPinFitsRegularAndCompactTilesInBothAppearances() async throws {
        let stage = ProcessInfo.processInfo.environment["WINMUX_COMPANION_RENDER_STAGE"]
        let output = projectRoot.appendingPathComponent(".local/renders")
        let imageKey = "pin-companion-wechat-fixture"
        let previous = SafariExtensionIcons.shared.images[imageKey]
        defer { SafariExtensionIcons.shared.images[imageKey] = previous }
        if stage != nil {
            SafariExtensionIcons.shared.images[imageKey] = try XCTUnwrap(NSImage(contentsOf: output.appendingPathComponent("fixtures/wechat.png")))
        } else { SafariExtensionIcons.shared.images[imageKey] = iconTestImage(.systemGreen) }
        var browser = WorkspaceSidebarBrowserWindows()
        browser.siteIcons[1] = .init(key: imageKey)
        let snapshot = WorkspaceSidebarDockBadgeSnapshot(labelsByPath: ["/System/Applications/FaceTime.app": "1"])
        let badges = WorkspaceSidebarDockBadgeModel(read: { snapshot })
        let ready = expectation(description: "Fixture badge published")
        let publication = badges.$snapshot.filter { $0 == snapshot }.first().sink { _ in ready.fulfill() }
        badges.setEnabled(true)
        defer { badges.setEnabled(false); publication.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        var configuration = WorkspaceSidebarConfiguration.empty
        configuration.usesTabsList = true
        for floats in [1, 3] {
            var windows = [window(1, floating: false), window(2, floating: true)]
            if floats > 1 {
                windows.append(.init(windowId: 3, workspaceName: "27", appName: "Mail", appBundleId: "com.apple.mail",
                    appBundlePath: "/System/Applications/Mail.app", title: "Mail", isFocused: false, state: .floating))
                windows.append(window(4, floating: true))
            }
            for compact in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let tile = WorkspaceSidebarPinnedTab(workspace: workspace(windows),
                        badgeModel: badges, compact: compact, onSelect: { _ in })
                    let mounted = expectation(description: "Pinned tile mounted")
                    let content = ZStack {
                        WorkspaceSidebarSurface(shape: Rectangle(), configuration: configuration)
                        tile.frame(width: compact ? 34 : 72, height: compact ? 34 : 54)
                    }.frame(width: 144, height: 100)
                        .environment(\.workspaceSidebarBrowserWindows, browser)
                        .environment(\.colorScheme, scheme)
                        .scaleEffect(2).frame(width: 288, height: 200)
                        .onAppear { mounted.fulfill() }
                    let host = NSHostingView(rootView: content)
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    host.frame = CGRect(x: 0, y: 0, width: 288, height: 200)
                    host.layoutSubtreeIfNeeded()
                    await fulfillment(of: [mounted], timeout: 5)
                    host.layoutSubtreeIfNeeded()
                    XCTAssertNil(host.window)
                    XCTAssertEqual(host.fittingSize, CGSize(width: 288, height: 200))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let stage {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let name = "\(stage)\(floats == 1 ? "" : "-two-companions")-\(compact ? "compact" : "regular")-\(scheme == .dark ? "dark" : "light").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
