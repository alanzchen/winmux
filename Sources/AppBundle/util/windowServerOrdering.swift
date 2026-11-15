import AppKit

/// Whether the window server has `windowId` ordered in, from SkyLight's `SLSWindowIsOrderedIn`: private and read-only,
/// available with SIP on (Rift and OmniWM use it), looked up at run time. Nil when it isn't there or fails.
///
/// Probed on macOS 27.0 (26A428) in a VM with a synthetic app (2026-11-14): ordered out for a window closed by an app
/// that keeps it (`orderOut` on close), a minimized window and a hidden app's window; ordered in for a window on a
/// desktop Space while a full-screen Space is shown, for a full-screen window on a Space not shown, and for the same
/// hidden-on-close window shown again. An id the window server doesn't have answers "ordered out" too, without an
/// error: ask only of a window it lists. (`SLSCopySpacesForWindows` goes on naming the Space of an ordered-out window,
/// so it can't tell.)
nonisolated func windowServerIsOrderedIn(_ windowId: UInt32) -> Bool? {
    guard let skyLight = SkyLightWindowOrdering.shared else { return nil }
    var ordered: UInt8 = 0
    return skyLight.isOrderedIn(skyLight.connection, windowId, &ordered) == 0 ? ordered != 0 : nil
}

private struct SkyLightWindowOrdering: @unchecked Sendable {
    typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Int32
    typealias MainConnectionID = @convention(c) () -> Int32
    let connection: Int32
    let isOrderedIn: IsOrderedIn

    static let shared: SkyLightWindowOrdering? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let mainConnection = dlsym(library, "SLSMainConnectionID"),
              let isOrderedIn = dlsym(library, "SLSWindowIsOrderedIn")
        else { return nil }
        return SkyLightWindowOrdering(connection: unsafeBitCast(mainConnection, to: MainConnectionID.self)(),
            isOrderedIn: unsafeBitCast(isOrderedIn, to: IsOrderedIn.self))
    }()
}
