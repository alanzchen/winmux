import AppKit
import CryptoKit

struct AppIconArtwork: Sendable {
    let image: CGImage
    let fingerprint: Data
}

/// Only public icon lookups: no screen capture, Dock scraping, or new permissions.
enum AppIconSource {
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
        guard let image = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
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
