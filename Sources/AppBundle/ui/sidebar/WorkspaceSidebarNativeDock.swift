import AppKit
import Combine
import QuartzCore
import SwiftUI

struct WorkspaceSidebarNativeDockWorkspace {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let isActive: Bool
    let isEnabled: Bool
    let opacity: Double
    let select: () -> Void
    let selectApp: (WorkspaceSidebarAppViewModel) -> Void
    let rename: () -> Void
    var drop: (WorkspaceSidebarDragPayload) -> Void = { _ in }
}

private struct WorkspaceSidebarNativeDockArtworkKey: Equatable {
    struct Section: Equatable {
        let name: String
        let identifier: String
        let apps: [WorkspaceSidebarAppViewModel]
    }
    let sections: [Section]
    let size: CGFloat
    let backingScale: CGFloat
    let scale: CGFloat

    init(_ input: WorkspaceSidebarNativeDock, backingScale: CGFloat) {
        sections = input.workspaces.map {
            Section(name: $0.workspace.name, identifier: workspaceSidebarAppSummaryIdentifier($0.workspace),
                apps: $0.workspace.apps.map { app in
                    var artwork = app
                    // Full titles update accessibility/tooltips, not cached artwork.
                    artwork.contextTitle = nil
                    return artwork
                })
        }
        size = input.configuration.dockIconSize
        self.backingScale = backingScale
        scale = backingScale * (1 + input.configuration.dockMagnificationAmount)
    }
}

/// SwiftUI supplies snapshots and cold controls. The display link only changes
/// cached layer poses; it never publishes a pointer or a frame into SwiftUI.
struct WorkspaceSidebarNativeDock: NSViewRepresentable {
    let configuration: WorkspaceSidebarConfiguration
    let visibleWidth: CGFloat
    let compactLength: CGFloat
    let leadingLength: CGFloat
    let trailingLength: CGFloat
    let leading: AnyView
    let trailing: AnyView
    let workspaces: [WorkspaceSidebarNativeDockWorkspace]
    let projectId: WorkspaceProjectId
    let monitorScopeId: String
    let showsCreate: Bool
    let reduceTransparency: Bool
    let blockers: WorkspaceSidebarDockPointerBlockers
    let motion: WorkspaceSidebarDockMotionController
    let hitRegions: WorkspaceSidebarDockHitRegions
    let actions: WorkspaceSidebarActions
    var pointerOverride: CGPoint? = nil
    var dropPreview: WorkspaceSidebarDropPreviewViewModel? = nil
    var reduceMotion: Bool = false

    func makeNSView(context: Context) -> WorkspaceSidebarNativeDockView {
        let view = WorkspaceSidebarNativeDockView()
        view.configure(self)
        return view
    }

    func updateNSView(_ view: WorkspaceSidebarNativeDockView, context: Context) { view.configure(self) }

    static func dismantleNSView(_ view: WorkspaceSidebarNativeDockView, coordinator: ()) { view.detach() }
}

@MainActor
final class WorkspaceSidebarNativeDockView: NSView {
    private var input: WorkspaceSidebarNativeDock?
    private let driver = WorkspaceSidebarDockDisplayLinkView()
    private let leading = NSHostingView(rootView: AnyView(EmptyView()))
    private let trailing = NSHostingView(rootView: AnyView(EmptyView()))
    private var backdrop: NSView?
    private var backdropStyle: String?
    private let contents = CALayer()
    private let indicatorLayer = CALayer()
    private let createLayer = CALayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let previewClip = WorkspaceSidebarNativeDockClipView()
    private let createPreview = NSHostingView(rootView: AnyView(EmptyView()))
    private var showsCreatePreview = false
    private var tiles: [[CALayer]] = []
    private var badgeLayers: [[CALayer]] = []
    private var badgeLabels: [String: String] = [:]
    private var separators: [CALayer] = []
    private var imageModels: [AppIconModel] = []
    private var subscriptions: [AnyCancellable] = []
    private var artworkKey: WorkspaceSidebarNativeDockArtworkKey?
    private var accessibilityButtons: [WorkspaceSidebarNativeDockButton] = []
    private(set) var geometry: WorkspaceSidebarNativeDockGeometry?
    private var scrollOffset: CGFloat = 0
    private var pressed: (workspace: String, app: WorkspaceSidebarAppViewModel?, point: CGPoint, iconSize: CGFloat)?
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    private var pressedCreate = false
    private var dragging = false
    private var drag = WorkspaceSidebarAppDragSession()
    private var tooltipsEnabled = false
    private(set) var tooltipFrames: [CGRect] = []
    private(set) var tooltipTags: [NSView.ToolTipTag] = []
    private var tooltipUpdateTask: Task<Void, Never>?
    private var tooltipUpdateDeadline: CFTimeInterval = 0
    private var incomingDrop: (WorkspaceSidebarDragPayload, WorkspaceSidebarDropTargetKind)?
    private var pendingTransitions: [String: CGRect]?
    private var transitionDeadline: CFTimeInterval = 0
    private var transitionExtent: CGRect?
    private var surfaceHitPath: CGPath?
    private var scrollRecovery: DispatchWorkItem?
    private var isScrolling = false
    private var inputRevision: UInt64 = 0
    private var renderedRevision: UInt64?
    private var renderedFrame: WorkspaceSidebarDockMotionFrame?
    private var renderedBounds = CGRect.null
    private var renderedScrollOffset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = false
        rim.colors = [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0.12).cgColor]
        rim.startPoint = CGPoint(x: 0, y: 0)
        rim.endPoint = CGPoint(x: 1, y: 1)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1
        rim.mask = rimMask
        layer?.addSublayer(rim)
        contents.masksToBounds = true
        layer?.addSublayer(contents)
        contents.addSublayer(indicatorLayer)
        contents.addSublayer(createLayer)
        leading.sizingOptions = []
        trailing.sizingOptions = []
        createPreview.sizingOptions = []
        if #available(macOS 13.3, *) {
            leading.safeAreaRegions = []
            trailing.safeAreaRegions = []
            createPreview.safeAreaRegions = []
        }
        previewClip.wantsLayer = true
        previewClip.layer?.masksToBounds = true
        previewClip.addSubview(createPreview)
        previewClip.isHidden = true
        addSubview(previewClip)
        addSubview(leading)
        addSubview(trailing)
        addSubview(driver)
        driver.onFrame = { [weak self] in self?.render($0) }
        registerForDraggedTypes([.init(workspaceSidebarDragPayloadType.identifier)])
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dock")
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { releaseArtwork() }

    func configure(_ input: WorkspaceSidebarNativeDock) {
        tooltipsEnabled = true
        let previous = self.input
        self.input = input
        inputRevision &+= 1
        if previous?.configuration.compactRailWidth != input.configuration.compactRailWidth { surfaceHitPath = nil }
        input.motion.attach(to: driver)
        configurePointer(input)
        leading.rootView = input.leading
        trailing.rootView = input.trailing
        showsCreatePreview = input.showsCreate && input.dropPreview?.targetsNewWorkspace == true
            && (input.dropPreview?.targetProjectId == nil || input.dropPreview?.targetProjectId == input.projectId)
            && (input.dropPreview?.targetMonitorScopeId == nil || input.dropPreview?.targetMonitorScopeId == input.monitorScopeId)
        if showsCreatePreview, let preview = input.dropPreview {
            createPreview.rootView = AnyView(WorkspaceSidebarDropPreviewView(preview: preview,
                rowHeight: workspaceSidebarWorkspaceRowHeight, style: .appIcon(size: input.configuration.dockIconSize)))
        } else { createPreview.rootView = AnyView(EmptyView()) }
        previewClip.isHidden = !showsCreatePreview
        if previous?.projectId != input.projectId || previous?.configuration.dockPosition != input.configuration.dockPosition {
            scrollOffset = 0
        }
        configureBackdrop(input)
        let key = WorkspaceSidebarNativeDockArtworkKey(input, backingScale: window?.backingScaleFactor ?? 2)
        if artworkKey != key {
            if let previous, let geometry, !input.reduceMotion {
                var frames: [String: CGRect] = [:]
                for (entry, poses) in zip(previous.workspaces, geometry.icons) {
                    let ids = ["workspace"] + entry.workspace.apps.map(\.id)
                    for (id, pose) in zip(ids, poses) {
                        frames[entry.workspace.name + "/" + id] = pose
                    }
                }
                pendingTransitions = frames
                transitionExtent = frames.values.reduce(CGRect.null) { $0.union($1) }
            }
            artworkKey = key
            rebuildArtwork(input)
            // AX and pointer callbacks can arrive before AppKit's next layout.
            // Never index old poses using the newly installed snapshot.
            geometry = nil
        } else {
            // Focus changes affect opacity and the workspace tile, not cached app
            // images or their subscriptions. Preserve the existing layer identities.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Equal structural keys guarantee matching rows and a title at index zero.
            for (index, entry) in input.workspaces.enumerated() {
                for tile in tiles[index] where tile.opacity != Float(entry.opacity) { tile.opacity = Float(entry.opacity) }
                if previous?.workspaces[index].isActive != entry.isActive {
                    tiles[index][0].contents = workspaceArtwork(entry, size: key.size, scale: key.scale)
                }
            }
            CATransaction.commit()
        }
        rebuildAccessibilityIfNeeded(input)
        // Install matching geometry before returning the new snapshot to AppKit.
        // A queued pointer/AX callback must never see new identities with old poses.
        render(input.blockers.isEmpty ? driver.motion.frame : .init())
        driver.schedulePointerRecheck()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let resized = driver.frame != bounds
        if resized { driver.frame = bounds }
        render(input?.blockers.isEmpty == true ? driver.motion.frame : .init())
        if resized { driver.schedulePointerRecheck() }
    }

    private func configurePointer(_ input: WorkspaceSidebarNativeDock) {
        driver.configurePointer(blockers: input.blockers.union(isScrolling ? .scroll : []),
            horizontal: input.configuration.dockPosition == .bottom,
            contains: { [weak self] in self?.contains($0) == true })
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A backing change can reach a retained outgoing view. Only a new
        // representable snapshot may let it reclaim the controller from its successor.
        if let input, input.motion.owns(driver) { configure(input) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        scheduleIconTooltips()
    }

    private func updateIconTooltips() {
        tooltipUpdateTask?.cancel()
        tooltipUpdateTask = nil
        var frames: [CGRect] = []
        if tooltipsEnabled, let input, let geometry, input.motion.owns(driver) {
            for row in geometry.icons {
                for (index, frame) in row.enumerated() where index == 0
                    ? input.configuration.showWorkspaceTooltips : input.configuration.showAppTooltips {
                    let visible = frame.intersection(contents.frame).intersection(bounds)
                    if !visible.isNull && !visible.isEmpty { frames.append(visible) }
                }
            }
        }
        guard frames != tooltipFrames else { return }
        for tag in tooltipTags { removeToolTip(tag) }
        tooltipFrames = frames
        tooltipTags = frames.map { addToolTip($0, owner: self, userData: nil) }
    }

    private func scheduleIconTooltips() {
        guard tooltipsEnabled, let input, input.motion.owns(driver),
              input.configuration.showWorkspaceTooltips || input.configuration.showAppTooltips else {
            updateIconTooltips()
            return
        }
        // A single trailing update follows lens motion. Re-registering every display
        // frame would restart AppKit's hover timer and churn native tracking regions.
        tooltipUpdateDeadline = CACurrentMediaTime() + 0.12
        guard tooltipUpdateTask == nil else { return }
        tooltipUpdateTask = Task { @MainActor [weak self] in
            while let self {
                let delay = self.tooltipUpdateDeadline - CACurrentMediaTime()
                if delay <= 0 {
                    self.tooltipUpdateTask = nil
                    self.updateIconTooltips()
                    return
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard tooltipsEnabled, let input, let geometry, input.motion.owns(driver), !dragging, incomingDrop == nil, !isScrolling else { return "" }
        // Hover labels remain available for workspaces in use on another display.
        // Only icons have labels; section padding must not masquerade as an icon.
        for (section, frames) in geometry.icons.enumerated() {
            for index in frames.indices where displayedIconFrame(section: section, icon: index)
                .intersection(contents.frame).contains(point) {
                let workspace = input.workspaces[section].workspace
                if index == 0 { return input.configuration.showWorkspaceTooltips ? workspace.displayName : "" }
                return input.configuration.showAppTooltips ? workspaceSidebarAppTooltip(workspace.apps[index - 1]) : ""
            }
        }
        return ""
    }

    private func configureBackdrop(_ input: WorkspaceSidebarNativeDock) {
        let config = input.configuration
        let style = "\(config.chromeStyle)-\(config.solidChromeColor)-\(config.solidChromeCustomColor)-\(input.reduceTransparency)"
        if style != backdropStyle {
            backdrop?.removeFromSuperview()
            let view: NSView
            if config.chromeStyle == .solid || input.reduceTransparency {
                view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = config.chromeStyle == .solid
                    ? NSColor(config.resolvedSolidChromeColor).cgColor : NSColor(white: 0.18, alpha: 1).cgColor
            } else if #available(macOS 26, *) {
                let glass = NSGlassEffectView()
                glass.style = .clear
                view = glass
            } else {
                let material = NSVisualEffectView()
                material.material = .hudWindow
                material.blendingMode = .behindWindow
                material.state = .active
                view = material
            }
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            // Keep the native material below both cached artwork and cold controls.
            addSubview(view, positioned: .below, relativeTo: leading)
            view.layer?.zPosition = -1
            backdrop = view
            backdropStyle = style
        }
        backdrop?.alphaValue = config.effectiveGlassOpacity
        rim.isHidden = config.chromeStyle == .solid || input.reduceTransparency
        rim.opacity = Float(config.effectiveGlassOpacity)
        let radius = config.compactRailWidth / 3
        backdrop?.layer?.cornerRadius = radius
        if #available(macOS 26, *), let glass = backdrop as? NSGlassEffectView { glass.cornerRadius = radius }
    }

    private func rebuildArtwork(_ input: WorkspaceSidebarNativeDock) {
        releaseArtwork()
        for tile in tiles.flatMap({ $0 }) { tile.removeFromSuperlayer() }
        for separator in separators { separator.removeFromSuperlayer() }
        tiles = []
        badgeLayers = []
        badgeLabels = [:]
        separators = []
        let size = input.configuration.dockIconSize
        let scale = (window?.backingScaleFactor ?? 2) * (1 + input.configuration.dockMagnificationAmount)
        let fallback = ImageRenderer(content: WorkspaceSidebarWorkspaceIconBackground(isActive: false)
            .overlay { Image(systemName: "app.dashed").font(.system(size: size * 0.5)).foregroundStyle(Color.white.opacity(0.85)) }
            .frame(width: size, height: size))
        fallback.scale = scale
        let fallbackImage = fallback.cgImage
        for entry in input.workspaces {
            let workspace = entry.workspace
            var row: [CALayer] = []
            var badges: [CALayer] = []
            let title = makeTile(size: size, opacity: entry.opacity)
            title.contents = workspaceArtwork(entry, size: size, scale: scale)
            row.append(title)
            for app in workspace.apps {
                let tile = makeTile(size: size, opacity: entry.opacity)
                tile.contents = fallbackImage
                if let request = AppIconRequest(bundleIdentifier: app.bundleId, bundlePath: app.bundlePath) {
                    let model = AppIconProvider.shared.model(for: request)
                    AppIconProvider.shared.retain(model)
                    imageModels.append(model)
                    subscriptions.append(model.$image.sink { [weak tile] image in
                        guard let tile else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        tile.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? fallbackImage
                        CATransaction.commit()
                    })
                }
                if let label = app.identityLabel {
                    let identity = CALayer()
                    identity.frame = CGRect(x: 0, y: 0, width: size, height: size)
                    let renderer = ImageRenderer(content: WorkspaceSidebarIdentityLabel(label: label, size: size))
                    renderer.scale = scale
                    identity.contentsScale = scale
                    identity.contents = renderer.cgImage
                    tile.addSublayer(identity)
                }
                let badge = CALayer()
                badge.frame = CGRect(x: 0, y: 0, width: size, height: size)
                tile.addSublayer(badge)
                badges.append(badge)
                row.append(tile)
            }
            tiles.append(row)
            badgeLayers.append(badges)
            let separator = CALayer()
            separator.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            contents.addSublayer(separator)
            separators.append(separator)
        }
        indicatorLayer.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        let plus = ImageRenderer(content: Image(systemName: "plus")
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white.opacity(0.45))
            .frame(width: 32, height: 32))
        plus.scale = window?.backingScaleFactor ?? 2
        createLayer.contents = plus.cgImage
        createLayer.contentsGravity = .resizeAspect
        subscriptions.append(WorkspaceSidebarDockBadgeModel.shared.$snapshot.sink { [weak self] in
            self?.updateBadges($0)
        })
    }

    private func workspaceArtwork(_ entry: WorkspaceSidebarNativeDockWorkspace, size: CGFloat, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: WorkspaceSidebarWorkspaceIcon(
            identifier: workspaceSidebarAppSummaryIdentifier(entry.workspace), isActive: entry.isActive,
            size: size, showsIndicator: false))
        renderer.scale = scale
        return renderer.cgImage
    }

    private func updateBadges(_ snapshot: WorkspaceSidebarDockBadgeSnapshot) {
        guard let input else { return }
        let size = input.configuration.dockIconSize
        let diameter = max(12, size * 0.38)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (section, entry) in input.workspaces.enumerated() {
            for (index, app) in entry.workspace.apps.enumerated() {
                let key = entry.workspace.name + "/" + app.id
                let label = snapshot.label(forPath: app.bundlePath)
                guard badgeLabels[key] != label else { continue }
                badgeLabels[key] = label
                let layer = badgeLayers[section][index]
                guard let label else { layer.contents = nil; continue }
                let renderer = ImageRenderer(content: Text(label.count > 4 ? String(label.prefix(3)) + "…" : label)
                    .font(.system(size: diameter * 0.65, weight: .semibold))
                    .foregroundStyle(.white).padding(.horizontal, diameter * 0.22)
                    .frame(minWidth: diameter, minHeight: diameter)
                    .background(Color(red: 0.96, green: 0.20, blue: 0.23), in: Capsule())
                    .frame(width: size, height: size, alignment: .topTrailing))
                renderer.scale = (window?.backingScaleFactor ?? 2) * (1 + input.configuration.dockMagnificationAmount)
                layer.contents = renderer.cgImage
            }
        }
        CATransaction.commit()
    }

    private func makeTile(size: CGFloat, opacity: Double) -> CALayer {
        let tile = CALayer()
        tile.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        tile.contentsGravity = .resizeAspect
        tile.opacity = Float(opacity)
        contents.addSublayer(tile)
        return tile
    }

    private func releaseArtwork() {
        subscriptions.removeAll()
        for model in imageModels { AppIconProvider.shared.release(model) }
        imageModels = []
    }

    func detach() {
        tooltipsEnabled = false
        tooltipUpdateTask?.cancel()
        tooltipUpdateTask = nil
        for tag in tooltipTags { removeToolTip(tag) }
        tooltipTags = []
        tooltipFrames = []
        scrollRecovery?.cancel()
        scrollRecovery = nil
        isScrolling = false
        driver.onFrame = nil
        driver.detachPointer()
        releaseArtwork()
        artworkKey = nil
        if dragging { endWorkspaceSidebarItemDrag() }
        dragging = false
        pressed = nil
        pressedCreate = false
        drag = .init()
    }

    private func rebuildAccessibilityIfNeeded(_ input: WorkspaceSidebarNativeDock) {
        var labels: [(String?, String?, String)] = []
        for entry in input.workspaces {
            labels.append((entry.workspace.name, nil, "Switch to workspace \(entry.workspace.displayName)"))
            labels += entry.workspace.apps.map {
                (entry.workspace.name, $0.id, "Focus \(workspaceSidebarAppContextDescription($0, workspaceDisplayName: entry.workspace.displayName))")
            }
        }
        if input.showsCreate { labels.append((nil, nil, "Create workspace")) }
        guard labels.count != accessibilityButtons.count || zip(labels, accessibilityButtons).contains(where: {
            $0.0.0 != $0.1.workspaceName || $0.0.1 != $0.1.appId || $0.0.2 != $0.1.accessibilityLabel()
        }) else { return }
        accessibilityButtons = labels.map {
            WorkspaceSidebarNativeDockButton(owner: self, workspaceName: $0.0, appId: $0.1, label: $0.2)
        }
        setAccessibilityChildren([leading] + accessibilityButtons + [trailing])
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func buttonFrame(workspaceName: String?, appId: String?) -> CGRect? {
        guard let input, let geometry else { return nil }
        func visible(_ frame: CGRect?) -> CGRect? {
            guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
            return frame
        }
        guard let workspaceName else { return visible(geometry.create?.intersection(geometry.page)) }
        guard let index = input.workspaces.firstIndex(where: { $0.workspace.name == workspaceName }) else { return nil }
        let icon: Int
        if let appId {
            guard let app = input.workspaces[index].workspace.apps.firstIndex(where: { $0.id == appId }) else { return nil }
            icon = app + 1
        } else { icon = 0 }
        return visible(displayedIconFrame(section: index, icon: icon).intersection(contents.frame))
    }

    func buttonIsEnabled(workspaceName: String?) -> Bool {
        guard let input else { return false }
        guard let workspaceName else { return input.showsCreate }
        return input.workspaces.first(where: { $0.workspace.name == workspaceName })?.isEnabled == true
    }

    @discardableResult
    func pressButton(workspaceName: String?, appId: String?) -> Bool {
        guard let input, buttonIsEnabled(workspaceName: workspaceName), !isWorkspaceSidebarDragInProgress() else { return false }
        guard let workspaceName else {
            input.actions.send(.createWorkspace(projectId: input.projectId, monitorScopeId: input.monitorScopeId))
            return true
        }
        guard let entry = input.workspaces.first(where: { $0.workspace.name == workspaceName }) else { return false }
        if let appId {
            guard let app = entry.workspace.apps.first(where: { $0.id == appId }) else { return false }
            entry.selectApp(app)
        } else { entry.select() }
        return true
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit's legacy AX entry point lacks actor annotations. Its UI callbacks
        // run on main; enforce that before touching the view or returning an element.
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated {
            result = accessibilityButtons.first(where: { $0.accessibilityFrame().contains(point) })
        }
        return result ?? super.accessibilityHitTest(point)
    }

    func render(_ frame: WorkspaceSidebarDockMotionFrame) {
        guard let input else { return }
        let config = input.configuration
        let horizontal = config.dockPosition == .bottom
        let createLength = showsCreatePreview ? max(32, config.dockIconSize) : 32
        let compactLength = input.compactLength + createLength - 32
        let effectiveFrame: WorkspaceSidebarDockMotionFrame
        if isScrolling { effectiveFrame = .init() }
        else if let pointer = input.pointerOverride, input.blockers.isEmpty {
            let resting = workspaceSidebarSurfaceFrame(availableSize: bounds.size, visibleWidth: input.visibleWidth,
                compactHeight: compactLength, expansionProgress: 0, fitsDockContent: true,
                compactLeftGap: config.compactLeftGap, position: config.dockPosition)
            let radius = config.compactRailWidth / 3
            let insideRestingSurface = CGPath(roundedRect: resting, cornerWidth: radius,
                cornerHeight: radius, transform: nil).contains(pointer)
            effectiveFrame = (insideRestingSurface || contains(pointer))
                ? .init(pointer: pointer, strength: 1) : .init()
        } else { effectiveFrame = input.blockers.isEmpty ? frame : .init() }
        // AppKit can ask for layout after a layer transaction even when the input
        // and bounds did not change. Do not encode the same scene a second time.
        guard renderedRevision != inputRevision || renderedFrame != effectiveFrame
            || renderedBounds != bounds || renderedScrollOffset != scrollOffset else { return }
        let next = WorkspaceSidebarNativeDockGeometry(size: bounds.size, configuration: config,
            visibleWidth: input.visibleWidth, compactLength: compactLength,
            leadingLength: input.leadingLength, trailingLength: input.trailingLength,
            appCounts: input.workspaces.map { $0.workspace.apps.count }, showsCreate: input.showsCreate,
            frame: effectiveFrame, scrollOffset: scrollOffset,
            createLength: createLength)
        if scrollOffset > next.maximumScroll {
            scrollOffset = next.maximumScroll
            render(frame)
            return
        }
        let refreshTooltipsImmediately = renderedRevision != inputRevision || renderedBounds != bounds
        renderedRevision = inputRevision
        renderedFrame = effectiveFrame
        renderedBounds = bounds
        renderedScrollOffset = scrollOffset
        let previousSurface = geometry?.surface
        geometry = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if previousSurface != next.surface { surfaceHitPath = nil }
        if backdrop?.frame != next.surface { backdrop?.frame = next.surface }
        if rim.frame != next.surface {
            rim.frame = next.surface
            rimMask.frame = rim.bounds
            let radius = config.compactRailWidth / 3
            rimMask.path = CGPath(roundedRect: rim.bounds.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        place(leading, in: next.leading)
        place(trailing, in: next.trailing)
        // Reserve the complete lens envelope, without making Core Animation mask
        // the full expanded-panel canvas. The cross-axis extent stays fixed while the lens moves.
        let overflow = config.dockMagnificationOverflow
        var envelope: CGRect = switch config.dockPosition {
            case .left: CGRect(x: next.surface.minX, y: next.page.minY,
                width: next.surface.width + overflow, height: next.page.height)
            case .right: CGRect(x: next.surface.minX - overflow, y: next.page.minY,
                width: next.surface.width + overflow, height: next.page.height)
            case .bottom: CGRect(x: next.page.minX, y: next.surface.minY - overflow,
                width: next.page.width, height: next.surface.height + overflow)
        }
        if let extent = transitionExtent {
            if pendingTransitions != nil || CACurrentMediaTime() < transitionDeadline {
                // A size change can be animating down from larger artwork.
                envelope = envelope.union(extent)
            } else { transitionExtent = nil }
        }
        let clip = horizontal
            ? CGRect(x: next.page.minX, y: envelope.minY, width: next.page.width, height: envelope.height)
            : CGRect(x: envelope.minX, y: next.page.minY, width: envelope.width, height: next.page.height)
        if contents.frame != clip { contents.frame = clip }
        if contents.bounds != clip { contents.bounds = clip }
        for (section, poses) in next.icons.enumerated() {
            for (index, pose) in poses.enumerated() {
                let tile = tiles[section][index]
                let center = CGPoint(x: pose.midX, y: pose.midY)
                let transform = CGAffineTransform(scaleX: pose.width / config.dockIconSize,
                    y: pose.height / config.dockIconSize)
                if tile.position != center { tile.position = center }
                if tile.affineTransform() != transform { tile.setAffineTransform(transform) }
            }
            let sectionFrame = next.sections[section]
            if separators[section].isHidden != (section == 0) { separators[section].isHidden = section == 0 }
            let separatorFrame = horizontal
                ? CGRect(x: sectionFrame.minX - 3, y: sectionFrame.minY + 10, width: 0.5, height: max(0, sectionFrame.height - 20))
                : CGRect(x: sectionFrame.minX + 10, y: sectionFrame.minY - 3, width: max(0, sectionFrame.width - 20), height: 0.5)
            if separators[section].frame != separatorFrame { separators[section].frame = separatorFrame }
        }
        let activeIndex = input.workspaces.firstIndex(where: \.isActive)
        if indicatorLayer.isHidden != (activeIndex == nil) { indicatorLayer.isHidden = activeIndex == nil }
        if let index = activeIndex, let pose = next.icons[index].first {
            let diameter = workspaceSidebarIndicatorDiameter(railWidth: config.compactRailWidth)
            let outward = -workspaceSidebarIndicatorLeadingOffset(tileSize: config.dockIconSize, railWidth: config.compactRailWidth)
            let point: CGPoint = switch config.dockPosition {
                case .left: CGPoint(x: pose.minX - outward, y: pose.midY - diameter / 2)
                case .right: CGPoint(x: pose.maxX + outward - diameter, y: pose.midY - diameter / 2)
                case .bottom: CGPoint(x: pose.midX - diameter / 2, y: pose.maxY + outward - diameter)
            }
            let indicatorFrame = CGRect(origin: point, size: CGSize(width: diameter, height: diameter))
            if indicatorLayer.frame != indicatorFrame { indicatorLayer.frame = indicatorFrame }
            if indicatorLayer.cornerRadius != diameter / 2 { indicatorLayer.cornerRadius = diameter / 2 }
        }
        let hideCreate = next.create == nil || showsCreatePreview
        if createLayer.isHidden != hideCreate { createLayer.isHidden = hideCreate }
        if let create = next.create, createLayer.frame != create { createLayer.frame = create }
        if showsCreatePreview, let create = next.create {
            place(previewClip, in: clip)
            place(createPreview, in: create.offsetBy(dx: -clip.minX, dy: -clip.minY))
        }
        if let previous = pendingTransitions {
            transitionDeadline = CACurrentMediaTime() + 0.22
            for (section, entry) in input.workspaces.enumerated() {
                for (index, id) in (["workspace"] + entry.workspace.apps.map(\.id)).enumerated() {
                    let tile = tiles[section][index]
                    let pose = next.icons[section][index]
                    if let old = previous[entry.workspace.name + "/" + id], old != pose {
                        let position = CABasicAnimation(keyPath: "position")
                        position.fromValue = NSValue(point: CGPoint(x: old.midX, y: old.midY))
                        position.duration = 0.22
                        position.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        tile.add(position, forKey: "snapshotPosition")
                        let scale = CABasicAnimation(keyPath: "transform.scale")
                        scale.fromValue = old.width / config.dockIconSize
                        scale.duration = 0.22
                        scale.timingFunction = position.timingFunction
                        tile.add(scale, forKey: "snapshotScale")
                    } else if previous[entry.workspace.name + "/" + id] == nil {
                        let opacity = CABasicAnimation(keyPath: "opacity")
                        opacity.fromValue = 0
                        opacity.duration = 0.16
                        tile.add(opacity, forKey: "snapshotArrival")
                    }
                }
            }
            pendingTransitions = nil
        }
        if refreshTooltipsImmediately { updateIconTooltips() }
        else { scheduleIconTooltips() }
        // A retained outgoing compact view may still receive layout callbacks.
        // Its geometry must never replace the expanded renderer's hit regions.
        // Reclaiming through configure increments inputRevision and republishes.
        guard input.motion.owns(driver) else { return }
        var iconFrames: [CGRect] = []
        iconFrames.reserveCapacity(next.icons.reduce(0) { $0 + $1.count })
        for row in next.icons {
            for pose in row {
                let visible = pose.intersection(clip)
                if !visible.isNull && !visible.isEmpty { iconFrames.append(visible) }
            }
        }
        input.hitRegions.surface = next.surface
        input.hitRegions.icons = iconFrames
        input.actions.setSurfaceFrame(next.surface)
        input.actions.setDockIconFrames(input.blockers.isEmpty ? iconFrames : [])
        var targets = zip(input.workspaces, next.sections).map {
            WorkspaceSidebarDropTargetFrame(kind: .workspace($0.0.workspace.name), frame: $0.1)
        }
        if let create = next.create {
            targets.append(.init(kind: .newWorkspace(projectId: input.projectId, monitorScopeId: input.monitorScopeId), frame: create))
        }
        input.actions.setDropTargets(workspaceSidebarClippedDropTargets(targets, to: next.page))
        driver.performanceTrace?.geometry(surfaceY: next.surface.minY, icons: iconFrames.count)
    }

    private func place(_ view: NSView, in frame: CGRect) {
        if view.frame.size != frame.size { view.setFrameSize(frame.size) }
        if view.frame.origin != frame.origin { view.setFrameOrigin(frame.origin) }
    }

    private func contains(_ point: CGPoint) -> Bool {
        guard let geometry, let input else { return false }
        let rect = geometry.surface
        // Most input is in the rectangular middle. Defer the exact CGPath test
        // and its allocation to curved corners/boundaries, preserving their shape.
        if point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY {
            let radius = input.configuration.compactRailWidth / 3
            let rx = min(radius, rect.width / 2)
            let ry = min(radius, rect.height / 2)
            if point.x > rect.minX, point.x < rect.maxX, point.y > rect.minY, point.y < rect.maxY,
               ((point.x >= rect.minX + rx && point.x <= rect.maxX - rx)
                || (point.y >= rect.minY + ry && point.y <= rect.maxY - ry)) { return true }
            if surfaceHitPath == nil {
                surfaceHitPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            if surfaceHitPath?.contains(point) == true { return true }
        }
        return input.hitRegions.icons.contains { $0.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard input?.motion.owns(driver) == true else { return nil }
        let local = convert(point, from: superview)
        guard contains(local) else { return nil }
        if leading.frame.contains(local), let hit = leading.hitTest(local) { return hit }
        if trailing.frame.contains(local), let hit = trailing.hitTest(local) { return hit }
        return self
    }

    private func target(at point: CGPoint) -> (workspace: Int, app: Int?)? {
        guard let input, let geometry else { return nil }
        for (workspace, frames) in geometry.icons.enumerated() where input.workspaces[workspace].isEnabled {
            for index in frames.indices where displayedIconFrame(section: workspace, icon: index).intersection(contents.frame).contains(point) {
                return (workspace, index == 0 ? nil : index - 1)
            }
        }
        if let workspace = geometry.sections.firstIndex(where: { $0.intersection(geometry.page).contains(point) }),
           input.workspaces[workspace].isEnabled { return (workspace, nil) }
        return nil
    }

    private func displayedIconFrame(section: Int, icon: Int) -> CGRect {
        if CACurrentMediaTime() < transitionDeadline, let frame = tiles[section][icon].presentation()?.frame { return frame }
        return geometry?.icons[section][icon] ?? .zero
    }

    override func mouseDown(with event: NSEvent) {
        pressed = nil
        pressedCreate = false
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { presentContextMenu(menu, event, self) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let target = target(at: point), let geometry {
            guard let entry = input?.workspaces[target.workspace] else { return }
            pressed = (entry.workspace.name, target.app.map { entry.workspace.apps[$0] }, point,
                geometry.icons[target.workspace][(target.app ?? -1) + 1].width)
        } else if buttonFrame(workspaceName: nil, appId: nil)?.contains(point) == true {
            pressedCreate = true
        }
    }

    // The display-link input bridge already consumes movement. Do not forward it
    // up the responder chain into the enclosing SwiftUI hosting view as well.
    override func mouseMoved(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let app = pressed.app, let input else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) >= 4 else { return }
            dragging = true
            beginWorkspaceSidebarItemDrag()
            driver.reset()
        }
        noteCurrentMousePointerSample()
        drag.update(workspaceName: pressed.workspace, appId: app.id,
            pointer: MousePointerTracker.shared.currentSample.point, iconSize: pressed.iconSize, actions: input.actions)
    }

    override func mouseUp(with event: NSEvent) {
        guard let input else { return }
        defer { pressed = nil; dragging = false; pressedCreate = false }
        if dragging {
            noteCurrentMousePointerSample()
            drag.finish(pointer: MousePointerTracker.shared.currentSample.point, actions: input.actions)
            endWorkspaceSidebarItemDrag()
        } else if pressedCreate, buttonFrame(workspaceName: nil, appId: nil)?.contains(convert(event.locationInWindow, from: nil)) == true {
            pressButton(workspaceName: nil, appId: nil)
        } else if let pressed, let hit = target(at: convert(event.locationInWindow, from: nil)) {
            let entry = input.workspaces[hit.workspace]
            let app = hit.app.map { entry.workspace.apps[$0] }
            guard pressed.workspace == entry.workspace.name, pressed.app?.id == app?.id else { return }
            pressButton(workspaceName: pressed.workspace, appId: app?.id)
        }
    }

    func showAppMenu(workspaceName: String, appId: String?) -> Bool {
        guard let frame = buttonFrame(workspaceName: workspaceName, appId: appId),
              let menu = contextMenu(workspaceName: workspaceName, appId: appId) else { return false }
        driver.reset()
        pressed = nil
        // AX callers must not wait for the menu tracking loop to finish.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            menu.popUp(positioning: nil, at: CGPoint(x: frame.midX, y: frame.maxY), in: self)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let input, let geometry else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let hit = target(at: point)
        // In-use workspace tiles still expose their existing management menu.
        guard let index = hit?.workspace ?? geometry.sections.firstIndex(where: {
            $0.intersection(geometry.page).contains(point)
        }) else { return nil }
        let entry = input.workspaces[index]
        driver.reset()
        pressed = nil
        return contextMenu(workspaceName: entry.workspace.name, appId: hit?.app.map { entry.workspace.apps[$0].id })
    }

    private func contextMenu(workspaceName: String, appId: String?) -> NSMenu? {
        guard let input, let entry = input.workspaces.first(where: { $0.workspace.name == workspaceName }) else { return nil }
        if let appId, entry.isEnabled, let app = entry.workspace.apps.first(where: { $0.id == appId }) {
            return workspaceSidebarNativeAppMenu(workspaceSidebarAppMenu(workspaceName: workspaceName, app: app))
        }
        let menu = NSMenu()
        menu.addItem(WorkspaceSidebarNativeDockMenuItem("Customize Dock & Sidebar…") {
            ShortcutSettingsModel.shared.requestDockSettings()
        })
        menu.addItem(.separator())
        menu.addItem(WorkspaceSidebarNativeDockMenuItem("Rename Workspace", perform: entry.rename))
        menu.addItem(.separator())
        menu.addItem(WorkspaceSidebarNativeDockMenuItem("Delete Workspace") {
            input.actions.send(.deleteWorkspace(entry.workspace.name))
        })
        return menu
    }

    func dropTarget(at point: CGPoint) -> WorkspaceSidebarDropTargetKind? {
        guard let input, let geometry else { return nil }
        if let index = geometry.sections.firstIndex(where: { $0.intersection(geometry.page).contains(point) }) {
            return .workspace(input.workspaces[index].workspace.name)
        }
        if geometry.create?.intersection(geometry.page).contains(point) == true {
            return .newWorkspace(projectId: input.projectId, monitorScopeId: input.monitorScopeId)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let type = NSPasteboard.PasteboardType(workspaceSidebarDragPayloadType.identifier)
        guard let raw = sender.draggingPasteboard.string(forType: type),
              let payload = WorkspaceSidebarDragPayload(encodedValue: raw),
              let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        else {
            clearIncomingDrop()
            return []
        }
        if incomingDrop?.0 != payload || incomingDrop?.1 != target {
            incomingDrop = (payload, target)
            driver.reset()
            switch payload {
                case .window(let id): input?.actions.send(.previewWindowDrop(id, target: target))
                case .tabGroup(let id): input?.actions.send(.previewTabGroupDrop(id, target: target))
            }
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearIncomingDrop() }

    private func clearIncomingDrop() {
        guard incomingDrop != nil else { return }
        incomingDrop = nil
        input?.actions.send(.clearDropPreview)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .move, let (payload, target) = incomingDrop else { return false }
        clearIncomingDrop()
        if isWorkspaceSidebarDragInProgress(kind: getCurrentMouseManipulationKind(),
            startedInSidebar: getCurrentMouseDragStartedInSidebar()) {
            Task { @MainActor in
                finishWorkspaceSidebarDragAfterMouseUp()
                try? await resetManipulatedWithMouseIfPossible()
            }
            return true
        }
        return performDrop(payload, on: target)
    }

    @discardableResult
    func performDrop(_ payload: WorkspaceSidebarDragPayload, on target: WorkspaceSidebarDropTargetKind) -> Bool {
        guard let input else { return false }
        switch target {
            case .monitor: return false
            case .workspace(let name):
                guard let entry = input.workspaces.first(where: { $0.workspace.name == name }) else { return false }
                entry.drop(payload)
            case .newWorkspace(let projectId, let monitorScopeId):
                guard input.showsCreate, input.projectId == projectId, input.monitorScopeId == monitorScopeId else { return false }
                switch payload {
                    case .window(let id): input.actions.send(.moveWindowToNewWorkspace(id, projectId: projectId, monitorScopeId: monitorScopeId))
                    case .tabGroup(let id): input.actions.send(.moveTabGroupToNewWorkspace(id, projectId: projectId, monitorScopeId: monitorScopeId))
                }
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let geometry, let input else { return }
        let delta = input.configuration.dockPosition == .bottom && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset = min(max(scrollOffset - delta * (event.hasPreciseScrollingDeltas ? 1 : 12), 0), geometry.maximumScroll)
        isScrolling = true
        configurePointer(input)
        driver.reset(publishFrame: false)
        render(.init())
        scrollRecovery?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self, let input = self.input else { return }
            self.scrollRecovery = nil
            self.isScrolling = false
            self.configurePointer(input)
        }
        scrollRecovery = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: recovery)
    }
}

private final class WorkspaceSidebarNativeDockClipView: NSView {
    override var isFlipped: Bool { true }
}
