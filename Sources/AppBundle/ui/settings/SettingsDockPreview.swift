import AppKit
import SwiftUI

/// Uses the production shelf materials, workspace tile and lens geometry. It has
/// no window-management actions or native Dock integration: examples stay local.
struct SettingsDockPreview: View {
    @ObservedObject var editor: SettingsEditor
    @State private var expanded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private func value(_ key: String) -> SettingsValue { editor.value(SettingsCatalog.field(key)) }
    var previewConfiguration: WorkspaceSidebarConfiguration {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.showAppIcons = value("workspace-sidebar.mode").text == "dock"
        layout.dockPosition = WorkspaceDockPosition(rawValue: value("workspace-sidebar.dock-position").text) ?? .left
        layout.dockIconSize = CGFloat(value("workspace-sidebar.dock-icon-size").integer)
        layout.dockMagnification = value("workspace-sidebar.dock-magnification").bool && !value("workspace-sidebar.always-expanded").bool
        layout.dockMagnificationAmount = value("workspace-sidebar.dock-magnification-amount").number
        layout.chromeStyle = ChromeStyle(rawValue: value("workspace-sidebar.dock-appearance.style").text) ?? .liquidGlass
        layout.glassOpacity = value("workspace-sidebar.dock-appearance.glass-opacity").number
        layout.solidChromeColor = ChromeSolidColor(rawValue: value("workspace-sidebar.dock-appearance.solid-color").text) ?? .midnight
        layout.solidChromeCustomColor = value("workspace-sidebar.dock-appearance.custom-color").text
        layout.sidebarBlur = value("workspace-sidebar.sidebar-appearance.blur").bool
        layout.sidebarBackgroundOpacity = value("workspace-sidebar.sidebar-appearance.background-opacity").number
        layout.expandedWidth = CGFloat(value("workspace-sidebar.width").integer)
        layout.compactLeftGap = CGFloat(value("workspace-sidebar.dock-left-gap").integer)
        return layout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live preview").font(.headline)
                Spacer()
                if previewConfiguration.showAppIcons {
                    Toggle("Expanded", isOn: $expanded).toggleStyle(.button).controlSize(.small)
                }
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if expanded || !previewConfiguration.showAppIcons || value("workspace-sidebar.always-expanded").bool {
                    expandedPreview
                        .frame(width: min(previewConfiguration.expandedWidth, 245), height: 164)
                } else {
                    SettingsDockPreviewShelf(configuration: previewConfiguration,
                        showsBadge: value("workspace-sidebar.show-app-badges").bool)
                }
            }
            .frame(height: 194)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            Text("Sample workspace. Hover over the icons to try magnification. Preview updates while you adjust a slider; changes save when you release it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.dock-preview")
    }

    private var expandedPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Search windows", systemImage: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            Text("Workspace 1").font(.headline)
            Label("Mail — Inbox", systemImage: "envelope")
            Label("Finder — Documents", systemImage: "folder")
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            WorkspaceSidebarSurface(shape: RoundedRectangle(cornerRadius: 12), configuration: previewConfiguration)
        }
        .allowsHitTesting(false)
    }
}

private struct SettingsDockPreviewShelf: View {
    let configuration: WorkspaceSidebarConfiguration
    let showsBadge: Bool
    @State private var pointer: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let mailIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = configuration.dockPosition == .bottom
            let size = configuration.dockIconSize * 0.8
            let thickness = WorkspaceSidebarConfig.dockWidth(forIconSize: size)
            let lens = WorkspaceSidebarDockMagnification(itemSize: size, count: 2,
                enabled: configuration.dockMagnification && !reduceMotion, amount: configuration.dockMagnificationAmount)
            let frames = lens.frames(width: thickness, pointerY: pointer)
            let length = lens.renderedHeight(pointerY: pointer) + 16
            let gap = configuration.compactLeftGap
            let surface = CGRect(x: horizontal ? (geometry.size.width - length) / 2 : configuration.dockPosition == .right ? geometry.size.width - thickness - gap : gap,
                y: horizontal ? geometry.size.height - thickness - gap : (geometry.size.height - length) / 2,
                width: horizontal ? length : thickness, height: horizontal ? thickness : length)
            ZStack(alignment: .topLeading) {
                WorkspaceSidebarDockSurface(shape: RoundedRectangle(cornerRadius: thickness * 0.35), configuration: configuration)
                    .opacity(reduceTransparency ? 1 : configuration.effectiveGlassOpacity)
                    .frame(width: surface.width, height: surface.height)
                    .clipShape(RoundedRectangle(cornerRadius: thickness * 0.35))
                    .position(x: surface.midX, y: surface.midY)
                ForEach(0..<2) { index in
                    let base = frames[index].offsetBy(dx: 0, dy: 8)
                    let frame = workspaceSidebarDockOrientedFrame(base, crossAxis: thickness, position: configuration.dockPosition)
                        .offsetBy(dx: surface.minX, dy: surface.minY)
                    Group {
                        if index == 0 {
                            WorkspaceSidebarWorkspaceIcon(identifier: "1", isActive: true, size: frame.width,
                                railWidth: thickness, showsIndicator: false)
                        } else {
                            ZStack(alignment: .topTrailing) {
                                if let icon = Self.mailIcon { Image(nsImage: icon).resizable().scaledToFit() }
                                else { Image(systemName: "envelope.fill").resizable().scaledToFit().padding(6) }
                                if showsBadge {
                                    Text("3").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 17, height: 17).background(.red, in: Circle())
                                }
                            }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                    case .active(let point):
                        let iconHit = frames.contains { base in
                            workspaceSidebarDockOrientedFrame(base.offsetBy(dx: 0, dy: 8), crossAxis: thickness, position: configuration.dockPosition)
                                .offsetBy(dx: surface.minX, dy: surface.minY).contains(point)
                        }
                        pointer = surface.contains(point) || iconHit
                            ? (horizontal ? point.x - surface.minX : point.y - surface.minY) - 8 : nil
                    case .ended: pointer = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pointer == nil)
            .onChange(of: configuration.dockPosition) { _ in pointer = nil }
        }
        .padding(16)
        .accessibilityLabel("Sample Dock with workspace 1 and Mail\(showsBadge ? ", three unread messages" : "")")
    }
}
