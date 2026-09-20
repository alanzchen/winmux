import AppKit
import ApplicationServices
import Darwin

/// CoreDock exports are optional SPI. Resolve them at runtime so a future macOS
/// can disable integration without preventing WinMux from launching.
private struct SystemDockBridge: @unchecked Sendable {
    static let shared = SystemDockBridge()
    private typealias GetAutoHide = @convention(c) () -> UInt8
    private typealias SetAutoHide = @convention(c) (UInt8) -> Void
    private typealias GetRect = @convention(c) (UnsafeMutablePointer<CGRect>) -> Void
    private typealias GetOrientation = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let getAutoHide: GetAutoHide?
    private let setAutoHideValue: SetAutoHide?
    private let rect: GetRect?
    private let orientation: GetOrientation?

    private init() {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
        self.handle = handle
        getAutoHide = handle.flatMap { dlsym($0, "CoreDockGetAutoHideEnabled") }.map { unsafeBitCast($0, to: GetAutoHide.self) }
        setAutoHideValue = handle.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }.map { unsafeBitCast($0, to: SetAutoHide.self) }
        rect = handle.flatMap { dlsym($0, "CoreDockGetRect") }.map { unsafeBitCast($0, to: GetRect.self) }
        orientation = handle.flatMap { dlsym($0, "CoreDockGetOrientationAndPinning") }.map { unsafeBitCast($0, to: GetOrientation.self) }
    }

    var autoHide: Bool? { getAutoHide.map { $0() != 0 } }
    func setAutoHide(_ enabled: Bool) { setAutoHideValue?(enabled ? 1 : 0) }
    var position: WorkspaceDockPosition? {
        guard let orientation else { return nil }
        var edge: Int32 = 0
        var pinning: Int32 = 0
        orientation(&edge, &pinning)
        switch edge {
            case 2: return .bottom
            case 3: return .left
            case 4: return .right
            default: return nil
        }
    }
    var reservedRect: CGRect? {
        guard let rect else { return nil }
        var result = CGRect.zero
        rect(&result)
        // Auto-hide reserves a zero-thickness line even while the Dock is revealed.
        // Keep that line: it still identifies the native edge and owning display.
        return systemDockValidReservedRect(result) ? result : nil
    }
}

private func systemDockValidReservedRect(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.maxX.isFinite && rect.maxY.isFinite &&
        rect.size.width >= 0 && rect.size.height >= 0 && (rect.width > 1 || rect.height > 1)
}

/// CoreDockGetRect describes reserved space, not the visible shelf. Reconstruct
/// its inward thickness from AX without using the animated AX position as the
/// anchor; an offscreen list must not suppress a Dock on an adjacent display.
func systemDockVisibilityTarget(reservedRect: CGRect, listSize: CGSize,
    position: WorkspaceDockPosition?) -> CGRect? {
    guard systemDockValidReservedRect(reservedRect),
          listSize.width.isFinite, listSize.height.isFinite,
          listSize.width > 1, listSize.height > 1 else { return nil }
    if reservedRect.width > 1 && reservedRect.height > 1 { return reservedRect }
    switch position {
        case .bottom where reservedRect.width > 1:
            return CGRect(x: reservedRect.minX, y: reservedRect.maxY - listSize.height,
                width: reservedRect.width, height: listSize.height)
        case .left where reservedRect.height > 1:
            return CGRect(x: reservedRect.minX, y: reservedRect.minY,
                width: listSize.width, height: reservedRect.height)
        case .right where reservedRect.height > 1:
            return CGRect(x: reservedRect.maxX - listSize.width, y: reservedRect.minY,
                width: listSize.width, height: reservedRect.height)
        default: return nil
    }
}

struct SystemDockSnapshot: Equatable, Sendable {
    /// Quartz coordinates (origin at the primary display's top left).
    var targetRect: CGRect?
    var visibleRect: CGRect?
    var nativePosition: WorkspaceDockPosition?
}

func systemDockHidesDock(_ snapshot: SystemDockSnapshot, position: WorkspaceDockPosition, display: Rect) -> Bool {
    guard let target = snapshot.targetRect, let visible = snapshot.visibleRect,
          !target.isEmpty, !target.isNull, !target.isInfinite else { return false }
    let screen = CGRect(x: display.minX, y: display.minY, width: display.width, height: display.height)
    guard systemDockVisibleRect(listFrame: visible, targetFrame: target.intersection(screen)) != nil else { return false }
    if let nativePosition = snapshot.nativePosition { return position == nativePosition }

    // Use the resting target, not the animated/clipped AX frame: its proportions
    // can change while the Dock slides in. Only a shared display edge conflicts.
    let leftDistance = abs(target.minX - screen.minX)
    let rightDistance = abs(screen.maxX - target.maxX)
    let bottomDistance = abs(screen.maxY - target.maxY) // Quartz Y increases downward.
    let sideDistance = min(leftDistance, rightDistance)
    let thickness = min(target.width, target.height)
    let nearCorner = bottomDistance <= thickness && sideDistance <= thickness
    let nativePosition: WorkspaceDockPosition
    // Near a corner, system margins can make the perpendicular edge closer.
    // The resting long axis disambiguates full-width/full-height Docks there.
    if nearCorner ? target.width >= target.height : bottomDistance < sideDistance {
        nativePosition = .bottom
    } else {
        nativePosition = leftDistance <= rightDistance ? .left : .right
    }
    return position == nativePosition
}

func systemDockVisibleRect(listFrame: CGRect, targetFrame: CGRect) -> CGRect? {
    // Hidden Dock AX elements remain in the tree, just beyond the display edge.
    // Clip against the Dock's target as well as the screen: otherwise that hidden
    // rectangle could falsely hide WinMux on an adjacent monitor.
    let visible = listFrame.intersection(targetFrame)
    return visible.width > 1 && visible.height > 1 && !visible.isNull ? visible : nil
}

/// Watch the native Dock's edge on every display, including before it migrates.
/// Scrubbing a left WinMux Dock must not poll a bottom native Dock at pointer rate.
func systemDockPointerNearActivation(_ point: CGPoint, target: CGRect?, primaryHeight: CGFloat,
    screens: [CGRect], nativePosition: WorkspaceDockPosition? = nil) -> Bool {
    guard let target else { return false }
    let native = CGRect(x: target.minX, y: primaryHeight - target.maxY, width: target.width, height: target.height)
    if native.insetBy(dx: -48, dy: -48).contains(point) { return true }
    let vertical = nativePosition.map { $0 != .bottom } ?? (native.height > native.width)
    let owner = screens.first { $0.intersects(native) }
    let onLeft = nativePosition.map { $0 == .left } ??
        (owner.map { abs(native.minX - $0.minX) < abs($0.maxX - native.maxX) } ?? true)
    return screens.contains { screen in
        guard screen.contains(point) else { return false }
        if !vertical { return point.y - screen.minY < 24 }
        return onLeft ? point.x - screen.minX < 24 : screen.maxX - point.x < 24
    }
}

func systemDockPollInterval(pointerNearDock: Bool, dockVisible: Bool,
    timeSincePointerActivity: TimeInterval, timeSinceSnapshotChange: TimeInterval = .infinity,
    timeSinceKeyboardActivity: TimeInterval = .infinity) -> TimeInterval {
    // A stationary visible Dock is just as idle as a hidden one. Keep the fast
    // cadence only around input and observed transitions, including keyboard reveals.
    if timeSincePointerActivity < 1, pointerNearDock { return 0.05 }
    if min(timeSinceSnapshotChange, timeSinceKeyboardActivity) < 1 { return 0.15 }
    if dockVisible, timeSincePointerActivity < 1 { return 0.15 }
    return 1
}

private func readSystemDockSnapshot() -> SystemDockSnapshot? {
    let bridge = SystemDockBridge.shared
    guard AXIsProcessTrusted(), let reserved = bridge.reservedRect,
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return nil }
    let nativePosition = bridge.position
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.1)
    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    guard let children = value(root, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    var hidden: SystemDockSnapshot?
    for list in children.prefix(16) where value(list, kAXRoleAttribute) as? String == kAXListRole {
        guard let position = value(list, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(list, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { continue }
        guard let target = systemDockVisibilityTarget(reservedRect: reserved, listSize: dimensions,
            position: nativePosition) else { continue }
        let snapshot = SystemDockSnapshot(targetRect: target,
            visibleRect: systemDockVisibleRect(listFrame: CGRect(origin: point, size: dimensions), targetFrame: target),
            nativePosition: nativePosition)
        if snapshot.visibleRect != nil { return snapshot }
        hidden = snapshot
    }
    return hidden
}

/// Own only the preference change made for Bottom mode. Keep a recovery record
/// before changing the Dock; restore on disable/quit or the next launch after a crash.
@MainActor
final class SystemDockAutoHideLease {
    private var active = false
    private var requestedActive = false
    private var original: Bool?
    private var acquisitionConfirmed = false
    private var isRestoring = false
    private var restoreIssued = false
    private var restoreTask: Task<Void, Never>?
    private let read: () -> Bool?
    private let write: (Bool) -> Void
    private let save: (Bool?) -> Void

    init(original: Bool? = nil, read: @escaping () -> Bool?, write: @escaping (Bool) -> Void,
         save: @escaping (Bool?) -> Void) {
        self.original = original
        self.read = read
        self.write = write
        self.save = save
    }

    deinit { restoreTask?.cancel() }

    func configure(active requested: Bool) {
        requestedActive = requested
        guard requested else {
            guard active || original != nil else { return }
            active = false
            isRestoring = original != nil
            restoreIfNeeded()
            if isRestoring, restoreTask == nil {
                // Visibility polling stops when WinMux switches to Sidebar or is
                // disabled. Finish a delayed restore independently of that loop.
                restoreTask = Task { [weak self] in
                    var attempts = 0
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(attempts < 20 ? 100 : 1_000)) }
                        catch { return }
                        guard let self, self.isRestoring else { return }
                        self.restoreIfNeeded()
                        attempts += 1
                    }
                }
            }
            return
        }
        if isRestoring {
            // A pending disable must finish before reacquiring; an old true read
            // is not proof that the queued restore has already taken effect.
            restoreIfNeeded()
            return
        }
        guard !active else { return }
        restoreTask?.cancel(); restoreTask = nil
        restoreIssued = false
        guard let current = read() else { return }
        active = true
        acquisitionConfirmed = original != nil && current
        if !current {
            original = current
            save(current)
            write(true)
            // A delayed or failed setter is not proof that the change never lands.
            // Retain recovery until a later read confirms enable or release restores it.
            acquisitionConfirmed = read() == true
        }
    }

    func observeCurrentPreference() {
        guard let original, let current = read() else { return }
        if !active {
            if restoreIssued, current == original { forgetOriginal() }
            return
        }
        // Read on the same actor as acquisition. An older detached AX snapshot
        // must never discard a restore record created while that read was in flight.
        if current { acquisitionConfirmed = true }
        else if acquisitionConfirmed {
            // A confirmed enable followed by disable is a user's newer choice.
            forgetOriginal()
        }
    }

    private func restoreIfNeeded() {
        guard let original, read() != nil else { return }
        if !restoreIssued {
            restoreIssued = true
            // Queue restore after any pending enable, even if the current read
            // still matches the original. Do not resend while awaiting its result.
            write(original)
        }
        observeCurrentPreference()
    }

    private func forgetOriginal() {
        let reacquire = isRestoring && requestedActive
        original = nil
        isRestoring = false
        restoreIssued = false
        restoreTask?.cancel(); restoreTask = nil
        save(nil)
        if reacquire { configure(active: true) }
    }
}

@MainActor
final class SystemDockCoordinator {
    static let shared = SystemDockCoordinator()
    private static let recoveryKey = "WinMux.systemDock.originalAutoHide"
    private var enabled = false
    private var position: WorkspaceDockPosition = .left
    private var isShuttingDown = false
    private var snapshot = SystemDockSnapshot()
    private var generation = 0
    private var poll: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    // Elapsed intervals must not stall when the user or NTP adjusts wall time.
    private var lastRead: TimeInterval = -.infinity
    private var lastSuccess: TimeInterval = -.infinity
    private var lastSnapshotChange: TimeInterval = -.infinity
    private var pointerNearDock = false
    private var lastPointerActivity: TimeInterval = -.infinity
    private var lastKeyboardActivity: TimeInterval = -.infinity
    private var primaryHeight: CGFloat = 0
    private var screens: [CGRect] = []
    private var observers: [NSObjectProtocol] = []
    private let lease: SystemDockAutoHideLease
    private let read: @Sendable () async -> SystemDockSnapshot?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private convenience init() {
        let defaults = UserDefaults.standard
        let lease = SystemDockAutoHideLease(original: defaults.object(forKey: Self.recoveryKey) as? Bool,
            read: { SystemDockBridge.shared.autoHide }, write: { SystemDockBridge.shared.setAutoHide($0) },
            save: { value in
                if let value { defaults.set(value, forKey: Self.recoveryKey) }
                else { defaults.removeObject(forKey: Self.recoveryKey) }
                // This is a one-time recovery journal, not a per-frame preference.
                defaults.synchronize()
            })
        self.init(lease: lease, read: {
            await Task.detached(priority: .utility) { readSystemDockSnapshot() }.value
        }, sleep: { seconds in
            try await Task.sleep(for: .milliseconds(Int64(seconds * 1_000)))
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRead() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
    }

    // Inject native I/O and suspension to exercise the actual polling loop without
    // changing the user's Dock preferences or relying on wall-clock test deadlines.
    init(lease: SystemDockAutoHideLease, read: @escaping @Sendable () async -> SystemDockSnapshot?,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.lease = lease
        self.read = read
        self.sleep = sleep
    }

    func shutdown() {
        isShuttingDown = true
        configure(enabled: false, position: .left)
    }

    func configure(enabled: Bool, position: WorkspaceDockPosition) {
        let enabled = enabled && !isShuttingDown
        lease.configure(active: enabled && position == .bottom)
        let newScreens = NSScreen.screens.map(\.frame)
        let geometryChanged = screens != newScreens || self.position != position
        screens = newScreens
        self.position = position
        primaryHeight = screens.first?.height ?? 0
        guard self.enabled != enabled else {
            if enabled && geometryChanged {
                generation += 1
                readTask?.cancel(); readTask = nil
                lastRead = -.infinity
                pointerNearDock = false
                requestRead()
            }
            return
        }
        self.enabled = enabled
        generation += 1
        if !enabled {
            poll?.cancel(); poll = nil
            readTask?.cancel(); readTask = nil
            snapshot = .init()
            return
        }
        startPolling()
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.requestRead()
                // Calculate the next interval from the completed read, not the
                // previous snapshot; an idle sleep would consume the transition window.
                await self.readTask?.value
                guard !Task.isCancelled, self.enabled else { return }
                let seconds = systemDockPollInterval(pointerNearDock: self.pointerNearDock,
                    dockVisible: self.snapshot.visibleRect != nil,
                    timeSincePointerActivity: ProcessInfo.processInfo.systemUptime - self.lastPointerActivity,
                    timeSinceSnapshotChange: ProcessInfo.processInfo.systemUptime - self.lastSnapshotChange,
                    timeSinceKeyboardActivity: ProcessInfo.processInfo.systemUptime - self.lastKeyboardActivity)
                do { try await self.sleep(seconds) } catch { return }
            }
        }
    }

    func hidesDock(on monitor: Monitor) -> Bool {
        enabled && systemDockHidesDock(snapshot, position: position, display: monitor.rect)
    }

    func notePointerActivity(_ appKitPoint: CGPoint) {
        guard enabled else { return }
        lastPointerActivity = ProcessInfo.processInfo.systemUptime
        pointerNearDock = systemDockPointerNearActivation(appKitPoint, target: snapshot.targetRect,
            primaryHeight: primaryHeight, screens: screens, nativePosition: snapshot.nativePosition)
        if pointerNearDock { requestRead() }
    }

    func noteKeyboardActivity(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        // Cmd-Option-D, Control-F3 and Escape can change the Dock with a stationary pointer.
        // Reuse the existing key monitor; plain typing adds no reads or timers.
        guard enabled, keyCode == 53 || !modifierFlags.intersection([.command, .control]).isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasIdle = now - lastKeyboardActivity >= 1
        lastKeyboardActivity = now
        if wasIdle { startPolling() }
    }

    private func requestRead() {
        let now = ProcessInfo.processInfo.systemUptime
        guard enabled, readTask == nil, now - lastRead >= 0.04 else { return }
        lastRead = now
        let generation = generation
        let read = read
        readTask = Task { [weak self] in
            let next = await read()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.readTask = nil
            let monitors = workspaceSidebarResolvedPanelMonitors()
            let previouslyHidden = monitors.map { self.hidesDock(on: $0) }
            if let next {
                if self.snapshot != next { self.lastSnapshotChange = ProcessInfo.processInfo.systemUptime }
                self.snapshot = next
                self.lastSuccess = ProcessInfo.processInfo.systemUptime
                self.lease.observeCurrentPreference()
            } else if ProcessInfo.processInfo.systemUptime - self.lastSuccess > 2 {
                self.snapshot = .init()
            }
            if previouslyHidden != monitors.map({ self.hidesDock(on: $0) }) {
                WorkspaceSidebarPanel.refreshAll()
            }
        }
    }
}
