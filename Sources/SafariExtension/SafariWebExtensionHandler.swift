import Foundation
import SafariServices

/// Relays each message from the extension's background script to WinMux and returns WinMux's
/// answer. Safari runs this in a sandbox, so it reaches WinMux through a socket in the app group
/// container they share; since macOS 15, apps outside the group can't use that folder without
/// asking. WinMux checks this extension's signature before reading a message. The handler keeps
/// nothing and doesn't read the messages, except to add Safari's profile.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        var envelope: [String: Any] = ["message": item?.userInfo?[SFExtensionMessageKey] ?? NSNull()]
        if #available(macOS 14.0, *), let profile = item?.userInfo?[SFExtensionProfileKey] {
            envelope["profile"] = (profile as? UUID)?.uuidString ?? profile as? String
        }
        let request = UncheckedRequest(context: context, envelope: envelope)
        DispatchQueue.global(qos: .utility).async {
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: relayToWinMux(request.envelope) ?? ["v": 1, "ok": false]]
            request.context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}

/// The request moves to one background exchange and is completed exactly once there.
private struct UncheckedRequest: @unchecked Sendable {
    let context: NSExtensionContext
    let envelope: [String: Any]
}

private let maximumMessageBytes = 2 * 1024 * 1024

private func relayToWinMux(_ envelope: [String: Any]) -> Any? {
    guard JSONSerialization.isValidJSONObject(envelope),
          let request = try? JSONSerialization.data(withJSONObject: envelope), request.count <= maximumMessageBytes,
          let group = Bundle.main.object(forInfoDictionaryKey: "WinMuxAppGroup") as? String,
          let socket = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
              .appendingPathComponent("tabs.sock").path,
          let answer = exchange(request, at: socket)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: answer)
}

/// One request and one answer, each a 4-byte big-endian length and JSON, within three seconds.
private func exchange(_ request: Data, at path: String) -> Data? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    var length = UInt32(request.count).bigEndian
    let frame = Data(bytes: &length, count: 4) + request
    guard transfer(descriptor, count: frame.count, until: deadline, from: frame) != nil,
          let header = transfer(descriptor, count: 4, until: deadline, from: nil) else { return nil }
    let count = header.reduce(0) { $0 << 8 | Int($1) }
    guard count <= maximumMessageBytes else { return nil }
    return transfer(descriptor, count: count, until: deadline, from: nil)
}

/// Writes `source`, or reads `count` bytes, waiting with poll so the whole exchange has one deadline.
/// The descriptor doesn't block, so no single write outlasts it.
private func transfer(_ descriptor: Int32, count: Int, until deadline: TimeInterval, from source: Data?) -> Data? {
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    let reading = source == nil
    var data = source ?? Data(count: count)
    let complete = data.withUnsafeMutableBytes { buffer -> Bool in
        var offset = 0
        while offset < count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(reading ? POLLIN : POLLOUT), revents: 0)
            let ready = poll(&descriptorPoll, 1, Int32(remaining * 1000) + 1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return false }
            let moved = reading ? read(descriptor, buffer.baseAddress! + offset, count - offset)
                : write(descriptor, buffer.baseAddress! + offset, count - offset)
            if moved < 0, errno == EINTR || errno == EAGAIN { continue }
            guard moved > 0 else { return false }
            offset += moved
        }
        return true
    }
    return complete ? data : nil
}
