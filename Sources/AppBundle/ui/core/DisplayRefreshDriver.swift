import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

private let displayRefreshHostClockFrequency = CVGetHostClockFrequency()

private func displayRefreshDriverCallback(
    _: CVDisplayLink,
    _ now: UnsafePointer<CVTimeStamp>,
    _: UnsafePointer<CVTimeStamp>,
    _: CVOptionFlags,
    _: UnsafeMutablePointer<CVOptionFlags>,
    _ userInfo: UnsafeMutableRawPointer?,
) -> CVReturn {
    guard let userInfo else { return kCVReturnSuccess }
    let driver = Unmanaged<DisplayRefreshDriver>.fromOpaque(userInfo).takeUnretainedValue()
    let timestamp = displayRefreshHostClockFrequency > 0
        ? Double(now.pointee.hostTime) / displayRefreshHostClockFrequency
        : CACurrentMediaTime()
    driver.enqueue(timestamp: timestamp)
    return kCVReturnSuccess
}

@MainActor
final class DisplayRefreshDriver: @unchecked Sendable {
    static let shared = DisplayRefreshDriver()

    private struct Subscription {
        weak var owner: AnyObject?
        let callback: (CFTimeInterval) -> Void
    }

    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?
    nonisolated private let delivery = DisplayRefreshDelivery()

    private init() {}

    nonisolated fileprivate func enqueue(timestamp: CFTimeInterval) {
        guard delivery.offer(timestamp) else { return }
        Task { @MainActor in
            if let timestamp = delivery.takeLatest() { fire(timestamp: timestamp) }
        }
    }

    func add(owner: AnyObject, callback: @escaping (CFTimeInterval) -> Void) {
        subscriptions[ObjectIdentifier(owner)] = Subscription(owner: owner, callback: callback)
        startIfNeeded()
    }

    func remove(owner: AnyObject) {
        subscriptions.removeValue(forKey: ObjectIdentifier(owner))
        stopIfIdle()
    }

    private func startIfNeeded() {
        guard !subscriptions.isEmpty, displayLink == nil, fallbackTimer == nil else { return }
        if startDisplayLink() {
            return
        }
        startFallbackTimer()
    }

    private func startDisplayLink() -> Bool {
        var rawLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&rawLink) == kCVReturnSuccess,
              let rawLink
        else {
            return false
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(rawLink, displayRefreshDriverCallback, userInfo) == kCVReturnSuccess,
              CVDisplayLinkStart(rawLink) == kCVReturnSuccess
        else {
            return false
        }
        displayLink = rawLink
        return true
    }

    private func startFallbackTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                DisplayRefreshDriver.shared.fire(timestamp: CACurrentMediaTime())
            }
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopIfIdle() {
        pruneReleasedOwners()
        guard subscriptions.isEmpty else { return }
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func pruneReleasedOwners() {
        var releasedOwners: [ObjectIdentifier]?
        for (id, subscription) in subscriptions where subscription.owner == nil {
            if releasedOwners == nil {
                releasedOwners = []
            }
            releasedOwners?.append(id)
        }
        guard let releasedOwners else { return }
        for id in releasedOwners {
            subscriptions.removeValue(forKey: id)
        }
    }

    fileprivate func fire(timestamp: CFTimeInterval) {
        pruneReleasedOwners()
        guard !subscriptions.isEmpty else {
            stopIfIdle()
            return
        }
        for subscription in subscriptions.values {
            subscription.callback(timestamp)
        }
    }

}

/// CVDisplayLink runs off the main thread. Keep one pending delivery containing
/// the newest timestamp, rather than replaying obsolete frames after a UI stall.
final class DisplayRefreshDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: CFTimeInterval?

    func offer(_ next: CFTimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let needsDelivery = timestamp == nil
        timestamp = next
        return needsDelivery
    }

    func takeLatest() -> CFTimeInterval? {
        lock.lock()
        defer { timestamp = nil; lock.unlock() }
        return timestamp
    }
}

func displayRefreshEaseInOut(_ progress: CGFloat) -> CGFloat {
    let clamped = min(max(progress, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
}

func displayRefreshInterpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
}

func displayRefreshInterpolate(_ start: CGRect, _ end: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
        x: displayRefreshInterpolate(start.minX, end.minX, progress: progress),
        y: displayRefreshInterpolate(start.minY, end.minY, progress: progress),
        width: displayRefreshInterpolate(start.width, end.width, progress: progress),
        height: displayRefreshInterpolate(start.height, end.height, progress: progress),
    )
}
