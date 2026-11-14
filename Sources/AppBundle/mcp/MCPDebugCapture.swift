import AppKit
import Common
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The long edge of a screenshot unless asked for another, in pixels.
let debugScreenshotDefaultLongEdge = 1600
/// A recording's frames are smaller unless asked for otherwise: many of them share its memory.
let debugRecordingDefaultLongEdge = 1024
/// The long edges a client may ask for; a display is never captured larger than its native size.
let debugCaptureLongEdgeRange = 64 ... 16384

let debugScreenCapturePermissionMissing = "macOS hasn't allowed WinMux to record the screen. Allow it in System Settings → "
    + "Privacy & Security → Screen & System Audio Recording; you may need to quit and reopen WinMux after."

/// Shown with every image: an image is what was on screen, unredacted.
let debugScreenImagesNote = "Images show whatever was on screen, WinMux's own panels included, and can't be redacted: "
    + "titles and private content are in them even when include_titles is false. They're kept in memory only."

enum DebugImageFormat: String, Sendable {
    case jpeg, png

    var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
    var typeIdentifier: String { (self == .jpeg ? UTType.jpeg : UTType.png).identifier }
}

/// A display to capture, numbered and placed as `winmux_debug_snapshot` describes it.
struct DebugCaptureDisplay: Equatable, Sendable {
    let monitorId: Int
    let name: String
    /// Points, in WinMux's coordinates: the main display's top left is 0, 0, and y grows down.
    let frame: Rect
    let visibleFrame: Rect
    let displayId: CGDirectDisplayID?
}

struct DebugCapturedImage: Equatable, Sendable {
    let data: Data
    let width: Int
    let height: Int
    let format: DebugImageFormat
}

enum DebugCaptureOutcome: Equatable, Sendable {
    case image(DebugCapturedImage)
    case failed(String)
}

/// Screen capture for the debug tools: macOS's permission, and an image of each display, kept in memory only.
/// Tests replace it.
protocol DebugScreenCapturing: AnyObject, Sendable {
    /// Whether macOS lets WinMux capture the screen now. Never asks.
    func hasPermission() -> Bool
    /// Asks macOS, which shows its prompt at most once. Whether it's allowed now.
    @discardableResult func requestPermission() -> Bool
    /// One outcome per display, in order.
    func capture(_ displays: [DebugCaptureDisplay], maxLongEdge: Int, format: DebugImageFormat) async -> [DebugCaptureOutcome]
}

@MainActor var debugScreenCapture: any DebugScreenCapturing = SystemDebugScreenCapture()

/// Asks macOS for Screen Recording for the debug tools: only from Settings, when the user turns Allow debug
/// screenshots on there or presses Allow Screen Recording, and at most once. Never from a config, a reload or a tool.
@MainActor var debugScreenRecordingPermission = ScreenRecordingPermissionModel(
    preflight: { MainActor.assumeIsolated { debugScreenCapture.hasPermission() } },
    request: { MainActor.assumeIsolated { debugScreenCapture.requestPermission() } })

/// Bumped whenever the debug tools are revoked: a capture that began before sends nothing.
@MainActor private(set) var debugCaptureEpoch: UInt64 = 0

/// Allow debug screenshots or the server went off: a recording is dropped, and captures under way send nothing.
@MainActor
func revokeDebugCapture(reason: String) {
    debugCaptureEpoch &+= 1
    DebugRecorder.shared.revoke(reason: reason)
}

/// A display's image size: native, or smaller with its proportions so its long edge is at most `maxLongEdge`.
func debugCaptureSize(points: CGSize, scale: CGFloat, maxLongEdge: Int) -> (width: Int, height: Int) {
    let width = points.width * scale
    let height = points.height * scale
    let long = max(width, height)
    guard long > 0 else { return (0, 0) }
    let factor = min(1, CGFloat(maxLongEdge) / long)
    return (max(1, Int((width * factor).rounded())), max(1, Int((height * factor).rounded())))
}

/// The displays to capture: every one, or the one numbered `monitorId`.
@MainActor
func debugCaptureDisplays(_ monitorId: Int?) -> [DebugCaptureDisplay] {
    let screens = NSScreen.screens
    return sortedMonitors.compactMap { monitor in
        // Not the placeholder WinMux uses while no display is connected: it's no screen.
        guard !monitor.isFallbackMonitor, let id = monitor.monitorId_oneBased, monitorId.map({ $0 == id }) ?? true else { return nil }
        let index = monitor.monitorAppKitNsScreenScreensId - 1
        return DebugCaptureDisplay(monitorId: id, name: monitor.name, frame: monitor.rect, visibleFrame: monitor.visibleRect,
                                   displayId: screens.indices.contains(index) ? screens[index].displayId : nil)
    }
}

/// Encodes an image in memory; nothing is written to disk.
@concurrent
func debugEncodeImage(_ image: CGImage, _ format: DebugImageFormat) async -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, format.typeIdentifier as CFString, 1, nil) else { return nil }
    let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.7] : [:]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

/// ScreenCaptureKit's screenshots: every window on the display, WinMux's own included, since they're what's
/// being debugged. The cursor is shown.
final class SystemDebugScreenCapture: DebugScreenCapturing {
    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func capture(_ displays: [DebugCaptureDisplay], maxLongEdge: Int, format: DebugImageFormat) async -> [DebugCaptureOutcome] {
        guard #available(macOS 14.0, *) else { return displays.map { _ in .failed("Screenshots need macOS 14 or later.") } }
        // Without the permission, ScreenCaptureKit would ask: only Settings asks.
        guard hasPermission() else { return displays.map { _ in .failed(debugScreenCapturePermissionMissing) } }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return displays.map { _ in .failed("macOS couldn't list the displays: \(error.localizedDescription)") }
        }
        var outcomes: [DebugCaptureOutcome] = []
        for display in displays {
            guard let screen = content.displays.first(where: { $0.displayID == display.displayId }) else {
                outcomes.append(.failed("This display isn't connected now."))
                continue
            }
            outcomes.append(await debugCapture(screen, display, maxLongEdge: maxLongEdge, format: format))
        }
        return outcomes
    }
}

@available(macOS 14.0, *)
private func debugCapture(_ screen: SCDisplay, _ display: DebugCaptureDisplay, maxLongEdge: Int, format: DebugImageFormat) async -> DebugCaptureOutcome {
    let filter = SCContentFilter(display: screen, excludingWindows: [])
    let size = debugCaptureSize(points: CGSize(width: display.frame.width, height: display.frame.height),
                                scale: CGFloat(filter.pointPixelScale), maxLongEdge: maxLongEdge)
    let configuration = SCStreamConfiguration()
    configuration.width = size.width
    configuration.height = size.height
    configuration.showsCursor = true
    do {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = await debugEncodeImage(image, format) else { return .failed("WinMux couldn't encode the image.") }
        return .image(DebugCapturedImage(data: data, width: image.width, height: image.height, format: format))
    } catch {
        return .failed("macOS couldn't capture this display: \(error.localizedDescription)")
    }
}

// MARK: - The screenshot tool

struct MCPDebugScreenshotOptions: Equatable, Sendable {
    /// Only this display, numbered as `winmux_debug_snapshot` numbers them.
    var monitorId: Int? = nil
    var maxLongEdge = debugScreenshotDefaultLongEdge
    var format = DebugImageFormat.jpeg
}

/// A display and its image, as tool results describe them: where the image lies in WinMux's coordinates, and how
/// many of its pixels make a point.
func debugCaptureDescription(_ display: DebugCaptureDisplay, _ outcome: DebugCaptureOutcome, imageIndex: Int?) -> MCPJSON {
    var object: [String: MCPJSON] = [
        "id": .int(display.monitorId),
        "name": .string(display.name),
        "frame": debugSnapshotRect(display.frame),
        "visibleFrame": debugSnapshotRect(display.visibleFrame),
    ]
    switch outcome {
        case .image(let image):
            var described: [String: MCPJSON] = [
                "width": .int(image.width),
                "height": .int(image.height),
                "format": .string(image.format.rawValue),
                "pixelsPerPoint": .double(display.frame.width > 0 ? (Double(image.width) / Double(display.frame.width) * 1000).rounded() / 1000 : 0),
            ]
            if let imageIndex { described["contentIndex"] = .int(imageIndex) }
            object["image"] = .object(described)
        case .failed(let message):
            object["error"] = .string(message)
    }
    return .object(object)
}

func debugImageContent(_ image: DebugCapturedImage) -> MCPJSON {
    .object(["type": .string("image"), "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.format.mimeType)])
}

func debugTextContent(_ document: MCPJSON) -> MCPJSON {
    .object(["type": .string("text"), "text": .string(String(decoding: document.encoded(), as: UTF8.self))])
}

func debugToolError(_ message: String) -> MCPJSON {
    .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
}

/// One image of each display, or of one, with where each lies, so it lines up with `winmux_debug_snapshot`. Reads
/// only; never asks macOS for the permission, which Settings does.
@MainActor
func mcpDebugScreenshot(_ options: MCPDebugScreenshotOptions) async -> MCPJSON {
    if MCPRequestRestrictions.refusesScreenImages { return debugToolError(mcpScreenImagesRefusal) }
    let displays = debugCaptureDisplays(options.monitorId)
    if displays.isEmpty {
        return debugToolError(options.monitorId.map { "No display is numbered \($0); winmux_debug_snapshot lists them." } ?? "No display to capture.")
    }
    let capture = debugScreenCapture
    guard capture.hasPermission() else { return debugToolError(debugScreenCapturePermissionMissing) }
    let epoch = debugCaptureEpoch
    let outcomes = await capture.capture(displays, maxLongEdge: options.maxLongEdge, format: options.format)
    // Revoked while capturing: what was captured is dropped.
    guard debugCaptureEpoch == epoch else {
        return debugToolError("Allow debug screenshots or the MCP server was turned off while capturing: no image is sent.")
    }
    var images: [MCPJSON] = []
    var described: [MCPJSON] = []
    for (display, outcome) in zip(displays, outcomes) {
        if case .image(let image) = outcome {
            images.append(debugImageContent(image))
            described.append(debugCaptureDescription(display, outcome, imageIndex: images.count))
        } else {
            described.append(debugCaptureDescription(display, outcome, imageIndex: nil))
        }
    }
    let document: MCPJSON = .object([
        "schema": .string("winmux-debug-screenshot/1"),
        "note": .string(debugScreenImagesNote),
        "displays": .array(described),
    ])
    return .object(["content": .array([debugTextContent(document)] + images), "isError": .bool(images.isEmpty)])
}
