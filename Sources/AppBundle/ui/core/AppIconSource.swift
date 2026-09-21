import AppKit
import CryptoKit

struct AppIconArtwork: Sendable {
    let image: CGImage
    let fingerprint: Data
}

/// Only public icon lookups: no screen capture, Dock scraping, or new permissions.
enum AppIconSource {
    private static let rasterCache = AppIconRasterCache()
    static func bundleImage(_ request: AppIconRequest) -> NSImage? {
        guard let path = request.bundlePath ?? request.bundleIdentifier.flatMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path
        }), FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage
        image?.isTemplate = false
        return image
    }

    static func read(_ requests: [AppIconRequest]) async -> [AppIconArtwork?] {
        let work = Task.detached(priority: .utility) {
            // Most views already know the exact bundle path; those need no process scan.
            let running = requests.contains(where: { $0.bundlePath == nil })
                ? NSWorkspace.shared.runningApplications.filter { !$0.isTerminated } : []
            let byIdentifier = Dictionary(grouping: running, by: { $0.bundleIdentifier ?? "" })
            return requests.map { request in
                guard !Task.isCancelled else { return nil as AppIconArtwork? }
                return autoreleasepool {
                    // A path is authoritative: another installed copy with the same
                    // bundle identifier must never donate its replacement icon.
                    // NSRunningApplication.icon also caches old artwork after Finder
                    // replaces it, even on freshly enumerated application objects.
                    let icon: NSImage?
                    if request.bundlePath != nil {
                        icon = bundleImage(request)
                    } else {
                        let candidates = byIdentifier[request.bundleIdentifier ?? ""] ?? []
                        let app = candidates.count == 1 ? candidates.first : candidates.first(where: \.isActive)
                        let located = AppIconRequest(bundleIdentifier: request.bundleIdentifier, bundlePath: app?.bundleURL?.path)
                        icon = located.flatMap(bundleImage) ?? app?.icon
                    }
                    guard let icon else { return nil }
                    return rasterize(icon)
                }
            }
        }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    static func rasterize(_ icon: NSImage) -> AppIconArtwork? {
        // 256 pixels cover a 48pt icon magnified to 96pt on Retina displays.
        let size = 256
        var proposed = CGRect(x: 0, y: 0, width: size, height: size)
        guard let image = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        // Continue asking for fresh artwork (including Finder replacements), but
        // avoid repeated resampling and color conversion of unchanged source pixels.
        return rasterCache.artwork(for: image) { rasterize(image, size: size) }
    }

    private static func rasterize(_ image: CGImage, size: Int) -> AppIconArtwork? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2,
                                       width: width, height: height))
        guard let pixels = context.data, let prepared = context.makeImage() else { return nil }
        let digest = Data(SHA256.hash(data: Data(bytes: pixels, count: size * size * 4)))
        return AppIconArtwork(image: prepared, fingerprint: digest)
    }
}

/// NSWorkspace recreates CGImages between polls, so compare pixels and their interpretation,
/// not object identity. Keep only prepared artwork and small descriptors, not source bitmaps.
/// NSLock protects the cache and its synchronous renderer across utility tasks.
final class AppIconRasterCache: @unchecked Sendable {
    private struct Format {
        let dimensions: [Int]
        let bitmapInfo: CGBitmapInfo
        let intent: CGColorRenderingIntent
        let interpolate: Bool
        let isMask: Bool
        let colorSpace: CGColorSpace?
        let decode: [CGFloat]?

        init(_ image: CGImage) {
            dimensions = [image.width, image.height, image.bitsPerComponent, image.bitsPerPixel, image.bytesPerRow]
            bitmapInfo = image.bitmapInfo
            intent = image.renderingIntent
            interpolate = image.shouldInterpolate
            isMask = image.isMask
            colorSpace = image.colorSpace
            let count = image.isMask ? 2 : (image.colorSpace?.numberOfComponents ?? 0) * 2
            decode = image.decode.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
        }

        func matches(_ other: Self) -> Bool {
            dimensions == other.dimensions && bitmapInfo == other.bitmapInfo && intent == other.intent
                && interpolate == other.interpolate && isMask == other.isMask && decode == other.decode
                && (colorSpace == nil && other.colorSpace == nil
                    || colorSpace != nil && other.colorSpace != nil && CFEqual(colorSpace!, other.colorSpace!))
        }
    }
    private let lock = NSLock()
    private var entries: [Data: (format: Format, artwork: AppIconArtwork, use: UInt64)] = [:]
    private var use: UInt64 = 0
    private let limit: Int

    init(limit: Int = 64) { self.limit = max(0, limit) }

    func artwork(for image: CGImage, render: () -> AppIconArtwork?) -> AppIconArtwork? {
        guard let pixels = image.dataProvider?.data else { return render() }
        let key = Data(SHA256.hash(data: pixels as Data))
        let format = Format(image)
        return lock.withLock {
            use &+= 1
            if let cached = entries[key], cached.format.matches(format) {
                entries[key] = (cached.format, cached.artwork, use)
                return cached.artwork
            }
            guard let result = render() else { return nil }
            guard limit > 0 else { return result }
            if entries.count >= limit, let oldest = entries.min(by: { $0.value.use < $1.value.use })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[key] = (format, result, use)
            return result
        }
    }
}
