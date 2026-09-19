import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class AppIconSourceTest: XCTestCase {
    func testRasterizationPreservesColorAspectRatioAndStableFingerprint() throws {
        let image = iconTestImage(.red, size: CGSize(width: 128, height: 64))
        let first = try XCTUnwrap(AppIconSource.rasterize(image))
        let second = try XCTUnwrap(AppIconSource.rasterize(image))
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.fingerprint, try iconArtwork(.green).fingerprint)
        let bitmap = NSBitmapImageRep(cgImage: first.image)
        XCTAssertEqual(bitmap.pixelsWide, 256)
        XCTAssertEqual(bitmap.pixelsHigh, 256)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 128, y: 10)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 128, y: 128)?.usingColorSpace(.sRGB)).redComponent, 0.95)
    }

    func testNativeReplacementAndRemovalRefreshInSameProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winmux-icons-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("Replacement Icon Test.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "dev.winmux.icon-test.\(UUID().uuidString)",
                                   "CFBundleName": "Replacement Icon Test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(NSWorkspace.shared.setIcon(iconTestImage(.red), forFile: app.path, options: []))
        let request = try XCTUnwrap(AppIconRequest(bundleIdentifier: info["CFBundleIdentifier"], bundlePath: app.path))
        let provider = AppIconProvider(refreshInterval: .milliseconds(50), observesWorkspace: false)
        let model = provider.model(for: request)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        provider.retain(model)
        defer { provider.release(model); withExtendedLifetime(subscription) {} }
        try await waitForIcons { changes == 1 }
        let first = try XCTUnwrap(model.image.flatMap(AppIconSource.rasterize))
        XCTAssertEqual(first.fingerprint, try iconArtwork(.red).fingerprint)

        XCTAssertTrue(NSWorkspace.shared.setIcon(iconTestImage(.green), forFile: app.path, options: []))
        try await waitForIcons { changes == 2 }
        let second = try XCTUnwrap(model.image.flatMap(AppIconSource.rasterize))
        XCTAssertEqual(second.fingerprint, try iconArtwork(.green).fingerprint)

        XCTAssertTrue(NSWorkspace.shared.setIcon(nil, forFile: app.path, options: []))
        try await waitForIcons { changes == 3 }
        let restored = try XCTUnwrap(model.image.flatMap(AppIconSource.rasterize))
        XCTAssertNotEqual(restored.fingerprint, first.fingerprint)
        XCTAssertNotEqual(restored.fingerprint, second.fingerprint)

        // An app update/move can temporarily remove the bundle. NSWorkspace alone
        // would return a generic icon and incorrectly overwrite the cached artwork.
        let lastValid = model.image
        try FileManager.default.removeItem(at: app)
        let missing = await AppIconSource.read([request])
        XCTAssertNil(missing.first!)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.image === lastValid)
        XCTAssertEqual(changes, 3)
    }

    func testIdentifierOnlyLookupResolvesTheSystemFinderIcon() async throws {
        let identifier = "com.apple.finder"
        let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier))
        let byID = try XCTUnwrap(AppIconRequest(bundleIdentifier: identifier, bundlePath: nil))
        let byPath = try XCTUnwrap(AppIconRequest(bundleIdentifier: identifier, bundlePath: url.path))
        let images = await AppIconSource.read([byID, byPath])
        XCTAssertEqual(try XCTUnwrap(images[0]).fingerprint, try XCTUnwrap(images[1]).fingerprint)
    }

    func testMountedIconRepaintsWithoutRebuildingParentOrChangingBounds() async throws {
        let reader = IconTestReader(value: try iconArtwork(.red))
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: false,
                                      initialImage: { _ in iconTestImage(.red) }, read: { await reader.read($0) })
        let probe = IconRenderProbe()
        let host = NSHostingView(rootView: IconTestRoot(provider: provider, probe: probe))
        host.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window, "This regression must not activate a desktop window")
        try await waitForIcons { await reader.calls.count == 1 }
        // Finish the initial async publication, then record a stable host.
        try await Task.sleep(for: .milliseconds(20))
        let before = try bitmap(host)
        XCTAssertGreaterThan(try centerColor(before).redComponent, 0.95)
        let count = probe.bodyCount
        await reader.setValue(try iconArtwork(.green))
        provider.requestRefresh()
        try await waitForIcons { await reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let after = try bitmap(host)
        XCTAssertGreaterThan(try centerColor(after).greenComponent, 0.95)
        XCTAssertLessThan(try centerColor(after).redComponent, 0.05)
        XCTAssertEqual(probe.bodyCount, count, "Refresh must invalidate the icon leaf, not the Dock's layout tree")
        XCTAssertEqual(host.fittingSize, CGSize(width: 64, height: 64))
        let output = projectRoot.appendingPathComponent(".build/replacement-app-icons")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(before.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("before.png"))
        try XCTUnwrap(after.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("after.png"))
    }

    func testAbruptHostingViewTeardownStopsRefreshWork() async throws {
        let reader = IconTestReader(value: try iconArtwork(.red))
        let provider = AppIconProvider(refreshInterval: .milliseconds(15), observesWorkspace: false,
                                      initialImage: { _ in iconTestImage(.red) }, read: { await reader.read($0) })
        var host: NSHostingView<IconTestRoot>? = NSHostingView(rootView: IconTestRoot(provider: provider, probe: IconRenderProbe()))
        host?.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        host?.layoutSubtreeIfNeeded()
        try await waitForIcons { await reader.calls.count > 0 }
        let lifetime = IconHostLifetime(host)
        host = nil
        try await waitForIcons { lifetime.view == nil }
        try await Task.sleep(for: .milliseconds(40))
        let before = await reader.calls.count
        try await Task.sleep(for: .milliseconds(80))
        let after = await reader.calls.count
        XCTAssertEqual(after, before, "Destroying a drag/preview host must release its icon consumer")
    }

    func testClearingPersistentDragPreviewHostStopsRefreshWork() async throws {
        let reader = IconTestReader(value: try iconArtwork(.red))
        let provider = AppIconProvider(refreshInterval: .milliseconds(15), observesWorkspace: false,
                                      initialImage: { _ in iconTestImage(.red) }, read: { await reader.read($0) })
        let host = NSHostingView(rootView: AnyView(IconTestRoot(provider: provider, probe: IconRenderProbe())))
        host.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        host.layoutSubtreeIfNeeded()
        try await waitForIcons { await reader.calls.count > 0 }
        // WindowDragCursorProxyPanel.hide clears its persistent hosting view this way.
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let before = await reader.calls.count
        try await Task.sleep(for: .milliseconds(80))
        let after = await reader.calls.count
        XCTAssertEqual(after, before)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private func centerColor(_ image: NSBitmapImageRep) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }
}

@MainActor
private final class IconRenderProbe { var bodyCount = 0 }

@MainActor
private final class IconHostLifetime {
    weak var view: NSView?
    init(_ view: NSView?) { self.view = view }
}

private struct IconTestRoot: View {
    let provider: AppIconProvider
    let probe: IconRenderProbe

    var body: some View {
        probe.bodyCount += 1
        return AppIconView(bundleIdentifier: "dev.winmux.test", bundlePath: "/Test.app", provider: provider) { icon in
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }.frame(width: 64, height: 64)
    }
}
