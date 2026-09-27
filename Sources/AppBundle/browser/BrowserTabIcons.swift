import AppKit
import Combine
import ImageIO

/// Only the origin survives parsing; credentials, paths and search strings do not.
func browserTabIconOrigin(_ address: String) -> URL? {
    guard let url = URL(string: address), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
          !host.allSatisfy({ $0.isNumber || $0 == "." }),
          !["localhost", ".localhost", ".local", ".internal", ".lan", ".home.arpa"].contains(where: { host == $0 || host.hasSuffix($0) }),
          !host.hasSuffix(".") else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host
    origin.port = url.port == 443 ? nil : url.port
    return origin.url
}

struct BrowserTabIconCandidate: Equatable, Sendable {
    let target: BrowserTabTarget
    /// Nil means an address was read successfully but isn't eligible for an icon.
    /// No candidate at all means the read was transient or ambiguous.
    let origin: URL?
}

struct BrowserTabIconAssociations {
    private var pending: [UInt32: (candidate: BrowserTabIconCandidate, since: TimeInterval)] = [:]
    private(set) var origins: [BrowserTabTarget: URL] = [:]

    mutating func update(_ snapshot: BrowserWindowTabs, now: TimeInterval) {
        let alive = Set(snapshot.tabs.map(\.target))
        origins = origins.filter { $0.key.windowId != snapshot.windowId || alive.contains($0.key) }
        guard let candidate = snapshot.iconCandidate, alive.contains(candidate.target),
              snapshot.tabs.filter(\.isSelected).map(\.target) == [candidate.target] else {
            pending[snapshot.windowId] = nil
            return
        }
        if let pending = pending[snapshot.windowId], pending.candidate == candidate, now - pending.since >= 0.75 {
            origins[candidate.target] = candidate.origin
        } else if pending[snapshot.windowId]?.candidate != candidate {
            // Keep the last confirmed icon through reselection, transient reads,
            // and title changes. Only a confirmed new origin replaces it.
            pending[snapshot.windowId] = (candidate, now)
        }
    }

    mutating func retain(_ targets: Set<BrowserTabTarget>) {
        origins = origins.filter { targets.contains($0.key) }
        pending = pending.filter { targets.contains($0.value.candidate.target) }
    }
}

enum BrowserTabIconDownload {
    static let maximumBytes = 256 * 1024

    static func allowsRedirect(to url: URL?, origin: URL, count: Int) -> Bool {
        guard let url, count <= 3, url.user == nil, url.password == nil else { return false }
        return browserTabIconOrigin(url.absoluteString) == origin
    }

    static func fetch(origin: URL) async -> Data? {
        guard browserTabIconOrigin(origin.absoluteString) == origin else { return nil }
        for path in ["favicon.ico", "apple-touch-icon.png"] {
            guard !Task.isCancelled else { return nil }
            if let data = await download(origin.appendingPathComponent(path), origin: origin), let image = thumbnail(data) {
                return image
            }
        }
        return nil
    }

    private static func download(_ url: URL, origin: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let delegate = BrowserTabIconSessionDelegate(origin: origin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("WinMux Website Icons", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= maximumBytes else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              ["public.png", "public.jpeg", "com.microsoft.ico", "com.compuserve.gif", "org.webmproject.webp"].contains(type as String),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

private final class BrowserTabIconSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    private let lock = NSLock()
    private var redirects = 0
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let allowed = BrowserTabIconDownload.allowsRedirect(to: request.url, origin: origin, count: redirects)
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

@MainActor
final class BrowserTabIconModel: ObservableObject {
    static let shared = BrowserTabIconModel()
    @Published private(set) var images: [URL: NSImage] = [:]
    private var failed: [URL: TimeInterval] = [:]
    private var queue: [URL] = []
    private var tasks: [URL: Task<Data?, Never>] = [:]
    private var enabled = false
    private var generation = 0
    private let download: @Sendable (URL) async -> Data?

    init(download: @escaping @Sendable (URL) async -> Data? = { await BrowserTabIconDownload.fetch(origin: $0) }) {
        self.download = download
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        queue = []
        failed = [:]
        images = [:]
    }

    func request(_ origin: URL?) {
        guard enabled, let origin, images[origin] == nil, tasks[origin] == nil, !queue.contains(origin),
              ProcessInfo.processInfo.systemUptime - (failed[origin] ?? -.infinity) > 300,
              queue.count < 128 else { return }
        queue.append(origin)
        startQueued()
    }

    private func startQueued() {
        while enabled, tasks.count < 3, !queue.isEmpty {
            let origin = queue.removeFirst()
            let token = generation
            let download = download
            let work = Task.detached(priority: .utility) { await download(origin) }
            tasks[origin] = work
            Task { [weak self] in
                let data = await work.value
                guard let self, self.enabled, self.generation == token else { return }
                self.tasks[origin] = nil
                if let data, let image = NSImage(data: data) {
                    if self.images.count >= 128, let oldest = self.images.keys.first { self.images[oldest] = nil }
                    self.images[origin] = image
                } else {
                    if self.failed.count >= 128 { self.failed.removeAll() }
                    self.failed[origin] = ProcessInfo.processInfo.systemUptime
                }
                self.startQueued()
            }
        }
    }
}
