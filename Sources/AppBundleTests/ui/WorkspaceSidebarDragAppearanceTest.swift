import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDragAppearanceTest: XCTestCase {
    func testIconDragUsesItsSourceSizeAndKeepsTheWindowDragAction() {
        var receivedId: UInt32?
        var receivedSize: Double?
        let actions = WorkspaceSidebarActions(
            resolveAppDragWindow: { _, _ in 42 },
            appIconDragChanged: { id, _, size in
                receivedId = id
                receivedSize = Double(size)
            }
        )
        var drag = WorkspaceSidebarAppDragSession()
        drag.update(workspaceName: "1", appId: "app", pointer: .zero, iconSize: 28, actions: actions)
        XCTAssertEqual(receivedId, 42)
        XCTAssertEqual(receivedSize, 28)
    }

    func testAppearanceStaysPinnedUntilGestureEnds() {
        clearActiveWorkspaceSidebarDrag()
        defer { clearActiveWorkspaceSidebarDrag() }
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 32))
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window)
        XCTAssertEqual(currentActiveWorkspaceSidebarDrag()?.previewStyle, .appIcon(size: 32))
        clearActiveWorkspaceSidebarDrag()
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window)
        XCTAssertEqual(currentActiveWorkspaceSidebarDrag()?.previewStyle, .row)
    }

    func testCursorSizeDoesNotDependOnWindowTitleForIconDrags() {
        XCTAssertEqual(windowDragCursorProxySize(label: "A", style: .appIcon(size: 32)), CGSize(width: 44, height: 44))
        XCTAssertEqual(windowDragCursorProxySize(label: String(repeating: "Long title", count: 20), style: .appIcon(size: 32)), CGSize(width: 44, height: 44))
        XCTAssertEqual(windowDragCursorProxySize(label: "A").height, 28)
    }

    func testCompactCursorAndDestinationNeverRenderWindowTitle() throws {
        for newWorkspace in [false, true] {
            let short = preview(title: "A", newWorkspace: newWorkspace)
            let long = preview(title: "This long window title must never be truncated beside a compact icon", newWorkspace: newWorkspace)
            XCTAssertEqual(
                try render(WindowDragCursorProxyView(preview: short, style: .appIcon(size: 32)), size: CGSize(width: 44, height: 44)),
                try render(WindowDragCursorProxyView(preview: long, style: .appIcon(size: 32)), size: CGSize(width: 44, height: 44))
            )
            XCTAssertEqual(
                try render(WorkspaceSidebarDropPreviewView(preview: short, rowHeight: 28, style: .appIcon(size: 32)), size: CGSize(width: 50, height: 32)),
                try render(WorkspaceSidebarDropPreviewView(preview: long, rowHeight: 28, style: .appIcon(size: 32)), size: CGSize(width: 50, height: 32))
            )
            XCTAssertNotEqual(
                try render(WindowDragCursorProxyView(preview: short), size: CGSize(width: 224, height: 28)),
                try render(WindowDragCursorProxyView(preview: long), size: CGSize(width: 224, height: 28))
            )
        }
    }

    private func preview(title: String, newWorkspace: Bool) -> WorkspaceSidebarDropPreviewViewModel {
        WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 42, label: title, appName: "Safari",
            appBundleIdentifier: "com.apple.Safari", targetWorkspaceName: newWorkspace ? nil : "2",
            targetsNewWorkspace: newWorkspace, isTabGroup: false, windowCount: 1)
    }

    private func render(_ view: some View, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
