import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarWorkspaceSection: View, Animatable {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let dragPreview: WorkspaceSidebarDropPreviewViewModel?
    nonisolated var expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration
    let emitsDropTarget: Bool
    let isFromOtherDisplay: Bool
    let isInUseOnOtherDisplay: Bool
    let isOnFocusedMonitor: Bool
    let allowsWorkspaceActivation: Bool
    let isPinnedActiveWorkspace: Bool
    let isActiveOnTargetMonitor: Bool
    let projectContextLabel: String?
    let projectContextColor: Color?
    @Binding var renamingWorkspaceName: String?
    @Binding var renamingWorkspaceText: String
    let onBeginRenameWorkspace: @MainActor () -> Void
    let onCommitRenameWorkspace: @MainActor () -> Void
    let onCancelRenameWorkspace: @MainActor () -> Void
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let isSearchFiltering: Bool
    @Binding var activeInUseOverrideWorkspaceName: String?
    @Binding var pendingInUseOverrideAppId: String?
    let actions: WorkspaceSidebarActions

    @State var isHovered = false
    @State var hoveredWindowId: UInt32? = nil
    @State var hoveredTabGroupId: UInt32? = nil
    @State var isDropTargeted = false
    @State var isDropSettling = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    nonisolated var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    var morphProgress: CGFloat { min(max(expansionProgress, 0), 1) }
    var compactCardWidth: CGFloat { max(layout.compactRailWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1) }
    var compactInnerInset: CGFloat { 0 }

    var headerHeight: CGFloat {
        if isCompact, layout.showAppIcons {
            return WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: appSummaryWidth).height
        }
        return workspaceSidebarWorkspaceSectionHeaderHeight
    }
    let rowHeight: CGFloat = workspaceSidebarWorkspaceRowHeight

    var contentWidth: CGFloat { workspaceSidebarContentWidth(expansionProgress, layout: layout) }
    var sectionWidth: CGFloat {
        guard layout.showAppIcons else { return workspaceSidebarSectionWidth(expansionProgress, layout: layout) }
        let compact = max(layout.collapsedWidth - workspaceSidebarCompactRailHorizontalInset * 2, 1)
        let expanded = workspaceSidebarExpandedSectionWidth(layout: layout)
        return compact + (expanded - compact) * morphProgress
    }
    var sectionInnerInset: CGFloat {
        layout.showAppIcons
            ? compactInnerInset + (workspaceSidebarSectionInnerHorizontalInset - compactInnerInset) * morphProgress
            : workspaceSidebarSectionInnerHorizontalInset
    }
    var appSummaryWidth: CGFloat { max(compactCardWidth - compactInnerInset * 2, 1) }
    var isCompact: Bool { expansionProgress < workspaceSidebarRowsRevealProgress }
    var showsWindowRows: Bool { expansionProgress >= workspaceSidebarRowsRevealProgress }
    var sectionMinHeight: CGFloat? {
        if layout.showAppIcons, allowsWorkspaceActivation, isInUseOnOtherDisplay,
           workspace.items.isEmpty || isShowingInUseOverlay
        {
            let compactHeight = WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: appSummaryWidth).height + 6
            let expandedHeight = workspaceSidebarInUseOverrideMinHeight(sectionWidth: workspaceSidebarExpandedSectionWidth(layout: layout))
            return compactHeight + (expandedHeight - compactHeight) * morphProgress
        }
        if !isCompact, allowsWorkspaceActivation, isInUseOnOtherDisplay,
           workspace.items.isEmpty || isShowingInUseOverlay
        {
            return workspaceSidebarInUseOverrideMinHeight(sectionWidth: sectionWidth)
        }
        return nil
    }
    var isDropTarget: Bool { dragPreview?.targetWorkspaceName == workspace.name }
    var activeSidebarDragSourceWindowId: UInt32? { dragPreview?.sourceWindowId }
    var isShowingInUseOverlay: Bool { activeInUseOverrideWorkspaceName == workspace.name }
    var showsInUseOverride: Bool {
        expansionProgress >= 1 && allowsWorkspaceActivation && isInUseOnOtherDisplay && isShowingInUseOverlay
    }
    var isSearchSelectedWorkspace: Bool { selectedSearchTarget == .workspace(workspace.name) }
    var isRenamingWorkspace: Bool { renamingWorkspaceName == workspace.name }
    var inUseOverrideText: String {
        if let monitorName = workspace.monitorName, !monitorName.isEmpty {
            return "In use on \(monitorName)"
        }
        return "In use on another display"
    }
    var sectionShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: workspaceSidebarSectionCornerRadius, style: .continuous)
    }

    var body: some View {
        interactiveSectionContent
            .padding(.vertical, layout.showAppIcons ? 3 + morphProgress : (isCompact ? 3 : 4))
            .padding(.horizontal, sectionInnerInset)
            .frame(width: sectionWidth, alignment: .leading)
            .frame(minHeight: sectionMinHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .opacity(compactFocusOpacity)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    debugWorkspaceSidebarRenameLog("workspaceContextRename workspace=\(workspace.name) displayName=\(workspace.displayName) compact=\(isCompact)")
                    onBeginRenameWorkspace()
                } label: {
                    Text("Rename Workspace")
                }
                Divider()
                Button(role: .destructive) {
                    actions.send(.deleteWorkspace(workspace.name))
                } label: {
                    Text("Delete Workspace")
                }
            }
            .onHover { hover in
                isHovered = hover
                actions.hoverWorkspace(workspace.name, hover)
            }
            .onDrop(of: [workspaceSidebarDragPayloadType], delegate: WorkspaceSidebarDropDelegate(
                target: .workspace(workspace.name),
                actions: actions,
                performPayloadDrop: handlePayloadDrop,
                isTargeted: $isDropTargeted,
                isSettling: $isDropSettling,
            ))
            .help(isInUseOnOtherDisplay ? inUseOverrideText : (layout.showAppIcons ? workspaceSidebarAppSummaryLabel(workspace) : workspace.displayName))
            .zIndex(isDropTarget ? 1 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: dragPreview)
            .modifier(WorkspaceSidebarLegacyExpansionAnimation(isEnabled: !layout.showAppIcons, reduceMotion: reduceMotion, progress: expansionProgress))
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: isHovered)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: hoveredWindowId)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: hoveredTabGroupId)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: isOnFocusedMonitor)
            .background {
                ZStack {
                    sectionBackground
                    if (layout.showAppIcons || !isCompact) && allowsWorkspaceActivation {
                        sectionActivationButton
                    }
                }
            }
            .overlay(alignment: .center) {
                if showsInUseOverride {
                    inUseOverrideOverlay
                        .zIndex(5)
                }
            }
            .onChange(of: isInUseOnOtherDisplay) { isInUse in
                if !isInUse, isShowingInUseOverlay {
                    activeInUseOverrideWorkspaceName = nil
                }
            }
            .onChange(of: workspace.monitorScopeId) { _ in
                cancelWorkspaceOverride()
            }
            .shadow(
                color: isDropTarget ? Color.white.opacity(0.16) : .clear,
                radius: isDropTarget ? 12 : 0
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WorkspaceSidebarDropTargetPreferenceKey.self,
                        value: emitsDropTarget ? [WorkspaceSidebarDropTargetFrame(
                            kind: .workspace(workspace.name),
                            frame: geometry.frame(in: .named("workspaceSidebarContent")),
                        )] : [],
                    )
                }
            }
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var morphsTitle: Bool { layout.showAppIcons && !isRenamingWorkspace }

    /// Only pair the icons shown in the fixed compact column with rows actually rendered below.
    var appMorphTargets: [String: WorkspaceSidebarAppMorphTarget] {
        guard layout.showAppIcons else { return [:] }
        let count = WorkspaceSidebarAppIconLayout(appCount: workspace.apps.count, availableWidth: appSummaryWidth).visibleAppCount
        let visibleAppIds = Set(workspace.apps.prefix(count).map(\.id))
        var targets: [String: WorkspaceSidebarAppMorphTarget] = [:]
        for item in workspace.items {
            let windows: [WorkspaceSidebarWindowViewModel]
            let opacity: Double
            switch item.kind {
                case .window(let window):
                    windows = [window]
                    opacity = 1
                case .tabGroup(let group):
                    windows = group.searchVisibleTabs ?? group.tabs
                    opacity = 0.56
            }
            for window in windows {
                let id = WorkspaceSidebarAppViewModel(name: window.appName, bundleId: window.appBundleId, bundlePath: window.appBundlePath).id
                if visibleAppIds.contains(id), targets[id] == nil {
                    targets[id] = WorkspaceSidebarAppMorphTarget(windowId: window.windowId, opacity: opacity)
                }
            }
        }
        return targets
    }

    func morphAppId(for window: WorkspaceSidebarWindowViewModel, targets: [String: WorkspaceSidebarAppMorphTarget]? = nil) -> String? {
        (targets ?? appMorphTargets).first { $0.value.windowId == window.windowId }?.key
    }

    var morphingSectionContent: some View {
        let targets = appMorphTargets
        return WorkspaceSidebarMorphLayout(progress: morphProgress, compactWidth: appSummaryWidth) {
            VStack(alignment: .leading, spacing: 3) {
                WorkspaceSidebarAppIconHeader(
                    workspace: workspace,
                    availableWidth: appSummaryWidth,
                    isActive: isActiveOnTargetMonitor,
                    morphTargets: Set(targets.keys),
                    morphsTitle: morphsTitle,
                )
                dropPreviewRow(style: .appIcon(size: WorkspaceSidebarAppIconLayout(appCount: 0, availableWidth: appSummaryWidth).itemSize))
            }
            .opacity(1 - Double(morphProgress))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                expandedHeader.frame(height: workspaceSidebarWorkspaceSectionHeaderHeight)
                windowRows
                dropPreviewRow()
            }
            .opacity(Double(morphProgress))
            .allowsHitTesting(morphProgress >= 1)
            .accessibilityHidden(morphProgress < 1)
        }
        .overlayPreferenceValue(WorkspaceSidebarMorphPreference.self) { anchors in
            ZStack {
                WorkspaceSidebarMorphOverlay(
                    anchors: anchors,
                    progress: morphProgress,
                    workspace: workspace,
                    targets: targets,
                    isActive: isActiveOnTargetMonitor,
                    morphsTitle: morphsTitle,
                )
                if allowsWorkspaceActivation, !isRenamingWorkspace, morphProgress < 1 {
                    WorkspaceSidebarDockAppButtons(
                        anchors: anchors,
                        progress: morphProgress,
                        workspace: workspace,
                        targets: targets,
                        actions: actions,
                        onSelectApp: handleAppClick
                    )
                }
            }
        }
        .modifier(WorkspaceSidebarReadOnlySummary(isEnabled: !allowsWorkspaceActivation, label: workspaceSidebarAppSummaryLabel(workspace)))
    }

    func handleSectionClick() {
        guard allowsWorkspaceActivation,
              shouldHandleWorkspaceSidebarActivation(
                isEditing: isRenamingWorkspace,
                isSidebarDragInProgress: isWorkspaceSidebarDragInProgress(),
              )
        else { return }
        pendingInUseOverrideAppId = nil
        if isInUseOnOtherDisplay {
            activeInUseOverrideWorkspaceName = workspace.name
            if expansionProgress < 1 {
                actions.send(.expandForWorkspaceOverride)
            }
            return
        }
        actions.send(.selectWorkspace(workspace.name))
    }

    func handleAppClick(_ app: WorkspaceSidebarAppViewModel) {
        guard allowsWorkspaceActivation,
              shouldHandleWorkspaceSidebarActivation(
                isEditing: isRenamingWorkspace,
                isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()
              )
        else { return }
        if isInUseOnOtherDisplay {
            pendingInUseOverrideAppId = app.id
            activeInUseOverrideWorkspaceName = workspace.name
            if expansionProgress < 1 { actions.send(.expandForWorkspaceOverride) }
            return
        }
        pendingInUseOverrideAppId = nil
        activeInUseOverrideWorkspaceName = nil
        actions.send(.selectApp(workspaceName: workspace.name, appId: app.id))
    }

    func commitWorkspaceOverride() {
        guard showsInUseOverride else { return }
        let appId = pendingInUseOverrideAppId
        pendingInUseOverrideAppId = nil
        activeInUseOverrideWorkspaceName = nil
        if let appId {
            actions.send(.overrideWorkspaceInUseAndSelectApp(workspaceName: workspace.name, appId: appId))
        } else {
            actions.send(.overrideWorkspaceInUse(workspace.name))
        }
    }

    func cancelWorkspaceOverride() {
        if isShowingInUseOverlay {
            pendingInUseOverrideAppId = nil
            activeInUseOverrideWorkspaceName = nil
        }
    }

    func handlePayloadDrop(_ payload: WorkspaceSidebarDragPayload) {
        guard !workspaceSidebarPayload(payload, comesFromWorkspace: workspace.name) else {
            actions.send(.clearDropPreview)
            WindowDragCursorProxyPanel.shared.hide()
            return
        }
        switch payload {
            case .window(let windowId):
                actions.send(.moveWindow(windowId, toWorkspace: workspace.name))
            case .tabGroup(let representativeWindowId):
                actions.send(.moveTabGroup(representativeWindowId, toWorkspace: workspace.name))
        }
    }
}

private struct WorkspaceSidebarLegacyExpansionAnimation: ViewModifier {
    let isEnabled: Bool
    let reduceMotion: Bool
    let progress: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.82), value: progress)
        } else {
            content
        }
    }
}

private struct WorkspaceSidebarReadOnlySummary: ViewModifier {
    let isEnabled: Bool
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            content
        }
    }
}

@MainActor
private func workspaceSidebarPayload(_ payload: WorkspaceSidebarDragPayload, comesFromWorkspace workspaceName: String) -> Bool {
    switch payload {
        case .window(let windowId):
            return Window.get(byId: windowId)?.nodeWorkspace?.name == workspaceName
        case .tabGroup(let representativeWindowId):
            guard let window = Window.get(byId: representativeWindowId) else { return false }
            return dragSubjectNode(for: window, subject: .group).nodeWorkspace?.name == workspaceName
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var sectionBackground: some View {
        sectionShape
            .fill(sectionBackgroundFill)
            .background { sectionGlassCard }
            .overlay {
                if isActiveWorkspaceSelection {
                    sectionShape
                        .strokeBorder(Color.white.opacity(layout.showAppIcons ? 0.30 - 0.10 * Double(morphProgress) : (isCompact ? 0.30 : 0.20)), lineWidth: StrokeToken.control)
                }
                if isPinnedActiveWorkspace && !isSearchFiltering {
                    sectionShape
                        .strokeBorder(
                            Color.white.opacity(0.24),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }
            }
            .opacity(layout.showAppIcons ? (isDropTarget ? max(Double(morphProgress), 0.45) : Double(morphProgress)) : 1)
    }

    /// The Apple-native container look for an expanded workspace: a dimensional Liquid Glass card.
    /// A bare `.glassEffect` over the already-glassy panel reads flat, so this adds the three
    /// things that give real Liquid Glass its depth — a refractive edge, a specular top
    /// highlight, and a lift shadow — and renders inside a `GlassEffectContainer` (only glass,
    /// no foreground text, so it's safe) where the native lensing actually engages. The state
    /// tint fills on top. No-op on older systems; the plain tint fill stands in.
    @ViewBuilder
    var sectionGlassCard: some View {
        if #available(macOS 26.0, *), layout.chromeStyle == .liquidGlass {
            GlassEffectContainer {
                ZStack {
                    Color.clear.glassEffect(.regular, in: sectionShape)
                    // Specular top sheen.
                    sectionShape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.16), location: 0),
                                    .init(color: Color.white.opacity(0.04), location: 0.14),
                                    .init(color: Color.clear, location: 0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottom,
                            )
                        )
                        .blendMode(.screen)
                    // Refractive glass edge.
                    Color.clear
                        .glassEffect(.regular, in: sectionShape)
                        .mask(sectionShape.stroke(lineWidth: 2))
                    sectionShape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
            }
            .glassShadow(.resting)
            .opacity(layout.effectiveGlassOpacity)
        } else if layout.chromeStyle == .solid {
            sectionShape
                .fill(layout.resolvedSolidChromeColor.opacity(0.38))
                .overlay {
                    sectionShape.strokeBorder(Color.white.opacity(0.12), lineWidth: StrokeToken.hairline)
                }
        }
    }

    var sectionBackgroundFill: Color {
        if isDropTarget {
            // A neutral lift works against both solid colors and Liquid Glass without
            // introducing the system accent color into themed chrome.
            return Color.white.opacity(layout.chromeStyle == .solid ? 0.18 : 0.14)
        }
        if isSearchSelectedWorkspace {
            return Color.white.opacity(0.105)
        }
        if isSearchFiltering {
            return isHovered ? Color.white.opacity(0.045) : Color.white.opacity(0.015)
        }
        if allowsWorkspaceActivation && isInUseOnOtherDisplay {
            let redOpacity: Double = workspace.isFocused ? 0.16 : 0.065
            let hoveredRedOpacity: Double = workspace.isFocused ? 0.24 : 0.13
            return Color(nsColor: .systemRed).opacity(isHovered ? hoveredRedOpacity : redOpacity)
        }
        if isPinnedActiveWorkspace {
            return Color.white.opacity(isHovered ? 0.15 : 0.10)
        }
        if isActiveOnTargetMonitor {
            let compactOpacity: Double = workspace.isFocused ? 0.24 : 0.14
            let expandedOpacity: Double = workspace.isFocused ? 0.12 : 0.07
            return Color.white.opacity(layout.showAppIcons
                ? compactOpacity + (expandedOpacity - compactOpacity) * Double(morphProgress)
                : (isCompact ? compactOpacity : expandedOpacity))
        }
        if isFromOtherDisplay {
            return Color(nsColor: .systemPink).opacity(isHovered ? 0.10 : 0.05)
        }
        if isHovered {
            return Color.white.opacity(0.045)
        }
        return Color.white.opacity(0.015)
    }

    var isActiveWorkspaceSelection: Bool {
        !isSearchFiltering && (isPinnedActiveWorkspace || isActiveOnTargetMonitor)
    }

    var compactFocusOpacity: Double {
        if layout.showAppIcons, !isOnFocusedMonitor { return 0.72 + 0.28 * Double(morphProgress) }
        return isCompact && !isOnFocusedMonitor ? 0.72 : 1
    }

    var inUseOverrideOverlay: some View {
        WorkspaceSidebarInUseOverrideOverlay(
            text: inUseOverrideText,
            onOverride: commitWorkspaceOverride,
            onCancel: cancelWorkspaceOverride,
        )
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var workspaceBadge: some View {
        Text(workspaceBadgeText)
            .font(.system(size: 18, weight: isActiveOnTargetMonitor ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(workspaceBadgeForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: workspaceSidebarBadgeWidth, height: workspaceSidebarBadgeWidth)
    }

    var workspaceBadgeText: String {
        if workspace.isGeneratedName, workspace.sidebarLabel.isEmpty {
            return generatedWorkspaceBadgeText
        }
        if workspace.isGeneratedName, let initial = workspace.displayName.first {
            return String(initial).uppercased()
        }
        return workspace.displayName.first.map { String($0).uppercased() } ?? "W"
    }

    var generatedWorkspaceBadgeText: String {
        let prefix = "Workspace "
        if workspace.displayName.hasPrefix(prefix) {
            let suffix = String(workspace.displayName.dropFirst(prefix.count))
            if !suffix.isEmpty { return suffix }
        }
        return workspace.displayName.first.map { String($0).uppercased() } ?? "W"
    }

    var workspaceBadgeForeground: Color {
        if isActiveOnTargetMonitor {
            return Color.white
        }
        return Color.white.opacity(0.70)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var headerButton: some View {
        Button(action: handleSectionClick) {
            header
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var header: some View {
        Group {
            if isCompact {
                if layout.showAppIcons {
                    WorkspaceSidebarAppIconHeader(
                        workspace: workspace,
                        availableWidth: appSummaryWidth,
                        isActive: isActiveOnTargetMonitor,
                    )
                } else {
                    workspaceBadge
                        .frame(width: workspaceSidebarBadgeWidth, height: workspaceSidebarBadgeWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                expandedHeader
            }
        }
    }

    var expandedHeader: some View {
        HStack(spacing: workspaceSidebarHeaderSpacing) {
            if isRenamingWorkspace && (!layout.showAppIcons || morphProgress >= 1) {
                WorkspaceSidebarWorkspaceRenameField(
                    text: $renamingWorkspaceText,
                    workspaceName: workspace.name,
                    onCommit: onCommitRenameWorkspace,
                    onCancel: onCancelRenameWorkspace,
                )
            } else {
                Text(workspace.displayName)
                    .font(expandedTitleFont)
                    .foregroundStyle(isActiveOnTargetMonitor ? Color.white : Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(WorkspaceSidebarMorphAnchor(element: .expandedTitle, isEnabled: morphsTitle))
            }
            if let projectContextLabel, let projectContextColor {
                Text(projectContextLabel)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(projectContextColor.opacity(0.86))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background {
                        Capsule(style: .continuous)
                            .fill(projectContextColor.opacity(0.13))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(projectContextColor.opacity(0.24), lineWidth: 0.5)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, workspaceSidebarHeaderRowLeadingPadding)
        .padding(.trailing, workspaceSidebarRowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var expandedTitleFont: Font {
        let font = Font.system(size: 15, weight: isActiveOnTargetMonitor ? .bold : .semibold)
        return layout.showAppIcons ? font.monospacedDigit() : font
    }
}
extension WorkspaceSidebarWorkspaceSection {
    @ViewBuilder
    var windowRows: some View {
        let targets = appMorphTargets
        if (layout.showAppIcons || showsWindowRows), !workspace.items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(workspace.items) { item in
                    workspaceItemView(item, morphTargets: targets)
                }
            }
            .padding(.leading, workspaceSidebarWindowRowsLeadingIndent)
        }
    }

    @ViewBuilder
    func workspaceItemView(_ item: WorkspaceSidebarItemViewModel, morphTargets: [String: WorkspaceSidebarAppMorphTarget]) -> some View {
        switch item.kind {
            case .window(let window):
                workspaceWindowButton(window, allowsDrag: true, appIconMorphId: morphAppId(for: window, targets: morphTargets))
            case .tabGroup(let group):
                workspaceTabGroupView(group, morphTargets: morphTargets)
        }
    }

    @ViewBuilder
    func dropPreviewRow(style: WorkspaceSidebarDragPreviewStyle = .row) -> some View {
        if dragPreview?.targetWorkspaceName == workspace.name {
            WorkspaceSidebarDropPreviewView(preview: dragPreview.orDie(), rowHeight: rowHeight, style: style)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .opacity),
                removal: .identity,
            ))
        }
    }
}
extension WorkspaceSidebarWorkspaceSection {
    @ViewBuilder
    var interactiveSectionContent: some View {
        if layout.showAppIcons {
            morphingSectionContent
        } else if isCompact {
            Button(action: handleSectionClick) {
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(sectionShape)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(sectionShape)
        } else {
            sectionContent.contentShape(sectionShape)
        }
    }

    var sectionActivationButton: some View {
        Button(action: handleSectionClick) {
            Color.clear.contentShape(sectionShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.showAppIcons && morphProgress < 1 ? workspaceSidebarAppSummaryLabel(workspace) : workspace.displayName)
    }

    var sectionContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            headerSlot
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            windowRows
            dropPreviewRow()
        }
    }

    @ViewBuilder
    var headerSlot: some View {
        header
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func workspaceTabGroupView(_ group: WorkspaceSidebarTabGroupViewModel, morphTargets: [String: WorkspaceSidebarAppMorphTarget]) -> some View {
        let isDragging = activeSidebarDragSourceWindowId == group.representativeWindowId
        return VStack(alignment: .leading, spacing: 1) {
            tabGroupHeaderButton(group)
            tabGroupTabs(group, isDragging: isDragging, morphTargets: morphTargets)
        }
        .padding(.vertical, 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: isDragging)
    }

    func tabGroupTabs(_ group: WorkspaceSidebarTabGroupViewModel, isDragging: Bool, morphTargets: [String: WorkspaceSidebarAppMorphTarget]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.searchVisibleTabs ?? group.tabs) { tab in
                workspaceWindowButton(
                    tab,
                    allowsDrag: true,
                    subject: .window,
                    leadingHitInset: workspaceSidebarTabGroupChildLeadingIndent,
                    appIconMorphId: morphAppId(for: tab, targets: morphTargets),
                )
            }
        }
        .opacity(1)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func tabGroupHeaderButton(_ group: WorkspaceSidebarTabGroupViewModel) -> some View {
        Button {
            guard allowsWorkspaceActivation else { return }
            guard shouldHandleWorkspaceSidebarActivation(isEditing: false, isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()) else { return }
            pendingInUseOverrideAppId = nil
            if isInUseOnOtherDisplay {
                activeInUseOverrideWorkspaceName = workspace.name
                return
            }
            activeInUseOverrideWorkspaceName = nil
            actions.send(.selectWindow(group.representativeWindowId))
        } label: {
            WorkspaceSidebarWindowRow(
                title: group.title.isEmpty ? "Tab Group" : group.title,
                badge: group.windowCount > 1 ? "\(group.windowCount)" : nil,
                isFocused: group.isFocused,
                suppressFocusedStyle: isSearchFiltering,
                rowHeight: rowHeight,
                isHovered: hoveredTabGroupId == group.representativeWindowId || selectedSearchTarget == .window(group.representativeWindowId),
                style: .tabGroupHeader,
                appBundleIds: group.tabs.map(\.appBundleId),
                appBundlePaths: group.tabs.map(\.appBundlePath),
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.tabGroupDragChanged(group.representativeWindowId, $0) },
            onEnded: { actions.tabGroupDragEnded(group.representativeWindowId, $0) },
        ))
        .workspaceSidebarDrag(enabled: true) {
            WorkspaceSidebarDragPayload.tabGroup(group.representativeWindowId).itemProvider
        }
        .onHover { hover in
            hoveredTabGroupId = hover ? group.representativeWindowId :
                (hoveredTabGroupId == group.representativeWindowId ? nil : hoveredTabGroupId)
        }
        .opacity(1)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func workspaceWindowButton(
        _ window: WorkspaceSidebarWindowViewModel,
        allowsDrag: Bool,
        subject: WindowDragSubject = .window,
        leadingHitInset: CGFloat = 0,
        appIconMorphId: String? = nil,
    ) -> some View {
        Button {
            guard allowsWorkspaceActivation else { return }
            guard shouldHandleWorkspaceSidebarActivation(isEditing: false, isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()) else { return }
            pendingInUseOverrideAppId = nil
            if isInUseOnOtherDisplay {
                activeInUseOverrideWorkspaceName = workspace.name
                return
            }
            activeInUseOverrideWorkspaceName = nil
            actions.send(.selectWindow(window.windowId))
        } label: {
            WorkspaceSidebarWindowRow(
                title: window.title ?? window.appName,
                badge: nil,
                isFocused: window.isFocused,
                suppressFocusedStyle: isSearchFiltering,
                rowHeight: rowHeight,
                isHovered: hoveredWindowId == window.windowId || selectedSearchTarget == .window(window.windowId),
                style: leadingHitInset > 0 ? .tabGroupChild : .window,
                appBundleIds: [window.appBundleId],
                appBundlePaths: [window.appBundlePath],
                appIconMorphId: appIconMorphId,
            )
            .padding(.leading, leadingHitInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: allowsDrag,
            onChanged: { pointer in
                if subject == .group {
                    actions.tabGroupDragChanged(window.windowId, pointer)
                } else {
                    actions.windowDragChanged(window.windowId, pointer)
                }
            },
            onEnded: { pointer in
                if subject == .group {
                    actions.tabGroupDragEnded(window.windowId, pointer)
                } else {
                    actions.windowDragEnded(window.windowId, pointer)
                }
            },
        ))
        .workspaceSidebarDrag(enabled: allowsDrag) {
            WorkspaceSidebarDragPayload.window(window.windowId).itemProvider
        }
        .onHover { hover in
            hoveredWindowId = nextWorkspaceSidebarHoveredWindowId(
                currentHoveredWindowId: hoveredWindowId,
                windowId: window.windowId,
                isHovering: hover,
            )
        }
        .opacity(1)
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: activeSidebarDragSourceWindowId == window.windowId)
    }
}
