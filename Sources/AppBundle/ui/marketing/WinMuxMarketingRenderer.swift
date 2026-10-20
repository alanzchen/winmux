import AppKit
import SwiftUI

/// Exports a deterministic marketing composition that embeds WinMux's production SwiftUI views.
/// The renderer does not capture the screen or read pixels from application windows.
@MainActor
public func renderWinMuxMarketingImage(to outputURL: URL) throws {
    try renderMarketingView(WinMuxMarketingCanvas(), to: outputURL)
}

/// Exports a focused proof containing one real Safari surface and two WinMux tabs.
@MainActor
public func renderWinMuxSafariProofImage(to outputURL: URL) throws {
    try renderMarketingView(WinMuxSafariProofCanvas(), to: outputURL)
}

/// Exports a Helium tab group (with Ghostty and Finder tabs) tiled beside Safari and the WinMux sidebar.
@MainActor
public func renderWinMuxAppsProofImage(to outputURL: URL) throws {
    try renderMarketingView(WinMuxAppsProofCanvas(), to: outputURL)
}

/// Exports a tiled Safari and Plasticity workspace using their measured split ratio.
@MainActor
public func renderWinMuxSafariPlasticityProofImage(to outputURL: URL) throws {
    try renderMarketingView(
        WinMuxSafariPlasticityProofCanvas(),
        to: outputURL,
        size: CGSize(width: 1_600, height: 928),
        renderScale: 2
    )
}

@MainActor
private func renderMarketingView<Content: View>(
    _ rootView: Content,
    to outputURL: URL,
    size: CGSize = CGSize(width: 1_600, height: 900),
    renderScale: CGFloat = 1
) throws {
    let renderSize = CGSize(width: size.width * renderScale, height: size.height * renderScale)
    let content = rootView
        .frame(width: size.width, height: size.height)
        .scaleEffect(renderScale, anchor: .topLeading)
        .frame(width: renderSize.width, height: renderSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .environment(\.workspaceSidebarClockDate, Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 5, hour: 10)
        ))

    // Liquid Glass is composed by WindowServer. A detached NSHostingView cannot reproduce the
    // material: SwiftUI.ImageRenderer omits AppKit-backed surfaces, and cacheDisplay has no live
    // compositor. Host the code-defined scene in a dedicated window, wait for composition, then
    // read only that window's surface. No existing app window or desktop content is captured.
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    if !application.isRunning {
        application.finishLaunching()
    }

    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = CGRect(origin: .zero, size: renderSize)
    let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: renderSize),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.sharingType = .readOnly

    if let screenFrame = NSScreen.main?.visibleFrame {
        window.setFrameOrigin(CGPoint(
            x: screenFrame.midX - (renderSize.width / 2),
            y: screenFrame.midY - (renderSize.height / 2)
        ))
    }

    window.orderFrontRegardless()
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    let windowNumber = CGWindowID(window.windowNumber)
    guard let image = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowNumber,
        [.boundsIgnoreFraming, .bestResolution]
    ) else {
        window.orderOut(nil)
        throw WinMuxMarketingRenderError.renderFailed
    }

    window.orderOut(nil)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
        throw WinMuxMarketingRenderError.encodingFailed
    }
    try data.write(to: outputURL, options: .atomic)
}

private struct WinMuxSafariProofCanvas: View {
    private let strip = MarketingFixtures.browserTabStrip

    private var groupSize: CGSize {
        let maximumContentSize = CGSize(width: 1_360, height: 780)
        guard let pixels = MarketingAsset.pixelSize(named: "safari-retina.png"),
              pixels.width > 0,
              pixels.height > 0
        else {
            return CGSize(width: 1_262, height: 820)
        }

        let aspectRatio = pixels.width / pixels.height
        let contentWidth = min(maximumContentSize.width, maximumContentSize.height * aspectRatio)
        let contentHeight = contentWidth / aspectRatio
        return CGSize(width: contentWidth, height: contentHeight + strip.frame.height)
    }

    var body: some View {
        ZStack {
            MarketingDesktopWallpaper(
                imageName: "macos-blue-wallpaper.jpg",
                darkeningOpacity: 0.58
            )

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            )

            MarketingCapturedTabWindow(
                strip: strip,
                imageName: "safari-retina.png",
                contentMode: .fit
            )
            .frame(width: groupSize.width, height: groupSize.height)
        }
        .frame(width: 1_600, height: 900)
        .clipped()
    }
}

private struct WinMuxAppsProofCanvas: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MarketingDesktopWallpaper(
                imageName: "macos-blue-wallpaper.jpg",
                darkeningOpacity: 0.48
            )

            LinearGradient(
                colors: [.black.opacity(0.02), .black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )

            MarketingCapturedTabWindow(
                strip: MarketingFixtures.appsTabStrip,
                imageName: "helium-retina.png",
                imageAlignment: .top
            )
            .frame(width: 918, height: 852)
            .offset(x: 64, y: 24)

            MarketingCapturedTabWindow(
                strip: MarketingFixtures.browserTabStrip,
                imageName: "safari-retina.png",
                imageAlignment: .top
            )
            .frame(width: 582, height: 852)
            .offset(x: 994, y: 24)

            if let sidebar = MarketingAsset.image(named: "winmux-retina.png") {
                Image(nsImage: sidebar)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 900, alignment: .topLeading)
                    .frame(width: 560, height: 900, alignment: .topLeading)
                    .offset(x: 0, y: 0)
                    .zIndex(5)
            }
        }
        .frame(width: 1_600, height: 900)
        .clipped()
    }
}

private struct WinMuxSafariPlasticityProofCanvas: View {
    private let canvasHeight: CGFloat = 928
    private let sidebarWidth: CGFloat = 280
    private let reservedSidebarWidth: CGFloat = 50
    private let topMargin: CGFloat = 56
    private let sidebarTopMargin: CGFloat = 35
    private let gutter: CGFloat = 8
    // Expansion overlays the tiles; only the collapsed rail reserves layout space.
    private var safariAspect: CGFloat { captureAspect("helium-current-retina.png") }
    private var plasticityAspect: CGFloat { captureAspect("plasticity-current-retina.png") }
    private var contentHeight: CGFloat {
        min(
            (1_600 - reservedSidebarWidth - 3 * gutter - 4 * windowTabGroupShellHorizontalInset())
                / (safariAspect + plasticityAspect),
            canvasHeight - topMargin - gutter - chromeHeight
        )
    }
    private var safariWidth: CGFloat { contentHeight * safariAspect + 2 * windowTabGroupShellHorizontalInset() }
    private var plasticityWidth: CGFloat { contentHeight * plasticityAspect + 2 * windowTabGroupShellHorizontalInset() }
    private var chromeHeight: CGFloat {
        MarketingFixtures.plasticityTabStrip.frame.height
            + windowTabGroupShellTopInset() + windowTabGroupShellBottomInset()
    }
    private var tileHeight: CGFloat { contentHeight + chromeHeight }
    // Keep the right and inter-window gaps fixed. Extra space stays beneath the sidebar.
    private var tilesLeading: CGFloat { 1_600 - 2 * gutter - safariWidth - plasticityWidth }

    private func captureAspect(_ name: String) -> CGFloat {
        guard let image = MarketingAsset.image(named: name) else {
            preconditionFailure("Missing marketing capture: \(name)")
        }
        return image.size.width / image.size.height
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarketingDesktopWallpaper(
                imageName: "macos-blue-wallpaper.jpg",
                darkeningOpacity: 0.46,
                height: canvasHeight
            )

            LinearGradient(
                colors: [.black.opacity(0.02), .black.opacity(0.26)],
                startPoint: .top,
                endPoint: .bottom
            )

            MarketingCapturedTabWindow(
                strip: MarketingFixtures.safariCurrentTabStrip,
                imageName: "helium-current-retina.png",
                contentMode: .fit,
                imageAlignment: .top,
                shadowOpacity: 0
            )
            .frame(width: safariWidth, height: tileHeight)
            .offset(x: tilesLeading, y: topMargin)

            MarketingCapturedTabWindow(
                strip: MarketingFixtures.plasticityTabStrip,
                imageName: "plasticity-current-retina.png",
                contentMode: .fit,
                imageAlignment: .top,
                shadowOpacity: 0
            )
            .frame(width: plasticityWidth, height: tileHeight)
            .offset(x: tilesLeading + gutter + safariWidth, y: topMargin)

        }
        .frame(width: 1_600, height: canvasHeight)
        .overlay(alignment: .topLeading) {
            let sidebar = WorkspaceSidebarView(snapshot: MarketingFixtures.sidebarSnapshot)
            let shape = sidebar.sidebarShape(layout: sidebar.dockLayout(availableHeight: canvasHeight - sidebarTopMargin))
            sidebar
                .frame(width: sidebarWidth, height: canvasHeight - sidebarTopMargin)
                .background(
                    Color(red: 0.012, green: 0.045, blue: 0.115).opacity(0.50),
                    in: shape
                )
                .clipShape(shape)
                .offset(y: sidebarTopMargin)
        }
        .overlay(alignment: .top) {
            MarketingMenuBar()
        }
        .clipped()
    }
}

private enum WinMuxMarketingRenderError: LocalizedError {
    case renderFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
            case .renderFailed:
                "SwiftUI did not produce a rendered image."
            case .encodingFailed:
                "AppKit could not encode the rendered image as PNG."
        }
    }
}

private struct WinMuxMarketingCanvas: View {
    private let sidebarSnapshot = MarketingFixtures.sidebarSnapshot
    private let codeTabs = MarketingFixtures.codeTabStrip
    private let browserTabs = MarketingFixtures.browserTabStrip

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarketingDesktopWallpaper()

            WorkspaceSidebarView(snapshot: sidebarSnapshot)
                .frame(width: sidebarSnapshot.visibleWidth, height: 906)
                .zIndex(5)

            MarketingCapturedTabWindow(strip: codeTabs, imageName: "xcode-winmux.png")
                .frame(width: 590, height: 620)
                .offset(x: 300, y: 44)
                .rotationEffect(.degrees(-0.6))
                .zIndex(2)

            MarketingCapturedTabWindow(strip: browserTabs, imageName: "safari-swiftui.png")
                .frame(width: 735, height: 500)
                .offset(x: 820, y: 76)
                .rotationEffect(.degrees(0.45))
                .zIndex(3)

            MarketingCapturedWindow(imageName: "finder-winmux.png")
                .frame(width: 390, height: 260)
                .offset(x: 390, y: 584)
                .rotationEffect(.degrees(-1.1))
                .zIndex(3.2)

            campaignCopy
                .frame(width: 700, alignment: .leading)
                .offset(x: 835, y: 627)
                .zIndex(4)
        }
        .clipped()
    }

    private var campaignCopy: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                MarketingAppIcon()
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.42), radius: 14, y: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text("WinMux")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("A sidebar-first window manager for macOS")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
            }

            Text("Your workspace, in flow.")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .tracking(-1.2)

            HStack(spacing: 10) {
                MarketingFeaturePill(symbol: "sidebar.left", title: "See every space")
                MarketingFeaturePill(symbol: "rectangle.3.group", title: "Group any window")
                MarketingFeaturePill(symbol: "arrow.up.left.and.arrow.down.right", title: "Drag to arrange")
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.44))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
    }
}

private enum MarketingAsset {
    private static func url(named name: String) -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return root.appendingPathComponent("resources/marketing/captures/\(name)")
    }

    static func image(named name: String) -> NSImage? {
        NSImage(contentsOf: url(named: name))
    }

    static func pixelSize(named name: String) -> CGSize? {
        guard let data = try? Data(contentsOf: url(named: name)),
              let representation = NSBitmapImageRep(data: data)
        else { return nil }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
}

private struct MarketingDesktopWallpaper: View {
    var imageName = "macos-sonoma-wallpaper.png"
    var darkeningOpacity = 0.0
    var height: CGFloat = 900

    var body: some View {
        ZStack {
            if let wallpaper = MarketingAsset.image(named: imageName) {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(red: 0.12, green: 0.18, blue: 0.42)
            }

            Color(red: 0.005, green: 0.018, blue: 0.075)
                .opacity(darkeningOpacity)

            LinearGradient(
                colors: [Color.black.opacity(0.06), Color.black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.16), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: Color.black.opacity(0.10), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .frame(width: 1_600, height: height)
        .clipped()
    }
}

private struct MarketingMenuBar: View {
    private var clockText: String {
        "Sat Sep 5  10:00 AM"
    }

    var body: some View {
        HStack(spacing: 21) {
            Image(systemName: "apple.logo")
                .font(.system(size: 15, weight: .semibold))
            Text("WinMux").fontWeight(.semibold)
            Text("File")
            Text("Edit")
            Text("View")
            Text("Window")
            Text("Help")
            Spacer()
            Text(clockText)
        }
        .font(.system(size: 13.25, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: 27)
    }
}

/// Wraps a real application-window capture with WinMux's production tab-group chrome.
private struct MarketingCapturedTabWindow: View {
    let strip: WindowTabStripViewModel
    let imageName: String
    var contentMode: ContentMode = .fill
    var imageAlignment: Alignment = .center
    var shadowOpacity = 0.50

    var body: some View {
        GeometryReader { proxy in
            let innerRect = WindowTabGroupShellShape.innerRect(
                in: CGRect(origin: .zero, size: proxy.size),
                tabBarHeight: strip.frame.height
            )
            let outerShape = WindowTabGroupOuterShape(
                activeWindowCornerRadius: strip.activeWindowCornerRadius
            )

            ZStack(alignment: .top) {
                outerShape
                    .fill(Color(red: 0.025, green: 0.10, blue: 0.22).opacity(0.20))
                    .overlay {
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.blue.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }

                if let image = MarketingAsset.image(named: imageName) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(
                            width: innerRect.width,
                            height: innerRect.height,
                            alignment: imageAlignment
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(
                            cornerRadius: strip.activeWindowCornerRadius,
                            style: .continuous
                        ))
                        .offset(y: innerRect.minY)

                }

                MarketingMeasuredTabGroupFrameView(strip: strip, groupSize: proxy.size)
                WindowTabStripView(strip: strip)
                    .frame(height: strip.frame.height)
            }
            .clipShape(outerShape)
            .shadow(color: .black.opacity(shadowOpacity), radius: 28, y: 17)
        }
    }
}

private struct MarketingMeasuredTabGroupFrameView: View {
    let strip: WindowTabStripViewModel
    let groupSize: CGSize

    var body: some View {
        let tabHeight = min(strip.frame.height, groupSize.height)
        let outerShape = WindowTabGroupOuterShape(
            activeWindowCornerRadius: strip.activeWindowCornerRadius
        )
        let innerShape = MarketingMeasuredWindowBoundaryShape(
            tabBarHeight: tabHeight,
            cornerRadius: strip.activeWindowCornerRadius
        )
        let shellShape = MarketingMeasuredWindowShellShape(
            tabBarHeight: tabHeight,
            cornerRadius: strip.activeWindowCornerRadius
        )

        ZStack(alignment: .topLeading) {
            GlassSurface(
                shape: outerShape,
                style: config.workspaceSidebar.chromeStyle,
                solidColor: config.workspaceSidebar.resolvedSolidChromeColor
            )
            .mask {
                shellShape.fill(style: FillStyle(eoFill: true))
            }

            outerShape
                .stroke(Color.white.opacity(GlassToken.borderOpacity), lineWidth: windowTabGroupFrameStrokeWidth)
                .glassShadow(.raised)

            Rectangle()
                .fill(Color.white.opacity(GlassToken.separatorOpacity))
                .frame(height: StrokeToken.hairline)
                .offset(y: tabHeight - StrokeToken.hairline)

            innerShape
                .stroke(mattePanelInsetShadow, lineWidth: windowTabGroupFrameInnerStrokeWidth)
        }
        .frame(width: groupSize.width, height: groupSize.height)
        .allowsHitTesting(false)
    }
}

private struct MarketingMeasuredWindowShellShape: Shape {
    let tabBarHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(WindowTabGroupOuterShape(activeWindowCornerRadius: cornerRadius).path(in: rect))
        path.addPath(MarketingMeasuredWindowBoundaryShape(
            tabBarHeight: tabBarHeight,
            cornerRadius: cornerRadius
        ).path(in: rect))
        return path
    }
}

private struct MarketingMeasuredWindowBoundaryShape: Shape {
    let tabBarHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let innerRect = WindowTabGroupShellShape.innerRect(
            in: rect,
            tabBarHeight: tabBarHeight
        )
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: innerRect)
    }
}

private struct MarketingCapturedWindow: View {
    let imageName: String

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image = MarketingAsset.image(named: imageName) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.035, green: 0.038, blue: 0.052)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.48), radius: 25, y: 15)
        }
    }
}

private struct MarketingFeaturePill: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.86))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5) }
    }
}

private struct MarketingAppIcon: View {
    private struct Pane: Identifiable {
        let id: Int
        let color: Color
        let size: CGSize
        let offset: CGSize
        let rotation: Angle
    }

    private let panes = [
        Pane(id: 0, color: Color(red: 0.12, green: 0.52, blue: 0.95), size: CGSize(width: 35, height: 29), offset: CGSize(width: -5, height: -16), rotation: .degrees(-9)),
        Pane(id: 1, color: Color(red: 0.92, green: 0.57, blue: 0.05), size: CGSize(width: 31, height: 32), offset: CGSize(width: 18, height: -15), rotation: .degrees(10)),
        Pane(id: 2, color: Color(red: 0.47, green: 0.27, blue: 0.70), size: CGSize(width: 29, height: 23), offset: CGSize(width: -22, height: 0), rotation: .degrees(-7)),
        Pane(id: 3, color: Color(red: 0.14, green: 0.56, blue: 0.31), size: CGSize(width: 37, height: 29), offset: CGSize(width: -8, height: 19), rotation: .degrees(8)),
        Pane(id: 4, color: Color(red: 0.78, green: 0.08, blue: 0.66), size: CGSize(width: 28, height: 27), offset: CGSize(width: 20, height: 18), rotation: .degrees(-8)),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.10), Color.black.opacity(0.98)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 110
                    )
                )

            ForEach(panes) { pane in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [pane.color.opacity(0.72), pane.color.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(pane.color.opacity(0.85), lineWidth: 0.8)
                    }
                    .frame(width: pane.size.width, height: pane.size.height)
                    .rotationEffect(pane.rotation)
                    .offset(pane.offset)
            }

            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

@MainActor
private enum MarketingFixtures {
    private final class TabGroupIdentity {}

    private static let codeIdentity = TabGroupIdentity()
    private static let browserIdentity = TabGroupIdentity()
    private static let heliumIdentity = TabGroupIdentity()
    private static let safariCurrentIdentity = TabGroupIdentity()
    private static let plasticityIdentity = TabGroupIdentity()
    private static let defaultProject = WorkspaceProjectId(rawValue: "default")

    static let sidebarSnapshot = WorkspaceSidebarSnapshot(
        workspaces: [
            WorkspaceSidebarWorkspaceViewModel(
                name: "code",
                projectId: defaultProject,
                displayName: "Design",
                sidebarLabel: "D",
                isGeneratedName: false,
                monitorScopeId: "display-main",
                monitorName: "Studio Display",
                isFocused: true,
                isVisible: true,
                items: [
                    .init(kind: .tabGroup(.init(
                        representativeWindowId: 101,
                        workspaceName: "code",
                        title: "5X.plasticity",
                        windowCount: 3,
                        isFocused: true,
                        tabs: [
                            sidebarWindow(101, workspace: "code", app: "Plasticity", bundle: "com.electron.plasticity", title: "5X.plasticity", focused: true),
                            sidebarWindow(102, workspace: "code", app: "Autodesk Fusion", bundle: "com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion", title: "Fusion"),
                            sidebarWindow(103, workspace: "code", app: "Finder", bundle: "com.apple.finder", title: "Finder"),
                        ]
                    ))),
                    .init(kind: .tabGroup(.init(
                        representativeWindowId: 104,
                        workspaceName: "code",
                        title: "alpaca engineering",
                        windowCount: 2,
                        isFocused: false,
                        tabs: [
                            sidebarWindow(104, workspace: "code", app: "Helium", bundle: "net.imput.helium", title: "alpaca engineering"),
                            sidebarWindow(105, workspace: "code", app: "Safari", bundle: "com.apple.Safari", title: "Safari"),
                        ]
                    ))),
                ]
            ),
            WorkspaceSidebarWorkspaceViewModel(
                name: "research",
                projectId: defaultProject,
                displayName: "Browser",
                sidebarLabel: "B",
                isGeneratedName: false,
                monitorScopeId: "display-main",
                monitorName: "Studio Display",
                isFocused: false,
                isVisible: false,
                items: [
                    .init(kind: .window(sidebarWindow(201, workspace: "research", app: "Safari", bundle: "com.apple.Safari", title: "Apple Developer"))),
                    .init(kind: .window(sidebarWindow(202, workspace: "research", app: "Notes", bundle: "com.apple.Notes", title: "Launch notes"))),
                ]
            ),
        ],
        projects: [
            WorkspaceSidebarProjectViewModel(id: defaultProject, displayName: "WinMux", colorHex: "#7C6CF2"),
            WorkspaceSidebarProjectViewModel(id: "personal", displayName: "Personal", colorHex: "#58A6FF"),
        ],
        activeProjectId: defaultProject,
        monitorScopes: [
            WorkspaceSidebarMonitorScopeViewModel(
                id: "default",
                displayName: "All Displays",
                subtitle: nil,
                systemImageName: "display.2",
                isFocusedMonitor: true
            ),
        ],
        selectedMonitorScopeId: "default",
        targetMonitorScopeId: "display-main",
        focusedMonitorScopeId: "display-main",
        visibleWidth: 280,
        hoveredWorkspaceName: nil,
        dropPreview: nil,
        configuration: WorkspaceSidebarConfiguration(
            collapsedWidth: 44,
            expandedWidth: 280,
            topPadding: 12,
            showMonitorSelector: true,
            showsClock: true,
            showsSeconds: false,
            showsDate: true,
            showsWeekday: true,
            showsStatusPills: true,
            chromeStyle: .liquidGlass,
            solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20"
        )
    )

    static let codeTabStrip = tabStrip(
        identity: codeIdentity,
        workspace: "code",
        activeWindowId: 101,
        tabs: [
            tab(101, workspace: "code", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "WorkspaceSidebarView.swift", active: true),
            tab(102, workspace: "code", app: "Terminal", bundle: "com.apple.Terminal", title: "winmux — swift run"),
        ]
    )

    static let browserTabStrip = tabStrip(
        identity: browserIdentity,
        workspace: "code",
        activeWindowId: 103,
        tabs: [
            tab(103, workspace: "code", app: "Safari", bundle: "com.apple.Safari", title: "macOS 27 — Apple", active: true),
            tab(104, workspace: "code", app: "Safari", bundle: "com.apple.Safari", title: "Apple Intelligence"),
        ]
    )

    static let appsTabStrip = tabStrip(
        identity: heliumIdentity,
        workspace: "work",
        activeWindowId: 301,
        tabs: [
            tab(301, workspace: "work", app: "Helium", bundle: "net.imput.helium", title: "alpaca engineering", active: true),
            tab(302, workspace: "work", app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "WinMux"),
            tab(303, workspace: "work", app: "Finder", bundle: "com.apple.finder", title: "winmux"),
        ]
    )

    static let safariCurrentTabStrip = tabStrip(
        identity: safariCurrentIdentity,
        workspace: "design",
        activeWindowId: 601,
        tabs: [
            tab(
                601,
                workspace: "design",
                app: "Helium",
                bundle: "net.imput.helium",
                path: "/Applications/Helium.app",
                title: "alpaca engineering",
                active: true
            ),
            tab(
                602,
                workspace: "design",
                app: "Safari",
                bundle: "com.apple.Safari",
                path: "/Applications/Safari.app",
                title: "Safari"
            ),
        ],
        cornerRadius: 14
    )

    static let plasticityTabStrip = tabStrip(
        identity: plasticityIdentity,
        workspace: "design",
        activeWindowId: 701,
        tabs: [
            tab(
                701,
                workspace: "design",
                app: "Plasticity",
                bundle: "com.electron.plasticity",
                path: "/Applications/Plasticity.app",
                title: "5X.plasticity",
                active: true
            ),
            tab(
                702,
                workspace: "design",
                app: "Autodesk Fusion",
                bundle: "com.autodesk.dls.streamer.scriptapp.Autodesk-Fusion",
                path: "/Users/xzm/Applications/Autodesk Fusion.app",
                title: "Fusion"
            ),
            tab(
                703,
                workspace: "design",
                app: "Finder",
                bundle: "com.apple.finder",
                path: "/System/Library/CoreServices/Finder.app",
                title: "Finder"
            ),
        ],
        cornerRadius: 14
    )

    private static func sidebarWindow(
        _ id: UInt32,
        workspace: String,
        app: String,
        bundle: String,
        title: String,
        focused: Bool = false
    ) -> WorkspaceSidebarWindowViewModel {
        WorkspaceSidebarWindowViewModel(
            windowId: id,
            workspaceName: workspace,
            appName: app,
            appBundleId: bundle,
            appBundlePath: nil,
            title: title,
            isFocused: focused
        )
    }

    private static func tab(
        _ id: UInt32,
        workspace: String,
        app: String,
        bundle: String,
        path: String? = nil,
        title: String,
        active: Bool = false
    ) -> WindowTabItemViewModel {
        WindowTabItemViewModel(
            windowId: id,
            workspaceName: workspace,
            appName: app,
            appBundleId: bundle,
            appBundlePath: path,
            title: title,
            isActive: active
        )
    }

    private static func tabStrip(
        identity: TabGroupIdentity,
        workspace: String,
        activeWindowId: UInt32,
        tabs: [WindowTabItemViewModel],
        cornerRadius: CGFloat = 16
    ) -> WindowTabStripViewModel {
        WindowTabStripViewModel(
            id: ObjectIdentifier(identity),
            workspaceName: workspace,
            frame: CGRect(x: 0, y: 0, width: 400, height: 40),
            groupFrame: CGRect(x: 0, y: 0, width: 400, height: 400),
            activeWindowId: activeWindowId,
            activeWindowCornerRadius: cornerRadius,
            tabs: tabs,
            occludingFloatingWindowFrames: []
        )
    }
}
