import AppKit
@testable import AppBundle
import Combine
import XCTest

@MainActor
final class AppIconProviderTest: XCTestCase {
    func testCacheUsesBundlePathAndNormalizesEmptyInputs() throws {
        XCTAssertNil(AppIconRequest(bundleIdentifier: "", bundlePath: ""))
        let identifierOnly = try XCTUnwrap(AppIconRequest(bundleIdentifier: "example.app", bundlePath: ""))
        XCTAssertNil(identifierOnly.bundlePath)
        var lookups = 0
        let provider = AppIconProvider(observesWorkspace: false, initialImage: { _ in lookups += 1; return nil }, read: { _ in [] })
        let first = provider.model(for: request("/Applications/One.app"))
        let normalized = provider.model(for: request("/Applications/./One.app/"))
        XCTAssertTrue(first === normalized)
        XCTAssertFalse(first === provider.model(for: request("/Applications/Other/One.app")))
        for _ in 0..<1_000 { XCTAssertTrue(first === provider.model(for: first.request)) }
        XCTAssertEqual(lookups, 2, "Repeated layout/hover queries must only hit the cache")
    }

    func testEvictionPreservesModelsStillOwnedByViews() {
        var lookups = 0
        let provider = AppIconProvider(cacheLimit: 1, observesWorkspace: false,
                                      initialImage: { _ in lookups += 1; return nil }, read: { _ in [] })
        let borrowed = provider.model(for: request("/One.app"))
        _ = provider.model(for: request("/Two.app"))
        XCTAssertTrue(borrowed === provider.model(for: borrowed.request))
        XCTAssertEqual(lookups, 2)
        _ = provider.model(for: request("/Three.app"))
        _ = provider.model(for: request("/Two.app"))
        XCTAssertEqual(lookups, 4, "Unreferenced inactive entries must be evicted")
    }

    func testRefreshPublishesOnlyChangedAppAndPreservesLastValidImage() async throws {
        let red = try iconArtwork(.red)
        let green = try iconArtwork(.green)
        let reader = IconTestReader(value: red)
        let fallback = iconTestImage(.gray)
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: false,
                                      initialImage: { _ in fallback }, read: { await reader.read($0) })
        let first = provider.model(for: request("/One.app"))
        let second = provider.model(for: request("/Two.app"))
        XCTAssertTrue(first.image === fallback)
        var firstChanges = 0
        var secondChanges = 0
        let subscriptions = [first.objectWillChange.sink { firstChanges += 1 }, second.objectWillChange.sink { secondChanges += 1 }]
        defer { withExtendedLifetime(subscriptions) {} }
        provider.retain(first)
        provider.retain(second)
        defer { provider.release(first); provider.release(second) }
        try await waitForIcons { firstChanges == 1 && secondChanges == 1 }
        let firstImage = first.image
        let secondImage = second.image
        provider.requestRefresh()
        try await waitForIcons { await reader.calls.count == 2 }
        // Drain the completed read's main-actor application before asserting no redraw.
        await Task.yield()
        XCTAssertTrue(first.image === firstImage)
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)

        await reader.setValue(green)
        provider.requestRefresh(bundlePath: first.request.bundlePath)
        try await waitForIcons { firstChanges == 2 }
        let lastBatch = await reader.calls.last
        XCTAssertEqual(lastBatch, [first.request])
        XCTAssertTrue(second.image === secondImage)
        XCTAssertEqual(secondChanges, 1)
        let replacement = first.image
        await reader.setValue(nil)
        provider.requestRefresh(bundlePath: first.request.bundlePath)
        try await waitForIcons { await reader.calls.count == 4 }
        await Task.yield()
        XCTAssertTrue(first.image === replacement, "A failed lookup must not blank an existing icon")
        XCTAssertEqual(firstChanges, 2)
    }

    func testPollingRefreshesWithoutInputAndStopsAfterLastConsumerLeaves() async throws {
        let reader = IconTestReader(value: try iconArtwork(.red))
        let provider = AppIconProvider(refreshInterval: .milliseconds(20), observesWorkspace: false,
                                      initialImage: { _ in nil }, read: { await reader.read($0) })
        let model = provider.model(for: request("/One.app"))
        provider.retain(model)
        provider.retain(model)
        try await waitForIcons { model.image != nil }
        let initial = model.image
        provider.release(model)
        await reader.setValue(try iconArtwork(.green))
        try await waitForIcons { model.image !== initial }
        provider.release(model)
        try await Task.sleep(for: .milliseconds(30))
        let calls = await reader.calls.count
        try await Task.sleep(for: .milliseconds(70))
        let after = await reader.calls.count
        XCTAssertEqual(after, calls)
    }

    func testLateReadCannotOverwriteAReappearedView() async throws {
        let red = try iconArtwork(.red)
        let green = try iconArtwork(.green)
        let reader = IconTestReader(value: red, suspendFirst: true)
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: false,
                                      initialImage: { _ in nil }, read: { await reader.read($0) })
        let model = provider.model(for: request("/One.app"))
        provider.retain(model)
        try await waitForIcons { await reader.calls.count == 1 }
        provider.release(model)
        await reader.setValue(green)
        provider.retain(model)
        defer { provider.release(model) }
        try await waitForIcons { model.image != nil }
        let replacement = model.image
        await reader.finishFirst(with: red)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(model.image === replacement, "Cancelled native lookups can finish, but must not publish")
    }

    func testRequestsDuringAReadCoalesceIntoOneFollowup() async throws {
        let red = try iconArtwork(.red)
        let reader = IconTestReader(value: red, suspendFirst: true)
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: false,
                                      initialImage: { _ in nil }, read: { await reader.read($0) })
        let model = provider.model(for: request("/One.app"))
        provider.retain(model)
        defer { provider.release(model) }
        try await waitForIcons { await reader.calls.count == 1 }
        for _ in 0..<50 { provider.requestRefresh() }
        await reader.finishFirst(with: red)
        try await waitForIcons { await reader.calls.count == 2 }
        try await Task.sleep(for: .milliseconds(10))
        let count = await reader.calls.count
        XCTAssertEqual(count, 2)
    }

    func testReappearingAppRejectsOldBatchWhileOtherAppStaysMounted() async throws {
        let red = try iconArtwork(.red)
        let green = try iconArtwork(.green)
        let reader = IconTestReader(value: red, suspendFirst: true)
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: false,
                                      initialImage: { _ in nil }, read: { await reader.read($0) })
        let first = provider.model(for: request("/One.app"))
        let second = provider.model(for: request("/Two.app"))
        var changes = 0
        let subscription = first.objectWillChange.sink { changes += 1 }
        provider.retain(first)
        provider.retain(second)
        defer { provider.release(first); provider.release(second); withExtendedLifetime(subscription) {} }
        try await waitForIcons { await reader.calls.count == 1 }
        provider.release(first)
        provider.retain(first)
        await reader.setValue(green)
        await reader.finishFirst(with: red)
        try await waitForIcons { first.image != nil && second.image != nil }
        XCTAssertEqual(changes, 1, "Reappearing app must never publish the obsolete first batch")
        XCTAssertEqual(try XCTUnwrap(first.image.flatMap(AppIconSource.rasterize)).fingerprint, green.fingerprint)
        XCTAssertEqual(try XCTUnwrap(second.image.flatMap(AppIconSource.rasterize)).fingerprint, red.fingerprint)
    }

    func testAnonymousWorkspaceNotificationDoesNotRefreshAllIcons() async throws {
        let reader = IconTestReader(value: try iconArtwork(.red))
        let center = NotificationCenter()
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: true,
                                      notificationCenter: center,
                                      initialImage: { _ in nil }, read: { await reader.read($0) })
        let model = provider.model(for: request("/One.app"))
        provider.retain(model)
        defer { provider.release(model) }
        try await waitForIcons { model.image != nil }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        let count = await reader.calls.count
        XCTAssertEqual(count, 1)
    }

    func testWorkspaceNotificationsTargetIdentifierAndStopAfterRelease() async throws {
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let identifier = try XCTUnwrap(app.bundleIdentifier)
        let center = NotificationCenter()
        let reader = IconTestReader(value: try iconArtwork(.red))
        let provider = AppIconProvider(refreshInterval: .seconds(60), observesWorkspace: true,
                                      notificationCenter: center, initialImage: { _ in nil }, read: { await reader.read($0) })
        let model = provider.model(for: AppIconRequest(bundleIdentifier: identifier, bundlePath: nil)!)
        let other = provider.model(for: request("/Unrelated.app"))
        for cycle in 0..<2 {
            provider.retain(model)
            provider.retain(other)
            try await waitForIcons { await reader.calls.count == cycle * 4 + 1 }
            for (index, notification) in [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification].enumerated() {
                center.post(name: notification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
                try await waitForIcons { await reader.calls.count == cycle * 4 + index + 2 }
                let batch = await reader.calls.last
                XCTAssertEqual(batch, [model.request], "App event must refresh identifier-only model without touching other apps")
            }
            provider.release(model)
            provider.release(other)
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                        userInfo: [NSWorkspace.applicationUserInfoKey: app])
            try await Task.sleep(for: .milliseconds(20))
            let count = await reader.calls.count
            XCTAssertEqual(count, (cycle + 1) * 4)
        }
    }

    private func request(_ path: String) -> AppIconRequest {
        AppIconRequest(bundleIdentifier: "example.app", bundlePath: path)!
    }
}

actor IconTestReader {
    private var value: AppIconArtwork?
    private let suspendFirst: Bool
    private var suspended: CheckedContinuation<[AppIconArtwork?], Never>?
    private(set) var calls: [[AppIconRequest]] = []

    init(value: AppIconArtwork?, suspendFirst: Bool = false) {
        self.value = value
        self.suspendFirst = suspendFirst
    }

    func read(_ requests: [AppIconRequest]) async -> [AppIconArtwork?] {
        calls.append(requests)
        if suspendFirst, calls.count == 1 {
            return await withCheckedContinuation { suspended = $0 }
        }
        return requests.map { _ in value }
    }

    func setValue(_ value: AppIconArtwork?) { self.value = value }

    func finishFirst(with value: AppIconArtwork?) {
        suspended?.resume(returning: calls.first?.map { _ in value } ?? [])
        suspended = nil
    }
}

@MainActor
func waitForIcons(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw IconTestError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private enum IconTestError: Error { case timeout }

func iconTestImage(_ color: NSColor, size: CGSize = CGSize(width: 128, height: 128)) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

func iconArtwork(_ color: NSColor) throws -> AppIconArtwork {
    try XCTUnwrap(AppIconSource.rasterize(iconTestImage(color)))
}
