import AppKit
@testable import AppBundle
import XCTest

/// Gates one disk operation through the cache's existing clock dependency.
private final class IconCacheClockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)

    init(entered: XCTestExpectation) { self.entered = entered }
    func arm() { lock.withLock { armed = true } }
    func now() -> TimeInterval {
        let shouldWait = lock.withLock {
            let result = armed
            armed = false
            return result
        }
        if shouldWait {
            entered.fulfill()
            resume.wait()
        }
        return 100
    }
}

@MainActor
final class BrowserTabIconCacheConcurrencyTest: XCTestCase {
    func testPreparedIconRemainsKnownWhilePruningOwnsDiskLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let key = BrowserTabIconDiskCache.digest(png)
        let partition = "safari:profile:regression"
        let gate = IconCacheClockGate(entered: expectation(description: "Pruning holds disk lock"))
        BrowserTabIconDiskCache(directory: directory, clock: gate.now).store(partition: partition, icon: key, png: png)
        let relaunched = BrowserTabIconDiskCache(directory: directory, clock: gate.now)
        relaunched.prepare()
        XCTAssertTrue(relaunched.knows(partition: partition, icon: key))

        let pruned = expectation(description: "Pruning finishes")
        // The prepared prune's first clock read is in evict(), after it acquires the disk lock.
        gate.arm()
        DispatchQueue.global().async {
            relaunched.prune()
            pruned.fulfill()
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let queried = expectation(description: "Metadata lookup finishes before disk work")
        DispatchQueue.global().async {
            XCTAssertTrue(relaunched.knows(partition: partition, icon: key), "Disk contention must not mean absent")
            XCTAssertFalse(relaunched.knows(partition: "safari:profile:other", icon: key))
            queried.fulfill()
        }
        await fulfillment(of: [queried], timeout: 5)
        gate.resume.signal()
        await fulfillment(of: [pruned], timeout: 5)
        XCTAssertEqual(relaunched.icon(partition: partition, icon: key), png)
    }
}
