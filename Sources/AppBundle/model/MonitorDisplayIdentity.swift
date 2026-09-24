import AppKit

/// Identifies a physical display across reboots, reconnects, and rearrangements. Top-left
/// points and `NSScreen` indices change whenever displays move or the main display changes.
struct MonitorDisplayIdentity: Hashable, Sendable {
    /// `CGDisplayCreateUUIDFromDisplayID`, derived from EDID. Identical panels without serial
    /// numbers can share it.
    var uuid: String?
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var isBuiltin: Bool

    init(uuid: String?, vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0, isBuiltin: Bool = false) {
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
    }

    var key: String? {
        if let uuid { return uuid }
        guard serial != 0, vendor != 0 || model != 0 else { return nil }
        return "\(vendor):\(model):\(serial)"
    }

    static func forDisplay(_ displayId: CGDirectDisplayID) -> MonitorDisplayIdentity {
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayId)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return MonitorDisplayIdentity(
            uuid: uuid,
            vendor: CGDisplayVendorNumber(displayId),
            model: CGDisplayModelNumber(displayId),
            serial: CGDisplaySerialNumber(displayId),
            isBuiltin: CGDisplayIsBuiltin(displayId) != 0,
        )
    }
}
