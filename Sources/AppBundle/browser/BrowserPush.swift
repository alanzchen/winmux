import Foundation

/// Transport version is separate from Safari's backwards-compatible metadata version.
struct BrowserPushEnvelope: Equatable, Sendable {
    let browser: String
    let epoch: String
    let sequence: Int
    let snapshot: Bool
    let removed: [Int]

    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              abs(n.doubleValue) <= 9_007_199_254_740_991 else { return nil }
        return n.intValue
    }

    static func decode(_ value: Any?) -> Self? {
        guard let raw = value as? [String: Any], integer(raw["v"]) == 1,
              let browser = raw["browser"] as? String, ["safari", "chrome"].contains(browser),
              let epoch = raw["epoch"] as? String, UUID(uuidString: epoch) != nil,
              let sequence = integer(raw["seq"]), sequence > 0,
              let kind = raw["kind"] as? String, ["snapshot", "delta"].contains(kind),
              let removed = raw["removed"] as? [Any], removed.count <= 64 else { return nil }
        let ids = removed.compactMap(integer)
        guard ids.count == removed.count, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 >= 0 }), kind != "snapshot" || ids.isEmpty else { return nil }
        return .init(browser: browser, epoch: epoch, sequence: sequence, snapshot: kind == "snapshot", removed: ids)
    }
}

struct BrowserPushControl: Equatable, Sendable {
    let profile: String
    let session: String
    let browser: String
    let epoch: String
    let request: String
    let kind: String
    let window: Int?
    let tab: Int?

    static func decode(_ raw: [String: Any], profile: String, session: String) -> Self? {
        guard BrowserPushEnvelope.integer(raw["protocol"]) == 1,
              let browser = raw["browser"] as? String, ["safari", "chrome"].contains(browser),
              let epoch = raw["epoch"] as? String, UUID(uuidString: epoch) != nil,
              let request = raw["request"] as? String, UUID(uuidString: request) != nil,
              let kind = raw["kind"] as? String, ["ready", "result", "activated", "refused"].contains(kind) else { return nil }
        return .init(profile: profile, session: session, browser: browser, epoch: epoch, request: request, kind: kind,
                     window: BrowserPushEnvelope.integer(raw["window"]), tab: BrowserPushEnvelope.integer(raw["tab"]))
    }
}

/// A gap poisons the stream until a newer full snapshot. Duplicate deliveries do not renew it.
struct BrowserPushSequence {
    enum Acceptance { case accept, duplicate, snapshotRequired }
    private(set) var session = ""
    private(set) var epoch = ""
    private(set) var sequence = 0
    private(set) var valid = false
    private var retired: [String] = []

    mutating func receive(session: String, envelope: BrowserPushEnvelope) -> Acceptance {
        let same = self.session == session && epoch == envelope.epoch
        let identity = session + ":" + envelope.epoch
        if !same, retired.contains(identity) { return .duplicate }
        if same, envelope.sequence <= sequence { return valid ? .duplicate : .snapshotRequired }
        guard envelope.snapshot || (same && valid && envelope.sequence == sequence + 1) else {
            valid = false
            return .snapshotRequired
        }
        if !same, !self.session.isEmpty { retired.append(self.session + ":" + epoch); if retired.count > 256 { retired.removeFirst() } }
        self.session = session
        epoch = envelope.epoch
        sequence = envelope.sequence
        valid = true
        return .accept
    }
}

/// Command scope includes the stream as well as the browser's own ids. It never uses titles.
struct BrowserPushTarget: Equatable, Sendable {
    let browser: String
    let profile: String
    let session: String
    let epoch: String
    let window: Int
    let tab: Int
    let sequence: Int
}

/// Result and postcondition may arrive in either order. Neither alone establishes success.
struct BrowserPushConfirmation {
    let request: String
    let target: BrowserPushTarget
    private(set) var result = false
    private(set) var activated = false
    private(set) var refused = false

    mutating func receive(_ control: BrowserPushControl) {
        guard control.request == request, control.browser == target.browser, control.profile == target.profile,
              control.session == target.session, control.epoch == target.epoch,
              control.window == target.window, control.tab == target.tab else { return }
        if control.kind == "result" { result = true }
        if control.kind == "activated" { activated = true }
        if control.kind == "refused" { refused = true }
    }

    var outcome: BrowserTabActionResult? {
        if refused { return .notDispatched(.changed) }
        return result && activated ? .dispatched(.confirmed) : nil
    }
}

/// AX is safe only before any extension action, including an explicit refusal before invocation.
/// A missing reply, cancellation after dispatch, or partial confirmation can never press again.
@MainActor
func browserTabSelectWithFallback(push: (() async -> BrowserTabActionResult)?,
                                  ax: () async -> BrowserTabActionResult) async -> BrowserTabActionResult {
    guard !Task.isCancelled else { return .notDispatched(.cancelled) }
    if let push {
        let result = await push()
        guard result == .notDispatched(.changed), !Task.isCancelled else { return result }
    }
    return await ax()
}
