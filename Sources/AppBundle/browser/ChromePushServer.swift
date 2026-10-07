import Common
import Foundation
import Security

let chromeBundleId = "com.google.Chrome"

/// Each signed embedded CLI connection supplies a native profile scope, never a page field.
final class ChromePushServer: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let listener: Int32
    private let requirement: SecRequirement
    private let inode: ino_t
    private let lock = NSLock()
    private var peers: [String: ChromePushPeer] = [:]
    private let handle: @Sendable (String, Data, ChromePushPeer) async -> Data
    private let disconnected: @Sendable (String) async -> Void

    init?(helper: URL, handle: @escaping @Sendable (String, Data, ChromePushPeer) async -> Data,
          disconnected: @escaping @Sendable (String) async -> Void) {
        guard let requirement = BrowserPushIO.requirement(for: helper),
              var address = BrowserPushIO.address(BrowserPushIdentity.socket) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        unlink(BrowserPushIdentity.socket)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(BrowserPushIdentity.socket, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var file = stat()
        guard stat(BrowserPushIdentity.socket, &file) == 0 else { close(fd); return nil }
        inode = file.st_ino
        listener = fd
        self.requirement = requirement
        self.handle = handle
        self.disconnected = disconnected
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
    }

    deinit { stop() }

    func stop() {
        source.cancel()
        lock.lock()
        let live = Array(peers.values)
        peers.removeAll()
        lock.unlock()
        live.forEach { $0.stop() }
        var file = stat()
        if stat(BrowserPushIdentity.socket, &file) == 0, file.st_ino == inode { unlink(BrowserPushIdentity.socket) }
    }

    private func acceptAll() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            // BSD may inherit the listener's nonblocking flag; frame reads use socket deadlines.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 90, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            timeout.tv_sec = 2
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let id = UUID().uuidString
            let peer = ChromePushPeer(fd)
            lock.lock()
            let accepted = !source.isCancelled && peers.count < 32
            if accepted { peers[id] = peer }
            lock.unlock()
            guard accepted else { close(fd); continue }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer {
                    peer.stop()
                    peer.closeAfterReader()
                    lock.lock(); peers[id] = nil; lock.unlock()
                    Task { await disconnected(id) }
                }
                guard BrowserPushIO.peer(fd, meets: requirement) else { return }
                // Serialize handling so messages from a single stream cannot overtake one another.
                while let data = BrowserPushIO.read(fd) {
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        peer.send(await handle(id, data, peer))
                        done.signal()
                    }
                    done.wait()
                }
            }
        }
    }
}

final class ChromePushPeer: @unchecked Sendable {
    private let fd: Int32
    private let output = DispatchQueue(label: "WinMux Chrome output", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    init(_ fd: Int32) { self.fd = fd }
    func send(_ data: Data) {
        output.async { [self] in
            lock.lock()
            let mayWrite = !stopped
            lock.unlock()
            guard mayWrite else { return }
            if !BrowserPushIO.write(data, to: fd) { stop() }
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; shutdown(fd, SHUT_RDWR) }
    }
    func closeAfterReader() {
        // Drain queued writes before the descriptor can be reused.
        output.sync { close(fd) }
    }
}
