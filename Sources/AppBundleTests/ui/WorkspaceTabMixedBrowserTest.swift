import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceTabMixedBrowserTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() async throws { config = defaultConfig }

    private func window(_ id: UInt32, state: WorkspaceTabMemberState, appName: String = "Browser") -> WorkspaceSidebarWindowViewModel {
        .init(windowId: id, workspaceName: "mixed", appName: appName, appBundleId: "com.google.Chrome",
            appBundlePath: workspaceSidebarTestMissingAppPath, title: "Window \(id)", isFocused: false, state: state)
    }

    private func workspace(_ windows: [WorkspaceSidebarWindowViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: "mixed", projectId: workspaceProjectDefaultId, displayName: "mixed", sidebarLabel: "",
            isGeneratedName: true, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
            isFocused: false, isVisible: false, items: windows.map { .init(kind: .window($0)) })
    }

    private func tabs(_ id: UInt32) -> BrowserWindowTabs {
        let session = UUID()
        return .init(windowId: id, pid: 1, windowSession: session, tabs: ["Alpha", "Beta"].map { title in
            .init(target: .init(windowId: id, pid: 1, windowSession: session, tabId: UUID()), title: title, isSelected: false)
        })
    }

    func testMixedBrowserSearchFollowsSplitThenFloatingRows() {
        let model = workspace([window(1, state: .laidOut), window(2, state: .laidOut),
            window(3, state: .floating), window(4, state: .floating)])
        let tiled = tabs(1), floating = tabs(3)
        let expected: [WorkspaceSidebarSearchSelection] = [.window(1), .window(2)] +
            tiled.tabs.map { .browserTab($0.target) } + [.window(3)] +
            floating.tabs.map { .browserTab($0.target) } + [.window(4)]
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [model], browserTabs: [1: tiled, 3: floating]), expected)
    }

    func testMixedBrowserSearchListsOnlyMatchingChildrenWhenHeadersDoNotMatch() {
        let model = workspace([window(1, state: .laidOut), window(3, state: .floating)])
        let tiled = tabs(1), floating = tabs(3)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [model], browserTabs: [1: tiled, 3: floating], query: "Alpha"),
            [.browserTab(tiled.tabs[0].target), .browserTab(floating.tabs[0].target)])
        var loneTab = tiled
        loneTab.tabs = [tiled.tabs[0]]
        XCTAssertTrue(workspaceSidebarMatchingBrowserTabs(loneTab, window: window(1, state: .laidOut),
            workspace: model, query: "").isEmpty, "A lone tab keeps the native window row instead of a browser group")
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [model], browserTabs: [1: loneTab, 3: floating]),
            [.window(1), .window(3)] + floating.tabs.map { .browserTab($0.target) })
    }

    func testStandaloneBrowserInMixedCardDrawsItsNameOnlyOnce() async throws {
        let browser = tabs(1)
        let placements: [(WorkspaceTabMemberState, WorkspaceTabMemberState)] = [
            (.laidOut, .floating), (.floating, .floating), (.floating, .laidOut),
        ]
        for (state, otherState) in placements {
            func render(_ name: String) async throws -> WorkspaceSidebarTestRender {
                let model = workspace([window(1, state: state, appName: name), window(2, state: otherState)])
                let card = WorkspaceSidebarTabCardView(workspace: model, presentation: workspaceSidebarTabPresentation(model),
                    isActive: false, isDropTarget: false, dragSourceWindowId: nil, selectedSearchTarget: nil,
                    activation: .init(allowsActivation: true, isInUseOnOtherDisplay: false, requestOverride: {}),
                    isShowingOverride: false, overrideMinHeight: 0, actions: .init(), browserTabs: [1: browser],
                    onCommitOverride: {}, onCancelOverride: {})
                let mounted = expectation(description: "Browser card mounted")
                let host = NSHostingView(rootView: card.frame(width: 280).padding(8).background(Color.white)
                    .environment(\.colorScheme, .light).onAppear { mounted.fulfill() })
                host.frame = CGRect(x: 0, y: 0, width: 296, height: 250)
                host.layoutSubtreeIfNeeded()
                await fulfillment(of: [mounted], timeout: 5)
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return .init(bitmap: bitmap, targets: [], fittingSize: host.fittingSize)
            }
            let original = try await render("Google Chrome")
            let output = projectRoot.appendingPathComponent(".local/reviews/mixed-browser-\(state.rawValue)-\(otherState.rawValue).png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(original.bitmap.representation(using: .png, properties: [:])).write(to: output)
            let repeated = try await render("Google Chrome")
            XCTAssertNil(repeated.difference(from: original))
            let renamed = try await render("Google Chromium")
            let difference = try XCTUnwrap(renamed.difference(from: original))
            XCTAssertLessThan(difference.bounds.height, workspaceSidebarTabRowHeight,
                "Only one header row draws the browser name, including when it floats")
        }
    }
}
