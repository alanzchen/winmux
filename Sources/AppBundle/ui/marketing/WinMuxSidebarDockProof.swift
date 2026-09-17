import AppKit
import SwiftUI

/// Shows a production sidebar in a fixed-size canvas for visual comparison. This entry
/// point never starts the window manager, reads the user's configuration, or sends actions.
@MainActor
public func showWinMuxSidebarDockProof(
    width: CGFloat,
    height: CGFloat,
    origin: CGPoint?,
    holdDuration: TimeInterval,
    captureURL: URL? = nil,
    backdropURL: URL? = nil,
    expandedWidth: CGFloat = 240,
    expansion: CGFloat = 0,
    iconSize: CGFloat = 48,
    magnification: Bool = false,
    magnificationAmount: Double = 0.5,
    pointerY: CGFloat? = nil,
    glassOpacity: Double = 1,
    darkAppearance: Bool = true,
    presentationMode: String = "dock"
) throws {
    guard width.isFinite, width > 0, expandedWidth.isFinite, expandedWidth > width,
          height.isFinite, height > 0, expansion.isFinite, (0...1).contains(expansion),
          holdDuration.isFinite, holdDuration >= 0, (24...48).contains(iconSize),
          (0...1).contains(glassOpacity), (0...1).contains(magnificationAmount),
          ["dock", "sidebar"].contains(presentationMode) else {
        throw SidebarDockProofError.invalidDimensions
    }
    let visibleWidth = width + (expandedWidth - width) * expansion
    let growth = iconSize * CGFloat(magnificationAmount)
    let overflow = presentationMode == "dock" && magnification && expansion == 0
        ? max(growth - (width - iconSize) / 2, 0) : 0
    let backdrop = try backdropURL.map { url in
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw SidebarDockProofError.invalidBackdrop(url.path)
        }
        return image
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    if !application.isRunning {
        application.finishLaunching()
    }

    let size = CGSize(width: visibleWidth + overflow, height: height)
    let content = ZStack(alignment: .topLeading) {
        if let backdrop {
            // The caller supplies a matching wallpaper crop. Stretch it to the requested
            // point dimensions so Retina PNG metadata cannot change the comparison scale.
            Image(nsImage: backdrop)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: height)
        }
        WorkspaceSidebarView(snapshot: sidebarDockProofSnapshot(
            compactWidth: width,
            expandedWidth: expandedWidth,
            visibleWidth: visibleWidth,
            iconSize: iconSize,
            magnification: magnification,
            magnificationAmount: magnificationAmount,
            glassOpacity: glassOpacity,
            dockMode: presentationMode == "dock"
        ), actions: .init())
            .frame(width: size.width, height: height)
    }
    .frame(width: size.width, height: height)
    .environment(\.workspaceSidebarDockPointer, pointerY.map { CGPoint(x: width / 2, y: $0) })
    .environment(\.colorScheme, darkAppearance ? .dark : .light)
    .allowsHitTesting(false)
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.title = "WinMux Sidebar Dock Proof"
    window.contentView = hostingView
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.level = .floating
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.sharingType = .readOnly
    if let origin {
        window.setFrameOrigin(origin)
    } else if let screenFrame = NSScreen.main?.visibleFrame {
        window.setFrameOrigin(CGPoint(
            x: screenFrame.midX - visibleWidth / 2,
            y: screenFrame.midY - height / 2
        ))
    }
    defer {
        window.orderOut(nil)
        window.close()
    }

    window.orderFrontRegardless()
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    let windowID = CGWindowID(window.windowNumber)
    let metadata: [String: Any] = [
        "windowID": windowID,
        "coordinateSystem": "AppKit screen points; origin at lower left",
        "x": window.frame.minX,
        "y": window.frame.minY,
        "width": window.frame.width,
        "canvasWidth": window.frame.width,
        "mode": presentationMode,
        "compactWidth": width,
        "expandedWidth": expandedWidth,
        "visibleWidth": visibleWidth,
        "expansion": expansion,
        "height": window.frame.height,
        "holdSeconds": holdDuration,
        "hasBackdrop": backdrop != nil,
        "iconSize": iconSize,
        "magnification": magnification,
        "magnificationAmount": magnificationAmount,
        "glassOpacity": glassOpacity,
        "darkAppearance": darkAppearance,
    ]
    var output = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    output.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: output)

    // WindowServer must compose the live glass before it can be captured. Keep the run loop
    // responsive before capturing this window or an externally authorized screenshot.
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    if let captureURL {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ), image.width > 0, image.height > 0 else {
            throw SidebarDockProofError.captureFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard sidebarDockProofHasVisiblePixels(bitmap) else {
            throw SidebarDockProofError.emptyCapture
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SidebarDockProofError.captureFailed
        }
        try FileManager.default.createDirectory(at: captureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: captureURL, options: .atomic)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(holdDuration))
}

@MainActor
private func sidebarDockProofSnapshot(
    compactWidth: CGFloat,
    expandedWidth: CGFloat,
    visibleWidth: CGFloat,
    iconSize: CGFloat,
    magnification: Bool,
    magnificationAmount: Double,
    glassOpacity: Double,
    dockMode: Bool
) -> WorkspaceSidebarSnapshot {
    let scope = "sidebar-dock-proof"
    let project = workspaceProjectDefaultId
    func workspace(_ number: String, apps: [WorkspaceSidebarAppViewModel], active: Bool) -> WorkspaceSidebarWorkspaceViewModel {
        WorkspaceSidebarWorkspaceViewModel(
            name: number,
            projectId: project,
            displayName: number,
            sidebarLabel: number,
            isGeneratedName: false,
            monitorScopeId: scope,
            monitorName: nil,
            isFocused: active,
            isVisible: active,
            items: apps.enumerated().map { index, app in
                .init(kind: .window(.init(
                    windowId: UInt32((Int(number) ?? 0) * 100 + index + 1),
                    workspaceName: number,
                    appName: app.name,
                    appBundleId: app.bundleId,
                    appBundlePath: app.bundlePath,
                    title: "\(app.name) window",
                    isFocused: active && index == 0
                )))
            },
            apps: apps
        )
    }
    var configuration = WorkspaceSidebarConfiguration.empty
    configuration.collapsedWidth = compactWidth
    configuration.configuredCollapsedWidth = compactWidth
    configuration.expandedWidth = expandedWidth
    configuration.showAppIcons = dockMode
    configuration.dockIconSize = iconSize
    configuration.dockMagnification = dockMode && magnification
    configuration.dockMagnificationAmount = magnificationAmount
    configuration.glassOpacity = glassOpacity
    configuration.chromeStyle = .liquidGlass
    return WorkspaceSidebarSnapshot(
        workspaces: [
            workspace("1", apps: [
                .init(name: "Safari", bundleId: "com.apple.Safari", bundlePath: nil),
            ], active: true),
            workspace("2", apps: [
                .init(name: "Terminal", bundleId: "com.apple.Terminal", bundlePath: nil),
                .init(name: "Notes", bundleId: "com.apple.Notes", bundlePath: nil),
            ], active: false),
        ],
        projects: [],
        activeProjectId: project,
        monitorScopes: [],
        selectedMonitorScopeId: workspaceSidebarDefaultScopeId,
        targetMonitorScopeId: scope,
        focusedMonitorScopeId: scope,
        visibleWidth: visibleWidth,
        hoveredWorkspaceName: nil,
        dropPreview: nil,
        configuration: configuration
    )
}

@MainActor
private func sidebarDockProofHasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
    guard bitmap.hasAlpha else { return true }
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 {
                return true
            }
        }
    }
    return false
}

private enum SidebarDockProofError: LocalizedError {
    case captureFailed
    case emptyCapture
    case invalidBackdrop(String)
    case invalidDimensions

    var errorDescription: String? {
        switch self {
            case .captureFailed:
                "Could not capture the live sidebar proof window."
            case .emptyCapture:
                "WindowServer returned a fully transparent proof capture. Wake the desktop and try again."
            case .invalidBackdrop(let path):
                "Could not load the sidebar proof backdrop at \(path)."
            case .invalidDimensions:
                "Proof dimensions must be positive and finite; expanded width must exceed compact width and expansion must be from 0 to 1."
        }
    }
}
