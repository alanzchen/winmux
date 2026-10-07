import Foundation
import Darwin
import Security

/// Native messaging uses native endian; the private local relay uses the same bounded frames.
public enum BrowserPushIO {
    public static let maximumBytes = 1024 * 1024

    public static func read(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, count: 4) else { return nil }
        let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard count > 0, count <= maximumBytes else { return nil }
        return readExactly(fd, count: Int(count))
    }

    private static func readExactly(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let size = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
        return ok ? data : nil
    }

    public static func write(_ data: Data, to fd: Int32) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }
        var length = UInt32(data.count)
        let frame = Data(bytes: &length, count: 4) + data
        return frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < frame.count {
                let size = Darwin.write(fd, buffer.baseAddress! + offset, frame.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
    }

    public static func address(_ path: String) -> sockaddr_un? {
        var value = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: value.sun_path) else { return nil }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return value
    }

    public static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public static func requirement(for url: URL) -> SecRequirement? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    public static func peer(_ fd: Int32, meets requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
